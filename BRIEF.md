# Infrastructure-VM-Provisioner — Project Brief

## Purpose
General-purpose, reusable Windows scripting tooling for automated VM provisioning.
Not specific to any single project; intended to be consumed by other projects (e.g. synergy-ops).

## Repository
**Name:** `Infrastructure-Vm-Provisioner`
**Namespace:** Standalone — part of a polyrepo `infra-<scenario>` family.
**Audience:** DevOps / IaC use — sits in the provisioning/infrastructure layer.

## Structure
Polyrepo. Each infra scenario lives in its own repo. No shared repo yet.

## Goal
Automate creation of a Hyper-V VM on Windows 11, with Ubuntu installed and a default user configured — all values injectable, script reusable across environments.

## Key Decisions

### Hypervisor: Hyper-V
- Built into Windows 11 Pro/Enterprise — no installer step needed.
- All provisioning via PowerShell (`New-VM`, etc.).
- Ubuntu user/password injection via **cloud-init** (seed ISO).

### OS: Ubuntu (latest stable, recommended)
- Use official Ubuntu cloud image (`.vhdx`) to skip interactive installer.
- cloud-init handles first-boot configuration.

### Parameters: Single JSON Secret via SecretManagement

All parameters are stored as a **single JSON secret** in the local vault under the key `VmProvisionerConfig`. The JSON defines an array of VM definitions — the script iterates over each entry.

Secrets are stored locally using **PowerShell SecretManagement + SecretStore** (Microsoft's official local encrypted vault). The vault is AES-256 encrypted, scoped to the Windows user account — nothing is committed to the repo.

**Modules required:**
- `Microsoft.PowerShell.SecretManagement`
- `Microsoft.PowerShell.SecretStore`

**JSON structure:**
```json
[
  {
    "vmName": "ubuntu-01-ci",
    "cpuCount": 2,
    "ramGB": 4,
    "diskGB": 40,
    "ubuntuVersion": "24.04",
    "username": "u-01-admin",
    "password": "...",
    "ipAddress": "192.168.1.101",
    "subnetMask": "24",
    "gateway": "192.168.1.1",
    "dns": "8.8.8.8",
    "vmConfigPath": "D:\\Hyper-V\\Config",
    "vhdPath": "D:\\Hyper-V\\Disks"
  }
]
```

**Runtime usage:**
```powershell
.\provision.ps1
# Reads VMProvisionerConfig from vault, iterates over VM definitions.
```

### Script Behaviour

- **VM existence check** — skips creation if a VM with the same `vmName` already exists in Hyper-V
- **IP existence check** — checks whether `ipAddress` is already in use on the network before provisioning; aborts that entry if a conflict is detected
- **Static IP** — configured inside the VM via cloud-init (netplan); the Hyper-V virtual switch provides the network interface, IP assignment happens at the OS level on first boot

### Repo Scripts

| Script | Purpose |
|---|---|
| `setup-secrets.ps1` | One-time setup: installs SecretManagement modules, registers vault, stores the JSON config secret |
| `provision.ps1` | Main provisioning script — reads JSON from vault, checks VM and IP existence, creates VMs, configures Ubuntu via cloud-init |

#### Example — Self-Hosted GitHub Actions Runner (recommended specs)

#### Default VM Specs — Self-Hosted GitHub Actions Runner

```powershell
.\provision.ps1
# All configuration read from vault. No runtime arguments needed.
```

**Recommended specs per VM:**
- **2 vCPU / 4 GB RAM** — realistic minimum with Docker; leaves ample host headroom to stack multiple VMs on a well-resourced workstation (e.g. 64 GB host can comfortably run 6-7 VMs at this allocation with headroom for Windows)
- **40 GB disk** — sufficient with cleanup pipelines in place; covers Ubuntu base (~5 GB), runner agent, Docker image cache, and workspace
- **Ubuntu 24.04 LTS** — current long-term support release; matches the `ubuntu-24.04` GitHub-hosted runner label for parity

### Execution Context
- Scripts run **manually on Windows** (not via CI runners).

### Runner Strategy (broader context)
- Other `infra-*` repos may use self-hosted GitHub Actions runners.
- Runner scope (repo-level vs org-level) decided per repo.
- This repo: manual execution only.

## Repo Structure

The repo is scoped to VM provisioning across any hypervisor and guest OS. Each scenario lives under a `hypervisor/guest-os/` path. New scenarios must follow this convention.

```
Infrastructure-VM-Provisioner/
├── hyper-v/
│   └── ubuntu/
│       ├── provision.ps1
│       └── setup-secrets.ps1
├── BRIEF.md
└── README.md
```

Future scenarios extend the tree without changing the root structure:

```
├── hyper-v/
│   ├── ubuntu/
│   └── windows-server/
├── vmware/
│   └── ubuntu/
└── ...
```

Each scenario folder is self-contained — its own scripts, its own secrets setup, its own README if needed.

## Out of Scope (for now)
- Shared utility libraries across infra repos.
- Cross-platform support (Windows-only by design).
