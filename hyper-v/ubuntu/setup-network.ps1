<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1.
#>

# ---------------------------------------------------------------------------
# Invoke-NetworkSetup
#   Creates the shared Internal switch, assigns the gateway IP to the host
#   vNIC, and creates the NAT rule that routes VM traffic to the internet.
#   All three operations are idempotent - re-running is safe.
#
#   All VMs share one Internal switch ($SwitchName). An Internal switch
#   creates a virtual NIC on the host (vEthernet ($SwitchName)) through
#   which the host can SSH into the VMs. VMs cannot reach the physical
#   network directly, but the NetNat rule routes their outbound traffic
#   through the host's physical NIC - required for cloud-init's package
#   installs on first boot.
#
#   Gateway and subnet are derived from the first VM's config. All VMs must
#   share the same gateway and subnetMask: a single Internal switch maps to
#   one subnet, so mixing subnets would give some VMs a wrong default route.
#   A pre-flight check enforces this constraint.
# ---------------------------------------------------------------------------
function Invoke-NetworkSetup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $VmsToProvision,

        [Parameter(Mandatory)]
        [string] $SwitchName,

        [Parameter(Mandatory)]
        [string] $NatName
    )

    # ------------------------------------------------------------------
    # Enforce gateway/subnet consistency across all queued VMs.
    # ------------------------------------------------------------------
    $firstVm = $VmsToProvision[0]

    foreach ($vm in $VmsToProvision) {
        if ($vm.gateway    -ne $firstVm.gateway -or
            $vm.subnetMask -ne $firstVm.subnetMask) {
            throw (
                "All VM definitions must share the same gateway and subnetMask " +
                "- they will all be attached to the same Internal switch. " +
                "Conflicting entries: '$($firstVm.vmName)' " +
                "($($firstVm.gateway)/$($firstVm.subnetMask)) vs " +
                "'$($vm.vmName)' ($($vm.gateway)/$($vm.subnetMask))."
            )
        }
    }

    $gatewayIp    = $firstVm.gateway
    $prefixLength = [int]$firstVm.subnetMask

    # Derive the network address for the NAT prefix (e.g. 192.168.1.1/24
    # -> 192.168.1.0/24). Each byte of the gateway is masked with the
    # corresponding byte of the subnet mask built from the CIDR prefix.
    $gatewayBytes = [System.Net.IPAddress]::Parse($gatewayIp).GetAddressBytes()
    $maskBits     = '1' * $prefixLength + '0' * (32 - $prefixLength)
    $networkBytes = [byte[]](
        ([Convert]::ToByte($maskBits.Substring( 0, 8), 2) -band $gatewayBytes[0]),
        ([Convert]::ToByte($maskBits.Substring( 8, 8), 2) -band $gatewayBytes[1]),
        ([Convert]::ToByte($maskBits.Substring(16, 8), 2) -band $gatewayBytes[2]),
        ([Convert]::ToByte($maskBits.Substring(24, 8), 2) -band $gatewayBytes[3])
    )
    $natPrefix = "$([System.Net.IPAddress]::new($networkBytes))/$prefixLength"

    Write-Host ""
    Write-Host "--- Virtual switch: $SwitchName ---" -ForegroundColor Cyan

    # ------------------------------------------------------------------
    # Switch creation (idempotent)
    # ------------------------------------------------------------------
    $existingSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
    if ($null -ne $existingSwitch) {
        # Guard against a pre-existing switch with the same name but the
        # wrong type. An External switch would expose VMs directly on the
        # physical network rather than the isolated internal LAN this
        # script expects.
        if ($existingSwitch.SwitchType -ne 'Internal') {
            throw (
                "A switch named '$SwitchName' already exists but is type " +
                "'$($existingSwitch.SwitchType)', expected 'Internal'. " +
                "Rename or remove it before running this script."
            )
        }
        Write-Host "  Switch '$SwitchName' already exists - skipping." `
            -ForegroundColor Green
    }
    else {
        Write-Host "  Creating Internal switch '$SwitchName' ..."
        New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
        Write-Host "  ✓ Switch created." -ForegroundColor Green
    }

    # ------------------------------------------------------------------
    # Host vNIC IP assignment (idempotent)
    # After New-VMSwitch, Windows creates a host adapter named
    # 'vEthernet ($SwitchName)'. Assigning the gateway IP to it puts the
    # host on the same subnet as the VMs, enabling SSH from the host.
    # ------------------------------------------------------------------
    $hostAdapter = Get-NetAdapter |
        Where-Object { $_.Name -eq "vEthernet ($SwitchName)" }
    if ($null -eq $hostAdapter) {
        throw "Host virtual NIC 'vEthernet ($SwitchName)' not found."
    }

    $existingIp = Get-NetIPAddress `
        -InterfaceIndex $hostAdapter.InterfaceIndex `
        -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $gatewayIp }

    if ($null -ne $existingIp) {
        Write-Host "  Host vNIC already has IP $gatewayIp - skipping." `
            -ForegroundColor Green
    }
    else {
        Write-Host "  Assigning $gatewayIp/$prefixLength to host vNIC ..."
        New-NetIPAddress `
            -InterfaceIndex $hostAdapter.InterfaceIndex `
            -IPAddress      $gatewayIp `
            -PrefixLength   $prefixLength | Out-Null
        Write-Host "  ✓ Host vNIC configured." -ForegroundColor Green
    }

    # ------------------------------------------------------------------
    # NAT rule (idempotent)
    # Routes VM traffic out through the host's physical NIC so VMs can
    # reach the internet. Required for cloud-init package installs.
    # ------------------------------------------------------------------
    $existingNat = Get-NetNat -Name $NatName -ErrorAction SilentlyContinue
    if ($null -ne $existingNat) {
        Write-Host "  NAT rule '$NatName' already exists - skipping." `
            -ForegroundColor Green
    }
    else {
        Write-Host "  Creating NAT rule for $natPrefix ..."
        New-NetNat -Name $NatName `
                   -InternalIPInterfaceAddressPrefix $natPrefix | Out-Null
        Write-Host "  ✓ NAT rule created ($natPrefix)." -ForegroundColor Green
    }
}
