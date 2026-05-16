<#
.SYNOPSIS
    Structural wiring checks for provision.ps1.

.DESCRIPTION
    provision.ps1 has top-level side effects (vault read, module imports) so
    it cannot be dot-sourced safely from a test. As a pragmatic compromise
    these tests parse the file via AST and assert:
      - Invoke-JdkAcquisition (host-side prefetch) is wired between disk
        acquisition and seed-ISO generation, guarded by 'javaDevKit'.
      - Invoke-JdkInstall (on-VM install over the host file server) is
        wired after Invoke-VmCreation, guarded by 'javaDevKit'.

    Behavioural coverage of the JDK functions themselves lives in
    Tests/up/jdk/Invoke-JdkAcquisition.Tests.ps1 and
    Tests/up/jdk/Invoke-JdkInstall.Tests.ps1.
#>

BeforeAll {
    $script:provisionPath = Join-Path $PSScriptRoot `
        '..\hyper-v\ubuntu\provision.ps1'

    $tokens    = $null
    $parseErrs = $null
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:provisionPath, [ref] $tokens, [ref] $parseErrs)

    if ($parseErrs.Count -gt 0) {
        throw "provision.ps1 has parse errors: $($parseErrs -join '; ')"
    }

    # Pull every command invocation in the file once so each test can filter
    # cheaply by command name.
    $script:commands = $script:ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true)
}

Describe 'provision.ps1 - acquisition wiring (Step 4)' {

    It 'dot-sources Invoke-VmAcquisitions.ps1' {
        $text = Get-Content -Path $script:provisionPath -Raw
        $text | Should -Match 'Invoke-VmAcquisitions\.ps1'
    }

    It 'dot-sources Invoke-JdkAcquisition.ps1 (consumed by Invoke-VmAcquisitions)' {
        $text = Get-Content -Path $script:provisionPath -Raw
        $text | Should -Match 'Invoke-JdkAcquisition\.ps1'
    }

    It 'dot-sources Resolve-AdoptiumRelease.ps1 before Invoke-JdkAcquisition.ps1' {
        # Resolver must be loaded first because Invoke-JdkAcquisition.ps1
        # references Resolve-AdoptiumRelease at call time.
        $text       = Get-Content -Path $script:provisionPath -Raw
        $resolverAt = $text.IndexOf('Resolve-AdoptiumRelease.ps1')
        $acqAt      = $text.IndexOf('Invoke-JdkAcquisition.ps1')

        $resolverAt | Should -BeGreaterThan -1
        $acqAt      | Should -BeGreaterThan -1
        $resolverAt | Should -BeLessThan $acqAt
    }

    It 'dot-sources the per-software acquirers before the orchestrator' {
        # Orchestrator references the acquirer functions at call time;
        # loading them after would still work, but loading them before is
        # the convention this repo follows (matches the post side).
        $text   = Get-Content -Path $script:provisionPath -Raw
        $orchAt = $text.IndexOf('Invoke-VmAcquisitions.ps1')
        $jdkAt  = $text.IndexOf('Invoke-JdkAcquisition.ps1')
        $jdkAt | Should -BeLessThan $orchAt
    }

    It 'invokes Invoke-VmAcquisitions exactly once' {
        $calls = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Invoke-VmAcquisitions' }
        @($calls).Count | Should -Be 1
    }

    It 'calls Invoke-VmAcquisitions unconditionally (no per-field guard at orchestrator)' {
        # Field guards live INSIDE Invoke-VmAcquisitions so the orchestrator
        # does not need to know which acquirers each VM enables. This test
        # asserts the call is NOT inside an if-statement. Mirrors the
        # post-provisioning wiring shape.
        $call = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Invoke-VmAcquisitions' } |
            Select-Object -First 1

        $ifAst = $call.Parent
        while ($null -ne $ifAst -and
               -not ($ifAst -is [System.Management.Automation.Language.IfStatementAst])) {
            $ifAst = $ifAst.Parent
        }

        $ifAst | Should -BeNullOrEmpty `
            -Because 'Invoke-VmAcquisitions must be called for every VM; it self-skips when no opt-in fields are set'
    }

    It 'places Invoke-VmAcquisitions after disk acquisition and before seed-ISO generation' {
        # Ordering matters: vhdPath is created by Invoke-DiskImageAcquisition,
        # and the seed-ISO generator consumes _jdkTarballPath produced by
        # the JDK acquirer dispatched inside Invoke-VmAcquisitions.
        $byName = @{}
        foreach ($cmd in $script:commands) {
            $name = $cmd.GetCommandName()
            if ($name -in 'Invoke-DiskImageAcquisition',
                          'Invoke-VmAcquisitions',
                          'Invoke-SeedIsoGeneration') {
                if (-not $byName.ContainsKey($name)) {
                    $byName[$name] = $cmd.Extent.StartOffset
                }
            }
        }

        $byName['Invoke-DiskImageAcquisition'] |
            Should -BeLessThan $byName['Invoke-VmAcquisitions']
        $byName['Invoke-VmAcquisitions'] |
            Should -BeLessThan $byName['Invoke-SeedIsoGeneration']
    }
}

