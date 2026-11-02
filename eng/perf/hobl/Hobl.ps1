# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-HoblPlan {
    param([ValidateSet('windows', 'macos')][string]$Platform,
        [ValidateSet('original', 'aligned')][string]$Profile, [int]$Loops = 4)
    if ($Loops -lt 1 -or $Loops -gt 4) { throw 'Loops must be between 1 and 4.' }
    $manifest = Get-Content (Join-Path $PSScriptRoot 'manifest.json') -Raw | ConvertFrom-Json -AsHashtable
    $recipe = if ($Platform -eq 'macos' -and $Profile -eq 'original') { 'macosOriginal' } else { 'solution' }
    return [ordered]@{
        platform = $Platform
        profile = $Profile
        loops = $Loops
        smoke = $Loops -ne $manifest.defaultLoops
        recipe = $recipe
        sdkRelativePath = if ($recipe -eq 'macosOriginal') { 'source/.dotnet' } else { 'dotnet' }
        workload = $manifest.recipes[$recipe]
        comparability = $manifest.comparability[$Profile]
        provenance = $manifest
    }
}

function Get-HoblDotnetRoot {
    param([string]$RunRoot, [ValidateSet('windows', 'macos')][string]$Platform,
        [ValidateSet('original', 'aligned')][string]$Profile)
    if ($Platform -eq 'macos' -and $Profile -eq 'original') {
        return Join-Path (Join-Path $RunRoot 'source') '.dotnet'
    }
    return Join-Path $RunRoot 'dotnet'
}

function Get-HoblDeadlines {
    param([datetime]$StartedUtc, [double]$TotalSeconds, [double]$CleanupSeconds = 20)
    if ($CleanupSeconds -le 0 -or $TotalSeconds -le $CleanupSeconds) { throw 'Cleanup must have a positive reservation inside the total budget.' }
    return @{
        total = $StartedUtc.AddSeconds($TotalSeconds)
        workload = $StartedUtc.AddSeconds($TotalSeconds - $CleanupSeconds)
        cleanupSeconds = $CleanupSeconds
    }
}

function New-HoblWrapperProbe {
    param([string]$RunRoot)
    $directory = Join-Path $RunRoot 'provenance'
    $null = New-Item -ItemType Directory -Path $directory -Force
    $path = Join-Path $directory 'probe-wrapper-root.sh'
    Assert-HoblPath $path $RunRoot
    if (Test-Path -LiteralPath $path) { throw 'Wrapper probe already exists.' }
    # Execute the pinned function, not a second implementation of its routing.
    # The false argument forbids SDK installation, and preparation is disabled.
    $body = @'
#!/usr/bin/env bash
set -euo pipefail
source_root="$1"
if command -v cygpath >/dev/null 2>&1; then
  source_root="$(cygpath -u "$source_root")"
fi
export ci=false prepare_machine=false restore=false disable_configure_toolset_import=true
unset _InitializeDotNetCli
source "$source_root/eng/common/tools.sh"
InitializeDotNetCli false
selected_root="$_InitializeDotNetCli"
if command -v cygpath >/dev/null 2>&1; then
  selected_root="$(cygpath -w "$selected_root")"
fi
printf 'HOBL_DOTNET_ROOT=%s\n' "$selected_root"
'@
    [IO.File]::WriteAllText($path, $body.Replace("`r`n", "`n"))
    return $path
}

function Save-HoblAdapterSnapshot {
    param([string]$RunRoot)
    $destination = Join-Path (Join-Path $RunRoot 'provenance') 'adapter'
    Assert-HoblPath $destination $RunRoot
    $null = New-Item -ItemType Directory -Path $destination
    $files = foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -File) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $destination $file.Name)
        [ordered]@{ name = $file.Name; bytes = $file.Length; sourceLastWriteUtc = $file.LastWriteTimeUtc.ToString('o') }
    }
    [ordered]@{
        capturedUtc = [datetime]::UtcNow.ToString('o')
        kind = 'Adapter files copied at entry, before workload setup; no post-run reconstruction'
        files = @($files)
    } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $destination 'snapshot.json')
    return $destination
}

