[CmdletBinding()]
param([Parameter(Mandatory)][string]$Sdk, [Parameter(Mandatory)][string]$Binaries, [Parameter(Mandatory)][string]$Output)
. (Join-Path $PSScriptRoot 'Helpers.ps1')
# This entry point has no collector command, callback or capture option.
$owned = Start-KnownCpuFixture $Sdk $Binaries $Output
try
{
    $ready = Assert-KnownCpuFixture $owned $Output $Sdk
    Set-Content -LiteralPath (Join-Path $Output 'go') -Value 'unprofiled control only'
    Wait-CpuFile (Join-Path $Output 'done') $owned 15
    $phases = @(Get-Content (Join-Path $Output 'phases.json') -Raw | ConvertFrom-Json)
    $burnCpu = ($phases | Where-Object name -eq 'Burn' | Measure-Object cpuSeconds -Sum).Sum
    $sleepCpu = ($phases | Where-Object name -eq 'Sleep' | Measure-Object cpuSeconds -Sum).Sum
    $elapsed = ($phases | Measure-Object elapsedSeconds -Sum).Sum
    $passed = $phases.Count -eq 4 -and $elapsed -lt 20 -and $burnCpu -gt 1 -and $sleepCpu -lt 0.5
    Write-CpuJson @{ passed = $passed; profiled = $false; identity = $ready; phases = $phases; burnCpuSeconds = $burnCpu; sleepCpuSeconds = $sleepCpu; workElapsedSeconds = $elapsed } (Join-Path $Output 'control.json')
    if (-not $passed) { throw 'Known-work control failed CPU/Sleep discrimination.' }
}
finally
{
    Close-KnownCpuFixture $owned $Output
}
