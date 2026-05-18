<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 after Resolve-AdoptiumRelease.ps1 is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-JdkAcquisition
#   Materialises a Temurin JDK tarball on the host with checksum
#   verification and a sidecar lockfile so re-provisioning is deterministic
#   and offline-safe.
#
#   Cache layout (per Vm.vhdPath):
#     jdk-{vendor}-{requestedVersion}-linux-x64.tar.gz   - the archive
#     jdk-{vendor}-{requestedVersion}-linux-x64.lock.json - the pin
#
#   Cache key uses the *requested* (not resolved) version so that two VMs
#   asking for "21" share one cache slot until the lockfile is removed.
#   The lockfile is the source of truth for "what this slot committed to" -
#   the resolver is NOT re-invoked on subsequent runs, so a "21" request
#   does not silently upgrade between provisionings.
#
#   On return, $Vm._jdkTarballPath and $Vm._jdkResolvedVersion are set via
#   Add-Member for use by Invoke-JdkInstall.
# ---------------------------------------------------------------------------

function Invoke-JdkAcquisition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    Write-Host ""
    Write-Host "--- JDK acquisition: $($Vm.vmName) ---" -ForegroundColor Cyan

    $vendor           = $Vm.javaDevKit.vendor
    $requestedVersion = $Vm.javaDevKit.version

    # ------------------------------------------------------------------
    # Cache paths. Vm.vhdPath is guaranteed to exist by the upstream
    # disk-acquisition step that runs before JDK acquisition in
    # provision.ps1; no directory creation needed here.
    # ------------------------------------------------------------------
    $cacheKey    = "jdk-$vendor-$requestedVersion-linux-x64"
    $tarballPath = Join-Path $Vm.vhdPath "$cacheKey.tar.gz"
    $lockPath    = Join-Path $Vm.vhdPath "$cacheKey.lock.json"

    if (Test-Path $lockPath) {
        # --------------------------------------------------------------
        # Lockfile present - either a cache hit or a self-heal scenario.
        # The lockfile is authoritative; the resolver is not re-invoked.
        # --------------------------------------------------------------
        $lock = Get-Content -Path $lockPath -Raw | ConvertFrom-Json

        $tarballOk = $false
        if (Test-Path $tarballPath) {
            $actualHash = (Get-FileHash -Path $tarballPath -Algorithm SHA256).Hash
            if ($actualHash -ieq $lock.sha256) {
                $tarballOk = $true
            }
        }

        if ($tarballOk) {
            Write-Host "  Cache hit: $tarballPath" -ForegroundColor Green
        }
        else {
            # ----------------------------------------------------------
            # Self-heal: lockfile exists but the tarball is missing or
            # corrupt. Re-download from the lockfile's pinned sourceUrl
            # (NOT a fresh resolver call) so the cache slot remains
            # committed to the same build.
            # ----------------------------------------------------------
            Write-Warning (
                "JDK cache self-heal: tarball missing or hash mismatch for " +
                "'$cacheKey'. Re-downloading from pinned source."
            )

            try {
                Invoke-WithNetworkRetry `
                    -OperationName "JDK self-heal download ($cacheKey)" `
                    -ScriptBlock {
                        Invoke-WebRequest -Uri $lock.sourceUrl `
                                          -OutFile $tarballPath `
                                          -UseBasicParsing
                    }
            }
            catch {
                throw (
                    "Self-heal download failed from pinned source " +
                    "'$($lock.sourceUrl)': $_. Adoptium may have rotated " +
                    "the URL. Delete '$lockPath' to force re-resolution " +
                    "against the live API on the next run."
                )
            }

            $newHash = (Get-FileHash -Path $tarballPath -Algorithm SHA256).Hash
            if ($newHash -ine $lock.sha256) {
                throw (
                    "Self-heal hash mismatch for '$cacheKey'. Lockfile " +
                    "expected '$($lock.sha256)' but the redownload from " +
                    "'$($lock.sourceUrl)' produced '$newHash'. Upstream " +
                    "served different bytes for the same URL."
                )
            }

            Write-Host "  [OK] Self-heal complete: $tarballPath" `
                -ForegroundColor Green
        }

        $resolvedVersion = $lock.resolvedVersion
    }
    else {
        # --------------------------------------------------------------
        # True cache miss: resolve against the live API, download, verify,
        # then write the lockfile. The lockfile is only written after a
        # successful hash check so an aborted run does not leave a stale
        # pin behind.
        # --------------------------------------------------------------
        Write-Host "  Cache miss - resolving $vendor $requestedVersion ..."
        $release = Resolve-AdoptiumRelease -Vendor $vendor -Version $requestedVersion

        Write-Host "  Downloading $($release.ResolvedVersion) ..."
        Write-Host "    From: $($release.DownloadUrl)"
        Write-Host "    To  : $tarballPath"

        Invoke-WithNetworkRetry `
            -OperationName "JDK tarball download ($cacheKey)" `
            -ScriptBlock {
                Invoke-WebRequest -Uri $release.DownloadUrl `
                                  -OutFile $tarballPath `
                                  -UseBasicParsing
            }

        $actualHash = (Get-FileHash -Path $tarballPath -Algorithm SHA256).Hash
        if ($actualHash -ine $release.Sha256) {
            # Remove the partial/corrupt tarball so a re-run starts clean.
            # No lockfile is written so the next run is a fresh cache miss.
            Remove-Item -Path $tarballPath -Force -ErrorAction SilentlyContinue
            throw (
                "Fresh download hash mismatch for '$cacheKey'. Adoptium " +
                "advertised '$($release.Sha256)' but the downloaded file " +
                "hashed to '$actualHash'."
            )
        }

        # Lockfile schema (Step 3 plan): resolvedVersion, sha256,
        # downloadedUtc (ISO 8601 Z), sourceUrl. Kept minimal - extending
        # later is safe because the reader treats unknown fields as
        # opaque.
        $lockObject = [pscustomobject]@{
            resolvedVersion = $release.ResolvedVersion
            sha256          = $release.Sha256
            downloadedUtc   = (Get-Date).ToUniversalTime().ToString('o')
            sourceUrl       = $release.DownloadUrl
        }
        $lockObject | ConvertTo-Json | Set-Content -Path $lockPath -Encoding UTF8

        Write-Host "  [OK] JDK cached: $tarballPath" -ForegroundColor Green

        $resolvedVersion = $release.ResolvedVersion
    }

    # ------------------------------------------------------------------
    # Publish the cached artifact's location and the resolved version to
    # the VM object so the seed-ISO generator can stage the tarball and
    # template the install path without recomputing anything.
    # ------------------------------------------------------------------
    Add-Member -InputObject $Vm -MemberType NoteProperty `
               -Name '_jdkTarballPath' -Value $tarballPath -Force
    Add-Member -InputObject $Vm -MemberType NoteProperty `
               -Name '_jdkResolvedVersion' -Value $resolvedVersion -Force
}
