BeforeAll {
    # Stub the per-software acquirer so the orchestrator's dispatch can
    # be asserted in isolation. Behaviour for Invoke-JdkAcquisition itself
    # lives in Tests/up/jdk/Invoke-JdkAcquisition.Tests.ps1.
    function Invoke-JdkAcquisition { param($Vm) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\acquire\Invoke-VmAcquisitions.ps1"

    function New-PlainVm {
        [PSCustomObject]@{ vmName = 'node-01' }
    }

    function New-VmWithJdk {
        [PSCustomObject]@{
            vmName     = 'node-01'
            javaDevKit = [PSCustomObject]@{ vendor = 'temurin'; version = '21' }
        }
    }

    function New-VmWithJdkUninstallFalse {
        [PSCustomObject]@{
            vmName     = 'node-01'
            javaDevKit = [PSCustomObject]@{
                vendor    = 'temurin'
                version   = '21'
                uninstall = $false
            }
        }
    }

    function New-VmWithJdkUninstallTrue {
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

Describe 'Invoke-VmAcquisitions' {

    Context 'no opt-in fields' {

        It 'is a no-op when no acquirer fields are set' {
            Mock Invoke-JdkAcquisition {}
            Invoke-VmAcquisitions -Vm (New-PlainVm)
            Should -Invoke Invoke-JdkAcquisition -Times 0
        }
    }

    Context 'javaDevKit present' {

        It 'dispatches Invoke-JdkAcquisition exactly once with the VM' {
            Mock Invoke-JdkAcquisition {}
            Invoke-VmAcquisitions -Vm (New-VmWithJdk)
            Should -Invoke Invoke-JdkAcquisition -Times 1 -Exactly `
                -ParameterFilter { $Vm.vmName -eq 'node-01' }
        }

        It 'dispatches Invoke-JdkAcquisition when uninstall is explicitly $false' {
            Mock Invoke-JdkAcquisition {}
            Invoke-VmAcquisitions -Vm (New-VmWithJdkUninstallFalse)
            Should -Invoke Invoke-JdkAcquisition -Times 1 -Exactly `
                -ParameterFilter { $Vm.vmName -eq 'node-01' }
        }

        It 'skips Invoke-JdkAcquisition when uninstall is $true' {
            Mock Invoke-JdkAcquisition {}
            Invoke-VmAcquisitions -Vm (New-VmWithJdkUninstallTrue)
            Should -Invoke Invoke-JdkAcquisition -Times 0
        }
    }
}
