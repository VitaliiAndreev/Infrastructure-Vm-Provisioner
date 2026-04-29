# Plan: Drop PowerShell 5.1 Support

See [problem.md](problem.md) for context and scope.

## Index

- [Step 1 - Remove code compromise and stale comments](#step-1)
- [Step 2 - Update version pins, entry point docs, and README](#step-2)

---

## Step 1

**Replace the `Get-Member` shim in `Get-SanitizedVmDisplay` and scrub all
stale PS 5.1 comments from source files.**

Reason: keeping source changes separate from config/docs changes makes the
refactor reviewable in isolation and lets the test suite confirm correctness
before anything operationally significant (version pins) is touched.

### Files changed

| File | Change |
|------|--------|
| `hyper-v/ubuntu/common/config/Get-SanitizedVmDisplay.ps1` | Replace `Get-Member -InputObject $Vm -MemberType NoteProperty` loop with `$Vm.PSObject.Properties` |
| `hyper-v/ubuntu/common/config/ConvertFrom-VmConfigJson.ps1` | Remove lines 51-57 (comment citing "PS 5.1 and PS 7" `Get-Member` rationale; no longer applies now that `Assert-RequiredProperties` uses `PSObject.Properties` and this file no longer contains a `Get-Member` call) |
| `hyper-v/ubuntu/up/config/Select-VmsForProvisioning.ps1` | Line 36-37: remove "in PS 5.1" from the `Get-VM` comment (the `SilentlyContinue` guard is still correct in PS 7 for the same reason); lines 68-71: update `Ping` rationale (code stays; reason changes from "PS 5.1 compat" to "preferred over `Test-Connection` for predictability") |
| `hyper-v/ubuntu/up/vm/create-vm.ps1` | Lines 123-125: update `TcpClient` rationale (code stays; remove "output format differs between PS 5.1 and PS 7") |
| `hyper-v/ubuntu/up/disk/Invoke-BaseImagePatch.ps1` | Line 147: remove the "BOM injected by PowerShell 5.1" bullet from the base64 rationale list; other bullets remain |

### Detail - Get-SanitizedVmDisplay.ps1

Replace:

```powershell
foreach ($member in (Get-Member -InputObject $Vm -MemberType NoteProperty)) {
    $safe[$member.Name] = if ($member.Name -in $Script:SecretFields) {
```

With:

```powershell
foreach ($member in $Vm.PSObject.Properties) {
    $safe[$member.Name] = if ($member.Name -in $Script:SecretFields) {
```

### Tests

No new tests. The existing
`Tests/common/config/Get-SanitizedVmDisplay.Tests.ps1` exercises all
property-enumeration and masking scenarios and will catch any regression.
Run the full unit test suite to confirm green.

---

## Step 2

**Bump module version pins in `setup-secrets.ps1`, update `.NOTES` in the
entry point scripts, and update README.**

Reason: the version pin changes are operationally significant - they
determine which module releases are pulled on a fresh machine. Keeping them
in a separate commit makes the intent clear and allows rolling back the
config change independently of the source cleanup in Step 1.

### Files changed

| File | Change |
|------|--------|
| `hyper-v/ubuntu/setup-secrets.ps1` | Bootstrap guard: `[Version]'1.3.3'` -> `[Version]'2.0.0'`; `Invoke-ModuleInstall` call: `Infrastructure.Secrets -MinimumVersion '2.1.0'` -> `'3.0.0'` |
| `hyper-v/ubuntu/provision.ps1` | `.NOTES` REQUIREMENTS: `"PowerShell 5.1 (ships with Windows 11) or later. PS 7 is recommended but not required."` -> `"PowerShell 7+"` |
| `hyper-v/ubuntu/deprovision.ps1` | Same `.NOTES` change as `provision.ps1` |
| `README.md` | Prerequisites: `PowerShell 5.1+` -> `PowerShell 7+` |

### Tests

No new tests. Run `Run-Tests.ps1` under `pwsh` locally to confirm all unit
tests still pass after the changes.
