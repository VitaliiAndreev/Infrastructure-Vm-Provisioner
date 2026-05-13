BeforeAll {
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\common\config\Assert-FilesField.ps1"

    # Builds a VM definition object with the given JSON fragment as its
    # 'files' field. Tests parse JSON rather than constructing PSCustomObjects
    # by hand so the validator sees the same shape ConvertFrom-VmConfigJson
    # hands it at runtime.
    function New-VmWithFilesJson([string] $FilesJson) {
        $json = if ($null -eq $FilesJson) {
            '{ "vmName": "node-01" }'
        } else {
            "{ `"vmName`": `"node-01`", `"files`": $FilesJson }"
        }
        return ($json | ConvertFrom-Json)
    }

    function New-VmWithoutFiles {
        return ('{ "vmName": "node-01" }' | ConvertFrom-Json)
    }

    # All happy-path tests need a real-on-disk source path because the
    # validator performs Test-Path. Use TestDrive so each It cleans up.
    function New-ExistingSourcePath {
        $path = Join-Path $TestDrive 'src.bin'
        Set-Content -Path $path -Value 'unit-test-bytes' -Encoding Byte
        # JSON-escape the backslashes for embedding in JSON fragments.
        return ($path -replace '\\', '\\')
    }
}

Describe 'Assert-FilesField' {

    Context 'optional field absent' {

        It 'returns silently when files is absent' {
            $vm = New-VmWithoutFiles
            { Assert-FilesField -Vm $vm } | Should -Not -Throw
        }

        It 'returns silently when files is an empty array' {
            $vm = New-VmWithFilesJson '[]'
            { Assert-FilesField -Vm $vm } | Should -Not -Throw
        }
    }

    Context 'valid files' {

        It 'accepts a single { source, target } entry with an existing source' {
            $src = New-ExistingSourcePath
            $vm = New-VmWithFilesJson "[{ `"source`": `"$src`", `"target`": `"/opt/lib/x.bin`" }]"
            { Assert-FilesField -Vm $vm } | Should -Not -Throw
        }

        It 'accepts multiple entries' {
            $src = New-ExistingSourcePath
            $vm = New-VmWithFilesJson @"
[
    { "source": "$src", "target": "/opt/lib/a.bin" },
    { "source": "$src", "target": "/opt/lib/b.bin" }
]
"@
            { Assert-FilesField -Vm $vm } | Should -Not -Throw
        }
    }

    Context 'invalid files - shape' {

        It 'throws when files is a JSON object instead of an array' {
            $vm = New-VmWithFilesJson '{ "source": "x", "target": "/y" }'
            { Assert-FilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*files must be a JSON array*"
        }

        It 'throws when files is a string' {
            $vm = New-VmWithFilesJson '"oops"'
            { Assert-FilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*files must be a JSON array*"
        }

        It 'throws when an entry is not an object' {
            $vm = New-VmWithFilesJson '["just-a-string"]'
            { Assert-FilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*files[0] must be a JSON object*"
        }

        It 'throws on unknown sub-field (catches typos like src/dest)' {
            $src = New-ExistingSourcePath
            $vm = New-VmWithFilesJson "[{ `"src`": `"$src`", `"target`": `"/y`" }]"
            { Assert-FilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*unknown sub-field 'src'*"
        }
    }

    Context 'invalid files - source' {

        It 'throws when source is missing' {
            $vm = New-VmWithFilesJson '[{ "target": "/y" }]'
            { Assert-FilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*missing required sub-field 'source'*"
        }

        It 'throws when source is empty' {
            $vm = New-VmWithFilesJson '[{ "source": "", "target": "/y" }]'
            { Assert-FilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*source must be a non-empty string*"
        }

        It 'throws when source path does not exist on the host' {
            $vm = New-VmWithFilesJson `
                '[{ "source": "C:\\does-not-exist-xyz\\f.bin", "target": "/y" }]'
            { Assert-FilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*source path does not exist*"
        }
    }

    Context 'invalid files - target' {

        It 'throws when target is missing' {
            $src = New-ExistingSourcePath
            $vm = New-VmWithFilesJson "[{ `"source`": `"$src`" }]"
            { Assert-FilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*missing required sub-field 'target'*"
        }

        It 'throws when target is empty' {
            $src = New-ExistingSourcePath
            $vm = New-VmWithFilesJson "[{ `"source`": `"$src`", `"target`": `"`" }]"
            { Assert-FilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*target must be a non-empty string*"
        }

        It 'throws when target is a relative path' {
            $src = New-ExistingSourcePath
            $vm = New-VmWithFilesJson "[{ `"source`": `"$src`", `"target`": `"opt/x`" }]"
            { Assert-FilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*absolute Linux path*"
        }

        It 'throws when target is a Windows-style path' {
            $src = New-ExistingSourcePath
            $vm = New-VmWithFilesJson "[{ `"source`": `"$src`", `"target`": `"C:\\opt\\x`" }]"
            { Assert-FilesField -Vm $vm } |
                Should -Throw -ExpectedMessage "*absolute Linux path*"
        }
    }
}
