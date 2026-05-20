# Infrastructure-VM-Provisioner

> Reusable Windows scripting tooling for automated Hyper-V VM provisioning and removal.

## Index

- [Overview](#overview)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [setup-secrets.ps1](#setup-secretsps1)
  - [Optional: install a JDK](#optional-install-a-jdk)
  - [Removing a JDK](#removing-a-jdk)
  - [Optional: copy files to the VM](#optional-copy-files-to-the-vm)
    - [Bulk entries](#bulk-entries)
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

## Requirements

PowerShell 7+ (`pwsh`). Windows PowerShell 5.1 is not supported.

---

## Quick start

**Prerequisites:** Windows 11 with Hyper-V enabled, PowerShell 7+, and
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
| `switchName`    | string | Hyper-V Internal switch name. Default: `VmLAN`     |
| `natName`       | string | Windows NAT rule name. Default: `VmLAN-NAT`        |
| `javaDevKit`    | object? | Optional. Installs a JDK system-wide on first boot. See [Optional: install a JDK](#optional-install-a-jdk). |
| `files`         | array?  | Optional. Copies arbitrary host files onto the VM. See [Optional: copy files to the VM](#optional-copy-files-to-the-vm). |

### Optional: install a JDK

Add a `javaDevKit` object to any VM entry to install a JDK system-wide on
first boot. When absent, no JDK is installed and the rest of provisioning is
unaffected.

```jsonc
{
  "vmName": "dev-01",
  "...":    "...",
  "javaDevKit": {
    "vendor":  "temurin",
    "version": "21"
  }
}
```

| Sub-field   | Type      | Required | Default | Allowed values                                                |
|-------------|-----------|----------|---------|---------------------------------------------------------------|
| `vendor`    | string    | yes      | —       | `temurin` (Adoptium Temurin — currently the only supported vendor). |
| `version`   | string    | yes      | —       | A **string** in one of four granularities (see below).         |
| `uninstall` | boolean?  | no       | `false` | Set to `true` on a previously provisioned VM to remove the JDK on the next run. See [Removing a JDK](#removing-a-jdk). |

Version-string granularities — pick the level of pinning that suits you:

| Example         | Meaning                                          |
|-----------------|--------------------------------------------------|
| `"21"`          | Latest GA of feature release 21                  |
| `"21.0"`        | Latest GA on the 21.0 line                       |
| `"21.0.5"`      | Latest build of 21.0.5                           |
| `"21.0.5+11"`   | Exact build, no resolution                       |

`version` must be a JSON string. Numeric values like `21` are rejected so that
`"21.0"` cannot silently degrade to `21` through trailing-zero loss, and so
that `"21.0.5+11"` (not a valid JSON number) follows the same rule as the
other granularities.

At provision time the requested granularity is resolved against the
[Adoptium v3 API](https://api.adoptium.net/q/swagger-ui/) to a concrete build
(for example `"21"` -> `21.0.6+7`) along with its SHA-256 and download URL.
The resolved build is then pinned in a host-side lockfile next to the cached
tarball so subsequent provisioning runs reuse the exact same bytes — no
silent upgrades between runs.

**Cache artifacts** — written into `vhdPath` (same directory as the cached
Ubuntu VHDX):

| File                                                | Purpose                                                                 |
|-----------------------------------------------------|-------------------------------------------------------------------------|
| `jdk-{vendor}-{requestedVersion}-linux-x64.tar.gz`  | The Temurin tarball, keyed by the requested (not resolved) version.     |
| `jdk-{vendor}-{requestedVersion}-linux-x64.lock.json` | Sidecar pin recording `resolvedVersion`, `sha256`, `sourceUrl`, and download timestamp. |

The cache key uses the **requested** version, so two VMs that both ask for
`"21"` share one cache slot. The lockfile is authoritative on subsequent
runs — the resolver is not re-invoked — so a `"21"` request cannot silently
upgrade to a newer build between provisionings.

To invalidate the pin:

- **Delete the lockfile** to force re-resolution against the live Adoptium
  API on the next run (use this to pull in a newer build for a coarse
  request like `"21"`).
- **Delete only the tarball** to trigger a self-heal redownload of the
  exact build the lockfile pinned to (useful when the cached file is
  corrupt but the pin is still wanted).

Neither file is committed — the cache lives entirely on the host, same
trust model as the cached Ubuntu VHDX.

**On the VM** — after the VM is up and cloud-init has finished, the
post-provisioning orchestrator pushes the cached tarball over its
already-open SSH session via the host file server (the same mechanism
`Infrastructure-GitHubRunners` uses to ship the actions-runner binary).
The `Install-Jdk` step then streams the tarball through `tar` directly
into the install directory (no intermediate file on the VM disk) and
writes a system-wide environment script:

| Location                              | Purpose                                                                          |
|---------------------------------------|----------------------------------------------------------------------------------|
| `/opt/jdk-{vendor}-{resolvedVersion}/` | Install root. Path embeds the *resolved* build so coexisting installs do not collide if the requested version is later bumped. |
| `/etc/profile.d/jdk.sh`               | Exports `JAVA_HOME` and prepends `$JAVA_HOME/bin` to `PATH`. Sourced by every login shell automatically. |

The install runs **out-of-band**, not via cloud-init `runcmd`. cloud-init's
job is to bootstrap the OS; the provisioner installs optional software.
Same pattern as the runner install in Infrastructure-GitHubRunners. This
keeps the seed ISO's lifecycle short (it carries the plaintext admin
password and is detached as soon as SSH is reachable) and avoids putting
cloud-init stage knowledge into the host provisioner.

Because the export script lives under `/etc/profile.d/`, any user account
later created on the VM — including those provisioned by
[Infrastructure-Vm-Users](https://github.com/VitaliiAndreev/Infrastructure-Vm-Users) —
sees `JAVA_HOME` and `java` on `PATH` without any additional configuration
in that repo. This is the deliberate split of responsibilities: the
provisioner owns "software the box needs"; Vm-Users owns identities.

The extraction step is idempotent — if the install directory's `release`
file already exists, re-runs of `provision.ps1` are a no-op for the JDK
step.

### Removing a JDK

To remove a previously installed JDK from a long-lived VM without
rebuilding it, set `javaDevKit.uninstall` to `true` on the same VM entry
and re-run `provision.ps1`:

```jsonc
{
  "vmName": "dev-01",
  "...":    "...",
  "javaDevKit": {
    "vendor":    "temurin",
    "version":   "21",
    "uninstall": true
  }
}
```

`vendor` and `version` stay required so the schema is uniform whether the
operator is installing or uninstalling. The removal step uses only
`vendor` (as the `/opt/jdk-{vendor}-*` install-dir prefix); `version` is
ignored.

On the VM, the removal step deletes `/opt/jdk-{vendor}-*` (matched by
vendor prefix glob — the v1 invariant is one JDK per VM, so the prefix
uniquely identifies the install), `/etc/profile.d/jdk.sh`, and any
`/usr/local/bin` symlinks pointing into the removed install dir (the
non-login-shell `PATH` wiring written by `Install-Jdk`). An empty glob
match is a clean no-op.

The provisioner does **not** rewrite the input JSON after a successful
removal — the flag stays. Re-running with the flag still set is a clean
no-op (everything is already gone), so it is safe to leave. When the
operator is truly done with the JDK on that VM, delete the whole
`javaDevKit` block in one explicit edit.

The host-side tarball cache under `vhdPath` is **not** touched — it is
keyed by `{vendor, requestedVersion}` and may be shared with other VMs
that still want the install.

### Optional: copy files to the VM

Add a `files` array to any VM entry to copy arbitrary host files onto the
VM after cloud-init finishes. Each entry is a `{ source, target }` pair —
local Windows path on the host, absolute Linux path on the VM.

```jsonc
{
  "vmName": "dev-01",
  "...":    "...",
  "files": [
    { "source": "C:\\jars\\mylib-1.0.jar", "target": "/opt/lib/mylib-1.0.jar" },
    { "source": "C:\\fixtures\\seed.json", "target": "/var/data/seed.json" }
  ]
}
```

| Sub-field | Required | Notes                                                                  |
|-----------|----------|------------------------------------------------------------------------|
| `source`  | yes      | Windows path. **Must exist at validation time** — typos fail before any VM work begins. |
| `target`  | yes      | Absolute Linux path on the VM (must start with `/`). Parent directory is created if absent. |

The copy is performed over the same SSH session and host file server used
by other post-provisioning steps (see [provision.ps1](#provisionps1) step
10). The actual file transfer is delegated to
`Infrastructure.HyperV`'s `Copy-VmFiles` cmdlet — the validator that
backs the schema (`Assert-VmFilesField`) also lives there. Both are
reused by `Infrastructure-Vm-Users` for its own (user-owned) file copies.
Re-runs overwrite the target file with the current host source —
the user's intent is "this file should look like this".

**Ownership model in the provisioner**: every file copied by this step
lands `root:root, 0644`. The provisioner runs *before* user creation, so
no app users exist yet to chown to. Files needing a per-user owner belong
in `Infrastructure-Vm-Users`'s `files` array, which runs after that step
creates the users.

`files` is **purely user data** — no install step (JDK, future Maven, …)
reads from these paths. Each install is self-contained. This keeps the
contract simple: the user owns the target paths and what lives there.

#### Bulk entries

For a directory of related files (a JAR classpath, a fixtures tree, ...),
a bulk entry copies every match of a host wildcard under one VM target
directory without enumerating each file in the config. Single and bulk
entries can be mixed freely in the same `files` array.

```jsonc
{
  "vmName": "ci-01",
  "...":    "...",
  "files": [
    { "pattern": "C:\\jars\\*.jar", "targetDir": "/opt/ci-jars" }
  ]
}
```

| Sub-field              | Required | Default | Notes                                                                                                  |
|------------------------|----------|---------|--------------------------------------------------------------------------------------------------------|
| `pattern`              | yes      | —       | Host-side wildcard accepted by `Get-ChildItem -Path`. Must match at least one file when the transport runs. |
| `targetDir`            | yes      | —       | Absolute Linux directory on the VM (must start with `/`). Created if absent.                            |
| `recurse`              | no       | `false` | Descend into subdirectories of `pattern`'s root.                                                        |
| `preserveRelativePath` | no       | `false` | Mirror the host subtree under `targetDir` instead of flattening every match to its basename. Useful for a Maven-style tree. |

`source` and `pattern` are mutually exclusive on a single entry — mixing
them is a validation error so the intent stays unambiguous. Bulk entries
land `root:root, 0644`, same as single entries, with the same ownership
rationale described above.

Each bulk entry runs as its own `Copy-VmFilesByPattern` call, dispatched
in JSON order alongside any single entries in the same array. Errors
(zero matches, target-path collisions) are reported per entry, before
any SSH I/O happens for that entry — so a misspelled pattern names
itself in the failure instead of being lost in a batched run.

The transport is delegated to `Infrastructure.HyperV`'s
[`Copy-VmFilesByPattern`](https://github.com/VitaliiAndreev/Infrastructure-HyperV/blob/master/Infrastructure.HyperV/Public/FileTransfer/Copy-VmFilesByPattern.ps1) —
see its notes for the exact wildcard semantics (including the zero-match
and target-collision pre-flight errors raised before any SSH I/O).

---

## provision.ps1

Run as Administrator after `setup-secrets.ps1` has stored the config.

```powershell
.\provision.ps1
```

Reads `VmProvisionerConfig` from the vault and for each VM definition:

1. Validates all required fields.
2. Classifies each entry as **new** (no Hyper-V VM with this `vmName`
   exists AND the `ipAddress` is silent), **existing** (Hyper-V VM
   exists AND the `ipAddress` responds — the VM is up), or **skipped**
   (any other combination). New VMs get the full destructive pipeline;
   existing VMs are *reconciled* — only the idempotent additive steps
   (host-side acquisitions and post-provisioning) run, so adding
   `javaDevKit` / `files` / etc. to a VM definition and re-running
   `provision.ps1` pushes the change without re-creating the VM. The
   two skipped cases get a warning explaining why:
   - VM is absent but the IP responds → static-IP conflict with an
     unknown machine.
   - VM exists but the IP does not respond → VM is offline; start it
     and re-run.

   The steps below note which classifications they apply to.
3. **(new VMs only)** Downloads the Ubuntu cloud image (`.vhd.tar.gz`)
   from the Ubuntu CDN into `vhdPath` once per `ubuntuVersion`, converts
   it to `.vhdx`, and caches it. On first download it also patches the
   base image via WSL2 to enable the NoCloud cloud-init datasource
   (required for Hyper-V — the Azure image ships with Azure-only
   datasource config). Subsequent runs reuse the cached, patched base
   image — no re-download or re-patch.
4. **(new VMs only)** Copies the base image to a per-VM disk
   (`{vmName}.vhdx`) and resizes it to `diskGB`.
5. **(new AND existing VMs)** Runs host-side acquisitions for each VM
   via a small per-VM orchestrator (`Invoke-VmAcquisitions`). Today it
   dispatches one acquirer:
   - **`javaDevKit`** acquires the requested Temurin tarball into
     `vhdPath` (see [Optional: install a JDK](#optional-install-a-jdk)).
     Skipped when `javaDevKit.uninstall` is `true` - no tarball is needed
     for the removal path.

   Skipped silently for VMs that have no opt-in fields. Each acquirer is
   idempotent via its on-host lockfile, so a re-run against an already-
   cached artefact is cheap. New acquirers plug in as one dispatch line
   in the orchestrator, not a new step here.
6. **(new VMs only)** Generates a cloud-init seed ISO
   (`{vmName}-seed.iso`) in `vmConfigPath` containing `meta-data`,
   `user-data`, and `network-config`. On first boot cloud-init reads the
   ISO to create the OS user, enable SSH, and apply the static IP - no
   interactive installer needed.
7. **(always)** Creates a Hyper-V Internal switch named `VmLAN` (if
   absent), assigns the `gateway` IP to the host-side virtual NIC, and
   adds a `New-NetNat` rule for the subnet so VMs can reach the internet
   through the host. Idempotent; runs even when only existing VMs are
   being reconciled so a rebuilt host gets the network re-applied.
8. **(new VMs only)** Creates each VM (Gen 2, static RAM, VHDX from
   step 4), sets Secure Boot to `MicrosoftUEFICertificateAuthority`
   (required for Ubuntu), attaches the seed ISO, connects to `VmLAN`,
   and starts the VM. Polls port 22 until cloud-init finishes, then
   detaches and deletes the seed ISO.
9. **(new AND existing VMs)** Runs post-provisioning. Opens one host file server and
    one SSH session per VM, waits once for cloud-init to finish, then
    dispatches each enabled step:
    - **`files`** copies host files to declared VM paths (each entry is
      dispatched in JSON order: single entries via `Copy-VmFiles`, bulk
      entries via `Copy-VmFilesByPattern`; see
      [Optional: copy files to the VM](#optional-copy-files-to-the-vm)).
    - **`javaDevKit`** extracts the prefetched Temurin tarball into
      `/opt/jdk-{vendor}-{resolvedVersion}/` and writes
      `/etc/profile.d/jdk.sh`
      (see [Optional: install a JDK](#optional-install-a-jdk)).
      When `javaDevKit.uninstall` is `true`, the orchestrator dispatches
      the removal step instead (deletes `/opt/jdk-{vendor}-*`,
      `/etc/profile.d/jdk.sh`, and stale `/usr/local/bin` symlinks) —
      see [Removing a JDK](#removing-a-jdk).

    Each step is self-contained — no step consumes files left by another
    step. Adding a new step (e.g. Maven) is a one-function addition with
    one dispatch line in `Invoke-VmPostProvisioning`. Skipped silently
    for VMs that have no opt-in fields. Idempotent on the VM side: the
    JDK install no-ops when its `release` file is already present, file
    copies overwrite with the current host source bytes.

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
   with exponential backoff (capped at 30 s) via `Invoke-WithRetry` from
   `Infrastructure.Common` using the file-lock retry strategy. If the file is
   still locked after all retries the script throws with the path identified
   — re-running after a few seconds retries the deletion.
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

The shared workflow runs `Run-Tests.ps1` on PowerShell 7.
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
|     |     |- ConvertFrom-VmConfigJson.ps1  # JSON parsing and validation; delegates the optional 'files' array to Infrastructure.HyperV's Assert-VmFilesField
|     |     |- Assert-JavaDevKitField.ps1    # Validates optional javaDevKit field
|     |     `- Get-SanitizedVmDisplay.ps1    # Masks password in diagnostic output
|     |- up/
|     |  |- config/
|     |  |  `- Select-VmsForProvisioning.ps1 # Pre-flight VM-existence and IP-conflict checks
|     |  |- disk/
|     |  |  |- Invoke-DiskImageAcquisition.ps1  # Downloads, converts, caches base VHDX
|     |  |  `- Invoke-BaseImagePatch.ps1        # Patches cloud-init datasource via WSL2
|     |  |- jdk/
|     |  |  |- Resolve-AdoptiumRelease.ps1      # Resolves version granularity via Adoptium v3 API
|     |  |  `- Invoke-JdkAcquisition.ps1        # Downloads + verifies tarball, writes lockfile pin
|     |  |- acquire/
|     |  |  `- Invoke-VmAcquisitions.ps1        # Per-VM host-side acquisition orchestrator; dispatches each per-software acquirer guarded by its opt-in field
|     |  |- post/
|     |  |  |- Invoke-VmPostProvisioning.ps1    # Per-VM transport orchestrator (file server + SSH + cloud-init wait), dispatches steps; calls Infrastructure.HyperV's Copy-VmFiles for the 'files' step
|     |  |  |- Install-Jdk.ps1                  # Step: extracts the prefetched JDK tarball and writes /etc/profile.d/jdk.sh
|     |  |  `- Uninstall-Jdk.ps1                # Step: removes /opt/jdk-{vendor}-*, /etc/profile.d/jdk.sh, and stale /usr/local/bin symlinks
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
|  |  |- jdk/                # Unit tests for up/jdk
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
