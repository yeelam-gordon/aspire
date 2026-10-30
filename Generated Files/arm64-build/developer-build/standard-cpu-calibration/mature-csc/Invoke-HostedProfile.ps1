[CmdletBinding()]
param([Parameter(Mandatory)][string]$RepositoryRoot,[Parameter(Mandatory)][string]$SdkRoot,
    [Parameter(Mandatory)][string]$ResultsDirectory,[Parameter(Mandatory)][string]$ToolsDirectory)
. (Join-Path $PSScriptRoot 'Guard.ps1')
$null=Assert-MatureContext
& (Join-Path $PSScriptRoot 'Invoke-MatureProtocol.ps1') -RepositoryRoot $RepositoryRoot -SdkRoot $SdkRoot `
    -ResultsDirectory $ResultsDirectory -ToolsDirectory $ToolsDirectory -HostedCapture
