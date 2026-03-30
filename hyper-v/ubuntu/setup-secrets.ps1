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

# Install Infrastructure.Secrets from PSGallery if not already present.
# To update an existing installation: Update-Module Infrastructure.Secrets
if (-not (Get-Module -ListAvailable -Name Infrastructure.Secrets)) {
    Write-Host "Installing Infrastructure.Secrets from PSGallery ..." -ForegroundColor Cyan
    Install-Module Infrastructure.Secrets -Scope CurrentUser -Force
}
Import-Module Infrastructure.Secrets -Force -ErrorAction Stop

. "$PSScriptRoot\common.ps1"

Initialize-InfrastructureVault `
    -VaultName           'VmProvisioner' `
    -SecretName          'VmProvisionerConfig' `
    @PSBoundParameters `
    -Validate {
        param($json)
        $defs = @(ConvertFrom-VmConfigJson -Json $json)
        Write-Host "✓ JSON validated - $($defs.Count) VM definition(s) found." `
            -ForegroundColor Green
    }

Write-Host ""
Write-Host "Setup complete. Run provision.ps1 to create VMs." -ForegroundColor Cyan
