BeforeAll {
    # Stub all Hyper-V and networking cmdlets unavailable outside a Hyper-V host.
    function Get-VMNetworkAdapter { param([switch]$All, $ErrorAction) }
    function Get-NetNat           { param([string]$Name, $ErrorAction) }
    function Remove-NetNat        { param([string]$Name, $Confirm) }
    function Get-NetIPAddress     { param($IPAddress, $ErrorAction) }
    function Remove-NetIPAddress  { param($IPAddress, $Confirm) }
    function Get-VMSwitch         { param([string]$Name, $ErrorAction) }
    function Remove-VMSwitch      { param([string]$Name, [switch]$Force) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\down\network\teardown-network.ps1"

    # Sets up all stubs so the full teardown path runs without error.
    # All Get-* return absent (nothing to remove) and Remove-* are no-ops.
    function Initialize-AllAbsentMocks {
        Mock Get-VMNetworkAdapter { }    # no VMs connected
        Mock Get-NetNat           { }    # NAT rule absent
        Mock Remove-NetNat        { }
        Mock Get-NetIPAddress     { }    # host IP absent
        Mock Remove-NetIPAddress  { }
        Mock Get-VMSwitch         { }    # switch absent
        Mock Remove-VMSwitch      { }
    }

    # Sets up all stubs so each object exists and requires removal.
    function Initialize-AllPresentMocks {
        Mock Get-VMNetworkAdapter { }    # no VMs connected - teardown proceeds
        Mock Get-NetNat           { [PSCustomObject]@{ Name = 'VmLAN-NAT' } }
        Mock Remove-NetNat        { }
        Mock Get-NetIPAddress     { [PSCustomObject]@{ IPAddress = '192.168.1.1' } }
        Mock Remove-NetIPAddress  { }
        Mock Get-VMSwitch         { [PSCustomObject]@{ Name = 'VmLAN' } }
        Mock Remove-VMSwitch      { }
    }
}

Describe 'Invoke-NetworkTeardown' {

    # ------------------------------------------------------------------
    Context 'VMs still connected - teardown skipped' {
    # ------------------------------------------------------------------
        # Removing shared network objects while VMs are still attached
        # would cut their network access. The function must bail out and
        # leave everything intact when Get-VMNetworkAdapter reports that
        # adapters are still connected to the switch.

        It 'does not remove NAT, host IP, or switch when VMs are still connected' {
            Initialize-AllPresentMocks
            # Return an adapter connected to the switch so the guard fires.
            Mock Get-VMNetworkAdapter {
                [PSCustomObject]@{ SwitchName = 'VmLAN'; VMName = 'node-01' }
            }

            Invoke-NetworkTeardown -SwitchName 'VmLAN' `
                                   -Gateway   '192.168.1.1' `
                                   -NatName   'VmLAN-NAT'

            Should -Invoke Remove-NetNat       -Times 0
            Should -Invoke Remove-NetIPAddress -Times 0
            Should -Invoke Remove-VMSwitch     -Times 0
        }

        It 'does not skip teardown when a VM is connected to a different switch' {
            # The guard filters by SwitchName. An adapter on a different switch
            # must not be counted, otherwise teardown would be skipped even
            # though no VMs are attached to the target switch.
            Initialize-AllPresentMocks
            Mock Get-VMNetworkAdapter {
                [PSCustomObject]@{ SwitchName = 'OtherSwitch'; VMName = 'node-99' }
            }

            Invoke-NetworkTeardown -SwitchName 'VmLAN' `
                                   -Gateway   '192.168.1.1' `
                                   -NatName   'VmLAN-NAT'

            Should -Invoke Remove-NetNat       -Times 1 -Exactly
            Should -Invoke Remove-NetIPAddress -Times 1 -Exactly
            Should -Invoke Remove-VMSwitch     -Times 1 -Exactly
        }

        It 'queries all VM adapters with -All when checking for connected VMs' {
            # Without -All, Get-VMNetworkAdapter requires -VMName and returns
            # nothing - the guard would silently never fire, causing the switch
            # to be torn down while VMs are still running.
            Initialize-AllPresentMocks
            Mock Get-VMNetworkAdapter { }

            Invoke-NetworkTeardown -SwitchName 'VmLAN' `
                                   -Gateway   '192.168.1.1' `
                                   -NatName   'VmLAN-NAT'

            Should -Invoke Get-VMNetworkAdapter -Times 1 -Exactly -ParameterFilter {
                $All -eq $true
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'NAT rule removal' {
    # ------------------------------------------------------------------

        It 'removes the NAT rule when it exists' {
            Initialize-AllPresentMocks

            Invoke-NetworkTeardown -SwitchName 'VmLAN' `
                                   -Gateway   '192.168.1.1' `
                                   -NatName   'VmLAN-NAT'

            # -Confirm:$false prevents an interactive prompt that would block CI.
            Should -Invoke Remove-NetNat -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'VmLAN-NAT' -and $Confirm -eq $false
            }
        }

        It 'does not call Remove-NetNat when the rule is already absent' {
            Initialize-AllAbsentMocks

            Invoke-NetworkTeardown -SwitchName 'VmLAN' `
                                   -Gateway   '192.168.1.1' `
                                   -NatName   'VmLAN-NAT'

            Should -Invoke Remove-NetNat -Times 0
        }

        It 'does not throw when the NAT rule is absent' {
            Initialize-AllAbsentMocks

            { Invoke-NetworkTeardown -SwitchName 'VmLAN' `
                                     -Gateway   '192.168.1.1' `
                                     -NatName   'VmLAN-NAT' } | Should -Not -Throw
        }
    }

    # ------------------------------------------------------------------
    Context 'host vNIC IP removal' {
    # ------------------------------------------------------------------

        It 'removes the host vNIC IP when it exists' {
            Initialize-AllPresentMocks

            Invoke-NetworkTeardown -SwitchName 'VmLAN' `
                                   -Gateway   '192.168.1.1' `
                                   -NatName   'VmLAN-NAT'

            # -Confirm:$false prevents an interactive prompt that would block CI.
            Should -Invoke Remove-NetIPAddress -Times 1 -Exactly -ParameterFilter {
                $IPAddress -eq '192.168.1.1' -and $Confirm -eq $false
            }
        }

        It 'does not call Remove-NetIPAddress when the IP is already absent' {
            Initialize-AllAbsentMocks

            Invoke-NetworkTeardown -SwitchName 'VmLAN' `
                                   -Gateway   '192.168.1.1' `
                                   -NatName   'VmLAN-NAT'

            Should -Invoke Remove-NetIPAddress -Times 0
        }

        It 'does not throw when the host vNIC IP is absent' {
            Initialize-AllAbsentMocks

            { Invoke-NetworkTeardown -SwitchName 'VmLAN' `
                                     -Gateway   '192.168.1.1' `
                                     -NatName   'VmLAN-NAT' } | Should -Not -Throw
        }
    }

    # ------------------------------------------------------------------
    Context 'virtual switch removal' {
    # ------------------------------------------------------------------

        It 'removes the virtual switch when it exists' {
            Initialize-AllPresentMocks

            Invoke-NetworkTeardown -SwitchName 'VmLAN' `
                                   -Gateway   '192.168.1.1' `
                                   -NatName   'VmLAN-NAT'

            # -Force prevents an interactive confirmation prompt that would block CI.
            Should -Invoke Remove-VMSwitch -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'VmLAN' -and $Force -eq $true
            }
        }

        It 'does not call Remove-VMSwitch when the switch is already absent' {
            Initialize-AllAbsentMocks

            Invoke-NetworkTeardown -SwitchName 'VmLAN' `
                                   -Gateway   '192.168.1.1' `
                                   -NatName   'VmLAN-NAT'

            Should -Invoke Remove-VMSwitch -Times 0
        }

        It 'does not throw when the virtual switch is absent' {
            Initialize-AllAbsentMocks

            { Invoke-NetworkTeardown -SwitchName 'VmLAN' `
                                     -Gateway   '192.168.1.1' `
                                     -NatName   'VmLAN-NAT' } | Should -Not -Throw
        }
    }

    # ------------------------------------------------------------------
    Context 'full teardown - all objects present, no VMs remaining' {
    # ------------------------------------------------------------------

        It 'removes NAT, host IP, and switch when no VMs remain on the switch' {
            Initialize-AllPresentMocks

            Invoke-NetworkTeardown -SwitchName 'VmLAN' `
                                   -Gateway   '192.168.1.1' `
                                   -NatName   'VmLAN-NAT'

            Should -Invoke Remove-NetNat       -Times 1 -Exactly
            Should -Invoke Remove-NetIPAddress -Times 1 -Exactly
            Should -Invoke Remove-VMSwitch     -Times 1 -Exactly
        }
    }
}
