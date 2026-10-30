[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResultsDirectory,
    [string]$RepositoryRoot = 'Q:\aspire-perf-compiler-profiles',
    [string]$OriginalManifest = 'Q:\aspire\Generated Files\arm64-build\developer-build\compiler-image-profiles\performance-02\originals.json',
    [string]$TraceEventDirectory = 'Q:\runtime-perf-pgo-tools\artifacts\bin\coreclr\windows.arm64.Release\dotnet-pgo'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Paired-Helpers.ps1')
if (-not $IsWindows) { throw 'This released-host smoke entry is Windows-only.' }
if (Test-Path -LiteralPath $ResultsDirectory) { throw 'One smoke attempt per new evidence directory, never overwrite.' }
$null = New-Item -ItemType Directory -Path $ResultsDirectory
$ResultsDirectory = (Resolve-Path $ResultsDirectory).Path
$sdk = Join-Path $RepositoryRoot '.dotnet'
$dotnet = Join-Path $sdk 'dotnet.exe'
# Establish the epoch BEFORE either reader build, so any setup node is owned.
$epoch = [DateTime]::UtcNow
Write-PairedJson @{ smokeEpochUtc = $epoch; productRoot = $RepositoryRoot; instrumentationRoot = $PSScriptRoot
    status = 'preflight; no product builds yet' } (Join-Path $ResultsDirectory 'epoch.json')
$private = @(Get-Process | Where-Object { $_.Path -and (Test-PrivateSdkPath $_.Path $sdk $true) } |
    Select-Object Id,Path,StartTime)
Write-PairedJson $private (Join-Path $ResultsDirectory 'preexisting-root-processes.json')
if ($private.Count) { throw 'Released root has preexisting processes; refuse, never kill unknown work.' }
$head = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
$status = @(& git -C $RepositoryRoot status --porcelain)
if ($head -cne '06efc928e31486923754398007f4f78003e04ee3' -or $status.Count) { throw 'Exact clean product source required.' }
$checks = @(
    foreach ($entry in (Get-Content $OriginalManifest -Raw | ConvertFrom-Json))
    {
        @{ path = $entry.path; backup = $entry.backup
            bytesUnchanged = [Linq.Enumerable]::SequenceEqual[byte](
                [IO.File]::ReadAllBytes($entry.path), [IO.File]::ReadAllBytes($entry.backup))
            timestampUnchanged = [IO.File]::GetLastWriteTimeUtc($entry.path).Ticks -eq $entry.lastWriteTicks }
    }
)
Write-PairedJson @{ head = $head; status = $status; originalManifest = $OriginalManifest
    checks = $checks; sdkHost = Get-NativeImageIdentity $dotnet
    sdkVersion = (Get-Content (Join-Path $RepositoryRoot 'global.json') -Raw | ConvertFrom-Json).sdk.version
    bootstrap = 'Reuse existing restored P43 private SDK; no new SDK copy, restore, overlays or package installs.'
    traceLibrary = [Reflection.AssemblyName]::GetAssemblyName(
        (Join-Path $TraceEventDirectory 'Microsoft.Diagnostics.Tracing.TraceEvent.dll')).FullName } `
    (Join-Path $ResultsDirectory 'preflight.json')
if (@($checks | Where-Object { -not $_.bytesUnchanged -or -not $_.timestampUnchanged }).Count)
{
    throw 'Original P43 source/image/config bytes or timestamps differ; refuse.'
}
$commands = [Collections.Generic.List[object]]::new()
$env:MSBUILDTERMINALLOGGER = 'false'
Push-Location $RepositoryRoot
try
{
    foreach ($name in @('binlog-reader','trace-reader'))
    {
        $project = Join-Path $PSScriptRoot ([IO.Path]::Combine($name, $(if ($name -eq 'binlog-reader') { 'Reader.csproj' } else { 'TraceReader.csproj' })))
        $arguments = @('build', $project, '--configuration', 'Debug', '--nologo', '/p:UseSharedCompilation=false', '/nr:false')
        if ($name -eq 'trace-reader') { $arguments += "/p:TraceEventDirectory=$TraceEventDirectory" }
        & $dotnet @arguments *> (Join-Path $ResultsDirectory "$name-build.log")
        $exit = $LASTEXITCODE
        $commands.Add(@{ executable = $dotnet; arguments = $arguments; exitCode = $exit; workingDirectory = $RepositoryRoot
            includedInTiming = $false })
        Write-PairedJson @($commands.ToArray()) (Join-Path $ResultsDirectory 'commands.json')
        if ($exit) { throw "Actual $name compilation failed." }
    }
    & (Join-Path $PSScriptRoot 'Measure-PairedWarmup.ps1') -RepositoryRoot $RepositoryRoot `
        -ResultsDirectory (Join-Path $ResultsDirectory 'measurements') -JobStartUtc $epoch -EditCount 1 -LocalSmoke
}
finally
{
    Pop-Location
    $remaining = @(Get-Process | Where-Object { $_.Path -and (Test-PrivateSdkPath $_.Path $sdk $true) } |
        Select-Object Id,Path,StartTime)
    Write-PairedJson @{ remainingRootProcesses = $remaining
        head = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
        sourceStatus = @(& git -C $RepositoryRoot status --porcelain)
        originals = @(
            foreach ($entry in (Get-Content $OriginalManifest -Raw | ConvertFrom-Json))
            {
                @{ path = $entry.path; bytesUnchanged = [Linq.Enumerable]::SequenceEqual[byte](
                    [IO.File]::ReadAllBytes($entry.path), [IO.File]::ReadAllBytes($entry.backup))
                    timestampUnchanged = [IO.File]::GetLastWriteTimeUtc($entry.path).Ticks -eq $entry.lastWriteTicks }
            }
        ) } (Join-Path $ResultsDirectory 'outer-final-state.json')
}
