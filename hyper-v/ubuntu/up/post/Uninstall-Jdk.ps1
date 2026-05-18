<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1.
    Invoked by Invoke-VmPostProvisioning, which owns the file server +
    SSH lifecycle. This function is a step within that lifecycle, not an
    entry point.
#>

# ---------------------------------------------------------------------------
# Uninstall-Jdk
#   Removes a previously provisioned JDK from the VM:
#     - Deletes /opt/jdk-{vendor}-* (matched by vendor prefix glob - the
#       v1 invariant is "one JDK per VM", so a single vendor prefix
#       uniquely identifies the install).
#     - Prunes /usr/local/bin symlinks pointing into the removed dir
#       (those that Install-Jdk wired up for non-login shell PATH).
#     - Deletes /etc/profile.d/jdk.sh unconditionally (the path is
#       provisioner-owned; no content-match check).
#
#   Self-contained: takes its own SSH client; no host file server is
#   needed (nothing is staged for a removal). Re-runnable in isolation.
#
#   Idempotency: an empty glob is a no-op (nullglob), so re-runs with
#   the uninstall flag still set stay green. This is required because
#   the flag intentionally stays in the JSON across successful runs - the
#   operator removes it explicitly when truly done.
# ---------------------------------------------------------------------------

function Uninstall-Jdk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [object] $Vm
    )

    $vendor = $Vm.javaDevKit.vendor

    Write-Host "  [JDK] uninstall vendor='$vendor'"

    # PS-side $vendor interpolates at construction time; backtick-prefixed
    # shell variables stay literal so the running shell dereferences its
    # own copies.
    #
    # Symlinks under /usr/local/bin are pruned BEFORE the install dirs are
    # removed: doing it first lets readlink resolve to the still-present
    # target, so a simple case-match against "$d"/* tells us which links
    # belong to this JDK. After rm -rf the targets are orphaned and the
    # match would need string surgery to recover the same information.
    $uninstallScript = @"
set -e
vendor='$vendor'
shopt -s nullglob
install_dirs=( /opt/jdk-"`$vendor"-* )
for d in "`${install_dirs[@]}"; do
  for link in /usr/local/bin/*; do
    [ -L "`$link" ] || continue
    target="`$(readlink -f "`$link" || true)"
    case "`$target" in
      "`$d"/*) sudo rm -f "`$link" ;;
    esac
  done
  sudo rm -rf "`$d"
done
sudo rm -f /etc/profile.d/jdk.sh
"@

    # Normalise CRLF -> LF; bash treats a trailing \r as part of the token
    # ('set -e\r' -> 'bash: set: -: invalid option').
    $uninstallScript = $uninstallScript -replace "`r`n", "`n"

    $result = Invoke-SshClientCommand -SshClient $SshClient -Command $uninstallScript
    if ($result.ExitStatus -ne 0) {
        throw ("JDK uninstall failed on $($Vm.vmName) " +
            "(exit $($result.ExitStatus)). " +
            "stdout: $($result.Output)  stderr: $($result.Error)")
    }

    Write-Host "  [JDK] [OK] uninstall complete." -ForegroundColor Green
}
