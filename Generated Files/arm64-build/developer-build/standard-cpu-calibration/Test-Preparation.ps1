[CmdletBinding()]
param([Parameter(Mandatory)][string]$Sdk, [Parameter(Mandatory)][string]$Binaries, [Parameter(Mandatory)][string]$Output)
. (Join-Path $PSScriptRoot 'Helpers.ps1')
if (Test-Path -LiteralPath $Output) { throw 'Refusing test evidence overwrite.' }
$null = New-Item -ItemType Directory -Path $Output
$valid = @{
    actions = 'true'; repository = 'yeelam-gordon/aspire'
    ref = 'refs/heads/perf/arm64-standard-cpu-calibration'; event = 'workflow_dispatch'
    runnerEnvironment = 'github-hosted'; runnerOS = 'Windows'; runnerArch = 'ARM64'
    imageOS = 'win11-vs2026-arm64'; osArch = 'Arm64'; processArch = 'Arm64'; runId = '123'
}
if (-not (Test-HostedCpuContext $valid)) { throw 'Hosted pure guard positive fixture failed.' }
$cases = @()
foreach ($key in $valid.Keys)
{
    $invalid = $valid.Clone()
    $invalid[$key] = 'not-owned'
    $rejected = -not (Test-HostedCpuContext $invalid)
    $cases += @{ changed = $key; rejected = $rejected }
    if (-not $rejected) { throw "Guard failed to reject $key" }
}
# Actual entry-point negative fixture is LOCAL only; never simulate an allowed
# hosted environment to execute a recording. Pure predicate fixtures above do not
# create sessions/processes. On the real hosted job, skip this local-only case.
$localEntryRejected = $null
if ($env:GITHUB_ACTIONS -cne 'true')
{
    $forbiddenOutput = Join-Path $Output 'must-not-exist'
    $process = Start-CpuProcess (Get-Process -Id $PID).Path @(
        '-NoProfile', '-File', (Join-Path $PSScriptRoot 'Invoke-HostedCalibration.ps1'),
        '-Sdk', $Sdk, '-Binaries', $Binaries, '-Output', $forbiddenOutput
    ) (Join-Path $Output 'local-capture-rejection')
    $receipt = Complete-CpuProcess $process 10
    $localEntryRejected = $receipt.exitCode -ne 0 -and -not $receipt.timedOut -and -not (Test-Path $forbiddenOutput)
    if (-not $localEntryRejected) { throw 'Capture entry point did not fail before local side effects.' }
}
$archiveTests = Start-CpuProcess (Join-Path $Sdk 'dotnet.exe') @(
    (Join-Path $Binaries 'CpuDecoder.dll'), 'archive-tests', (Join-Path $Output 'archive-api')
) (Join-Path $Output 'archive-api')
$archiveReceipt = Complete-CpuProcess $archiveTests 15
if ($archiveReceipt.exitCode -ne 0 -or $archiveReceipt.timedOut) { throw 'Public archive API tests failed.' }
Write-CpuJson @{ passed = $true; hostedPredicateCases = $cases; localEntryRejectedBeforeSideEffects = $localEntryRejected; archiveReceipt = $archiveReceipt; recordings = 0 } (Join-Path $Output 'tests.json')
