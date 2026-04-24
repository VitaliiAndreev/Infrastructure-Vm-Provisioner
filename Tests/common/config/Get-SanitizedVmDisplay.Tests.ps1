BeforeAll {
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\config\Get-SanitizedVmDisplay.ps1"

    # Builds a PSCustomObject from a hashtable - mirrors what ConvertFrom-Json
    # produces so tests reflect real consumer usage.
    function New-TestVm([hashtable] $props) {
        [PSCustomObject] $props
    }
}

Describe 'Get-SanitizedVmDisplay' {

    # ------------------------------------------------------------------
    Context 'secret field masking' {
    # ------------------------------------------------------------------

        It 'replaces the password field with ***' {
            $vm = New-TestVm @{ vmName = 'node-01'; password = 's3cr3t' }
            $result = Get-SanitizedVmDisplay -Vm $vm
            $result.password | Should -Be '***'
        }

        It 'does not mask non-secret fields' {
            $vm = New-TestVm @{ vmName = 'node-01'; password = 's3cr3t' }
            $result = Get-SanitizedVmDisplay -Vm $vm
            $result.vmName | Should -Be 'node-01'
        }

        It 'masks a secret field whose value is null' {
            # ConvertFrom-Json can produce $null for omitted fields;
            # the masking logic must not skip $null values.
            $vm = New-TestVm @{ vmName = 'node-01'; password = $null }
            $result = Get-SanitizedVmDisplay -Vm $vm
            $result.password | Should -Be '***'
        }

        It 'masks a secret field regardless of case (Password vs password)' {
            # PowerShell -in is case-insensitive, so a field named 'Password'
            # (capital P) must still be treated as a secret.
            $vm = New-TestVm @{ vmName = 'node-01'; Password = 's3cr3t' }
            $result = Get-SanitizedVmDisplay -Vm $vm
            $result.Password | Should -Be '***'
        }
    }

    # ------------------------------------------------------------------
    Context 'output structure' {
    # ------------------------------------------------------------------

        It 'preserves all fields from the input object' {
            $vm = New-TestVm @{
                vmName    = 'node-01'
                ipAddress = '10.0.0.1'
                password  = 's3cr3t'
            }
            $result = Get-SanitizedVmDisplay -Vm $vm
            # All three input fields must appear in the output.
            $result.PSObject.Properties.Name |
                Should -Contain 'vmName'
            $result.PSObject.Properties.Name |
                Should -Contain 'ipAddress'
            $result.PSObject.Properties.Name |
                Should -Contain 'password'
        }

        It 'returns fields in alphabetical order (Get-Member iteration order in PS 5.1)' {
            # Get-Member -MemberType NoteProperty returns properties in
            # alphabetical order in PS 5.1, regardless of the input object's
            # insertion order. The function uses [ordered]@{} to preserve
            # that order faithfully in the output.
            $vm = [PSCustomObject][ordered]@{
                vmName    = 'node-01'
                ipAddress = '10.0.0.1'
                password  = 'x'
            }
            $result = Get-SanitizedVmDisplay -Vm $vm
            $names = @($result.PSObject.Properties.Name)
            $names[0] | Should -Be 'ipAddress'
            $names[1] | Should -Be 'password'
            $names[2] | Should -Be 'vmName'
        }

        It 'returns a PSCustomObject (not a hashtable or string)' {
            $vm = New-TestVm @{ vmName = 'node-01' }
            $result = Get-SanitizedVmDisplay -Vm $vm
            $result | Should -BeOfType [PSCustomObject]
        }
    }

    # ------------------------------------------------------------------
    Context 'edge cases' {
    # ------------------------------------------------------------------

        It 'does not throw when the VM object has no properties' {
            # Get-Member returns nothing for an empty object; the foreach
            # must complete without error and return an empty PSCustomObject.
            $vm = [PSCustomObject] @{}
            { Get-SanitizedVmDisplay -Vm $vm } | Should -Not -Throw
        }

        It 'returns an empty object when the VM object has no properties' {
            $vm = [PSCustomObject] @{}
            $result = Get-SanitizedVmDisplay -Vm $vm
            # Enumerate into a real array first: PSMemberInfoIntegratingCollection
            # in PS 5.1 does not expose .Name as a usable array when empty.
            @($result.PSObject.Properties) | Should -HaveCount 0
        }

        It 'does not mask anything when no secret fields are present' {
            $vm = New-TestVm @{ vmName = 'node-01'; ipAddress = '10.0.0.1' }
            $result = Get-SanitizedVmDisplay -Vm $vm
            $result.vmName    | Should -Be 'node-01'
            $result.ipAddress | Should -Be '10.0.0.1'
        }

        It 'masks all fields when every field is a secret' {
            # Artificial case, but verifies the loop handles a full-secret
            # object without short-circuiting.
            $vm = New-TestVm @{ password = 'hunter2' }
            $result = Get-SanitizedVmDisplay -Vm $vm
            $result.password | Should -Be '***'
            # Confirm no original value leaked.
            $result.PSObject.Properties.Value | Should -Not -Contain 'hunter2'
        }
    }
}
