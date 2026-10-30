[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter(Mandatory)][string]$ResultsDirectory,
    [Parameter(Mandatory)][DateTime]$JobStartUtc
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Paired-Helpers.ps1')
if (-not ($IsWindows -or $IsMacOS)) { throw 'Only native Windows/macOS ARM64 are supported.' }
if (Test-Path -LiteralPath $ResultsDirectory) { throw 'Refusing overwrite/retry of a paired block.' }
$null = New-Item -ItemType Directory -Path $ResultsDirectory
$ResultsDirectory = (Resolve-Path -LiteralPath $ResultsDirectory).Path
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$sdkRoot = Join-Path $RepositoryRoot '.dotnet'
$dotnet = Join-Path $sdkRoot $(if ($IsWindows) { 'dotnet.exe' } else { 'dotnet' })
$source = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
if (-not (Test-PairedDispatch $env:GITHUB_REPOSITORY $env:GITHUB_REF $env:GITHUB_EVENT_NAME $source) -or
    @(& git -C $RepositoryRoot status --porcelain).Count)
{
    throw 'Fork/manual/ref/exact clean product source guard failed.'
}
if ($JobStartUtc.ToUniversalTime() -gt [DateTime]::UtcNow -or $JobStartUtc -lt [DateTime]::UtcNow.AddMinutes(-30))
{
    throw 'Invalid job ownership epoch.'
}
$inherited = @(Get-ChildItem Env: | Where-Object Name -Match '^(DOTNET|COMPlus|CORECLR|COR_|MSBUILD)' | Select-Object Name,Value)
# Reject inherited tuning instead of silently normalizing a different experiment.
$allowed = @('DOTNET_ROOT', 'DOTNET_ROOT_X64', 'DOTNET_ROOT_ARM64', 'DOTNET_MULTILEVEL_LOOKUP',
    'DOTNET_NOLOGO', 'DOTNET_CLI_TELEMETRY_OPTOUT', 'DOTNET_SKIP_FIRST_TIME_EXPERIENCE',
    'DOTNET_GENERATE_ASPNET_CERTIFICATE', 'DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE', 'MSBUILDTERMINALLOGGER')
Write-PairedJson $inherited (Join-Path $ResultsDirectory 'inherited-environment.json')
if (@($inherited | Where-Object Name -NotIn $allowed).Count) { throw 'Inherited build/runtime override; investigate before measuring.' }
$env:DOTNET_ROOT = $sdkRoot
$env:PATH = "$sdkRoot$([IO.Path]::PathSeparator)$env:PATH"
$env:MSBUILDTERMINALLOGGER = 'false'
$project = [IO.Path]::Combine('src', 'Aspire.Hosting', 'Aspire.Hosting.csproj')
$sourceFile = Join-Path $RepositoryRoot ([IO.Path]::Combine('src', 'Aspire.Hosting', 'DistributedApplication.cs'))
$reader = Join-Path $PSScriptRoot ([IO.Path]::Combine('binlog-reader', 'bin', 'Debug', 'net11.0', 'Reader.dll'))
$sdkVersion = (Get-Content (Join-Path $RepositoryRoot 'global.json') -Raw | ConvertFrom-Json).sdk.version
$config = Join-Path $sdkRoot ([IO.Path]::Combine('sdk', $sdkVersion, 'Roslyn', 'bincore', 'VBCSCompiler.runtimeconfig.json'))
$originalSource = [IO.File]::ReadAllBytes($sourceFile)
$sourceTime = [IO.File]::GetLastWriteTimeUtc($sourceFile)
$configs = @(Get-ChildItem -LiteralPath $sdkRoot -Recurse -Filter '*.runtimeconfig.json' -File | ForEach-Object {
    @{ path = $_.FullName; bytes = [IO.File]::ReadAllBytes($_.FullName); time = $_.LastWriteTimeUtc }
})
$originalConfig = [IO.File]::ReadAllBytes($config)
$configTime = [IO.File]::GetLastWriteTimeUtc($config)
$candidateConfig = New-PgoCandidate $originalConfig
[IO.File]::WriteAllBytes((Join-Path $ResultsDirectory 'baseline.runtimeconfig.json'), $originalConfig)
[IO.File]::WriteAllBytes((Join-Path $ResultsDirectory 'candidate.runtimeconfig.json'), $candidateConfig)
$receipts = [Collections.Generic.List[object]]::new()
$cleanup = [Collections.Generic.List[object]]::new()
$comparisons = [Collections.Generic.List[object]]::new()
$observed = @{}
$confirmedExited = @{}
$failure = $null
$cleanupFailed = $false

