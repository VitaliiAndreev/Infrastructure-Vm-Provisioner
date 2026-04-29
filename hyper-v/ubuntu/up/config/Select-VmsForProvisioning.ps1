<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1.
#>

# ---------------------------------------------------------------------------
# Select-VmsForProvisioning
#   Runs pre-flight checks on each VM definition and outputs only those
#   that should be provisioned. Two checks run per VM, in order:
#
#   a) VM existence - if a Hyper-V VM with the same vmName already exists,
#      the entry is skipped. Re-creating an existing VM risks data loss.
#
#   b) IP conflict  - if ipAddress responds to a ping, the entry is skipped.
#      Assigning a static IP already in use causes network conflicts that
#      are difficult to diagnose from inside the VM.
#
#   VMs that pass both checks are written to the pipeline. Collect with
#   @(Select-VmsForProvisioning ...) to guarantee an array when one VM
#   is returned.
# ---------------------------------------------------------------------------
function Select-VmsForProvisioning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $VmDefs
    )

    foreach ($vm in $VmDefs) {
        Write-Host ""
        Write-Host "--- Checking: $($vm.vmName) ---" -ForegroundColor Cyan

        # ------------------------------------------------------------------
        # Check a) VM existence
        # Get-VM throws on a missing name without -ErrorAction;
        # SilentlyContinue returns $null instead.
        # ------------------------------------------------------------------
        $existing = Get-VM -Name $vm.vmName -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            Write-Warning "VM '$($vm.vmName)' already exists in Hyper-V - skipping."
            continue
        }

        # ------------------------------------------------------------------
        # Check b) IP conflict
        # The existing VM owns this IP, so pinging it is expected to succeed
        # and is not a conflict. The IP check is skipped when check a) fires.
        # ------------------------------------------------------------------
        if (Test-IpAddressInUse -IpAddress $vm.ipAddress) {
            Write-Warning (
                "IP $($vm.ipAddress) is already in use on the network - " +
                "skipping '$($vm.vmName)' to avoid a static-IP conflict."
            )
            continue
        }

        Write-Host "[OK] '$($vm.vmName)' passed all checks - queued for provisioning." `
            -ForegroundColor Green
        $vm
    }
}

# ---------------------------------------------------------------------------
# Test-IpAddressInUse
#   Returns $true if the IP address responds to a ping within 1000 ms.
#
#   [System.Net.NetworkInformation.Ping] is used instead of Test-Connection
#   for predictability: Test-Connection returns rich objects and requires
#   -Count 1; the .NET API is a direct call with a clear return value.
# ---------------------------------------------------------------------------
function Test-IpAddressInUse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $IpAddress
    )

    $ping   = [System.Net.NetworkInformation.Ping]::new()
    $result = $ping.Send($IpAddress, 1000)
    $ping.Dispose()

    return $result.Status -eq [System.Net.NetworkInformation.IPStatus]::Success
}
