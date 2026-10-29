[CmdletBinding()]
param([Parameter(Mandatory)][string]$ResultsDirectory)
$ErrorActionPreference = 'Stop'
$arms = @('normal-1', 'mt-1', 'mt-2', 'normal-2')
$baseline = @(Get-Content (Join-Path $ResultsDirectory 'normal-1/dll-inventory.json') -Raw | ConvertFrom-Json)
$results = foreach ($arm in $arms)
{
    $directory = Join-Path $ResultsDirectory $arm
    $record = Get-Content (Join-Path $directory 'result.json') -Raw | ConvertFrom-Json
    if ($record.exitCode -ne 0) { throw "Failed arm: $arm" }
    $inventory = @(Get-Content (Join-Path $directory 'dll-inventory.json') -Raw | ConvertFrom-Json)
    if (@(Compare-Object @($baseline.path) @($inventory.path)).Count) { throw "Inventory differs: $arm" }
    $differences = @()
    if ($arm -ne 'normal-1')
    {
        foreach ($file in $baseline)
        {
            $reference = [IO.File]::ReadAllBytes((Join-Path (Join-Path $ResultsDirectory 'normal-1/dlls') $file.path))
            $candidate = [IO.File]::ReadAllBytes((Join-Path (Join-Path $directory 'dlls') $file.path))
            if (-not [Linq.Enumerable]::SequenceEqual[byte]($reference, $candidate)) { $differences += $file.path }
        }
    }
    # PerformanceSummary rows are "248616 ms  Csc  287 calls". Durations
    # overlap across workers: their sum is neither CPU nor critical-path time.
    $log = Get-Content (Join-Path $directory 'build.log') -Raw
    $compiler = [regex]::Matches($log, '(?m)^\s+(\d+) ms\s+Csc\s+(\d+) calls\s*$')
    if ($compiler.Count -ne 1) { throw "Expected one Csc summary row: $arm" }
    [ordered]@{
        arm = $arm; elapsedSeconds = $record.elapsedSeconds
        compilerTaskAggregateSeconds = [double]$compiler[0].Groups[1].Value / 1000
        compilerTaskCalls = [int]$compiler[0].Groups[2].Value
        retainedProductDllCount = $inventory.Count; differingDlls = $differences
        setup = @(Get-Content (Join-Path $directory 'setup.json') -Raw | ConvertFrom-Json)
        command = $record.command
    }
}
$summary = [ordered]@{
    source = '06efc928e31486923754398007f4f78003e04ee3'
    interpretation = 'Two samples/mode on one runner/platform. Csc task sums overlap: not CPU or critical path.'
    dllComparison = 'Exact retained Aspire*.dll paths/bytes within this platform, including satellites; not other generated artifacts or runtime behavior.'
    msbuildNodeReuse = $false; arms = @($results)
}
$summary | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $ResultsDirectory 'summary.json')
if (@($results | Where-Object { $_.differingDlls.Count }).Count) { throw 'Retained DLLs differ; inspect summary.' }
if (@($results.compilerTaskCalls | Select-Object -Unique).Count -ne 1) { throw 'Compiler task count differs between modes.' }
$results | ForEach-Object { [pscustomobject]@{ arm = $_.arm; seconds = $_.elapsedSeconds; cscCalls = $_.compilerTaskCalls; dllCount = $_.retainedProductDllCount; differences = $_.differingDlls.Count } } | Format-Table
