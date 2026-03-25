# Infrastructure-VM-Provisioner

> Reusable Windows scripting tooling for automated Hyper-V VM provisioning.

## Index

- [Overview](#overview)
- [setup-secrets.ps1](#setup-secretsps1)
- [Repo structure](#repo-structure)

---

## Overview

<!-- TODO: expand in Step 7 -->

Automates creation of Hyper-V VMs on Windows 11, with Ubuntu installed and a
default user configured via cloud-init. All parameters are stored in an
encrypted local vault — nothing sensitive is committed to the repo.

See [BRIEF.md](BRIEF.md) for full project context.

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
    "vmConfigPath":  "D:\\Hyper-V\\Config",
    "vhdPath":       "D:\\Hyper-V\\Disks"
  }
]
```

All fields are required. After first boot, connect via `ssh username@ipAddress`.

<!-- TODO: full field descriptions added in Step 7 -->

---

## Repo structure

```
Infrastructure-VM-Provisioner/
├── hyper-v/
│   └── ubuntu/
│       ├── provision.ps1       # Main provisioning script
│       └── setup-secrets.ps1   # One-time vault setup
├── BRIEF.md
└── README.md
```

Each scenario follows the `hypervisor/guest-os/` convention. Future scenarios
(e.g. `hyper-v/windows-server/`, `vmware/ubuntu/`) extend the tree without
changing the root structure.
