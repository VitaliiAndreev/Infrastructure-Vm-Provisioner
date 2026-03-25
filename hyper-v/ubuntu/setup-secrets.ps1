<#
.SYNOPSIS
    One-time setup: installs SecretManagement modules, registers the local
    vault, and stores the VM provisioner JSON config as an encrypted secret.

.DESCRIPTION
    Run this once per machine before running provision.ps1.

    All VM parameters (names, passwords, IP addresses, etc.) are
    stored in an AES-256-encrypted local vault scoped to your Windows user
    account. Nothing sensitive is ever written to the repository.

    The vault uses no interactive password by default (Authentication=None),
    which is appropriate for a workstation where the Windows login already
    gates access. Pass -RequireVaultPassword to enable vault-level password
    protection on top of that.

    SECURITY NOTE: The -ConfigJson parameter accepts a raw JSON string.
    Avoid passing it inline on shared machines where process listings are
    visible to other users - prefer -ConfigFile instead, pointing to a file
    outside the repo.

.PARAMETER ConfigJson
    The VM config as a raw JSON string. Mutually exclusive with -ConfigFile.

.PARAMETER ConfigFile
    Path to a JSON file containing the VM config. Mutually exclusive with
    -ConfigJson. The file is read at runtime and its contents are stored in
    the vault; the file itself is not modified.

.PARAMETER RequireVaultPassword
    When specified, the SecretStore vault is configured to require a
    password on each session. Prompts interactively. Recommended on
    shared or less-trusted machines.

.EXAMPLE
    # Store config from a file (recommended - avoids secrets in shell history)
    .\setup-secrets.ps1 -ConfigFile C:\private\vm-config.json

.EXAMPLE
    # Store config inline (convenient for quick tests)
    .\setup-secrets.ps1 -ConfigJson '[{"vmName":"ubuntu-01",...}]'

.EXAMPLE
    # Enable vault password prompt in addition to Windows user scope
    .\setup-secrets.ps1 -ConfigFile C:\private\vm-config.json -RequireVaultPassword

.NOTES
    JSON CONFIG FORMAT

    The config file must contain a JSON array, one object per VM:

    [
      {
        "vmName":       "ubuntu-01-ci",   # Hyper-V VM name (must be unique)
        "cpuCount":     2,                # Virtual CPU count
        "ramGB":        4,                # RAM in GB
        "diskGB":       40,               # OS disk size in GB
        "ubuntuVersion":"24.04",          # Ubuntu LTS version (e.g. "24.04")
        "username":     "u-01-admin",     # Default OS user created by cloud-init
        "password":     "...",            # Password for that user (used for SSH)
        "ipAddress":    "192.168.1.101",  # Static IP assigned inside the VM
        "subnetMask":   "24",             # CIDR prefix length
        "gateway":      "192.168.1.1",
        "dns":          "8.8.8.8",
        "vmConfigPath": "D:\\Hyper-V\\Config",  # Where VM config files are stored
        "vhdPath":      "D:\\Hyper-V\\Disks"    # Where VM disk images are stored
      }
    ]

    All fields are required. Multiple VM objects in the array are each
    provisioned in turn. Connect to a VM after first boot via:
        ssh username@ipAddress
#>

[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    # Raw JSON string with the VM definitions array.
    [Parameter(Mandatory, ParameterSetName = 'Json')]
    [string] $ConfigJson,

    # Path to a JSON file containing the VM config. Mutually exclusive with
    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string] $ConfigFile,

    # Require an interactive password for the SecretStore vault.
    [Parameter()]
    [switch] $RequireVaultPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 1. Load JSON from file or inline string
# ---------------------------------------------------------------------------

if ($PSCmdlet.ParameterSetName -eq 'File') {
    if (-not (Test-Path $ConfigFile -PathType Leaf)) {
        throw "Config file not found: $ConfigFile"
    }
    $ConfigJson = Get-Content -Raw -Path $ConfigFile
}

# ---------------------------------------------------------------------------
# 2. Validate JSON structure before touching the vault
#    Fail fast - no point installing modules if the config is malformed.
# ---------------------------------------------------------------------------

try {
    $vmDefs = $ConfigJson | ConvertFrom-Json -ErrorAction Stop
}
catch {
    throw "Invalid JSON: $_"
}

if ($vmDefs -isnot [array] -or $vmDefs.Count -eq 0) {
    throw "Config must be a non-empty JSON array of VM definitions."
}

# Required fields that every VM definition must supply.
$requiredFields = @(
    'vmName', 'cpuCount', 'ramGB', 'diskGB', 'ubuntuVersion',
    'username', 'password',
    'ipAddress', 'subnetMask', 'gateway', 'dns',
    'vmConfigPath', 'vhdPath'
)

foreach ($vm in $vmDefs) {
    foreach ($field in $requiredFields) {
        # Use the PSObject property bag so we catch nulls as well as missing keys.
        $prop = $vm.PSObject.Properties[$field]
        if ($null -eq $prop -or [string]::IsNullOrWhiteSpace($prop.Value)) {
            throw "VM definition is missing required field '$field': $($vm | ConvertTo-Json -Depth 1)"
        }
    }
}

