<#
.SYNOPSIS
    Installs and imports every PowerShell module the Infrastructure-Vm-Provisioner
    entry-point scripts need.

.DESCRIPTION
    Centralised so each entry-point (provision.ps1, deprovision.ps1, ...)
    dot-sources this file once instead of repeating the same install/import
    block. Intentionally not a function: dot-sourcing this script imports
    every required module into the caller's scope, which is what the
    entry-points and their dot-sourced helpers expect.

    Step 1 - NuGet provider: PowerShellGet uses it to download from PSGallery.
             Included even though it's idempotent so a cold machine doesn't
             need a separate setup step.

    Step 2 - Infrastructure.Common: the chicken-and-egg case. It supplies
             Invoke-ModuleInstall used by every install below, so it cannot
             install itself - the inline guard is unavoidable.

    Step 3 - Everything else flows through Invoke-ModuleInstall.

.NOTES
    Setup-secrets.ps1 is responsible for the encrypted SecretStore vault and
    its provider modules; that side of the world is not duplicated here.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Install-InfrastructureCommonWithRetry
#   The chicken-and-egg case: Invoke-ModuleInstall (which has retry built
#   in) lives inside Infrastructure.Common, so it cannot be used to install
#   Infrastructure.Common itself. A small inline retry wrapper here covers
#   that single bootstrap call. All later Invoke-ModuleInstall calls below
#   get retry for free.
#
#   Defaults mirror Invoke-ModuleInstall's: 6 attempts, exponential 10 s ->
#   20 -> 40 -> 80 -> 160, capped at 300 s (5 min). Total wait ~5 min
#   before giving up - long enough to ride out a transient PSGallery
#   resolution blip, short enough that a real outage fails the run.
# ---------------------------------------------------------------------------
function Install-InfrastructureCommonWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Version] $MinimumVersion,
        [int] $MaxAttempts         = 6,
        [int] $InitialDelaySeconds = 10,
        [int] $MaxDelaySeconds     = 300
    )
    $delay = $InitialDelaySeconds
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            # -ErrorAction Stop promotes PSGallery "Unable to resolve
            # package source" (a non-terminating error by default) to a
            # terminating one so the catch block can retry it.
            Install-Module Infrastructure.Common `
                -MinimumVersion $MinimumVersion `
                -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -ge $MaxAttempts) { throw }
            Write-Warning (
                "Install-Module Infrastructure.Common failed " +
                "(attempt $attempt/$MaxAttempts): " +
                "$($_.Exception.Message). Retrying in ${delay}s ..."
            )
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min($delay * 2, $MaxDelaySeconds)
        }
    }
}

# Step 1 - NuGet provider
$_nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $_nuget -or $_nuget.Version -lt [Version]'2.8.5.201') {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 `
        -Scope CurrentUser -Force -ForceBootstrap | Out-Null
}

# Step 2 - Infrastructure.Common (chicken-and-egg bootstrap)
$_common = Get-Module -ListAvailable -Name Infrastructure.Common |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $_common -or $_common.Version -lt [Version]'5.1.0') {
    Install-InfrastructureCommonWithRetry -MinimumVersion '5.1.0'
    # Re-query so the comparison below uses the freshly installed version.
    $_common = Get-Module -ListAvailable -Name Infrastructure.Common |
        Sort-Object Version -Descending | Select-Object -First 1
}
# Reload only when the loaded state differs from the target (multiple
# versions live, or wrong version live). Mirrors the conditional in
# Invoke-ModuleInstall - inlined here because the bootstrap installs
# the very module that defines that function.
$_loaded = @(Get-Module -Name Infrastructure.Common)
if ($_loaded.Count -ne 1 -or $_loaded[0].Version -ne $_common.Version) {
    if ($_loaded) { $_loaded | Remove-Module -Force }
    Import-Module Infrastructure.Common -Force -ErrorAction Stop
}

# Step 3 - Everything else
# Infrastructure.HyperV provides Test-VmSshPort (used by create-vm.ps1's
# cloud-init readiness poll) and New-VmSshClient / Invoke-SshClientCommand /
# Invoke-WithVmFileServer / Add-VmFileServerFile (used by the out-of-band
# post-provisioning file transfers and software installs).
Invoke-ModuleInstall -ModuleName 'Infrastructure.HyperV' -MinimumVersion '0.3.1'

# Posh-SSH is loaded only for its bundled Renci.SshNet.dll - the SSH.NET
# types that New-VmSshClient instantiates. Posh-SSH's own cmdlets are not
# used (ConnectionInfoGenerator in Posh-SSH 3.x drops algorithm entries,
# breaking key exchange against OpenSSH 9.x on Ubuntu 24.04). Same pattern
# as Infrastructure-E2E's vm-provisioning tests.
Invoke-ModuleInstall -ModuleName 'Posh-SSH'

# Infrastructure.Secrets is used by setup-secrets.ps1 to seed the vault;
# included here so setup-secrets can dot-source this helper too. The
# SecretManagement provider modules are imported (not installed) by
# provision.ps1 itself - it expects them on the machine already.
Invoke-ModuleInstall -ModuleName 'Infrastructure.Secrets' -MinimumVersion '3.0.1'
