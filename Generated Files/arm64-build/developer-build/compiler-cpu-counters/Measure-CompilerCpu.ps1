[CmdletBinding()]
param(
    [string]$RepositoryRoot = 'Q:\aspire-perf-scheduler-diagnostic',
    [string]$ResultsDirectory = (Join-Path $PSScriptRoot 'run-01'),
    [ValidateRange(100, 1000)]
    [int]$IntervalMilliseconds = 200,
    [ValidateSet(0, 500)]
    [int]$IdleObservationMilliseconds = 0,
    [switch]$PreflightOnly
)

$ErrorActionPreference = 'Stop'
if (-not ($IsWindows -or $IsMacOS)) { throw 'Only Windows and macOS ARM64 are supported by this diagnostic.' }
. (Join-Path $PSScriptRoot 'Compiler-Identity.ps1')
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$sdkRoot = Join-Path $RepositoryRoot '.dotnet'
$dotnet = Join-Path $sdkRoot $(if ($IsWindows) { 'dotnet.exe' } else { 'dotnet' })
$reader = Join-Path $PSScriptRoot ([IO.Path]::Combine('binlog-reader', 'bin', 'Debug', 'net11.0', 'Reader.dll'))
if (-not $PreflightOnly -and -not (Test-Path -LiteralPath $reader)) { throw 'Build the small binlog reader first (see README).' }
if (Test-Path -LiteralPath $ResultsDirectory) { throw 'Evidence directory already exists; refusing overwrite.' }
$source = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $source -ne '06efc928e31486923754398007f4f78003e04ee3') { throw 'Unexpected source identity.' }
if (@(& git -C $RepositoryRoot status --porcelain).Count) { throw 'Worktree must be source-clean.' }
$null = New-Item -ItemType Directory -Path $ResultsDirectory
$ResultsDirectory = (Resolve-Path -LiteralPath $ResultsDirectory).Path
$sessionStart = [DateTime]::UtcNow
$initialEnvironment = @(Get-ChildItem Env: | Where-Object Name -Match 'MSBUILD|DOTNET|COMPlus' | Select-Object Name,Value)
# Remove the previous scheduler/server experiments. No /mt, /m, /nr, quality,
# shared-compilation, analyzer, generator, documentation, or framework overrides.
$unset = @('MSBUILDDEBUGSCHEDULER', 'MSBUILDDEBUGPATH', 'MSBUILDUSESERVER', 'MSBUILDMULTITHREADED')
foreach ($name in $unset) { Remove-Item "Env:\$name" -ErrorAction SilentlyContinue }
$env:MSBUILDTERMINALLOGGER = 'false'
$env:DOTNET_ROOT = $sdkRoot
$env:PATH = "$sdkRoot$([IO.Path]::PathSeparator)$env:PATH"
$identities = @{}
$observed = @{}
$cases = [Collections.Generic.List[object]]::new()
$cleanup = [Collections.Generic.List[object]]::new()
$launched = [Collections.Generic.List[object]]::new()
$editFile = Join-Path $RepositoryRoot ([IO.Path]::Combine('src', 'Aspire.Hosting', 'DistributedApplication.cs'))
$originalBytes = [IO.File]::ReadAllBytes($editFile)
$originalWriteTime = [IO.File]::GetLastWriteTimeUtc($editFile)
$sourceEdited = $false
$project = [IO.Path]::Combine('src', 'Aspire.Hosting', 'Aspire.Hosting.csproj')

function Write-Json($Value, [string]$Path)
{
    ConvertTo-Json -InputObject $Value -Depth 15 | Set-Content -LiteralPath $Path
}

