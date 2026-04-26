BeforeAll {
    # Stub Hyper-V cmdlet unavailable outside a Hyper-V host.
    function Get-VM { param($Name, $ErrorAction) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\config\Select-VmsForProvisioning.ps1"

    function New-TestVm {
        param(
            [string] $VmName     = 'node-01',
            [string] $IpAddress  = '192.168.1.10'
        )
        [PSCustomObject]@{ vmName = $VmName; ipAddress = $IpAddress }
    }

    # Default: no existing VM, no IP conflict - both checks pass.
    function Initialize-Mocks {
        Mock Get-VM              { $null  }
        Mock Test-IpAddressInUse { $false }
    }
}

Describe 'Select-VmsForProvisioning' {

    # ------------------------------------------------------------------
    Context 'VM already exists in Hyper-V' {
    # ------------------------------------------------------------------

        It 'skips a VM that already exists' {
            Initialize-Mocks
            Mock Get-VM { [PSCustomObject]@{ Name = 'node-01' } }

            $result = @(Select-VmsForProvisioning -VmDefs @(New-TestVm))

            $result.Count | Should -Be 0
        }

        It 'still processes subsequent VMs after skipping an existing one' {
            Initialize-Mocks
            Mock Get-VM -ParameterFilter { $Name -eq 'node-01' } {
                [PSCustomObject]@{ Name = 'node-01' }
            }
            Mock Get-VM -ParameterFilter { $Name -eq 'node-02' } { $null }

            $vms = @(
                (New-TestVm -VmName 'node-01'),
                (New-TestVm -VmName 'node-02')
            )
            $result = @(Select-VmsForProvisioning -VmDefs $vms)

            $result.Count    | Should -Be 1
            $result[0].vmName | Should -Be 'node-02'
        }

        It 'does not check the IP when the VM already exists' {
            # The existing VM owns this IP - a ping response is expected and
            # is not a conflict. Checking would produce a false positive skip.
            Initialize-Mocks
            Mock Get-VM { [PSCustomObject]@{ Name = 'node-01' } }

            Select-VmsForProvisioning -VmDefs @(New-TestVm)

            Should -Invoke Test-IpAddressInUse -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'IP address conflict' {
    # ------------------------------------------------------------------

        It 'skips a VM whose IP address is already in use' {
            Initialize-Mocks
            Mock Test-IpAddressInUse { $true }

            $result = @(Select-VmsForProvisioning -VmDefs @(New-TestVm))

            $result.Count | Should -Be 0
        }

        It 'still processes subsequent VMs after skipping an IP conflict' {
            Initialize-Mocks
            Mock Test-IpAddressInUse -ParameterFilter { $IpAddress -eq '192.168.1.10' } { $true  }
            Mock Test-IpAddressInUse -ParameterFilter { $IpAddress -eq '192.168.1.11' } { $false }

            $vms = @(
                (New-TestVm -VmName 'node-01' -IpAddress '192.168.1.10'),
                (New-TestVm -VmName 'node-02' -IpAddress '192.168.1.11')
            )
            $result = @(Select-VmsForProvisioning -VmDefs $vms)

            $result.Count     | Should -Be 1
            $result[0].vmName | Should -Be 'node-02'
        }

        It 'checks the correct IP address for each VM' {
            Initialize-Mocks

            Select-VmsForProvisioning -VmDefs @(New-TestVm -IpAddress '192.168.1.10')

            Should -Invoke Test-IpAddressInUse -Times 1 -Exactly -ParameterFilter {
                $IpAddress -eq '192.168.1.10'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'VM passes all checks' {
    # ------------------------------------------------------------------

        It 'returns the VM when it passes both checks' {
            Initialize-Mocks

            $result = @(Select-VmsForProvisioning -VmDefs @(New-TestVm))

            $result.Count     | Should -Be 1
            $result[0].vmName | Should -Be 'node-01'
        }

        It 'returns all VMs when all pass both checks' {
            Initialize-Mocks

            $vms = @(
                (New-TestVm -VmName 'node-01' -IpAddress '192.168.1.10'),
                (New-TestVm -VmName 'node-02' -IpAddress '192.168.1.11')
            )
            $result = @(Select-VmsForProvisioning -VmDefs $vms)

            $result.Count | Should -Be 2
        }

        It 'returns an empty array when all VMs are skipped' {
            Initialize-Mocks
            Mock Get-VM { [PSCustomObject]@{ Name = 'node-01' } }

            $result = @(Select-VmsForProvisioning -VmDefs @(New-TestVm))

            $result.Count | Should -Be 0
        }
    }
}