function Get-PrivateProcesses
{
    foreach ($process in Get-Process -Name dotnet,VBCSCompiler,MSBuild -ErrorAction SilentlyContinue)
    {
        if (-not $process.Path -or -not (Test-PrivateSdkPath $process.Path $sdkRoot $IsWindows)) { continue }
        $start = $process.StartTime.ToUniversalTime()
        if ($start -lt $JobStartUtc.ToUniversalTime()) { throw "Preexisting private process: $($process.Id)" }
        if ($IsWindows)
        {
            $native = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)"
            if (-not $native -or [math]::Abs(($native.CreationDate.ToUniversalTime() - $start).TotalSeconds) -gt 0.1)
            {
                throw 'Private process birth could not be established.'
            }
            $command = $native.CommandLine
            $parentId = $native.ParentProcessId
        }
        else
        {
            $lines = @(& /bin/ps -ww -p "$($process.Id)" -o 'pid=,ppid=,comm=,args=')
            if ($LASTEXITCODE -ne 0 -or $lines.Count -ne 1) { throw 'Private ps identity unavailable.' }
            $parsed = ConvertFrom-MacProcessLine $lines[0] $process.Id
            $command = $parsed.commandEvidence
            $parentId = $parsed.parentId
        }
        $identity = @{ pid = $process.Id; startTicks = $start.Ticks; startUtc = $start.ToString('O')
            executablePath = $process.Path; commandEvidence = $command; parentPid = $parentId
            kind = Get-CompilerProcessKind $process.ProcessName $process.Path $command $sdkRoot $IsWindows }
        $confirmed = Get-Process -Id $process.Id -ErrorAction Stop
        if (-not (Test-OwnedProcessIdentity $identity $confirmed.Id $confirmed.StartTime.ToUniversalTime().Ticks $confirmed.Path $sdkRoot $IsWindows))
        {
            throw 'Private identity changed during native query.'
        }
        $observed["$($identity.pid):$($identity.startTicks)"] = $identity
        $identity
    }
}

