[CmdletBinding()]
param([Parameter(Mandatory)][string]$RepositoryRoot, [Parameter(Mandatory)][string]$Evidence)
. (Join-Path $PSScriptRoot 'Helpers.ps1')
$context = Assert-HostedCpuContext
. (Join-Path $PSScriptRoot 'Bootstrap-Sdk.ps1')
if (Test-Path -LiteralPath $Evidence) { throw 'Refusing setup evidence overwrite.' }
$null = New-Item -ItemType Directory -Path $Evidence
Write-CpuJson $context (Join-Path $Evidence 'hosted-context.json')
$sdk = Join-Path $RepositoryRoot '.dotnet'
& (Join-Path $PSScriptRoot 'Test-Bootstrap.ps1') -RepositoryRoot $RepositoryRoot -Output (Join-Path $Evidence 'bootstrap-tests')
Invoke-NativeSdkBootstrap $RepositoryRoot $sdk (Join-Path $Evidence 'sdk-bootstrap')
$oldHelper = Join-Path (Split-Path $PSScriptRoot -Parent) 'compiler-warmup-paired\Get-OfflineDecoder.ps1'
$library = & $oldHelper -Destination (Join-Path $Evidence 'offline-library')
$package = Split-Path (Split-Path $library -Parent) -Parent
& (Join-Path $PSScriptRoot 'Build-Tools.ps1') -Sdk $sdk -TraceEventPackage $package -Output (Join-Path $Evidence 'tools')
& (Join-Path $PSScriptRoot 'Test-Preparation.ps1') -Sdk $sdk -Binaries (Join-Path $Evidence 'tools') -Output (Join-Path $Evidence 'preparation-tests')
