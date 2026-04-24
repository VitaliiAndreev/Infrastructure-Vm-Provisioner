<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 and setup-secrets.ps1 after Infrastructure.Common is loaded.
#>

# Fields whose values must never appear in diagnostic output or error messages.
$Script:SecretFields = @('password')

# ---------------------------------------------------------------------------
# Get-SanitizedVmDisplay
#   Returns a display-safe version of a VM definition object with secret
#   field values replaced by '***'. Used in error messages and diagnostics
#   so that passwords are never written to the console or logs.
# ---------------------------------------------------------------------------

function Get-SanitizedVmDisplay {
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    $safe = [ordered]@{}
    foreach ($member in (Get-Member -InputObject $Vm -MemberType NoteProperty)) {
        $safe[$member.Name] = if ($member.Name -in $Script:SecretFields) {
            '***'
        } else {
            $Vm.($member.Name)
        }
    }
    return [PSCustomObject]$safe
}
