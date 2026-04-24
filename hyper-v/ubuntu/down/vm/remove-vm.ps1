<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    deprovision.ps1.
#>

# ---------------------------------------------------------------------------
# Invoke-VmRemoval
#   Stops and deletes a Hyper-V VM, then removes its VHDX, seed ISO, and
#   VM configuration directory.
#
#   Steps performed:
#     1. Check whether the VM exists in Hyper-V.
#        - If present: Stop (when running), then Remove-VM.
#        - If absent: skip Hyper-V teardown (idempotent re-run after partial
#          failure - VM may have been removed but file cleanup did not finish).
#     2. Delete the per-VM VHDX with a retry loop.
#        Windows VMMS releases its handle on the VHDX asynchronously after
#        Remove-VM returns. Immediate deletion would throw IOException. Up to
#        5 attempts at 2-second intervals; throws on exhaustion identifying
#        the locked path so the operator can re-run when the handle is freed.
#     3. Delete the seed ISO if present. Absence is not an error - provision.ps1
#        removes it after first boot, so it is routinely absent.
#     4. Delete the VM configuration directory with the same retry loop as the
#        VHDX (Hyper-V config files are also held by VMMS until it flushes).
# ---------------------------------------------------------------------------
function Invoke-VmRemoval {
    [CmdletBinding()]
    param(
        # VM config object as produced by ConvertFrom-VmConfigJson.
        [Parameter(Mandatory)]
        [object] $Vm
    )

    Write-Host ""
    Write-Host "--- Removing VM: $($Vm.vmName) ---" -ForegroundColor Cyan

    # ------------------------------------------------------------------
    # Step 1 - Hyper-V teardown
    # ------------------------------------------------------------------
    $existingVm = Get-VM -Name $Vm.vmName -ErrorAction SilentlyContinue
    if ($null -ne $existingVm) {
        if ($existingVm.State -ne 'Off') {
            Write-Host "  Stopping VM ..."
            Stop-VM -Name $Vm.vmName -Force
        }
        Write-Host "  Removing VM from Hyper-V ..."
        Remove-VM -Name $Vm.vmName -Force
        Write-Host "  [OK] VM removed from Hyper-V." -ForegroundColor Green
    }
    else {
        Write-Host "  VM not found in Hyper-V - skipping Hyper-V teardown." `
            -ForegroundColor Yellow
    }

    # ------------------------------------------------------------------
    # Step 2 - VHDX deletion (with VMMS handle-release retry)
    # ------------------------------------------------------------------
    $vhdxPath = Join-Path $Vm.vhdPath "$($Vm.vmName).vhdx"
    if (Test-Path $vhdxPath) {
        Remove-ItemWithRetry -Path $vhdxPath
        Write-Host "  [OK] VHDX deleted." -ForegroundColor Green
    }

    # ------------------------------------------------------------------
    # Step 3 - Seed ISO deletion (no retry - not held by VMMS)
    # ------------------------------------------------------------------
    $seedIsoPath = Join-Path $Vm.vmConfigPath "$($Vm.vmName)-seed.iso"
    if (Test-Path $seedIsoPath) {
        Remove-Item -Path $seedIsoPath -Force
        Write-Host "  [OK] Seed ISO deleted." -ForegroundColor Green
    }

    # ------------------------------------------------------------------
    # Step 4 - VM configuration directory deletion (with retry)
    # ------------------------------------------------------------------
    $vmConfigDir = Join-Path $Vm.vmConfigPath $Vm.vmName
    if (Test-Path $vmConfigDir) {
        Remove-ItemWithRetry -Path $vmConfigDir
        Write-Host "  [OK] VM config directory deleted." -ForegroundColor Green
    }

    Write-Host "  [OK] $($Vm.vmName) removed." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Remove-ItemWithRetry
#   Deletes a file or directory, retrying on IOException up to $MaxAttempts
#   times with $IntervalSeconds between each attempt.
#
#   VMMS (Virtual Machine Management Service) releases its handles on VHDX
#   and config directory files asynchronously after Remove-VM returns. An
#   immediate Remove-Item would throw IOException: The process cannot access
#   the file. Retrying allows the handle to be freed before giving up.
# ---------------------------------------------------------------------------
function Remove-ItemWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [int] $MaxAttempts    = 5,
        [int] $IntervalSeconds = 2
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            return
        }
        catch [System.IO.IOException] {
            if ($attempt -lt $MaxAttempts) {
                Write-Host ("  File still locked, retrying in $IntervalSeconds s " +
                    "($attempt/$MaxAttempts) ...")
                Start-Sleep -Seconds $IntervalSeconds
            }
        }
    }

    throw (
        "Could not delete '$Path' after $MaxAttempts attempts - " +
        "VMMS may still hold a handle. Re-run deprovision.ps1 after a " +
        "few seconds to retry the file deletion."
    )
}
