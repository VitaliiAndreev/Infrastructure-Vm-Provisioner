<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 after iso.ps1 is loaded (New-SeedIso must be available).
#>

# ---------------------------------------------------------------------------
# Invoke-SeedIsoGeneration
#   Builds the three cloud-init files and writes a NoCloud seed ISO for a
#   single VM. The ISO is placed in Vm.vmConfigPath.
#
#   cloud-init's NoCloud datasource reads from a filesystem volume labelled
#   'cidata'. Three files are placed in the root of the ISO:
#
#     meta-data      - instance identity (instance-id, local-hostname).
#     user-data      - cloud-config: OS user, SSH, installed packages.
#     network-config - cloud-init network v2 format: static IP, gateway,
#                      DNS. Kept separate from user-data so cloud-init's
#                      network module processes it before other modules
#                      that require network access (e.g. package install).
#
#   SECURITY - user-data contains Vm.password in plaintext so cloud-init
#   can hash it internally (plain_text_passwd). The ISO persists on the
#   host after provisioning; delete it once the VM is running, or restrict
#   read access to Vm.vmConfigPath to the provisioning account only.
#
#   On return, $Vm._seedIsoPath is set via Add-Member for use by
#   Invoke-VmCreation.
# ---------------------------------------------------------------------------
function Invoke-SeedIsoGeneration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    Write-Host ""
    Write-Host "--- Cloud-init ISO: $($Vm.vmName) ---" -ForegroundColor Cyan

    # Ensure the vmConfigPath directory exists.
    if (-not (Test-Path -Path $Vm.vmConfigPath -PathType Container)) {
        New-Item -ItemType Directory -Path $Vm.vmConfigPath -Force | Out-Null
        Write-Host "  Created directory: $($Vm.vmConfigPath)"
    }

    # ------------------------------------------------------------------
    # meta-data
    # instance-id must change if the instance is re-created from scratch;
    # using vmName satisfies this for our one-VM-per-name model. It also
    # sets the Linux hostname on first boot via local-hostname.
    # ------------------------------------------------------------------
    $metaData = @"
instance-id: $($Vm.vmName)
local-hostname: $($Vm.vmName)
"@

    # ------------------------------------------------------------------
    # user-data (cloud-config)
    #
    # plain_text_passwd lets cloud-init hash the password internally,
    # avoiding the need to pre-compute a sha512crypt hash on Windows.
    # lock_passwd must be false - without it cloud-init locks the account
    # after setting the password, blocking SSH password auth even when
    # ssh_pwauth is true.
    # Specifying users: without 'default' in the list intentionally omits
    # the cloud image's built-in 'ubuntu' user; only our configured user
    # is created.
    # package_upgrade is false to keep the first boot fast; operators can
    # run upgrades afterwards.
    #
    # Values that may contain YAML-special characters (colon, hash, quote)
    # are wrapped in YAML double-quoted strings. Backslashes and double
    # quotes within those strings are escaped below.
    # ------------------------------------------------------------------
    $yamlUsername = $Vm.username -replace '\\', '\\' -replace '"', '\"'
    # cloud-init requires plain_text_passwd as a literal string in YAML.
    # Vm.password is a plain string from ConvertFrom-Json; converting to
    # SecureString would only require converting back here. Protection
    # relies on vault encryption at rest and the short session lifetime.
    $yamlPassword = $Vm.password -replace '\\', '\\' -replace '"', '\"'

    $userData = @"
#cloud-config

users:
  - name: "$yamlUsername"
    plain_text_passwd: "$yamlPassword"
    lock_passwd: false
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [adm, cdrom, dip, plugdev, lxd]

ssh_pwauth: true

packages:
  - openssh-server

package_update: true
package_upgrade: false
"@

    # ------------------------------------------------------------------
    # network-config (cloud-init network configuration v2 / netplan)
    #
    # Matching on driver: hv_netvsc rather than a fixed interface name
    # (eth0, enp0s*, etc.) because the kernel-assigned name varies across
    # Ubuntu releases and Hyper-V generations. hv_netvsc is the driver for
    # all Hyper-V synthetic NICs, so this match always hits the right NIC.
    # ------------------------------------------------------------------
    $networkConfig = @"
version: 2
ethernets:
  eth0:
    match:
      driver: hv_netvsc
    dhcp4: false
    addresses:
      - $($Vm.ipAddress)/$($Vm.subnetMask)
    routes:
      - to: default
        via: $($Vm.gateway)
    nameservers:
      addresses:
        - $($Vm.dns)
"@

    $seedIsoPath = Join-Path $Vm.vmConfigPath "$($Vm.vmName)-seed.iso"
    Write-Host "  Writing: $seedIsoPath"

    New-SeedIso -OutputPath $seedIsoPath -Files @{
        'meta-data'      = $metaData
        'user-data'      = $userData
        'network-config' = $networkConfig
    }

    Write-Host "  [OK] Seed ISO ready: $seedIsoPath" -ForegroundColor Green

    # Store the ISO path on the VM object so Invoke-VmCreation can
    # attach and clean it up without recomputing the path.
    Add-Member -InputObject $Vm -MemberType NoteProperty `
               -Name '_seedIsoPath' -Value $seedIsoPath -Force
}
