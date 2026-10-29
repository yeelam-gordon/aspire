[CmdletBinding()]
param([string]$ResultsDirectory = (Join-Path $PSScriptRoot 'run-01'))

$ErrorActionPreference = 'Stop'
$summary = foreach ($case in @('cold-clean', 'no-op', 'warm-comment-edit'))
{
    $directory = Join-Path $ResultsDirectory $case
    $record = Get-Content -Raw -LiteralPath (Join-Path $directory 'result.json') | ConvertFrom-Json
    $samples = @(Get-Content -Raw -LiteralPath (Join-Path $directory 'counter-snapshots.json') | ConvertFrom-Json)
    $csc = Get-Content -Raw -LiteralPath (Join-Path $directory 'csc.json') | ConvertFrom-Json
    if ($record.exitCode -ne 0 -or -not $csc.successful -or $csc.unfinishedCscCount) { throw "Failed/incomplete build: $case" }
    if ($record.metricStatus -and $record.metricStatus -ne 'valid-process-window-counter-diagnostic') { throw "CPU metric was not validated: $case" }
    if (($case -eq 'no-op' -and $csc.cscCount -ne 0) -or ($case -ne 'no-op' -and $csc.cscCount -eq 0)) { throw "Unexpected Csc count: $case" }
    foreach ($task in $csc.tasks)
    {
        if (@($task.compilerServerMessages | Where-Object { $_ -match 'CompilerServer: server - server processed compilation' }).Count -ne 1)
        {
            throw "Csc server coverage not confirmed: $case/$($task.project)/$($task.target)"
        }
    }
    if (-not @($record.servers).Count) { throw "Missing actual compiler coverage: $case" }
    if ($csc.cscCount -gt 0 -and [double](($record.servers | Measure-Object cpuSeconds -Sum).Sum) -le 0) { throw "Csc ran without advancing CPU counters: $case" }
    foreach ($server in $record.servers)
    {
        $previous = $null
        $ownedSamples = @($samples | Where-Object key -EQ $server.identity.key)
        foreach ($sample in $ownedSamples)
        {
            $s = $sample.snapshot
            if (-not $s.alive -or [math]::Abs($s.totalSeconds - $s.userSeconds - $s.kernelSeconds) -gt 0.05) { throw "Invalid CPU counters: $case" }
            foreach ($field in @('totalSeconds', 'userSeconds', 'kernelSeconds'))
            {
                if ($previous -and $s.$field -lt $previous.$field) { throw "Nonmonotonic CPU: $case/$field" }
            }
            $previous = $s
        }
        if ($ownedSamples[-1].phase -ne 'final' -or
            [math]::Abs($server.cpuSeconds - ($server.final.totalSeconds - $server.baseline.totalSeconds)) -gt 0.000001)
        {
            throw "Incomplete final/delta coverage: $case"
        }
    }
    $mainCsc = @($csc.tasks | Where-Object { $_.project -match '[\\/]src[\\/]Aspire\.Hosting[\\/]Aspire\.Hosting\.csproj$' -and $_.target -eq 'CoreCompile' })
    [pscustomobject][ordered]@{
        case = $case; commandWallSeconds = $record.commandWallSeconds
        compilerCpuSeconds = [double](($record.servers | Measure-Object cpuSeconds -Sum).Sum)
        userSeconds = [double](($record.servers | Measure-Object userSeconds -Sum).Sum)
        kernelSeconds = [double](($record.servers | Measure-Object kernelSeconds -Sum).Sum)
        effectiveCores = [double](($record.servers | Measure-Object cpuSeconds -Sum).Sum) / $record.commandWallSeconds
        cscCount = $csc.cscCount; allCscWallSumSeconds = [double](($csc.tasks | Measure-Object wallSeconds -Sum).Sum)
        hostingMainCscWallSeconds = [double](($mainCsc | Measure-Object wallSeconds -Sum).Sum)
        maxObservedWorkingSetBytes = ($samples.snapshot | Measure-Object workingSetBytes -Maximum).Maximum
        finalWorkingSetBytes = @($record.servers.final.workingSetBytes)
        maxObservedThreads = ($samples.snapshot | Measure-Object threads -Maximum).Maximum
        observerCpuSeconds = $record.observerCpuSeconds
        samplingBodyWallSeconds = $record.samplingBodyWallSeconds
        maxPollGapSeconds = $record.maxObservedPollGapSeconds
        finalSnapshotTailSeconds = @($record.servers.finalSnapshotTailSeconds)
        firstSeenLagSeconds = @($record.servers.firstSeenLagSeconds)
        baselineLeadSecondsUpperBound = $record.warmBaselineLeadSecondsUpperBound
        snapshots = $samples.Count
        maxCpuComponentDifferenceSeconds = ($samples.snapshot | ForEach-Object { [math]::Abs($_.totalSeconds - $_.userSeconds - $_.kernelSeconds) } | Measure-Object -Maximum).Maximum
        allCscServerExecutionConfirmed = $true
    }
}
$final = Get-Content -Raw -LiteralPath (Join-Path $ResultsDirectory 'final-state.json') | ConvertFrom-Json
if (-not $final.sourceBytesRestored -or $final.trackedAndUntrackedStatus.Count -or $final.failure) { throw 'Final source state invalid.' }
$cleanup = @(Get-Content -Raw -LiteralPath (Join-Path $ResultsDirectory 'owned-cleanup.json') | ConvertFrom-Json)
if (@($cleanup | Where-Object { -not $_.exitConfirmed }).Count) { throw 'Cleanup not confirmed.' }
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $ResultsDirectory 'verified-summary.json')
$summary | Format-Table case,commandWallSeconds,compilerCpuSeconds,effectiveCores,cscCount,hostingMainCscWallSeconds
