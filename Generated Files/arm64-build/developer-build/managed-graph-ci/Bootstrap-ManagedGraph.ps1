[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter(Mandatory)][string]$ResultsDirectory
)
$ErrorActionPreference = 'Stop'
$RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'Arm64' -or
    [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() -ne 'Arm64') { throw 'Native ARM64 required.' }
New-Item -ItemType Directory -Path $ResultsDirectory -Force | Out-Null
$timer = [Diagnostics.Stopwatch]::StartNew()
Push-Location $RepositoryRoot
try
{
    $bootstrap = Join-Path $RepositoryRoot $(if ($IsWindows) { 'dotnet.cmd' } else { 'dotnet.sh' })
    & $bootstrap --info *> (Join-Path $ResultsDirectory 'sdk-bootstrap.log')
    if ($LASTEXITCODE -ne 0) { throw 'SDK bootstrap failed.' }
    [xml]$versions = Get-Content (Join-Path $RepositoryRoot 'eng/Versions.props') -Raw
    $runtimeVersion = @($versions.Project.PropertyGroup.DotNetRuntimeNet10VersionForTesting | Where-Object { $_ })[0]
    $nativeRoot = Join-Path $RepositoryRoot '.dotnet'
    $installer = Join-Path $nativeRoot $(if ($IsWindows) { 'dotnet-install.ps1' } else { 'dotnet-install.sh' })
    # Preseed native and non-native runtimes in isolated roots before Arcade's
    # wrapper can conflate them (dotnet/arcade#16584). Setup only, not a speedup.
    # This uses the SDK bootstrap's standard installer, not product modifications.
    foreach ($architecture in @('arm64', 'x64'))
    {
        $root = if ($architecture -eq 'arm64') { $nativeRoot } else { Join-Path $nativeRoot $architecture }
        foreach ($runtime in @('dotnet', 'aspnetcore'))
        {
            $log = Join-Path $ResultsDirectory "runtime-$runtime-$architecture.log"
            if ($IsWindows)
            {
                & pwsh -NoProfile -File $installer -Version $runtimeVersion -Architecture $architecture -Runtime $runtime -InstallDir $root -SkipNonVersionedFiles -NoPath *> $log
            }
            else
            {
                & bash $installer --version $runtimeVersion --architecture $architecture --runtime $runtime --install-dir $root --skip-non-versioned-files --no-path *> $log
            }
            if ($LASTEXITCODE -ne 0) { throw "Runtime bootstrap failed: $runtime/$architecture" }
        }
    }
    $restore = Join-Path $RepositoryRoot $(if ($IsWindows) { 'restore.cmd' } else { 'restore.sh' })
    $project = Join-Path $RepositoryRoot 'src/Aspire.Hosting/Aspire.Hosting.csproj'
    & $restore -configuration Debug -projects $project /nr:false *> (Join-Path $ResultsDirectory 'toolchain-restore.log')
    if ($LASTEXITCODE -ne 0) { throw 'Repository restore failed.' }
}
finally
{
    $timer.Stop()
    @{ elapsedSeconds = $timer.Elapsed.TotalSeconds; scope = 'SDK bootstrap, architecture-isolated runtime provisioning, repository Hosting restore; never included in build-only samples.' } |
        ConvertTo-Json | Set-Content (Join-Path $ResultsDirectory 'bootstrap.json')
    Pop-Location
}
