---
# Problem Statement

## Index
- [What we're building](#what-were-building)
- [For the layperson](#for-the-layperson)
- [Constraints](#constraints)
- [Out of scope](#out-of-scope)

---

## What we're building

Two PowerShell scripts under `hyper-v/ubuntu/` that together automate the
creation of one or more Ubuntu VMs on a Windows 11 Hyper-V host:

| Script | Role |
|---|---|
| `setup-secrets.ps1` | One-time: installs SecretManagement modules, registers local vault, stores the JSON VM config |
| `provision.ps1` | Idempotent: reads config from vault, validates IPs, creates VMs, injects cloud-init seed ISO |

A `README.md` documenting usage is also required.

---

## For the layperson

Imagine you want to spin up several Linux virtual machines on your Windows PC —
each with its own name, memory, IP address, and login. Doing this by hand
through the Hyper-V UI is tedious and error-prone.

These two scripts automate the process:

1. **`setup-secrets.ps1`** — run once to store all VM settings (names,
   passwords, IPs, etc.) in an encrypted vault on your PC. Nothing sensitive
   ever touches the repo.
2. **`provision.ps1`** — run whenever you want to create (or re-run safely on
   already-created) VMs. It reads the vault, checks whether each VM already
   exists and whether the IP is free, downloads the Ubuntu disk image if
   needed, then creates each VM and drops in a cloud-init config so Ubuntu
   sets up the right user and static IP on first boot.

---

## Constraints

- Windows 11 Pro/Enterprise with Hyper-V enabled (built-in).
- PowerShell 5.1+ (ships with Windows; 7+ preferred for module compat).
- Modules: `Microsoft.PowerShell.SecretManagement`,
  `Microsoft.PowerShell.SecretStore` (installed by `setup-secrets.ps1`).
- Ubuntu cloud image (`.vhdx`) sourced from official Ubuntu releases — no
  interactive installer.
- Static IP configured inside the VM via **cloud-init / netplan**; Hyper-V
  provides the NIC, not the IP.
- Scripts run manually on a Windows workstation — not in CI.

---

## Out of scope

- Other hypervisors or guest OSes (folder structure accommodates them later).
- Shared utility libraries.
- Cross-platform support.

See [BRIEF.md](../../../BRIEF.md) for full context.
