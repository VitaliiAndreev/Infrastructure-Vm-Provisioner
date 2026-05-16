BeforeAll {
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\config\Assert-JavaDevKitField.ps1"

    # Builds a VM definition object with the given JSON fragment as its
    # 'javaDevKit' field. Tests parse JSON rather than constructing
    # PSCustomObjects by hand so the validator sees the same shape that
    # ConvertFrom-VmConfigJson hands it at runtime.
    function New-VmWithJdkJson([string] $JdkJson) {
        $json = if ($null -eq $JdkJson) {
            '{ "vmName": "node-01" }'
        } else {
            "{ `"vmName`": `"node-01`", `"javaDevKit`": $JdkJson }"
        }
        return ($json | ConvertFrom-Json)
    }

    function New-VmWithoutJdk {
        return ('{ "vmName": "node-01" }' | ConvertFrom-Json)
    }
}

Describe 'Assert-JavaDevKitField' {

    # ------------------------------------------------------------------
    Context 'optional field absent' {
    # ------------------------------------------------------------------

        It 'returns silently when javaDevKit is absent' {
            $vm = New-VmWithoutJdk
            { Assert-JavaDevKitField -Vm $vm } | Should -Not -Throw
        }

        It 'does not add a javaDevKit field when absent' {
            $vm = New-VmWithoutJdk
            Assert-JavaDevKitField -Vm $vm
            $vm.PSObject.Properties['javaDevKit'] | Should -BeNullOrEmpty
        }
    }

    # ------------------------------------------------------------------
    Context 'valid javaDevKit' {
    # ------------------------------------------------------------------

        It 'accepts vendor temurin with major-only version "21"' {
            $vm = New-VmWithJdkJson '{ "vendor": "temurin", "version": "21" }'
            { Assert-JavaDevKitField -Vm $vm } | Should -Not -Throw
        }

        It 'accepts major.minor version "21.0"' {
            $vm = New-VmWithJdkJson '{ "vendor": "temurin", "version": "21.0" }'
            { Assert-JavaDevKitField -Vm $vm } | Should -Not -Throw
        }

        It 'accepts major.minor.patch version "21.0.5"' {
            $vm = New-VmWithJdkJson '{ "vendor": "temurin", "version": "21.0.5" }'
            { Assert-JavaDevKitField -Vm $vm } | Should -Not -Throw
        }

        It 'accepts major.minor.patch+build version "21.0.5+11"' {
            $vm = New-VmWithJdkJson '{ "vendor": "temurin", "version": "21.0.5+11" }'
            { Assert-JavaDevKitField -Vm $vm } | Should -Not -Throw
        }
    }

    # ------------------------------------------------------------------
    Context 'vendor validation' {
    # ------------------------------------------------------------------

        It 'throws when vendor is missing' {
            $vm = New-VmWithJdkJson '{ "version": "21" }'
            { Assert-JavaDevKitField -Vm $vm } |
                Should -Throw -ExpectedMessage "*vendor*"
        }

        It 'throws when vendor is an unsupported value' {
            $vm = New-VmWithJdkJson '{ "vendor": "corretto", "version": "21" }'
            { Assert-JavaDevKitField -Vm $vm } |
                Should -Throw -ExpectedMessage "*vendor*temurin*"
        }
    }

    # ------------------------------------------------------------------
    Context 'version validation' {
    # ------------------------------------------------------------------

        It 'throws when version is missing' {
            $vm = New-VmWithJdkJson '{ "vendor": "temurin" }'
            { Assert-JavaDevKitField -Vm $vm } |
                Should -Throw -ExpectedMessage "*version*"
        }

        It 'throws when version is a JSON number (not a string)' {
            # JSON number 21 parses to Int32, not String. The string-type
            # check must reject it before the regex sees it.
            $vm = New-VmWithJdkJson '{ "vendor": "temurin", "version": 21 }'
            { Assert-JavaDevKitField -Vm $vm } |
                Should -Throw -ExpectedMessage "*version*string*"
        }

        It 'throws when version contains a trailing tag' {
            $vm = New-VmWithJdkJson '{ "vendor": "temurin", "version": "21.0.5+11-LTS" }'
            { Assert-JavaDevKitField -Vm $vm } |
                Should -Throw -ExpectedMessage "*version*granularity*"
        }

        It 'throws when version has four numeric segments' {
            $vm = New-VmWithJdkJson '{ "vendor": "temurin", "version": "21.0.5.7" }'
            { Assert-JavaDevKitField -Vm $vm } |
                Should -Throw -ExpectedMessage "*version*granularity*"
        }

        It 'throws when version is an empty string' {
            $vm = New-VmWithJdkJson '{ "vendor": "temurin", "version": "" }'
            { Assert-JavaDevKitField -Vm $vm } |
                Should -Throw -ExpectedMessage "*version*granularity*"
        }
    }

    # ------------------------------------------------------------------
    Context 'strict sub-field set' {
    # ------------------------------------------------------------------

        It 'throws when an unknown sub-field is present (typo guard)' {
            # 'versoin' is the canonical typo example - validator must catch
            # it rather than silently treating the field as if version is
            # missing.
            $vm = New-VmWithJdkJson '{ "vendor": "temurin", "versoin": "21" }'
            { Assert-JavaDevKitField -Vm $vm } |
                Should -Throw -ExpectedMessage "*versoin*"
        }

        It 'throws when an extra sub-field is present alongside valid ones' {
            $vm = New-VmWithJdkJson '{ "vendor": "temurin", "version": "21", "arch": "x64" }'
            { Assert-JavaDevKitField -Vm $vm } |
                Should -Throw -ExpectedMessage "*arch*"
        }
    }

    # ------------------------------------------------------------------
    Context 'shape validation' {
    # ------------------------------------------------------------------

        It 'throws when javaDevKit is a string instead of an object' {
            $vm = New-VmWithJdkJson '"temurin-21"'
            { Assert-JavaDevKitField -Vm $vm } |
                Should -Throw -ExpectedMessage "*javaDevKit*object*"
        }

        It 'throws when javaDevKit is an array instead of an object' {
            $vm = New-VmWithJdkJson '[ "temurin", "21" ]'
            { Assert-JavaDevKitField -Vm $vm } |
                Should -Throw -ExpectedMessage "*javaDevKit*object*"
        }

        It 'throws when javaDevKit is null' {
            $vm = New-VmWithJdkJson 'null'
            { Assert-JavaDevKitField -Vm $vm } |
                Should -Throw -ExpectedMessage "*javaDevKit*object*"
        }
    }

    # ------------------------------------------------------------------
    Context 'error message contains VM context' {
    # ------------------------------------------------------------------

        It 'includes the vmName in the thrown message' {
            $vm = New-VmWithJdkJson '{ "vendor": "corretto", "version": "21" }'
            { Assert-JavaDevKitField -Vm $vm } |
                Should -Throw -ExpectedMessage "*node-01*"
        }

        It 'falls back to (unknown) when vmName is absent' {
            $json = '{ "javaDevKit": { "vendor": "corretto", "version": "21" } }'
            $vm   = ($json | ConvertFrom-Json)
            { Assert-JavaDevKitField -Vm $vm } |
                Should -Throw -ExpectedMessage "*(unknown)*"
        }
    }
}
