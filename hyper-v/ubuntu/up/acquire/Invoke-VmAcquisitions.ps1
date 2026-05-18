<#
.NOTES
    Do not run this file directly. Dot-sourced by provision.ps1 after the
    per-software acquirer files are loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-VmAcquisitions
#   Per-VM host-side acquisition orchestrator. Inspects the VM definition
#   and dispatches to each per-software acquirer whose opt-in field is set.
#   Self-skips silently when no opt-in fields apply.
#
#   The acquisition layer has no shared transport to amortize (each
#   acquirer is just "fetch X to host cache, attach $vm._xPath"). The
#   orchestrator exists purely to keep provision.ps1's per-VM loop a
#   one-liner as more acquirers are added, so the high-level provisioning
#   sequence stays readable.
#
#   Mirrors Invoke-VmPostProvisioning's "one orchestrator + N step
#   functions" shape on the post-VM side. Each acquirer is self-contained
#   and may not depend on another acquirer's output.
# ---------------------------------------------------------------------------

function Invoke-VmAcquisitions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    # Skip JDK acquisition on the uninstall path - no tarball is needed
    # to remove an install, so we avoid an unnecessary Adoptium API call
    # on a cache miss. The host cache is shared across VMs and stays
    # untouched.
    if ($Vm.PSObject.Properties['javaDevKit'] -and
        -not ($Vm.javaDevKit.PSObject.Properties['uninstall'] -and $Vm.javaDevKit.uninstall)) {
        Invoke-JdkAcquisition -Vm $Vm
    }
}
