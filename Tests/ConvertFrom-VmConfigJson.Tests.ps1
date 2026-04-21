BeforeAll {
    # Stub Assert-RequiredProperties before dot-sourcing so the function exists
    # when ConvertFrom-VmConfigJson.ps1 is loaded. The real implementation
    # lives in Infrastructure.Common, which is not required in the test
    # environment.
    function Assert-RequiredProperties {
        param($Object, $Properties, $Context)
    }

    . "$PSScriptRoot\..\hyper-v\ubuntu\config\ConvertFrom-VmConfigJson.ps1"

    # Builds a minimal valid VM definition with all required fields populated.
    # Individual tests override specific fields as needed.
    function New-ValidVmJson([string] $vmName = 'node-01') {
        @"
{
    "vmName":        "$vmName",
    "cpuCount":      2,
    "ramGB":         4,
    "diskGB":        40,
    "ubuntuVersion": "24.04",
    "username":      "admin",
    "password":      "s3cr3t",
    "ipAddress":     "10.0.0.10",
    "subnetMask":    "255.255.255.0",
    "gateway":       "10.0.0.1",
    "dns":           "8.8.8.8",
    "vmConfigPath":  "C:\\VMs\\$vmName",
    "vhdPath":       "C:\\VHDs"
}
"@
    }
}

Describe 'ConvertFrom-VmConfigJson' {

    # ------------------------------------------------------------------
    Context 'valid input' {
    # ------------------------------------------------------------------

        It 'returns a VM object for a single-object JSON array' {
            $result = @(ConvertFrom-VmConfigJson -Json "[$(New-ValidVmJson)]")
            $result | Should -HaveCount 1
            $result[0].vmName | Should -Be 'node-01'
        }

        It 'normalises a bare JSON object to a 1-element array (PS 5.1 unwrap)' {
            # ConvertFrom-Json in PS 5.1 unwraps a single-element JSON array
            # into a bare PSCustomObject. @() in the function normalises this
            # so callers always receive an array.
            $result = @(ConvertFrom-VmConfigJson -Json (New-ValidVmJson))
            $result | Should -HaveCount 1
        }

        It 'returns all VM objects for a multi-VM JSON array' {
            $json = "[$(New-ValidVmJson 'node-01'), $(New-ValidVmJson 'node-02')]"
            $result = @(ConvertFrom-VmConfigJson -Json $json)
            $result | Should -HaveCount 2
            $result[0].vmName | Should -Be 'node-01'
            $result[1].vmName | Should -Be 'node-02'
        }
    }

    # ------------------------------------------------------------------
    Context 'invalid JSON' {
    # ------------------------------------------------------------------

        It 'throws "Invalid JSON" for a malformed JSON string' {
            { ConvertFrom-VmConfigJson -Json '{not valid json' } |
                Should -Throw -ExpectedMessage '*Invalid JSON*'
        }

        It 'throws on an empty string' {
            # PS 5.1 rejects an empty [string] parameter before the function
            # body runs, so the error comes from parameter binding rather than
            # the "Invalid JSON" catch block. The function still throws - this
            # test pins that boundary behaviour.
            { ConvertFrom-VmConfigJson -Json '' } |
                Should -Throw -ExpectedMessage '*empty string*'
        }
    }

    # ------------------------------------------------------------------
    Context 'empty or non-object JSON' {
    # ------------------------------------------------------------------

        It 'throws when the JSON array is empty' {
            { ConvertFrom-VmConfigJson -Json '[]' } |
                Should -Throw -ExpectedMessage '*non-empty JSON array*'
        }

        It 'calls Assert-RequiredProperties on a JSON scalar (documents current behaviour)' {
            # ConvertFrom-Json succeeds for a quoted scalar like '"hello"', but
            # the result is a string, not a PSCustomObject. Assert-RequiredProperties
            # is called on it - this test pins the current behaviour so any
            # future guard added here is a deliberate, tested change.
            Mock Assert-RequiredProperties {}
            { ConvertFrom-VmConfigJson -Json '"hello"' } | Should -Not -Throw
            Should -Invoke Assert-RequiredProperties -Times 1 -Exactly
        }
    }

    # ------------------------------------------------------------------
    Context 'Assert-RequiredProperties call contract' {
    # ------------------------------------------------------------------

        It 'calls Assert-RequiredProperties once per VM' {
            Mock Assert-RequiredProperties {}
            $json = "[$(New-ValidVmJson 'node-01'), $(New-ValidVmJson 'node-02')]"
            @(ConvertFrom-VmConfigJson -Json $json)
            Should -Invoke Assert-RequiredProperties -Times 2 -Exactly
        }

        It 'passes the vmName in the Context when vmName is present' {
            Mock Assert-RequiredProperties {}
            @(ConvertFrom-VmConfigJson -Json "[$(New-ValidVmJson 'node-01')]")
            Should -Invoke Assert-RequiredProperties -Times 1 -Exactly -ParameterFilter {
                $Context -like "*node-01*"
            }
        }

        It 'uses (unknown) in the Context when vmName is absent' {
            # A VM definition with no vmName field at all - the Context string
            # must fall back to (unknown) so the error is still meaningful.
            $json = '[{ "cpuCount": 2 }]'
            Mock Assert-RequiredProperties {}
            @(ConvertFrom-VmConfigJson -Json $json)
            Should -Invoke Assert-RequiredProperties -Times 1 -Exactly -ParameterFilter {
                $Context -like "*(unknown)*"
            }
        }

        It 'throws when Assert-RequiredProperties throws (field validation failure)' {
            Mock Assert-RequiredProperties { throw "missing required field 'ipAddress'" }
            { ConvertFrom-VmConfigJson -Json "[$(New-ValidVmJson)]" } |
                Should -Throw -ExpectedMessage "*missing required field*"
        }
    }

    # ------------------------------------------------------------------
    Context 'partial output on mid-loop validation failure' {
    # ------------------------------------------------------------------

        It 'throws when the second VM fails validation' {
            # KNOWN BEHAVIOUR: the first VM is emitted to the pipeline before
            # the second VM is validated. If the caller wraps in @(), the array
            # will be incomplete when the throw is caught. This test documents
            # the behaviour so any future fix is deliberate and tested.
            #
            # $script: scope is required - Pester mock scriptblocks run in their
            # own scope and cannot read a local $callCount from the It block.
            $script:_mockCallCount = 0
            Mock Assert-RequiredProperties {
                $script:_mockCallCount++
                if ($script:_mockCallCount -eq 2) {
                    throw "missing required field 'ipAddress'"
                }
            }
            $json = "[$(New-ValidVmJson 'node-01'), $(New-ValidVmJson 'node-02')]"
            { @(ConvertFrom-VmConfigJson -Json $json) } |
                Should -Throw -ExpectedMessage "*missing required field*"
        }
    }
}
