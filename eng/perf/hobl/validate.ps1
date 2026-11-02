# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'Hobl.ps1')
$checks = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Assert-Rejected {
    param([scriptblock]$Action, [string]$Message)
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    Assert-True $rejected $Message
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$fixtureRoot = Join-Path $repoRoot ('artifacts\hobl-fixture-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixtureRoot
try {
    foreach ($file in Get-ChildItem $PSScriptRoot -Filter '*.ps1') {
        $tokens = $null
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        Assert-True ($errors.Count -eq 0) "PowerShell parse errors: $($file.Name): $errors"
    }
    foreach ($os in @('windows', 'macos')) {
        foreach ($profile in @('original', 'aligned')) {
            # Exercise the actual CLI plan branch, not only a copy of the manifest.
            $json = & (Join-Path $PSScriptRoot 'run.ps1') -Platform $os -Profile $profile -Plan | Out-String
            $plan = $json | ConvertFrom-Json -AsHashtable
            Assert-True ($plan.loops -eq 4 -and -not $plan.smoke) 'Default must be a four-loop scenario.'
            Assert-True ($plan.provenance.source.commit -eq '4884590ffaa580e742f479b4daf77f9d36451f35') 'Source drift.'
            Assert-True ($plan.provenance.hobl.commit -eq 'df120528374c0a5de5cb5a526175973d1ea2b53f') 'HOBL reference drift.'
            $phases = $plan.workload.iteration
            Assert-True (($phases.phase -join ',') -eq 'clean,restore,build') 'Phase ordering drift.'
            Assert-True (-not $phases[0].timed -and -not $phases[1].timed -and $phases[2].timed) 'Timing includes clean/restore.'
            $commands = @($phases | ForEach-Object { $_.argv -join ' ' })
            $sdkRoot = Get-HoblDotnetRoot $fixtureRoot $os $profile
            $expectedSdkRoot = if ($os -eq 'macos' -and $profile -eq 'original') { Join-Path (Join-Path $fixtureRoot 'source') '.dotnet' }
                else { Join-Path $fixtureRoot 'dotnet' }
            Assert-True ($sdkRoot -eq $expectedSdkRoot) 'SDK root is inconsistent with the workload profile.'
            if ($os -eq 'macos' -and $profile -eq 'original') {
                Assert-True (($commands -join '|') -eq './build.sh --clean|./build.sh --restore|./build.sh --build') 'Mac original recipe replaced.'
                Assert-True (($plan.workload.prep[0] -join ' ') -eq './build.sh --restore --build /p:UpdateConfigurationSchema=true') 'Mac prep drift.'
            }
            else {
                Assert-True (($commands -join '|') -eq 'dotnet clean Aspire.slnx|dotnet restore Aspire.slnx|dotnet build Aspire.slnx --no-restore') 'Solution recipe drift.'
                Assert-True (($plan.workload.prep[1] -join ' ') -eq 'dotnet build Aspire.slnx --no-incremental /p:UpdateConfigurationSchema=true') 'Solution prep drift.'
            }
        }
    }
    Assert-True (Get-HoblPlan 'windows' 'original' 1).smoke 'Short run not labelled smoke.'
    Assert-Rejected { Get-HoblPlan 'windows' 'original' 0 } 'Zero-loop plan accepted.'
    $owned = Join-Path $fixtureRoot 'owned'
    $null = New-Item -ItemType Directory -Path $owned
    $sentinel = Join-Path $fixtureRoot 'outside.txt'
    Set-Content $sentinel 'outside preserved'
    Assert-HoblPath $owned $fixtureRoot -Recurse
    Push-Location $owned
    try {
        Assert-HoblPath '.\new-child' $fixtureRoot
        $checks++
    }
    finally { Pop-Location }
    Assert-Rejected { Assert-HoblPath $fixtureRoot $fixtureRoot } 'Root accepted as owned child.'
    Assert-Rejected { Assert-HoblPath (Join-Path $fixtureRoot '..\foreign') $fixtureRoot } 'Traversal accepted.'
    $boundary = New-HoblNuGetBoundary $owned
    [xml]$config = Get-Content $boundary -Raw
    Assert-True ($null -ne $config.configuration.packageSourceMapping.clear) 'Ancestor mappings not cleared.'
    Assert-True (($config.configuration.ChildNodes.Name -join ',') -eq 'packageSourceMapping') 'Boundary clears unrelated policy sections.'
    Assert-True ($config.configuration.ChildNodes.Name -notcontains 'trustedSigners') 'Signer policy changed.'
    Assert-True ($config.SelectNodes('//add').Count -eq 0) 'Boundary adds feeds or settings.'
    Assert-Rejected { New-HoblNuGetBoundary $owned } 'Boundary overwrites an existing config.'
    $link = Join-Path $owned 'foreign-link'
    $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
    $null = New-Item -ItemType $linkType -Path $link -Target $fixtureRoot
    Assert-Rejected { Assert-HoblPath $owned $fixtureRoot -Recurse } 'Nested link accepted.'
    Assert-Rejected { Assert-HoblPath (Join-Path $link 'new') $fixtureRoot } 'Ancestor link accepted.'
    # Remove only the created link, never its target.
    (Get-Item -LiteralPath $link -Force).Delete()
    $envMap = @{ HOBL_FIXTURE = 'child only' }
    $common = @{ WorkingDirectory = $owned; Environment = $envMap; Deadline = [datetime]::UtcNow.AddMinutes(1)
        BudgetRoot = $fixtureRoot; BudgetBytes = 10MB }
    $pwsh = (Get-Process -Id $PID).Path
    $record = Invoke-HoblProcess -Argv @($pwsh, '-NoProfile', '-Command', 'Write-Output $env:HOBL_FIXTURE; [Console]::Error.WriteLine("stderr retained")') -Log (Join-Path $owned 'success.log') @common
    Assert-True ((Get-Content $record.stdout -Raw).Trim() -eq 'child only') 'Child environment not applied.'
    Assert-True ((Get-Content $record.stderr -Raw).Trim() -eq 'stderr retained') 'Stderr missing.'
    Assert-True ($env:HOBL_FIXTURE -ne 'child only') 'Parent environment mutated.'
    $originalStorageGetter = (Get-Command Get-HoblBytes -CommandType Function).ScriptBlock
    $script:timingKernel = $null
    $timingStop = Join-Path $owned 'timing-stop.txt'
    try {
        function Get-HoblBytes {
            param([string]$Root)
            if ($null -eq $script:timingKernel) {
                $child = (Get-Variable process -Scope 1 -ErrorAction Stop).Value
                Set-Content -LiteralPath $timingStop 'stop'
                if (-not $child.WaitForExit(10000)) { throw 'Timing fixture child did not exit.' }
                $script:timingKernel = @{
                    pid = $child.Id
                    seconds = ($child.ExitTime.ToUniversalTime() - $child.StartTime.ToUniversalTime()).TotalSeconds
                }
                Start-Sleep -Milliseconds 1200
            }
            return 0L
        }
        $timingEnvironment = $envMap.Clone()
        $timingEnvironment.HOBL_TIMING_STOP = $timingStop
        $timing = Invoke-HoblProcess -Argv @($pwsh, '-NoProfile', '-Command',
            'while (-not (Test-Path -LiteralPath $env:HOBL_TIMING_STOP)) { Start-Sleep -Milliseconds 20 }') `
            -Log (Join-Path $owned 'timing.log') -WorkingDirectory $owned -Environment $timingEnvironment `
            -Deadline ([datetime]::UtcNow.AddSeconds(25)) -BudgetRoot $fixtureRoot -BudgetBytes 10MB
        Assert-True ($timing.processId -eq $script:timingKernel.pid) 'Timing witness joined the wrong child.'
        Assert-True ([Math]::Abs($timing.processWallSeconds - $script:timingKernel.seconds) -lt 0.001) 'Score includes storage-observation delay.'
        Assert-True ($timing.wallSeconds - $timing.processWallSeconds -ge 1) 'Fixture did not distinguish supervisor from process time.'
    }
    finally { Set-Item Function:Get-HoblBytes -Value $originalStorageGetter }
    Assert-Rejected { Invoke-HoblProcess -Argv @($pwsh, '-NoProfile', '-Command', 'exit 7') -Log (Join-Path $owned 'failure.log') @common } 'Nonzero exit accepted.'
    $failure = Get-Content (Join-Path $owned 'failure.log.command.json') -Raw | ConvertFrom-Json
    Assert-True ($failure.exitCode -eq 7) 'Original failed exit code lost.'
    Assert-True ($failure.processWallSeconds -gt 0) 'Failed child lifetime was lost.'
    $accepted = Invoke-HoblProcess -Argv @($pwsh, '-NoProfile', '-Command', 'exit 7') -Log (Join-Path $owned 'accepted.log') -SuccessExitCodes @(0, 7) @common
    Assert-True ($accepted.exitCode -eq 7) 'Documented nonzero success exit was not retained.'
    Assert-Rejected { Invoke-HoblProcess -Argv @('missing-hobl-fixture-executable') -Log (Join-Path $owned 'missing.log') @common } 'Missing executable accepted.'
    $missing = Get-Content (Join-Path $owned 'missing.log.command.json') -Raw | ConvertFrom-Json
    Assert-True ($null -eq $missing.processWallSeconds) 'Failed launch invented a child lifetime.'
    $short = $common.Clone()
    $short.Deadline = [datetime]::UtcNow.AddSeconds(2)
    Assert-Rejected { Invoke-HoblProcess -Argv @($pwsh, '-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -Log (Join-Path $owned 'timeout.log') @short } 'Bounded process timeout ignored.'
    $timeout = Get-Content (Join-Path $owned 'timeout.log.command.json') -Raw | ConvertFrom-Json
    Assert-True ($timeout.failure -match 'Run time budget exhausted' -and $timeout.terminatedOwnTree) 'Timeout did not terminate only its owned command.'
    Assert-True ($null -eq (Get-Process -Id $timeout.processId -ErrorAction SilentlyContinue)) 'Timed-out child remains running.'
    Assert-True ((Get-Content $sentinel -Raw).Trim() -eq 'outside preserved') 'Outside sentinel changed.'
    $snapshot = Save-HoblAdapterSnapshot $owned
    Assert-True ((Get-Content (Join-Path $snapshot 'run.ps1') -Raw) -ceq
        (Get-Content (Join-Path $PSScriptRoot 'run.ps1') -Raw)) 'Adapter snapshot did not preserve the current runner.'
    Assert-Rejected { Get-HoblDeadlines ([datetime]::UtcNow) 10 10 } 'Cleanup reservation exceeds the total budget.'

    # Model a build server that outlives a timed client. It is an independent owned
    # process, so killing the workload tree cannot accidentally satisfy this test.
    $serverScript = Join-Path $owned 'owned-server.ps1'
    $ready = Join-Path $owned 'server-ready.txt'
    $stop = Join-Path $owned 'server-stop.txt'
    Set-Content $serverScript @'
param([string]$ReadyFile, [string]$StopFile)
Set-Content -LiteralPath $ReadyFile $PID
$limit = [datetime]::UtcNow.AddSeconds(25)
while (-not (Test-Path -LiteralPath $StopFile)) {
    if ([datetime]::UtcNow -ge $limit) { exit 9 }
    Start-Sleep -Milliseconds 50
}
exit 0
'@
    $server = [Diagnostics.Process]::new()
    $server.StartInfo = [Diagnostics.ProcessStartInfo]::new($pwsh)
    $server.StartInfo.UseShellExecute = $false
    $server.StartInfo.CreateNoWindow = $true
    foreach ($arg in @('-NoProfile', '-File', $serverScript, $ready, $stop)) { $server.StartInfo.ArgumentList.Add($arg) }
    try {
        $null = $server.Start()
        $readyDeadline = [datetime]::UtcNow.AddSeconds(5)
        while (-not (Test-Path $ready) -and [datetime]::UtcNow -lt $readyDeadline -and -not $server.HasExited) { Start-Sleep -Milliseconds 50 }
        Assert-True ((Test-Path $ready) -and -not $server.HasExited) 'Owned server did not become ready.'
        $limits = Get-HoblDeadlines ([datetime]::UtcNow) 12 7
        $expiring = $common.Clone()
        $expiring.Deadline = $limits.workload
        Assert-Rejected { Invoke-HoblProcess -Argv @($pwsh, '-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -Log (Join-Path $owned 'expired-workload.log') @expiring } 'Workload deadline did not expire.'
        Assert-True ([datetime]::UtcNow -ge $limits.workload -and -not $server.HasExited) 'Persistent server was not alive after workload expiry.'
        $cleanupEnvironment = $envMap.Clone()
        $cleanupEnvironment.HOBL_STOP_FILE = $stop
        $cleanup = Invoke-HoblReservedCleanup -Argv @($pwsh, '-NoProfile', '-Command',
            '[IO.File]::WriteAllText($env:HOBL_STOP_FILE, "stop")') -WorkingDirectory $owned `
            -Log (Join-Path $owned 'reserved-shutdown.log') -Environment $cleanupEnvironment `
            -TotalDeadline $limits.total -BudgetRoot $fixtureRoot
        Assert-True ($server.WaitForExit(1000) -and $server.ExitCode -eq 0) 'Reserved cleanup did not shut down the persistent owned server.'
        Assert-True ([datetime]::Parse($cleanup.startedUtc).ToUniversalTime() -ge $limits.workload -and
            [datetime]::UtcNow -le $limits.total) 'Cleanup did not execute after workload expiry inside the original total budget.'
    }
    finally {
        if (-not $server.HasExited) {
            Set-Content $stop 'test-finally'
            if (-not $server.WaitForExit(1000)) { $server.Kill($true); $server.WaitForExit() }
        }
        $server.Dispose()
    }
    $oldOutput = Join-Path $owned 'old.dll'
    $freshOutput = Join-Path $owned 'fresh.dll'
    Set-Content $oldOutput 'old'
    Set-Content $freshOutput 'new'
    [IO.File]::SetLastWriteTimeUtc($oldOutput, [datetime]::new(2026, 11, 2, 5, 59, 0, [DateTimeKind]::Utc))
    [IO.File]::SetLastWriteTimeUtc($freshOutput, [datetime]::new(2026, 11, 2, 6, 1, 0, [DateTimeKind]::Utc))
    $fresh = @(Get-HoblFreshOutputs $owned '2026-11-02T14:00:00.0000000+08:00')
    Assert-True ($fresh.Count -eq 1 -and $fresh[0].Name -eq 'fresh.dll') 'Fresh artifact detection lost timezone offset.'
    $fresh = @(Get-HoblFreshOutputs $owned '2026-11-02T06:00:00.0000000Z')
    Assert-True ($fresh.Count -eq 1 -and $fresh[0].Name -eq 'fresh.dll') 'UTC artifact detection converted to local ticks.'
    $upstreamBinlog = Join-Path $owned 'upstream.binlog'
    Set-Content $upstreamBinlog 'synthetic binlog fixture'
    [IO.File]::SetLastWriteTimeUtc($upstreamBinlog, [datetime]::new(2026, 11, 2, 6, 1, 0, [DateTimeKind]::Utc))
    $freshLogs = @(Get-HoblFreshOutputs $owned '2026-11-02T06:00:00.0000000Z' -Filter '*.binlog')
    Assert-True ($freshLogs.Count -eq 1 -and $freshLogs[0].Name -eq 'upstream.binlog') 'Upstream per-iteration binary-log discovery failed.'
    $timeFile = Join-Path $owned 'time.txt'
    Set-Content $timeFile @('real 12.34', 'user 5.67', 'sys 1.23')
    $time = Get-HoblUnixTime $timeFile
    Assert-True ($time.real -eq 12.34 -and $time.user -eq 5.67 -and $time.sys -eq 1.23) 'Mac raw CPU/wall timing changed.'
    Set-Content $timeFile @('real 12,34', 'user 5,67', 'sys 1,23')
    Assert-True ((Get-HoblUnixTime $timeFile).real -eq 12.34) 'Locale decimal separator lost.'
    Set-Content $timeFile @('real 12.34', 'user 5.67')
    Assert-Rejected { Get-HoblUnixTime $timeFile } 'Incomplete Mac timing accepted.'
    Set-Content $timeFile @('real 12.34', 'user 5.67', 'sys 1.23', 'real 99.99')
    Assert-Rejected { Get-HoblUnixTime $timeFile } 'Duplicate Mac timing accepted.'
    Set-Content $timeFile @('real NaN', 'user 5.67', 'sys 1.23')
    Assert-Rejected { Get-HoblUnixTime $timeFile } 'Malformed Mac timing accepted.'

    $phases = foreach ($phase in @('clean', 'restore', 'build')) {
        @{ phase = $phase; exitCode = 0; stdout = $record.stdout; stderr = $record.stderr }
    }
    $iteration = @{ phases = @($phases); scenarioRuntimeSeconds = 1.25; compilerInvocations = $null
        compilerCommandLinesObserved = 0; compilerCaptureKind = 'stdout-command-line-mentions-only'
        compiledOutputs = 2; builtArtifacts = 2; binlogs = @() }
    $evidence = @{ status = 'passed'; diagnosticBinlogs = $false; iterations = @($iteration) }
    Assert-HoblEvidence $evidence 1
    $checks++
    Assert-Rejected { Assert-HoblEvidence $evidence 4 } 'Incomplete four-loop evidence accepted.'
    $iteration.compiledOutputs = 0
    Assert-Rejected { Assert-HoblEvidence $evidence 1 } 'Empty compiler work accepted.'
    $iteration.compiledOutputs = 2
    $iteration.scenarioRuntimeSeconds = 0
    Assert-Rejected { Assert-HoblEvidence $evidence 1 } 'Missing timing accepted.'
    $iteration.scenarioRuntimeSeconds = [double]::NaN
    Assert-Rejected { Assert-HoblEvidence $evidence 1 } 'Nonfinite timing accepted.'
    $iteration.scenarioRuntimeSeconds = 1.25
    $evidence.diagnosticBinlogs = $true
    Assert-Rejected { Assert-HoblEvidence $evidence 1 } 'Missing binlogs accepted.'
    $binlog = Join-Path $owned 'empty.binlog'
    $null = New-Item -ItemType File -Path $binlog
    $iteration.binlogs = @($binlog)
    Assert-Rejected { Assert-HoblEvidence $evidence 1 } 'Empty binlog accepted.'
    $iteration.binlogs = @()
    $evidence.diagnosticBinlogs = $false
    $phases[2].stdout = $binlog
    Assert-Rejected { Assert-HoblEvidence $evidence 1 } 'Empty build log accepted.'
    $phases[2].stdout = Join-Path $owned 'nonexistent.log'
    Assert-Rejected { Assert-HoblEvidence $evidence 1 } 'Missing build log accepted.'

    # Structural isolation checks supplement (not replace) actionlint or a real Actions run.
    $workflow = Get-Content (Join-Path $repoRoot '.github\workflows\hobl-aspire.yml') -Raw
    Assert-True ($workflow -match "(?m)^  workflow_dispatch:\r?$" -and $workflow -match "(?m)^  workflow_call:\r?$" -and
        $workflow -notmatch "(?m)^  (push|pull_request|pull_request_target|schedule):") 'Worker has an automatic trigger or missing reusable entrypoint.'
    Assert-True ($workflow.Contains("if: github.repository == 'yeelam-gordon/aspire' && github.ref == 'refs/heads/perf/hobl-aspire'")) 'Missing owned fork/branch gate.'
    Assert-True ($workflow -match 'contents: read' -and $workflow -notmatch '(?m)^\s+[\w-]+: write') 'Excess workflow permissions.'
    Assert-True ($workflow -match 'fail-fast: false' -and $workflow -match 'timeout-minutes: 60') 'Missing bounded independent jobs.'
    Assert-True ($workflow -match 'runner: windows-11-vs2026-arm' -and $workflow -match 'runner: macos-latest') 'Missing native runner pair.'
    Assert-True ($workflow -match 'if: always\(\)' -and $workflow -match 'actions/upload-artifact@') 'Missing unconditional evidence upload.'
    Assert-True ($workflow -match '\./eng/perf/hobl/run\.ps1' -and $workflow -match '\./eng/perf/hobl/validate\.ps1') 'CI does not use local entrypoints.'
    $dispatcher = Get-Content (Join-Path $repoRoot '.github\workflows\compare-arm64-developer-build.yml') -Raw
    Assert-True ($dispatcher -match "(?m)^  workflow_dispatch:\r?$" -and
        $dispatcher -notmatch "(?m)^  (push|pull_request|pull_request_target|schedule|workflow_call):") 'Registered dispatcher is not manual-only.'
    Assert-True ($dispatcher.Contains("if: github.repository == 'yeelam-gordon/aspire' && github.ref == 'refs/heads/perf/hobl-aspire'")) 'Dispatcher missing fork/branch guard.'
    Assert-True ($dispatcher -match 'uses: \./\.github/workflows/hobl-aspire\.yml') 'Dispatcher does not call same-branch worker.'
    foreach ($inputName in @('profile', 'loops', 'diagnostic_binlogs')) {
        Assert-True ($dispatcher.Contains("${inputName}: `${{ inputs.$inputName }}")) "Dispatcher does not forward $inputName."
        Assert-True ($workflow -match "(?m)^      ${inputName}:\r?$") "Reusable worker missing $inputName."
    }
    Write-Host "PASS: $checks focused adapter checks. No workloads or CI dispatched."
}
finally {
    # Fresh fixture tree only; never remove a repository/session/root or traverse a surviving link.
    if (Test-Path -LiteralPath $fixtureRoot) {
        Assert-HoblPath $fixtureRoot $repoRoot -Recurse
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}
