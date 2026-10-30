param([string] $CompletedBaselineWarmup)
. (Join-Path $PSScriptRoot 'Common-P38.ps1')
$directory = Join-Path $evidence 'block-1'
if (Test-Path $directory)
{
    throw 'One block only; refusing to overwrite or retry.'
}
$inherited = @(Get-ChildItem Env: | Where-Object Name -Match '^(DOTNET|COMPlus|CORECLR|COR_|MSBUILD)' |
    Select-Object Name,Value)
# Reject, rather than silently normalizing, inherited runtime/JIT/build tuning.
# DOTNET_ROOT and PATH are then scoped solely to this independent SDK copy.
if (@($inherited | Where-Object Name -NotIn @('DOTNET_ROOT', 'MSBUILDTERMINALLOGGER')).Count)
{
    Write-Json $inherited (Join-Path $evidence 'rejected-environment.json')
    throw 'Inherited tuning requires investigation before measurement.'
}
$env:DOTNET_ROOT = $private
$env:PATH = "$private;$env:PATH"
$env:MSBUILDTERMINALLOGGER = 'false'
$sourceCommit = (& git -C $work rev-parse HEAD).Trim()
if ($sourceCommit -ne '06efc928e31486923754398007f4f78003e04ee3' -or
    @(& git -C $work status --porcelain --untracked-files=no).Count -or
    @(Get-OwnedCompilers).Count)
{
    throw 'Unexpected source state or compiler already active in owned SDK.'
}
$null = New-Item -ItemType Directory $directory
$originalSource = [IO.File]::ReadAllBytes($sourceFile)
$sourceTime = [IO.File]::GetLastWriteTimeUtc($sourceFile)
$originalConfig = [IO.File]::ReadAllBytes($config)
$configTime = [IO.File]::GetLastWriteTimeUtc($config)
[IO.File]::WriteAllBytes((Join-Path $directory 'original-source.bin'), $originalSource)
[IO.File]::WriteAllBytes((Join-Path $directory 'baseline.runtimeconfig.json'), $originalConfig)
$baseline = [Text.Encoding]::UTF8.GetString($originalConfig) | ConvertFrom-Json -AsHashtable
foreach ($key in @('System.Runtime.TieredPGO', 'System.Runtime.TieredCompilation',
    'System.Runtime.TieredCompilation.QuickJit', 'System.Runtime.TieredCompilation.QuickJitForLoops',
    'System.Runtime.ReadyToRun'))
{
    if ($baseline.runtimeOptions.configProperties.ContainsKey($key))
    {
        throw "Unexpected original runtime policy: $key"
    }
}
$candidate = [Text.Encoding]::UTF8.GetString($originalConfig) | ConvertFrom-Json -AsHashtable
$candidate.runtimeOptions.configProperties['System.Runtime.TieredPGO'] = $false
$candidateConfig = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $candidate -Depth 15))
[IO.File]::WriteAllBytes((Join-Path $directory 'candidate.runtimeconfig.json'), $candidateConfig)
# Structural equality after removing the single proposed boolean is the gate;
# formatting is not a second runtime change.
$check = [Text.Encoding]::UTF8.GetString($candidateConfig) | ConvertFrom-Json -AsHashtable
$null = $check.runtimeOptions.configProperties.Remove('System.Runtime.TieredPGO')
if ((ConvertTo-Json $check -Depth 15 -Compress) -cne (ConvertTo-Json $baseline -Depth 15 -Compress))
{
    throw 'Candidate changes more than the PGO property.'
}
$results = @()
$cleanup = @()
$failure = $null

function Set-Arm([string] $Arm)
{
    if (@(Get-OwnedCompilers).Count)
    {
        throw 'Compiler must exit before config replacement.'
    }
    [IO.File]::WriteAllBytes($config, $(if ($Arm -eq 'baseline') { $originalConfig } else { $candidateConfig }))
    [IO.File]::SetLastWriteTimeUtc($config, $configTime)
}

function Restore-Source
{
    [IO.File]::WriteAllBytes($sourceFile, $originalSource)
    [IO.File]::SetLastWriteTimeUtc($sourceFile, $sourceTime)
}

