$ErrorActionPreference = 'Stop'
$work = 'Q:\aspire-perf-compiler-pgo'
$evidence = $PSScriptRoot
$private = Join-Path $work '.dotnet'
$sdk = Join-Path $private 'sdk\11.0.100-rc.2.26504.105'
$dotnet = Join-Path $private 'dotnet.exe'
$config = Join-Path $sdk 'Roslyn\bincore\VBCSCompiler.runtimeconfig.json'
$sourceFile = Join-Path $work 'src\Aspire.Hosting\DistributedApplication.cs'
$reader = Join-Path $evidence 'reader-bin\Reader.dll'

function Write-Json($Value, [string] $Path)
{
    ConvertTo-Json -InputObject $Value -Depth 20 | Set-Content -LiteralPath $Path
}

function Get-Machine([string] $Path)
{
    $stream = [IO.File]::OpenRead($Path)
    $binary = [IO.BinaryReader]::new($stream)
    try
    {
        $stream.Position = 0x3c
        $offset = $binary.ReadInt32()
        $stream.Position = $offset + 4
        return $binary.ReadUInt16().ToString('X4')
    }
    finally
    {
        $binary.Dispose()
    }
}

function Get-Workers
{
    Get-CimInstance Win32_Process |
        Where-Object { $_.Name -match '^(MSBuild|VBCSCompiler|dotnet)\.exe$' } |
        Select-Object ProcessId,ParentProcessId,CreationDate,ExecutablePath,CommandLine
}

function Get-OwnedCompilers
{
    foreach ($process in Get-Process -Name VBCSCompiler,dotnet -ErrorAction SilentlyContinue)
    {
        if (-not $process.Path -or -not $process.Path.StartsWith("$private\", [StringComparison]::OrdinalIgnoreCase))
        {
            continue
        }
        $identity = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)"
        if ($identity.CommandLine -match 'VBCSCompiler\.(exe|dll)')
        {
            [pscustomobject] @{
                pid = $process.Id
                startTicks = $process.StartTime.ToUniversalTime().Ticks
                path = $process.Path
                commandLine = $identity.CommandLine
                parentPid = $identity.ParentProcessId
            }
        }
    }
}

function Stop-Exact($Identity)
{
    $process = Get-Process -Id $Identity.pid -ErrorAction SilentlyContinue
    $alreadyExited = -not $process
    if ($process)
    {
        if ($process.Path -ne $Identity.path -or $process.StartTime.ToUniversalTime().Ticks -ne $Identity.startTicks)
        {
            throw "Refusing reused PID $($Identity.pid)"
        }
        Stop-Process -Id $Identity.pid -Force
        if (-not $process.WaitForExit(10000))
        {
            throw "Owned process failed to exit: $($Identity.pid)"
        }
    }
    return [pscustomobject] @{ identity = $Identity; alreadyExited = $alreadyExited; exitConfirmed = $true }
}

function Stop-OwnedCompilers
{
    foreach ($identity in @(Get-OwnedCompilers))
    {
        Stop-Exact $identity
    }
}

function Invoke-BuildCommand([string[]] $Arguments, [string] $Stem)
{
    $info = [Diagnostics.ProcessStartInfo]::new($dotnet)
    $info.WorkingDirectory = $work
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $Arguments)
    {
        $info.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $started = [DateTime]::UtcNow
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $null = $process.Start()
    # Read concurrently: either redirected stream can otherwise fill its pipe.
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $exited = $process.WaitForExit(240000)
    if (-not $exited)
    {
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit()
    }
    $timer.Stop()
    [IO.File]::WriteAllText("$Stem.stdout.log", $stdout.GetAwaiter().GetResult())
    [IO.File]::WriteAllText("$Stem.stderr.log", $stderr.GetAwaiter().GetResult())
    $result = [pscustomobject] @{
        executable = $dotnet
        workingDirectory = $work
        arguments = $Arguments
        startUtc = $started
        endUtc = [DateTime]::UtcNow
        wallSeconds = $timer.Elapsed.TotalSeconds
        exitCode = $process.ExitCode
        pid = $process.Id
        timedOut = -not $exited
    }
    Write-Json $result "$Stem.result.json"
    if (-not $exited -or $process.ExitCode -ne 0)
    {
        throw "Command failed; retained receipt: $Stem"
    }
    return $result
}

function Read-Binlog([string] $Path, [string] $Output)
{
    & $dotnet $reader binlog $Path $Output
    if ($LASTEXITCODE)
    {
        throw "Binlog replay failed: $Path"
    }
}

function Snapshot-Outputs([string] $Destination)
{
    foreach ($project in @('Aspire.Hosting', 'Aspire.Hosting.Integration.Analyzers'))
    {
        $files = @(
            Get-ChildItem (Join-Path $work "artifacts\bin\$project\Debug") -Recurse -File
            Get-ChildItem (Join-Path $work "artifacts\obj\$project\Debug") -Recurse -File |
                Where-Object Extension -In @('.cs', '.resources', '.xml', '.json', '.dll', '.pdb')
        )
        foreach ($file in $files)
        {
            $relative = [IO.Path]::GetRelativePath((Join-Path $work 'artifacts'), $file.FullName)
            $target = Join-Path $Destination $relative
            $null = New-Item -ItemType Directory (Split-Path $target) -Force
            Copy-Item -LiteralPath $file.FullName -Destination $target
        }
    }
}
