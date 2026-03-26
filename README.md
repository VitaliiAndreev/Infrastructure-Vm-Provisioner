# Infrastructure-VM-Provisioner

> Reusable Windows scripting tooling for automated Hyper-V VM provisioning.

## Index

- [Overview](#overview)
- [Quick start](#quick-start)
- [setup-secrets.ps1](#setup-secretsps1)
- [provision.ps1](#provisionps1)
- [Repo structure](#repo-structure)

---

## Overview

<!-- TODO: expand in Step 7 -->

Automates creation of Hyper-V VMs on Windows 11, with Ubuntu installed and a
default user configured via cloud-init. All parameters are stored in an
encrypted local vault — nothing sensitive is committed to the repo.

See [BRIEF.md](BRIEF.md) for full project context.

---

## Quick start

```powershell
# 1. Store config in the local vault (once per machine)
.\hyper-v\ubuntu\setup-secrets.ps1 -ConfigFile C:\private\vm-config.json

# 2. Provision VMs (run as Administrator)
.\hyper-v\ubuntu\provision.ps1
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
`Microsoft.PowerShell.SecretStore` if missing, registers the `VmLAN`
vault, validates the JSON, and stores it as the `VmLANConfig` secret.
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
    "vmConfigPath":  "D:\\Hyper-V\\Config",
    "vhdPath":       "D:\\Hyper-V\\Disks"
  }
]
```

All fields are required. After first boot, connect via `ssh username@ipAddress`.

<!-- TODO: full field descriptions added in Step 7 -->

---

## provision.ps1

Run as Administrator after `setup-secrets.ps1` has stored the config.

```powershell
.\provision.ps1
```

Reads `VmLANConfig` from the vault and for each VM definition:

1. Validates all required fields.
2. Skips the entry if a Hyper-V VM with the same `vmName` already exists
   (idempotent re-runs are safe).
3. Aborts the entry if `ipAddress` responds to a ping (prevents static-IP
   conflicts with existing machines).
4. Downloads the Ubuntu cloud image (`.vhd.zip`) from the Ubuntu CDN into
   `vhdPath` once per `ubuntuVersion`, converts it to `.vhdx`, and caches
   it. Subsequent runs reuse the cached base image — no re-download.
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

<!-- TODO: Step 6 (VM creation) details added when implemented -->

---

## Repo structure

```
Infrastructure-VM-Provisioner/
├── hyper-v/
│   └── ubuntu/
│       ├── provision.ps1       # Main provisioning script
│       ├── setup-secrets.ps1   # One-time vault setup
│       ├── common.ps1          # Shared helpers (config parsing, secret display)
│       └── iso.ps1             # Seed ISO creation (provision.ps1 only)
├── BRIEF.md
└── README.md
```

Each scenario follows the `hypervisor/guest-os/` convention. Future scenarios
(e.g. `hyper-v/windows-server/`, `vmware/ubuntu/`) extend the tree without
changing the root structure.
