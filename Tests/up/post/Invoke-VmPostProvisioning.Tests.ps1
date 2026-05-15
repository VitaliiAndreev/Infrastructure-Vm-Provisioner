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
        'Copy-VmFiles'            = @()
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

    function global:Copy-VmFiles {
        param($SshClient, $Server, $Entries)
        $global:_PostProv_Calls['Copy-VmFiles'] += @{ Entries = $Entries }
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

    function New-VmWithFiles {
        $vm = New-PlainVm
        Add-Member -InputObject $vm -MemberType NoteProperty -Name 'files' -Value @(
            [PSCustomObject]@{ source = 'C:\src\a'; target = '/opt/a' }
        )
        $vm
    }
}

AfterAll {
    foreach ($name in @(
            'Invoke-WithVmFileServer', 'New-VmSshClient',
            'Invoke-SshClientCommand', 'Install-Jdk', 'Copy-VmFiles',
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

        It 'dispatches Install-Jdk when javaDevKit is set' {
            Invoke-VmPostProvisioning -Vm (New-VmWithJdk)
            $global:_PostProv_Calls['Install-Jdk'].Count | Should -Be 1
        }

        It 'does NOT dispatch Install-Jdk when javaDevKit is absent' {
            Invoke-VmPostProvisioning -Vm (New-VmWithFiles)
            $global:_PostProv_Calls['Install-Jdk'].Count | Should -Be 0
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
            $global:_PostProv_Calls['Copy-VmFiles'].Count | Should -Be 0
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
