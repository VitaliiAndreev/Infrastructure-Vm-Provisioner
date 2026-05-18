<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1.
#>

# ---------------------------------------------------------------------------
# Select-VmsForProvisioning
#   Runs pre-flight checks on each VM definition and outputs only those that
#   should be touched by the pipeline. Each returned VM is annotated with
#   a '_state' note property:
#
#     'new'      - no Hyper-V VM with this name exists AND the IP does not
#                  respond. The full destructive pipeline (disk acquisition,
#                  seed-ISO generation, VM creation) plus host-side
#                  acquisitions and post-provisioning all run for this VM.
#
#     'existing' - a Hyper-V VM with this name exists AND the IP responds.
#                  Destructive steps are skipped; only the idempotent
#                  additive steps (host-side acquisitions, post-provisioning)
#                  run. Lets the operator add javaDevKit / files / etc. to
#                  an already-provisioned VM and re-run provision.ps1.
#
#   VMs that match no clean classification are dropped with a warning:
#     - VM does not exist but IP responds: IP conflict with some other
#       machine on the subnet. Creating would assign a duplicate IP.
#     - VM exists but IP does not respond: VM is powered off or its
#       network is broken. Post-provisioning would fail at the SSH open
#       with an opaque error - safer to surface the state up front.
#
#   Callers must collect with ConvertTo-Array to guarantee an array when a
#   single VM is returned.
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

        # Get-VM throws on a missing name without -ErrorAction;
        # SilentlyContinue returns $null instead.
        $existing  = $null -ne (Get-VM -Name $vm.vmName -ErrorAction SilentlyContinue)
        $ipInUse   = Test-IpAddressInUse -IpAddress $vm.ipAddress

        # Decision matrix. The four cases are exhaustive and mutually exclusive.
        if (-not $existing -and -not $ipInUse) {
            $vm | Add-Member -MemberType NoteProperty -Name '_state' -Value 'new' -Force
            Write-Host "[OK] '$($vm.vmName)' is new - full pipeline." `
                -ForegroundColor Green
            $vm
        }
        elseif ($existing -and $ipInUse) {
            $vm | Add-Member -MemberType NoteProperty -Name '_state' -Value 'existing' -Force
            Write-Host "[OK] '$($vm.vmName)' exists and is reachable - reconcile (additive steps only)." `
                -ForegroundColor Green
            $vm
        }
        elseif (-not $existing -and $ipInUse) {
            Write-Warning (
                "IP $($vm.ipAddress) is in use but no Hyper-V VM named " +
                "'$($vm.vmName)' exists - skipping to avoid a static-IP " +
                "conflict with an unknown machine."
            )
        }
        else {
            # $existing -and -not $ipInUse
            Write-Warning (
                "Hyper-V VM '$($vm.vmName)' exists but its IP " +
                "$($vm.ipAddress) does not respond - skipping. Start the " +
                "VM (and verify its network) before re-running so " +
                "post-provisioning has somewhere to SSH."
            )
        }
    }
}

# ---------------------------------------------------------------------------
# Test-IpAddressInUse
#   Returns $true if the IP address responds to either an ICMP ping (within
#   1000 ms) or a TCP probe on the SSH port. Either signal is sufficient
#   because some VMs (e.g. Ubuntu with a restrictive host firewall) drop
#   ICMP but still serve SSH, and conversely a squatter on the subnet may
#   answer ping without exposing SSH. ORing both probes catches both
#   classes of "the IP is taken".
#
#   [System.Net.NetworkInformation.Ping] is used instead of Test-Connection
#   for predictability: Test-Connection returns rich objects and requires
#   -Count 1; the .NET API is a direct call with a clear return value.
#   SSH reachability is delegated to Test-VmSshPort (Infrastructure.HyperV)
#   so the pre-flight and the downstream gate use the same probe.
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

    if ($result.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
        return $true
    }

    # ICMP silent - fall back to an SSH-port TCP probe so VMs that block
    # ping but accept SSH are still recognised as reachable.
    return [bool] (Test-VmSshPort -IpAddress $IpAddress -Port 22)
}
