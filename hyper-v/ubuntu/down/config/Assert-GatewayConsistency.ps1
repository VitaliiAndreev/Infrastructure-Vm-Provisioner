<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    deprovision.ps1 (and any future entry point that needs the gateway IP).
#>

# ---------------------------------------------------------------------------
# Assert-GatewayConsistency
#   Validates that all VM definitions share the same gateway, then returns
#   the common gateway IP.
#
#   All VMs provisioned by this tooling are attached to the same VmLAN
#   Internal switch, which maps to a single subnet. Mixed gateways would
#   mean VMs on different subnets sharing one switch - an invalid config
#   that would give some VMs an unreachable default route.
#
#   Throws if any VM's gateway differs from the first VM's gateway.
#   Returns the shared gateway IP on success.
# ---------------------------------------------------------------------------
function Assert-GatewayConsistency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $VmDefs
    )

    $firstVm = $VmDefs[0]
    foreach ($vm in $VmDefs) {
        if ($vm.gateway -ne $firstVm.gateway) {
            throw (
                "All VM definitions must share the same gateway - they must " +
                "all be on the same VmLAN switch. Conflicting entries: " +
                "'$($firstVm.vmName)' ($($firstVm.gateway)) vs " +
                "'$($vm.vmName)' ($($vm.gateway))."
            )
        }
    }

    return $firstVm.gateway
}
