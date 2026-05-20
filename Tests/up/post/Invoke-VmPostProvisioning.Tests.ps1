BeforeAll {
    # ---- Why this file uses global stubs instead of Pester Mock ------------
    # Invoke-VmPostProvisioning wraps its per-VM work in a scriptblock
    # frozen with .GetNewClosure() so the orchestrator's locals survive
    # the trip into Infrastructure.HyperV's Invoke-WithVmFileServer
    # (another module's session state). The closure captures the
    # orchestrator file's session state at closure-creation time; command
    # resolution from inside the closure does not walk back into Pester's
    # per-container scope, so Mocks declared in BeforeEach never intercept
    # the inner calls.
    #
    # The functions inside the closure (New-VmSshClient,
    # Invoke-SshClientCommand, Install-Jdk, Copy-VmFiles) are therefore
    # defined as GLOBAL stubs that record their invocations into a
    # $global: log. Tests read the log directly. The outer call
    # (Invoke-WithVmFileServer) runs from the orchestrator function's
    # own scope, which DOES see global stubs - the stub there forwards
    # to the captured scriptblock so the closure executes in-process.
    # ----------------------------------------------------------------------

    # Auto-loading of the real Infrastructure.HyperV would shadow these
    # global stubs because module-exported functions win over plain
    # session functions. Remove anything already loaded and disable
    # auto-load for the duration of the file. Both reads are defensive
    # under StrictMode.
    Remove-Module Infrastructure.HyperV -Force -ErrorAction SilentlyContinue
    $prior = Get-Variable -Name PSModuleAutoLoadingPreference -Scope Global `
        -ErrorAction SilentlyContinue
    $script:_priorAutoLoad = if ($null -ne $prior) { $prior.Value } else { $null }
    $global:PSModuleAutoLoadingPreference = 'None'

    # Global invocation log + reset helper. Reset is called from BeforeEach
    # in the Describe below.
    $global:_PostProv_Calls = @{
        'New-VmSshClient'         = @()
        'Invoke-SshClientCommand' = @()
        'Install-Jdk'             = @()
        'Uninstall-Jdk'           = @()
        'Copy-VmFiles'            = @()
        'Copy-VmFilesByPattern'   = @()
        'Invoke-WithVmFileServer' = @()
    }
    function global:Reset-PostProvCallLog {
        foreach ($k in @($global:_PostProv_Calls.Keys)) {
            $global:_PostProv_Calls[$k] = @()
        }
    }

    # Fake transport handles. The orchestrator only inspects ScriptMethod
    # surfaces (Disconnect / Dispose, IsConnected); no real state needed.
    $global:_PostProv_FakeSshClient = [PSCustomObject]@{ IsConnected = $false }
    $global:_PostProv_FakeSshClient | Add-Member -MemberType ScriptMethod -Name 'Disconnect' -Value {}
    $global:_PostProv_FakeSshClient | Add-Member -MemberType ScriptMethod -Name 'Dispose'    -Value {}

    $global:_PostProv_FakeServer = [PSCustomObject]@{
        BaseUrl    = 'http://192.168.1.1:8745'
        StagingDir = 'C:\Users\Public\file-server-stage'
    }

    # Toggle: when set, Invoke-SshClientCommand returns ExitStatus=1
    # instead of 0 so the "non-zero cloud-init" test can exercise that
    # branch without Mock.
    $global:_PostProv_SshExitStatus = 0

    # ---- Global stubs ----------------------------------------------------

    # Outer (orchestrator-scope) stub. Forwards to the captured scriptblock
    # so the closure executes in-process and records its own calls below.
    function global:Invoke-WithVmFileServer {
        param($VmIpAddress, $Port, [scriptblock]$ScriptBlock)
        $global:_PostProv_Calls['Invoke-WithVmFileServer'] += @{
            VmIpAddress = $VmIpAddress
            Port        = $Port
        }
        & $ScriptBlock $global:_PostProv_FakeServer
    }

    # PSSA's plain-text password warning is suppressed for the same reason
    # it is on the real cmdlet - SSH.NET requires a plain string.
    function global:New-VmSshClient {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSAvoidUsingPlainTextForPassword', 'Password')]
        param($IpAddress, $Username, $Password)
        $global:_PostProv_Calls['New-VmSshClient'] += @{
            IpAddress = $IpAddress
            Username  = $Username
            Password  = $Password
        }
        return $global:_PostProv_FakeSshClient
    }

    function global:Invoke-SshClientCommand {
        param($SshClient, $Command)
        $global:_PostProv_Calls['Invoke-SshClientCommand'] += @{
            Command = $Command
        }
        [PSCustomObject]@{
            ExitStatus = $global:_PostProv_SshExitStatus
            Output     = ''
            Error      = ''
        }
    }

    function global:Install-Jdk {
        param($SshClient, $Server, $Vm)
        $global:_PostProv_Calls['Install-Jdk'] += @{ Vm = $Vm }
    }

    function global:Uninstall-Jdk {
        param($SshClient, $Vm)
        $global:_PostProv_Calls['Uninstall-Jdk'] += @{ Vm = $Vm }
    }

    function global:Copy-VmFiles {
        param($SshClient, $Server, $Entries)
        $global:_PostProv_Calls['Copy-VmFiles'] += @{ Entries = $Entries }
    }

    function global:Copy-VmFilesByPattern {
        param($SshClient, $Server, $Pattern, $TargetDir,
              [switch]$Recurse, [switch]$PreserveRelativePath)
        $global:_PostProv_Calls['Copy-VmFilesByPattern'] += @{
            Pattern              = $Pattern
            TargetDir            = $TargetDir
            Recurse              = [bool]$Recurse
            PreserveRelativePath = [bool]$PreserveRelativePath
        }
    }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\post\Invoke-VmPostProvisioning.ps1"

    function New-PlainVm {
        [PSCustomObject]@{
            vmName    = 'node-01'
            ipAddress = '192.168.1.10'
            username  = 'admin'
            password  = 'unit-test-password-not-real'
        }
    }

    function New-VmWithJdk {
        $vm = New-PlainVm
        Add-Member -InputObject $vm -MemberType NoteProperty -Name 'javaDevKit' `
            -Value ([PSCustomObject]@{ vendor = 'temurin'; version = '21' })
        $vm
    }

    function New-VmWithJdkUninstallFalse {
        $vm = New-PlainVm
        Add-Member -InputObject $vm -MemberType NoteProperty -Name 'javaDevKit' `
            -Value ([PSCustomObject]@{
                vendor    = 'temurin'
                version   = '21'
                uninstall = $false
            })
        $vm
    }

    function New-VmWithJdkUninstall {
        $vm = New-PlainVm
        Add-Member -InputObject $vm -MemberType NoteProperty -Name 'javaDevKit' `
            -Value ([PSCustomObject]@{
                vendor    = 'temurin'
                version   = '21'
                uninstall = $true
            })
        $vm
    }

    function New-VmWithFiles {
        $vm = New-PlainVm
        Add-Member -InputObject $vm -MemberType NoteProperty -Name 'files' -Value @(
            [PSCustomObject]@{ source = 'C:\src\a'; target = '/opt/a' }
        )
        $vm
    }

    function New-VmWithBulkFile {
        $vm = New-PlainVm
        Add-Member -InputObject $vm -MemberType NoteProperty -Name 'files' -Value @(
            [PSCustomObject]@{ pattern = 'C:\jars\*.jar'; targetDir = '/opt/ci-jars' }
        )
        $vm
    }

    function New-VmWithBulkFileAllSwitches {
        $vm = New-PlainVm
        Add-Member -InputObject $vm -MemberType NoteProperty -Name 'files' -Value @(
            [PSCustomObject]@{
                pattern              = 'C:\jars\*.jar'
                targetDir            = '/opt/ci-jars'
                recurse              = $true
                preserveRelativePath = $true
            }
        )
        $vm
    }

    function New-VmWithMixedFiles {
        $vm = New-PlainVm
        Add-Member -InputObject $vm -MemberType NoteProperty -Name 'files' -Value @(
            [PSCustomObject]@{ source = 'C:\src\a'; target = '/opt/a' },
            [PSCustomObject]@{ pattern = 'C:\jars\*.jar'; targetDir = '/opt/ci-jars' },
            [PSCustomObject]@{ source = 'C:\src\b'; target = '/opt/b' }
        )
        $vm
    }
}

