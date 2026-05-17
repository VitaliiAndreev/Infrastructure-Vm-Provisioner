BeforeAll {
    # Stub Hyper-V cmdlet unavailable outside a Hyper-V host.
    function Get-VM { param($Name, $ErrorAction) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\config\Select-VmsForProvisioning.ps1"

    function New-TestVm {
        param(
            [string] $VmName    = 'node-01',
            [string] $IpAddress = '192.168.1.10'
        )
        [PSCustomObject]@{ vmName = $VmName; ipAddress = $IpAddress }
    }

    # Default: no existing VM, no IP conflict (i.e. classified as 'new').
    function Initialize-Mocks {
        Mock Get-VM              { $null  }
        Mock Test-IpAddressInUse { $false }
    }
}

Describe 'Select-VmsForProvisioning' {

    # ------------------------------------------------------------------
    Context 'new VM (Hyper-V absent, IP free)' {
    # ------------------------------------------------------------------

        It "annotates the VM with _state = 'new' and returns it" {
            Initialize-Mocks

            $result = @(Select-VmsForProvisioning -VmDefs @(New-TestVm))

            $result.Count        | Should -Be 1
            $result[0].vmName    | Should -Be 'node-01'
            $result[0]._state    | Should -Be 'new'
        }
    }

    # ------------------------------------------------------------------
    Context 'existing VM (Hyper-V present, IP responds)' {
    # ------------------------------------------------------------------

        It "annotates the VM with _state = 'existing' and returns it" {
            # The existing VM owns its IP, so a ping response is expected
            # and confirms reachability for downstream reconcile.
            Initialize-Mocks
            Mock Get-VM              { [PSCustomObject]@{ Name = 'node-01' } }
            Mock Test-IpAddressInUse { $true }

            $result = @(Select-VmsForProvisioning -VmDefs @(New-TestVm))

            $result.Count     | Should -Be 1
            $result[0].vmName | Should -Be 'node-01'
            $result[0]._state | Should -Be 'existing'
        }
    }

    # ------------------------------------------------------------------
    Context 'IP conflict with unknown machine (Hyper-V absent, IP in use)' {
    # ------------------------------------------------------------------

        It 'drops the VM with a warning' {
            Initialize-Mocks
            Mock Test-IpAddressInUse { $true }

            $result = @(Select-VmsForProvisioning -VmDefs @(New-TestVm) `
                3> $null)

            $result.Count | Should -Be 0
        }
    }

    # ------------------------------------------------------------------
    Context 'existing VM that is offline (Hyper-V present, IP silent)' {
    # ------------------------------------------------------------------

        It 'drops the VM with a warning' {
            # An offline existing VM would fail post-provisioning at SSH
            # open with an opaque error - surface the state up front
            # instead so the operator can start the VM and re-run.
            Initialize-Mocks
            Mock Get-VM              { [PSCustomObject]@{ Name = 'node-01' } }
            Mock Test-IpAddressInUse { $false }

            $result = @(Select-VmsForProvisioning -VmDefs @(New-TestVm) `
                3> $null)

            $result.Count | Should -Be 0
        }
    }

    # ------------------------------------------------------------------
    Context 'mixed batch' {
    # ------------------------------------------------------------------

        It 'classifies each VM independently and returns only valid ones' {
            Initialize-Mocks
            Mock Get-VM -ParameterFilter { $Name -eq 'new-vm' }      { $null }
            Mock Get-VM -ParameterFilter { $Name -eq 'existing-vm' } {
                [PSCustomObject]@{ Name = 'existing-vm' }
            }
            Mock Get-VM -ParameterFilter { $Name -eq 'conflict-vm' } { $null }
            Mock Get-VM -ParameterFilter { $Name -eq 'offline-vm' }  {
                [PSCustomObject]@{ Name = 'offline-vm' }
            }

            Mock Test-IpAddressInUse -ParameterFilter { $IpAddress -eq '10.0.0.1' } { $false }
            Mock Test-IpAddressInUse -ParameterFilter { $IpAddress -eq '10.0.0.2' } { $true  }
            Mock Test-IpAddressInUse -ParameterFilter { $IpAddress -eq '10.0.0.3' } { $true  }
            Mock Test-IpAddressInUse -ParameterFilter { $IpAddress -eq '10.0.0.4' } { $false }

            $vms = @(
                (New-TestVm -VmName 'new-vm'      -IpAddress '10.0.0.1'),
                (New-TestVm -VmName 'existing-vm' -IpAddress '10.0.0.2'),
                (New-TestVm -VmName 'conflict-vm' -IpAddress '10.0.0.3'),
                (New-TestVm -VmName 'offline-vm'  -IpAddress '10.0.0.4')
            )

            $result = @(Select-VmsForProvisioning -VmDefs $vms 3> $null)

            $result.Count                                   | Should -Be 2
            ($result | Where-Object vmName -eq 'new-vm')._state      | Should -Be 'new'
            ($result | Where-Object vmName -eq 'existing-vm')._state | Should -Be 'existing'
        }
    }
}
