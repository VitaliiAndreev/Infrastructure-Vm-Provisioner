<#
.SYNOPSIS
    Runs SSH integration tests against a Docker target container.

.DESCRIPTION
    Delegates to the canonical implementation in Infrastructure-Common
    (expected as a sibling checkout under the same parent directory).
    Requires Docker Desktop (Linux containers) to be running.

.EXAMPLE
    .\Run-IntegrationTests-AgainstDockerTarget.ps1
#>

& ([IO.Path]::Combine($PSScriptRoot, '..', 'Infrastructure-Common', `
    'Run-IntegrationTests-AgainstDockerTarget.ps1')) -TestsRoot $PSScriptRoot
