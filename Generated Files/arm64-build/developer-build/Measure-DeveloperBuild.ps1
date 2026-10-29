[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RepositoryRoot,

    [Parameter(Mandatory)]
    [string]$ResultsDirectory
)

$ErrorActionPreference = 'Stop'
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$null = New-Item -ItemType Directory -Path $ResultsDirectory -Force
$ResultsDirectory = (Resolve-Path -LiteralPath $ResultsDirectory).Path
$resultsPath = Join-Path $ResultsDirectory 'measurements.json'
if (Test-Path -LiteralPath $resultsPath) { throw 'Choose a new results directory; evidence must not be overwritten.' }
$changes = & git -C $RepositoryRoot status --porcelain --untracked-files=no
if ($LASTEXITCODE -ne 0 -or $changes) { throw 'The benchmark requires a clean tracked source tree.' }

$dotnetRoot = if ($env:DOTNET_GLOBAL_INSTALL_DIR)
{
    $env:DOTNET_GLOBAL_INSTALL_DIR
}
else
{
    Join-Path $RepositoryRoot '.dotnet'
}
$dotnet = Join-Path $dotnetRoot $(if ($IsWindows) { 'dotnet.exe' } else { 'dotnet' })
if (-not (Test-Path -LiteralPath $dotnet -PathType Leaf)) { throw 'Run the repository restore entry point first.' }
$env:MSBUILDTERMINALLOGGER = 'false'
$measurements = [Collections.Generic.List[object]]::new()

function Invoke-DotnetCase([string]$Project, [string]$Case, [string]$Kind, [string[]]$Arguments)
{
    $log = Join-Path $ResultsDirectory "$Project-$Case.log"
    $started = [DateTimeOffset]::UtcNow
    $timer = [Diagnostics.Stopwatch]::StartNew()
    & $dotnet @Arguments *> $log
    $code = $LASTEXITCODE
    $timer.Stop()
    $measurements.Add([pscustomobject]@{
        project = $Project
        case = $Case
        kind = $Kind
        arguments = $Arguments
        startedUtc = $started.ToString('o')
        elapsedSeconds = $timer.Elapsed.TotalSeconds
        exitCode = $code
        log = $log
    })
    ConvertTo-Json -InputObject @($measurements.ToArray()) -Depth 5 |
        Set-Content -LiteralPath $resultsPath
    Write-Output "$Project/$Case exit=$code seconds=$($timer.Elapsed.TotalSeconds)"
    if ($code -ne 0) { throw "Benchmark command failed; inspect $log" }
}

$revision = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
@{
    sourceSha = $revision
    osArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    processArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    logicalProcessorCount = [Environment]::ProcessorCount
    osDescription = [Runtime.InteropServices.RuntimeInformation]::OSDescription
    imageOS = $env:ImageOS
    imageVersion = $env:ImageVersion
    scope = 'Debug managed project builds with normal defaults; no publish/pack or AOT toggles. Restore/clean are setup, not build-only latency.'
    compilerTiming = 'Binlogs contain Csc/compiler tasks; project wall time also includes evaluation, generators, analyzers and output work.'
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ResultsDirectory 'provenance.json')
if ($IsWindows)
{
    Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ResultsDirectory 'hardware.json')
}
elseif ($IsMacOS)
{
    & sysctl machdep.cpu.brand_string hw.ncpu hw.physicalcpu hw.memsize > (Join-Path $ResultsDirectory 'hardware.log')
    if ($LASTEXITCODE -ne 0) { throw 'Could not record Mac hardware.' }
}
& $dotnet --info > (Join-Path $ResultsDirectory 'sdk-info.log')
if ($LASTEXITCODE -ne 0) { throw 'Could not identify the selected SDK.' }

$projects = @(
    @{ name = 'Hosting'; project = 'src/Aspire.Hosting/Aspire.Hosting.csproj'; edit = 'src/Aspire.Hosting/DistributedApplication.cs' },
    @{ name = 'Cli'; project = 'src/Aspire.Cli/Aspire.Cli.csproj'; edit = 'src/Aspire.Cli/Program.cs' }
)
Push-Location -LiteralPath $RepositoryRoot
try
{
    foreach ($item in $projects)
    {
        $project = Join-Path $RepositoryRoot $item.project
        Invoke-DotnetCase $item.name 'restore' 'setup' @('restore', $project, '-p:Configuration=Debug', '--nologo')
        Invoke-DotnetCase $item.name 'clean' 'setup' @('clean', $project, '--configuration', 'Debug', '--nologo')
        $build = @('build', $project, '--configuration', 'Debug', '--no-restore', '--nologo')
        Invoke-DotnetCase $item.name 'clean-build' 'build-only' ($build + "/bl:$(Join-Path $ResultsDirectory "$($item.name)-clean-build.binlog")")

        $source = Join-Path $RepositoryRoot $item.edit
        $original = [IO.File]::ReadAllBytes($source)
        $newline = if ([Text.Encoding]::UTF8.GetString($original).Contains("`r`n")) { "`r`n" } else { "`n" }
        try
        {
            foreach ($iteration in 1..3)
            {
                Invoke-DotnetCase $item.name "noop-$iteration" 'build-only' ($build + "/bl:$(Join-Path $ResultsDirectory "$($item.name)-noop-$iteration.binlog")")
                # Change a source checksum without changing behavior or project settings.
                # Restore the exact original bytes even if a measured build fails.
                $edit = [Text.Encoding]::UTF8.GetBytes("$newline// Developer build measurement $iteration$newline")
                [IO.File]::WriteAllBytes($source, [byte[]]($original + $edit))
                Invoke-DotnetCase $item.name "edit-$iteration" 'build-only' ($build + "/bl:$(Join-Path $ResultsDirectory "$($item.name)-edit-$iteration.binlog")")
            }
        }
        finally
        {
            [IO.File]::WriteAllBytes($source, $original)
        }
    }
}
finally
{
    Pop-Location
}
$changes = & git -C $RepositoryRoot status --porcelain --untracked-files=no
if ($LASTEXITCODE -ne 0 -or $changes) { throw 'Unexpected tracked source changes remain after the benchmark.' }
