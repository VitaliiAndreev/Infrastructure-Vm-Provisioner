<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 after acquire-disk-image.ps1 and generate-seed-iso.ps1
    have run (Vm._vhdxPath and Vm._seedIsoPath must be set).
#>

# ---------------------------------------------------------------------------
# Invoke-VmCreation
#   Creates a Hyper-V Gen 2 VM, boots it, waits for SSH to become reachable,
#   then removes the seed ISO.
#
#   Steps performed:
#     1. Create the VM with Gen 2, static RAM, and the per-VM VHDX.
#     2. Set CPU count.
#     3. Configure Secure Boot with the UEFI CA template (required for
#        Ubuntu's shim bootloader).
#     4. Attach the seed ISO as a DVD drive (cloud-init reads it on boot).
#     5. Connect the network adapter to the shared Internal switch.
#     6. Start the VM.
#     7. Poll TCP port 22 until cloud-init finishes (SSH reachable = done).
#     8. Detach and delete the seed ISO in a finally block so it is always
#        removed regardless of SSH success or timeout (it contains the
#        plaintext password).
# ---------------------------------------------------------------------------
function Invoke-VmCreation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm,

        [Parameter(Mandatory)]
        [string] $SwitchName
    )

    Write-Host ""
    Write-Host "--- Creating VM: $($Vm.vmName) ---" -ForegroundColor Cyan

    # -Path directs Hyper-V to store the VM configuration files (.vmcx etc.)
    # in vmConfigPath, keeping them co-located with the seed ISO and separate
    # from the OS disk in vhdPath.
    # MemoryStartupBytes is static RAM - dynamic memory is not used because
    # runner workloads benefit from a predictable allocation and dynamic
    # memory adds balloon-driver overhead inside the guest.
    Write-Host "  Creating VM (Gen 2, $($Vm.cpuCount) vCPU, $($Vm.ramGB) GB RAM) ..."
    New-VM -Name              $Vm.vmName `
           -Generation        2 `
           -MemoryStartupBytes ([int64]$Vm.ramGB * 1GB) `
           -VHDPath           $Vm._vhdxPath `
           -Path              $Vm.vmConfigPath | Out-Null

    # ------------------------------------------------------------------
    # Verify New-VM produced a VM in the Off state before proceeding.
    # If the VHDX was locked by a still-running previous instance, New-VM
    # may have silently failed while $ErrorActionPreference = 'Stop' did
    # not fire (Hyper-V can surface some failures as warnings). A host
    # auto-start policy could also start the VM between creation and here.
    # Both cases would cause Set-VMFirmware to fail with "cannot modify
    # firmware while VM is running". We catch both by checking state now
    # and throwing a clear message rather than a confusing firmware error.
    # ------------------------------------------------------------------
    $createdVmState = (Get-VM -Name $Vm.vmName -ErrorAction Stop).State
    if ($createdVmState -ne 'Off') {
        throw (
            "VM '$($Vm.vmName)' is in state '$createdVmState' immediately " +
            "after creation - expected 'Off'. A previous provisioning run " +
            "may have left it running. Stop or remove the VM manually and " +
            "re-run, or delete the per-VM disk to force a fresh provision."
        )
    }

    Set-VMProcessor -VMName $Vm.vmName -Count $Vm.cpuCount

    # ------------------------------------------------------------------
    # Secure Boot
    # The default template 'MicrosoftWindows' rejects Ubuntu's shim
    # bootloader. 'MicrosoftUEFICertificateAuthority' trusts third-party
    # UEFI bootloaders signed by Microsoft, which Ubuntu's shim is.
    # Setting the first boot device to the VHDX avoids a PXE network-boot
    # attempt that would add a timeout before every boot.
    # ------------------------------------------------------------------
    $osDisk = Get-VMHardDiskDrive -VMName $Vm.vmName | Select-Object -First 1
    Set-VMFirmware -VMName              $Vm.vmName `
                   -EnableSecureBoot    On `
                   -SecureBootTemplate  'MicrosoftUEFICertificateAuthority' `
                   -FirstBootDevice     $osDisk

    # ------------------------------------------------------------------
    # Seed ISO
    # Attached as a DVD drive. cloud-init does not require the ISO to be
    # bootable - the NoCloud datasource scans all block devices for a
    # volume labelled 'cidata'. The DVD drive sits below the VHDX in the
    # boot order and is never attempted as a boot source.
    # ------------------------------------------------------------------
    Add-VMDvdDrive -VMName $Vm.vmName -Path $Vm._seedIsoPath

    # ------------------------------------------------------------------
    # Network
    # ------------------------------------------------------------------
    Connect-VMNetworkAdapter -VMName     $Vm.vmName `
                             -Name       'Network Adapter' `
                             -SwitchName $SwitchName

    Write-Host "  Starting VM ..."
    Start-VM -VMName $Vm.vmName
    Write-Host "  [OK] VM started." -ForegroundColor Green

    # ------------------------------------------------------------------
    # Poll port 22 until cloud-init finishes, then delete seed ISO.
    #
    # cloud-init runs on first boot: applies netplan (static IP), installs
    # openssh-server, and creates the OS user. SSH becoming reachable is
    # the reliable completion signal - it requires all of the above to have
    # succeeded.
    #
    # The seed ISO is deleted in a finally block so it is removed regardless
    # of whether SSH succeeds or times out. cloud-init reads all seed files
    # into /var/lib/cloud/ at the very start of its run; by the time any
    # timeout fires the ISO is no longer read and is safe to delete.
    # Leaving it on disk is never acceptable - it contains the plaintext
    # password.
    #
    # [System.Net.Sockets.TcpClient] is used instead of Test-NetConnection
    # because Test-NetConnection's output format differs between PS 5.1 and
    # PS 7; the .NET API is consistent across both versions.
    # ------------------------------------------------------------------
    $timeoutMinutes      = 10
    $pollIntervalSeconds = 10
    $deadline            = (Get-Date).AddMinutes($timeoutMinutes)
    $sshReady            = $false

    try {
        Write-Host "  Polling SSH on $($Vm.vmName) ..." -NoNewline

        while ((Get-Date) -lt $deadline) {
            # Abort early if the VM is no longer running - no point waiting
            # out the full timeout if it has already crashed or shut down.
            $vmState = (Get-VM -Name $Vm.vmName).State
            if ($vmState -ne 'Running') {
                Write-Host ''
                throw (
                    "VM '$($Vm.vmName)' stopped unexpectedly " +
                    "(state: $vmState). Check the Hyper-V console."
                )
            }

            $tcpClient = $null
            try {
                $tcpClient = [System.Net.Sockets.TcpClient]::new()
                if ($tcpClient.ConnectAsync($Vm.ipAddress, 22).Wait(2000)) {
                    $sshReady = $true
                    break
                }
            }
            catch { }
            finally {
                if ($null -ne $tcpClient) { $tcpClient.Dispose() }
            }
            Write-Host '.' -NoNewline
            Start-Sleep -Seconds $pollIntervalSeconds
        }

        Write-Host ''

        if (-not $sshReady) {
            throw (
                "SSH on '$($Vm.vmName)' did not become reachable within " +
                "$timeoutMinutes minutes. Check the Hyper-V console for " +
                "boot errors."
            )
        }

        Write-Host "  [OK] SSH reachable on $($Vm.vmName)." -ForegroundColor Green
    }
    finally {
        # Remove-VMDvdDrive detaches before Remove-Item deletes - deleting a
        # file still attached leaves a broken DVD drive reference in the VM.
        $dvdDrive = Get-VMDvdDrive -VMName $Vm.vmName |
            Where-Object { $_.Path -eq $Vm._seedIsoPath }
        if ($null -ne $dvdDrive) {
            Remove-VMDvdDrive -VMName            $Vm.vmName `
                              -ControllerNumber   $dvdDrive.ControllerNumber `
                              -ControllerLocation $dvdDrive.ControllerLocation
        }
        if (Test-Path $Vm._seedIsoPath) {
            Remove-Item -Path $Vm._seedIsoPath -Force
            Write-Host "  [OK] Seed ISO removed." -ForegroundColor Green
        }
    }

    Write-Host "  [OK] $($Vm.vmName) ready." -ForegroundColor Green
    Write-Host "    Connect: ssh $($Vm.username)@$($Vm.vmName)" `
        -ForegroundColor Cyan
}
