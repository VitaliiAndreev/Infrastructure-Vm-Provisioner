<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    ConvertFrom-VmConfigJson.ps1.
#>

# ---------------------------------------------------------------------------
# Assert-FilesField
#   Validates the optional 'files' field on a VM definition.
#
#   The field is optional - when absent, the function returns silently. When
#   present, it must be an array (possibly empty) of objects with exactly:
#       files[].source : Windows host path; must exist at validation time.
#       files[].target : absolute Linux path on the VM (starts with '/').
#
#   Source existence is checked here so a typo'd path fails before any VM
#   work begins, not at the SSH-copy step where the only signal would be
#   "file server returned 404".
#
#   Strict-by-design: unknown sub-fields throw. Catches typos like 'src'
#   or 'dest' that would otherwise be silently ignored.
# ---------------------------------------------------------------------------

function Assert-FilesField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    if (-not $Vm.PSObject.Properties['files']) {
        return
    }

    $vmName = if ($Vm.PSObject.Properties['vmName']) { $Vm.vmName } else { '(unknown)' }
    $ctx    = "VM '$vmName': files"

    $files = $Vm.files

    # ConvertFrom-Json yields System.Object[] for a JSON array. Reject any
    # other shape (including a bare object or string) - the operator should
    # see a clear schema error, not a runtime null-deref deeper in the
    # provisioner.
    if ($null -eq $files -or -not ($files -is [System.Collections.IEnumerable]) -or
        $files -is [string]) {
        throw "$ctx must be a JSON array of { source, target } objects."
    }

    $allowedFields = @('source', 'target')

    $i = 0
    foreach ($entry in $files) {
        $entryCtx = "$ctx[$i]"
        $i++

        if ($null -eq $entry -or
            $entry -isnot [System.Management.Automation.PSCustomObject]) {
            throw "$entryCtx must be a JSON object with 'source' and 'target' sub-fields."
        }

        foreach ($prop in $entry.PSObject.Properties) {
            if ($prop.Name -notin $allowedFields) {
                throw "$entryCtx has unknown sub-field '$($prop.Name)'. Allowed sub-fields: $($allowedFields -join ', ')."
            }
        }

        if (-not $entry.PSObject.Properties['source']) {
            throw "$entryCtx is missing required sub-field 'source'."
        }
        if ($entry.source -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.source)) {
            throw "$entryCtx.source must be a non-empty string (Windows host path)."
        }
        # Existence check at validation time - the operator gets a clear
        # 'wrong path' error before any VM work begins, instead of an
        # opaque file-server 404 deep in post-provisioning.
        if (-not (Test-Path -LiteralPath $entry.source)) {
            throw "$entryCtx.source path does not exist on the host: '$($entry.source)'."
        }

        if (-not $entry.PSObject.Properties['target']) {
            throw "$entryCtx is missing required sub-field 'target'."
        }
        if ($entry.target -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.target)) {
            throw "$entryCtx.target must be a non-empty string (absolute Linux path)."
        }
        # Linux absolute path. Reject Windows-style paths and relatives so
        # the on-VM mkdir / curl never lands in the admin user's $HOME by
        # accident.
        if ($entry.target -notmatch '^/') {
            throw "$entryCtx.target must be an absolute Linux path starting with '/' (got '$($entry.target)')."
        }
    }
}
