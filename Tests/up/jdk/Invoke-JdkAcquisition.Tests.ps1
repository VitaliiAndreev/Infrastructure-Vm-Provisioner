BeforeAll {
    # Stub every cmdlet that touches the network or real filesystem. Stubs
    # are permissive no-ops; individual tests override with Mock. The
    # acquisition module dot-sources Resolve-AdoptiumRelease in production,
    # but the resolver is itself stubbed here so unit tests stay isolated.
    function Test-Path         { param($Path, $PathType) }
    function Get-Content       { param($Path, [switch]$Raw) }
    function Set-Content       { param($Path, $Value, $Encoding) }
    function Get-FileHash      { param($Path, $Algorithm) }
    function Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing) }
    function Remove-Item       { param($Path, [switch]$Force, $ErrorAction) }

    # Stub the resolver before dot-sourcing the acquisition script so the
    # function call inside Invoke-JdkAcquisition binds to the stub instead
    # of the real implementation (which would otherwise hit the live API).
    function Resolve-AdoptiumRelease {
        param([string] $Vendor, [string] $Version)
        return @{
            ResolvedVersion = '21.0.6+7'
            Sha256          = 'AAAA'
            DownloadUrl     = 'https://example.invalid/jdk-21.0.6+7.tar.gz'
            ArchiveName     = 'OpenJDK21U-jdk_x64_linux_hotspot_21.0.6_7.tar.gz'
        }
    }

    # The acquisition script wraps Invoke-WebRequest in Invoke-WithNetworkRetry
    # (from Infrastructure.Common). Stub it as a pass-through so unit tests
    # stay isolated from the real module - retry policy itself is covered
    # by Infrastructure.Common's own tests.
    function Invoke-WithNetworkRetry {
        param([scriptblock] $ScriptBlock, [string] $OperationName,
              [int] $MaxAttempts, [int] $InitialDelaySeconds)
        return & $ScriptBlock
    }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\jdk\Invoke-JdkAcquisition.ps1"

    # Minimal VM object. All tests use the same vhdPath / javaDevKit so the
    # cache key derived inside the function is predictable:
    #   cacheKey    = "jdk-temurin-21-linux-x64"
    #   tarballPath = "C:\VHDs\jdk-temurin-21-linux-x64.tar.gz"
    #   lockPath    = "C:\VHDs\jdk-temurin-21-linux-x64.lock.json"
    function New-TestVm {
        [PSCustomObject]@{
            vmName     = 'node-01'
            vhdPath    = 'C:\VHDs'
            javaDevKit = [PSCustomObject]@{
                vendor  = 'temurin'
                version = '21'
            }
        }
    }

    # Fixture lockfile JSON returned by the mocked Get-Content when the
    # path matches the lockfile. The resolver-stub Sha256 ('AAAA') matches
    # this on purpose so cache-hit paths can hash-compare cleanly.
    $script:LockJson = @{
        resolvedVersion = '21.0.6+7'
        sha256          = 'AAAA'
        downloadedUtc   = '2026-05-01T00:00:00.0000000Z'
        sourceUrl       = 'https://example.invalid/pinned-21.0.6+7.tar.gz'
    } | ConvertTo-Json
}

