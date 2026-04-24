BeforeAll {
    # Stub all Hyper-V and filesystem cmdlets unavailable outside a Hyper-V host.
    function Get-VM        { param($Name, [switch]$ErrorAction) }
    function Stop-VM       { param($Name, [switch]$Force) }
    function Remove-VM     { param($Name, [switch]$Force) }
    function Remove-Item   { param($Path, [switch]$Recurse, [switch]$Force, $ErrorAction) }
    function Test-Path     { param($Path) }
    function Start-Sleep   { param($Seconds) }
    function Join-Path     { param($Path, $ChildPath) "$Path\$ChildPath" }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\down\vm\remove-vm.ps1"

    # Standard VM object satisfying all Invoke-VmRemoval requirements.
    function New-TestVm {
        [PSCustomObject]@{
            vmName       = 'node-01'
            vhdPath      = 'D:\Hyper-V\Disks'
            vmConfigPath = 'D:\Hyper-V\Config'
        }
    }

    # Sets up all stubs in their neutral no-op form.
    function Initialize-Mocks {
        Mock Get-VM      { [PSCustomObject]@{ State = 'Off' } }
        Mock Stop-VM     { }
        Mock Remove-VM   { }
        Mock Test-Path   { $false }
        Mock Remove-Item { }
        Mock Start-Sleep { }
    }
}

Describe 'Invoke-VmRemoval' {

    # ------------------------------------------------------------------
    Context 'Hyper-V teardown - VM present' {
    # ------------------------------------------------------------------

        It 'calls Stop-VM when the VM is in a running state' {
            Initialize-Mocks
            Mock Get-VM { [PSCustomObject]@{ State = 'Running' } }

            Invoke-VmRemoval -Vm (New-TestVm)

            # -Force prevents an interactive confirmation prompt that would
            # block CI when the VM is running.
            Should -Invoke Stop-VM -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'node-01' -and $Force -eq $true
            }
        }

        It 'does not call Stop-VM when the VM is already Off' {
            Initialize-Mocks
            Mock Get-VM { [PSCustomObject]@{ State = 'Off' } }

            Invoke-VmRemoval -Vm (New-TestVm)

            Should -Invoke Stop-VM -Times 0
        }

        It 'calls Remove-VM when the VM is Off' {
            Initialize-Mocks

            Invoke-VmRemoval -Vm (New-TestVm)

            # -Force prevents an interactive confirmation prompt that would
            # block CI.
            Should -Invoke Remove-VM -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'node-01' -and $Force -eq $true
            }
        }

        It 'calls Remove-VM after Stop-VM when the VM is Running' {
            Initialize-Mocks
            Mock Get-VM { [PSCustomObject]@{ State = 'Running' } }

            Invoke-VmRemoval -Vm (New-TestVm)

            Should -Invoke Remove-VM -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'node-01' -and $Force -eq $true
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'Hyper-V teardown - VM absent' {
    # ------------------------------------------------------------------
        # If a prior run removed the VM but file cleanup did not complete,
        # re-running must still proceed to file deletion.

        It 'skips Stop-VM and Remove-VM when the VM is absent from Hyper-V' {
            Initialize-Mocks
            Mock Get-VM { $null }

            Invoke-VmRemoval -Vm (New-TestVm)

            Should -Invoke Stop-VM  -Times 0
            Should -Invoke Remove-VM -Times 0
        }

        It 'still deletes the VHDX when the VM is absent from Hyper-V' {
            Initialize-Mocks
            Mock Get-VM    { $null }
            Mock Test-Path { $true }

            Invoke-VmRemoval -Vm (New-TestVm)

            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
                $Path -like '*node-01.vhdx'
            }
        }

        It 'still deletes the seed ISO and config dir when the VM is absent from Hyper-V' {
            Initialize-Mocks
            Mock Get-VM    { $null }
            Mock Test-Path { $true }

            Invoke-VmRemoval -Vm (New-TestVm)

            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
                $Path -like '*node-01-seed.iso'
            }
            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
                $Path -like '*Config\node-01'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'VHDX deletion' {
    # ------------------------------------------------------------------

        It 'deletes the VHDX when it exists' {
            Initialize-Mocks
            Mock Test-Path { param($Path) $Path -like '*node-01.vhdx' }

            Invoke-VmRemoval -Vm (New-TestVm)

            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
                $Path -like '*node-01.vhdx'
            }
        }

        It 'does not throw when the VHDX is absent' {
            Initialize-Mocks
            Mock Test-Path { $false }

            { Invoke-VmRemoval -Vm (New-TestVm) } | Should -Not -Throw
        }

        It 'retries VHDX deletion when the first attempt throws IOException' {
            Initialize-Mocks
            Mock Test-Path { param($Path) $Path -like '*node-01.vhdx' }

            $script:_removeCallCount = 0
            Mock Remove-Item {
                $script:_removeCallCount++
                # Succeed on the second attempt.
                if ($script:_removeCallCount -eq 1) {
                    throw [System.IO.IOException]::new('File locked')
                }
            }

            { Invoke-VmRemoval -Vm (New-TestVm) } | Should -Not -Throw

            Should -Invoke Remove-Item -Times 2 -Exactly -ParameterFilter {
                $Path -like '*node-01.vhdx'
            }
        }

        It 'throws after exhausting retries if the VHDX remains locked' {
            Initialize-Mocks
            Mock Test-Path { param($Path) $Path -like '*node-01.vhdx' }
            Mock Remove-Item {
                throw [System.IO.IOException]::new('File locked')
            }

            { Invoke-VmRemoval -Vm (New-TestVm) } |
                Should -Throw -ExpectedMessage '*Could not delete*'
        }
    }

    # ------------------------------------------------------------------
    Context 'seed ISO deletion' {
    # ------------------------------------------------------------------

        It 'deletes the seed ISO when it exists' {
            Initialize-Mocks
            Mock Test-Path { param($Path) $Path -like '*node-01-seed.iso' }

            Invoke-VmRemoval -Vm (New-TestVm)

            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
                $Path -like '*node-01-seed.iso' -and $Force -eq $true
            }
        }

        It 'does not throw when the seed ISO is absent' {
            Initialize-Mocks
            Mock Test-Path { $false }

            { Invoke-VmRemoval -Vm (New-TestVm) } | Should -Not -Throw
        }
    }

    # ------------------------------------------------------------------
    Context 'VM config directory deletion' {
    # ------------------------------------------------------------------

        It 'deletes the VM config directory when it exists' {
            Initialize-Mocks
            Mock Test-Path { param($Path) $Path -like '*Config\node-01' }

            Invoke-VmRemoval -Vm (New-TestVm)

            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
                $Path -like '*Config\node-01'
            }
        }

        It 'does not throw when the VM config directory is absent' {
            Initialize-Mocks
            Mock Test-Path { $false }

            { Invoke-VmRemoval -Vm (New-TestVm) } | Should -Not -Throw
        }
    }
}