function Get-OwnedCandidates
{
    foreach ($p in Get-Process -Name VBCSCompiler,dotnet,MSBuild -ErrorAction SilentlyContinue)
    {
        try
        {
            if (-not $p.Path -or -not (Test-PrivateSdkPath $p.Path $sdkRoot $IsWindows)) { continue }
            $start = $p.StartTime.ToUniversalTime()
            $key = "$($p.Id):$($start.Ticks)"
            if (-not $identities.ContainsKey($key))
            {
                # Identity arguments are queried ONCE per new private-root
                # PID/start-time, not every poll, and are not exported.
                if ($IsWindows)
                {
                    $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)"
                    if (-not $cim -or [math]::Abs(($cim.CreationDate.ToUniversalTime() - $start).TotalSeconds) -gt 0.1)
                    {
                        throw "Cannot verify process start identity $key"
                    }
                    $command = $cim.CommandLine
                    $parentPid = $cim.ParentProcessId
                }
                else
                {
                    # Preserve the predecessor's exact field format, but query
                    # only this private-root PID, never `ps -axo` arguments.
                    $lines = @(& /bin/ps -ww -p "$($p.Id)" -o 'pid=,ppid=,comm=,args=')
                    if ($LASTEXITCODE -ne 0 -or $lines.Count -ne 1) { throw "ps identity unavailable for $key" }
                    $parsed = ConvertFrom-MacProcessLine $lines[0] $p.Id
                    $confirmed = [Diagnostics.Process]::GetProcessById($p.Id)
                    try
                    {
                        if ($confirmed.StartTime.ToUniversalTime().Ticks -ne $start.Ticks -or $confirmed.Path -cne $p.Path)
                        {
                            throw "Process changed during ps verification: $key"
                        }
                    }
                    finally { $confirmed.Dispose() }
                    $command = $parsed.commandEvidence
                    $parentPid = $parsed.parentId
                }
                $kind = Get-CompilerProcessKind $p.ProcessName $p.Path $command $sdkRoot $IsWindows
                $identities[$key] = [ordered]@{
                    key = $key; pid = $p.Id; startUtc = $start.ToString('O'); startTicks = $start.Ticks
                    executablePath = $p.Path; commandLineVerified = $true; parentPid = $parentPid
                    kind = $kind; nativeImage = $null; requestedRuntimeConfig = $null
                }
                # Retain exact ownership BEFORE optional native/runtime reads:
                # failed preflight must still be able to stop our new server.
                if ($kind -in @('compiler', 'msbuild-helper')) { $observed[$key] = $identities[$key] }
                if ($kind -eq 'compiler')
                {
                    try
                    {
                        $identities[$key].nativeImage = Get-NativeImageIdentity $p.Path
                        $config = if ($p.ProcessName -eq 'VBCSCompiler')
                        {
                            Join-Path (Split-Path $p.Path) 'VBCSCompiler.runtimeconfig.json'
                        }
                        else
                        {
                            $null
                        }
                        if ($config -and (Test-Path -LiteralPath $config))
                        {
                            $identities[$key].requestedRuntimeConfig = Get-Content -Raw -LiteralPath $config | ConvertFrom-Json
                        }
                    }
                    catch
                    {
                        $identities[$key].nativeIdentityFailure = $_.ToString()
                        throw
                    }
                }
            }
            if ($identities[$key].kind -in @('compiler', 'msbuild-helper'))
            {
                $observed[$key] = $identities[$key]
                [pscustomobject]@{ process = $p; identity = $identities[$key] }
            }
        }
        catch
        {
            # A disappearing process is not silently a zero-CPU compiler.
            throw "Private-SDK discovery failed for PID $($p.Id): $_"
        }
    }
}

function Read-Counters($Candidate, [double]$Offset)
{
    $p = $Candidate.process
    $p.Refresh()
    if ($p.HasExited -or -not (Test-OwnedProcessIdentity $Candidate.identity $p.Id $p.StartTime.ToUniversalTime().Ticks $p.Path $sdkRoot $IsWindows))
    {
        throw "Compiler exited or changed identity: $($Candidate.identity.key)"
    }
    # These are actual cumulative per-process CPU sums, not sampled thread-time.
    # https://learn.microsoft.com/dotnet/api/system.diagnostics.process.totalprocessortime?view=net-10.0
    $user = $p.UserProcessorTime.TotalSeconds
    $kernel = $p.PrivilegedProcessorTime.TotalSeconds
    $total = $p.TotalProcessorTime.TotalSeconds
    $snapshot = [pscustomobject]@{
        offsetSeconds = $Offset; utc = [DateTime]::UtcNow.ToString('O')
        totalSeconds = $total; userSeconds = $user; kernelSeconds = $kernel
        componentDifferenceSeconds = $total - $user - $kernel
        workingSetBytes = $p.WorkingSet64; peakWorkingSetBytes = $p.PeakWorkingSet64
        privateBytes = $p.PrivateMemorySize64; threads = $p.Threads.Count
        alive = -not $p.HasExited
    }
    if (-not $snapshot.alive) { throw "Compiler exited during CPU read: $($Candidate.identity.key); metric invalid." }
    return $snapshot
}

