BeforeAll {
    # Stub every cmdlet and external command that requires a Hyper-V host,
    # network access, or a real filesystem. Stubs are permissive no-ops by
    # default; individual tests override with Mock where needed.

    # --- Hyper-V / VHD cmdlets ---
    function Convert-VHD   { param($Path, $DestinationPath, $VHDType, $ErrorAction) }
    function Mount-VHD     { param($Path, [switch]$NoDriveLetter, [switch]$PassThru) }
    function Dismount-VHD  { param($Path) }
    function Resize-VHD    { param($Path, $SizeBytes) }
    function Get-VHD       { param($Path) }

    # --- Filesystem / web cmdlets ---
    function Test-Path         { param($Path, $PathType) }
    function New-Item          { param($ItemType, $Path, [switch]$Force) }
    function Copy-Item         { param($Path, $Destination) }
    function Remove-Item       { param($Path, [switch]$Recurse, [switch]$Force) }
    function Get-ChildItem     { param($Path, $Filter, [switch]$Recurse) }
    function Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing) }
    function Get-Command       { param($Name, $ErrorAction) }

    # External command stubs. Using $args (not [Parameter(ValueFromRemainingArguments)])
    # because the [Parameter] attribute adds common parameters such as -ErrorAction
    # and -ErrorVariable. The wsl callers pass -e and -u flags, which PowerShell then
    # tries to match against those common parameters, making them ambiguous and throwing.
    # $args captures everything without parameter binding, avoiding the conflict.
    function wsl { $global:LASTEXITCODE = 0 }
    function tar { $global:LASTEXITCODE = 0 }

    . "$PSScriptRoot\..\hyper-v\ubuntu\disk\Invoke-DiskImageAcquisition.ps1"

    # Invoke-BaseImagePatch is defined in Invoke-BaseImagePatch.ps1 and is tested
    # separately in Invoke-BaseImagePatch.Tests.ps1. Stub it here so acquisition
    # tests can control whether patching "succeeds" or "throws" without needing
    # WSL2 mock infrastructure.
    function Invoke-BaseImagePatch { param($BaseImagePath, $SentinelPath) }

    # Minimal VM object for all tests.
    function New-TestVm {
        [PSCustomObject]@{
            vmName        = 'node-01'
            vhdPath       = 'C:\VHDs'
            ubuntuVersion = '24.04'
            diskGB        = 40
        }
    }

    # ---------------------------------------------------------------------------
    # Default Test-Path mock
    #   Covers the most common scenario: vhdPath exists, base image is cached,
    #   sentinel is present (WSL2 block skipped), per-VM disk is absent.
    #   Individual tests override specific path patterns as needed.
    # ---------------------------------------------------------------------------
    function Set-DefaultTestPath {
        Mock Test-Path {
            param($Path, $PathType)
            # vhdPath directory exists.
            if ($PathType -eq 'Container')                        { return $true  }
            # Base image VHDX is cached (match the base name, not the VM disk).
            if ($Path -match '24\.04.*\.vhdx$')                   { return $true  }
            # Sentinel present - WSL2 patching is skipped.
            if ($Path -match '\.nocloud-patched$')                { return $true  }
            # Per-VM disk is absent - triggers copy + resize.
            if ($Path -match 'node-01\.vhdx$')                    { return $false }
            return $false
        }
    }
}