Write-Host "✓ JSON validated - $($vmDefs.Count) VM definition(s) found." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 3. Ensure NuGet provider is available
#    PowerShellGet requires NuGet >= 2.8.5.201 to install modules from
#    PSGallery. -ForceBootstrap suppresses the interactive prompt that
#    PackageManagement shows when the provider is missing. The call is a
#    no-op if a sufficient version is already installed.
# ---------------------------------------------------------------------------

Write-Host "Ensuring NuGet package provider ..." -ForegroundColor Cyan
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 `
    -Scope CurrentUser -Force -ForceBootstrap | Out-Null
Write-Host "✓ NuGet provider ready." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 4. Install SecretManagement modules if not already present
#    Both modules are published by Microsoft on the PowerShell Gallery.
# ---------------------------------------------------------------------------

$requiredModules = @(
    'Microsoft.PowerShell.SecretManagement',
    'Microsoft.PowerShell.SecretStore'
)

# Install all missing modules before importing any of them. Importing
# SecretManagement before SecretStore is installed causes PowerShellGet to
# warn that SecretManagement is "in use" when it tries to satisfy
# SecretStore's dependency on it.
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Host "Installing module: $mod ..." -ForegroundColor Cyan
        Install-Module -Name $mod -Repository PSGallery -Scope CurrentUser -Force
        Write-Host "✓ Installed $mod." -ForegroundColor Green
    }
    else {
        Write-Host "✓ Module already present: $mod" -ForegroundColor Green
    }
}

foreach ($mod in $requiredModules) {
    Import-Module $mod -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# 5. Configure SecretStore
#    Authentication=None means the vault is unlocked automatically for the
#    current Windows user - the AES-256 encryption key is derived from the
#    Windows user profile. No separate vault password is required unless
#    -RequireVaultPassword was passed.
#
#    Every SecretStore cmdlet triggers store initialization if the store does
#    not yet exist, and the default initialization requires a password. To
#    avoid the prompt we must distinguish "store not yet created" from
#    "store already exists" without invoking any SecretStore cmdlet.
#    We do this by checking for the store config file on disk.
#
#    - Fresh store: Reset-SecretStore initializes it to a known state with
#      no prompts. -Force skips the "this wipes all secrets" confirmation
#      (safe here because there are no secrets yet).
#    - Existing store: Get-SecretStoreConfiguration reads the current auth
#      mode; we warn if it differs from what was requested rather than
#      silently changing it (which would require the vault password anyway).
# ---------------------------------------------------------------------------

$authMode    = if ($RequireVaultPassword) { 'Password' } else { 'None' }
# SecretStore writes its config file here on all supported Windows versions.
$storeConfig = Join-Path $env:LOCALAPPDATA `
    'Microsoft\PowerShell\secretmanagement\localstore\storeconfig'

Write-Host "Configuring SecretStore (Authentication=$authMode) ..." -ForegroundColor Cyan

if (-not (Test-Path $storeConfig)) {
    # Store has never been initialized - create it with the desired auth mode.
    # Reset-SecretStore is the only cmdlet that accepts auth mode at creation
    # time without first running default (password) initialization.
    Reset-SecretStore -Authentication $authMode -Interaction None -Force
    Write-Host "✓ SecretStore initialized." -ForegroundColor Green
}
else {
    # Store already exists - read config (safe: store is already initialized
    # so this cmdlet will not prompt).
    $existing = Get-SecretStoreConfiguration
    if ($existing.Authentication -ne $authMode) {
        Write-Warning (
            "SecretStore is already configured with " +
            "Authentication='$($existing.Authentication)'. " +
            "The requested mode '$authMode' was not applied. " +
            "Run Set-SecretStoreConfiguration manually to change it."
        )
    }
    else {
        Write-Host "✓ SecretStore already configured (Authentication=$authMode)." `
            -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# 6. Register the vault (idempotent - skip if it already exists)
# ---------------------------------------------------------------------------

$vaultName = 'VmProvisioner'

$existingVault = Get-SecretVault -Name $vaultName -ErrorAction SilentlyContinue
if ($null -eq $existingVault) {
    Write-Host "Registering vault '$vaultName' ..." -ForegroundColor Cyan
    Register-SecretVault `
        -Name $vaultName `
        -ModuleName Microsoft.PowerShell.SecretStore `
        -DefaultVault
    Write-Host "✓ Vault '$vaultName' registered." -ForegroundColor Green
}
else {
    Write-Host "✓ Vault '$vaultName' already registered." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 7. Store the JSON config in the vault
#    Set-Secret overwrites an existing value with the same name, so
#    re-running this script safely updates the stored config.
# ---------------------------------------------------------------------------

$secretName = 'VmProvisionerConfig'

Write-Host "Storing secret '$secretName' in vault '$vaultName' ..." -ForegroundColor Cyan
Set-Secret -Vault $vaultName -Name $secretName -Secret $ConfigJson
Write-Host "✓ Secret stored." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 8. Verify round-trip: read back and parse to confirm nothing was corrupted
# ---------------------------------------------------------------------------

$readBack = Get-Secret -Vault $vaultName -Name $secretName -AsPlainText
$parsed   = $readBack | ConvertFrom-Json

Write-Host (
    "✓ Round-trip verified - $($parsed.Count) VM definition(s) readable " +
    "from vault."
) -ForegroundColor Green

Write-Host ""
Write-Host "Setup complete. Run provision.ps1 to create VMs." -ForegroundColor Cyan