function Start-Command([string[]]$Arguments, [string]$LogDirectory, [string]$LogStem)
{
    $info = [Diagnostics.ProcessStartInfo]::new($dotnet)
    $info.WorkingDirectory = $RepositoryRoot
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $p = [Diagnostics.Process]::new()
    $p.StartInfo = $info
    $null = $p.Start()
    # Drain BOTH pipes immediately; sequential reads can deadlock on full buffers.
    $command = [pscustomobject]@{
        process = $p; stdout = $p.StandardOutput.ReadToEndAsync(); stderr = $p.StandardError.ReadToEndAsync()
        startTicks = $p.StartTime.ToUniversalTime().Ticks; logDirectory = $LogDirectory; logStem = $LogStem
    }
    $launched.Add($command)
    return $command
}

function Invoke-Case([string]$Name)
{
    $directory = Join-Path $ResultsDirectory $Name
    $null = New-Item -ItemType Directory -Path $directory
    $states = @{}
    $samples = [Collections.Generic.List[object]]::new()
    $observer = [Diagnostics.Process]::GetCurrentProcess()
    $observer.Refresh()
    $observerCpuStart = $observer.TotalProcessorTime.TotalSeconds
    $observerTimer = [Diagnostics.Stopwatch]::StartNew()
    $baselineAt = [DateTime]::UtcNow
    foreach ($candidate in @(Get-OwnedCandidates | Where-Object { $_.identity.kind -eq 'compiler' }))
    {
        $snapshot = Read-Counters $candidate 0
        $states[$candidate.identity.key] = @{
            identity = $candidate.identity; baseline = $snapshot; previous = $snapshot
            newServer = $false; firstSeenLagSeconds = 0; snapshots = 1
        }
        $samples.Add([pscustomobject]@{ key = $candidate.identity.key; phase = 'baseline'; snapshot = $snapshot })
    }
    if ($Name -eq 'cold-clean' -and $states.Count) { throw 'Cold requires no live private-SDK compiler.' }
    if ($Name -ne 'cold-clean' -and -not $states.Count) { throw 'Warm requires a retained compiler baseline.' }
    $baselineLead = ([DateTime]::UtcNow - $baselineAt).TotalSeconds
    $arguments = @('build', $project, '--configuration', 'Debug', '--no-restore', '--nologo', "/bl:$(Join-Path $directory 'build.binlog')")
    $started = [DateTime]::UtcNow
    $wall = [Diagnostics.Stopwatch]::StartNew()
    $command = Start-Command $arguments $directory ''
    $polls = 0
    $samplingSeconds = 0.0
    $lastPoll = 0.0
    $maxPollGap = 0.0
    try
    {
        do
        {
            if ($wall.Elapsed.TotalSeconds -gt 180) { throw "Measured command exceeded 180-second local bound: $Name" }
            $exited = $command.process.WaitForExit($IntervalMilliseconds)
            $commandEnd = $wall.Elapsed.TotalSeconds
            $pollTimer = [Diagnostics.Stopwatch]::StartNew()
            $maxPollGap = [math]::Max($maxPollGap, $commandEnd - $lastPoll)
            $lastPoll = $commandEnd
            $currentKeys = @{}
            foreach ($candidate in @(Get-OwnedCandidates | Where-Object { $_.identity.kind -eq 'compiler' }))
            {
                $key = $candidate.identity.key
                $currentKeys[$key] = $true
                $snapshot = Read-Counters $candidate $wall.Elapsed.TotalSeconds
                if (-not $states.ContainsKey($key))
                {
                    $created = [DateTime]::Parse($candidate.identity.startUtc).ToUniversalTime()
                    if ($created -lt $started) { throw "Unbaselined pre-existing compiler: $key" }
                    $states[$key] = @{
                        identity = $candidate.identity
                        baseline = [pscustomobject]@{ totalSeconds = 0.0; userSeconds = 0.0; kernelSeconds = 0.0 }
                        previous = $null; newServer = $true
                        firstSeenLagSeconds = ([DateTime]::UtcNow - $created).TotalSeconds; snapshots = 0
                    }
                }
                $state = $states[$key]
                foreach ($field in @('totalSeconds', 'userSeconds', 'kernelSeconds'))
                {
                    if ($state.previous -and $snapshot.$field -lt $state.previous.$field) { throw "Nonmonotonic $field for $key" }
                }
                if ([math]::Abs($snapshot.componentDifferenceSeconds) -gt 0.05) { throw "CPU component mismatch for $key" }
                $state.previous = $snapshot
                $state.snapshots++
                $samples.Add([pscustomobject]@{ key = $key; phase = $(if ($exited) { 'final' } else { 'poll' }); snapshot = $snapshot })
            }
            foreach ($key in $states.Keys)
            {
                if (-not $currentKeys.ContainsKey($key)) { throw "Compiler disappeared before final snapshot: $key; metric invalid, not zero." }
            }
            $polls++
            $samplingSeconds += $pollTimer.Elapsed.TotalSeconds
        } while (-not $exited)
    }
    catch
    {
        Write-Json @($samples.ToArray()) (Join-Path $directory 'counter-snapshots.json')
        throw
    }
    $wall.Stop()
    $observer.Refresh()
    $observerCpu = $observer.TotalProcessorTime.TotalSeconds - $observerCpuStart
    $observerTimer.Stop()
    [IO.File]::WriteAllText((Join-Path $directory 'stdout.log'), $command.stdout.GetAwaiter().GetResult())
    [IO.File]::WriteAllText((Join-Path $directory 'stderr.log'), $command.stderr.GetAwaiter().GetResult())
    Write-Json @($samples.ToArray()) (Join-Path $directory 'counter-snapshots.json')
    $servers = @(
        foreach ($state in $states.Values)
        {
            $total = $state.previous.totalSeconds - $state.baseline.totalSeconds
            [pscustomobject][ordered]@{
                identity = $state.identity; newServer = $state.newServer
                baseline = $state.baseline; final = $state.previous
                firstSeenLagSeconds = $state.firstSeenLagSeconds; snapshots = $state.snapshots
                cpuSeconds = $total
                userSeconds = $state.previous.userSeconds - $state.baseline.userSeconds
                kernelSeconds = $state.previous.kernelSeconds - $state.baseline.kernelSeconds
                effectiveCoresDuringCommand = $total / $commandEnd
                finalSnapshotTailSeconds = $state.previous.offsetSeconds - $commandEnd
            }
        }
    )
    $record = [ordered]@{
        case = $Name; source = $source; executable = $dotnet; arguments = $arguments
        launcherPid = $command.process.Id; exitCode = $command.process.ExitCode
        startedUtc = $started.ToString('O'); commandWallSeconds = $commandEnd
        observerPid = $PID; observerCpuSeconds = $observerCpu
        observerWindowSeconds = $observerTimer.Elapsed.TotalSeconds
        samplingIntervalMilliseconds = $IntervalMilliseconds; polls = $polls
        samplingBodyWallSeconds = $samplingSeconds; maxObservedPollGapSeconds = $maxPollGap
        warmBaselineLeadSecondsUpperBound = $baselineLead
        servers = $servers
        metricStatus = 'pending-binlog-and-coverage-validation'
        coverage = $(if ($states.Count) { 'final-alive; identity-guarded; monotonic; CPU components within 50ms' } else { 'no actual compiler identified' })
        scope = 'All retained private-SDK compiler-server work in project command, including dependency compilations; not Hosting Csc CPU alone. Launcher CPU excluded.'
        attributionLimit = 'CPU includes retained-server background activity; no-op CPU is not request CPU. Never subtract an assumed idle/GC baseline.'
    }
    $cases.Add($record)
    Write-Json $record (Join-Path $directory 'result.json')
    if ($command.process.ExitCode -ne 0) { throw "Build failed: $Name" }
    if (-not $states.Count) { throw "No actual compiler coverage: $Name" }
    # Replay is outside the measurement and launches no compiler/server.
    & $dotnet $reader (Join-Path $directory 'build.binlog') (Join-Path $directory 'csc.json') *> (Join-Path $directory 'replay.log')
    if ($LASTEXITCODE -ne 0) { throw "Binlog replay failed: $Name" }
    $csc = Get-Content -Raw -LiteralPath (Join-Path $directory 'csc.json') | ConvertFrom-Json
    if (($Name -eq 'no-op' -and $csc.cscCount -ne 0) -or ($Name -ne 'no-op' -and $csc.cscCount -eq 0))
    {
        throw "Unexpected Csc count $($csc.cscCount): $Name"
    }
    foreach ($task in $csc.tasks)
    {
        if (@($task.compilerServerMessages | Where-Object { $_ -match 'CompilerServer: server - server processed compilation' }).Count -ne 1)
        {
            throw "Csc used an unconfirmed/fallback compiler: $Name; reject CPU coverage."
        }
    }
    if ($csc.cscCount -gt 0 -and [double](($servers | Measure-Object cpuSeconds -Sum).Sum) -le 0)
    {
        throw "Csc ran but compiler CPU did not advance: $Name; reject unsupported/default-zero counters."
    }
    $record.cscCount = $csc.cscCount
    $record.cscAggregateWallSeconds = [double](($csc.tasks | Measure-Object wallSeconds -Sum).Sum)
    $record.metricStatus = 'valid-process-window-counter-diagnostic'
    Write-Json $record (Join-Path $directory 'result.json')
    Write-Host "$Name wall=$commandEnd compilerCPU=$(($servers | Measure-Object cpuSeconds -Sum).Sum) Csc=$($csc.cscCount)"
}

