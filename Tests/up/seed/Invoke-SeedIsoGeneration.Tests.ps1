BeforeAll {
    # New-SeedIso lives in iso.ps1 and depends on IMAPI2 COM objects that are
    # unavailable in a headless test environment. Stub it before dot-sourcing
    # generate-seed-iso.ps1 so the function reference resolves without error.
    function New-SeedIso { param($OutputPath, $Files) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\seed\generate-seed-iso.ps1"

    function New-TestVm {
        [PSCustomObject]@{
            vmName       = 'node-01'
            vmConfigPath = 'E:\a_VMs\Hyper-V\Config'
            username     = 'admin'
            password     = 'P@ssw0rd'
            ipAddress    = '192.168.1.10'
            subnetMask   = '24'
            gateway      = '192.168.1.1'
            dns          = '8.8.8.8'
        }
    }
}

Describe 'Invoke-SeedIsoGeneration' {

    # ------------------------------------------------------------------
    Context 'vmConfigPath setup' {
    # ------------------------------------------------------------------

        It 'creates vmConfigPath directory when it does not exist' {
            Mock Test-Path { $false }
            Mock New-Item {}
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-Item -Times 1 -Exactly -ParameterFilter {
                $ItemType -eq 'Directory' -and $Path -eq 'E:\a_VMs\Hyper-V\Config'
            }
        }

        It 'does not create vmConfigPath when it already exists' {
            Mock Test-Path { $true }
            Mock New-Item {}
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-Item -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'meta-data content' {
    # ------------------------------------------------------------------

        It 'sets instance-id to vmName' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['meta-data'] -match 'instance-id: node-01'
            }
        }

        It 'sets local-hostname to vmName' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['meta-data'] -match 'local-hostname: node-01'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'user-data content' {
    # ------------------------------------------------------------------

        It 'includes the configured username' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match 'name: "admin"'
            }
        }

        It 'includes the configured password' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match 'plain_text_passwd: "P@ssw0rd"'
            }
        }

        It 'escapes backslashes in username for YAML double-quoted strings' {
            # A domain\user credential would break YAML without escaping the
            # backslash. The -replace '\\', '\\\\' in the source doubles it.
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            $vm = [PSCustomObject]@{
                vmName       = 'node-01'
                vmConfigPath = 'E:\a_VMs\Hyper-V\Config'
                username     = 'domain\admin'
                password     = 'P@ssw0rd'
                ipAddress    = '192.168.1.10'
                subnetMask   = '24'
                gateway      = '192.168.1.1'
                dns          = '8.8.8.8'
            }
            Invoke-SeedIsoGeneration -Vm $vm
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match ([regex]::Escape('name: "domain\\admin"'))
            }
        }

        It 'escapes double quotes in password for YAML double-quoted strings' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            $vm = [PSCustomObject]@{
                vmName       = 'node-01'
                vmConfigPath = 'E:\a_VMs\Hyper-V\Config'
                username     = 'admin'
                password     = 'P@ss"word'
                ipAddress    = '192.168.1.10'
                subnetMask   = '24'
                gateway      = '192.168.1.1'
                dns          = '8.8.8.8'
            }
            Invoke-SeedIsoGeneration -Vm $vm
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match ([regex]::Escape('plain_text_passwd: "P@ss\"word"'))
            }
        }

        It 'sets ssh_pwauth to true' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match 'ssh_pwauth: true'
            }
        }

        It 'includes openssh-server in the package list' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['user-data'] -match 'openssh-server'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'network-config content' {
    # ------------------------------------------------------------------

        It 'includes the IP address and subnet mask in CIDR notation' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['network-config'] -match '192\.168\.1\.10/24'
            }
        }

        It 'includes the gateway as the default route' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['network-config'] -match 'via: 192\.168\.1\.1'
            }
        }

        It 'includes the DNS server address' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['network-config'] -match '8\.8\.8\.8'
            }
        }

        It 'matches on hv_netvsc driver so the config is NIC-name-independent' {
            # Matching by driver rather than interface name (eth0, enp0s*) means
            # the config works regardless of how the kernel names the NIC across
            # Ubuntu versions or Hyper-V generations.
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files['network-config'] -match 'driver: hv_netvsc'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'ISO file structure' {
    # ------------------------------------------------------------------

        It 'passes all three required cloud-init file names to New-SeedIso' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $Files.ContainsKey('meta-data')      -and
                $Files.ContainsKey('user-data')      -and
                $Files.ContainsKey('network-config')
            }
        }

        It 'writes the ISO to vmConfigPath/{vmName}-seed.iso' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            Invoke-SeedIsoGeneration -Vm (New-TestVm)
            Should -Invoke New-SeedIso -ParameterFilter {
                $OutputPath -eq 'E:\a_VMs\Hyper-V\Config\node-01-seed.iso'
            }
        }
    }

    # ------------------------------------------------------------------
    Context '_seedIsoPath output' {
    # ------------------------------------------------------------------

        It 'sets _seedIsoPath on the VM object after writing the ISO' {
            Mock Test-Path { $true }
            Mock New-SeedIso {}
            $vm = New-TestVm
            Invoke-SeedIsoGeneration -Vm $vm
            $vm._seedIsoPath | Should -Be 'C:\VMs\node-01\node-01-seed.iso'
        }
    }
}
