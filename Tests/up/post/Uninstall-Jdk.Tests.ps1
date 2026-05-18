BeforeAll {
    # SSH cmdlet is stubbed permissively before dot-source so the
    # function-under-test resolves it at parse time. Tests Mock it
    # individually for behavioural assertions.
    function Invoke-SshClientCommand { param($SshClient, $Command) }
    # Stubbed so the file-server-not-called assertion can Mock it.
    # Uninstall-Jdk itself never references this cmdlet.
    function Add-VmFileServerFile    { param($Server, $LocalPath) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\post\Uninstall-Jdk.ps1"

    # The orchestrator hands Uninstall-Jdk a live SshClient. Tests use a
    # stand-in that the function never inspects beyond passing it through.
    $script:FakeSshClient = [PSCustomObject]@{ }

    function New-JdkVm {
        [PSCustomObject]@{
            vmName     = 'node-01'
            javaDevKit = [PSCustomObject]@{
                vendor    = 'temurin'
                version   = '21'
                uninstall = $true
            }
        }
    }
}

Describe 'Uninstall-Jdk' {

    BeforeEach {
        Mock Invoke-SshClientCommand {
            [PSCustomObject]@{ ExitStatus = 0; Output = ''; Error = '' }
        }
    }

    It 'targets /opt/jdk-{vendor}-* with nullglob (empty match is a no-op)' {
        Uninstall-Jdk -SshClient $script:FakeSshClient -Vm (New-JdkVm)

        Should -Invoke Invoke-SshClientCommand -Times 1 -Exactly -ParameterFilter {
            $Command -match 'shopt -s nullglob' -and
            $Command -match [regex]::Escape('/opt/jdk-"$vendor"-*') -and
            $Command -match "vendor='temurin'"
        }
    }

    It 'removes /etc/profile.d/jdk.sh unconditionally' {
        # Outside any glob loop - runs even when no install dir matched, so
        # an orphaned profile snippet is still cleaned up.
        Uninstall-Jdk -SshClient $script:FakeSshClient -Vm (New-JdkVm)

        Should -Invoke Invoke-SshClientCommand -ParameterFilter {
            $Command -match 'sudo rm -f /etc/profile\.d/jdk\.sh'
        }
    }

    It 'prunes /usr/local/bin symlinks pointing into the removed install dir' {
        Uninstall-Jdk -SshClient $script:FakeSshClient -Vm (New-JdkVm)

        Should -Invoke Invoke-SshClientCommand -ParameterFilter {
            $Command -match 'for link in /usr/local/bin/\*'      -and
            $Command -match '\[ -L "\$link" \]'                  -and
            $Command -match 'readlink -f "\$link"'               -and
            $Command -match 'sudo rm -f "\$link"'
        }
    }

    It 'prunes symlinks BEFORE removing the install dir (readlink resolves)' {
        # After rm -rf, readlink -f on the symlink would resolve to an
        # orphaned path and we would need string surgery to recover which
        # links belonged to the JDK. Doing the prune first keeps the
        # case-match against "$d"/* honest.
        Uninstall-Jdk -SshClient $script:FakeSshClient -Vm (New-JdkVm)

        Should -Invoke Invoke-SshClientCommand -ParameterFilter {
            $linkIdx = $Command.IndexOf('rm -f "$link"')
            $dirIdx  = $Command.IndexOf('rm -rf "$d"')
            $linkIdx -ge 0 -and $dirIdx -ge 0 -and $linkIdx -lt $dirIdx
        }
    }

    It 'does not stage any tarball (no file-server helper invoked)' {
        # Removal needs no host artefact; the orchestrator still opens a
        # file server (cheap, may be used by the files step in the same
        # run) but Uninstall-Jdk itself must not call into it.
        Mock Add-VmFileServerFile { throw 'Uninstall-Jdk must not stage files' }

        { Uninstall-Jdk -SshClient $script:FakeSshClient -Vm (New-JdkVm) } |
            Should -Not -Throw
        Should -Not -Invoke Add-VmFileServerFile
    }

    It 'does not wait for cloud-init (the orchestrator has already done that)' {
        Uninstall-Jdk -SshClient $script:FakeSshClient -Vm (New-JdkVm)

        Should -Not -Invoke Invoke-SshClientCommand -ParameterFilter {
            $Command -match 'cloud-init'
        }
    }

    It 'throws when the uninstall command exits non-zero, naming the VM' {
        Mock Invoke-SshClientCommand {
            [PSCustomObject]@{
                ExitStatus = 2
                Output     = ''
                Error      = 'permission denied'
            }
        }

        { Uninstall-Jdk -SshClient $script:FakeSshClient -Vm (New-JdkVm) } |
            Should -Throw -ExpectedMessage '*JDK uninstall failed on node-01*'
    }
}
