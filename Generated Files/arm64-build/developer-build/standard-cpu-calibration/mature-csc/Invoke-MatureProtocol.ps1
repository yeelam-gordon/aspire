[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter(Mandatory)][string]$SdkRoot,
    [Parameter(Mandatory)][string]$ResultsDirectory,
    [Parameter(Mandatory)][string]$ToolsDirectory,
    [switch]$HostedCapture
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Guard.ps1')
if ($HostedCapture) { $null=Assert-MatureContext }
. (Join-Path $PSScriptRoot 'Failure.ps1')
# P46's fixed ordinary-workload orchestrator, with its same P44 identity,
# command and exact-pipe/parent/absence cleanup implementation. No probe or
# ReportAnalyzer path is carried forward.
$paired=Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'compiler-warmup-paired'
. (Join-Path $paired 'Paired-Helpers.ps1')
. (Join-Path $paired 'Paired-Cleanup.ps1')
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $paired 'Measure-PairedWarmup.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Retained P44 source cannot be parsed.' }
$selected=@('Get-PrivateProcesses','Get-ExitDiagnostic','Invoke-PairedCommand','Restore-PairedSource','Read-PairedCpu','Get-PairedProof')
foreach($name in $selected)
{
    $nodes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
    if ($nodes.Count -ne 1) { throw "Ambiguous retained P44 function: $name" }
    . ([scriptblock]::Create($nodes[0].Extent.Text))
}
if ((& git -C $RepositoryRoot rev-parse HEAD).Trim() -cne '06efc928e31486923754398007f4f78003e04ee3' -or
    @(& git -C $RepositoryRoot status --porcelain).Count) { throw 'Exact clean product source required.' }
