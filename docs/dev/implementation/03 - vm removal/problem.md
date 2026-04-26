# Problem: VM Removal

## Index

- [What we are changing](#what-we-are-changing)
- [For the layman](#for-the-layman)
- [Constraints](#constraints)

---

## What we are changing

`provision.ps1` creates Hyper-V VMs but there is no corresponding
removal path. When a VM is no longer needed the operator must manually
stop and delete it, remove its disk file, and clean up the shared
network objects if no other VMs remain. Each of those steps is easy to
get wrong (wrong file path, leftover NAT rule, lingering VHDX).

We are adding `deprovision.ps1` - the exact reverse of `provision.ps1`.
It reads the same `VmProvisionerConfig` vault secret, stops and removes
each VM, deletes per-VM disk and seed ISO artefacts, and tears down the
shared network when no VMs remain.

See [plan.md](plan.md) for the step-by-step implementation.

---

## Constraints

**Network is shared.**
The `VmLAN` virtual switch, host vNIC IP address, and NAT rule are
created once and shared across all VMs. They must not be removed until
the last VM is deprovisioned. Removing the switch while other VMs are
connected would drop their network access.

**Base image is preserved.**
The cached base VHDX (`ubuntu-{version}-server-cloudimg-amd64.vhdx`)
and its sentinel file are not deleted. They represent significant
download and patching work and are needed for re-provisioning.

**Seed ISO may already be absent.**
`provision.ps1` removes the seed ISO from the DVD drive and deletes the
file after the VM's first boot completes. Deprovisioning must tolerate
its absence without throwing.

**Operation is irreversible.**
VMs, their configuration directories, and per-VM VHDX files are
permanently deleted. There is no undo.

**No SSH required.**
All operations are local Hyper-V and filesystem calls. No SSH session
is opened.
