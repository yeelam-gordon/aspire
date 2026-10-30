[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter(Mandatory)][string]$ResultsDirectory,
    [Parameter(Mandatory)][DateTime]$JobStartUtc,
    [ValidateSet(1, 20)][int]$EditCount = 20,
    [switch]$LocalSmoke,
    [string]$ContinueLocalSmokeFrom
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Paired-Helpers.ps1')
. (Join-Path $PSScriptRoot 'Paired-Cleanup.ps1')
if (-not ($IsWindows -or $IsMacOS)) { throw 'Only native Windows/macOS ARM64 are supported.' }
if (Test-Path -LiteralPath $ResultsDirectory) { throw 'Refusing overwrite/retry of a paired block.' }
$null = New-Item -ItemType Directory -Path $ResultsDirectory
$ResultsDirectory = (Resolve-Path -LiteralPath $ResultsDirectory).Path
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$sdkRoot = Join-Path $RepositoryRoot '.dotnet'
$dotnet = Join-Path $sdkRoot $(if ($IsWindows) { 'dotnet.exe' } else { 'dotnet' })
$source = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
if (-not (Test-PairedInvocation $env:GITHUB_REPOSITORY $env:GITHUB_REF $env:GITHUB_EVENT_NAME $source `
    $EditCount $LocalSmoke.IsPresent ($env:GITHUB_ACTIONS -eq 'true')) -or
    @(& git -C $RepositoryRoot status --porcelain).Count)
{
    throw 'Hosted fork/manual/ref/twenty-edit or explicit local one-edit smoke/exact clean source guard failed.'
}
$expectedCases = 2 * (2 + $EditCount)
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
$traceReader = Join-Path $PSScriptRoot ([IO.Path]::Combine('trace-reader', 'bin', 'Debug', 'net11.0', 'TraceReader.dll'))
$sdkVersion = (Get-Content (Join-Path $RepositoryRoot 'global.json') -Raw | ConvertFrom-Json).sdk.version
$config = Join-Path $sdkRoot ([IO.Path]::Combine('sdk', $sdkVersion, 'Roslyn', 'bincore', 'VBCSCompiler.runtimeconfig.json'))
$originalSource = [IO.File]::ReadAllBytes($sourceFile)
$sourceTime = [IO.File]::GetLastWriteTimeUtc($sourceFile)
$immutableFiles = @(
    Get-ChildItem -LiteralPath $sdkRoot -Recurse -Filter '*.runtimeconfig.json' -File
    Get-ChildItem -LiteralPath (Split-Path $config) -File
    Get-Item -LiteralPath $dotnet
    foreach ($pattern in @('coreclr.dll','clrjit.dll','hostpolicy.dll','libcoreclr.dylib','libclrjit.dylib','libhostpolicy.dylib'))
    {
        Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'shared') -Recurse -Filter $pattern -File
    }
) | Sort-Object FullName -Unique
$configs = @($immutableFiles | ForEach-Object {
    @{ path = $_.FullName; bytes = [IO.File]::ReadAllBytes($_.FullName); time = $_.LastWriteTimeUtc }
})
$originalConfig = [IO.File]::ReadAllBytes($config)
$configTime = [IO.File]::GetLastWriteTimeUtc($config)
Assert-PairedNormalPolicy $originalConfig
[IO.File]::WriteAllBytes((Join-Path $ResultsDirectory 'original.runtimeconfig.json'), $originalConfig)
Write-PairedJson @($configs | ForEach-Object { @{ path = $_.path; bytes = $_.bytes.Length; timestampUtc = $_.time } }) `
    (Join-Path $ResultsDirectory 'immutable-inputs.json')
$receipts = [Collections.Generic.List[object]]::new()
$cleanup = [Collections.Generic.List[object]]::new()
$comparisons = [Collections.Generic.List[object]]::new()
$observed = @{}
$confirmedExited = @{}
$cleanupByKey = @{}
$shutdownRequests = @{}
$stopRequests = @{}
$nativeBirths = @{}
$ownedParentProofs = @{}
$cleanupPlans = [Collections.Generic.List[object]]::new()
$script:resetInProgress = $false
$failure = $null
$cleanupFailed = $false
$timingPassed = $false
$diagnosticPassed = $false
$diagnosticCases = 0
$diagnosticRequests = [Collections.Generic.List[object]]::new()
$cpuErrors = [Collections.Generic.List[object]]::new()
$lastBuildExit = $null
$lastCaseEnd = $null
$referenceResults = $ResultsDirectory
$lifetimes = @(1..3)
$checkingContinuation = [bool]$ContinueLocalSmokeFrom
if ($ContinueLocalSmokeFrom)
{
    # Bounded recovery of the actual first Windows smoke's quoted-pipe cleanup
    # bug. Never repeat a completed build or expose a hosted retry mechanism.
    if (-not $LocalSmoke -or $EditCount -ne 1) { throw 'Continuation is local one-edit smoke only.' }
    $prior = Get-Content (Join-Path $ContinueLocalSmokeFrom 'final-state.json') -Raw | ConvertFrom-Json
    $priorProtocol = Get-Content (Join-Path $ContinueLocalSmokeFrom 'protocol.json') -Raw | ConvertFrom-Json
    $priorRows = @(Get-Content (Join-Path $ContinueLocalSmokeFrom 'measurements.json') -Raw | ConvertFrom-Json)
    if (-not $prior.localSmoke -or $prior.completedCases -ne 3 -or $prior.expectedCases -ne 6 -or
        $prior.diagnosticCases -ne 0 -or -not $prior.cleanupFailed -or
        $prior.failure -cne 'Exactly one owned compiler pipe required.' -or
        -not $prior.sourceBytesRestored -or -not $prior.sourceTimestampRestored -or
        $prior.sourceStatus.Count -or $prior.sourceHead -cne $source -or
        ([DateTime]$priorProtocol.jobStartUtc).Ticks -ne $JobStartUtc.ToUniversalTime().Ticks -or
        ($priorRows.case -join ',') -cne 'cold,noop,edit1' -or
        @($priorRows | Where-Object { $_.index -ne 1 -or $_.serverCpu.status -ne 'valid' }).Count -or
        @($prior.configChecks | Where-Object { -not $_.bytesUnchanged -or -not $_.timestampUnchanged }).Count)
    {
        throw 'Prior evidence is not the exact bounded quoted-pipe cleanup failure.'
    }
    foreach ($row in $priorRows) { $receipts.Add($row) }
    foreach ($identity in $prior.processIdentities) { $observed["$($identity.pid):$($identity.startTicks)"] = $identity }
    foreach ($key in $prior.confirmedExited) { $confirmedExited[$key] = $true }
    $referenceResults = (Resolve-Path $ContinueLocalSmokeFrom).Path
    $lifetimes = @(2,3)
    Write-PairedJson @{ prior = $referenceResults; reusedCases = 3; notRepeated = @('cold','noop','edit1')
        reason = 'Quoted Windows pipe token parser repair; only unfinished second lifetime and diagnostic execute.'
        epoch = $JobStartUtc } (Join-Path $ResultsDirectory 'continuation.json')
}

function Get-PrivateProcesses
{
    foreach ($process in Get-Process -Name dotnet,VBCSCompiler,MSBuild -ErrorAction SilentlyContinue)
    {
        if (-not $process.Path -or -not (Test-PrivateSdkPath $process.Path $sdkRoot $IsWindows)) { continue }
        $fields = Get-PairedRuntimeFields $process
        if (-not $fields.complete) { throw 'Private discovery cannot establish live runtime birth/path.' }
        $start = $process.StartTime.ToUniversalTime()
        if ($start -lt $JobStartUtc.ToUniversalTime()) { throw "Preexisting private process: $($process.Id)" }
        if ($IsWindows)
        {
            $native = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)"
            if (-not $native -or $native.CreationDate -isnot [DateTime] -or
                [math]::Abs(($native.CreationDate.ToUniversalTime() - $start).TotalSeconds) -gt 0.1)
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
        if ($checkingContinuation)
        {
            $key = "$($identity.pid):$($identity.startTicks)"
            if (-not $observed.ContainsKey($key) -or
                -not (Test-OwnedProcessIdentity $observed[$key] $identity.pid $identity.startTicks $identity.executablePath $sdkRoot $IsWindows))
            {
                throw 'Unknown private process during smoke continuation; never adopt or stop.'
            }
        }
        $confirmed = Get-Process -Id $process.Id -ErrorAction Stop
        $confirmedFields = Get-PairedRuntimeFields $confirmed
        if (-not $confirmedFields.complete -or
            -not (Test-OwnedProcessIdentity $identity $confirmedFields.pid $confirmedFields.startTicks $confirmedFields.executablePath $sdkRoot $IsWindows))
        {
            throw 'Private identity changed during native query.'
        }
        if (-not $IsWindows)
        {
            $key = "$($identity.pid):$($identity.startTicks)"
            if (-not $nativeBirths.ContainsKey($key))
            {
                $nativeState = Get-ExitDiagnostic $identity
                $null = Get-PairedExitState $identity $confirmedFields $nativeState '' $false $false $sdkRoot $false
                $nativeBirths[$key] = $nativeState.native.nativeStart
            }
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

function Invoke-PairedCommand([string[]]$Arguments, [string]$Stem,
    [hashtable]$ExtraEnvironment = @{}, [string]$Executable = $dotnet)
{
    $info = [Diagnostics.ProcessStartInfo]::new($Executable)
    $info.WorkingDirectory = $RepositoryRoot
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    foreach ($key in $ExtraEnvironment.Keys) { $info.Environment[$key] = $ExtraEnvironment[$key] }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $start = [DateTime]::UtcNow
    $startTicks = [Diagnostics.Stopwatch]::GetTimestamp()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $null = $process.Start()
    $birth = $process.StartTime.ToUniversalTime().Ticks
    # Drain concurrently; no sampler, counter tool or profiler runs in this interval.
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $exited = $process.WaitForExit(120000)
    $timer.Stop()
    $exitTicks = [Diagnostics.Stopwatch]::GetTimestamp()
    $exitUtc = [DateTime]::UtcNow
    if ($Arguments[0] -eq 'build') { $script:lastBuildExit = $exitUtc }
    if (-not $exited)
    {
        $identity = @{ pid = $process.Id; startTicks = $birth; executablePath = $Executable; kind = 'launched-command' }
        Stop-PairedOwnedParent $identity
        Confirm-PairedPrivateAbsence $identity
        if (-not $script:resetInProgress) { Reset-PrivateProcesses }
    }
    if (-not $stdout.Wait(5000) -or -not $stderr.Wait(5000)) { throw 'Command pipes did not close within bound.' }
    [IO.File]::WriteAllText("$Stem.stdout.log", $stdout.GetAwaiter().GetResult())
    [IO.File]::WriteAllText("$Stem.stderr.log", $stderr.GetAwaiter().GetResult())
    $receipt = @{ executable = $Executable; arguments = $Arguments; workingDirectory = $RepositoryRoot
        startUtc = $start; exitUtc = $exitUtc; wallSeconds = $timer.Elapsed.TotalSeconds; timedOut = -not $exited
        addedEnvironment = $ExtraEnvironment
        commandStartMonotonicTicks = $startTicks; commandExitMonotonicTicks = $exitTicks
        stopwatchFrequency = [Diagnostics.Stopwatch]::Frequency
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

function Read-PairedCpu($Identity)
{
    $p = Get-Process -Id $Identity.pid -ErrorAction Stop
    if (-not (Test-OwnedProcessIdentity $Identity $p.Id $p.StartTime.ToUniversalTime().Ticks $p.Path $sdkRoot $IsWindows))
    {
        throw 'Compiler identity changed before CPU endpoint.'
    }
    $start = [DateTime]::UtcNow
    $user = $p.UserProcessorTime.TotalSeconds
    $userAt = [DateTime]::UtcNow
    $kernel = $p.PrivilegedProcessorTime.TotalSeconds
    $kernelAt = [DateTime]::UtcNow
    $total = $p.TotalProcessorTime.TotalSeconds
    $totalAt = [DateTime]::UtcNow
    Assert-PairedCpuValues $user $kernel $total
    $p.Refresh()
    if ($p.HasExited -or -not (Test-OwnedProcessIdentity $Identity $p.Id $p.StartTime.ToUniversalTime().Ticks $p.Path $sdkRoot $IsWindows))
    {
        throw 'Compiler not final-alive at CPU endpoint.'
    }
    return @{ identity = $Identity; startUtc = $start; userReadUtc = $userAt; kernelReadUtc = $kernelAt
        totalReadUtc = $totalAt; finalAliveUtc = [DateTime]::UtcNow; alive = $true
        userSeconds = $user; kernelSeconds = $kernel; totalSeconds = $total
        componentDifferenceSeconds = $total - $user - $kernel }
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
                $header = Get-PairedRuntimeImageHeader $bytes $IsWindows
                @{ path = $library; header = $header }
            }
            finally { $stream.Dispose() }
        }
    )
    [byte[]]$expected = $originalConfig
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
        host = Get-NativeImageIdentity $dotnet; order = @('default-A1','default-A2')
        cases = @('cold','noop') + @(1..$EditCount | ForEach-Object { "edit$_" })
        editCount = $EditCount; expectedCases = $expectedCases
        invocation = if ($LocalSmoke) { 'local-one-edit-smoke; no performance benefit claims' } else { 'hosted-fixed-twenty-edit-block' }
        timing = 'Command start-to-exit wall; Csc task elapsed sum is work wall, NEVER CPU.'
        setup = 'Clean and private-node reset excluded before each fresh default lifetime. No training/warmup builds.'
        cache = 'Filesystem/NuGet caches warm; cold means fresh compiler and cleaned outputs, not machine cold.'
        lifetime = 'Two A/A lifetimes; ordinary node reuse within lifetime. Not a statistical population or equal hardware.'
        preregisteredWindows = @{ early = @(1..5); late = @(16..20) }
        diagnostic = 'After throughput only: fresh normal-policy cold and two edits; instrumented walls excluded.'
        effectiveEnvironment = @(Get-ChildItem Env: | Where-Object Name -Match '^(DOTNET|COMPlus|CORECLR|COR_|MSBUILD)' | Select-Object Name,Value)
    } (Join-Path $ResultsDirectory 'protocol.json')
    $null = Invoke-PairedCommand @('--info') (Join-Path $ResultsDirectory 'dotnet-info')
    if ($ContinueLocalSmokeFrom)
    {
        # Discovery must not silently adopt work that appeared after the failed
        # turn. Validate against the frozen prior ownership registry first.
        $priorKeys = @($observed.Keys)
        foreach ($identity in @(Get-PrivateProcesses))
        {
            if ("$($identity.pid):$($identity.startTicks)" -notin $priorKeys)
            {
                throw 'Unknown private process appeared during local continuation; refuse cleanup.'
            }
        }
    }
    Reset-PrivateProcesses
    $checkingContinuation = $false
    foreach ($ordinal in $lifetimes)
    {
        $diagnostic = $ordinal -eq 3
        if ($diagnostic)
        {
            $timingPassed = $receipts.Count -eq $expectedCases
            Write-PairedJson @{ passed = $timingPassed; completedCases = $receipts.Count; expectedCases = $expectedCases
                cpuPassed = $cpuErrors.Count -eq 0 } (Join-Path $ResultsDirectory 'throughput-gate.json')
            if (-not $timingPassed) { throw 'Incomplete throughput; diagnostic not authorized.' }
        }
        $arm = 'default'
        $directory = Join-Path $ResultsDirectory $(if ($diagnostic) { 'diagnostic' } else { "$ordinal-default" })
        $null = New-Item -ItemType Directory -Path $directory
        Restore-PairedSource
        $null = Invoke-PairedCommand @('clean', $project, '--configuration', 'Debug', '--nologo') (Join-Path $directory 'clean')
        Reset-PrivateProcesses
        $birthAfter = [DateTime]::UtcNow.Ticks
        $server = $null
        $cases = if ($diagnostic) { @('cold','edit1','edit2') } else { @('cold','noop') + @(1..$EditCount | ForEach-Object { "edit$_" }) }
        $capture = if ($diagnostic) {
            @{
                DOTNET_EnableEventPipe = '1'
                DOTNET_EventPipeConfig = 'Microsoft-Windows-DotNETRuntime:0x3000000038:5'
                # Runtime env DWORDs are hexadecimal: 100 == 256 MiB.
                DOTNET_EventPipeCircularMB = '100'
                DOTNET_EventPipeOutputStreaming = '1'
                DOTNET_EventPipeOutputPath = (Join-Path $directory 'process-{pid}.nettrace')
            }
        } else { @{} }
        if ($diagnostic)
        {
            Write-PairedJson @{ environment = $capture; providerLevel = 5; bufferMiB = 256
                sampling = 'none'; normalPolicy = $true; throughputSamples = $false
                settings280Required = $false; jitElapsedIsNotCpu = $true } (Join-Path $directory 'capture-policy.json')
        }
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
            $cpu = @{ status = 'pending'; scope = 'ALL retained server activity including background; not Csc CPU, machine percent, or wall-minus-wait.'
                baselineKind = if ($server) { 'live endpoint' } else { 'conceptual zero at actual process creation' } }
            if (-not $diagnostic -and $server)
            {
                try { $cpu.begin = Read-PairedCpu $server }
                catch { $cpu.status = 'rejected'; $cpu.error = $_.ToString() }
            }
            $buildStart = [DateTime]::UtcNow
            $delay = if ($lastCaseEnd) { ($buildStart - $lastCaseEnd).TotalSeconds } else { $null }
            $receipt = Invoke-PairedCommand @('build', $project, '--configuration', 'Debug', '--no-restore', '--nologo', "/bl:$binlog") (Join-Path $caseDirectory 'build') $capture
            # Only two lightweight endpoints, outside the command timer. Discover
            # the actual cold server once; do not sample/poll during the build.
            if (-not $diagnostic)
            {
                try
                {
                    # The retained warm identity is already established. Read
                    # it directly, then let Get-PairedProof revalidate native
                    # discovery below; avoid a platform-dependent CIM/ps query
                    # extending every warm CPU endpoint. Cold still needs its
                    # one actual discovery, with the recorded endpoint tail.
                    $current = @(if ($server) { $server } else {
                        Get-PrivateProcesses | Where-Object kind -EQ 'compiler'
                    })
                    if ($current.Count -ne 1) { throw 'Actual compiler CPU coverage unavailable.' }
                    $cpu.end = Read-PairedCpu $current[0]
                    if ($server -and ($server.pid -ne $current[0].pid -or $server.startTicks -ne $current[0].startTicks))
                    {
                        throw 'Compiler lifetime changed during command.'
                    }
                    if (-not $server -and $current[0].startTicks -lt $receipt.startUtc.Ticks) { throw 'Cold compiler predates command.' }
                    if (-not $server)
                    {
                        $cpu.conceptualBegin = @{ actualCreationUtc = $current[0].startUtc
                            totalSeconds = 0; userSeconds = 0; kernelSeconds = 0
                            origin = 'Zero only at actual process creation; not an unsupported API fallback.' }
                    }
                    if ($cpu.status -ne 'rejected')
                    {
                        foreach ($field in @('totalSeconds','userSeconds','kernelSeconds'))
                        {
                            $cpu[$field] = $cpu.end[$field] - $(if ($server) { $cpu.begin[$field] } else { 0 })
                            if ($cpu[$field] -lt 0) { throw 'Nonmonotonic CPU endpoint.' }
                        }
                        $cpu.status = 'valid'
                    }
                }
                catch { $cpu.status = 'rejected'; $cpu.error = $_.ToString() }
                $cpu.commandBeginLeadSeconds = if ($cpu.begin) { ($receipt.startUtc - $cpu.begin.totalReadUtc).TotalSeconds } else { $null }
                $cpu.commandEndTailSeconds = if ($cpu.end) { ($cpu.end.totalReadUtc - $receipt.exitUtc).TotalSeconds } else { $null }
            }
            $lastCaseEnd = $lastBuildExit
            $null = Invoke-PairedCommand @($reader, $binlog, (Join-Path $caseDirectory 'csc.json')) (Join-Path $caseDirectory 'offline-replay')
            $data = Get-Content (Join-Path $caseDirectory 'csc.json') -Raw | ConvertFrom-Json
            $expected = if ($case -eq 'cold') { 15 } elseif ($case -eq 'noop') { 0 } else { 14 }
            if (-not $diagnostic)
            {
                if ($expected -gt 0 -and $cpu.status -eq 'valid' -and $cpu.totalSeconds -le 0)
                {
                    $cpu.status = 'rejected'; $cpu.error = 'Compiler did work but API returned no CPU advancement.'
                }
                if ($cpu.status -ne 'valid') { $cpuErrors.Add(@{ lifetime = $ordinal; case = $case; endpoint = $cpu }) }
                Write-PairedJson $cpu (Join-Path $caseDirectory 'server-cpu.json')
            }
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
            if (-not $diagnostic)
            {
                $outputs = Join-Path $caseDirectory 'outputs'
                $files = @(Get-PairedOutputFiles $RepositoryRoot)
                $manifest = @(
                    foreach ($file in $files)
                    {
                        $relative = [IO.Path]::GetRelativePath((Join-Path $RepositoryRoot 'artifacts'), $file.FullName)
                        $target = Join-Path $outputs $relative
                        $null = New-Item -ItemType Directory -Path (Split-Path $target) -Force
                        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
                        @{ path = $relative; bytes = $file.Length }
                    }
                )
                Write-PairedJson $manifest (Join-Path $caseDirectory 'output-manifest.json')
                if ($case -eq 'cold')
                {
                    Write-PairedJson @(Get-PairedEmbeddedDebug $outputs) (Join-Path $caseDirectory 'embedded-debug.json')
                }
                $commands = ConvertTo-Json -InputObject @($data.tasks |
                    Select-Object project,target,commandLine,analyzerPaths | Sort-Object project,target,commandLine) -Depth 15 -Compress
                [IO.File]::WriteAllText((Join-Path $caseDirectory 'compile-inputs.json'), $commands)
                if ($ordinal -gt 1)
                {
                    $reference = Join-Path $referenceResults ([IO.Path]::Combine('1-default', $case))
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
                    interBuildDelaySeconds = $delay; serverCpu = $cpu
                    cscCount = $data.cscCount; mainCscWallSeconds = @($main.wallSeconds)
                    cscTaskWallSumSeconds = ($data.tasks | Measure-Object wallSeconds -Sum).Sum
                    outputFiles = $manifest.Count; compiler = $server })
                Write-PairedJson @($receipts.ToArray()) (Join-Path $ResultsDirectory 'measurements.json')
            }
            else
            {
                $diagnosticCases++
                $diagnosticRequests.Add(@{ case = $case; compiler = $server; command = $receipt
                    includedInThroughput = $false })
                Write-PairedJson @($diagnosticRequests.ToArray()) (Join-Path $directory 'requests.json')
            }
        }
        Restore-PairedSource
        Reset-PrivateProcesses
        if ($diagnostic)
        {
            $trace = Join-Path $directory "process-$($server.pid).nettrace"
            $null = Invoke-PairedCommand @($traceReader, $trace, "$($server.pid)", (Join-Path $directory 'decoded'), $RepositoryRoot) `
                (Join-Path $directory 'offline-trace-replay')
            $traceProof = Get-Content (Join-Path $directory ([IO.Path]::Combine('decoded','quality.json'))) -Raw | ConvertFrom-Json
            $diagnosticPassed = $traceProof.passed -and $diagnosticCases -eq 3
            Write-PairedJson @{ passed = $diagnosticPassed; cases = $diagnosticCases
                compiler = $server; trace = $trace; gracefulFinalization = $true; quality = $traceProof } `
                (Join-Path $ResultsDirectory 'diagnostic-gate.json')
            if (-not $diagnosticPassed) { throw 'Diagnostic trace coverage/behavior gate failed.' }
        }
    }
}
catch
{
    $failure = $_.ToString()
    Write-PairedJson @{ failure = $failure; stack = $_.ScriptStackTrace } (Join-Path $ResultsDirectory 'failure.json')
    if (-not $diagnosticPassed)
    {
        Write-PairedJson @{ passed = $false; executedCases = $diagnosticCases; failure = $failure
            throughputPassed = $timingPassed; interpretation = 'Not zero diagnostic work; raw capture/decoder failure retained.' } `
            (Join-Path $ResultsDirectory 'diagnostic-gate.json')
    }
}
finally
{
    Restore-PairedSource
    try { Reset-PrivateProcesses } catch { $cleanupFailed = $true; $cleanupError = $_.ToString() }
    # Restoration must happen even if exit cannot be established; fail the gate,
    # retain diagnostics, and do not start another arm or retry.
    # No runtimeconfig or image is ever written, including restoration.
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
        completedCases = $receipts.Count; expectedCases = $expectedCases; editCount = $EditCount
        throughputPassed = $timingPassed; cpuPassed = $cpuErrors.Count -eq 0; cpuErrors = @($cpuErrors.ToArray())
        diagnosticPassed = $diagnosticPassed; diagnosticCases = $diagnosticCases
        localSmoke = $LocalSmoke.IsPresent; comparisons = @($comparisons.ToArray())
        processIdentities = @($observed.Values); confirmedExited = @($confirmedExited.Keys) }
    Write-PairedJson $state (Join-Path $ResultsDirectory 'final-state.json')
    if ($failure -or $cleanupFailed -or -not $diagnosticPassed -or $cpuErrors.Count -or $receipts.Count -ne $expectedCases -or -not $state.sourceBytesRestored -or
        -not $state.sourceTimestampRestored -or $state.sourceStatus.Count -or
        @($configChecks | Where-Object { -not $_.bytesUnchanged -or -not $_.timestampUnchanged }).Count)
    {
        throw 'Paired block failed; retain raw evidence, no automatic retry or promotion.'
    }
}
