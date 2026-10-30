$ErrorActionPreference = 'Stop'

function Write-CpuJson($Value, [string]$Path)
{
    ConvertTo-Json -InputObject $Value -Depth 15 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Test-HostedCpuContext($Context)
{
    return $Context.actions -ceq 'true' -and
        $Context.repository -ceq 'yeelam-gordon/aspire' -and
        $Context.ref -ceq 'refs/heads/perf/arm64-standard-cpu-calibration' -and
        $Context.event -ceq 'workflow_dispatch' -and
        $Context.runnerEnvironment -ceq 'github-hosted' -and
        $Context.runnerOS -ceq 'Windows' -and $Context.runnerArch -ceq 'ARM64' -and
        $Context.imageOS -ceq 'win11-vs2026-arm64' -and
        $Context.osArch -ceq 'Arm64' -and $Context.processArch -ceq 'Arm64' -and
        $Context.runId -match '^\d+$'
}

function Assert-HostedCpuContext
{
    $context = [ordered]@{
        actions = $env:GITHUB_ACTIONS; repository = $env:GITHUB_REPOSITORY
        ref = $env:GITHUB_REF; event = $env:GITHUB_EVENT_NAME
        runnerEnvironment = $env:RUNNER_ENVIRONMENT; runnerOS = $env:RUNNER_OS
        runnerArch = $env:RUNNER_ARCH; imageOS = $env:ImageOS; runId = $env:GITHUB_RUN_ID
        osArch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        processArch = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    }
    if (-not (Test-HostedCpuContext $context))
    {
        throw 'Capture/setup requires the exact fork/manual/ref and dedicated hosted Windows ARM64 image. Local recording has no override.'
    }
    $workspace = [IO.Path]::GetFullPath($env:GITHUB_WORKSPACE).TrimEnd('\') + '\'
    if (-not $PSScriptRoot.StartsWith($workspace, [StringComparison]::OrdinalIgnoreCase))
    {
        throw 'Instrumentation is outside the owned GitHub workspace.'
    }
    $head = (& git -C $PSScriptRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $head -cne $env:GITHUB_SHA)
    {
        throw 'Checked-out instrumentation does not match dispatched SHA.'
    }
    return $context
}

function Get-CpuPeMachine([string]$Path)
{
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($Path))
    try
    {
        # DOS offset 0x3c points at the PE signature, followed by the Machine UInt16.
        $reader.BaseStream.Position = 0x3c
        $offset = $reader.ReadInt32()
        $reader.BaseStream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw "Invalid PE: $Path" }
        return '0x{0:X4}' -f $reader.ReadUInt16()
    }
    finally { $reader.Dispose() }
}

function Start-CpuProcess([string]$Executable, [string[]]$Arguments, [string]$Prefix)
{
    $info = [Diagnostics.ProcessStartInfo]::new($Executable)
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($info)
    return [pscustomobject]@{
        process = $process; pid = $process.Id
        birthTicks = $process.StartTime.ToUniversalTime().Ticks
        executable = [IO.Path]::GetFullPath($Executable)
        arguments = $Arguments; prefix = $Prefix
        stdout = $process.StandardOutput.ReadToEndAsync()
        stderr = $process.StandardError.ReadToEndAsync()
        startedUtc = [DateTime]::UtcNow
    }
}

function Stop-ExactCpuProcess($Owned)
{
    $live = Get-Process -Id $Owned.pid -ErrorAction SilentlyContinue
    if ($null -ne $live -and -not $live.HasExited)
    {
        if ($live.StartTime.ToUniversalTime().Ticks -ne $Owned.birthTicks -or
            -not [string]::Equals($live.Path, $Owned.executable, [StringComparison]::OrdinalIgnoreCase))
        {
            throw 'PID identity changed; refusing cleanup.'
        }
        Stop-Process -Id $Owned.pid -ErrorAction Stop
        if (-not $Owned.process.WaitForExit(5000)) { throw 'Owned process did not exit after exact-PID cleanup.' }
    }
}