function Invoke-IdleObservation
{
    # Optional future-pair observation only. No build/request is launched; this
    # labels lingering server work and is NEVER subtracted from another case.
    $before = @{}
    foreach ($candidate in @(Get-OwnedCandidates | Where-Object { $_.identity.kind -eq 'compiler' }))
    {
        $before[$candidate.identity.key] = Read-Counters $candidate 0
    }
    if (-not $before.Count) { throw 'Idle observation requires the retained compiler.' }
    $observer = [Diagnostics.Process]::GetCurrentProcess()
    $observer.Refresh()
    $observerStart = $observer.TotalProcessorTime.TotalSeconds
    $timer = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Milliseconds $IdleObservationMilliseconds
    $after = @{}
    foreach ($candidate in @(Get-OwnedCandidates | Where-Object { $_.identity.kind -eq 'compiler' }))
    {
        $after[$candidate.identity.key] = Read-Counters $candidate $timer.Elapsed.TotalSeconds
    }
    $timer.Stop()
    $observer.Refresh()
    $rows = foreach ($key in $before.Keys)
    {
        if (-not $after.ContainsKey($key)) { throw 'Compiler lifetime ended during idle observation; CPU observation invalid.' }
        foreach ($field in @('totalSeconds', 'userSeconds', 'kernelSeconds'))
        {
            if ($after[$key].$field -lt $before[$key].$field) { throw 'Nonmonotonic idle counter.' }
        }
        if ([math]::Abs($after[$key].componentDifferenceSeconds) -gt 0.05) { throw 'Idle CPU component mismatch.' }
        [pscustomobject]@{
            key = $key; baseline = $before[$key]; final = $after[$key]
            cpuSeconds = $after[$key].totalSeconds - $before[$key].totalSeconds
        }
    }
    if ($after.Count -ne $before.Count) { throw 'Compiler set changed during idle observation.' }
    Write-Json ([ordered]@{
        kind = 'unbuilt-background-server-observation-not-request-CPU'
        requestedMilliseconds = $IdleObservationMilliseconds; wallSeconds = $timer.Elapsed.TotalSeconds
        observerCpuSeconds = $observer.TotalProcessorTime.TotalSeconds - $observerStart
        servers = @($rows); subtraction = 'none'
    }) (Join-Path $ResultsDirectory 'background-observation.json')
}

