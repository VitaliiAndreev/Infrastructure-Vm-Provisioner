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

# Install / import every required PowerShell module via the centralised
# helper. Owns NuGet provider, Infrastructure.Common, Infrastructure.Secrets,
# and the rest of this repo's deps in one place.
. "$PSScriptRoot\Install-ModuleDependencies.ps1"

# ConvertFrom-VmConfigJson.ps1 is dot-sourced after the modules are loaded.
# It only calls Assert-RequiredProperties inside function bodies, not at
# load time, so this ordering is safe.
. "$PSScriptRoot\common\config\ConvertFrom-VmConfigJson.ps1"

Initialize-MicrosoftPowerShellSecretStoreVault `
    -VaultName           'VmProvisioner' `
    -SecretName          'VmProvisionerConfig' `
    @PSBoundParameters `
    -Validate {
        param($json)
        $defs = ConvertTo-Array (ConvertFrom-VmConfigJson -Json $json)
        Write-Host "[OK] JSON validated - $($defs.Count) VM definition(s) found." `
            -ForegroundColor Green
    }

Write-Host ""
Write-Host "Setup complete. Run provision.ps1 to create VMs." -ForegroundColor Cyan
