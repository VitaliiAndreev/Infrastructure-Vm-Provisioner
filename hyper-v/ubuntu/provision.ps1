<#
.SYNOPSIS
    Provision one or more Hyper-V Ubuntu VMs from a JSON config stored in the
    local SecretStore vault.

.DESCRIPTION
    Reads the VmProvisionerConfig secret, validates each VM definition, performs
    idempotency and safety checks, then provisions each VM that passes all checks.

    Run setup-secrets.ps1 once first to populate the vault before running
    this script.

.NOTES
    REQUIREMENTS
    - Windows 11 with Hyper-V enabled.
    - Run as Administrator (Hyper-V cmdlets require elevation).
    - Microsoft.PowerShell.SecretManagement + Microsoft.PowerShell.SecretStore
      installed by setup-secrets.ps1.
    - PowerShell 7+.

    IDEMPOTENCY
    - If a Hyper-V VM with the same vmName already exists, that entry is
      skipped rather than re-created.
    - If the target ipAddress responds to a ping, that entry is aborted to
      avoid a static-IP conflict with an existing machine.

    SECURITY
    - No secrets are passed as command-line arguments or written to disk.
      All sensitive values are read at runtime from the encrypted vault.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\common\config\Get-SanitizedVmDisplay.ps1"
. "$PSScriptRoot\common\config\ConvertFrom-VmConfigJson.ps1"
. "$PSScriptRoot\up\config\Select-VmsForProvisioning.ps1"
. "$PSScriptRoot\up\seed\iso.ps1"
. "$PSScriptRoot\up\disk\Invoke-BaseImagePatch.ps1"
. "$PSScriptRoot\up\disk\Invoke-DiskImageAcquisition.ps1"
. "$PSScriptRoot\up\seed\generate-seed-iso.ps1"
. "$PSScriptRoot\up\network\setup-network.ps1"
. "$PSScriptRoot\up\vm\create-vm.ps1"

# ---------------------------------------------------------------------------
# 1. Ensure SecretManagement modules are loaded
#    Import only - provisioning should have no side effects on the module
#    environment. Installing modules is setup-secrets.ps1's responsibility.
# ---------------------------------------------------------------------------

foreach ($mod in @(
    'Microsoft.PowerShell.SecretManagement',
    'Microsoft.PowerShell.SecretStore'
)) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        throw "Module '$mod' is not installed. Run setup-secrets.ps1 first."
    }
    Import-Module $mod -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# 2. Read VmProvisionerConfig from the local vault
# ---------------------------------------------------------------------------

$vaultName  = 'VmProvisioner'
$secretName = 'VmProvisionerConfig'

Write-Host "Reading '$secretName' from vault '$vaultName' ..." -ForegroundColor Cyan

$vault = Get-SecretVault -Name $vaultName -ErrorAction SilentlyContinue
if ($null -eq $vault) {
    throw "Vault '$vaultName' not found. Run setup-secrets.ps1 first."
}

$configJson = Get-Secret -Vault $vaultName -Name $secretName `
    -AsPlainText -ErrorAction Stop

# ---------------------------------------------------------------------------
# 3. Parse and validate JSON
#    Done here (not relying solely on setup-secrets.ps1) because the vault
#    could hold stale or manually-edited data. Failing fast is safer than
#    discovering a missing field mid-provisioning.
# ---------------------------------------------------------------------------

$vmDefs = ConvertTo-Array (ConvertFrom-VmConfigJson -Json $configJson)
Write-Host "[OK] Config validated - $($vmDefs.Count) VM definition(s) found." `
    -ForegroundColor Green

# ---------------------------------------------------------------------------
# 4. Idempotency and safety checks
#    Filters $vmDefs down to VMs that are safe to provision:
#      a) no existing Hyper-V VM with the same vmName
#      b) no machine already responding to the target ipAddress
# ---------------------------------------------------------------------------

$vmsToProvision = ConvertTo-Array (Select-VmsForProvisioning -VmDefs $vmDefs)

Write-Host ""

if ($vmsToProvision.Count -eq 0) {
    Write-Host "No VMs to provision - all entries were skipped." `
        -ForegroundColor Yellow
    exit 0
}

Write-Host "$($vmsToProvision.Count) VM(s) queued for provisioning." `
    -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 5. Disk image acquisition
#    Downloads, converts, patches, and copies the per-VM VHDX.
#    Sets $vm._vhdxPath on each object for use in step 8.
#
#    Invoke-BaseImagePatch (called internally) throws a 'Wsl2NotReady:'
#    error if WSL2 is not yet installed or initialised. We catch it here
#    so we can print the reboot prompt and exit cleanly rather than
#    letting the error propagate as an unhandled exception.
# ---------------------------------------------------------------------------

foreach ($vm in $vmsToProvision) {
    try {
        Invoke-DiskImageAcquisition -Vm $vm
    }
    catch {
        if ($_.Exception.Message -match '^Wsl2NotReady: ') {
            Write-Host ($_.Exception.Message -replace '^Wsl2NotReady: ', '') `
                -ForegroundColor Yellow
            exit 0
        }
        throw
    }
}

# ---------------------------------------------------------------------------
# 6. Cloud-init seed ISO generation
#    Builds meta-data, user-data, and network-config; writes the ISO.
#    Sets $vm._seedIsoPath on each object for use in step 8.
# ---------------------------------------------------------------------------

foreach ($vm in $vmsToProvision) {
    Invoke-SeedIsoGeneration -Vm $vm
}

# ---------------------------------------------------------------------------
# 7. Virtual switch and NAT setup
#    Switch and NAT names come from the config (default: VmLAN / VmLAN-NAT).
#    Idempotent - safe to re-run.
# ---------------------------------------------------------------------------

$switchName = $vmsToProvision[0].switchName
$natName    = $vmsToProvision[0].natName

Invoke-NetworkSetup -VmsToProvision $vmsToProvision `
                    -SwitchName     $switchName `
                    -NatName        $natName

# ---------------------------------------------------------------------------
# 8. VM creation
#    Creates, configures, boots each VM, and waits for SSH readiness.
# ---------------------------------------------------------------------------

foreach ($vm in $vmsToProvision) {
    Invoke-VmCreation -Vm $vm -SwitchName $switchName
}

Write-Host ""
Write-Host "Provisioning complete." -ForegroundColor Green