AfterAll {
    foreach ($name in @(
            'Invoke-WithVmFileServer', 'New-VmSshClient',
            'Invoke-SshClientCommand', 'Install-Jdk', 'Uninstall-Jdk',
            'Copy-VmFiles', 'Copy-VmFilesByPattern',
            'Reset-PostProvCallLog')) {
        Remove-Item -Path "function:global:$name" -ErrorAction SilentlyContinue
    }
    foreach ($name in @(
            '_PostProv_Calls', '_PostProv_FakeSshClient',
            '_PostProv_FakeServer', '_PostProv_SshExitStatus')) {
        Remove-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue
    }

    $priorVar = Get-Variable -Name _priorAutoLoad -Scope Script `
        -ErrorAction SilentlyContinue
    $prior = if ($null -ne $priorVar) { $priorVar.Value } else { $null }
    if ($null -eq $prior) {
        Remove-Variable -Name PSModuleAutoLoadingPreference -Scope Global `
            -ErrorAction SilentlyContinue
    } else {
        $global:PSModuleAutoLoadingPreference = $prior
    }
}

Describe 'Invoke-VmPostProvisioning' {

    BeforeEach {
        Reset-PostProvCallLog
        $global:_PostProv_SshExitStatus = 0
    }

    Context 'no opt-in fields' {

        It 'is a no-op when neither files nor javaDevKit is set' {
            Invoke-VmPostProvisioning -Vm (New-PlainVm)

            $global:_PostProv_Calls['Invoke-WithVmFileServer'].Count | Should -Be 0
            $global:_PostProv_Calls['New-VmSshClient'].Count         | Should -Be 0
        }

        It 'is a no-op when files is an empty array' {
            $vm = New-PlainVm
            Add-Member -InputObject $vm -MemberType NoteProperty -Name 'files' -Value @()

            Invoke-VmPostProvisioning -Vm $vm

            $global:_PostProv_Calls['Invoke-WithVmFileServer'].Count | Should -Be 0
        }
    }

    Context 'one or more opt-in fields' {

        It 'opens the file server with the VM IP' {
            Invoke-VmPostProvisioning -Vm (New-VmWithJdk)

            $calls = $global:_PostProv_Calls['Invoke-WithVmFileServer']
            $calls.Count | Should -Be 1
            $calls[0].VmIpAddress | Should -Be '192.168.1.10'
        }

        It 'connects SSH as the admin user with the VM password' {
            Invoke-VmPostProvisioning -Vm (New-VmWithJdk)

            $calls = $global:_PostProv_Calls['New-VmSshClient']
            $calls.Count | Should -Be 1
            $calls[0].IpAddress | Should -Be '192.168.1.10'
            $calls[0].Username  | Should -Be 'admin'
            $calls[0].Password  | Should -Be 'unit-test-password-not-real'
        }

        It 'waits for cloud-init exactly once, capped with timeout(1)' {
            Invoke-VmPostProvisioning -Vm (New-VmWithJdk)

            $calls = $global:_PostProv_Calls['Invoke-SshClientCommand']
            $calls.Count | Should -Be 1
            $calls[0].Command | Should -Match '^timeout \d+ cloud-init status --wait'
        }

        It 'dispatches Install-Jdk (not Uninstall-Jdk) when javaDevKit has no uninstall flag' {
            Invoke-VmPostProvisioning -Vm (New-VmWithJdk)
            $global:_PostProv_Calls['Install-Jdk'].Count   | Should -Be 1
            $global:_PostProv_Calls['Uninstall-Jdk'].Count | Should -Be 0
        }

        It 'dispatches Install-Jdk (not Uninstall-Jdk) when uninstall = $false' {
            # Explicit false must behave like absence - removing the flag
            # is just as valid as flipping it.
            Invoke-VmPostProvisioning -Vm (New-VmWithJdkUninstallFalse)
            $global:_PostProv_Calls['Install-Jdk'].Count   | Should -Be 1
            $global:_PostProv_Calls['Uninstall-Jdk'].Count | Should -Be 0
        }

        It 'dispatches Uninstall-Jdk (not Install-Jdk) when uninstall = $true' {
            Invoke-VmPostProvisioning -Vm (New-VmWithJdkUninstall)
            $global:_PostProv_Calls['Uninstall-Jdk'].Count | Should -Be 1
            $global:_PostProv_Calls['Install-Jdk'].Count   | Should -Be 0
        }

        It 'still opens the file server when uninstall = $true (orchestrator owns transport)' {
            # The file server lifecycle is the orchestrator's; the uninstall
            # step does not stage anything but the orchestrator still pays
            # the (cheap) open + close since other steps in the same run
            # (e.g. files) may need it.
            Invoke-VmPostProvisioning -Vm (New-VmWithJdkUninstall)
            $global:_PostProv_Calls['Invoke-WithVmFileServer'].Count | Should -Be 1
        }

        It 'does NOT dispatch Install-Jdk or Uninstall-Jdk when javaDevKit is absent' {
            Invoke-VmPostProvisioning -Vm (New-VmWithFiles)
            $global:_PostProv_Calls['Install-Jdk'].Count   | Should -Be 0
            $global:_PostProv_Calls['Uninstall-Jdk'].Count | Should -Be 0
        }

        It 'runs Copy-VmFiles before Uninstall-Jdk when both are set' {
            $vm = New-VmWithJdkUninstall
            Add-Member -InputObject $vm -MemberType NoteProperty -Name 'files' -Value @(
                [PSCustomObject]@{ source = 'C:\src\a'; target = '/opt/a' }
            )

            $originalCopy   = ${function:global:Copy-VmFiles}
            $originalUninst = ${function:global:Uninstall-Jdk}
            $global:_PostProv_Order = @()
            ${function:global:Copy-VmFiles}   = { param($SshClient, $Server, $Entries) $global:_PostProv_Order += 'files' }
            ${function:global:Uninstall-Jdk}  = { param($SshClient, $Vm)               $global:_PostProv_Order += 'jdk-uninstall' }
            try {
                Invoke-VmPostProvisioning -Vm $vm
                $global:_PostProv_Order | Should -Be @('files', 'jdk-uninstall')
            }
            finally {
                ${function:global:Copy-VmFiles}  = $originalCopy
                ${function:global:Uninstall-Jdk} = $originalUninst
                Remove-Variable -Name _PostProv_Order -Scope Global -ErrorAction SilentlyContinue
            }
        }

        It 'dispatches Copy-VmFiles when files is set, passing -Entries' {
            Invoke-VmPostProvisioning -Vm (New-VmWithFiles)

            $calls = $global:_PostProv_Calls['Copy-VmFiles']
            $calls.Count | Should -Be 1
            # Orchestrator must translate $Vm.files (source/target lowercase)
            # into the module's Source/Target entry shape.
            @($calls[0].Entries).Count    | Should -Be 1
            $calls[0].Entries[0].Source   | Should -Be 'C:\src\a'
            $calls[0].Entries[0].Target   | Should -Be '/opt/a'
        }

        It 'does NOT dispatch Copy-VmFiles when files is absent' {
            Invoke-VmPostProvisioning -Vm (New-VmWithJdk)
            $global:_PostProv_Calls['Copy-VmFiles'].Count          | Should -Be 0
            $global:_PostProv_Calls['Copy-VmFilesByPattern'].Count | Should -Be 0
        }

        It 'dispatches Copy-VmFilesByPattern (not Copy-VmFiles) for a bulk entry' {
            # Defaults for optional booleans are applied at the dispatch
            # site, not in the validator, so an entry without them must
            # still surface as $false to the transport.
            Invoke-VmPostProvisioning -Vm (New-VmWithBulkFile)

            $bulk = $global:_PostProv_Calls['Copy-VmFilesByPattern']
            $bulk.Count                  | Should -Be 1
            $bulk[0].Pattern             | Should -Be 'C:\jars\*.jar'
            $bulk[0].TargetDir           | Should -Be '/opt/ci-jars'
            $bulk[0].Recurse             | Should -Be $false
            $bulk[0].PreserveRelativePath | Should -Be $false
            $global:_PostProv_Calls['Copy-VmFiles'].Count | Should -Be 0
        }

        It 'forwards recurse / preserveRelativePath when set on a bulk entry' {
            Invoke-VmPostProvisioning -Vm (New-VmWithBulkFileAllSwitches)

            $bulk = $global:_PostProv_Calls['Copy-VmFilesByPattern']
            $bulk.Count                   | Should -Be 1
            $bulk[0].Recurse              | Should -Be $true
            $bulk[0].PreserveRelativePath | Should -Be $true
        }

        It 'dispatches mixed [single, bulk, single] entries in JSON order' {
            # JSON order is the contract the dispatch loop preserves; both
            # transports share the same SSH session, so there is no
            # batching win to chase by grouping by form.
            $originalCopy = ${function:global:Copy-VmFiles}
            $originalBulk = ${function:global:Copy-VmFilesByPattern}
            $global:_PostProv_Order = @()
            ${function:global:Copy-VmFiles} = {
                param($SshClient, $Server, $Entries)
                $global:_PostProv_Order += "single:$($Entries[0].Source)"
            }
            ${function:global:Copy-VmFilesByPattern} = {
                param($SshClient, $Server, $Pattern, $TargetDir,
                      [switch]$Recurse, [switch]$PreserveRelativePath)
                $global:_PostProv_Order += "bulk:$Pattern"
            }
            try {
                Invoke-VmPostProvisioning -Vm (New-VmWithMixedFiles)
                $global:_PostProv_Order | Should -Be @(
                    'single:C:\src\a',
                    'bulk:C:\jars\*.jar',
                    'single:C:\src\b'
                )
            }
            finally {
                ${function:global:Copy-VmFiles}          = $originalCopy
                ${function:global:Copy-VmFilesByPattern} = $originalBulk
                Remove-Variable -Name _PostProv_Order -Scope Global -ErrorAction SilentlyContinue
            }
        }

        It 'runs files entries before Install-Jdk when both a bulk entry and javaDevKit are set' {
            $vm = New-VmWithJdk
            Add-Member -InputObject $vm -MemberType NoteProperty -Name 'files' -Value @(
                [PSCustomObject]@{ pattern = 'C:\jars\*.jar'; targetDir = '/opt/ci-jars' }
            )

            $originalBulk = ${function:global:Copy-VmFilesByPattern}
            $originalInst = ${function:global:Install-Jdk}
            $global:_PostProv_Order = @()
            ${function:global:Copy-VmFilesByPattern} = {
                param($SshClient, $Server, $Pattern, $TargetDir,
                      [switch]$Recurse, [switch]$PreserveRelativePath)
                $global:_PostProv_Order += 'files-bulk'
            }
            ${function:global:Install-Jdk} = {
                param($SshClient, $Server, $Vm)
                $global:_PostProv_Order += 'jdk'
            }
            try {
                Invoke-VmPostProvisioning -Vm $vm
                $global:_PostProv_Order | Should -Be @('files-bulk', 'jdk')
            }
            finally {
                ${function:global:Copy-VmFilesByPattern} = $originalBulk
                ${function:global:Install-Jdk}           = $originalInst
                Remove-Variable -Name _PostProv_Order -Scope Global -ErrorAction SilentlyContinue
            }
        }

        It 'propagates Copy-VmFilesByPattern failures and still disposes the SSH client' {
            # Simulates the resolver's zero-match / collision errors, which
            # throw before any SSH I/O for the entry. The orchestrator's
            # finally block must still tear down the SSH session.
            $vm = New-VmWithBulkFile
            $originalBulk = ${function:global:Copy-VmFilesByPattern}
            $script:_DisposedClient = $null
            $global:_PostProv_FakeSshClient | Add-Member -MemberType ScriptMethod `
                -Name 'Dispose' -Force -Value { $script:_DisposedClient = $true }
            ${function:global:Copy-VmFilesByPattern} = {
                param($SshClient, $Server, $Pattern, $TargetDir,
                      [switch]$Recurse, [switch]$PreserveRelativePath)
                throw "resolver: pattern '$Pattern' matched zero files"
            }
            try {
                { Invoke-VmPostProvisioning -Vm $vm } |
                    Should -Throw -ExpectedMessage '*matched zero files*'
                $script:_DisposedClient | Should -Be $true
            }
            finally {
                ${function:global:Copy-VmFilesByPattern} = $originalBulk
                $global:_PostProv_FakeSshClient | Add-Member -MemberType ScriptMethod `
                    -Name 'Dispose' -Force -Value {}
                Remove-Variable -Name _DisposedClient -Scope Script -ErrorAction SilentlyContinue
            }
        }

        It 'dispatches Copy-VmFiles before Install-Jdk when both are set' {
            # Stylistic ordering only - steps are self-contained, but the
            # orchestrator commits to this order so output is predictable.
            $vm = New-VmWithJdk
            Add-Member -InputObject $vm -MemberType NoteProperty -Name 'files' -Value @(
                [PSCustomObject]@{ source = 'C:\src\a'; target = '/opt/a' }
            )

            # Replace the two step stubs with order-recording versions for
            # this test only. ${function:global:Foo} yields the function's
            # scriptblock directly; assigning a new scriptblock back
            # replaces the function body in-place.
            $originalCopy = ${function:global:Copy-VmFiles}
            $originalInst = ${function:global:Install-Jdk}
            $global:_PostProv_Order = @()
            ${function:global:Copy-VmFiles} = { param($SshClient, $Server, $Entries) $global:_PostProv_Order += 'files' }
            ${function:global:Install-Jdk}  = { param($SshClient, $Server, $Vm)      $global:_PostProv_Order += 'jdk' }
            try {
                Invoke-VmPostProvisioning -Vm $vm
                $global:_PostProv_Order | Should -Be @('files', 'jdk')
            }
            finally {
                ${function:global:Copy-VmFiles} = $originalCopy
                ${function:global:Install-Jdk}  = $originalInst
                Remove-Variable -Name _PostProv_Order -Scope Global -ErrorAction SilentlyContinue
            }
        }

        It 'still dispatches steps when cloud-init wait reports non-zero' {
            # Non-zero cloud-init status is most often unrelated to our
            # steps - dispatch and let downstream assertions catch real
            # problems.
            $global:_PostProv_SshExitStatus = 1

            Invoke-VmPostProvisioning -Vm (New-VmWithJdk)

            $global:_PostProv_Calls['Install-Jdk'].Count | Should -Be 1
        }
    }
}
