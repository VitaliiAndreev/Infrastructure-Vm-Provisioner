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
    - PowerShell 5.1 (ships with Windows 11) or later. PS 7 is recommended
      but not required.

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

. "$PSScriptRoot\common.ps1"

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

$vmDefs = @(ConvertFrom-VmConfigJson -Json $configJson)
Write-Host "✓ Config validated - $($vmDefs.Count) VM definition(s) found." `
    -ForegroundColor Green

# ---------------------------------------------------------------------------
# 4. Idempotency and safety checks
#
#    For each VM definition two checks run in order:
#
#    a) VM existence  - if a VM with vmName already exists in Hyper-V,
#       skip that entry. Re-creating an existing VM risks data loss.
#
#    b) IP conflict   - if ipAddress responds to a ping, abort that entry.
#       Assigning a static IP already in use will cause network conflicts
#       that are difficult to diagnose inside the VM.
#
#    VMs that pass both checks are collected in $vmsToProvision for the
#    subsequent provisioning steps (Steps 4-6).
# ---------------------------------------------------------------------------

$vmsToProvision = [System.Collections.Generic.List[object]]::new()

foreach ($vm in $vmDefs) {
    Write-Host ""
    Write-Host "--- Checking: $($vm.vmName) ---" -ForegroundColor Cyan

    # ------------------------------------------------------------------
    # Check a) VM existence
    # ------------------------------------------------------------------
    # Get-VM throws on a missing name in PS 5.1 without -ErrorAction, so
    # SilentlyContinue is required to get a $null return instead.
    $existing = Get-VM -Name $vm.vmName -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        Write-Warning "VM '$($vm.vmName)' already exists in Hyper-V - skipping."
        continue
    }

    # ------------------------------------------------------------------
    # Check b) IP conflict
    # ------------------------------------------------------------------
    # [System.Net.NetworkInformation.Ping] is used instead of
    # Test-Connection because Test-Connection's -TimeoutSeconds parameter
    # was only added in PS 7. The .NET API works identically on PS 5.1 and
    # PS 7. A 1000 ms timeout avoids a long wait per entry when the address
    # is offline (the expected state for a VM that doesn't exist yet).
    $ping       = [System.Net.NetworkInformation.Ping]::new()
    $pingResult = $ping.Send($vm.ipAddress, 1000)
    $ping.Dispose()

    if ($pingResult.Status -eq
            [System.Net.NetworkInformation.IPStatus]::Success) {
        Write-Warning (
            "IP $($vm.ipAddress) is already in use on the network - " +
            "skipping '$($vm.vmName)' to avoid a static-IP conflict."
        )
        continue
    }

    Write-Host "✓ '$($vm.vmName)' passed all checks - queued for provisioning." `
        -ForegroundColor Green
    $vmsToProvision.Add($vm)
}

Write-Host ""

if ($vmsToProvision.Count -eq 0) {
    Write-Host "No VMs to provision - all entries were skipped." `
        -ForegroundColor Yellow
    exit 0
}

Write-Host "$($vmsToProvision.Count) VM(s) queued for provisioning." `
    -ForegroundColor Cyan

# TODO: Step 4 - disk image acquisition (download + cache base .vhdx,
#       copy per-VM disk)
# TODO: Step 5 - cloud-init seed ISO generation (meta-data, user-data,
#       netplan, pack into FAT ISO)
# TODO: Step 6 - VM creation (New-VM, attach ISO, Secure Boot, start)
