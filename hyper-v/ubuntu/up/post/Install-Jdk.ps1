<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1.
    Invoked by Invoke-VmPostProvisioning, which owns the file server +
    SSH lifecycle. This function is a step within that lifecycle, not an
    entry point.
#>

# ---------------------------------------------------------------------------
# Install-Jdk
#   Installs the prefetched Temurin tarball ($Vm._jdkTarballPath, populated
#   by Invoke-JdkAcquisition during the host-side phase) onto the VM:
#     - Stages the tarball via $Server (Add-VmFileServerFile -> URL).
#     - Streams curl -> tar with --strip-components=1 into
#       /opt/jdk-{vendor}-{resolvedVersion}/ - the tarball is never
#       materialised on the VM disk.
#     - Writes /etc/profile.d/jdk.sh so every login shell - including
#       users later created by Infrastructure-Vm-Users - sees JAVA_HOME
#       and $JAVA_HOME/bin on PATH.
#
#   Self-contained: takes its own SSH client and file-server handle from
#   the orchestrator, but does not consume anything left on the VM by
#   another step. Re-runnable in isolation.
#
#   Idempotency: the install no-ops if the install dir's 'release' file
#   (shipped at the root of every Temurin tarball) already exists.
#
#   Security: the admin password is supplied to the SSH client by the
#   orchestrator; this function never sees it. The install script never
#   embeds it.
# ---------------------------------------------------------------------------

function Install-Jdk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [object] $Server,

        [Parameter(Mandatory)]
        [object] $Vm
    )

    $vendor          = $Vm.javaDevKit.vendor
    $resolvedVersion = $Vm._jdkResolvedVersion
    $tarballPath     = $Vm._jdkTarballPath
    $installDir      = "/opt/jdk-$vendor-$resolvedVersion"

    Write-Host "  [JDK] $vendor $resolvedVersion -> $installDir"

    $url = Add-VmFileServerFile -Server $Server -LocalPath $tarballPath

    # PS-side $url and $installDir interpolate at construction time;
    # backtick-prefixed shell variables stay literal so the running shell
    # dereferences its own copies. The single-quoted printf format keeps
    # $JAVA_HOME / $PATH literal in the generated jdk.sh so they expand
    # at user-login time, not jdk.sh-creation time.
    #
    # Two PATH wirings are needed because they cover different shell
    # contexts:
    #   - /etc/profile.d/jdk.sh sets JAVA_HOME and prepends $JAVA_HOME/bin
    #     to PATH for LOGIN shells. JAVA_HOME is what build tools and
    #     IDEs read; not setting it would force every consumer to
    #     hard-code the install path.
    #   - Symlinks under /usr/local/bin make the JDK binaries reachable
    #     from NON-login shells too (sshd command execution, systemd
    #     services, cron jobs). /usr/local/bin is on the default PATH
    #     baked into /etc/login.defs ENV_PATH and PAM, which both login
    #     and non-login shells inherit.
    $installScript = @"
set -e
install_dir='$installDir'
url='$url'
if [ ! -f "`$install_dir/release" ]; then
  sudo mkdir -p "`$install_dir"
  curl -fsSL "`$url" | sudo tar -xzf - --strip-components=1 -C "`$install_dir"
  printf 'export JAVA_HOME=%s\nexport PATH="`$JAVA_HOME/bin:`$PATH"\n' \
    "`$install_dir" | sudo tee /etc/profile.d/jdk.sh > /dev/null
  sudo chmod 0644 /etc/profile.d/jdk.sh
  for f in "`$install_dir"/bin/*; do
    sudo ln -sf "`$f" /usr/local/bin/
  done
fi
"@

    $result = Invoke-SshClientCommand -SshClient $SshClient -Command $installScript
    if ($result.ExitStatus -ne 0) {
        throw ("JDK install failed on $($Vm.vmName) " +
            "(exit $($result.ExitStatus)). " +
            "stdout: $($result.Output)  stderr: $($result.Error)")
    }

    Write-Host "  [JDK] [OK] installed under $installDir." -ForegroundColor Green
}