function Assert-HoblPath {
    param([string]$Path, [string]$Root, [switch]$Recurse)
    # PowerShell's current location can differ from Environment.CurrentDirectory.
    # Resolve relative paths through the provider before applying lexical confinement.
    $full = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
    $rootFull = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $full.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, $comparison)) {
        throw "Path is not a strict child of owned root: $full"
    }
    # Inspect ancestors too: a lexically confined path can traverse a junction outside the root.
    $current = $full
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point forbidden: $current" }
        }
        $parent = Split-Path $current -Parent
        if ($parent -eq $current) { break }
        $current = $parent
    }
    if ($Recurse -and (Test-Path -LiteralPath $full)) {
        # Do not follow links; reject them before any clean can reach a foreign tree.
        foreach ($item in Get-ChildItem -LiteralPath $full -Recurse -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point forbidden: $($item.FullName)" }
        }
    }
}

function Get-HoblBytes {
    param([string]$Root)
    $total = 0L
    foreach ($item in Get-ChildItem -LiteralPath $Root -File -Recurse -Force) { $total += $item.Length }
    return $total
}

function Get-HoblFreshOutputs {
    param([string]$Artifacts, [string]$StartedUtc, [string]$Filter = '*.dll')
    # Command timestamps end in Z, e.g. 2026-11-02T06:00:00.0000000Z.
    # DateTime.Parse without RoundtripKind converts to local time; comparing its
    # raw ticks against LastWriteTimeUtc then loses real outputs on non-UTC hosts.
    $start = [datetime]::Parse($StartedUtc, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    return @(Get-ChildItem -LiteralPath $Artifacts -Recurse -File -Filter $Filter |
        Where-Object { $_.LastWriteTimeUtc -ge $start })
}

function Get-HoblUnixTime {
    param([string]$Path)
    $timing = @{}
    # Darwin time -p emits real/user/sys rows, e.g. "real 12.34". Its decimal
    # separator follows LC_NUMERIC, so "real 12,34" is also valid, without grouping.
    # https://github.com/apple-oss-distributions/shell_cmds/blob/main/time/time.c
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -notmatch '^(real|user|sys)\s+([0-9]+(?:[.,][0-9]+)?)$') { throw 'Malformed macOS time evidence.' }
        $key = $Matches[1]
        if ($timing.ContainsKey($key)) { throw "Duplicate macOS time row: $key" }
        $timing[$key] = [double]::Parse($Matches[2].Replace(',', '.'), [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($timing.Count -ne 3) { throw 'Missing macOS time evidence.' }
    return $timing
}

function New-HoblNuGetBoundary {
    param([string]$RunRoot)
    $path = Join-Path $RunRoot 'NuGet.Config'
    Assert-HoblPath $path $RunRoot
    if (Test-Path -LiteralPath $path) { throw "NuGet boundary already exists: $path" }
    # NuGet merges ancestor packageSourceMapping entries even when the source's
    # packageSources has <clear/>. For example, an ancestor's exact dotnet-tools
    # mapping beats v9.4.2's "*" mappings after that feed has been removed.
    # Replace only inherited package mappings with the pinned workload's mappings.
    # Do not clear audits, disabled sources, fallback folders or signer/config policy.
    # Mapping replacement is itself a declared routing-policy adaptation.
    [IO.File]::WriteAllText($path, @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSourceMapping><clear /></packageSourceMapping>
</configuration>
'@)
    return $path
}

function Invoke-HoblProcess {
    param([string[]]$Argv, [string]$WorkingDirectory, [string]$Log,
        [hashtable]$Environment, [datetime]$Deadline, [string]$BudgetRoot, [long]$BudgetBytes,
        [string]$TimingFile = '', [int[]]$SuccessExitCodes = @(0))
    if ([datetime]::UtcNow -ge $Deadline) { throw 'Run time budget exhausted before command start.' }
    $actual = @($Argv)
    if ($TimingFile) { $actual = @('/usr/bin/time', '-p', '-o', $TimingFile) + $actual }
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $actual[0]
    for ($i = 1; $i -lt $actual.Count; $i++) { $psi.ArgumentList.Add($actual[$i]) }
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($key in $Environment.Keys) {
        if ($null -eq $Environment[$key]) { $null = $psi.Environment.Remove($key) }
        else { $psi.Environment[$key] = [string]$Environment[$key] }
    }
    $stdout = [IO.FileStream]::new($Log, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $stderr = [IO.FileStream]::new("$Log.stderr", [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $started = [datetime]::UtcNow
    $failure = $null
    $exitCode = $null
    $hasStarted = $false
    $childProcessId = $null
    $terminatedOwnTree = $false
    try {
        if (-not $process.Start()) { throw "Unable to start $($actual[0])" }
        $hasStarted = $true
        $childProcessId = $process.Id
        $outTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
        $errTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
        $nextStorageCheck = [datetime]::UtcNow
        while (-not $process.WaitForExit(1000)) {
            if ([datetime]::UtcNow -ge $Deadline) { throw 'Run time budget exhausted; terminating only owned command tree.' }
            if ($BudgetBytes -ne [long]::MaxValue -and [datetime]::UtcNow -ge $nextStorageCheck) {
                if ($BudgetBytes -ne [long]::MaxValue -and (Get-HoblBytes $BudgetRoot) -gt $BudgetBytes) { throw 'Owned run storage budget exceeded.' }
                $nextStorageCheck = [datetime]::UtcNow.AddSeconds(30)
            }
        }
        $clock.Stop()
        $null = $outTask.GetAwaiter().GetResult()
        $null = $errTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    }
    catch {
        $failure = $_.Exception.Message
        if ($hasStarted -and -not $process.HasExited) {
            $process.Kill($true)
            $process.WaitForExit()
            $terminatedOwnTree = $true
        }
        if (Test-Path variable:outTask) { $null = $outTask.GetAwaiter().GetResult() }
        if (Test-Path variable:errTask) { $null = $errTask.GetAwaiter().GetResult() }
        $clock.Stop()
    }
    finally {
        $stdout.Dispose()
        $stderr.Dispose()
        $process.Dispose()
    }
    $record = [ordered]@{
        argv = $actual
        workingDirectory = $WorkingDirectory
        startedUtc = $started.ToString('o')
        processId = $childProcessId
        terminatedOwnTree = $terminatedOwnTree
        exitCode = $exitCode
        wallSeconds = $clock.Elapsed.TotalSeconds
        stdout = $Log
        stderr = "$Log.stderr"
        failure = $failure
    }
    $record | ConvertTo-Json -Depth 10 | Set-Content "$Log.command.json"
    if ($failure) { throw "$failure See $Log.command.json" }
    if ($exitCode -notin $SuccessExitCodes) { throw "Command exited $exitCode`: $($actual -join ' '). See $Log and $Log.stderr" }
    if ((Get-HoblBytes $BudgetRoot) -gt $BudgetBytes) { throw 'Owned run storage budget exceeded.' }
    return $record
}

function Invoke-HoblReservedCleanup {
    param([string[]]$Argv, [string]$WorkingDirectory, [string]$Log,
        [hashtable]$Environment, [datetime]$TotalDeadline, [string]$BudgetRoot)
    # This uses the reserved remainder of the ORIGINAL budget, not the expired
    # workload deadline or a fresh extension. Storage exhaustion must not prevent
    # shutdown: only this small cleanup command gets an unlimited byte threshold.
    return Invoke-HoblProcess -Argv $Argv -WorkingDirectory $WorkingDirectory -Log $Log `
        -Environment $Environment -Deadline $TotalDeadline -BudgetRoot $BudgetRoot -BudgetBytes ([long]::MaxValue)
}

function Assert-HoblEvidence {
    param([System.Collections.IDictionary]$Evidence, [int]$ExpectedLoops)
    if ($Evidence.status -ne 'passed' -or @($Evidence.iterations).Count -ne $ExpectedLoops) {
        throw 'Missing successful iterations.'
    }
    foreach ($iteration in $Evidence.iterations) {
        if (@($iteration.phases).Count -ne 3) { throw 'Missing clean/restore/build phases.' }
        for ($i = 0; $i -lt 3; $i++) {
            $phase = $iteration.phases[$i]
            if ($phase.phase -ne @('clean', 'restore', 'build')[$i] -or $phase.exitCode -ne 0) { throw 'Invalid phase result.' }
            foreach ($path in @($phase.stdout, $phase.stderr)) {
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing phase log: $path" }
            }
        }
        $seconds = [double]$iteration.scenarioRuntimeSeconds
        if ([double]::IsNaN($seconds) -or [double]::IsInfinity($seconds) -or $seconds -le 0 -or
            $iteration.compiledOutputs -lt 1 -or $iteration.builtArtifacts -lt 1) {
            throw 'Empty build work/timing evidence.'
        }
        if ((Get-Item -LiteralPath $iteration.phases[2].stdout).Length -eq 0) { throw 'Empty build log.' }
        if ($Evidence.diagnosticBinlogs -and @($iteration.binlogs).Count -lt 1) { throw 'Missing diagnostic binlogs.' }
        foreach ($path in @($iteration.binlogs)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -eq 0) {
                throw "Empty or missing binlog: $path"
            }
        }
    }
}
