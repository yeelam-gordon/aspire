[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RepositoryRoot,

    [Parameter(Mandatory)]
    [string]$ResultsDirectory,

    [switch]$ProfileHosting,

    [switch]$NativeHosting
)

$ErrorActionPreference = 'Stop'
if (($ProfileHosting -or $NativeHosting) -and ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted'))
{
    throw 'Compiler-server profile cleanup is restricted to the dedicated hosted experiment job.'
}
if ($NativeHosting -and ($ProfileHosting -or $env:GITHUB_REPOSITORY -ne 'yeelam-gordon/aspire' -or
    $env:GITHUB_REF -ne 'refs/heads/perf/arm64-native-compiler-profile'))
{
    throw 'Native capture requires its dedicated fork branch and cannot combine profiling modes.'
}
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
    if ($NativeHosting -and $Kind -eq 'profiled-analysis')
    {
        $process = Start-Process $dotnet -ArgumentList ($Arguments | ForEach-Object { '"' + $_ + '"' }) `
            -RedirectStandardOutput $log -RedirectStandardError "$log.stderr" -PassThru
        if (-not $process.WaitForExit(90000))
        {
            Stop-Process -Id $process.Id -Force
            $code = 124
        }
        else { $code = $process.ExitCode }
    }
    else
    {
        & $dotnet @Arguments *> $log
        $code = $LASTEXITCODE
    }
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

function Invoke-NativeTool([string]$Tool, [string[]]$ToolArguments, [switch]$AllowFailure)
{
    "> $Tool $ToolArguments" | Add-Content -LiteralPath $nativeLog
    $output = & $Tool @ToolArguments 2>&1 | Out-String
    $output | Add-Content -LiteralPath $nativeLog
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) { throw "Native tool failed ($LASTEXITCODE); inspect $nativeLog" }
    return $output
}

function Get-WprNativeQuality([string]$StopOutput, [bool]$StopSucceeded)
{
    # WPR can return success while warning:
    # "This trace has dropped 1493079 events. Please record this trace again."
    # Accept grouped counts such as "1,493,079"; missing/unrecognized output is not zero loss.
    $warning = [regex]::Match($StopOutput, '(?im)^\s*This trace has dropped (?<count>[0-9]+(?:[,.\u00a0\u202f ][0-9]{3})*) events\.\s*Please record this trace again\.\s*$')
    $reportedLoss = $null
    [long]$count = 0
    if ($warning.Success -and [long]::TryParse(($warning.Groups['count'].Value -replace '[^0-9]', ''), [ref]$count)) { $reportedLoss = $count }
    $status = if ($reportedLoss -gt 0) { 'degraded' }
    elseif (-not $StopSucceeded -or $StopOutput -notmatch 'The trace was successfully saved\.' -or
        ($StopOutput -match '(?i)dropped|events?\s+lost' -and $null -eq $reportedLoss)) { 'unknown' }
    else { 'unverified' }
    return [pscustomobject]@{
        status = $status
        reportedLostEvents = $reportedLoss
        stopSucceeded = $StopSucceeded
        message = switch ($status)
        {
            'degraded' { 'WPR final stop reported event loss; retained trace is degraded.' }
            'unknown' { 'Stop/finalization output is failed or unrecognized; quality is unknown.' }
            'unverified' { 'no loss warning reported; independent offline verification required' }
        }
        independentOfflineVerificationRequired = $true
        cpuCoverage = 'Unvalidated; independently verify compiler PID CPU samples/stacks and final stream loss.'
        collectorStatusLog = 'native-tools.log'
    }
}

function Write-NativeFailure([string]$Phase, [object]$Failure, [string]$Trace)
{
    $message = "$Phase`n$($Failure | Out-String)"
    $message | Add-Content (Join-Path $ResultsDirectory 'native-errors.log')
    Write-Host $message
    foreach ($suffix in @('.stdout.log', '.stderr.log', '.notify.stdout.log', '.notify.stderr.log'))
    {
        $path = "$Trace$suffix"
        if (Test-Path -LiteralPath $path) { Write-Host "$path`n$(Get-Content -LiteralPath $path -Raw)" }
    }
}

function Invoke-NativeHosting([string[]]$BuildArguments)
{
    $nativeLog = Join-Path $ResultsDirectory 'native-tools.log'
    $instance = "Hosting-$([guid]::NewGuid().ToString('N'))"
    $trace = Join-Path $ResultsDirectory $(if ($IsWindows) { 'Hosting.etl' } else { 'Hosting.trace' })
    $started = $false
    $captureError = $collector = $waiter = $null
    $ready = $false
    try
    {
        if ($IsWindows)
        {
            $tool = (Get-Command wpr.exe -ErrorAction Stop).Source
            $profiles = Invoke-NativeTool $tool @('-profiles')
            $help = Invoke-NativeTool $tool @('-help', 'start')
            $null = Invoke-NativeTool $tool @('-help', 'stop')
            if ($profiles -notmatch '\bCPU\b' -or $help -notmatch '-instancename') { throw 'Required WPR capabilities unavailable.' }
            if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'WPR requires an elevated hosted runner.' }
            # CPU.verbose retains sampling/scheduling stacks and CLR runtime/rundown providers
            # without the broad DotNET profile. Keep default stop-time PDB generation:
            # https://learn.microsoft.com/windows-hardware/test/wpt/wpr-command-line-options
            $null = Invoke-NativeTool $tool @('-exportprofile', 'CPU.verbose', (Join-Path $ResultsDirectory 'native-profiles.wprp'), '-filemode')
            $started = $true
            $null = Invoke-NativeTool $tool @('-start', 'CPU.verbose', '-filemode', '-recordtempto', $ResultsDirectory, '-instancename', $instance)
        }
        elseif ($IsMacOS)
        {
            $tool = (Invoke-NativeTool xcrun @('--find', 'xctrace')).Trim()
            $null = Invoke-NativeTool xcodebuild @('-version')
            $null = Invoke-NativeTool $tool @('version')
            $help = Invoke-NativeTool $tool @('help', 'record')
            $exportHelp = Invoke-NativeTool $tool @('help', 'export')
            $templates = Invoke-NativeTool $tool @('list', 'templates')
            foreach ($flag in @('--all-processes', '--time-limit', '--no-prompt', '--notify-tracing-started'))
            {
                if (-not $help.Contains($flag)) { throw "xctrace lacks $flag" }
            }
            if ($templates -notmatch 'Time Profiler' -or $exportHelp -notmatch '--toc' -or $exportHelp -notmatch '--xpath') { throw 'Required Xcode template/export capabilities unavailable.' }
            $notify = (Get-Command notifyutil -ErrorAction Stop).Source
            $notifyHelp = Invoke-NativeTool $notify @('-h')
            foreach ($flag in @('-1', '-s', '-g'))
            {
                if (-not $notifyHelp.Contains($flag)) { throw "notifyutil lacks documented $flag support." }
            }
            $notification = "com.aspire.hosting.$instance"
            # Register before launching xctrace. State 1 confirms the waiter registered;
            # notifyutil -g emits "<notification-name> 1", not a buffered recorder message.
            # https://github.com/apple-oss-distributions/Libnotify/blob/main/notifyutil/notifyutil.c
            $waiter = Start-Process $notify -ArgumentList @('-1', $notification, '-s', $notification, '1') `
                -RedirectStandardOutput "$trace.notify.stdout.log" -RedirectStandardError "$trace.notify.stderr.log" -PassThru
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            while ((Invoke-NativeTool $notify @('-g', $notification)).Trim() -ne "$notification 1")
            {
                if ($waiter.HasExited -or [DateTime]::UtcNow -gt $deadline) { throw 'Darwin notification waiter did not register.' }
                Start-Sleep -Milliseconds 100
            }
            # All-processes, not --launch: VBCSCompiler is a child/server, not the build launcher.
            # Run as the compiler's user. Unsupported headless permissions fail; never use sudo
            # or change security settings. xctrace(1) documents --notify-tracing-started.
            "> $tool record --template 'Time Profiler' --all-processes --no-prompt --time-limit 120s --notify-tracing-started $notification --output $trace" | Add-Content $nativeLog
            $collector = Start-Process $tool -ArgumentList @('record', '--template', '"Time Profiler"', '--all-processes', '--no-prompt', '--time-limit', '120s', '--notify-tracing-started', $notification, '--output', "`"$trace`"") `
                -RedirectStandardOutput "$trace.stdout.log" -RedirectStandardError "$trace.stderr.log" -PassThru
            "Owned xctrace PID=$($collector.Id); notifyutil PID=$($waiter.Id)" | Add-Content $nativeLog
        }
        else { throw 'Native capture supports only Windows and macOS.' }
        $started = $true
        if ($IsMacOS)
        {
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while (-not $waiter.WaitForExit(250))
            {
                if ($collector.HasExited -or [DateTime]::UtcNow -gt $deadline) { throw 'xctrace did not send its readiness notification; inspect collector permissions/errors.' }
            }
            if ($waiter.ExitCode -ne 0 -or $collector.HasExited) { throw 'xctrace readiness notification failed or collector exited.' }
            $ready = $true
            "Received xctrace readiness notification: $notification" | Add-Content $nativeLog
        }
        Invoke-DotnetCase 'Hosting' 'native-cold-build' 'profiled-analysis' $BuildArguments
        if ($IsMacOS -and $collector.HasExited) { throw 'xctrace exited before the build completed; coverage is incomplete.' }
        # Match private SDK apphosts (.../VBCSCompiler[.exe] -pipename:...) as well as
        # dotnet exec ".../VBCSCompiler.dll" -pipename:...; export identities, not arguments.
        $compilerPathPattern = '(?:^|[\s"])' + [regex]::Escape($dotnetRoot.TrimEnd([char[]]'\/')) +
            '[\\/](?:[^"\s]+[\\/])*VBCSCompiler(?:\.exe|\.dll)?(?=["\s]|$)'
        $compilers = if ($IsWindows)
        {
            Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -match $compilerPathPattern -or $_.CommandLine -match $compilerPathPattern } |
                Select-Object ProcessId, ParentProcessId, Name
        }
        else
        {
            & ps -axo 'pid=,ppid=,comm=,args=' | Where-Object { $_ -match $compilerPathPattern } |
                ForEach-Object { $fields = $_.Trim() -split '\s+', 3; [pscustomobject]@{ ProcessId = $fields[0]; ParentProcessId = $fields[1]; Name = 'VBCSCompiler' } }
        }
        @($compilers) | ConvertTo-Json | Set-Content (Join-Path $ResultsDirectory 'native-compiler-processes.json')
        if (-not $compilers) { throw 'No private-SDK VBCSCompiler child identified; do not infer launcher-only coverage.' }
    }
    catch
    {
        $captureError = $_
        Write-NativeFailure 'Primary native capture error (before finalization)' $_ $trace
        throw
    }
    finally
    {
        if ($started -and $IsWindows)
        {
            try { $null = Invoke-NativeTool $tool @('-status', 'collectors', '-details', '-instancename', $instance) }
            finally
            {
                $stopOutput = ''
                $stopSucceeded = $false
                try
                {
                    $stopOutput = Invoke-NativeTool $tool @('-stop', $trace, 'Cold Hosting managed build', '-instancename', $instance) -AllowFailure
                    $stopSucceeded = $LASTEXITCODE -eq 0
                }
                finally
                {
                    $quality = Get-WprNativeQuality $stopOutput $stopSucceeded
                    $quality | ConvertTo-Json | Set-Content (Join-Path $ResultsDirectory 'native-quality.json')
                }
                if ($quality.status -ne 'unverified') { throw "Native capture quality is $($quality.status); inspect native-quality.json and retained ETL/logs." }
            }
            if ((Get-Item $trace).Length -lt 1024) { throw 'No usable-sized native ETL captured.' }
        }
        elseif ($IsMacOS -and ($collector -or $waiter))
        {
            $finalized = $exported = $false
            try
            {
                # Signal the actual owned xctrace PID immediately, including when never ready.
                if ($collector -and -not $collector.HasExited)
                {
                    $null = Invoke-NativeTool /bin/kill @('-INT', "$($collector.Id)")
                    if (-not $collector.WaitForExit(30000))
                    {
                        Stop-Process -Id $collector.Id -Force
                        throw 'Owned xctrace did not finalize after SIGINT; partial trace is invalid.'
                    }
                }
                if ($collector -and $collector.ExitCode -ne 0) { throw 'Owned xctrace failed; partial trace is invalid.' }
                $finalized = $null -ne $collector
                if ($ready -and -not $captureError)
                {
                    $tocPath = Join-Path $ResultsDirectory 'native-toc.xml'
                    $null = Invoke-NativeTool $tool @('export', '--input', $trace, '--toc', '--output', $tocPath)
                    # Use only the documented xctrace(1) export schema, if present in this trace's TOC:
                    # https://keith.github.io/xcode-man-pages/xctrace.1.html (--xpath example).
                    $tables = @(([xml](Get-Content $tocPath -Raw)).SelectNodes('//table[@schema]') |
                        Where-Object { $_.schema -eq 'time-profile' } |
                        ForEach-Object { $_.schema } | Sort-Object -Unique)
                    if (-not $tables) { throw 'No recognized CPU table in TOC; raw Mac trace requires compatible Xcode.' }
                    foreach ($schema in $tables)
                    {
                        $null = Invoke-NativeTool $tool @('export', '--input', $trace, '--xpath', "//table[@schema='$schema']", '--output', (Join-Path $ResultsDirectory "native-$schema.xml"))
                        if (-not ([xml](Get-Content (Join-Path $ResultsDirectory "native-$schema.xml") -Raw)).SelectNodes('//row').Count) { throw "Exported CPU table $schema has no rows." }
                    }
                    $exported = $true
                }
            }
            catch
            {
                Write-NativeFailure 'Native finalization/cleanup error' $_ $trace
                if (-not $captureError) { throw }
            }
            finally
            {
                @{
                    status = if ($exported) { 'unverified' } else { 'partial-invalid' }
                    readinessReceived = $ready
                    collectorFinalized = $finalized
                    cpuCoverage = 'Unvalidated; independently verify compiler PID CPU samples/stacks, symbols and trace completeness.'
                } | ConvertTo-Json | Set-Content (Join-Path $ResultsDirectory 'native-quality.json')
                if ($waiter -and -not $waiter.HasExited)
                {
                    try { Stop-Process -Id $waiter.Id -Force }
                    catch
                    {
                        Write-NativeFailure 'Native notification-waiter cleanup error' $_ $trace
                        if (-not $captureError) { throw }
                    }
                }
            }
        }
    }
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
    scope = if ($NativeHosting) { 'Diagnostic cold Hosting CPU capture, ReportAnalyzer retained; WPR CPU/scheduling, Mac Time Profiler CPU samples, not managed thread-time TopN or throughput. Mac recording is bounded at 120s; correlate compiler PID and build UTC interval. Mac JIT symbols and wait/scheduling attribution are not guaranteed.' } elseif ($ProfileHosting) { 'Diagnostic cold Hosting build with ReportAnalyzer and managed thread/GC tracing; elapsed time is not a throughput baseline.' } else { 'Debug managed project builds with normal defaults; no publish/pack or AOT toggles. Restore/clean are setup, not build-only latency.' }
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
        if (($ProfileHosting -or $NativeHosting) -and $item.name -ne 'Hosting') { continue }
        $project = Join-Path $RepositoryRoot $item.project
        Invoke-DotnetCase $item.name 'restore' 'setup' @('restore', $project, '-p:Configuration=Debug', '--nologo')
        Invoke-DotnetCase $item.name 'clean' 'setup' @('clean', $project, '--configuration', 'Debug', '--nologo')
        $build = @('build', $project, '--configuration', 'Debug', '--no-restore', '--nologo')
        if ($ProfileHosting -or $NativeHosting)
        {
            # This job owns its SDK servers. Start cold and stop gracefully after
            # capture so persistent compiler/server traces are finalized before upload.
            & $dotnet build-server shutdown --msbuild --vbcscompiler *> (Join-Path $ResultsDirectory 'servers-before.log')
            if ($LASTEXITCODE -ne 0) { throw 'Could not establish a cold compiler-server profile.' }
            if ($NativeHosting)
            {
                $nativeError = $null
                try { Invoke-NativeHosting ($build + @('/p:ReportAnalyzer=true', "/bl:$(Join-Path $ResultsDirectory 'Hosting-native-cold-build.binlog')")) }
                catch { $nativeError = $_; $_ | Out-String | Add-Content (Join-Path $ResultsDirectory 'native-tools.log'); throw }
                finally
                {
                    try
                    {
                        & $dotnet build-server shutdown --msbuild --vbcscompiler *> (Join-Path $ResultsDirectory 'servers-after.log')
                        if ($LASTEXITCODE -ne 0) { throw 'Native profile compiler-server cleanup failed.' }
                    }
                    catch
                    {
                        Write-NativeFailure 'Native SDK-server cleanup error' $_ (Join-Path $ResultsDirectory 'Hosting.trace')
                        if (-not $nativeError) { throw }
                    }
                }
                continue
            }
            $env:DOTNET_EnableEventPipe = '1'
            $env:DOTNET_EventPipeOutputPath = Join-Path $ResultsDirectory 'compiler-{pid}.nettrace'
            $env:DOTNET_EventPipeOutputStreaming = '1'
            $env:DOTNET_EventPipeCircularMB = '10'
            # Omit network payloads; sample-profiler stacks include waits, not
            # just CPU work. This does not capture native/kernel or Defender events.
            $env:DOTNET_EventPipeConfig = 'Microsoft-DotNETCore-SampleProfiler:0:5,Microsoft-Windows-DotNETRuntime:1:4'
            try
            {
                Invoke-DotnetCase $item.name 'profiled-cold-build' 'profiled-analysis' ($build + @('/p:ReportAnalyzer=true', "/bl:$(Join-Path $ResultsDirectory 'Hosting-profiled-cold-build.binlog')"))
            }
            finally
            {
                Remove-Item Env:DOTNET_EnableEventPipe
                & $dotnet build-server shutdown --msbuild --vbcscompiler *> (Join-Path $ResultsDirectory 'servers-after.log')
                if ($LASTEXITCODE -ne 0) { throw 'Compiler-server trace finalization failed.' }
            }
            $traces = @(Get-ChildItem -LiteralPath $ResultsDirectory -Filter '*.nettrace' -File)
            $traces | Select-Object Name, Length | ConvertTo-Json |
                Set-Content -LiteralPath (Join-Path $ResultsDirectory 'trace-inventory.json')
            if (@($traces | Where-Object Length -gt 1024).Count -eq 0) { throw 'No usable-sized compiler traces were captured.' }
            continue
        }
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
