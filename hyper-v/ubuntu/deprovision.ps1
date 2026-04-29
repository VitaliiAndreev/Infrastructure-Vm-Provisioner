<#
.SYNOPSIS
    Remove one or more Hyper-V Ubuntu VMs from a JSON config stored in the
    local SecretStore vault.

.DESCRIPTION
    Reads the VmProvisionerConfig secret, validates each VM definition, stops
    and removes each VM with its associated files, then tears down the shared
    VmLAN network when no VMs remain on it.

    Run setup-secrets.ps1 once first to populate the vault before running
    this script.

.NOTES
    REQUIREMENTS
    - Windows 11 with Hyper-V enabled.
    - Run as Administrator (Hyper-V cmdlets require elevation).
    - Microsoft.PowerShell.SecretManagement + Microsoft.PowerShell.SecretStore
      installed by setup-secrets.ps1.
    - PowerShell 5.1 (ships with Windows 11) or later. PS 7 is recommended
      but not required.

    IDEMPOTENCY
    - If a VM in the config is not found in Hyper-V, its Hyper-V teardown is
      skipped and only file cleanup is attempted. Re-running after a partial
      failure retries the outstanding file deletions.
    - If the shared network objects (NAT rule, host vNIC IP, switch) are
      already absent, each is silently skipped.
    - If VMs outside the config are still attached to VmLAN, the network
      teardown is skipped to avoid cutting their connectivity.

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
. "$PSScriptRoot\down\config\Assert-GatewayConsistency.ps1"
. "$PSScriptRoot\down\vm\remove-vm.ps1"
. "$PSScriptRoot\down\network\teardown-network.ps1"

# ---------------------------------------------------------------------------
# 1. Ensure SecretManagement modules are loaded
#    Import only - deprovisioning should have no side effects on the module
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
#    discovering a missing field mid-deprovisioning.
# ---------------------------------------------------------------------------

$vmDefs = @(ConvertFrom-VmConfigJson -Json $configJson)
Write-Host "[OK] Config validated - $($vmDefs.Count) VM definition(s) found." `
    -ForegroundColor Green

# ---------------------------------------------------------------------------
# 4. Validate gateway consistency
#    All VMs must share the same gateway - they are all attached to the same
#    Internal switch during provisioning. The gateway is needed to call
#    Invoke-NetworkTeardown, so this check runs here rather than inside that
#    function (which does not receive the full VM list).
# ---------------------------------------------------------------------------

$gatewayIp  = Assert-GatewayConsistency -VmDefs $vmDefs
$switchName = $vmDefs[0].switchName
$natName    = $vmDefs[0].natName

# ---------------------------------------------------------------------------
# 5. Per-VM removal
#    Each VM is stopped and removed from Hyper-V, then its VHDX, seed ISO,
#    and config directory are deleted. If a VM is already absent from Hyper-V
#    (re-run after partial failure), only the file cleanup is attempted.
# ---------------------------------------------------------------------------

foreach ($vm in $vmDefs) {
    Invoke-VmRemoval -Vm $vm
}

# ---------------------------------------------------------------------------
# 6. Shared network teardown
#    Invoke-NetworkTeardown checks internally whether any VMs are still
#    attached to VmLAN before removing network objects. VMs outside the
#    config that remain on the switch will cause teardown to be skipped,
#    preserving their connectivity.
# ---------------------------------------------------------------------------

Invoke-NetworkTeardown -SwitchName $switchName `
                       -Gateway    $gatewayIp `
                       -NatName    $natName

Write-Host ""
Write-Host "Deprovisioning complete." -ForegroundColor Green