Describe 'provision.ps1 - post-provisioning wiring (Step 5)' {

    It 'dot-sources Invoke-VmPostProvisioning.ps1' {
        $text = Get-Content -Path $script:provisionPath -Raw
        $text | Should -Match 'Invoke-VmPostProvisioning\.ps1'
    }

    It 'dot-sources Install-Jdk before the orchestrator' {
        # Orchestrator references step functions at call time; loading
        # them after the orchestrator would still work, but loading them
        # before is the convention this repo follows.
        # Copy-VmFiles is NOT dot-sourced - it lives in Infrastructure.HyperV
        # and is imported by Install-ModuleDependencies.ps1.
        $text   = Get-Content -Path $script:provisionPath -Raw
        $orchAt = $text.IndexOf('Invoke-VmPostProvisioning.ps1')
        $stepAt = $text.IndexOf('Install-Jdk.ps1')
        $stepAt | Should -BeGreaterThan -1
        $stepAt | Should -BeLessThan $orchAt
    }

    It 'invokes Invoke-VmPostProvisioning exactly once' {
        $calls = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Invoke-VmPostProvisioning' }
        @($calls).Count | Should -Be 1
    }

    It 'calls Invoke-VmPostProvisioning unconditionally (no per-field guard at orchestrator)' {
        # Field guards live INSIDE Invoke-VmPostProvisioning so the
        # orchestrator does not need to know which steps each VM enables.
        # This test asserts the call is NOT inside an if-statement.
        $call = $script:commands |
            Where-Object { $_.GetCommandName() -eq 'Invoke-VmPostProvisioning' } |
            Select-Object -First 1

        $ifAst = $call.Parent
        while ($null -ne $ifAst -and
               -not ($ifAst -is [System.Management.Automation.Language.IfStatementAst])) {
            $ifAst = $ifAst.Parent
        }

        $ifAst | Should -BeNullOrEmpty `
            -Because 'Invoke-VmPostProvisioning must be called for every VM; it self-skips when no opt-in fields are set'
    }

    It 'places Invoke-VmPostProvisioning after Invoke-VmCreation' {
        # Post-provisioning needs a running, SSH-reachable VM, which
        # Invoke-VmCreation guarantees by blocking until SSH is up.
        $byName = @{}
        foreach ($cmd in $script:commands) {
            $name = $cmd.GetCommandName()
            if ($name -in 'Invoke-VmCreation', 'Invoke-VmPostProvisioning') {
                if (-not $byName.ContainsKey($name)) {
                    $byName[$name] = $cmd.Extent.StartOffset
                }
            }
        }

        $byName['Invoke-VmCreation'] |
            Should -BeLessThan $byName['Invoke-VmPostProvisioning']
    }
}
