[CmdletBinding()]
param([Parameter(Mandatory)][string]$InstrumentationRoot,[Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter(Mandatory)][string]$Evidence)
. (Join-Path $PSScriptRoot 'Guard.ps1')
$context=Assert-MatureContext
$p48=Split-Path $PSScriptRoot -Parent
. (Join-Path $p48 'Bootstrap-Sdk.ps1')
if(Test-Path $Evidence){throw 'Refusing setup evidence overwrite.'}
$null=New-Item -ItemType Directory -Path $Evidence
Write-CpuJson $context (Join-Path $Evidence 'hosted-context.json')
if((& git -C $RepositoryRoot rev-parse HEAD).Trim() -cne '06efc928e31486923754398007f4f78003e04ee3')
{throw 'Wrong fixed product checkout.'}
$sdk=Join-Path $RepositoryRoot '.dotnet'
Invoke-NativeSdkBootstrap $InstrumentationRoot $sdk (Join-Path $Evidence 'sdk-bootstrap')
$acquire=Join-Path (Split-Path $p48 -Parent) 'compiler-warmup-paired\Get-OfflineDecoder.ps1'
$library=& $acquire -Destination (Join-Path $Evidence 'offline-library')
$package=Split-Path (Split-Path $library -Parent) -Parent
& (Join-Path $PSScriptRoot 'Build-Tools.ps1') -Sdk $sdk -TraceEventPackage $package -Output (Join-Path $Evidence 'tools')
& (Join-Path $PSScriptRoot 'Test-Guards.ps1') -RepositoryRoot $RepositoryRoot -SdkRoot $sdk `
    -ToolsDirectory (Join-Path $Evidence 'tools') -Output (Join-Path $Evidence 'guards')
$probe=Start-CpuProcess (Join-Path $sdk 'dotnet.exe') @(
    (Join-Path $Evidence 'tools\CompilerSymbols.dll'),$sdk,(Join-Path $Evidence 'compiler-symbol-availability')
) (Join-Path $Evidence 'compiler-symbol-availability')
$r=Complete-CpuProcess $probe 180
if($r.exitCode -ne 0 -or $r.timedOut){throw 'Compiler image/PDB availability probe incomplete; retain limitation.'}
