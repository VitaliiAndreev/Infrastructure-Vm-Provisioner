BeforeAll {
    function Test-Path   { param($Path) }
    function New-Item    { param($ItemType, $Path, [switch]$Force) }
    function Get-Command { param($Name, $ErrorAction) }
    function Mount-VHD   { param($Path, [switch]$NoDriveLetter, [switch]$PassThru) }
    function Dismount-VHD { param($Path) }

    # wsl stub - uses $args to avoid parameter-binding conflicts with the
    # -u and -e flags passed by the callers (see Invoke-DiskImageAcquisition
    # tests for the detailed explanation).
    function wsl { $global:LASTEXITCODE = 0 }

    . "$PSScriptRoot\..\hyper-v\ubuntu\acquire-disk-image.ps1"

    $BaseImage = 'C:\VHDs\ubuntu-24.04-server-cloudimg-amd64.vhdx'
    $Sentinel  = 'C:\VHDs\ubuntu-24.04-server-cloudimg-amd64.nocloud-patched'
}

Describe 'Invoke-BaseImagePatch' {

    # ------------------------------------------------------------------
    Context 'sentinel already present' {
    # ------------------------------------------------------------------
        # The sentinel file records that the patch was applied on a previous
        # run. All WSL2 operations must be skipped to avoid redundant work.

        It 'returns without calling Mount-VHD when the sentinel exists' {
            Mock Test-Path { $true }
            Mock Mount-VHD {}

            Invoke-BaseImagePatch -BaseImagePath $BaseImage -SentinelPath $Sentinel

            Should -Invoke Mount-VHD -Times 0
        }

        It 'returns without calling wsl when the sentinel exists' {
            Mock Test-Path { $true }
            Mock wsl {}

            Invoke-BaseImagePatch -BaseImagePath $BaseImage -SentinelPath $Sentinel

            Should -Invoke wsl -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'WSL2 not ready' {
    # ------------------------------------------------------------------
        # When wsl.exe is absent or no distro is registered, the function
        # runs wsl --install and throws a Wsl2NotReady error. provision.ps1
        # catches that prefix and exits with code 0 after printing the
        # reboot prompt.
        #
        # This path was previously expressed as `exit 0` inside the function,
        # which terminated the test runner process and made it untestable.
        # The throw approach keeps the behavior observable.

        It 'throws a Wsl2NotReady error when wsl.exe is not found' {
            Mock Test-Path { $false }
            Mock Get-Command { }    # wsl.exe not on PATH

            { Invoke-BaseImagePatch -BaseImagePath $BaseImage -SentinelPath $Sentinel } |
                Should -Throw -ExpectedMessage 'Wsl2NotReady:*'
        }

        It 'throws a Wsl2NotReady error when no WSL2 distro is registered' {
            Mock Test-Path { $false }
            Mock Get-Command { [PSCustomObject]@{ Name = 'wsl.exe' } }
            # wsl --list returns exit code 0 but empty output - no distro.
            Mock wsl { $global:LASTEXITCODE = 0; return '' }

            { Invoke-BaseImagePatch -BaseImagePath $BaseImage -SentinelPath $Sentinel } |
                Should -Throw -ExpectedMessage 'Wsl2NotReady:*'
        }

        It 'calls wsl --install before throwing when WSL2 is not ready' {
            Mock Test-Path { $false }
            Mock Get-Command { }
            Mock wsl {}

            { Invoke-BaseImagePatch -BaseImagePath $BaseImage -SentinelPath $Sentinel } |
                Should -Throw

            # wsl --install should have been called to initiate setup.
            Should -Invoke wsl -ParameterFilter { $args -contains '--install' }
        }

        It 'does not call Mount-VHD when WSL2 is not ready' {
            Mock Test-Path { $false }
            Mock Get-Command { }
            Mock wsl {}
            Mock Mount-VHD {}

            { Invoke-BaseImagePatch -BaseImagePath $BaseImage -SentinelPath $Sentinel } |
                Should -Throw

            Should -Invoke Mount-VHD -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'wsl --mount --bare fails' {
    # ------------------------------------------------------------------
        # If the bare mount fails, the function throws and the finally block
        # must still dismount the VHD. The sentinel must not be created.

        BeforeEach {
            Mock Test-Path { $false }
            Mock Get-Command { [PSCustomObject]@{ Name = 'wsl.exe' } }
            Mock Mount-VHD { [PSCustomObject]@{ DiskNumber = 3 } }
            Mock Dismount-VHD {}
            Mock New-Item {}
        }

        It 'throws when wsl --mount --bare returns a non-zero exit code' {
            Mock wsl {
                if ($args -contains '--list') { $global:LASTEXITCODE = 0; return 'Ubuntu' }
                if ($args -contains '--bare') { $global:LASTEXITCODE = 1; return 'error'  }
                $global:LASTEXITCODE = 0; return ''
            }

            { Invoke-BaseImagePatch -BaseImagePath $BaseImage -SentinelPath $Sentinel } |
                Should -Throw -ExpectedMessage '*wsl --mount --bare failed*'
        }

        It 'calls Dismount-VHD in the finally block when wsl --mount --bare fails' {
            Mock wsl {
                if ($args -contains '--list') { $global:LASTEXITCODE = 0; return 'Ubuntu' }
                if ($args -contains '--bare') { $global:LASTEXITCODE = 1; return 'error'  }
                $global:LASTEXITCODE = 0; return ''
            }

            { Invoke-BaseImagePatch -BaseImagePath $BaseImage -SentinelPath $Sentinel } |
                Should -Throw

            Should -Invoke Dismount-VHD -Times 1 -Exactly -ParameterFilter {
                $Path -eq $BaseImage
            }
        }

        It 'does not create the sentinel file when wsl --mount --bare fails' {
            Mock wsl {
                if ($args -contains '--list') { $global:LASTEXITCODE = 0; return 'Ubuntu' }
                if ($args -contains '--bare') { $global:LASTEXITCODE = 1; return 'error'  }
                $global:LASTEXITCODE = 0; return ''
            }

            { Invoke-BaseImagePatch -BaseImagePath $BaseImage -SentinelPath $Sentinel } |
                Should -Throw

            Should -Invoke New-Item -Times 0
        }
    }
}