function Get-CompilerProof([string] $Arm, [int] $Index)
{
    $servers = @(Get-OwnedCompilers)
    if ($servers.Count -ne 1)
    {
        throw "Expected one private compiler, got $($servers.Count)"
    }
    $server = $servers[0]
    $process = Get-Process -Id $server.pid
    $modules = @($process.Modules | Where-Object ModuleName -In @('coreclr.dll', 'clrjit.dll', 'hostpolicy.dll') |
        ForEach-Object { @{ path = $_.FileName; machine = Get-Machine $_.FileName } })
    if ((Get-Machine $server.path) -ne 'AA64' -or $modules.Count -ne 3 -or
        @($modules | Where-Object { $_.machine -ne 'AA64' -or -not $_.path.StartsWith("$private\", [StringComparison]::OrdinalIgnoreCase) }).Count)
    {
        throw 'Compiler/runtime native ARM64 ownership failed.'
    }
    $actual = [IO.File]::ReadAllBytes($config)
    [byte[]] $expected = if ($Arm -eq 'baseline') { $originalConfig } else { $candidateConfig }
    if (-not [Linq.Enumerable]::SequenceEqual[byte]($actual, $expected))
    {
        throw 'Actual compiler runtimeconfig changed.'
    }
    return @{ index = $Index; arm = $Arm; identity = $server; modules = $modules
        runtimeconfig = $config; configProperties = (Get-Content $config -Raw | ConvertFrom-Json).runtimeOptions.configProperties }
}

try
{
    Write-Json @{
        source = $sourceCommit; sourceTimestamp = $sourceTime; configTimestamp = $configTime
        inheritedEnvironment = $inherited
        effectiveEnvironment = @(Get-ChildItem Env: | Where-Object Name -Match 'DOTNET|COMPlus|MSBUILD|CORECLR|COR_' |
            Select-Object Name,Value)
        order = @('baseline','candidate','candidate','baseline')
        warmup = 'One untimed clean/build per mode, baseline then candidate; stop each compiler.'
        completedBaselineWarmup = $CompletedBaselineWarmup
        cache = 'Fresh private SDK path, repository restore completed. Machine/filesystem/NuGet/analyzer caches NOT cold. Normal MSBuild worker reuse retained and recorded.'
        timing = 'Only ordinary dotnet build start-to-exit. Offline replay, identity queries and output copies occur after each command, never concurrently.'
        preexistingWorkers = @(Get-Workers)
        hardware = @(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors)
        osArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        powershellArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
        promotion = 'At least 5% cold OR mature edits(3..5) with both candidates faster than both baselines; no comparable opposite-case regression; overlapping/order-sensitive tradeoffs reject.'
    } "$directory\protocol.json"
    $null = Invoke-BuildCommand @('--info') "$directory\dotnet-info"
    $native = foreach ($path in @($dotnet, (Join-Path $sdk 'MSBuild.exe'), (Join-Path $sdk 'Roslyn\bincore\VBCSCompiler.exe'),
        (Join-Path $private 'shared\Microsoft.NETCore.App\11.0.0-rc.2.26504.105\coreclr.dll')))
    {
        @{ path = $path; machine = Get-Machine $path }
    }
    Write-Json @($native) "$directory\native-preflight.json"
    if (@($native | Where-Object machine -NE 'AA64').Count)
    {
        throw 'Non-native SDK.'
    }
    foreach ($arm in @('baseline', 'candidate'))
    {
        $warm = Join-Path $directory "untimed-$arm"
        if ($arm -eq 'baseline' -and $CompletedBaselineWarmup)
        {
            # A prior untimed build succeeded before a post-build PowerShell
            # byte-array binding failure. Reuse it, NEVER run a second warmup.
            $receipt = Get-Content "$CompletedBaselineWarmup\build.result.json" -Raw | ConvertFrom-Json
            $coverage = Get-Content "$CompletedBaselineWarmup\csc.json" -Raw | ConvertFrom-Json
            if ($receipt.exitCode -ne 0 -or -not $coverage.successful -or $coverage.cscCount -ne 15 -or $coverage.diagnostics.Count)
            {
                throw 'Cannot reuse unsuccessful untimed preparation.'
            }
            Copy-Item -LiteralPath $CompletedBaselineWarmup -Destination $warm -Recurse
            continue
        }
        $null = New-Item -ItemType Directory $warm
        Set-Arm $arm
        $null = Invoke-BuildCommand @('clean','src\Aspire.Hosting\Aspire.Hosting.csproj','--configuration','Debug','--nologo') "$warm\clean"
        $null = Invoke-BuildCommand @('build','src\Aspire.Hosting\Aspire.Hosting.csproj','--configuration','Debug','--no-restore','--nologo',"/bl:$warm\build.binlog") "$warm\build"
        Read-Binlog "$warm\build.binlog" "$warm\csc.json"
        Write-Json (Get-CompilerProof $arm 0) "$warm\compiler.json"
        $cleanup += @(Stop-OwnedCompilers)
    }
    $index = 0
    foreach ($arm in @('baseline','candidate','candidate','baseline'))
    {
        $index++
        $armDirectory = Join-Path $directory "$index-$arm"
        $null = New-Item -ItemType Directory $armDirectory
        Restore-Source
        # Restore original bytes between modes, including candidate-to-candidate.
        Set-Arm baseline
        Set-Arm $arm
        $null = Invoke-BuildCommand @('clean','src\Aspire.Hosting\Aspire.Hosting.csproj','--configuration','Debug','--nologo') "$armDirectory\clean"
        Write-Json @(Get-Workers) "$armDirectory\workers-before.json"
        $birthAfter = [DateTime]::UtcNow.Ticks
        $armServer = $null
        foreach ($case in @('cold','noop','edit1','edit2','edit3','edit4','edit5'))
        {
            if ($case.StartsWith('edit'))
            {
                # Identical bytes for each corresponding edit across all four arms.
                $comment = [Text.Encoding]::UTF8.GetBytes("`r`n// P38 identical owned edit $($case.Substring(4)); restored byte-for-byte.`r`n")
                [IO.File]::WriteAllBytes($sourceFile, [byte[]]($originalSource + $comment))
            }
            $caseDirectory = Join-Path $armDirectory $case
            $null = New-Item -ItemType Directory $caseDirectory
            $result = Invoke-BuildCommand @('build','src\Aspire.Hosting\Aspire.Hosting.csproj',
                '--configuration','Debug','--no-restore','--nologo',"/bl:$caseDirectory\build.binlog") "$caseDirectory\build"
            Read-Binlog "$caseDirectory\build.binlog" "$caseDirectory\csc.json"
            $data = Get-Content "$caseDirectory\csc.json" -Raw | ConvertFrom-Json
            $expected = if ($case -eq 'cold') { 15 } elseif ($case -eq 'noop') { 0 } else { 14 }
            if (-not $data.successful -or $data.unfinishedCscCount -or $data.cscCount -ne $expected -or $data.diagnostics.Count)
            {
                throw "Work/diagnostics gate failed in $index/$case"
            }
            foreach ($task in $data.tasks)
            {
                if (-not $task.succeeded -or @($task.compilerServerMessages | Where-Object { $_ -match 'server - server processed compilation' }).Count -ne 1)
                {
                    throw "Compilation server gate failed in $index/$case"
                }
            }
            $main = @($data.tasks | Where-Object { $_.target -eq 'CoreCompile' -and $_.project -like '*\Aspire.Hosting.csproj' })
            if ($case -ne 'noop' -and ($main.Count -ne 1 -or $main[0].analyzerPaths.Count -ne 26))
            {
                throw 'Main compile quality scope changed.'
            }
            $proof = Get-CompilerProof $arm $index
            if ($proof.identity.startTicks -lt $birthAfter -or
                ($armServer -and ($proof.identity.pid -ne $armServer.pid -or $proof.identity.startTicks -ne $armServer.startTicks)))
            {
                throw 'Compiler was not fresh per arm / stable within arm.'
            }
            $armServer = $proof.identity
            Write-Json $proof "$caseDirectory\compiler.json"
            Snapshot-Outputs "$caseDirectory\outputs"
            $record = [pscustomobject] @{
                index = $index; arm = $arm; case = $case; wallSeconds = $result.wallSeconds
                mainCscSeconds = if ($main.Count) { $main[0].wallSeconds } else { 0 }
                cscWorkSeconds = [double](($data.tasks | Measure-Object wallSeconds -Sum).Sum)
                cscCount = $data.cscCount; diagnostics = $data.diagnostics.Count
                analyzerItems = if ($main.Count) { $main[0].analyzerPaths.Count } else { 0 }
                compilerPid = $proof.identity.pid; compilerStartTicks = $proof.identity.startTicks
                directory = $caseDirectory
            }
            $results += $record
            Write-Json $results "$directory\results.json"
            $record | ConvertTo-Json -Compress
        }
        Restore-Source
        $cleanup += @(Stop-OwnedCompilers)
    }
}
catch
{
    $failure = $_.ToString()
    Write-Json @{ failure = $failure; details = $_.ScriptStackTrace } "$directory\failure.json"
    throw
}
finally
{
    Restore-Source
    $cleanup += @(Stop-OwnedCompilers)
    [IO.File]::WriteAllBytes($config, $originalConfig)
    [IO.File]::SetLastWriteTimeUtc($config, $configTime)
    # Only nodes under this independently created SDK are ours. Never shut down
    # or kill workers belonging to any other SDK/worktree.
    foreach ($worker in @(Get-Workers | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath.StartsWith("$private\", [StringComparison]::OrdinalIgnoreCase) -and $_.CommandLine -match '/nodemode:'
    }))
    {
        $process = Get-Process -Id $worker.ProcessId -ErrorAction SilentlyContinue
        if ($process)
        {
            $cleanup += Stop-Exact @{ pid = $process.Id; startTicks = $process.StartTime.ToUniversalTime().Ticks
                path = $process.Path; commandLine = $worker.CommandLine }
        }
    }
    Write-Json $cleanup "$directory\cleanup.json"
    Write-Json @{
        sourceBytesRestored = [Linq.Enumerable]::SequenceEqual[byte]($originalSource,[IO.File]::ReadAllBytes($sourceFile))
        sourceTimestampRestored = [IO.File]::GetLastWriteTimeUtc($sourceFile) -eq $sourceTime
        configBytesRestored = [Linq.Enumerable]::SequenceEqual[byte]($originalConfig,[IO.File]::ReadAllBytes($config))
        configTimestampRestored = [IO.File]::GetLastWriteTimeUtc($config) -eq $configTime
        sourceHead = (& git -C $work rev-parse HEAD).Trim()
        sourceStatus = @(& git -C $work status --porcelain)
        remainingOwnedCompilers = @(Get-OwnedCompilers)
        remainingWorkers = @(Get-Workers)
        failure = $failure
    } "$directory\final-state.json"
}
