BeforeAll {
    # Stub Hyper-V and networking cmdlets unavailable outside a Hyper-V host.
    function Get-VMSwitch     { param([string]$Name, $ErrorAction) }
    function New-VMSwitch     { param([string]$Name, $SwitchType)  }
    function Get-NetAdapter   { }
    function Get-NetIPAddress { param($InterfaceIndex, $AddressFamily, $ErrorAction) }
    function New-NetIPAddress { param($InterfaceIndex, $IPAddress, $PrefixLength)    }
    function Get-NetNat       { param([string]$Name, $ErrorAction) }
    function New-NetNat       { param([string]$Name, $InternalIPInterfaceAddressPrefix) }

    . "$PSScriptRoot\..\hyper-v\ubuntu\network\setup-network.ps1"

    # Factory for a minimal VM object. All VMs in a single batch must share
    # the same gateway and subnetMask (one Internal switch = one subnet).
    function New-TestVm {
        param(
            [string] $IpAddress = '192.168.1.10',
            [string] $Gateway   = '192.168.1.1',
            [string] $Subnet    = '24'
        )
        [PSCustomObject]@{
            vmName     = 'node-01'
            ipAddress  = $IpAddress
            gateway    = $Gateway
            subnetMask = $Subnet
        }
    }

    # Minimal host adapter object returned by Get-NetAdapter.
    # Name must match "vEthernet ($SwitchName)" - all tests use SwitchName 'VmLAN'.
    function New-TestAdapter {
        [PSCustomObject]@{
            InterfaceIndex = 5
            Name           = 'vEthernet (VmLAN)'
        }
    }

    # Sets up the mocks needed for all three idempotency paths to report
    # "already done" so the happy-path completes without side effects.
    function Initialize-AllPresentMocks {
        Mock Get-VMSwitch     { [PSCustomObject]@{ SwitchType = 'Internal' } }
        Mock Get-NetAdapter   { New-TestAdapter }
        Mock Get-NetIPAddress { [PSCustomObject]@{ IPAddress = '192.168.1.1' } }
        Mock Get-NetNat       { [PSCustomObject]@{ Name = 'VmLAN-NAT' } }
    }
}