Describe 'Remove-ItemWithRetry' {

    BeforeAll {
        function Start-Sleep { param($Seconds) }
        function Remove-Item { param($Path, [switch]$Recurse, [switch]$Force, $ErrorAction) }
        Mock Start-Sleep { }
    }

    It 'succeeds without retrying when Remove-Item succeeds on first attempt' {
        Mock Remove-Item { }

        { Remove-ItemWithRetry -Path 'C:\test\file.vhdx' } | Should -Not -Throw

        Should -Invoke Remove-Item -Times 1 -Exactly
    }

    It 'retries the specified number of times before throwing' {
        Mock Remove-Item {
            throw [System.IO.IOException]::new('File locked')
        }

        { Remove-ItemWithRetry -Path 'C:\test\file.vhdx' -MaxAttempts 3 } |
            Should -Throw -ExpectedMessage '*Could not delete*'

        Should -Invoke Remove-Item -Times 3 -Exactly
    }

    It 'sleeps between retry attempts' {
        $script:_attempt = 0
        Mock Remove-Item {
            $script:_attempt++
            if ($script:_attempt -lt 3) {
                throw [System.IO.IOException]::new('File locked')
            }
        }

        { Remove-ItemWithRetry -Path 'C:\test\file.vhdx' -MaxAttempts 3 -IntervalSeconds 2 } |
            Should -Not -Throw

        # 2 failures each followed by a sleep before the 3rd succeeds.
        Should -Invoke Start-Sleep -Times 2 -Exactly -ParameterFilter {
            $Seconds -eq 2
        }
    }

    It 'does not sleep after the final failing attempt' {
        Mock Remove-Item {
            throw [System.IO.IOException]::new('File locked')
        }

        { Remove-ItemWithRetry -Path 'C:\test\file.vhdx' -MaxAttempts 3 } |
            Should -Throw

        # 3 attempts, 3 failures - sleep only between attempts 1-2 and 2-3,
        # not after attempt 3 (would delay the throw with no retry following).
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }

    It 'does not retry non-IOException errors' {
        # UnauthorizedAccessException (permissions) and similar errors should
        # propagate immediately - retrying them is wrong and masks the real cause.
        Mock Remove-Item {
            throw [System.UnauthorizedAccessException]::new('Access denied')
        }

        { Remove-ItemWithRetry -Path 'C:\test\file.vhdx' -MaxAttempts 3 } |
            Should -Throw -ExpectedMessage '*Access denied*'

        Should -Invoke Remove-Item -Times 1 -Exactly
    }
}