Describe 'Invoke-JdkAcquisition' {

    # ------------------------------------------------------------------
    Context 'cache hit: lockfile present, tarball hash matches' {
    # ------------------------------------------------------------------

        It 'does not call resolver or download, sets _jdkTarballPath/_jdkResolvedVersion' {
            Mock Test-Path { param($Path, $PathType)
                # Both lockfile and tarball exist.
                return $true
            }
            Mock Get-Content       { return $script:LockJson }
            Mock Get-FileHash      { return [pscustomobject]@{ Hash = 'AAAA' } }
            Mock Invoke-WebRequest { }
            Mock Set-Content       { }
            Mock Resolve-AdoptiumRelease { throw 'resolver must not be called on cache hit' }

            $vm = New-TestVm
            Invoke-JdkAcquisition -Vm $vm

            Should -Invoke Resolve-AdoptiumRelease -Times 0
            Should -Invoke Invoke-WebRequest       -Times 0
            Should -Invoke Set-Content             -Times 0  # no lockfile rewrite

            $vm._jdkTarballPath     | Should -Be 'C:\VHDs\jdk-temurin-21-linux-x64.tar.gz'
            $vm._jdkResolvedVersion | Should -Be '21.0.6+7'
        }
    }

    # ------------------------------------------------------------------
    Context 'self-heal: lockfile present but tarball missing' {
    # ------------------------------------------------------------------

        It 'downloads from lockfile.sourceUrl (not resolver) and sets _jdkTarballPath' {
            Mock Test-Path { param($Path, $PathType)
                # Lockfile yes, tarball no.
                if ($Path -match '\.lock\.json$') { return $true }
                if ($Path -match '\.tar\.gz$')    { return $false }
                return $false
            }
            Mock Get-Content       { return $script:LockJson }
            # After redownload, the hash matches the lockfile.
            Mock Get-FileHash      { return [pscustomobject]@{ Hash = 'AAAA' } }
            Mock Invoke-WebRequest { }
            Mock Resolve-AdoptiumRelease { throw 'resolver must not be called on self-heal' }

            $vm = New-TestVm
            Invoke-JdkAcquisition -Vm $vm

            Should -Invoke Resolve-AdoptiumRelease -Times 0
            Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter {
                $Uri -eq 'https://example.invalid/pinned-21.0.6+7.tar.gz'
            }
            $vm._jdkTarballPath     | Should -Be 'C:\VHDs\jdk-temurin-21-linux-x64.tar.gz'
            $vm._jdkResolvedVersion | Should -Be '21.0.6+7'
        }
    }

    # ------------------------------------------------------------------
    Context 'self-heal: lockfile present but tarball hash mismatch' {
    # ------------------------------------------------------------------

        It 'redownloads from lockfile.sourceUrl and recovers when bytes match' {
            Mock Test-Path { return $true }   # both exist
            Mock Get-Content { return $script:LockJson }

            # First hash (corruption check) is wrong; second (post-redownload)
            # is correct. Pester's Mock returns the script-block result per
            # call - use a counter to vary behaviour.
            $script:hashCalls = 0
            Mock Get-FileHash {
                $script:hashCalls++
                if ($script:hashCalls -eq 1) {
                    return [pscustomobject]@{ Hash = 'BBBB' }  # corrupt
                }
                return [pscustomobject]@{ Hash = 'AAAA' }      # after redownload
            }
            Mock Invoke-WebRequest { }
            Mock Resolve-AdoptiumRelease { throw 'resolver must not be called on self-heal' }

            $vm = New-TestVm
            Invoke-JdkAcquisition -Vm $vm

            Should -Invoke Resolve-AdoptiumRelease -Times 0
            Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter {
                $Uri -eq 'https://example.invalid/pinned-21.0.6+7.tar.gz'
            }
            $vm._jdkTarballPath | Should -Be 'C:\VHDs\jdk-temurin-21-linux-x64.tar.gz'
        }
    }

    # ------------------------------------------------------------------
    Context 'self-heal: pinned URL returns 404 / network error' {
    # ------------------------------------------------------------------

        It 'throws with a hint to delete the lockfile' {
            Mock Test-Path { param($Path, $PathType)
                if ($Path -match '\.lock\.json$') { return $true }
                return $false
            }
            Mock Get-Content { return $script:LockJson }
            Mock Get-FileHash { return [pscustomobject]@{ Hash = 'AAAA' } }
            Mock Invoke-WebRequest { throw '404 Not Found' }

            $vm = New-TestVm
            { Invoke-JdkAcquisition -Vm $vm } |
                Should -Throw -ExpectedMessage '*Delete*lock*'
        }
    }

    # ------------------------------------------------------------------
    Context 'self-heal: redownload still hash-mismatches' {
    # ------------------------------------------------------------------

        It 'throws naming both the expected and actual hashes' {
            Mock Test-Path { return $true }
            Mock Get-Content { return $script:LockJson }
            # Both hash checks return a hash that does not match 'AAAA'.
            Mock Get-FileHash { return [pscustomobject]@{ Hash = 'BBBB' } }
            Mock Invoke-WebRequest { }   # succeeds, but bytes are wrong

            $vm = New-TestVm
            $err = $null
            try   { Invoke-JdkAcquisition -Vm $vm } catch { $err = $_ }

            $err               | Should -Not -BeNullOrEmpty
            $err.ToString()    | Should -Match 'AAAA'
            $err.ToString()    | Should -Match 'BBBB'
        }
    }

    # ------------------------------------------------------------------
    Context 'true cache miss: no lockfile' {
    # ------------------------------------------------------------------

        It 'calls resolver, downloads, writes lockfile, sets _jdkTarballPath' {
            Mock Test-Path { return $false }   # nothing exists
            Mock Get-FileHash { return [pscustomobject]@{ Hash = 'AAAA' } }
            Mock Invoke-WebRequest { }
            Mock Set-Content { }
            # Pester requires an explicit Mock (not just the BeforeAll stub)
            # for Should -Invoke counting to work.
            Mock Resolve-AdoptiumRelease {
                return @{
                    ResolvedVersion = '21.0.6+7'
                    Sha256          = 'AAAA'
                    DownloadUrl     = 'https://example.invalid/jdk-21.0.6+7.tar.gz'
                    ArchiveName     = 'OpenJDK21U-jdk_x64_linux_hotspot_21.0.6_7.tar.gz'
                }
            }

            $vm = New-TestVm
            Invoke-JdkAcquisition -Vm $vm

            Should -Invoke Resolve-AdoptiumRelease -Times 1 -ParameterFilter {
                $Vendor -eq 'temurin' -and $Version -eq '21'
            }
            Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter {
                $Uri -eq 'https://example.invalid/jdk-21.0.6+7.tar.gz'
            }
            Should -Invoke Set-Content -Times 1 -ParameterFilter {
                $Path -match '\.lock\.json$'
            }
            $vm._jdkTarballPath     | Should -Be 'C:\VHDs\jdk-temurin-21-linux-x64.tar.gz'
            $vm._jdkResolvedVersion | Should -Be '21.0.6+7'
        }
    }

    # ------------------------------------------------------------------
    Context 'fresh download: hash mismatch' {
    # ------------------------------------------------------------------

        It 'throws and does not write a lockfile' {
            Mock Test-Path { return $false }
            # Resolver advertised 'AAAA' but the file hashes to 'BBBB'.
            Mock Get-FileHash { return [pscustomobject]@{ Hash = 'BBBB' } }
            Mock Invoke-WebRequest { }
            Mock Set-Content { }
            Mock Remove-Item { }

            $vm = New-TestVm
            { Invoke-JdkAcquisition -Vm $vm } |
                Should -Throw -ExpectedMessage '*hash mismatch*'

            Should -Invoke Set-Content -Times 0
        }
    }
}
