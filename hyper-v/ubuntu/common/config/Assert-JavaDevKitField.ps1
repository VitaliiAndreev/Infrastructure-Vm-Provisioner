<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    ConvertFrom-VmConfigJson.ps1.
#>

# ---------------------------------------------------------------------------
# Assert-JavaDevKitField
#   Validates the optional 'javaDevKit' field on a VM definition.
#
#   The field is optional - when absent the function returns silently. When
#   present, the structure must match the schema exactly:
#       javaDevKit.vendor  : 'temurin'                        (only value)
#       javaDevKit.version : string matching one of four
#                            granularities (see $versionPatterns).
#
#   Lives in its own file so the rule set is independently testable and
#   ConvertFrom-VmConfigJson.ps1 stays a thin orchestrator.
#
#   Strict-by-design: unknown sub-fields throw. This catches silent typos
#   like 'versoin' that would otherwise be ignored and silently install
#   the wrong (or no) JDK.
# ---------------------------------------------------------------------------

function Assert-JavaDevKitField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    # Optional field - absence is valid and means "no JDK on this VM".
    if (-not $Vm.PSObject.Properties['javaDevKit']) {
        return
    }

    $jdk = $Vm.javaDevKit

    # Context fragment for every error message - the operator needs to know
    # which VM in a multi-VM config tripped the check.
    $vmName = if ($Vm.PSObject.Properties['vmName']) { $Vm.vmName } else { '(unknown)' }
    $ctx    = "VM '$vmName': javaDevKit"

    # PSCustomObject is what ConvertFrom-Json yields for a JSON object. A
    # string, number, array, or $null fails this check - those are not
    # 'objects' for our purposes.
    if ($null -eq $jdk -or $jdk -isnot [System.Management.Automation.PSCustomObject]) {
        throw "$ctx must be a JSON object with 'vendor' and 'version' sub-fields."
    }

    # Strict sub-field set. Reject anything outside this list to catch
    # typos like 'versoin' before they cause a confusing downstream error.
    $allowedFields = @('vendor', 'version')
    foreach ($prop in $jdk.PSObject.Properties) {
        if ($prop.Name -notin $allowedFields) {
            throw "$ctx has unknown sub-field '$($prop.Name)'. Allowed sub-fields: $($allowedFields -join ', ')."
        }
    }

    # vendor: required. Adoptium Temurin is currently the only supported value.
    if (-not $jdk.PSObject.Properties['vendor']) {
        throw "$ctx is missing required sub-field 'vendor'."
    }
    if ($jdk.vendor -ne 'temurin') {
        throw "$ctx.vendor must be 'temurin' (got '$($jdk.vendor)'). Adoptium Temurin is currently the only supported vendor."
    }

    # version: required, must be a string. Numeric JSON values are rejected
    # here so the operator gets a clear error rather than a confusing regex
    # mismatch. Rationale: JSON has no way to preserve '21.0' as distinct
    # from '21' once parsed as a number (trailing-zero loss), and '21.0.5+11'
    # is not a valid JSON number at all - so 'string only' is the single
    # consistent rule.
    if (-not $jdk.PSObject.Properties['version']) {
        throw "$ctx is missing required sub-field 'version'."
    }
    if ($jdk.version -isnot [string]) {
        throw "$ctx.version must be a string (e.g. '21' or '21.0.5+11'). Numeric JSON values are not accepted."
    }

    # Four supported granularities. Anchored so partial matches like
    # '21foo' or '21.0.5+11-extra' fail.
    $versionPatterns = @(
        '^\d+$',
        '^\d+\.\d+$',
        '^\d+\.\d+\.\d+$',
        '^\d+\.\d+\.\d+\+\d+$'
    )

    $matched = $false
    foreach ($pattern in $versionPatterns) {
        if ($jdk.version -match $pattern) {
            $matched = $true
            break
        }
    }
    if (-not $matched) {
        throw "$ctx.version '$($jdk.version)' is not a recognised granularity. Use '21', '21.0', '21.0.5' or '21.0.5+11'."
    }
}
