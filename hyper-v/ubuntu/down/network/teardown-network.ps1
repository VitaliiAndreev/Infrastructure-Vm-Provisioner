<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    deprovision.ps1.
#>

# ---------------------------------------------------------------------------
# Invoke-NetworkTeardown
#   Removes the shared NAT rule, host vNIC IP, and Internal switch created by
#   setup-network.ps1 - but only when no VMs remain connected to the switch.
#
#   Steps performed:
#     1. Count adapters still connected to the switch. If any remain, log and
#        return - removing the switch while VMs use it would drop their network
#        access. The caller is responsible for removing all VMs first.
#     2. Remove the NAT rule. Absence is not an error - the operator may have
#        removed it manually, or a previous partial run may have already deleted
#        it.
#     3. Remove the host vNIC IP assignment. Same absence tolerance.
#     4. Remove the virtual switch. Removing it also deletes the
#        'vEthernet ($SwitchName)' host adapter. Same absence tolerance.
# ---------------------------------------------------------------------------
function Invoke-NetworkTeardown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $SwitchName,

        # Gateway IP assigned to the host vNIC - the address to remove.
        [Parameter(Mandatory)]
        [string] $Gateway,

        [Parameter(Mandatory)]
        [string] $NatName
    )

    Write-Host ""
    Write-Host "--- Network teardown: $SwitchName ---" -ForegroundColor Cyan

    # ------------------------------------------------------------------
    # Guard: do not remove shared network objects while VMs are still
    # attached. Get-VMNetworkAdapter -All lists adapters for all VMs;
    # filtering by SwitchName identifies those still on this switch.
    # ------------------------------------------------------------------
    $remainingAdapters = @(
        Get-VMNetworkAdapter -All -ErrorAction SilentlyContinue |
            Where-Object { $_.SwitchName -eq $SwitchName }
    )

    if ($remainingAdapters.Count -gt 0) {
        Write-Host (
            "  $($remainingAdapters.Count) VM(s) still connected to '$SwitchName' " +
            "- skipping network teardown."
        ) -ForegroundColor Yellow
        return
    }

    # ------------------------------------------------------------------
    # NAT rule removal
    # ------------------------------------------------------------------
    $existingNat = Get-NetNat -Name $NatName -ErrorAction SilentlyContinue
    if ($null -ne $existingNat) {
        Write-Host "  Removing NAT rule '$NatName' ..."
        Remove-NetNat -Name $NatName -Confirm:$false
        Write-Host "  [OK] NAT rule removed." -ForegroundColor Green
    }
    else {
        Write-Host "  NAT rule '$NatName' not found - skipping." -ForegroundColor Yellow
    }

    # ------------------------------------------------------------------
    # Host vNIC IP removal
    # ------------------------------------------------------------------
    $existingIp = Get-NetIPAddress -IPAddress $Gateway -ErrorAction SilentlyContinue
    if ($null -ne $existingIp) {
        Write-Host "  Removing host vNIC IP $Gateway ..."
        Remove-NetIPAddress -IPAddress $Gateway -Confirm:$false
        Write-Host "  [OK] Host vNIC IP removed." -ForegroundColor Green
    }
    else {
        Write-Host "  Host vNIC IP $Gateway not found - skipping." -ForegroundColor Yellow
    }

    # ------------------------------------------------------------------
    # Virtual switch removal
    # Removing the switch also deletes the vEthernet ($SwitchName) host
    # adapter that was created alongside it.
    # ------------------------------------------------------------------
    $existingSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
    if ($null -ne $existingSwitch) {
        Write-Host "  Removing virtual switch '$SwitchName' ..."
        Remove-VMSwitch -Name $SwitchName -Force
        Write-Host "  [OK] Virtual switch removed." -ForegroundColor Green
    }
    else {
        Write-Host "  Virtual switch '$SwitchName' not found - skipping." -ForegroundColor Yellow
    }

    Write-Host "  [OK] Network teardown complete." -ForegroundColor Green
}
