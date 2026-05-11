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
if (-not $_common -or $_common.Version -lt [Version]'4.0.0') {
    Install-Module Infrastructure.Common -Scope CurrentUser -Force -AllowClobber
}
Import-Module Infrastructure.Common -Force -ErrorAction Stop

# Step 3 - Everything else
# Infrastructure.HyperV provides Test-VmSshPort, used by create-vm.ps1's
# cloud-init readiness poll.
Invoke-ModuleInstall -ModuleName 'Infrastructure.HyperV' -MinimumVersion '0.2.0'

# Infrastructure.Secrets is used by setup-secrets.ps1 to seed the vault;
# included here so setup-secrets can dot-source this helper too. The
# SecretManagement provider modules are imported (not installed) by
# provision.ps1 itself - it expects them on the machine already.
Invoke-ModuleInstall -ModuleName 'Infrastructure.Secrets' -MinimumVersion '3.0.1'
