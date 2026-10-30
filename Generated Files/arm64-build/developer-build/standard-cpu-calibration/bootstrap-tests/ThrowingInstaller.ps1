[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$Architecture,
    [Parameter(Mandatory)][string]$InstallDir,
    [switch]$NoPath,
    [string]$ZipPath,
    [switch]$KeepZip,
    [int]$DownloadTimeout
)
@{
    version = $Version; architecture = $Architecture; installDir = $InstallDir
    noPath = $NoPath.IsPresent; zipPath = $ZipPath; keepZip = $KeepZip.IsPresent
    downloadTimeout = $DownloadTimeout; runtimeBound = $PSBoundParameters.ContainsKey('Runtime')
} | ConvertTo-Json | Set-Content (Join-Path (Split-Path $InstallDir -Parent) 'actual-bound-arguments.json')
throw 'SDK_BOOTSTRAP_SENTINEL: original controlled installer failure; no runtime installation.'
