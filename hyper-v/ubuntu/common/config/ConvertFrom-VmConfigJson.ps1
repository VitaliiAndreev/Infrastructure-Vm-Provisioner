<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 and setup-secrets.ps1 after Infrastructure.Common is loaded.
#>

# ---------------------------------------------------------------------------
# ConvertFrom-VmConfigJson
#   Parses a VM provisioner JSON string and validates its structure.
#   Throws a descriptive error on any problem.
#
#   Outputs each validated VM definition object to the pipeline. Callers
#   must use ConvertTo-Array to collect the result as an array:
#       $vmDefs = ConvertTo-Array (ConvertFrom-VmConfigJson -Json $json)
#
#   Centralised here so the required-field list has a single source of
#   truth - update it once when the config schema changes.
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

    $vmDefs = ConvertTo-Array $parsed

    if ($vmDefs.Count -eq 0) {
        throw "Config must be a non-empty JSON array of VM definitions."
    }

    # Every VM definition must supply all of these fields. This list is the
    # authoritative schema - setup-secrets.ps1 and provision.ps1 both rely
    # on it via dot-source.
    $requiredFields = @(
        'vmName', 'cpuCount', 'ramGB', 'diskGB', 'ubuntuVersion',
        'username', 'password',
        'ipAddress', 'subnetMask', 'gateway', 'dns',
        'vmConfigPath', 'vhdPath'
    )

    foreach ($vm in $vmDefs) {
        # Assert-RequiredProperties is provided by Infrastructure.Common.
        Assert-RequiredProperties `
            -Object      $vm `
            -Properties  $requiredFields `
            -Context     "VM '$(if ($vm.PSObject.Properties['vmName']) { $vm.vmName } else { '(unknown)' })'"`

        # Apply defaults for optional fields. Using Add-Member rather than
        # property assignment so the field is added when absent without
        # overwriting an explicitly supplied value.
        if (-not $vm.PSObject.Properties['switchName']) {
            $vm | Add-Member -MemberType NoteProperty -Name switchName -Value 'VmLAN'
        }
        if (-not $vm.PSObject.Properties['natName']) {
            $vm | Add-Member -MemberType NoteProperty -Name natName -Value 'VmLAN-NAT'
        }

        # Output each validated VM object individually to the pipeline.
        # Callers collect via @(ConvertFrom-VmConfigJson ...).
        Write-Output $vm
    }
}
