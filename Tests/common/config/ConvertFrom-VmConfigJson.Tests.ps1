BeforeAll {
    # Stub Assert-RequiredProperties before dot-sourcing so the function exists
    # when ConvertFrom-VmConfigJson.ps1 is loaded. The real implementation
    # lives in Infrastructure.Common, which is not required in the test
    # environment.
    function Assert-RequiredProperties {
        param($Object, $Properties, $Context)
    }

    # ConvertTo-Array is provided by Infrastructure.Common at runtime.
    # Stub it here so the unit tests have no cross-repo dependency.
    function ConvertTo-Array {
        param([AllowNull()] $InputObject)
        if ($null -eq $InputObject) { return , @() }
        , @($InputObject)
    }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\config\ConvertFrom-VmConfigJson.ps1"

    # ConvertFrom-VmConfigJson.ps1 dot-sources Assert-JavaDevKitField.ps1, so
    # the real function is in scope. The wiring test below mocks it; behaviour
    # cases live in Assert-JavaDevKitField.Tests.ps1.
    #
    # Assert-VmFilesField is supplied by Infrastructure.HyperV at runtime.
    # Stub it here so the wiring test can mock it without loading the module.
    function Assert-VmFilesField {
        param(
            $Vm,
            $AllowedSubFields,
            [switch] $AllowBulkEntries,
            $PostEntryValidator,
            $PostEntryValidatorContext
        )
    }

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
    "vmConfigPath":  "E:\\a_VMs\\Hyper-V\\Config",
    "vhdPath":       "E:\\a_VMs\\Hyper-V\\Disks"
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
            # into a bare PSCustomObject. ConvertTo-Array normalises this so
            # callers always receive an array.
            $result = @(ConvertFrom-VmConfigJson -Json (New-ValidVmJson))
            $result | Should -HaveCount 1
        }

        It 'defaults switchName to VmLAN when absent' {
            $result = @(ConvertFrom-VmConfigJson -Json "[$(New-ValidVmJson)]")
            $result[0].switchName | Should -Be 'VmLAN'
        }

        It 'defaults natName to VmLAN-NAT when absent' {
            $result = @(ConvertFrom-VmConfigJson -Json "[$(New-ValidVmJson)]")
            $result[0].natName | Should -Be 'VmLAN-NAT'
        }

        It 'preserves explicit switchName and natName values' {
            $custom = (New-ValidVmJson | ConvertFrom-Json)
            $custom | Add-Member -MemberType NoteProperty -Name switchName -Value 'E2E-VmLAN'
            $custom | Add-Member -MemberType NoteProperty -Name natName    -Value 'E2E-VmLAN-NAT'
            $result = @(ConvertFrom-VmConfigJson -Json "[$(ConvertTo-Json $custom -Compress)]")
            $result[0].switchName | Should -Be 'E2E-VmLAN'
            $result[0].natName    | Should -Be 'E2E-VmLAN-NAT'
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
    Context 'Assert-JavaDevKitField wiring' {
    # ------------------------------------------------------------------

        It 'invokes Assert-JavaDevKitField once per VM' {
            # Wiring-only check. Behaviour cases for the validator itself
            # live in Assert-JavaDevKitField.Tests.ps1 - duplicating them
            # here would couple the caller's tests to its callee's rules.
            Mock Assert-JavaDevKitField {}
            $json = "[$(New-ValidVmJson 'node-01'), $(New-ValidVmJson 'node-02')]"
            @(ConvertFrom-VmConfigJson -Json $json)
            Should -Invoke Assert-JavaDevKitField -Times 2 -Exactly
        }

        It 'propagates a throw from Assert-JavaDevKitField' {
            Mock Assert-JavaDevKitField { throw "javaDevKit.version must be a string" }
            { ConvertFrom-VmConfigJson -Json "[$(New-ValidVmJson)]" } |
                Should -Throw -ExpectedMessage "*javaDevKit*"
        }
    }

    # ------------------------------------------------------------------
    Context 'Assert-VmFilesField wiring (Infrastructure.HyperV)' {
    # ------------------------------------------------------------------

        # Assert-VmFilesField is supplied by Infrastructure.HyperV at runtime.
        # The function is stubbed in BeforeAll alongside the other module
        # cmdlets so wiring tests can mock it without loading the module.

        It 'invokes Assert-VmFilesField once per VM with default sub-fields' {
            Mock Assert-VmFilesField {}
            $json = "[$(New-ValidVmJson 'node-01'), $(New-ValidVmJson 'node-02')]"
            @(ConvertFrom-VmConfigJson -Json $json)
            Should -Invoke Assert-VmFilesField -Times 2 -Exactly
        }

        It 'opts into bulk entries via -AllowBulkEntries' {
            # The opt-in is the only schema-surface change in this step.
            # Asserted here so a future caller cannot silently drop the
            # switch and lock the provisioner back into single-form-only.
            Mock Assert-VmFilesField {}
            @(ConvertFrom-VmConfigJson -Json "[$(New-ValidVmJson)]")
            Should -Invoke Assert-VmFilesField -Times 1 -Exactly -ParameterFilter {
                $AllowBulkEntries.IsPresent -and
                ($AllowedSubFields -join ',') -eq 'source,target'
            }
        }

        It 'propagates a throw from Assert-VmFilesField' {
            Mock Assert-VmFilesField { throw "files[0].source path does not exist" }
            { ConvertFrom-VmConfigJson -Json "[$(New-ValidVmJson)]" } |
                Should -Throw -ExpectedMessage "*files*"
        }
    }

    # ------------------------------------------------------------------
    Context 'files round-trip (bulk-form entries preserved)' {
    # ------------------------------------------------------------------

        # Behaviour of the bulk validator itself (missing targetDir, unknown
        # sub-fields, etc.) is covered by Assert-VmFilesField's own tests
        # in Infrastructure-HyperV. These cases only assert that opting in
        # at the call site does not drop or rename any field on the way
        # through the schema layer.

        # Helper inlined per test: Pester 5 hoists function definitions in
        # BeforeAll, but a function defined inside a Context body is not in
        # scope for the It blocks. Building the JSON inline keeps the
        # round-trip cases self-contained without a Context-level BeforeAll.

        It 'preserves a single bulk entry on the returned VM' {
            $files = '[{ "pattern": "C:\\jars\\*.jar", "targetDir": "/opt/ci-jars" }]'
            $core  = (New-ValidVmJson) -replace '\}\s*$', ''
            $result = @(ConvertFrom-VmConfigJson -Json "[$core, ""files"": $files }]")
            $result[0].files | Should -HaveCount 1
            $result[0].files[0].pattern   | Should -Be 'C:\jars\*.jar'
            $result[0].files[0].targetDir | Should -Be '/opt/ci-jars'
        }

        It 'preserves a mixed single + bulk entry array in source order' {
            $files = @'
[
    { "source": "C:\\seed.json", "target": "/var/data/seed.json" },
    { "pattern": "C:\\jars\\*.jar", "targetDir": "/opt/ci-jars" }
]
'@
            $core  = (New-ValidVmJson) -replace '\}\s*$', ''
            $result = @(ConvertFrom-VmConfigJson -Json "[$core, ""files"": $files }]")
            $result[0].files | Should -HaveCount 2
            $result[0].files[0].source  | Should -Be 'C:\seed.json'
            $result[0].files[1].pattern | Should -Be 'C:\jars\*.jar'
        }

        It 'preserves the optional recurse and preserveRelativePath booleans' {
            $files = '[{ "pattern": "C:\\jars\\**\\*.jar", "targetDir": "/opt/ci-jars", "recurse": true, "preserveRelativePath": true }]'
            $core  = (New-ValidVmJson) -replace '\}\s*$', ''
            $result = @(ConvertFrom-VmConfigJson -Json "[$core, ""files"": $files }]")
            $result[0].files[0].recurse              | Should -BeTrue
            $result[0].files[0].preserveRelativePath | Should -BeTrue
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
