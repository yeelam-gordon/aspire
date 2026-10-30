[CmdletBinding()]
param([Parameter(Mandatory)][string]$RepositoryRoot,[Parameter(Mandatory)][string]$SdkRoot,
    [Parameter(Mandatory)][string]$ResultsDirectory,[Parameter(Mandatory)][string]$ToolsDirectory)
if ($env:GITHUB_ACTIONS -ceq 'true') { throw 'Local unprofiled proof is not a hosted capture entry point.' }
& (Join-Path $PSScriptRoot 'Invoke-MatureProtocol.ps1') -RepositoryRoot $RepositoryRoot -SdkRoot $SdkRoot `
    -ResultsDirectory $ResultsDirectory -ToolsDirectory $ToolsDirectory
