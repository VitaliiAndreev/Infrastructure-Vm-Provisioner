# Infrastructure-VM-Provisioner

> Reusable Windows scripting tooling for automated Hyper-V VM provisioning and removal.

## Index

- [Overview](#overview)
- [Quick start](#quick-start)
- [setup-secrets.ps1](#setup-secretsps1)
- [provision.ps1](#provisionps1)
- [deprovision.ps1](#deprovisionps1)
- [CI](#ci)
- [Repo structure](#repo-structure)

---

## Overview

General-purpose, reusable Windows scripting tooling for automated Hyper-V VM
provisioning. Not specific to any single project — intended to be consumed by
other projects that need self-hosted infrastructure.

Automates creation and removal of Hyper-V VMs on Windows 11, with Ubuntu
installed and a default user configured via cloud-init. All parameters are
stored in an AES-256 encrypted local vault scoped to the Windows user account
— nothing sensitive is committed to the repo.

---

## Quick start

**Prerequisites:** Windows 11 with Hyper-V enabled, PowerShell 5.1+, and
Administrator privileges. WSL2 is installed automatically by `provision.ps1`
on first run if not already present (a reboot may be required).
`Infrastructure.Common` and `Infrastructure.Secrets` are installed from
PSGallery automatically on first run.

```powershell
# 1. Store config in the local vault (once per machine)
.\hyper-v\ubuntu\setup-secrets.ps1 -ConfigFile C:\private\vm-config.json

# 2. Provision VMs (run as Administrator)
.\hyper-v\ubuntu\provision.ps1

# 3. Remove VMs when no longer needed (run as Administrator)
.\hyper-v\ubuntu\deprovision.ps1
```

---

## setup-secrets.ps1

Run once per machine before `provision.ps1`.

```powershell
# Recommended: read config from a file outside the repo
.\setup-secrets.ps1 -ConfigFile C:\private\vm-config.json

# Optional: require a vault-level password on top of Windows user scope
.\setup-secrets.ps1 -ConfigFile C:\private\vm-config.json -RequireVaultPassword
```

Installs `Microsoft.PowerShell.SecretManagement` and
`Microsoft.PowerShell.SecretStore` if missing, registers the `VmProvisioner`
vault, validates the JSON, and stores it as the `VmProvisionerConfig` secret.
Re-running safely updates the stored config.

**Config file format** — a JSON array, one object per VM:

```jsonc
[
  {
    "vmName":        "ubuntu-01-ci",
    "cpuCount":      2,
    "ramGB":         4,
    "diskGB":        40,
    "ubuntuVersion": "24.04",
    "username":      "u-01-admin",
    "password":      "...",
    "ipAddress":     "192.168.1.101",
    "subnetMask":    "24",
    "gateway":       "192.168.1.1",
    "dns":           "8.8.8.8",
    "vmConfigPath":  "E:\\a_VMs\\Hyper-V\\Config",
    "vhdPath":       "E:\\a_VMs\\Hyper-V\\Disks"
  }
]
```

All fields are required. After first boot, connect via `ssh username@ipAddress`.

| Field           | Type   | Description                                        |
|-----------------|--------|----------------------------------------------------|
| `vmName`        | string | Name in Hyper-V and as the VM's hostname           |
| `cpuCount`      | int    | Number of virtual processors                       |
| `ramGB`         | int    | RAM in GB (static allocation)                      |
| `diskGB`        | int    | OS disk size in GB                                 |
| `ubuntuVersion` | string | Ubuntu release, e.g. `"24.04"`                     |
| `username`      | string | OS user created by cloud-init on first boot        |
| `password`      | string | Password for that user (plain text in vault only)  |
| `ipAddress`     | string | Static IPv4 address assigned inside the VM         |
| `subnetMask`    | string | CIDR prefix length, e.g. `"24"`                    |
| `gateway`       | string | Default gateway — also assigned to the host vNIC   |
| `dns`           | string | DNS server IP                                      |
| `vmConfigPath`  | string | Windows path where seed ISO is written             |
| `vhdPath`       | string | Windows path where VHDX files are stored           |

---

## provision.ps1

Run as Administrator after `setup-secrets.ps1` has stored the config.

```powershell
.\provision.ps1
```

Reads `VmProvisionerConfig` from the vault and for each VM definition:

1. Validates all required fields.
2. Skips the entry if a Hyper-V VM with the same `vmName` already exists
   (idempotent re-runs are safe).
3. Aborts the entry if `ipAddress` responds to a ping (prevents static-IP
   conflicts with existing machines).
4. Downloads the Ubuntu cloud image (`.vhd.tar.gz`) from the Ubuntu CDN into
   `vhdPath` once per `ubuntuVersion`, converts it to `.vhdx`, and caches it.
   On first download it also patches the base image via WSL2 to enable the
   NoCloud cloud-init datasource (required for Hyper-V — the Azure image ships
   with Azure-only datasource config). Subsequent runs reuse the cached,
   patched base image — no re-download or re-patch.
5. Copies the base image to a per-VM disk (`{vmName}.vhdx`) and resizes it
   to `diskGB`.
6. Generates a cloud-init seed ISO (`{vmName}-seed.iso`) in `vmConfigPath`
   containing `meta-data`, `user-data`, and `network-config`. On first boot
   cloud-init reads the ISO to create the OS user, enable SSH, and apply the
   static IP — no interactive installer needed.
7. Creates a Hyper-V Internal switch named `VmLAN` (if absent),
   assigns the `gateway` IP to the host-side virtual NIC, and adds a
   `New-NetNat` rule for the subnet so VMs can reach the internet through
   the host. The host reaches VMs at their static IPs via the same vNIC.
8. Creates each VM (Gen 2, static RAM, VHDX from step 5), sets Secure Boot
   to `MicrosoftUEFICertificateAuthority` (required for Ubuntu), attaches
   the seed ISO, connects to `VmLAN`, and starts the VM. Polls port 22
   until cloud-init finishes, then detaches and deletes the seed ISO.

---

## deprovision.ps1

Run as Administrator to remove VMs that were created by `provision.ps1`.

```powershell
.\deprovision.ps1
```

Reads the same `VmProvisionerConfig` from the vault and for each VM definition:

1. Validates all required fields.
2. Stops the VM if running, then removes it from Hyper-V. If the VM is already
   absent (re-run after a partial failure), the Hyper-V step is skipped and
   only file cleanup is attempted.
3. Deletes the per-VM VHDX (`{vmName}.vhdx`) in `vhdPath`. If Windows VMMS
   still holds a handle after `Remove-VM`, deletion is retried up to 5 times
   at 2-second intervals. If the file is still locked after all retries the
   script throws with the path identified — re-running after a few seconds
   retries the deletion.
4. Deletes the seed ISO (`{vmName}-seed.iso`) in `vmConfigPath` if present.
   `provision.ps1` removes it after first boot, so absence is not an error.
5. Deletes the VM configuration directory (`{vmConfigPath}/{vmName}/`) if
   present, with the same retry logic as the VHDX.

After all VMs are processed:

6. Removes the `VmLAN-NAT` NAT rule, the gateway IP from the host vNIC, and
   the `VmLAN` Internal switch — but only when no VMs remain connected to the
   switch. If VMs outside the config are still attached (e.g. provisioned
   separately), the network teardown is skipped to preserve their connectivity.

**The base Ubuntu image is not deleted.** It is shared across all VMs of the
same Ubuntu version and is not specific to any single config entry. Delete it
manually from `vhdPath` if it is no longer needed.

---

## CI

CI runs on pull requests targeting `master` via `.github/workflows/ci.yml`,
which delegates to the shared reusable workflow in
[Infrastructure-Common](https://github.com/VitaliiAndreev/Infrastructure-Common):

```
VitaliiAndreev/Infrastructure-Common/.github/workflows/ci-powershell.yml@master
```

The shared workflow runs `Run-Tests.ps1` on both PowerShell 5.1 and 7.
No additional CI configuration is needed in this repo.

---

## Repo structure

```
Infrastructure-VM-Provisioner/
|- .github/
|  `- workflows/
|     `- ci.yml              # Delegates to shared ci-powershell.yml in Infrastructure-Common
|- hyper-v/
|  `- ubuntu/
|     |- provision.ps1       # Entry point - orchestrates all provisioning steps
|     |- deprovision.ps1     # Entry point - reverses provision.ps1
|     |- setup-secrets.ps1   # One-time vault setup
|     |- common/
|     |  `- config/
|     |     |- ConvertFrom-VmConfigJson.ps1  # JSON parsing and validation
|     |     `- Get-SanitizedVmDisplay.ps1    # Masks password in diagnostic output
|     |- up/
|     |  |- config/
|     |  |  `- Select-VmsForProvisioning.ps1 # Pre-flight VM-existence and IP-conflict checks
|     |  |- disk/
|     |  |  |- Invoke-DiskImageAcquisition.ps1  # Downloads, converts, caches base VHDX
|     |  |  `- Invoke-BaseImagePatch.ps1        # Patches cloud-init datasource via WSL2
|     |  |- network/
|     |  |  `- setup-network.ps1               # Creates VmLAN switch, host IP, NAT rule
|     |  |- seed/
|     |  |  |- generate-seed-iso.ps1           # Builds cloud-init seed ISO
|     |  |  `- iso.ps1                         # IMAPI2 ISO creation helper
|     |  `- vm/
|     |     `- create-vm.ps1                   # Creates, boots, and polls each VM
|     `- down/
|        |- config/
|        |  `- Assert-GatewayConsistency.ps1 # Validates all VMs share one gateway
|        |- network/
|        |  `- teardown-network.ps1         # Removes NAT rule, host IP, and switch
|        `- vm/
|           `- remove-vm.ps1               # Stops, removes VM, deletes VHDX and config dir
|- Tests/
|  |- common/config/         # Unit tests for common/config helpers
|  |- up/
|  |  |- config/             # Unit tests for up/config helpers
|  |  |- disk/               # Unit tests for up/disk
|  |  |- network/            # Unit tests for up/network
|  |  |- seed/               # Unit tests for up/seed
|  |  `- vm/                 # Unit tests for up/vm
|  `- down/
|     |- config/             # Unit tests for down/config helpers
|     |- network/            # Unit tests for down/network
|     `- vm/                 # Unit tests for down/vm
|- Run-Tests.ps1             # Runs Pester tests (called by ci-powershell.yml)
`- README.md
```

Each scenario follows the `hypervisor/guest-os/` convention. Future scenarios
(e.g. `hyper-v/windows-server/`, `vmware/ubuntu/`) extend the tree without
changing the root structure. Each scenario folder is self-contained — its own
scripts, its own secrets setup, its own README if needed.

**Recommended specs for a self-hosted GitHub Actions runner:**

| Resource | Value  | Reasoning                                                                          |
|----------|--------|------------------------------------------------------------------------------------|
| vCPU     | 2      | Realistic minimum with Docker; stack multiple VMs on a well-resourced host         |
| RAM      | 4 GB   | Leaves headroom for 6–7 VMs on a 64 GB host                                       |
| Disk     | 40 GB  | Covers Ubuntu base (~5 GB), runner agent, Docker image cache, and workspace        |
| OS       | 24.04  | Current LTS; matches the `ubuntu-24.04` GitHub-hosted runner label for parity     |
