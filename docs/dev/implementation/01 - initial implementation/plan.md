---
# Implementation Plan

## Index
- [Step 1 — Repo skeleton](#step-1--repo-skeleton)
- [Step 2 — setup-secrets.ps1](#step-2--setup-secretsps1)
- [Step 3 — provision.ps1: vault read + validation](#step-3--provisionps1-vault-read--validation)
- [Step 4 — provision.ps1: disk image acquisition](#step-4--provisionps1-disk-image-acquisition)
- [Step 5 — provision.ps1: cloud-init seed ISO](#step-5--provisionps1-cloud-init-seed-iso)
- [Step 6 — provision.ps1: virtual switch and NAT](#step-6--provisionps1-virtual-switch-and-nat)
- [Step 7 — provision.ps1: VM creation](#step-7--provisionps1-vm-creation)
- [Step 8 — README.md](#step-8--readmemd)

---

## Step 1 — Repo skeleton

**What:** Create the directory structure and placeholder files.

```
hyper-v/
└── ubuntu/
    ├── provision.ps1       (empty)
    └── setup-secrets.ps1   (empty)
README.md                   (stub)
```

**Why:** Establishes the `hypervisor/guest-os/` convention from
[BRIEF.md](../../../BRIEF.md) before any code is written; every subsequent
step has a clear home.

---

## Step 2 — setup-secrets.ps1

**What:** Script that:
1. Installs `Microsoft.PowerShell.SecretManagement` +
   `Microsoft.PowerShell.SecretStore` if not already present.
2. Registers a `SecretStore` vault named `VmProvisioner` (no-prompt,
   password-protected or passwordless per user choice).
3. Accepts a JSON string (or path to a JSON file) and stores it as the
   `VmProvisionerConfig` secret.
4. Prints a confirmation and advises the user to run `provision.ps1`.

**Why:** Decouples sensitive config from the repo. Needs to exist and be
tested before `provision.ps1` can read from it.

```mermaid
graph TD
    subgraph Host["Windows Host"]
        User -->|runs| SS[setup-secrets.ps1]
        SS -->|Install-Module if missing| PSGallery[PowerShell Gallery]
        SS -->|Register-SecretVault| Vault[(VmProvisioner vault)]
        SS -->|Set-Secret VmProvisionerConfig| Vault
    end
```

---

## Step 3 — provision.ps1: vault read + validation

**What:** Opening section of `provision.ps1` that:
1. Reads the `VmProvisionerConfig` secret (JSON array).
2. Parses and validates required fields per VM entry.
3. Checks each VM name against existing Hyper-V VMs — skips if found.
4. Checks each `ipAddress` with a `Test-Connection` / ping sweep —
   aborts that entry if the IP is already in use.
5. Emits structured `Write-Host` / `Write-Warning` output for each decision.

**Why:** Idempotency and safety checks are the core value of the script;
implementing them first makes all subsequent steps testable in isolation.

```mermaid
graph TD
    subgraph Host["Windows Host"]
        P[provision.ps1] -->|Get-Secret| Vault[(VmProvisioner vault)]
        Vault -->|JSON array| P
        P -->|Get-VM| HyperV[Hyper-V]
        P -->|Test-Connection| Network[Network]
        P -->|Skip / Abort / Proceed| DecisionLog[Console output]
    end
```

---

## Step 4 — provision.ps1: disk image acquisition

**What:** For each VM entry that passes validation:
1. Derive the Ubuntu `.vhdx` download URL from `ubuntuVersion`.
2. If the base `.vhdx` already exists in `vhdPath`, skip download.
3. Otherwise download it (with progress output).
4. Copy (not move) the base image to a per-VM differencing or flat copy
   so the base stays reusable.

**Why:** Downloading a multi-GB image on every run would be wasteful; caching
the base image makes repeated provisioning fast.

```mermaid
graph TD
    subgraph Host["Windows Host"]
        P[provision.ps1] -->|check exists| LocalDisk[(vhdPath)]
        LocalDisk -->|missing| DL[Invoke-WebRequest]
        DL -->|.vhdx| LocalDisk
        LocalDisk -->|Copy-Item per VM| VMDisk[(per-VM .vhdx)]
    end
    DL -->|URL derived from ubuntuVersion| Ubuntu[Ubuntu releases CDN]
```

---

## Step 5 — provision.ps1: cloud-init seed ISO

**What:** For each VM, generate:
- `meta-data` (instance-id, local-hostname)
- `user-data` covering:
  - OS user + hashed password
  - SSH server enabled (`openssh-server` installed via `packages:`)
  - Password SSH auth enabled (`ssh_pwauth: true`)
  - Netplan static IP config written under `/etc/netplan/`

Then pack them into a FAT-formatted ISO (`seed.iso`) using
`New-IsoFile` or `oscdimg.exe` (ships with Windows ADK / available via
`mkisofs` if installed), placed alongside the VM disk.

**Why:** Cloud-init is the only mechanism to inject user credentials and
network config into the Ubuntu cloud image without an interactive installer.
The seed ISO is mounted as a second drive; cloud-init reads it on first boot.
SSH must be configured here — the cloud image has `openssh-server` disabled
by default and the port is not open until cloud-init enables it.

```mermaid
sequenceDiagram
    participant P as provision.ps1
    participant Disk as vmConfigPath
    participant CI as cloud-init
    participant VM as Ubuntu VM
    participant User

    P->>Disk: write meta-data
    P->>Disk: write user-data
    P->>Disk: write network-config
    P->>Disk: New-SeedIso -> seed.iso
    Note over CI,VM: first boot (Step 6)
    CI->>Disk: reads seed.iso
    CI->>VM: creates OS user + hashes password
    CI->>VM: applies netplan static IP
    CI->>VM: installs + enables openssh-server
    User->>VM: ssh username@ipAddress
```

---

## Step 6 — provision.ps1: virtual switch and NAT

**What:** Once, before any VM is created:
1. If a switch named `VmLAN` already exists, skip creation (idempotent).
2. `New-VMSwitch -SwitchType Internal` — creates a host-only virtual NIC;
   VMs on this switch can reach the host but not the physical network directly.
3. Assign the gateway IP from config to the host-side virtual NIC
   (`New-NetIPAddress`), using `subnetMask` as the prefix length.
4. If a NAT rule named `VmLAN-NAT` already exists, skip creation.
5. `New-NetNat` covering the same subnet — routes VM traffic out through the
   host's physical NIC so VMs can reach the internet (needed for cloud-init
   package installs on first boot).

**Why:** An Internal switch is the correct Hyper-V type for host-to-VM-only
access — no traffic leaves the host on the physical NIC unless NAT is added.
The `gateway` and `subnetMask` fields already in the config supply all the
information needed; no new config fields are required.
The switch name `VmLAN` is fixed so operators know exactly what was
created; it does not need to be configurable.

```mermaid
sequenceDiagram
    participant P as provision.ps1
    participant HV as Hyper-V
    participant Host as Host NIC
    participant NAT as Windows NAT

    P->>HV: New-VMSwitch VmLAN (Internal)
    HV->>Host: creates virtual NIC (vEthernet)
    P->>Host: New-NetIPAddress gateway/subnetMask
    P->>NAT: New-NetNat VmLAN-NAT (subnet)
    Note over Host,NAT: VMs reach internet via host NAT
    Note over P,Host: Host reaches VMs via vEthernet IP
```

---

## Step 7 — provision.ps1: VM creation

**What:** For each validated VM entry:
1. `New-VM` with the correct generation (Gen 2), memory, CPU, and vhd path.
2. Attach the seed ISO as a DVD drive.
3. Set Secure Boot template to `MicrosoftUEFICertificateAuthority`
   (required for Ubuntu Gen 2).
4. Connect to the specified virtual switch.
5. `Start-VM`.
6. Poll TCP port 22 on `ipAddress` until SSH is reachable (cloud-init done).
7. Detach the DVD drive (`Remove-VMDvdDrive`) and delete the seed ISO file.
8. Emit status output.

**Why:** This is the final assembly step — all prior steps feed into it.
Kept separate so the VM-creation logic is reviewable independently.
Deleting the seed ISO in the script (rather than leaving it to the operator)
removes the plaintext-password exposure automatically — no manual cleanup step.

```mermaid
sequenceDiagram
    participant P as provision.ps1
    participant HV as Hyper-V
    participant VM as Ubuntu VM
    participant CI as cloud-init

    P->>HV: New-VM (Gen 2, CPU, RAM, vhd)
    P->>HV: Add-VMDvdDrive seed.iso
    P->>HV: Set-VMFirmware (Secure Boot: MicrosoftUEFI)
    P->>HV: Connect-VMNetworkAdapter -> vSwitch
    P->>HV: Start-VM
    HV->>VM: boots
    VM->>CI: first boot triggers cloud-init
    CI-->>VM: user, SSH, network configured
    loop poll port 22
        P->>VM: TCP :22
    end
    P->>HV: Remove-VMDvdDrive
    P->>P: Remove-Item seed.iso
```

---

## Step 8 — README.md

**What:** Root `README.md` covering:
- Prerequisites (Hyper-V, PowerShell, modules, virtual switch) — note that
  **PS 5.1 (ships with Windows 11) is sufficient**; PS 7 is recommended but
  not required. State this explicitly so operators don't install PS 7
  unnecessarily.
- Quick start (setup-secrets → provision).
- JSON config reference (all fields, types, example) — including
  `sshPublicKey`.
- How to SSH into a provisioned VM.
- Idempotency and safety behaviour.
- Repo structure and extension guide.

**Why:** Required by [AGENTS.md](../../../AGENTS.md) (updated after each
step); also the primary onboarding document for anyone consuming this repo.

```mermaid
graph TD
    subgraph Docs["Documentation"]
        README[README.md] -->|references| SS[setup-secrets.ps1]
        README -->|references| P[provision.ps1]
        README -->|references| BRIEF[BRIEF.md]
    end
```
