# Problem: Unit Test Coverage

## Index
- [Summary](#summary)
- [For Laymen](#for-laymen)
- [What Is and Isn't Testable](#what-is-and-isnt-testable)
- [Pattern Reference](#pattern-reference)

---

## Summary

The repo has no automated tests. Any regression in the shared helper
functions (`common.ps1`) would only be caught at provisioning time - a
slow, side-effectful operation that requires a live Hyper-V host.

We want to add Pester 5 unit tests that run offline, without Hyper-V,
without the SecretStore vault, and without the Infrastructure.Secrets
module installed.

---

## What Is and Isn't Testable

| File | Testable? | Reason |
|------|-----------|--------|
| `common.ps1` - `Get-SanitizedVmDisplay` | Yes | Pure function, no I/O |
| `common.ps1` - `ConvertFrom-VmConfigJson` | Yes | Calls only `Assert-ConfigFields` (mockable) |
| `iso.ps1` - `New-SeedIso` | No | Requires IMAPI2 COM server (Windows-only, not mockable in Pester) |
| `provision.ps1` (script body) | No | Inline script; no extractable functions without a separate refactor |
| `setup-secrets.ps1` (script body) | No | Delegates entirely to `Initialize-InfrastructureVault`, which is tested in Infrastructure.Secrets |

---

## Pattern Reference

Mirrors [Infrastructure.Secrets test setup](../../../../../Infrastructure-Secrets):
- `Tests/` folder at repo root with `*.Tests.ps1` files
- `Run-Tests.ps1` at repo root - auto-installs Pester 5, runs all tests,
  exits non-zero on failure
- Each test file dot-sources only the specific file under test in `BeforeAll`
- External functions (`Assert-ConfigFields`) are stubbed so tests run without
  the Infrastructure.Secrets module installed