function Get-ExitDiagnostic($Identity)
{
    $diagnostic = @{ identity = $Identity; utc = [DateTime]::UtcNow.ToString('O')
        observerPid = $PID; observerRuntime = [Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
        observerArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() }
    if ($IsWindows)
    {
        $diagnostic.native = Get-CimInstance Win32_Process -Filter "ProcessId=$($Identity.pid)" |
            Select-Object ProcessId,ParentProcessId,CreationDate,ExecutablePath,CommandLine
    }
    else
    {
        $lines = @(& /bin/ps -ww -p "$($Identity.pid)" -o 'pid=,ppid=,state=,lstart=,comm=' 2>&1 | ForEach-Object { "$_" })
        $diagnostic.psExitCode = $LASTEXITCODE
        $diagnostic.raw = $lines
        if ($diagnostic.psExitCode -eq 0 -and $lines.Count -eq 1)
        {
            try { $diagnostic.native = ConvertFrom-PairedMacState $lines[0] $Identity.pid }
            catch { $diagnostic.nativeParseError = $_.ToString() }
        }
    }
    return $diagnostic
}

function Stop-ExactPrivate($Identity)
{
    if ($Identity.startTicks -lt $JobStartUtc.ToUniversalTime().Ticks -or
        -not (Test-PrivateSdkPath $Identity.executablePath $sdkRoot $IsWindows))
    {
        throw 'Refusing identity predating job epoch or outside private SDK.'
    }
    $process = Get-Process -Id $Identity.pid -ErrorAction SilentlyContinue
    $receipt = @{ identity = $Identity; before = Get-ExitDiagnostic $Identity; exitConfirmed = $false }
    try
    {
        if ($process)
        {
            if (-not (Test-OwnedProcessIdentity $Identity $process.Id $process.StartTime.ToUniversalTime().Ticks $process.Path $sdkRoot $IsWindows))
            {
                throw 'PID reuse/path change; refusing stop and refusing an exit claim.'
            }
            Stop-Process -Id $Identity.pid -Force
            # A non-child Process.WaitForExit can confuse retained Unix process
            # state with liveness. Require BOTH runtime absence and native ps
            # absence; a zombie or unresolved query remains a FAILED gate.
            $receipt.waitForExit = $process.WaitForExit(10000)
        }
        $timer = [Diagnostics.Stopwatch]::StartNew()
        do
        {
            $remaining = Get-Process -Id $Identity.pid -ErrorAction SilentlyContinue
            $native = Get-ExitDiagnostic $Identity
            $nativeAbsent = if ($IsWindows) { -not $native.native } else {
                Test-PairedAbsence ([bool]$remaining) $native.psExitCode $native.raw
            }
            if (-not $remaining -and $nativeAbsent) { $receipt.exitConfirmed = $true; break }
            if ($remaining -and -not (Test-OwnedProcessIdentity $Identity $remaining.Id $remaining.StartTime.ToUniversalTime().Ticks $remaining.Path $sdkRoot $IsWindows))
            {
                throw 'PID reused during absence proof; no exit claim.'
            }
            Start-Sleep -Milliseconds 100
        } while ($timer.Elapsed.TotalSeconds -lt 10)
        $receipt.after = $native
        if (-not $receipt.exitConfirmed) { throw 'Owned exit unconfirmed (including possible zombie); raw diagnostics retained.' }
    }
    catch
    {
        $receipt.error = $_.ToString()
        $receipt.afterFailure = Get-ExitDiagnostic $Identity
        throw
    }
    finally
    {
        $cleanup.Add($receipt)
        Write-PairedJson @($cleanup.ToArray()) (Join-Path $ResultsDirectory 'cleanup.json')
    }
}

function Reset-PrivateProcesses
{
    $current = @(Get-PrivateProcesses)
    $owned = @(Get-PairedPendingIdentities $observed $current $confirmedExited)
    # Stop MSBuild node parents first so a compiler orphan is not kept behind a
    # surviving owned node. This equal per-arm node-lifetime control is NOT a
    # measurement of pool-local ordinary developer server lifetime.
    foreach ($identity in @($owned | Sort-Object { if ($_.kind -eq 'compiler') { 1 } else { 0 } }))
    {
        Stop-ExactPrivate $identity
        $confirmedExited["$($identity.pid):$($identity.startTicks)"] = $true
    }
    if (@(Get-PrivateProcesses).Count) { throw 'Private processes remain after reset.' }
}

function Invoke-PairedCommand([string[]]$Arguments, [string]$Stem)
{
    $info = [Diagnostics.ProcessStartInfo]::new($dotnet)
    $info.WorkingDirectory = $RepositoryRoot
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $start = [DateTime]::UtcNow
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $null = $process.Start()
    $birth = $process.StartTime.ToUniversalTime().Ticks
    # Drain concurrently; no sampler, counter tool or profiler runs in this interval.
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $exited = $process.WaitForExit(120000)
    $timer.Stop()
    if (-not $exited)
    {
        $identity = @{ pid = $process.Id; startTicks = $birth; executablePath = $dotnet }
        Stop-ExactPrivate $identity
        Reset-PrivateProcesses
    }
    if (-not $stdout.Wait(5000) -or -not $stderr.Wait(5000)) { throw 'Command pipes did not close within bound.' }
    [IO.File]::WriteAllText("$Stem.stdout.log", $stdout.GetAwaiter().GetResult())
    [IO.File]::WriteAllText("$Stem.stderr.log", $stderr.GetAwaiter().GetResult())
    $receipt = @{ executable = $dotnet; arguments = $Arguments; workingDirectory = $RepositoryRoot
        startUtc = $start; wallSeconds = $timer.Elapsed.TotalSeconds; timedOut = -not $exited
        exitCode = $process.ExitCode; pid = $process.Id; startTicks = $birth }
    Write-PairedJson $receipt "$Stem.result.json"
    if (-not $exited -or $process.ExitCode -ne 0) { throw "Command failed: $Stem" }
    return $receipt
}

function Restore-PairedSource
{
    [IO.File]::WriteAllBytes($sourceFile, $originalSource)
    [IO.File]::SetLastWriteTimeUtc($sourceFile, $sourceTime)
}

function Set-PairedArm([string]$Arm)
{
    if (@(Get-PrivateProcesses).Count) { throw 'Config replacement requires absence of all private job processes.' }
    [IO.File]::WriteAllBytes($config, $(if ($Arm -eq 'baseline') { $originalConfig } else { $candidateConfig }))
    [IO.File]::SetLastWriteTimeUtc($config, $configTime)
}

function Get-PairedProof([string]$Arm)
{
    $servers = @(Get-PrivateProcesses | Where-Object kind -EQ 'compiler')
    if ($servers.Count -ne 1) { throw "Expected one private compiler, got $($servers.Count)" }
    $identity = $servers[0]
    $compilerStem = Join-Path (Split-Path $config) 'VBCSCompiler'
    if ($identity.commandEvidence -notmatch [regex]::Escape($compilerStem))
    {
        throw 'Compiler command does not bind to the exact SDK runtimeconfig.'
    }
    $native = Get-NativeImageIdentity $identity.executablePath
    $process = Get-Process -Id $identity.pid
    if ($IsWindows)
    {
        $libraries = @($process.Modules | Where-Object ModuleName -In @('coreclr.dll', 'clrjit.dll', 'hostpolicy.dll') |
            ForEach-Object FileName)
    }
    else
    {
        # lsof -Fn emits n/path records; preserve spaces rather than split on
        # whitespace. Inspect only this proven private PID, outside timing.
        $lines = @(& /usr/sbin/lsof -a -p "$($identity.pid)" -Fn)
        if ($LASTEXITCODE -ne 0) { throw 'Compiler loaded-runtime identity unavailable.' }
        $libraries = @($lines | Where-Object { $_ -match '^n.+/(libcoreclr|libclrjit|libhostpolicy)\.dylib$' } |
            ForEach-Object { $_.Substring(1) } | Sort-Object -Unique)
    }
    if ($libraries.Count -ne 3) { throw 'Expected actual loaded coreclr/JIT/hostpolicy libraries.' }
    $runtime = @(
        foreach ($library in $libraries)
        {
            if (-not (Test-PrivateSdkPath $library $sdkRoot $IsWindows)) { throw 'Runtime outside private SDK.' }
            $stream = [IO.File]::OpenRead($library)
            try
            {
                $bytes = [byte[]]::new([int][math]::Min(4096, $stream.Length))
                $stream.ReadExactly($bytes, 0, $bytes.Length)
                $header = Get-NativeImageHeader $bytes
                # The shared helper deliberately marks Mach-O dylibs as
                # non-executable. Validate their CPU type, not that apphost bit.
                if (-not $header.arm64 -and -not ($header.format -eq 'Mach-O64-thin' -and $header.cpuType -eq '0x0100000C'))
                {
                    throw 'Loaded runtime is not thin native ARM64.'
                }
                @{ path = $library; header = $header }
            }
            finally { $stream.Dispose() }
        }
    )
    [byte[]]$expected = if ($Arm -eq 'baseline') { $originalConfig } else { $candidateConfig }
    if (-not [Linq.Enumerable]::SequenceEqual[byte]($expected, [IO.File]::ReadAllBytes($config))) { throw 'Compiler config changed.' }
    return @{ identity = $identity; native = $native; runtime = $runtime; config = $config
        policy = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json }
}

try
{
    if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'Arm64' -or
        [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() -ne 'Arm64')
    {
        throw 'OS and observer must both be native ARM64.'
    }
    $hardware = if ($IsWindows)
    {
        @{ processors = @(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors)
            computer = Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer,Model,TotalPhysicalMemory }
    }
    else
    {
        $values = @(& /usr/sbin/sysctl hw.model hw.physicalcpu hw.logicalcpu hw.memsize)
        if ($LASTEXITCODE -ne 0 -or $values.Count -ne 4) { throw 'Hardware identity unavailable.' }
        $values
    }
    Write-PairedJson @{ source = $source; instrumentation = (& git -C $PSScriptRoot rev-parse HEAD).Trim()
        jobStartUtc = $JobStartUtc; hardware = $hardware; imageOS = $env:ImageOS; imageVersion = $env:ImageVersion
        os = [Runtime.InteropServices.RuntimeInformation]::OSDescription; sdk = $sdkVersion
        observerPid = $PID; observerRuntime = [Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
        host = Get-NativeImageIdentity $dotnet; order = @('baseline','candidate','candidate','baseline')
        cases = @('cold','noop') + @(1..8 | ForEach-Object { "edit$_" })
        timing = 'Command start-to-exit wall; Csc task elapsed sum is work wall, NEVER CPU.'
        setup = 'One untimed clean/build per policy; clean and private-node reset excluded per arm.'
        cache = 'Filesystem/NuGet caches warm; cold means fresh compiler and cleaned outputs, not machine cold.'
        lifetime = 'All job-private SDK processes reset before each arm; within-arm ordinary node reuse unchanged.'
        effectiveEnvironment = @(Get-ChildItem Env: | Where-Object Name -Match '^(DOTNET|COMPlus|CORECLR|COR_|MSBUILD)' | Select-Object Name,Value)
    } (Join-Path $ResultsDirectory 'protocol.json')
    $null = Invoke-PairedCommand @('--info') (Join-Path $ResultsDirectory 'dotnet-info')
    Reset-PrivateProcesses
    $index = 0
    foreach ($arm in @('baseline','candidate','baseline','candidate','candidate','baseline'))
    {
        $index++
        $warmup = $index -le 2
        $ordinal = $index - 2
        $directory = Join-Path $ResultsDirectory $(if ($warmup) { "untimed-$arm" } else { "$ordinal-$arm" })
        $null = New-Item -ItemType Directory -Path $directory
        Restore-PairedSource
        Set-PairedArm baseline
        Set-PairedArm $arm
        $null = Invoke-PairedCommand @('clean', $project, '--configuration', 'Debug', '--nologo') (Join-Path $directory 'clean')
        Reset-PrivateProcesses
        $birthAfter = [DateTime]::UtcNow.Ticks
        $server = $null
        $cases = if ($warmup) { @('cold') } else { @('cold','noop') + @(1..8 | ForEach-Object { "edit$_" }) }
        foreach ($case in $cases)
        {
            if ($case.StartsWith('edit'))
            {
                [IO.File]::WriteAllBytes($sourceFile, (Get-PairedEdit $originalSource ([int]$case.Substring(4))))
                # Deterministic corresponding source bytes AND timestamps across
                # arms; fixed increasing future mtimes force each compile even
                # if a hosted filesystem has coarse timestamp granularity.
                [IO.File]::SetLastWriteTimeUtc($sourceFile, $sourceTime.AddYears(10).AddSeconds([int]$case.Substring(4)))
            }
            $caseDirectory = Join-Path $directory $case
            $null = New-Item -ItemType Directory -Path $caseDirectory
            [IO.File]::WriteAllBytes((Join-Path $caseDirectory 'source-input.bin'), [IO.File]::ReadAllBytes($sourceFile))
            $inputTime = [IO.File]::GetLastWriteTimeUtc($sourceFile)
            Write-PairedJson @{ sourceFile = $sourceFile; lastWriteTimeUtc = $inputTime } (Join-Path $caseDirectory 'source-input.json')
            $binlog = Join-Path $caseDirectory 'build.binlog'
            $receipt = Invoke-PairedCommand @('build', $project, '--configuration', 'Debug', '--no-restore', '--nologo', "/bl:$binlog") (Join-Path $caseDirectory 'build')
            $null = Invoke-PairedCommand @($reader, $binlog, (Join-Path $caseDirectory 'csc.json')) (Join-Path $caseDirectory 'offline-replay')
            $data = Get-Content (Join-Path $caseDirectory 'csc.json') -Raw | ConvertFrom-Json
            $expected = if ($case -eq 'cold') { 15 } elseif ($case -eq 'noop') { 0 } else { 14 }
            if (-not $data.successful -or $data.unfinishedCscCount -or $data.cscCount -ne $expected -or $data.diagnostics.Count)
            {
                throw "Compilation/diagnostic gate failed: $ordinal/$case"
            }
            foreach ($task in $data.tasks)
            {
                if (-not $task.succeeded -or @($task.compilerServerMessages | Where-Object { $_ -match 'server - server processed compilation' }).Count -ne 1)
                {
                    throw 'Actual compilation server processing not proven.'
                }
            }
            $main = @($data.tasks | Where-Object {
                $_.target -eq 'CoreCompile' -and [IO.Path]::GetFileName($_.project) -eq 'Aspire.Hosting.csproj'
            })
            if ($case -ne 'noop' -and ($main.Count -ne 1 -or $main[0].analyzerPaths.Count -ne 26))
            {
                throw 'Hosting analyzer/generator quality scope changed.'
            }
            if (@($data.tasks | Where-Object { [IO.Path]::GetFileName($_.project) -notin @('Aspire.Hosting.csproj','Aspire.Hosting.Integration.Analyzers.csproj') }).Count)
            {
                throw 'Unexpected compilation scope.'
            }
            $proof = Get-PairedProof $arm
            if ($proof.identity.startTicks -lt $birthAfter -or ($server -and
                ($server.pid -ne $proof.identity.pid -or $server.startTicks -ne $proof.identity.startTicks)))
            {
                throw 'Compiler must be fresh per arm, stable within arm.'
            }
            $server = $proof.identity
            Write-PairedJson $proof (Join-Path $caseDirectory 'compiler.json')
            if (-not $warmup)
            {
                $outputs = Join-Path $caseDirectory 'outputs'
                $files = @(Get-PairedOutputFiles $RepositoryRoot)
                $manifest = @(
                    foreach ($file in $files)
                    {
                        $relative = [IO.Path]::GetRelativePath((Join-Path $RepositoryRoot 'artifacts'), $file.FullName)
                        $target = Join-Path $outputs $relative
                        $null = New-Item -ItemType Directory -Path (Split-Path $target) -Force
                        Copy-Item -LiteralPath $file.FullName -Destination $target
                        @{ path = $relative; bytes = $file.Length }
                    }
                )
                Write-PairedJson $manifest (Join-Path $caseDirectory 'output-manifest.json')
                $commands = ConvertTo-Json -InputObject @($data.tasks |
                    Select-Object project,target,commandLine,analyzerPaths | Sort-Object project,target,commandLine) -Depth 15 -Compress
                [IO.File]::WriteAllText((Join-Path $caseDirectory 'compile-inputs.json'), $commands)
                if ($ordinal -gt 1)
                {
                    $reference = Join-Path $ResultsDirectory ([IO.Path]::Combine('1-baseline', $case))
                    $comparison = Compare-PairedTrees (Join-Path $reference 'outputs') $outputs
                    $comparisons.Add($comparison)
                    $referenceInput = Get-Content (Join-Path $reference 'source-input.json') -Raw | ConvertFrom-Json
                    if (-not [Linq.Enumerable]::SequenceEqual[byte](
                        [IO.File]::ReadAllBytes((Join-Path $reference 'source-input.bin')),
                        [IO.File]::ReadAllBytes((Join-Path $caseDirectory 'source-input.bin'))) -or
                        $inputTime -ne [DateTime]$referenceInput.lastWriteTimeUtc)
                    {
                        throw 'Corresponding source bytes/timestamps differ across arms.'
                    }
                    if (-not $comparison.passed -or $commands -cne [IO.File]::ReadAllText((Join-Path $reference 'compile-inputs.json')))
                    {
                        throw 'Corresponding emitted bytes/manifests/compiler commands differ.'
                    }
                }
                if ($case -eq 'noop')
                {
                    $comparison = Compare-PairedTrees (Join-Path $directory ([IO.Path]::Combine('cold', 'outputs'))) $outputs
                    $comparisons.Add($comparison)
                    if (-not $comparison.passed) { throw 'No-op changed emitted output.' }
                }
                $receipts.Add(@{ index = $ordinal; arm = $arm; case = $case; command = $receipt
                    cscCount = $data.cscCount; mainCscWallSeconds = @($main.wallSeconds)
                    cscTaskWallSumSeconds = ($data.tasks | Measure-Object wallSeconds -Sum).Sum
                    outputFiles = $manifest.Count; compiler = $server })
                Write-PairedJson @($receipts.ToArray()) (Join-Path $ResultsDirectory 'measurements.json')
            }
        }
        Restore-PairedSource
        Reset-PrivateProcesses
    }
}
catch
{
    $failure = $_.ToString()
    Write-PairedJson @{ failure = $failure; stack = $_.ScriptStackTrace } (Join-Path $ResultsDirectory 'failure.json')
}
finally
{
    Restore-PairedSource
    try { Reset-PrivateProcesses } catch { $cleanupFailed = $true; $cleanupError = $_.ToString() }
    # Restoration must happen even if exit cannot be established; fail the gate,
    # retain diagnostics, and do not start another arm or retry.
    [IO.File]::WriteAllBytes($config, $originalConfig)
    [IO.File]::SetLastWriteTimeUtc($config, $configTime)
    $configChecks = @(
        foreach ($entry in $configs)
        {
            @{ path = $entry.path; bytesUnchanged = [Linq.Enumerable]::SequenceEqual[byte]($entry.bytes, [IO.File]::ReadAllBytes($entry.path))
                timestampUnchanged = [IO.File]::GetLastWriteTimeUtc($entry.path) -eq $entry.time }
        }
    )
    $state = @{ sourceBytesRestored = [Linq.Enumerable]::SequenceEqual[byte]($originalSource, [IO.File]::ReadAllBytes($sourceFile))
        sourceTimestampRestored = [IO.File]::GetLastWriteTimeUtc($sourceFile) -eq $sourceTime
        sourceHead = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
        sourceStatus = @(& git -C $RepositoryRoot status --porcelain); configChecks = $configChecks
        failure = $failure; cleanupFailed = $cleanupFailed; cleanupError = $cleanupError
        completedCases = $receipts.Count; comparisons = @($comparisons.ToArray())
        processIdentities = @($observed.Values); confirmedExited = @($confirmedExited.Keys) }
    Write-PairedJson $state (Join-Path $ResultsDirectory 'final-state.json')
    if ($failure -or $cleanupFailed -or $receipts.Count -ne 40 -or -not $state.sourceBytesRestored -or
        -not $state.sourceTimestampRestored -or $state.sourceStatus.Count -or
        @($configChecks | Where-Object { -not $_.bytesUnchanged -or -not $_.timestampUnchanged }).Count)
    {
        throw 'Paired block failed; retain raw evidence, no automatic retry or promotion.'
    }
}
