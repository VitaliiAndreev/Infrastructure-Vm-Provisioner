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
. "$PSScriptRoot\up\jdk\Resolve-AdoptiumRelease.ps1"
. "$PSScriptRoot\up\jdk\Invoke-JdkAcquisition.ps1"
. "$PSScriptRoot\up\acquire\Invoke-VmAcquisitions.ps1"
. "$PSScriptRoot\up\post\Install-Jdk.ps1"
. "$PSScriptRoot\up\post\Uninstall-Jdk.ps1"
. "$PSScriptRoot\up\post\Invoke-VmPostProvisioning.ps1"
. "$PSScriptRoot\up\seed\generate-seed-iso.ps1"
. "$PSScriptRoot\up\network\setup-network.ps1"
. "$PSScriptRoot\up\vm\create-vm.ps1"

# ---------------------------------------------------------------------------
# 1. Install / import every required module via the centralised helper.
#    Dot-source so the imports land in this script's scope.
# ---------------------------------------------------------------------------

. "$PSScriptRoot\Install-ModuleDependencies.ps1"

# ---------------------------------------------------------------------------
# 2. Ensure the SecretStore vault provider modules are loaded.
#    setup-secrets.ps1 installs them; provisioning is import-only.
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
# 3. Read VmProvisionerConfig from the local vault
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
# 4. Parse and validate JSON
#    Done here (not relying solely on setup-secrets.ps1) because the vault
#    could hold stale or manually-edited data. Failing fast is safer than
#    discovering a missing field mid-provisioning.
# ---------------------------------------------------------------------------

$vmDefs = ConvertTo-Array (ConvertFrom-VmConfigJson -Json $configJson)
Write-Host "[OK] Config validated - $($vmDefs.Count) VM definition(s) found." `
    -ForegroundColor Green

# ---------------------------------------------------------------------------
# 5. Idempotency and safety checks
#    Filters $vmDefs down to VMs that are safe to provision:
#      a) no existing Hyper-V VM with the same vmName
#      b) no machine already responding to the target ipAddress
# ---------------------------------------------------------------------------

$vmsToProcess = ConvertTo-Array (Select-VmsForProvisioning -VmDefs $vmDefs)

Write-Host ""

if ($vmsToProcess.Count -eq 0) {
    Write-Host "No VMs to process - all entries were skipped." `
        -ForegroundColor Yellow
    exit 0
}

# Split by classification. 'new' VMs go through the full destructive
# pipeline (disk acquisition, seed-ISO generation, VM creation); 'existing'
# VMs are reconciled with the idempotent additive steps only (host-side
# acquisitions + post-provisioning). Network setup is always run because
# it is idempotent and may need to be applied if the host environment was
# rebuilt around already-existing VMs.
$newVms      = ConvertTo-Array ($vmsToProcess | Where-Object { $_._state -eq 'new' })
$existingVms = ConvertTo-Array ($vmsToProcess | Where-Object { $_._state -eq 'existing' })

Write-Host ("Queued: $($newVms.Count) new VM(s), " +
            "$($existingVms.Count) existing VM(s) for reconcile.") `
    -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 6. Disk image acquisition (new VMs only)
#    Downloads, converts, patches, and copies the per-VM VHDX.
#    Sets $vm._vhdxPath on each object for use in step 10. Skipped for
#    existing VMs - their disks already exist and re-copying would lose
#    data.
#
#    Invoke-BaseImagePatch (called internally) throws a 'Wsl2NotReady:'
#    error if WSL2 is not yet installed or initialised. We catch it here
#    so we can print the reboot prompt and exit cleanly rather than
#    letting the error propagate as an unhandled exception.
# ---------------------------------------------------------------------------

foreach ($vm in $newVms) {
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
# 7. Host-side acquisitions (per VM - new AND existing)
#    Per-VM orchestrator that dispatches each per-software acquirer whose
#    opt-in field is set on the VM definition. Self-skips for VMs with no
#    opt-in fields. Adding a new acquirer is one dispatch line in
#    Invoke-VmAcquisitions, not a new block here.
#
#    Runs for existing VMs too: the operator may have added an opt-in
#    field (javaDevKit, ...) after the VM was originally provisioned, and
#    each acquirer is idempotent via its on-host lockfile so re-running
#    against an already-cached artefact is cheap.
# ---------------------------------------------------------------------------

foreach ($vm in $vmsToProcess) {
    Invoke-VmAcquisitions -Vm $vm
}

# ---------------------------------------------------------------------------
# 8. Cloud-init seed ISO generation (new VMs only)
#    Builds meta-data, user-data, and network-config; writes the ISO.
#    Sets $vm._seedIsoPath on each object for use in the VM-creation step.
#    Skipped for existing VMs - cloud-init already ran on their first boot.
# ---------------------------------------------------------------------------

foreach ($vm in $newVms) {
    Invoke-SeedIsoGeneration -Vm $vm
}

# ---------------------------------------------------------------------------
# 9. Virtual switch and NAT setup
#    Switch and NAT names come from the config (default: VmLAN / VmLAN-NAT).
#    Idempotent - safe to re-run. Always runs so a rebuilt host gets the
#    network re-applied around already-existing VMs.
# ---------------------------------------------------------------------------

$switchName = $vmsToProcess[0].switchName
$natName    = $vmsToProcess[0].natName

Invoke-NetworkSetup -VmsToProvision $vmsToProcess `
                    -SwitchName     $switchName `
                    -NatName        $natName

# ---------------------------------------------------------------------------
# 10. VM creation (new VMs only)
#    Creates, configures, boots each VM, and waits for SSH readiness.
#    Skipped for existing VMs.
# ---------------------------------------------------------------------------

foreach ($vm in $newVms) {
    Invoke-VmCreation -Vm $vm -SwitchName $switchName
}

# ---------------------------------------------------------------------------
# 11. Post-provisioning (per VM - new AND existing)
#     Opens one host file server + SSH session per VM, waits for cloud-init
#     to finish, then dispatches each enabled step. Each step is
#     self-contained - no cross-step file dependencies - so order between
#     dispatched steps is not load-bearing. Skipped silently for VMs that
#     have no opt-in fields set.
#
#     Runs for existing VMs too: this is what lets an operator add a
#     'javaDevKit' or 'files' entry to a VM definition and re-run
#     provision.ps1 to push the change. Each step is idempotent on the VM
#     side (release-file guard, file-overwrite semantics).
# ---------------------------------------------------------------------------

foreach ($vm in $vmsToProcess) {
    Invoke-VmPostProvisioning -Vm $vm
}

Write-Host ""
Write-Host "Provisioning complete." -ForegroundColor Green