$failure = $null
try
{
    if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'Arm64' -or
        [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() -ne 'Arm64')
    {
        throw 'Both OS and observer must be native ARM64.'
    }
    $instrumentation = @($initialEnvironment | Where-Object {
        ($_.Name -in @('DOTNET_STARTUP_HOOKS', 'DOTNET_EnableEventPipe', 'DOTNET_ROLL_FORWARD', 'COMPlus_EnableEventPipe')) -and
        $_.Value -and $_.Value -ne '0'
    })
    if ($instrumentation.Count) { throw 'Unexpected tracing/runtime policy environment; refusing a silently altered compiler runtime.' }
    $sdkNative = Get-NativeImageIdentity $dotnet
    $sdkInfo = Start-Command @('--info') $ResultsDirectory 'sdk-info.'
    if (-not $sdkInfo.process.WaitForExit(30000) -or $sdkInfo.process.ExitCode -ne 0) { throw 'SDK info preflight failed.' }
    $sdkText = $sdkInfo.stdout.GetAwaiter().GetResult()
    [IO.File]::WriteAllText((Join-Path $ResultsDirectory 'sdk-info.stdout.log'), $sdkText)
    $hostSection = [regex]::Match($sdkText, '(?ms)^Host:\s*\r?\n(?<body>.*?)(?:^\S|\z)')
    if (-not $hostSection.Success -or $hostSection.Groups['body'].Value -notmatch '(?m)^\s+Architecture:\s+arm64\s*$')
    {
        throw 'SDK --info did not confirm the actual host architecture as arm64.'
    }
    if ($IsWindows)
    {
        $processors = @(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors)
        $computer = Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer,Model,TotalPhysicalMemory
    }
    else
    {
        # Supported hardware-only sysctl keys; do not dump the process table or
        # all sysctl values. Raw labels preserve model/core/memory identity.
        $hardware = @(& /usr/sbin/sysctl hw.model hw.physicalcpu hw.logicalcpu hw.memsize)
        if ($LASTEXITCODE -ne 0 -or $hardware.Count -ne 4) { throw 'macOS hardware identity unavailable.' }
        $processors = $computer = $hardware
    }
    Write-Json ([ordered]@{
        source = $source; root = $RepositoryRoot; sdkRoot = $sdkRoot; observerPid = $PID
        startedUtc = $sessionStart.ToString('O'); logicalProcessors = [Environment]::ProcessorCount
        os = [Runtime.InteropServices.RuntimeInformation]::OSDescription
        processArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
        processors = $processors; computer = $computer; sdkNativeImage = $sdkNative
        initialEnvironment = $initialEnvironment; explicitlyUnset = $unset
        effectiveEnvironment = @(Get-ChildItem Env: | Where-Object Name -Match 'MSBUILD|DOTNET|COMPlus' | Select-Object Name,Value)
    }) (Join-Path $ResultsDirectory 'environment.json')
    if (@(Get-OwnedCandidates | Where-Object { $_.identity.kind -eq 'compiler' }).Count) { throw 'Existing owned compiler; cold reset must be explicit, not broad shutdown.' }
    if ($PreflightOnly)
    {
        Write-Json ([ordered]@{
            source = $source; status = 'native-SDK-preflight-only'
            compilerCpuCoverage = 'unverified until actual compiler discovery, counters and final-alive coverage during builds'
            cleanOrBuildStarted = $false; sourceEdited = $false
        }) (Join-Path $ResultsDirectory 'preflight.json')
        return
    }
    $setupArguments = @('clean', $project, '--configuration', 'Debug', '--nologo')
    Write-Json $setupArguments (Join-Path $ResultsDirectory 'clean-command.json')
    $setup = Start-Command $setupArguments $ResultsDirectory 'clean.'
    if (-not $setup.process.WaitForExit(120000)) { throw 'Project clean exceeded 120-second local bound.' }
    [IO.File]::WriteAllText((Join-Path $ResultsDirectory 'clean.stdout.log'), $setup.stdout.GetAwaiter().GetResult())
    [IO.File]::WriteAllText((Join-Path $ResultsDirectory 'clean.stderr.log'), $setup.stderr.GetAwaiter().GetResult())
    if ($setup.process.ExitCode -ne 0) { throw 'Project clean failed.' }
    Invoke-Case 'cold-clean'
    Invoke-Case 'no-op'
    if ($IdleObservationMilliseconds) { Invoke-IdleObservation }
    $comment = [Text.Encoding]::UTF8.GetBytes("`r`n// Owned compiler CPU counter diagnostic; restored byte-for-byte after measurement.`r`n")
    $sourceEdited = $true
    [IO.File]::WriteAllBytes($editFile, [byte[]]($originalBytes + $comment))
    Invoke-Case 'warm-comment-edit'
}
catch
{
    $failure = $_.ToString()
    Write-Json ([ordered]@{ status = 'failed'; error = $failure; rule = 'Do not interpret incomplete coverage as zero compiler CPU.' }) (Join-Path $ResultsDirectory 'failure.json')
    throw
}
finally
{
    foreach ($command in $launched)
    {
        $p = $command.process
        if (-not $p.HasExited)
        {
            # The exact ProcessStartInfo child is ours, even if sampling failed.
            if ($p.StartTime.ToUniversalTime().Ticks -ne $command.startTicks -or
                -not (Test-PrivateSdkPath $p.Path $sdkRoot $IsWindows))
            {
                throw 'Launcher identity changed; refusing termination.'
            }
            Stop-Process -Id $p.Id -Force
            $null = $p.WaitForExit(10000)
        }
    }
    if ($sourceEdited)
    {
        [IO.File]::WriteAllBytes($editFile, $originalBytes)
        [IO.File]::SetLastWriteTimeUtc($editFile, $originalWriteTime)
    }
    Write-Json @($identities.Values) (Join-Path $ResultsDirectory 'process-identities.json')
    Write-Json @($cases.ToArray()) (Join-Path $ResultsDirectory 'measurements.json')
    # Discover only this root, then terminate only exact observed PID/start-time
    # identities created during this invocation. Never global build-server shutdown.
    if (-not $PreflightOnly)
    {
        try { $null = @(Get-OwnedCandidates) } catch { $cleanup.Add([ordered]@{ discoveryError = $_.ToString() }) }
    }
    foreach ($identity in $observed.Values)
    {
        if ([DateTime]::Parse($identity.startUtc).ToUniversalTime() -lt $sessionStart) { continue }
        $p = Get-Process -Id $identity.pid -ErrorAction SilentlyContinue
        if (-not $PreflightOnly -and $p -and
            (Test-OwnedProcessIdentity $identity $p.Id $p.StartTime.ToUniversalTime().Ticks $p.Path $sdkRoot $IsWindows))
        {
            Stop-Process -Id $identity.pid -Force
            $exited = $p.WaitForExit(10000)
            $cleanup.Add([ordered]@{ identity = $identity; stopped = $true; exitConfirmed = $exited })
        }
    }
    Write-Json @($cleanup.ToArray()) (Join-Path $ResultsDirectory 'owned-cleanup.json')
    foreach ($command in $launched)
    {
        # A failed CPU read may interrupt an active build. Stop its confirmed
        # children before waiting for pipe EOF; an inherited writer must not
        # turn metric failure into an unbounded drain wait.
        foreach ($stream in @('stdout', 'stderr'))
        {
            $task = $command.$stream
            $path = Join-Path $command.logDirectory "$($command.logStem)$stream.log"
            if ($task.Wait(5000))
            {
                [IO.File]::WriteAllText($path, $task.GetAwaiter().GetResult())
            }
            else
            {
                $failure = "Owned $stream pipe did not close after cleanup; CPU metric/log coverage invalid."
                [IO.File]::WriteAllText("$path.incomplete", $failure)
                Write-Json ([ordered]@{ status = 'failed'; error = $failure }) (Join-Path $ResultsDirectory 'failure.json')
            }
        }
    }
    $restored = [Linq.Enumerable]::SequenceEqual[byte]($originalBytes, [IO.File]::ReadAllBytes($editFile))
    $status = @(& git -C $RepositoryRoot status --porcelain)
    Write-Json ([ordered]@{ sourceBytesRestored = $restored; trackedAndUntrackedStatus = $status; failure = $failure }) (Join-Path $ResultsDirectory 'final-state.json')
    if (-not $restored -or $status.Count) { throw 'Source restoration/source-clean check failed.' }
    if ($failure) { throw "Diagnostic failed; retained evidence: $failure" }
}
