BeforeAll {
    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\up\jdk\Resolve-AdoptiumRelease.ps1"

    # ------------------------------------------------------------------
    # Builds an Adoptium-shaped release object. Only the fields the
    # resolver inspects are populated - keeps fixtures focused.
    # ------------------------------------------------------------------
    function New-AdoptiumRelease {
        param(
            [int]    $Major,
            [int]    $Minor,
            [int]    $Security,
            [int]    $Build,
            [string] $Checksum   = 'sha-default',
            [string] $Link       = 'https://example.invalid/jdk.tar.gz',
            [string] $ArchiveName = 'OpenJDK-jdk_x64_linux_hotspot.tar.gz'
        )
        return [pscustomobject]@{
            release_name = "jdk-$Major.$Minor.$Security+$Build"
            version_data = [pscustomobject]@{
                major           = $Major
                minor           = $Minor
                security        = $Security
                build           = $Build
                openjdk_version = "$Major.$Minor.$Security+$Build"
            }
            binaries     = @(
                [pscustomobject]@{
                    architecture = 'x64'
                    os           = 'linux'
                    image_type   = 'jdk'
                    package      = [pscustomobject]@{
                        name     = $ArchiveName
                        link     = $Link
                        checksum = $Checksum
                    }
                }
            )
        }
    }

    # Canonical fixture: three GA releases of feature 21 in DESC order, as
    # the Adoptium API would return them.
    function Get-Fixture21 {
        return @(
            New-AdoptiumRelease -Major 21 -Minor 0 -Security 6 -Build 7  `
                -Checksum 'sha-21.0.6+7' -Link 'https://example.invalid/21.0.6+7.tar.gz' `
                -ArchiveName 'OpenJDK21U-jdk_x64_linux_hotspot_21.0.6_7.tar.gz'
            New-AdoptiumRelease -Major 21 -Minor 0 -Security 5 -Build 11 `
                -Checksum 'sha-21.0.5+11' -Link 'https://example.invalid/21.0.5+11.tar.gz' `
                -ArchiveName 'OpenJDK21U-jdk_x64_linux_hotspot_21.0.5_11.tar.gz'
            New-AdoptiumRelease -Major 21 -Minor 0 -Security 4 -Build 7  `
                -Checksum 'sha-21.0.4+7' -Link 'https://example.invalid/21.0.4+7.tar.gz' `
                -ArchiveName 'OpenJDK21U-jdk_x64_linux_hotspot_21.0.4_7.tar.gz'
        )
    }
}