Describe 'Invoke-DiskImageAcquisition' {

    # ------------------------------------------------------------------
    Context 'vhdPath directory setup' {
    # ------------------------------------------------------------------

        It 'creates vhdPath when it does not exist' {
            Mock Test-Path {
                param($Path, $PathType)
                if ($PathType -eq 'Container')         { return $false }
                if ($Path -match '24\.04.*\.vhdx$')    { return $true  }
                if ($Path -match '\.nocloud-patched$') { return $true  }
                if ($Path -match 'node-01\.vhdx$')     { return $false }
                return $false
            }
            Mock New-Item {}
            Mock Copy-Item {}
            Mock Get-VHD { [PSCustomObject]@{ Size = 2GB } }
            Mock Resize-VHD {}

            Invoke-DiskImageAcquisition -Vm (New-TestVm)

            Should -Invoke New-Item -Times 1 -Exactly -ParameterFilter {
                $ItemType -eq 'Directory' -and $Path -eq 'C:\VHDs'
            }
        }

        It 'does not create vhdPath when it already exists' {
            Set-DefaultTestPath
            Mock New-Item {}
            Mock Copy-Item {}
            Mock Get-VHD { [PSCustomObject]@{ Size = 2GB } }
            Mock Resize-VHD {}

            Invoke-DiskImageAcquisition -Vm (New-TestVm)

            Should -Invoke New-Item -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'base image - already cached' {
    # ------------------------------------------------------------------

        It 'skips download and conversion when the base VHDX already exists' {
            Set-DefaultTestPath
            Mock Invoke-WebRequest {}
            Mock Convert-VHD {}
            Mock Copy-Item {}
            Mock Get-VHD { [PSCustomObject]@{ Size = 2GB } }
            Mock Resize-VHD {}

            Invoke-DiskImageAcquisition -Vm (New-TestVm)

            Should -Invoke Invoke-WebRequest -Times 0
            Should -Invoke Convert-VHD       -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'base image - download and conversion' {
    # ------------------------------------------------------------------

        BeforeEach {
            # Base image absent; sentinel present so WSL2 block is skipped.
            Mock Test-Path {
                param($Path, $PathType)
                if ($PathType -eq 'Container')         { return $true  }
                if ($Path -match '\.nocloud-patched$') { return $true  }
                if ($Path -match 'node-01\.vhdx$')     { return $false }
                return $false    # base image absent
            }
        }

        It 'downloads from the Ubuntu CDN URL for the configured version' {
            Mock Invoke-WebRequest {}
            Mock New-Item {}
            Mock Get-ChildItem {
                [PSCustomObject]@{ FullName = 'C:\VHDs\_extract\ubuntu.vhd'; Name = 'ubuntu.vhd' }
            }
            Mock Copy-Item {}
            Mock Convert-VHD {}
            Mock Remove-Item {}
            Mock Get-VHD { [PSCustomObject]@{ Size = 2GB } }
            Mock Resize-VHD {}

            Invoke-DiskImageAcquisition -Vm (New-TestVm)

            Should -Invoke Invoke-WebRequest -ParameterFilter {
                $Uri -match 'cloud-images\.ubuntu\.com' -and
                $Uri -match '24\.04'                    -and
                $Uri -match 'azure\.vhd\.tar\.gz$'
            }
        }

        It 'throws when the download fails' {
            Mock Invoke-WebRequest { throw 'network error' }
            Mock New-Item {}

            { Invoke-DiskImageAcquisition -Vm (New-TestVm) } |
                Should -Throw -ExpectedMessage '*Failed to download*'
        }

        It 'throws when tar extraction fails' {
            Mock Invoke-WebRequest {}
            Mock New-Item {}
            Mock tar { $global:LASTEXITCODE = 1 }

            { Invoke-DiskImageAcquisition -Vm (New-TestVm) } |
                Should -Throw -ExpectedMessage '*tar extraction failed*'
        }

        It 'throws when no .vhd file is found in the extracted archive' {
            Mock Invoke-WebRequest {}
            Mock New-Item {}
            Mock Get-ChildItem { }    # nothing found

            { Invoke-DiskImageAcquisition -Vm (New-TestVm) } |
                Should -Throw -ExpectedMessage '*No .vhd file found*'
        }

        It 'converts the extracted .vhd to a Dynamic .vhdx' {
            Mock Invoke-WebRequest {}
            Mock New-Item {}
            Mock Get-ChildItem {
                [PSCustomObject]@{ FullName = 'C:\VHDs\_extract\ubuntu.vhd'; Name = 'ubuntu.vhd' }
            }
            Mock Copy-Item {}
            Mock Convert-VHD {}
            Mock Remove-Item {}
            Mock Get-VHD { [PSCustomObject]@{ Size = 2GB } }
            Mock Resize-VHD {}

            Invoke-DiskImageAcquisition -Vm (New-TestVm)

            Should -Invoke Convert-VHD -Times 1 -Exactly -ParameterFilter {
                $DestinationPath -match 'ubuntu-24\.04-server-cloudimg-amd64\.vhdx$' -and
                $VHDType         -eq 'Dynamic'
            }
        }

        It 'warns and uses the first .vhd when the archive contains multiple' {
            Mock Invoke-WebRequest {}
            Mock New-Item {}
            Mock Get-ChildItem {
                # Return two .vhd files - the code should warn and pick the first.
                @(
                    [PSCustomObject]@{ FullName = 'C:\VHDs\_extract\ubuntu-a.vhd'; Name = 'ubuntu-a.vhd' },
                    [PSCustomObject]@{ FullName = 'C:\VHDs\_extract\ubuntu-b.vhd'; Name = 'ubuntu-b.vhd' }
                )
            }
            Mock Copy-Item {}
            Mock Convert-VHD {}
            Mock Remove-Item {}
            Mock Get-VHD { [PSCustomObject]@{ Size = 2GB } }
            Mock Resize-VHD {}

            # The function must not throw - it warns and falls through.
            { Invoke-DiskImageAcquisition -Vm (New-TestVm) } | Should -Not -Throw

            # Convert-VHD must be called using the first file's path.
            Should -Invoke Copy-Item -ParameterFilter {
                $Path -eq 'C:\VHDs\_extract\ubuntu-a.vhd'
            }
        }

        It 'removes the archive and extraction directory after conversion' {
            Mock Invoke-WebRequest {}
            Mock New-Item {}
            Mock Get-ChildItem {
                [PSCustomObject]@{ FullName = 'C:\VHDs\_extract\ubuntu.vhd'; Name = 'ubuntu.vhd' }
            }
            Mock Copy-Item {}
            Mock Convert-VHD {}
            Mock Remove-Item {}
            Mock Get-VHD { [PSCustomObject]@{ Size = 2GB } }
            Mock Resize-VHD {}

            Invoke-DiskImageAcquisition -Vm (New-TestVm)

            Should -Invoke Remove-Item -ParameterFilter { $Path -match '\.tar\.gz$'  }
            Should -Invoke Remove-Item -ParameterFilter { $Path -match '_extract_'   }
        }
    }

    # ------------------------------------------------------------------
    Context 'WSL2 datasource patching - delegates to Invoke-BaseImagePatch' {
    # ------------------------------------------------------------------
        # Invoke-BaseImagePatch is tested in Invoke-BaseImagePatch.Tests.ps1.
        # These tests verify that Invoke-DiskImageAcquisition calls it with
        # the correct paths and propagates a Wsl2NotReady throw upward.

        It 'calls Invoke-BaseImagePatch with the base image and sentinel paths' {
            Set-DefaultTestPath
            Mock Invoke-BaseImagePatch {}
            Mock Copy-Item {}
            Mock Get-VHD { [PSCustomObject]@{ Size = 2GB } }
            Mock Resize-VHD {}

            Invoke-DiskImageAcquisition -Vm (New-TestVm)

            Should -Invoke Invoke-BaseImagePatch -Times 1 -Exactly -ParameterFilter {
                $BaseImagePath -eq 'C:\VHDs\ubuntu-24.04-server-cloudimg-amd64.vhdx' -and
                $SentinelPath  -eq 'C:\VHDs\ubuntu-24.04-server-cloudimg-amd64.nocloud-patched'
            }
        }

    }

    # ------------------------------------------------------------------
    Context 'per-VM disk - already exists' {
    # ------------------------------------------------------------------

        It 'does not copy or resize when the per-VM disk already exists' {
            # Both base image and per-VM disk present.
            Mock Test-Path {
                param($Path, $PathType)
                if ($PathType -eq 'Container')         { return $true }
                if ($Path -match '\.nocloud-patched$') { return $true }
                return $true    # base image + per-VM disk both present
            }
            Mock Copy-Item {}
            Mock Resize-VHD {}

            Invoke-DiskImageAcquisition -Vm (New-TestVm)

            Should -Invoke Copy-Item  -Times 0
            Should -Invoke Resize-VHD -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'per-VM disk - fresh copy' {
    # ------------------------------------------------------------------

        It 'copies the base image to a per-VM disk file named {vmName}.vhdx' {
            Set-DefaultTestPath
            Mock Copy-Item {}
            Mock Get-VHD { [PSCustomObject]@{ Size = 2GB } }
            Mock Resize-VHD {}

            Invoke-DiskImageAcquisition -Vm (New-TestVm)

            Should -Invoke Copy-Item -Times 1 -Exactly -ParameterFilter {
                $Destination -eq 'C:\VHDs\node-01.vhdx'
            }
        }

        It 'resizes the per-VM disk to diskGB when the base image is smaller' {
            Set-DefaultTestPath
            Mock Copy-Item {}
            Mock Get-VHD { [PSCustomObject]@{ Size = 2GB } }    # 2 GB < 40 GB
            Mock Resize-VHD {}

            Invoke-DiskImageAcquisition -Vm (New-TestVm)

            Should -Invoke Resize-VHD -Times 1 -Exactly -ParameterFilter {
                $Path      -eq 'C:\VHDs\node-01.vhdx' -and
                $SizeBytes -eq (40 * 1GB)
            }
        }

        It 'skips resize when diskGB does not exceed the current disk size' {
            # Resize-VHD cannot shrink a disk - the partition table would be
            # left inconsistent. The function warns and skips.
            Set-DefaultTestPath
            Mock Copy-Item {}
            Mock Get-VHD { [PSCustomObject]@{ Size = 80GB } }   # 80 GB > 40 GB
            Mock Resize-VHD {}

            Invoke-DiskImageAcquisition -Vm (New-TestVm)

            Should -Invoke Resize-VHD -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context '_vhdxPath output' {
    # ------------------------------------------------------------------

        It 'sets _vhdxPath on the VM object to {vhdPath}\{vmName}.vhdx' {
            Set-DefaultTestPath
            Mock Copy-Item {}
            Mock Get-VHD { [PSCustomObject]@{ Size = 2GB } }
            Mock Resize-VHD {}

            $vm = New-TestVm
            Invoke-DiskImageAcquisition -Vm $vm

            $vm._vhdxPath | Should -Be 'C:\VHDs\node-01.vhdx'
        }
    }
}
