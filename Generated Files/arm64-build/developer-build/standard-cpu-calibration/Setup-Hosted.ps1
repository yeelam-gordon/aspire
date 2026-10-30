[CmdletBinding()]
param([Parameter(Mandatory)][string]$RepositoryRoot, [Parameter(Mandatory)][string]$Evidence)
. (Join-Path $PSScriptRoot 'Helpers.ps1')
$context = Assert-HostedCpuContext
if (Test-Path -LiteralPath $Evidence) { throw 'Refusing setup evidence overwrite.' }
$null = New-Item -ItemType Directory -Path $Evidence
Write-CpuJson $context (Join-Path $Evidence 'hosted-context.json')
$sdk = Join-Path $RepositoryRoot '.dotnet'
if (Test-Path -LiteralPath $sdk) { throw 'Hosted private SDK must be fresh.' }
# Reuse the unchanged repository installer underlying P44 bootstrap, but install
# only its pinned ARM64 SDK. No product restore or Arcade x64 runtime loop.
$version = (Get-Content (Join-Path $RepositoryRoot 'global.json') -Raw | ConvertFrom-Json).sdk.version
if ($version -cne '11.0.100-rc.2.26504.105') { throw 'Unexpected P44 SDK pin.' }
$bootstrap = Start-CpuProcess (Get-Process -Id $PID).Path @(
    '-NoProfile', '-File', (Join-Path $RepositoryRoot 'eng\common\dotnet-install.ps1'),
    '-architecture', 'arm64', '-version', $version, '-runtime', 'sdk'
) (Join-Path $Evidence 'sdk-bootstrap')
$bootstrapReceipt = Complete-CpuProcess $bootstrap 240
if ($bootstrapReceipt.timedOut -or $bootstrapReceipt.exitCode -ne 0) { throw 'Native SDK-only bootstrap failed.' }
$hostPath = Join-Path $sdk 'dotnet.exe'
if ((Get-CpuPeMachine $hostPath) -ne '0xAA64') { throw 'Installed SDK host is not native ARM64.' }
$info = Start-CpuProcess $hostPath @('--info') (Join-Path $Evidence 'sdk-info')
$receipt = Complete-CpuProcess $info 15
if ($receipt.exitCode -ne 0 -or $receipt.timedOut) { throw 'Native SDK info failed.' }
$oldHelper = Join-Path (Split-Path $PSScriptRoot -Parent) 'compiler-warmup-paired\Get-OfflineDecoder.ps1'
$library = & $oldHelper -Destination (Join-Path $Evidence 'offline-library')
$package = Split-Path (Split-Path $library -Parent) -Parent
& (Join-Path $PSScriptRoot 'Build-Tools.ps1') -Sdk $sdk -TraceEventPackage $package -Output (Join-Path $Evidence 'tools')
& (Join-Path $PSScriptRoot 'Test-Preparation.ps1') -Sdk $sdk -Binaries (Join-Path $Evidence 'tools') -Output (Join-Path $Evidence 'preparation-tests')
