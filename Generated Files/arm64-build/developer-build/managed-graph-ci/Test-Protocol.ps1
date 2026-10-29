[CmdletBinding()]
param([Parameter(Mandatory)][string]$ResultsDirectory)
$ErrorActionPreference = 'Stop'
if (Test-Path $ResultsDirectory) { throw 'Refusing to overwrite smoke evidence.' }
foreach ($arm in @('normal-1', 'mt-1', 'mt-2', 'normal-2'))
{
    $directory = Join-Path $ResultsDirectory $arm
    New-Item -ItemType Directory -Path (Join-Path $directory 'dlls/fr') -Force | Out-Null
    foreach ($path in @('Aspire.Fixture.dll', 'fr/Aspire.Fixture.resources.dll'))
    {
        [IO.File]::WriteAllBytes((Join-Path (Join-Path $directory 'dlls') $path), [byte[]]@(1, 2, 3))
    }
    @(@{ path = 'Aspire.Fixture.dll'; bytes = 3 }, @{ path = 'fr/Aspire.Fixture.resources.dll'; bytes = 3 }) |
        ConvertTo-Json | Set-Content (Join-Path $directory 'dll-inventory.json')
    @{ exitCode = 0; elapsedSeconds = 1; command = 'fixture, not a build' } |
        ConvertTo-Json | Set-Content (Join-Path $directory 'result.json')
    '[]' | Set-Content (Join-Path $directory 'setup.json')
    '     123 ms  Csc  2 calls' | Set-Content (Join-Path $directory 'build.log')
}
& (Join-Path $PSScriptRoot 'Analyze-ManagedGraph.ps1') -ResultsDirectory $ResultsDirectory
Copy-Item (Join-Path $ResultsDirectory 'summary.json') (Join-Path $ResultsDirectory 'positive-summary.json')
[IO.File]::WriteAllBytes((Join-Path $ResultsDirectory 'mt-1/dlls/fr/Aspire.Fixture.resources.dll'), [byte[]]@(1, 2, 4))
$rejected = $false
try { & (Join-Path $PSScriptRoot 'Analyze-ManagedGraph.ps1') -ResultsDirectory $ResultsDirectory }
catch
{
    if ($_.Exception.Message -ne 'Retained DLLs differ; inspect summary.') { throw }
    $rejected = $true
}
if (-not $rejected) { throw 'Changed satellite was incorrectly accepted.' }
@{ positiveComparison = 'pass'; changedSatelliteRejected = $rejected; evidenceIsSynthetic = $true } |
    ConvertTo-Json | Set-Content (Join-Path $ResultsDirectory 'smoke-result.json')
