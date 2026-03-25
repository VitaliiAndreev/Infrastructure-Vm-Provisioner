# Infrastructure-VM-Provisioner

> Reusable Windows scripting tooling for automated Hyper-V VM provisioning.

## Index

- [Overview](#overview)
- [Repo structure](#repo-structure)

---

## Overview

<!-- TODO: expand in Step 7 -->

Automates creation of Hyper-V VMs on Windows 11, with Ubuntu installed and a
default user configured via cloud-init. All parameters are stored in an
encrypted local vault — nothing sensitive is committed to the repo.

See [BRIEF.md](BRIEF.md) for full project context.

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