if (-not $IsWindows -or [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() -cne 'Arm64')
{ throw 'Native Windows ARM64 observer required.' }
if (Test-Path $ResultsDirectory) { throw 'Refusing protocol evidence overwrite.' }
$null=New-Item -ItemType Directory -Path $ResultsDirectory
Copy-Item (Join-Path $PSScriptRoot 'granularity-plan.json') (Join-Path $ResultsDirectory 'granularity-plan.json')
$JobStartUtc=[DateTime]::UtcNow
$sdkRoot=[IO.Path]::GetFullPath($SdkRoot)
$dotnet=Join-Path $sdkRoot 'dotnet.exe'
$config=Join-Path $sdkRoot 'sdk\11.0.100-rc.2.26504.105\Roslyn\bincore\VBCSCompiler.runtimeconfig.json'
$originalConfig=[IO.File]::ReadAllBytes($config)
Assert-PairedNormalPolicy $originalConfig
$sourceFile=Join-Path $RepositoryRoot 'src\Aspire.Hosting\DistributedApplication.cs'
$originalSource=[IO.File]::ReadAllBytes($sourceFile)
$sourceTime=[IO.File]::GetLastWriteTimeUtc($sourceFile)
$project='src\Aspire.Hosting\Aspire.Hosting.csproj'
$observed=@{}; $confirmedExited=@{}; $cleanupByKey=@{}; $shutdownRequests=@{}; $stopRequests=@{}
$nativeBirths=@{}; $ownedParentProofs=@{}; $checkingContinuation=$false
$cleanup=[Collections.Generic.List[object]]::new()
$cleanupPlans=[Collections.Generic.List[object]]::new()
$commands=[Collections.Generic.List[object]]::new()
$cases=[Collections.Generic.List[object]]::new()
$script:resetInProgress=$false
$script:serverKey=$null
$failure=$null; $cleanupFailure=$null; $snapshotPassed=$false; $configs=@()
$errorState=@{primary=$null;primaryPhase=$null;secondary=[Collections.Generic.List[object]]::new()
    reportingErrors=[Collections.Generic.List[object]]::new();records=[Collections.Generic.List[string]]::new()
    directory=(Join-Path $ResultsDirectory 'errors');phase='native-owner-preflight'}

function Register-ProtocolFailure([Management.Automation.ErrorRecord]$Record,[string]$Kind)
{
    $paths=@('protocol.json','commands.json','cases.json','cleanup.json','final-state.json',
        'target\build.result.json','target\compiler.json','capture\session-before.json',
        'capture\session-start.json','capture\start.receipt.json','capture\session-final.json','capture\stop.receipt.json')|
        ForEach-Object{Join-Path $ResultsDirectory $_}
    Register-MatureFailure $errorState $Record $errorState.phase $Kind $paths
}

function Save-MatureOutputs([string]$Destination)
{
    $files=@(Get-PairedOutputFiles $RepositoryRoot)
    $manifest=@(foreach($file in $files)
    {
        $relative=[IO.Path]::GetRelativePath((Join-Path $RepositoryRoot 'artifacts'),$file.FullName)
        $target=Join-Path $Destination $relative
        $null=[IO.Directory]::CreateDirectory((Split-Path $target))
        [IO.File]::Copy($file.FullName,$target,$false)
        @{relativePath=$relative;bytes=$file.Length}
    })
    Write-PairedJson $manifest (Join-Path $Destination 'manifest.json')
}

function Invoke-MatureBuild([string]$Name)
{
    $directory=Join-Path $ResultsDirectory $Name
    $null=New-Item -ItemType Directory -Path $directory
    [IO.File]::WriteAllBytes((Join-Path $directory 'source-input.bin'),[IO.File]::ReadAllBytes($sourceFile))
    Write-PairedJson @{path=$sourceFile;mtimeUtc=[IO.File]::GetLastWriteTimeUtc($sourceFile)} (Join-Path $directory 'source-input.json')
    $before=if($script:serverKey){Read-PairedCpu $observed[$script:serverKey]}else{$null}
    $arguments=@('build',$project,'--configuration','Debug','--no-restore','--nologo','--verbosity','normal',"/bl:$(Join-Path $directory 'build.binlog')")
    $receipt=Invoke-PairedCommand $arguments (Join-Path $directory 'build')
    $commands.Add($receipt)
    $proof=Get-PairedProof 'default'
    $key="$($proof.identity.pid):$($proof.identity.startTicks)"
    if ($script:serverKey -and $script:serverKey -cne $key) { throw 'Default compiler lifetime changed.' }
    if (@($proof.runtime|Where-Object{-not $_.header.arm64}).Count -or
        @($proof.runtime|Where-Object{$_.path -match 'shared\\Microsoft.NETCore.App\\11.0.0-rc.2.26504.105\\coreclr.dll$'}).Count -ne 1)
    { throw 'Actual native private CLR11 compiler identity failed.' }
    $script:serverKey=$key
    $after=Read-PairedCpu $proof.identity
    Write-PairedJson $proof (Join-Path $directory 'compiler.json')
    $case=@{name=$Name;command=$receipt;compilerIdentity=$proof.identity;cpuBefore=$before;cpuAfter=$after
        cpuDeltaSeconds=if($before){$after.totalSeconds-$before.totalSeconds}else{$null}
        cpuMeaning='Whole private server delta over command endpoints, includes background; not request-exclusive Csc work.'}
    $cases.Add($case)
    Write-PairedJson @($cases.ToArray()) (Join-Path $ResultsDirectory 'cases.json')
    Write-Output "Completed $Name"
}

function Read-MatureBuild([string]$Name)
{
    $directory=Join-Path $ResultsDirectory $Name
    $commands.Add((Invoke-PairedCommand @((Join-Path $ToolsDirectory 'BinlogReader.dll'),
        (Join-Path $directory 'build.binlog'),(Join-Path $directory 'csc.json')) (Join-Path $directory 'replay')))
    $data=Get-Content (Join-Path $directory 'csc.json') -Raw|ConvertFrom-Json
    $main=@($data.tasks|Where-Object{$_.project.EndsWith('\Aspire.Hosting.csproj') -and $_.target -eq 'CoreCompile'})
    if (-not $data.successful -or $data.unfinishedCscCount -ne 0 -or
        ($Name -eq 'noop' -and $data.cscCount -ne 0) -or ($Name -ne 'noop' -and $main.Count -ne 1))
    { throw "Actual Csc work gate failed: $Name" }
    if($main.Count)
    {
        if($main[0].analyzerPaths.Count -ne 26 -or $main[0].commandLine -match '/reportanalyzer|enable-generator-cache' -or
            -not @($main[0].compilerServerMessages|Where-Object{$_ -match 'server processed compilation'}).Count)
        { throw "Normal analyzer/server/command policy failed: $Name" }
        $case=@($cases|Where-Object name -eq $Name)[0]
        if(([DateTime]$main[0].startedUtc) -lt ([DateTime]$case.command.startUtc) -or
            ([DateTime]$main[0].finishedUtc) -gt ([DateTime]$case.command.exitUtc))
        { throw "Binlog main-Csc UTC window falls outside its actual command: $Name" }
    }
}

try
{
    $native=@(Get-CimInstance Win32_Process|Where-Object{$_.Name -match '^(dotnet|VBCSCompiler|MSBuild)(\.exe)?$'})
    if(@($native|Where-Object{Test-PrivateSdkPath $_.ExecutablePath $sdkRoot $true}).Count -or (-not $HostedCapture -and $native.Count))
    { throw 'Preexisting SDK/build owner; no process adopted or stopped.' }
    $errorState.phase='environment-source-sdk-snapshot'
    $envs=@(Get-ChildItem Env:|Where-Object Name -Match '^(DOTNET|COMPlus|CORECLR|COR_|MSBUILD)'|Select-Object Name,Value)
    $allowed=@('DOTNET_ROOT','DOTNET_ROOT_X64','DOTNET_ROOT_ARM64','DOTNET_MULTILEVEL_LOOKUP','DOTNET_NOLOGO',
        'DOTNET_CLI_TELEMETRY_OPTOUT','DOTNET_SKIP_FIRST_TIME_EXPERIENCE','DOTNET_GENERATE_ASPNET_CERTIFICATE',
        'DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE','MSBUILDTERMINALLOGGER')
    if(@($envs|Where-Object Name -NotIn $allowed).Count){throw 'Inherited policy/instrumentation override.'}
    Write-PairedJson $envs (Join-Path $ResultsDirectory 'inherited-environment.json')
    $immutable=@(Get-ChildItem $sdkRoot -Recurse -Filter '*.runtimeconfig.json' -File
        Get-ChildItem (Split-Path $config) -File
        Get-Item $dotnet
        foreach($pattern in @('coreclr.dll','clrjit.dll','hostpolicy.dll')){Get-ChildItem (Join-Path $sdkRoot 'shared') -Recurse -Filter $pattern -File})|Sort-Object FullName -Unique
    $configs=@($immutable|ForEach-Object{@{path=$_.FullName;bytes=[IO.File]::ReadAllBytes($_.FullName);time=$_.LastWriteTimeUtc}})
    foreach($entry in $configs)
    {
        $backup=Join-Path $ResultsDirectory ("sdk-before\"+[IO.Path]::GetRelativePath($sdkRoot,$entry.path))
        $null=[IO.Directory]::CreateDirectory((Split-Path $backup))
        [IO.File]::WriteAllBytes($backup,$entry.bytes)
    }
    Write-PairedJson @($configs|ForEach-Object{@{path=$_.path;bytes=$_.bytes.Length;timestampUtc=$_.time}}) (Join-Path $ResultsDirectory 'immutable-inputs.json')
    [IO.File]::WriteAllBytes((Join-Path $ResultsDirectory 'original-source.bin'),$originalSource)
    $snapshotPassed=$true
    $env:DOTNET_ROOT=$sdkRoot; $env:PATH="$sdkRoot;$env:PATH"; $env:MSBUILDTERMINALLOGGER='false'
    $workspace=Join-Path $ResultsDirectory 'process-work'
    $null=New-Item -ItemType Directory -Path $workspace
    $env:TEMP=$workspace; $env:TMP=$workspace
    Write-PairedJson @{source='06efc928e31486923754398007f4f78003e04ee3';instrumentation=(& git -C $PSScriptRoot rev-parse HEAD).Trim()
        jobStartUtc=$JobStartUtc;sdk=$sdkRoot;compilerConfig=$config;sourceFile=$sourceFile;originalSourceTime=$sourceTime
        importedP44Functions=$selected;fixedEditCount=20;adaptiveWarmup=$false;reportAnalyzer=$false;hostedCapture=[bool]$HostedCapture
        processors=@(Get-CimInstance Win32_Processor|Select-Object Name,NumberOfCores,NumberOfLogicalProcessors)
        computer=Get-CimInstance Win32_ComputerSystem|Select-Object Manufacturer,Model,TotalPhysicalMemory
        observerPid=$PID;observerArchitecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
        observerRuntime=[Runtime.InteropServices.RuntimeInformation]::FrameworkDescription;os=[Runtime.InteropServices.RuntimeInformation]::OSDescription
        imageOS=$env:ImageOS;imageVersion=$env:ImageVersion;protectedFiles=$configs.Count} (Join-Path $ResultsDirectory 'protocol.json')
    $errorState.phase='sdk-info-selected-hosting-restore'
    $commands.Add((Invoke-PairedCommand @('--info') (Join-Path $ResultsDirectory 'dotnet-info')))
    $commands.Add((Invoke-PairedCommand @('restore',$project,'--nologo',"/bl:$(Join-Path $ResultsDirectory 'restore.binlog')") (Join-Path $ResultsDirectory 'restore')))
    foreach($name in @('cold','noop')){$errorState.phase="build-$name";Invoke-MatureBuild $name;Read-MatureBuild $name}
    foreach($index in 1..20)
    {
        [IO.File]::WriteAllBytes($sourceFile,(Get-PairedEdit $originalSource $index))
        [IO.File]::SetLastWriteTimeUtc($sourceFile,$sourceTime.AddYears(10).AddSeconds($index))
        $errorState.phase="build-edit$index"
        Invoke-MatureBuild "edit$index";Read-MatureBuild "edit$index"
    }
    [IO.File]::SetLastWriteTimeUtc($sourceFile,$sourceTime.AddYears(10).AddSeconds(21))
    $errorState.phase='plain-control'
    Invoke-MatureBuild 'plain';Read-MatureBuild 'plain'
    Save-MatureOutputs (Join-Path $ResultsDirectory 'plain-outputs')
    $state=$null
    $attachment=@{attempted=[bool]$HostedCapture;meaning='Attach pause and background CPU are diagnostic, not throughput or a new request.'}
    try
    {
        if($HostedCapture)
        {
            $errorState.phase='collector-start-attachment'
            . (Join-Path $PSScriptRoot 'Collector.ps1')
            $attachment.before=Read-PairedCpu $observed[$script:serverKey]
            $attachment.startUtc=[DateTime]::UtcNow
            $state=Start-MatureCollection $observed[$script:serverKey] (Join-Path $ResultsDirectory 'capture')
            $attachment.endUtc=[DateTime]::UtcNow
            $attachment.after=Read-PairedCpu $observed[$script:serverKey]
        }
        $errorState.phase='target-build'
        Write-PairedJson $attachment (Join-Path $ResultsDirectory 'attachment.json')
        [IO.File]::SetLastWriteTimeUtc($sourceFile,$sourceTime.AddYears(10).AddSeconds(22))
        # A timed-out build client may be stopped by the retained command helper,
        # but compiler/node reset must wait until our profiler stop/rundown.
        $script:resetInProgress=[bool]$HostedCapture
        try { Invoke-MatureBuild 'target' }
        finally { $script:resetInProgress=$false }
    }
    catch
    {
        Register-ProtocolFailure $_ 'primary'
        throw
    }
    finally
    {
        if($state -and $state.started)
        {
            $errorState.phase='compiler-liveness-before-stop'
            try{$state.compilerBeforeStop=Read-PairedCpu $observed[$script:serverKey]}
            catch{$state.compilerAliveProofError=$_.ToString();Register-ProtocolFailure $_ 'cleanup'}
            $errorState.phase='owned-collector-stop'
            try{Stop-MatureCollection $state}
            catch{Register-ProtocolFailure $_ 'cleanup'}
        }
    }
    if($null -ne $errorState.primary){$PSCmdlet.ThrowTerminatingError($errorState.primary)}
    $errorState.phase='target-replay-output-comparison'
    Read-MatureBuild 'target'
    Save-MatureOutputs (Join-Path $ResultsDirectory 'target-outputs')
    $comparison=Compare-PairedTrees (Join-Path $ResultsDirectory 'plain-outputs') (Join-Path $ResultsDirectory 'target-outputs')
    $comparison.sourceBytesIdentical=[Linq.Enumerable]::SequenceEqual[byte](
        [IO.File]::ReadAllBytes((Join-Path $ResultsDirectory 'plain\source-input.bin')),
        [IO.File]::ReadAllBytes((Join-Path $ResultsDirectory 'target\source-input.bin')))
    Write-PairedJson $comparison (Join-Path $ResultsDirectory 'output-comparison.json')
    Write-PairedJson @(Get-PairedEmbeddedDebug (Join-Path $ResultsDirectory 'target-outputs')) (Join-Path $ResultsDirectory 'embedded-debug.json')
    $plain=Get-Content (Join-Path $ResultsDirectory 'plain\csc.json') -Raw|ConvertFrom-Json
    $target=Get-Content (Join-Path $ResultsDirectory 'target\csc.json') -Raw|ConvertFrom-Json
    $plainMain=@($plain.tasks|Where-Object target -eq 'CoreCompile')[0]
    $main=@($target.tasks|Where-Object target -eq 'CoreCompile')[0]
    $equalCommand=$plainMain.commandLine -ceq $main.commandLine
    $equalDiagnostics=(ConvertTo-Json -InputObject $plain.diagnostics -Depth 20 -Compress) -ceq (ConvertTo-Json -InputObject $target.diagnostics -Depth 20 -Compress)
    $satellites=@(Get-PairedOutputFiles $RepositoryRoot|Where-Object{$_.FullName -match '\\bin\\Aspire.Hosting\\' -and $_.Name -eq 'Aspire.Hosting.resources.dll'}).Count
    Write-PairedJson @{commandEqual=$equalCommand;diagnosticsEqual=$equalDiagnostics;mainCsc=$main;plainMainCsc=$plainMain
        sourceFrozenAtEdit=20;satelliteCount=$satellites
        semantics='Main Csc/server CPU window includes runtime/background work, not request-exclusive attribution or potential wall gain.'} (Join-Path $ResultsDirectory 'work-proof.json')
    if($cases.Count -ne 24 -or -not $comparison.passed -or $comparison.count -ne 119 -or $satellites -ne 13 -or -not $comparison.sourceBytesIdentical -or -not $equalCommand -or -not $equalDiagnostics)
    { throw 'Declared same-source full 119-output/command/diagnostic equality failed.' }
    $errorState.phase='qualified-cpu-analysis'
    if($HostedCapture){ & (Join-Path $PSScriptRoot 'Analyze-Capture.ps1') -ResultsDirectory $ResultsDirectory -SdkRoot $sdkRoot -ToolsDirectory $ToolsDirectory }
}
catch
{
    if($null -eq $errorState.primary){Register-ProtocolFailure $_ 'primary'}
    $failure=@{error=$errorState.primary.ToString();stack=$errorState.primary.ScriptStackTrace;phase=$errorState.primaryPhase}
}
finally
{
    $errorState.phase='source-restoration'
    try{if($snapshotPassed){Restore-PairedSource}}
    catch{$cleanupFailure=@{error=$_.ToString();stack=$_.ScriptStackTrace};Register-ProtocolFailure $_ 'restoration'}
    $errorState.phase='private-process-cleanup'
    try{Reset-PrivateProcesses}
    catch{$cleanupFailure=@{error=$_.ToString();stack=$_.ScriptStackTrace};Register-ProtocolFailure $_ 'cleanup'}
    $errorState.phase='source-sdk-absence-verification'
    try
    {
    $checks=@($configs|ForEach-Object{@{path=$_.path;bytesUnchanged=[Linq.Enumerable]::SequenceEqual[byte]($_.bytes,[IO.File]::ReadAllBytes($_.path));timestampUnchanged=$_.time.Ticks -eq [IO.File]::GetLastWriteTimeUtc($_.path).Ticks}})
    $restoredBytes=[Linq.Enumerable]::SequenceEqual[byte]($originalSource,[IO.File]::ReadAllBytes($sourceFile))
    $restoredTime=$sourceTime.Ticks -eq [IO.File]::GetLastWriteTimeUtc($sourceFile).Ticks
    $sourceStatus=@(& git -C $RepositoryRoot status --porcelain)
    $remaining=@(Get-PrivateProcesses)
    $restorationPassed=$snapshotPassed -and $restoredBytes -and $restoredTime -and $sourceStatus.Count -eq 0 -and
        $remaining.Count -eq 0 -and @($checks|Where-Object{-not $_.bytesUnchanged -or -not $_.timestampUnchanged}).Count -eq 0
    if(-not$restorationPassed)
    {
        try{throw 'Source/SDK/absence restoration gate failed.'}
        catch{Register-ProtocolFailure $_ 'restoration'}
    }
    Write-PairedJson @{failure=$failure;cleanupFailure=$cleanupFailure;completedCases=$cases.Count;protectedFiles=$configs.Count;sdkChecks=$checks
        sourceBytesRestored=$restoredBytes;sourceTimestampRestored=$restoredTime;restorationPassed=$restorationPassed
        sourceHead=(& git -C $RepositoryRoot rev-parse HEAD).Trim();sourceStatus=$sourceStatus
        identities=@($observed.Values);confirmedExited=@($confirmedExited.Keys);remainingPrivateProcesses=$remaining
        hostedCapture=[bool]$HostedCapture;primaryPhase=$errorState.primaryPhase;failureRecords=@($errorState.records.ToArray())
        secondaryFailures=@($errorState.secondary|ForEach-Object{$_.ToString()});reportingFailures=@($errorState.reportingErrors.ToArray())} (Join-Path $ResultsDirectory 'final-state.json')
    Write-PairedJson @($commands.ToArray()) (Join-Path $ResultsDirectory 'commands.json')
    }
    catch{Register-ProtocolFailure $_ 'restoration'}
}
if($null -ne $errorState.primary){$PSCmdlet.ThrowTerminatingError($errorState.primary)}
