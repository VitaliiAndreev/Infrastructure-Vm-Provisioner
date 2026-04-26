BeforeAll {
    # New-SeedIso depends on IMAPI2FS (Windows COM server) and the
    # IsoStreamWriter C# shim compiled by Add-Type at runtime. Both are
    # unavailable in the test environment, so the three external dependencies
    # are stubbed here.
    #
    # All tests stop execution at the mocked New-Object call (the COM
    # instantiation). This is intentional: the subsequent static call
    # [IsoStreamWriter]::ToFile is not mockable via Pester, so tests are
    # written to terminate before reaching it.
    #
    # NOTE: if IsoStreamWriter was compiled by a prior call to the real
    # Add-Type in the same PowerShell session, the Add-Type guard test will
    # see the type as already present and not invoke Add-Type. Run tests in a
    # fresh session (pwsh -NonInteractive) to avoid this cross-run dependency.
    function Add-Type    { param([string] $TypeDefinition) }
    function New-Item    { param($ItemType, $Path) }
    function Remove-Item { param($Path, [switch]$Recurse, [switch]$Force, $ErrorAction) }
    function New-Object  { param($ComObject) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\seed\iso.ps1"
}

Describe 'New-SeedIso' {

    Context 'Add-Type guard' {

        It 'calls Add-Type to compile IsoStreamWriter when the type is not loaded' {
            Mock Add-Type    {}
            Mock New-Item    {}
            Mock Remove-Item {}
            Mock New-Object  { throw 'COM not available' }

            { New-SeedIso -OutputPath 'C:\out.iso' -Files @{} } | Should -Throw

            Should -Invoke Add-Type -Times 1 -Exactly
        }
    }

    Context 'temp directory lifecycle' {

        It 'creates a temp directory before writing files' {
            Mock Add-Type    {}
            Mock New-Item    {}
            Mock Remove-Item {}
            Mock New-Object  { throw 'COM not available' }

            { New-SeedIso -OutputPath 'C:\out.iso' -Files @{} } | Should -Throw

            Should -Invoke New-Item -Times 1 -Exactly -ParameterFilter {
                $ItemType -eq 'Directory'
            }
        }

        It 'removes the temp directory in the finally block when COM creation throws' {
            Mock Add-Type    {}
            Mock New-Item    {}
            Mock Remove-Item {}
            Mock New-Object  { throw 'IMAPI2FS not available' }

            { New-SeedIso -OutputPath 'C:\out.iso' -Files @{} } | Should -Throw

            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
                $Recurse -and $Force
            }
        }
    }
}