Describe 'Invoke-NetworkSetup' {

    # ------------------------------------------------------------------
    Context 'gateway and subnet consistency guard' {
    # ------------------------------------------------------------------

        It 'throws when two VMs have different gateways' {
            $vms = @(
                (New-TestVm -Gateway '192.168.1.1' -Subnet '24'),
                (New-TestVm -Gateway '10.0.0.1'   -Subnet '24')
            )
            { Invoke-NetworkSetup -VmsToProvision $vms `
                                  -SwitchName 'VmLAN' -NatName 'VmLAN-NAT' } |
                Should -Throw
        }

        It 'throws when two VMs have different subnet masks' {
            $vms = @(
                (New-TestVm -Gateway '192.168.1.1' -Subnet '24'),
                (New-TestVm -Gateway '192.168.1.1' -Subnet '16')
            )
            { Invoke-NetworkSetup -VmsToProvision $vms `
                                  -SwitchName 'VmLAN' -NatName 'VmLAN-NAT' } |
                Should -Throw
        }

        It 'does not throw when all VMs share the same gateway and subnet' {
            Initialize-AllPresentMocks
            $vms = @(
                (New-TestVm -IpAddress '192.168.1.10' -Gateway '192.168.1.1' -Subnet '24'),
                (New-TestVm -IpAddress '192.168.1.11' -Gateway '192.168.1.1' -Subnet '24')
            )
            { Invoke-NetworkSetup -VmsToProvision $vms `
                                  -SwitchName 'VmLAN' -NatName 'VmLAN-NAT' } |
                Should -Not -Throw
        }
    }

    # ------------------------------------------------------------------
    Context 'NAT prefix calculation' {
    # ------------------------------------------------------------------
        # The function derives the network address by masking the gateway IP
        # with the CIDR subnet mask, then passes it to New-NetNat. These tests
        # verify the bitwise calculation produces the correct prefix string.

        It 'derives 192.168.1.0/24 from gateway 192.168.1.1/24' {
            Initialize-AllPresentMocks
            Mock Get-NetNat { }
            Mock New-NetNat { }

            Invoke-NetworkSetup -VmsToProvision @(New-TestVm) `
                                -SwitchName 'VmLAN' -NatName 'VmLAN-NAT'

            Should -Invoke New-NetNat -ParameterFilter {
                $InternalIPInterfaceAddressPrefix -eq '192.168.1.0/24'
            }
        }

        It 'derives 10.0.0.0/8 from gateway 10.1.2.3/8' {
            Mock Get-VMSwitch     { [PSCustomObject]@{ SwitchType = 'Internal' } }
            Mock Get-NetAdapter   { New-TestAdapter }
            Mock Get-NetIPAddress { [PSCustomObject]@{ IPAddress = '10.1.2.3' } }
            Mock Get-NetNat       { }
            Mock New-NetNat       { }

            $vm = New-TestVm -Gateway '10.1.2.3' -Subnet '8'
            Invoke-NetworkSetup -VmsToProvision @($vm) `
                                -SwitchName 'VmLAN' -NatName 'VmLAN-NAT'

            Should -Invoke New-NetNat -ParameterFilter {
                $InternalIPInterfaceAddressPrefix -eq '10.0.0.0/8'
            }
        }

        It 'derives 172.16.0.0/12 from gateway 172.31.255.254/12' {
            Mock Get-VMSwitch     { [PSCustomObject]@{ SwitchType = 'Internal' } }
            Mock Get-NetAdapter   { New-TestAdapter }
            Mock Get-NetIPAddress { [PSCustomObject]@{ IPAddress = '172.31.255.254' } }
            Mock Get-NetNat       { }
            Mock New-NetNat       { }

            $vm = New-TestVm -Gateway '172.31.255.254' -Subnet '12'
            Invoke-NetworkSetup -VmsToProvision @($vm) `
                                -SwitchName 'VmLAN' -NatName 'VmLAN-NAT'

            Should -Invoke New-NetNat -ParameterFilter {
                $InternalIPInterfaceAddressPrefix -eq '172.16.0.0/12'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'switch creation' {
    # ------------------------------------------------------------------

        It 'creates an Internal switch when none exists' {
            Mock Get-VMSwitch { }
            Mock New-VMSwitch { }
            Mock Get-NetAdapter   { New-TestAdapter }
            Mock Get-NetIPAddress { [PSCustomObject]@{ IPAddress = '192.168.1.1' } }
            Mock Get-NetNat       { [PSCustomObject]@{ Name = 'VmLAN-NAT' } }

            Invoke-NetworkSetup -VmsToProvision @(New-TestVm) `
                                -SwitchName 'VmLAN' -NatName 'VmLAN-NAT'

            Should -Invoke New-VMSwitch -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'VmLAN' -and $SwitchType -eq 'Internal'
            }
        }

        It 'skips switch creation when an Internal switch already exists' {
            Initialize-AllPresentMocks
            Mock New-VMSwitch { }

            Invoke-NetworkSetup -VmsToProvision @(New-TestVm) `
                                -SwitchName 'VmLAN' -NatName 'VmLAN-NAT'

            Should -Invoke New-VMSwitch -Times 0
        }

        It 'throws when a switch with the same name exists but is not Internal' {
            # An External switch exposes VMs on the physical network, breaking
            # the isolated internal LAN assumption this script requires.
            Mock Get-VMSwitch { [PSCustomObject]@{ SwitchType = 'External' } }
            Mock Get-NetAdapter   { New-TestAdapter }
            Mock Get-NetIPAddress { }
            Mock Get-NetNat       { }

            { Invoke-NetworkSetup -VmsToProvision @(New-TestVm) `
                                  -SwitchName 'VmLAN' -NatName 'VmLAN-NAT' } |
                Should -Throw
        }
    }

    # ------------------------------------------------------------------
    Context 'host vNIC IP assignment' {
    # ------------------------------------------------------------------

        It 'assigns the gateway IP when the vNIC does not have it yet' {
            Mock Get-VMSwitch     { [PSCustomObject]@{ SwitchType = 'Internal' } }
            Mock Get-NetAdapter   { New-TestAdapter }
            Mock Get-NetIPAddress { }    # no existing IP
            Mock New-NetIPAddress { }
            Mock Get-NetNat       { [PSCustomObject]@{ Name = 'VmLAN-NAT' } }

            Invoke-NetworkSetup -VmsToProvision @(New-TestVm) `
                                -SwitchName 'VmLAN' -NatName 'VmLAN-NAT'

            Should -Invoke New-NetIPAddress -Times 1 -Exactly -ParameterFilter {
                $IPAddress    -eq '192.168.1.1' -and
                $PrefixLength -eq 24
            }
        }

        It 'skips IP assignment when the gateway IP is already on the vNIC' {
            Initialize-AllPresentMocks
            Mock New-NetIPAddress { }

            Invoke-NetworkSetup -VmsToProvision @(New-TestVm) `
                                -SwitchName 'VmLAN' -NatName 'VmLAN-NAT'

            Should -Invoke New-NetIPAddress -Times 0
        }

        It 'throws when the host vNIC adapter is not found' {
            Mock Get-VMSwitch     { [PSCustomObject]@{ SwitchType = 'Internal' } }
            Mock Get-NetAdapter   { }    # vNIC not present
            Mock Get-NetIPAddress { }
            Mock Get-NetNat       { }

            { Invoke-NetworkSetup -VmsToProvision @(New-TestVm) `
                                  -SwitchName 'VmLAN' -NatName 'VmLAN-NAT' } |
                Should -Throw
        }
    }

    # ------------------------------------------------------------------
    Context 'NAT rule creation' {
    # ------------------------------------------------------------------

        It 'creates the NAT rule when it does not exist' {
            Mock Get-VMSwitch     { [PSCustomObject]@{ SwitchType = 'Internal' } }
            Mock Get-NetAdapter   { New-TestAdapter }
            Mock Get-NetIPAddress { [PSCustomObject]@{ IPAddress = '192.168.1.1' } }
            Mock Get-NetNat       { }    # rule absent
            Mock New-NetNat       { }

            Invoke-NetworkSetup -VmsToProvision @(New-TestVm) `
                                -SwitchName 'VmLAN' -NatName 'VmLAN-NAT'

            Should -Invoke New-NetNat -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'VmLAN-NAT'
            }
        }

        It 'skips NAT rule creation when it already exists' {
            Initialize-AllPresentMocks
            Mock New-NetNat { }

            Invoke-NetworkSetup -VmsToProvision @(New-TestVm) `
                                -SwitchName 'VmLAN' -NatName 'VmLAN-NAT'

            Should -Invoke New-NetNat -Times 0
        }
    }
}
