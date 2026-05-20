<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1 after the
    per-step functions and Infrastructure.HyperV are loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-VmPostProvisioning
#   Post-provisioning orchestrator. Runs once per VM after Invoke-VmCreation
#   has confirmed SSH is reachable. Owns the transport: opens the host file
#   server and a single SSH session, waits for cloud-init to finish, then
#   dispatches to per-step functions.
#
#   Each dispatched step is self-contained - its inputs come from the VM
#   definition and its own acquired/staged files; it must not consume files
#   left on the VM by another step. Order between steps is therefore a
#   stylistic choice ('files' before installs), not a correctness one.
#
#   Why one orchestrator: starting a file server, opening SSH, and waiting
#   for cloud-init are per-VM concerns paid once, not per-step. Adding a
#   new step adds one dispatch line here, not a fresh file-server +
#   SSH + cloud-init scaffold.
# ---------------------------------------------------------------------------

function Invoke-VmPostProvisioning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    # Decide which steps apply before opening any transport. If nothing
    # applies, exit silently - no file server, no SSH, no log noise.
    $hasFiles = $Vm.PSObject.Properties['files'] -and
                @($Vm.files).Count -gt 0
    $hasJdk   = $Vm.PSObject.Properties['javaDevKit']
    if (-not ($hasFiles -or $hasJdk)) {
        return
    }

    Write-Host ""
    Write-Host "--- Post-provisioning: $($Vm.vmName) ---" -ForegroundColor Cyan

    # Capture VM fields explicitly into locals so the closure scriptblock
    # below sees them when invoked from another module (Invoke-WithVmFileServer
    # lives in Infrastructure.HyperV - function-scoped variables are not in
    # its lookup chain at invocation time without GetNewClosure()).
    $vmIp     = $Vm.ipAddress
    $vmName   = $Vm.vmName
    $username = $Vm.username
    $password = $Vm.password
    $vmRef    = $Vm

    # Capture the per-step functions as scriptblock locals so the closure
    # below can invoke them via the call operator. Name-based command
    # resolution from a closure invoked across a module boundary does NOT
    # walk back into provision.ps1's script scope where these functions
    # were dot-sourced. Capturing as variables sidesteps the lookup
    # entirely - the variables themselves are preserved by GetNewClosure().
    # Module-exported cmdlets (e.g. Copy-VmFiles) work the same way under
    # this approach, so the dispatch is uniform.
    $copyVmFiles          = ${function:Copy-VmFiles}
    $copyVmFilesByPattern = ${function:Copy-VmFilesByPattern}
    $installJdk           = ${function:Install-Jdk}
    $uninstallJdk         = ${function:Uninstall-Jdk}

    $postBlock = {
        param($server)

        $sshClient = $null
        try {
            $sshClient = New-VmSshClient `
                             -IpAddress $vmIp `
                             -Username  $username `
                             -Password  $password

            # cloud-init may still be running its later modules (apt holding
            # the dpkg lock, runcmd not yet started). Wait once, here, so no
            # downstream step has to know about it. timeout(1) caps the wait
            # server-side because SSH.NET has no client-side command timeout.
            Write-Host "  Waiting for cloud-init to finish ..."
            $waitResult = Invoke-SshClientCommand -SshClient $sshClient `
                -Command 'timeout 600 cloud-init status --wait'
            if ($waitResult.ExitStatus -ne 0) {
                # Non-zero here is most often unrelated to our steps
                # (cloud-init may have logged a warning in some module).
                # Proceed and let downstream assertions surface a real
                # problem rather than abort here on a false positive.
                Write-Warning ("cloud-init reported a non-zero status " +
                    "($($waitResult.ExitStatus)) on $vmName. Proceeding " +
                    "with post-provisioning steps.")
            }

            # Dispatch order: files first as a stylistic choice. Steps must
            # not depend on each other's outputs - if a future install needs
            # an artefact, it acquires its own copy.
            if ($hasFiles) {
                # Provisioner policy: every user file lands as root:root, 0644.
                # User-owned files belong in Vm-Users (which runs after the
                # users exist). Each entry is dispatched in JSON order so
                # operator-visible logging and any later side effects appear
                # in the same order the operator wrote them - per-entry
                # routing (not "all singles then all bulks") keeps that
                # contract while letting each bulk entry surface its
                # resolver errors (zero matches, target collisions) against
                # the specific files entry that triggered them, so the
                # operator knows which entry to fix.
                Write-Host "  [files] processing $(@($vmRef.files).Count) entry(s) ..."
                foreach ($entry in @($vmRef.files)) {
                    # Discriminator: presence of 'pattern' => bulk form,
                    # otherwise the existing single-file form. Step 2's
                    # schema guarantees the entry is well-formed for
                    # whichever branch matches.
                    if ($entry.PSObject.Properties['pattern']) {
                        $pattern   = $entry.pattern
                        $targetDir = $entry.targetDir
                        # Optional booleans default to $false when absent so
                        # the JSON round-trip in the schema stays a pure
                        # pass-through (default applied here, not in the
                        # validator).
                        $recurseProp = $entry.PSObject.Properties['recurse']
                        $recurse = if ($null -ne $recurseProp) {
                            [bool]$recurseProp.Value
                        } else { $false }
                        $preserveProp = $entry.PSObject.Properties['preserveRelativePath']
                        $preserveRelativePath = if ($null -ne $preserveProp) {
                            [bool]$preserveProp.Value
                        } else { $false }
                        Write-Host "  [files] bulk: $pattern -> $targetDir"
                        & $copyVmFilesByPattern -SshClient $sshClient `
                                                -Server $server `
                                                -Pattern $pattern `
                                                -TargetDir $targetDir `
                                                -Recurse:$recurse `
                                                -PreserveRelativePath:$preserveRelativePath
                    } else {
                        $singleEntries = @(
                            [PSCustomObject]@{ Source = $entry.source; Target = $entry.target }
                        )
                        Write-Host "  [files] single: $($entry.source) -> $($entry.target)"
                        & $copyVmFiles -SshClient $sshClient -Server $server -Entries $singleEntries
                    }
                }
                Write-Host "  [files] [OK] all copies complete." -ForegroundColor Green
            }
            if ($hasJdk) {
                # Pick install OR uninstall based on the flag; never both.
                # Installing-then-uninstalling in a single run is nonsense;
                # uninstalling-then-installing belongs in two explicit
                # provision runs so the operator's intent stays visible in
                # the JSON between them.
                $jdk = $vmRef.javaDevKit
                $uninstallProp = $jdk.PSObject.Properties['uninstall']
                if ($null -ne $uninstallProp -and $uninstallProp.Value -eq $true) {
                    & $uninstallJdk -SshClient $sshClient -Vm $vmRef
                } else {
                    & $installJdk -SshClient $sshClient -Server $server -Vm $vmRef
                }
            }
        }
        finally {
            if ($null -ne $sshClient) {
                if ($sshClient.IsConnected) { $sshClient.Disconnect() }
                $sshClient.Dispose()
            }
        }
    }.GetNewClosure()

    Invoke-WithVmFileServer -VmIpAddress $vmIp -ScriptBlock $postBlock
}
