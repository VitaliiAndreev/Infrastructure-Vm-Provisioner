<#
.SYNOPSIS
    One-time setup: stores the VM provisioner JSON config in the local vault.

.DESCRIPTION
    Run once per machine before running provision.ps1.
    Re-running safely updates the stored config.

    Installs the Infrastructure.Secrets module from PSGallery automatically if not
    already present on this machine.

.PARAMETER ConfigJson
    The VM config as a raw JSON string. Mutually exclusive with -ConfigFile.

.PARAMETER ConfigFile
    Path to a JSON file containing the VM config. Mutually exclusive with
    -ConfigJson. The file is read at runtime; it is not modified.

.PARAMETER RequireVaultPassword
    When specified, the SecretStore vault requires a password each session.
    Recommended on shared or less-trusted machines.

.EXAMPLE
    .\setup-secrets.ps1 -ConfigFile C:\private\vm-config.json

.EXAMPLE
    .\setup-secrets.ps1 -ConfigFile C:\private\vm-config.json -RequireVaultPassword
#>

[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Json')]
    [string] $ConfigJson,

    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string] $ConfigFile,

    [Parameter()]
    [switch] $RequireVaultPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Bootstrap Infrastructure.Common, which provides Invoke-ModuleInstall used
# for all subsequent module installs. This inline block is the only install
# logic that cannot be abstracted - you cannot call a function from a module
# that hasn't been installed yet.
# NuGet must be ensured here explicitly because Invoke-ModuleInstall is not
# yet available to do it, and Install-Module requires NuGet to reach PSGallery.
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 `
    -Scope CurrentUser -Force -ForceBootstrap | Out-Null
$_common = Get-Module -ListAvailable -Name Infrastructure.Common |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $_common -or $_common.Version -lt [Version]'1.2.1') {
    Install-Module Infrastructure.Common -Scope CurrentUser -Force
}
Import-Module Infrastructure.Common -Force -ErrorAction Stop

# ConvertFrom-VmConfigJson.ps1 is dot-sourced after Infrastructure.Common is
# loaded. It only calls Assert-RequiredProperties inside function bodies,
# not at load time, so this ordering is safe.
. "$PSScriptRoot\config\ConvertFrom-VmConfigJson.ps1"

# The minimum version is pinned here - bump it when a newer feature is required.
Invoke-ModuleInstall -ModuleName 'Infrastructure.Secrets' -MinimumVersion '2.1.0'

Initialize-MicrosoftPowerShellSecretStoreVault `
    -VaultName           'VmProvisioner' `
    -SecretName          'VmProvisionerConfig' `
    @PSBoundParameters `
    -Validate {
        param($json)
        $defs = @(ConvertFrom-VmConfigJson -Json $json)
        Write-Host "[OK] JSON validated - $($defs.Count) VM definition(s) found." `
            -ForegroundColor Green
    }

Write-Host ""
Write-Host "Setup complete. Run provision.ps1 to create VMs." -ForegroundColor Cyan
