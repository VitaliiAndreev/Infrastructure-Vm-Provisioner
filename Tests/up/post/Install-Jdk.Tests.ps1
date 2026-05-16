BeforeAll {
    # File-server / SSH cmdlets are stubbed permissively before dot-source so
    # the function-under-test resolves them at parse time. Tests Mock them
    # individually for behavioural assertions.
    function Add-VmFileServerFile    { param($Server, $LocalPath) }
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\post\Install-Jdk.ps1"

    # The orchestrator hands Install-Jdk a live SshClient and Server. Tests
    # use stand-ins that the function only inspects via duck-typing
    # (Server.BaseUrl is unused inside Install-Jdk - the URL comes from
    # Add-VmFileServerFile's return value).
    $script:FakeSshClient = [PSCustomObject]@{ }
    $script:FakeServer    = [PSCustomObject]@{ BaseUrl = 'http://192.168.1.1:8745' }

    # VM fixture shaped like what Invoke-JdkAcquisition publishes.
    function New-JdkVm {
        $vm = [PSCustomObject]@{
            vmName     = 'node-01'
            javaDevKit = [PSCustomObject]@{
                vendor  = 'temurin'
                version = '21'
            }
        }
        Add-Member -InputObject $vm -MemberType NoteProperty `
            -Name '_jdkTarballPath' `
            -Value 'C:\cache\jdk-temurin-21-linux-x64.tar.gz'
        Add-Member -InputObject $vm -MemberType NoteProperty `
            -Name '_jdkResolvedVersion' -Value '21.0.6+7'
        $vm
    }
}

Describe 'Install-Jdk' {

    BeforeEach {
        # Default mocks: file server returns a deterministic URL; SSH command
        # succeeds with empty output. Individual tests override SSH for the
        # failure-path case.
        Mock Add-VmFileServerFile {
            "$($Server.BaseUrl)/$(Split-Path -Leaf $LocalPath)"
        }
        Mock Invoke-SshClientCommand {
            [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
        }
    }

    It 'stages the prefetched tarball via the file server' {
        Install-Jdk -SshClient $script:FakeSshClient `
                    -Server    $script:FakeServer `
                    -Vm        (New-JdkVm)

        Should -Invoke Add-VmFileServerFile -Times 1 -Exactly -ParameterFilter {
            $LocalPath -eq 'C:\cache\jdk-temurin-21-linux-x64.tar.gz'
        }
    }

    It 'extracts into /opt/jdk-{vendor}-{resolvedVersion} with strip-components=1' {
        Install-Jdk -SshClient $script:FakeSshClient `
                    -Server    $script:FakeServer `
                    -Vm        (New-JdkVm)

        Should -Invoke Invoke-SshClientCommand -ParameterFilter {
            $Command -match [regex]::Escape('/opt/jdk-temurin-21.0.6+7') -and
            $Command -match '--strip-components=1'
        }
    }

    It 'is idempotent via a release-file guard' {
        Install-Jdk -SshClient $script:FakeSshClient `
                    -Server    $script:FakeServer `
                    -Vm        (New-JdkVm)

        Should -Invoke Invoke-SshClientCommand -ParameterFilter {
            $Command -match 'release'
        }
    }

    It 'writes /etc/profile.d/jdk.sh' {
        Install-Jdk -SshClient $script:FakeSshClient `
                    -Server    $script:FakeServer `
                    -Vm        (New-JdkVm)

        Should -Invoke Invoke-SshClientCommand -ParameterFilter {
            $Command -match '/etc/profile\.d/jdk\.sh'
        }
    }

    It 'symlinks every JDK binary into /usr/local/bin (non-login PATH)' {
        # /etc/profile.d/jdk.sh covers login shells only. Non-login
        # shells (sshd command exec, systemd services) need the
        # binaries on PATH via /usr/local/bin.
        Install-Jdk -SshClient $script:FakeSshClient `
                    -Server    $script:FakeServer `
                    -Vm        (New-JdkVm)

        Should -Invoke Invoke-SshClientCommand -ParameterFilter {
            $Command -match 'for f in.*/bin/\*' -and
            $Command -match 'sudo ln -sf .* /usr/local/bin/'
        }
    }

    It 'pipes curl from the staged URL into tar (no intermediate file)' {
        Install-Jdk -SshClient $script:FakeSshClient `
                    -Server    $script:FakeServer `
                    -Vm        (New-JdkVm)

        Should -Invoke Invoke-SshClientCommand -ParameterFilter {
            # Streaming pattern: curl ... | tar -xzf -
            $Command -match 'curl[^|]+\|\s*sudo tar -xzf -'
        }
    }

    It 'does not wait for cloud-init (the orchestrator has already done that)' {
        # Cloud-init wait is the orchestrator's responsibility - duplicating
        # it here would couple the step to transport concerns it does not own.
        Install-Jdk -SshClient $script:FakeSshClient `
                    -Server    $script:FakeServer `
                    -Vm        (New-JdkVm)

        Should -Not -Invoke Invoke-SshClientCommand -ParameterFilter {
            $Command -match 'cloud-init'
        }
    }

    It 'throws when the install command exits non-zero' {
        Mock Invoke-SshClientCommand {
            [PSCustomObject]@{
                ExitStatus = 2
                Output     = 'tar: bad archive'
                Error      = ''
            }
        }

        { Install-Jdk -SshClient $script:FakeSshClient `
                      -Server    $script:FakeServer `
                      -Vm        (New-JdkVm) } |
            Should -Throw -ExpectedMessage '*JDK install failed on node-01*'
    }
}
