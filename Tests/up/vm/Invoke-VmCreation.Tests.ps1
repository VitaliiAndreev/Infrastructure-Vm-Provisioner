BeforeAll {
    # Stub all Hyper-V cmdlets unavailable outside a Hyper-V host.
    function New-VM                   { param($Name, $Generation, $MemoryStartupBytes, $VHDPath, $Path) }
    function Set-VMProcessor          { param($VMName, $Count) }
    function Get-VMHardDiskDrive      { param($VMName) }
    function Set-VMFirmware           { param($VMName, $EnableSecureBoot, $SecureBootTemplate, $FirstBootDevice) }
    function Add-VMDvdDrive           { param($VMName, $Path) }
    function Connect-VMNetworkAdapter { param($VMName, $Name, $SwitchName) }
    function Start-VM                 { param($VMName) }
    function Get-VM                   { param($Name) }
    function Get-VMDvdDrive           { param($VMName) }
    function Remove-VMDvdDrive        { param($VMName, $ControllerNumber, $ControllerLocation) }
    function Remove-Item              { param($Path, [switch]$Force) }
    function Test-Path                { param($Path) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\vm\create-vm.ps1"

    # Standard VM object satisfying all Invoke-VmCreation requirements.
    function New-TestVm {
        [PSCustomObject]@{
            vmName       = 'node-01'
            vmConfigPath = 'E:\a_VMs\Hyper-V\Config'
            username     = 'admin'
            ipAddress    = '192.168.1.10'
            cpuCount     = 2
            ramGB        = 4
            _vhdxPath    = 'C:\VMs\node-01\node-01.vhdx'
            _seedIsoPath = 'C:\VMs\node-01\node-01-seed.iso'
        }
    }

    # Standard DVD drive object returned by Get-VMDvdDrive.
    function New-TestDvdDrive {
        [PSCustomObject]@{
            Path               = 'C:\VMs\node-01\node-01-seed.iso'
            ControllerNumber   = 1
            ControllerLocation = 0
        }
    }

    # Sets up the Hyper-V creation stubs in their neutral no-op form.
    # Also sets up the finally-block stubs so cleanup always runs cleanly.
    function Initialize-HyperVMocks {
        Mock New-VM              { }
        Mock Set-VMProcessor     { }
        Mock Get-VMHardDiskDrive { [PSCustomObject]@{ Path = 'disk.vhdx' } }
        Mock Set-VMFirmware      { }
        Mock Add-VMDvdDrive      { }
        Mock Connect-VMNetworkAdapter { }
        Mock Start-VM            { }
        # Return Off state by default so the post-creation guard passes.
        Mock Get-VM              { [PSCustomObject]@{ State = 'Off' } }
        Mock Get-VMDvdDrive      { New-TestDvdDrive }
        Mock Remove-VMDvdDrive   { }
        Mock Test-Path           { $false }
    }

    # Makes the SSH polling loop body never execute by returning a deadline in
    # the past relative to what Get-Date returns on the loop-condition check.
    #
    # The source sets the deadline as:
    #   $deadline = (Get-Date).AddMinutes($timeoutMinutes)   <- call 1
    # and then checks:
    #   while ((Get-Date) -lt $deadline)                     <- call 2+
    #
    # If all calls return the same instant T, the condition T < T+10min is
    # true and the loop body runs. To prevent that, the first call returns T
    # and every subsequent call returns T+11min (after the deadline).
    function Set-ExpiredDeadline {
        $script:_deadlineCallCount = 0
        Mock Get-Date {
            $script:_deadlineCallCount++
            if ($script:_deadlineCallCount -le 1) { [datetime]'2020-01-01' }
            else                                  { [datetime]'2020-01-01 01:00:00' }
        }
    }
}

Describe 'Invoke-VmCreation' {

    # ------------------------------------------------------------------
    Context 'VM creation parameters' {
    # ------------------------------------------------------------------

        It 'creates a Gen 2 VM with the correct name, RAM, VHDX, and config path' {
            Initialize-HyperVMocks
            Set-ExpiredDeadline

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw    # timeout throw - expected here

            Should -Invoke New-VM -Times 1 -Exactly -ParameterFilter {
                $Name               -eq 'node-01'                    -and
                $Generation         -eq 2                             -and
                $MemoryStartupBytes -eq (4 * 1GB)                    -and
                $VHDPath            -eq 'C:\VMs\node-01\node-01.vhdx' -and
                $Path               -eq 'C:\VMs\node-01'
            }
        }

        It 'sets the CPU count via Set-VMProcessor' {
            Initialize-HyperVMocks
            Set-ExpiredDeadline

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw

            Should -Invoke Set-VMProcessor -Times 1 -Exactly -ParameterFilter {
                $VMName -eq 'node-01' -and $Count -eq 2
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'Secure Boot configuration' {
    # ------------------------------------------------------------------
        # Ubuntu's shim bootloader requires MicrosoftUEFICertificateAuthority.
        # The default MicrosoftWindows template rejects third-party UEFI
        # bootloaders, causing a Secure Boot violation on first boot.

        It 'enables Secure Boot with the MicrosoftUEFICertificateAuthority template' {
            Initialize-HyperVMocks
            Set-ExpiredDeadline

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw

            Should -Invoke Set-VMFirmware -Times 1 -Exactly -ParameterFilter {
                $VMName             -eq 'node-01'                          -and
                $EnableSecureBoot   -eq 'On'                               -and
                $SecureBootTemplate -eq 'MicrosoftUEFICertificateAuthority'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'seed ISO attachment' {
    # ------------------------------------------------------------------

        It 'attaches the seed ISO as a DVD drive' {
            Initialize-HyperVMocks
            Set-ExpiredDeadline

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw

            Should -Invoke Add-VMDvdDrive -Times 1 -Exactly -ParameterFilter {
                $VMName -eq 'node-01' -and
                $Path   -eq 'C:\VMs\node-01\node-01-seed.iso'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'network adapter connection' {
    # ------------------------------------------------------------------

        It 'connects the network adapter to the specified switch' {
            Initialize-HyperVMocks
            Set-ExpiredDeadline

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw

            Should -Invoke Connect-VMNetworkAdapter -Times 1 -Exactly -ParameterFilter {
                $VMName     -eq 'node-01' -and
                $SwitchName -eq 'VmLAN'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'VM startup' {
    # ------------------------------------------------------------------

        It 'starts the VM after configuration' {
            Initialize-HyperVMocks
            Set-ExpiredDeadline

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw

            Should -Invoke Start-VM -Times 1 -Exactly -ParameterFilter {
                $VMName -eq 'node-01'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'post-creation state guard' {
    # ------------------------------------------------------------------
        # New-VM may silently fail when the target VHDX is locked by a
        # running leftover VM (Hyper-V can surface this as a warning rather
        # than a terminating error). A host auto-start policy can also
        # start a freshly-created VM before Set-VMFirmware runs. Either
        # way the VM is in a non-Off state right after New-VM returns, so
        # we check and throw before reaching Set-VMFirmware.

        It 'throws with an actionable message when the VM is not Off after creation' {
            Initialize-HyperVMocks
            Mock Get-VM { [PSCustomObject]@{ State = 'Running' } }

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw -ExpectedMessage '*Stop or remove the VM manually*'
        }

        It 'does not call Set-VMFirmware when the VM is not Off after creation' {
            Initialize-HyperVMocks
            Mock Get-VM { [PSCustomObject]@{ State = 'Running' } }

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw

            Should -Invoke Set-VMFirmware -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'SSH polling - VM stops unexpectedly' {
    # ------------------------------------------------------------------
        # The loop checks VM state each iteration. If the VM is no longer
        # Running it throws immediately rather than waiting out the timeout,
        # avoiding a 10-minute wait when the VM has already crashed.

        It 'throws immediately when the VM state is not Running' {
            Initialize-HyperVMocks

            # Return a date far enough in the future that the deadline
            # (date + 10 min) does not overflow and the loop body executes
            # at least once before the state check fires.
            Mock Get-Date { [datetime]'2099-01-01' }
            Mock Get-VM   { [PSCustomObject]@{ State = 'Off' } }

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw -ExpectedMessage '*stopped unexpectedly*'
        }
    }

    # ------------------------------------------------------------------
    Context 'SSH polling - timeout' {
    # ------------------------------------------------------------------

        It 'throws when the deadline passes without SSH becoming reachable' {
            Initialize-HyperVMocks
            Set-ExpiredDeadline

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw -ExpectedMessage '*did not become reachable*'
        }
    }

    # ------------------------------------------------------------------
    Context 'finally block - seed ISO cleanup' {
    # ------------------------------------------------------------------
        # The seed ISO is always removed regardless of whether SSH succeeds
        # or times out. It contains the plaintext password and must never
        # persist on the host disk after provisioning.

        It 'detaches the DVD drive in the finally block on timeout' {
            Initialize-HyperVMocks
            Set-ExpiredDeadline

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw

            Should -Invoke Remove-VMDvdDrive -Times 1 -Exactly -ParameterFilter {
                $VMName             -eq 'node-01' -and
                $ControllerNumber   -eq 1          -and
                $ControllerLocation -eq 0
            }
        }

        It 'deletes the seed ISO file in the finally block on timeout' {
            Initialize-HyperVMocks
            Set-ExpiredDeadline
            Mock Test-Path  { $true }    # ISO present on disk
            Mock Remove-Item { }

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw

            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
                $Path  -eq 'C:\VMs\node-01\node-01-seed.iso' -and
                $Force -eq $true
            }
        }

        It 'does not call Remove-Item when the seed ISO file is already gone' {
            Initialize-HyperVMocks
            Set-ExpiredDeadline
            Mock Test-Path   { $false }    # ISO already deleted
            Mock Remove-Item { }

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw

            Should -Invoke Remove-Item -Times 0
        }

        It 'skips Remove-VMDvdDrive when no matching DVD drive is found' {
            # If Add-VMDvdDrive failed before throwing, Get-VMDvdDrive returns
            # nothing. The finally block must handle a $null drive gracefully.
            Initialize-HyperVMocks
            Set-ExpiredDeadline
            Mock Get-VMDvdDrive    { }    # no drives attached
            Mock Remove-VMDvdDrive { }

            { Invoke-VmCreation -Vm (New-TestVm) -SwitchName 'VmLAN' } |
                Should -Throw

            Should -Invoke Remove-VMDvdDrive -Times 0
        }
    }
}
