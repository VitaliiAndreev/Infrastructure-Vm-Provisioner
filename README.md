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

<!-- TODO: full JSON config reference added in Step 7 -->

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