function Assert-ExactCpuProcess($Owned)
{
    $live = Get-Process -Id $Owned.pid -ErrorAction Stop
    if ($live.HasExited -or $live.StartTime.ToUniversalTime().Ticks -ne $Owned.birthTicks -or
        -not [string]::Equals($live.Path, $Owned.executable, [StringComparison]::OrdinalIgnoreCase))
    {
        throw 'Owned live PID/birth/path no longer matches.'
    }
}

function Complete-CpuProcess($Owned, [int]$TimeoutSeconds)
{
    $exited = $Owned.process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $exited) { Stop-ExactCpuProcess $Owned }
    $outputComplete = $true
    foreach ($stream in @('stdout', 'stderr'))
    {
        try
        {
            # A spawned broker can inherit a pipe even after its client exits.
            # Do not let finalization hang forever while draining that pipe.
            $Owned.$stream.WaitAsync([TimeSpan]::FromSeconds(5)).GetAwaiter().GetResult() |
                Set-Content "$($Owned.prefix).$stream.log"
        }
        catch
        {
            $outputComplete = $false
            $_.ToString() | Set-Content "$($Owned.prefix).$stream.log"
        }
    }
    $receipt = [ordered]@{
        pid = $Owned.pid; birthTicks = $Owned.birthTicks; executable = $Owned.executable
        arguments = $Owned.arguments; startedUtc = $Owned.startedUtc.ToString('O')
        endedUtc = [DateTime]::UtcNow.ToString('O'); timeoutSeconds = $TimeoutSeconds
        timedOut = -not $exited -or -not $outputComplete
        outputComplete = $outputComplete; exitCode = $Owned.process.ExitCode
    }
    Write-CpuJson $receipt "$($Owned.prefix).receipt.json"
    return $receipt
}

function Wait-CpuFile([string]$Path, $Owned, [int]$TimeoutSeconds)
{
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    {
        if (Test-Path -LiteralPath $Path) { return }
        if ($Owned.process.HasExited) { throw "Owned helper exited before $Path" }
        Start-Sleep -Milliseconds 50
    }
    throw "Timeout waiting for owned helper: $Path"
}

function Start-KnownCpuFixture([string]$Sdk, [string]$Binaries, [string]$Directory)
{
    if (Test-Path -LiteralPath $Directory) { throw 'Refusing fixture evidence overwrite.' }
    $null = New-Item -ItemType Directory -Path $Directory
    $hostPath = Join-Path $Sdk 'dotnet.exe'
    if ((Get-CpuPeMachine $hostPath) -ne '0xAA64') { throw 'Fixture host must be native ARM64.' }
    return Start-CpuProcess $hostPath @((Join-Path $Binaries 'KnownWork.dll'), $Directory) (Join-Path $Directory 'helper')
}

function Assert-KnownCpuFixture($Owned, [string]$Directory, [string]$Sdk)
{
    Wait-CpuFile (Join-Path $Directory 'ready.json') $Owned 10
    $ready = Get-Content (Join-Path $Directory 'ready.json') -Raw | ConvertFrom-Json
    if ($ready.pid -ne $Owned.pid -or $ready.birthTicks -ne $Owned.birthTicks -or
        -not [string]::Equals($ready.imagePath, $Owned.executable, [StringComparison]::OrdinalIgnoreCase) -or
        $ready.processArchitecture -cne 'Arm64' -or $ready.osArchitecture -cne 'Arm64' -or
        -not $ready.coreclrPath.StartsWith(([IO.Path]::GetFullPath($Sdk).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase) -or
        (Get-CpuPeMachine $ready.coreclrPath) -ne '0xAA64')
    {
        throw 'Owned PID/birth/path/native private runtime validation failed.'
    }
    return $ready
}

function Close-KnownCpuFixture($Owned, [string]$Directory)
{
    Set-Content -LiteralPath (Join-Path $Directory 'end') -Value 'owned graceful exit'
    $receipt = Complete-CpuProcess $Owned 5
    if ($receipt.timedOut -or $receipt.exitCode -ne 0) { throw 'Owned fixture cleanup did not exit normally.' }
}
