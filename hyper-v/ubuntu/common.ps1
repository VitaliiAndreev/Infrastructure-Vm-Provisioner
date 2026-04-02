<#
.SYNOPSIS
    Shared helpers dot-sourced by setup-secrets.ps1 and provision.ps1.

.NOTES
    Do not run this file directly. It is intended to be dot-sourced:
        . "$PSScriptRoot\common.ps1"
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

# ---------------------------------------------------------------------------
# ConvertFrom-VmConfigJson
#   Parses a VM provisioner JSON string and validates its structure.
#   Throws a descriptive error on any problem.
#
#   Outputs each validated VM definition object to the pipeline. Callers
#   must wrap the call in @() to collect the result as an array:
#       $vmDefs = @(ConvertFrom-VmConfigJson -Json $json)
#
#   Centralised here so the required-field list has a single source of
#   truth — update it once when the config schema changes.
# ---------------------------------------------------------------------------

function ConvertFrom-VmConfigJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Json
    )

    try {
        $parsed = $Json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Invalid JSON: $_"
    }

    # In PS 5.1, ConvertFrom-Json unwraps single-element JSON arrays into a
    # bare PSCustomObject. @() normalises the result to an array in both cases.
    $vmDefs = @($parsed)

    if ($vmDefs.Count -eq 0) {
        throw "Config must be a non-empty JSON array of VM definitions."
    }

    # Every VM definition must supply all of these fields. This list is the
    # authoritative schema — setup-secrets.ps1 and provision.ps1 both rely
    # on it via dot-source.
    $requiredFields = @(
        'vmName', 'cpuCount', 'ramGB', 'diskGB', 'ubuntuVersion',
        'username', 'password',
        'ipAddress', 'subnetMask', 'gateway', 'dns',
        'vmConfigPath', 'vhdPath'
    )

    foreach ($vm in $vmDefs) {
        # Get-Member -MemberType NoteProperty is the reliable way to enumerate
        # properties created by ConvertFrom-Json in PS 5.1 and PS 7.
        # PSObject.Properties-based lookups can return unexpected results in
        # PS 5.1 depending on how the object was constructed.
        # Assert-ConfigFields is provided by Infrastructure.Secrets (>= 1.1.0).
        # It handles the PS 5.1-compatible Get-Member loop and IsNullOrWhiteSpace
        # cast so this file does not need to duplicate that logic.
        Assert-ConfigFields `
            -Object  $vm `
            -Fields  $requiredFields `
            -Context "VM '$(if ($vm.PSObject.Properties['vmName']) { $vm.vmName } else { '(unknown)' })'"`

        # Output each validated VM object individually to the pipeline.
        # Callers collect via @(ConvertFrom-VmConfigJson ...).
        Write-Output $vm
    }
}