Describe 'Resolve-AdoptiumRelease' {

    # ------------------------------------------------------------------
    Context 'version granularity: major only' {
    # ------------------------------------------------------------------

        It 'queries the API with page_size 1 and returns the single newest GA' {
            Mock Invoke-AdoptiumFeatureReleases {
                param($Major, $PageSize)
                $Major    | Should -Be 21
                $PageSize | Should -Be 1
                # API was asked for DESC + page_size=1, so it returns one item.
                return ,(Get-Fixture21)[0]
            }

            $result = Resolve-AdoptiumRelease -Vendor 'temurin' -Version '21'

            $result.ResolvedVersion | Should -Be '21.0.6+7'
            $result.Sha256          | Should -Be 'sha-21.0.6+7'
            $result.DownloadUrl     | Should -Be 'https://example.invalid/21.0.6+7.tar.gz'
            $result.ArchiveName     | Should -Be 'OpenJDK21U-jdk_x64_linux_hotspot_21.0.6_7.tar.gz'
        }
    }

    # ------------------------------------------------------------------
    Context 'version granularity: major.minor' {
    # ------------------------------------------------------------------

        It 'filters mixed minor lines down to the requested minor and picks the highest' {
            # Inject a 21.1.0+1 release so the filter has something to drop.
            Mock Invoke-AdoptiumFeatureReleases {
                param($Major, $PageSize)
                $Major    | Should -Be 21
                $PageSize | Should -BeGreaterThan 1
                return @(
                    New-AdoptiumRelease -Major 21 -Minor 1 -Security 0 -Build 1 `
                        -Checksum 'sha-21.1.0+1'
                    (Get-Fixture21)[0]   # 21.0.6+7
                    (Get-Fixture21)[1]   # 21.0.5+11
                )
            }

            $result = Resolve-AdoptiumRelease -Vendor 'temurin' -Version '21.0'

            $result.ResolvedVersion | Should -Be '21.0.6+7'
            $result.Sha256          | Should -Be 'sha-21.0.6+7'
        }
    }

    # ------------------------------------------------------------------
    Context 'version granularity: major.minor.patch' {
    # ------------------------------------------------------------------

        It 'filters to the requested patch and picks the highest build' {
            Mock Invoke-AdoptiumFeatureReleases {
                return @(
                    New-AdoptiumRelease -Major 21 -Minor 0 -Security 5 -Build 11 `
                        -Checksum 'sha-21.0.5+11'
                    New-AdoptiumRelease -Major 21 -Minor 0 -Security 5 -Build 9  `
                        -Checksum 'sha-21.0.5+9'
                    New-AdoptiumRelease -Major 21 -Minor 0 -Security 4 -Build 7  `
                        -Checksum 'sha-21.0.4+7'
                )
            }

            $result = Resolve-AdoptiumRelease -Vendor 'temurin' -Version '21.0.5'

            # API returns DESC-sorted, so the +11 build is first among matches.
            $result.ResolvedVersion | Should -Be '21.0.5+11'
            $result.Sha256          | Should -Be 'sha-21.0.5+11'
        }
    }

    # ------------------------------------------------------------------
    Context 'version granularity: exact major.minor.patch+build' {
    # ------------------------------------------------------------------

        It 'returns that exact entry from the API response' {
            Mock Invoke-AdoptiumFeatureReleases { return Get-Fixture21 }

            $result = Resolve-AdoptiumRelease -Vendor 'temurin' -Version '21.0.5+11'

            $result.ResolvedVersion | Should -Be '21.0.5+11'
            $result.Sha256          | Should -Be 'sha-21.0.5+11'
            $result.DownloadUrl     | Should -Be 'https://example.invalid/21.0.5+11.tar.gz'
        }
    }

    # ------------------------------------------------------------------
    Context 'zero matches' {
    # ------------------------------------------------------------------

        It 'throws with the requested version in the message when nothing matches' {
            # Mock returns only 21.0.x lines, request 21.99 -> filter empties.
            Mock Invoke-AdoptiumFeatureReleases { return Get-Fixture21 }

            { Resolve-AdoptiumRelease -Vendor 'temurin' -Version '21.99' } |
                Should -Throw -ExpectedMessage "*21.99*"
        }

        It 'throws when the API returns an empty array' {
            Mock Invoke-AdoptiumFeatureReleases { return @() }

            { Resolve-AdoptiumRelease -Vendor 'temurin' -Version '21' } |
                Should -Throw -ExpectedMessage "*no GA releases*"
        }
    }

    # ------------------------------------------------------------------
    Context 'returned hashtable shape' {
    # ------------------------------------------------------------------

        It 'returns a hashtable with all four expected keys' {
            Mock Invoke-AdoptiumFeatureReleases { return ,(Get-Fixture21)[0] }

            $result = Resolve-AdoptiumRelease -Vendor 'temurin' -Version '21'

            $result                       | Should -BeOfType [hashtable]
            $result.Keys | Sort-Object    | Should -Be @('ArchiveName', 'DownloadUrl', 'ResolvedVersion', 'Sha256')
        }
    }

    # ------------------------------------------------------------------
    Context 'vendor and version input validation' {
    # ------------------------------------------------------------------

        It 'throws when vendor is not temurin' {
            { Resolve-AdoptiumRelease -Vendor 'corretto' -Version '21' } |
                Should -Throw -ExpectedMessage "*corretto*"
        }

        It 'throws when version is not a recognised granularity' {
            { Resolve-AdoptiumRelease -Vendor 'temurin' -Version '21-LTS' } |
                Should -Throw -ExpectedMessage "*granularity*"
        }
    }
}
