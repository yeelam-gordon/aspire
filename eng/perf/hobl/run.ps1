# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

[CmdletBinding()]
param(
    [ValidateSet('original', 'aligned')][string]$Profile = 'original',
    [ValidateRange(1, 4)][int]$Loops = 4,
    [ValidateSet('windows', 'macos')][string]$Platform = $(if ($IsWindows) { 'windows' } else { 'macos' }),
    [switch]$Plan,
    [switch]$DiagnosticBinlogs,
    [ValidateRange(1, 55)][int]$BudgetMinutes = 30,
    [ValidateRange(1, 100)][int]$BudgetGiB = 20,
    [string]$SetupSeedFrom = '',
    [string]$OutputRoot = (Join-Path $PSScriptRoot '..\..\..\artifacts\hobl')
)

. (Join-Path $PSScriptRoot 'Hobl.ps1')
$planData = Get-HoblPlan $Platform $Profile $Loops
if ($Plan) { $planData | ConvertTo-Json -Depth 20; return }

$deadlines = Get-HoblDeadlines -StartedUtc ([datetime]::UtcNow) -TotalSeconds ($BudgetMinutes * 60)
$deadline = $deadlines.workload
$budgetBytes = [long]$BudgetGiB * 1GB
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$OutputRoot = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot))
Assert-HoblPath $OutputRoot $repoRoot
$null = New-Item -ItemType Directory -Path $OutputRoot -Force
$runRoot = Join-Path $OutputRoot ("{0}-{1}-{2}-{3}" -f [datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ'), $Platform, $Profile, [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $runRoot
Assert-HoblPath $runRoot $OutputRoot
$logs = Join-Path $runRoot 'logs'
$source = Join-Path $runRoot 'source'
$dotnetRoot = Get-HoblDotnetRoot $runRoot $Platform $Profile
foreach ($directory in @('logs', 'cache', 'packages', 'scratch', 'cli', 'provenance')) {
    $null = New-Item -ItemType Directory -Path (Join-Path $runRoot $directory)
}
$planData | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $runRoot 'plan.json')
$nugetBoundary = New-HoblNuGetBoundary $runRoot
$result = [ordered]@{
    status = 'running'; completeFourLoopResult = $false; plan = $planData
    runRoot = $runRoot; budgetMinutes = $BudgetMinutes; budgetGiB = $BudgetGiB
    diagnosticBinlogs = [bool]$DiagnosticBinlogs; iterations = @(); setup = @()
    failure = $null; nativeToolchainVerified = $false; allBuildToolsNative = 'unverified'
    nugetBoundary = $nugetBoundary
    dotnetRoot = $dotnetRoot
    totalDeadlineUtc = $deadlines.total.ToString('o')
    workloadDeadlineUtc = $deadline.ToString('o')
    cleanupReserveSeconds = $deadlines.cleanupSeconds
    timingContract = 'Windows process start/exit lifetime; macOS upstream unix-time real; supervisor wall recorded separately'
}
$result.adapterSnapshot = Save-HoblAdapterSnapshot $runRoot
$childEnv = @{
    DOTNET_ROOT = $dotnetRoot; DOTNET_ROOT_ARM64 = $dotnetRoot
    DOTNET_ROOT_X64 = (Join-Path $dotnetRoot 'x64'); DOTNET_INSTALL_DIR = $dotnetRoot
    DOTNET_CLI_HOME = (Join-Path $runRoot 'cli'); DOTNET_MULTILEVEL_LOOKUP = '0'
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'; DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    # Modern SDKs ignore DOTNET_SKIP_FIRST_TIME_EXPERIENCE. Prevent their
    # first-use helper from changing persistent user PATH or the certificate store.
    DOTNET_ADD_GLOBAL_TOOLS_TO_PATH = 'false'; DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
    NUGET_PACKAGES = (Join-Path $runRoot 'packages')
    NUGET_HTTP_CACHE_PATH = (Join-Path $runRoot 'cache')
    NUGET_PLUGINS_CACHE_PATH = (Join-Path $runRoot 'cache\plugins')
    TEMP = (Join-Path $runRoot 'scratch'); TMP = (Join-Path $runRoot 'scratch'); TMPDIR = (Join-Path $runRoot 'scratch')
    npm_config_cache = (Join-Path $runRoot 'cache\npm')
    PLAYWRIGHT_BROWSERS_PATH = (Join-Path $runRoot 'cache\playwright')
    PLAYWRIGHT_DOWNLOAD_CONNECTION_TIMEOUT = '300000'
    MSBUILDTERMINALLOGGER = 'false'
    # Do not inherit parent experimentation (notably private P22 engines or newer SDK roots).
    MSBuildSDKsPath = $null; MSBUILD_EXE_PATH = $null; DOTNET_HOST_PATH = $null
    MSBUILDDEBUGENGINE = $null; MSBUILDDEBUGPATH = $null; MSBuildExtensionsPath = $null
    DOTNET_ROLL_FORWARD = $null; DOTNET_ROLL_FORWARD_TO_PRERELEASE = $null
    prepare_machine = 'false'; _InitializeDotNetCli = $null; _InitializeBuildTool = $null; _InitializeToolset = $null
}
# A developer shell must not redirect clean outputs or imports into another
# checkout. Let the pinned source compute its own default build paths.
foreach ($key in @('ArtifactsDir', 'ArtifactsPath', 'BaseOutputPath', 'BaseIntermediateOutputPath',
    'OutputPath', 'OutDir', 'IntermediateOutputPath', 'MSBuildProjectExtensionsPath', 'PackageOutputPath',
    'DirectoryBuildPropsPath', 'DirectoryBuildTargetsPath', 'DirectoryPackagesPropsPath',
    'MSBuildExtensionsPath32', 'MSBuildExtensionsPath64', 'MSBuildUserExtensionsPath',
    'CustomBeforeMicrosoftCommonTargets', 'CustomAfterMicrosoftCommonTargets',
    'CustomBeforeMicrosoftCommonProps', 'CustomAfterMicrosoftCommonProps',
    'DOTNET_MSBUILD_SDK_RESOLVER_CLI_DIR', 'DOTNET_MSBUILD_SDK_RESOLVER_SDKS_DIR',
    'DOTNET_MSBUILD_SDK_RESOLVER_SDKS_VER')) {
    $childEnv[$key] = $null
}
$separator = [IO.Path]::PathSeparator
$childEnv.PATH = $dotnetRoot + $separator + $env:PATH
$childEnv.NUGET_PLUGINS_CACHE_PATH = Join-Path (Join-Path $runRoot 'cache') 'plugins'
$childEnv.npm_config_cache = Join-Path (Join-Path $runRoot 'cache') 'npm'
$childEnv.PLAYWRIGHT_BROWSERS_PATH = Join-Path (Join-Path $runRoot 'cache') 'playwright'
if (-not $IsWindows) {
    # Keep HOME so NuGet still sees user audit/disabled-source/signer policy.
    # Private CLI/package/cache/scratch roots and first-use switches isolate writes.
    $childEnv.XDG_CACHE_HOME = Join-Path $runRoot 'cache'
}
$childEnv | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $runRoot 'environment.json')
$common = @{
    Environment = $childEnv; Deadline = $deadline; BudgetRoot = $runRoot; BudgetBytes = $budgetBytes
}
$sequence = 0
function Invoke-Setup {
    param([string[]]$Command, [string]$Directory = $runRoot)
    $script:sequence++
    $record = Invoke-HoblProcess -Argv $Command -WorkingDirectory $Directory -Log (Join-Path $logs ("setup-{0:D2}.log" -f $script:sequence)) @common
    $result.setup += $record
    Save-Result
    return $record
}
function Save-Result {
    $result | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $runRoot 'result.json')
}
function Get-PinnedDownload {
    param([string]$Uri, [string]$Destination)
    $remainingSeconds = [int][math]::Floor(($deadline - [datetime]::UtcNow).TotalSeconds)
    if ($remainingSeconds -lt 1) { throw 'Run time budget exhausted before download.' }
    Invoke-WebRequest $Uri -OutFile $Destination -TimeoutSec ([math]::Min(120, $remainingSeconds))
    if ((Get-HoblBytes $runRoot) -gt $budgetBytes) { throw 'Owned run storage budget exceeded.' }
}
function Save-SourceState {
    if (Test-Path (Join-Path $source '.git')) {
        $null = Invoke-Setup @('git', '-c', 'core.longpaths=true', 'status', '--short') $source
        $null = Invoke-Setup @('git', '-c', 'core.longpaths=true', 'diff', '--binary') $source
    }
}
try {
    Write-Host "HOBL adapter: $runRoot; total budget $BudgetMinutes minutes / $BudgetGiB GiB, including $($deadlines.cleanupSeconds)s cleanup reserve. Not full lab orchestration."
    Save-Result
    if (($Platform -eq 'windows' -and -not $IsWindows) -or ($Platform -eq 'macos' -and -not $IsMacOS)) { throw 'Execution platform mismatch; use -Plan for foreign recipes.' }
    if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'Arm64' -or
        [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne 'Arm64') {
        throw 'Native ARM64 OS and PowerShell are required.'
    }
    if ($PSVersionTable.PSVersion -le [version]'7.0') { throw 'PowerShell >7.0 required.' }
    if ($SetupSeedFrom) {
        $SetupSeedFrom = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SetupSeedFrom))
        Assert-HoblPath $SetupSeedFrom $OutputRoot
        $seed = Get-Content (Join-Path $SetupSeedFrom 'result.json') -Raw | ConvertFrom-Json -AsHashtable
        if ($seed.runRoot -ne $SetupSeedFrom -or $seed.plan.platform -ne $Platform -or
            $seed.status -notin @('passed', 'failed') -or -not $seed.nativeToolchainVerified -or
            $seed.plan.provenance.source.commit -ne $planData.provenance.source.commit -or
            $seed.plan.provenance.hobl.commit -ne $planData.provenance.hobl.commit -or
            $seed.plan.provenance.toolchain.installerCommit -ne $planData.provenance.toolchain.installerCommit) {
            throw 'Setup seed is not an owned, verified run with the pinned provenance.'
        }
        if ((Get-HoblBytes $SetupSeedFrom) -gt $budgetBytes) { throw 'Setup seed exceeds the storage budget.' }
        # Optional local setup cache only: a fresh source is still cloned, every
        # installer/check/prep command still runs, and no timed results are reused.
        $seedDotnet = Get-HoblDotnetRoot $SetupSeedFrom $Platform $seed.plan.profile
        if ($Platform -eq 'macos' -and $seed.plan.profile -eq 'original' -and
            (-not $seed.ContainsKey('dotnetRoot') -or $seed.dotnetRoot -ne $seedDotnet)) {
            throw 'Mac original setup seed predates verified wrapper SDK routing.'
        }
        foreach ($folder in @('dotnet', 'packages', 'cache')) {
            $seedPath = if ($folder -eq 'dotnet') { $seedDotnet } else { Join-Path $SetupSeedFrom $folder }
            $targetPath = if ($folder -eq 'dotnet') { $dotnetRoot } else { Join-Path $runRoot $folder }
            Assert-HoblPath $seedPath $SetupSeedFrom -Recurse
            Assert-HoblPath $targetPath $runRoot
            $null = New-Item -ItemType Directory -Path $targetPath -Force
            if ($IsWindows) {
                # Robocopy's 0..7 codes are successful copy outcomes. Copy data,
                # attributes and timestamps only, never security/ACLs; no /MIR/delete.
                $result.setup += Invoke-HoblProcess -Argv @('robocopy', $seedPath, $targetPath,
                    '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:0', '/W:0', '/XJ', '/NFL', '/NDL', '/NP') `
                    -WorkingDirectory $runRoot -Log (Join-Path $logs "setup-seed-$folder.log") -SuccessExitCodes (0..7) @common
            }
            else {
                foreach ($item in Get-ChildItem -LiteralPath $seedPath -Force) {
                    if ([datetime]::UtcNow -ge $deadline) { throw 'Time budget exhausted copying setup seed.' }
                    Copy-Item -LiteralPath $item.FullName -Destination $targetPath -Recurse
                }
            }
            if ((Get-HoblBytes $runRoot) -gt $budgetBytes) { throw 'Owned run storage budget exceeded copying setup seed.' }
        }
        $result.setupSeedFrom = $SetupSeedFrom
        Save-Result
    }
    $hardware = [ordered]@{
        os = [Runtime.InteropServices.RuntimeInformation]::OSDescription
        osArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        powershellArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
        powershellVersion = $PSVersionTable.PSVersion.ToString()
        logicalProcessors = [Environment]::ProcessorCount
    }
    if ($IsWindows) {
        $hardware.cpu = @(Get-CimInstance Win32_Processor | Select-Object Name, Architecture, NumberOfCores, NumberOfLogicalProcessors)
        $hardware.memoryBytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    }
    else {
        $null = Invoke-Setup @('/usr/sbin/sysctl', '-a')
        $null = Invoke-Setup @('/usr/bin/xcode-select', '-p')
        # grpc.tools in this source uses macosx_x64/protoc, including prep and possibly timed codegen.
        # Probe existing translation support, but never install Rosetta or assert all-native execution.
        $null = Invoke-Setup @('/usr/bin/arch', '-x86_64', '/usr/bin/true')
        if ($Profile -eq 'original') {
            $python = Invoke-Setup @('python3', '--version')
            if ((Get-Content $python.stdout -Raw).Trim() -ne 'Python 3.12.10') { throw 'Original macOS prep requires preexisting Python 3.12.10.' }
        }
    }
    $hardware | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $runRoot 'hardware.json')
    $null = Invoke-Setup @('git', '--version')
    $null = Invoke-Setup @('node', '-p', 'JSON.stringify({version:process.version,arch:process.arch,execPath:process.execPath})')
    $tools = foreach ($tool in @('git', 'node', 'pwsh')) {
        $executable = (Get-Command $tool -CommandType Application -ErrorAction Stop).Source
        $architecture = 'unverified'
        if ($IsWindows) {
            $toolBytes = [IO.File]::ReadAllBytes($executable)
            $offset = [BitConverter]::ToInt32($toolBytes, 0x3c)
            $architecture = 'PE machine 0x{0:X4}' -f [BitConverter]::ToUInt16($toolBytes, $offset + 4)
        }
        else {
            $fileInfo = Invoke-Setup @('/usr/bin/file', '-L', $executable)
            $architecture = (Get-Content $fileInfo.stdout -Raw).Trim()
        }
        [ordered]@{ tool = $tool; executable = $executable; architecture = $architecture }
    }
    $hardware.tools = @($tools)
    $hardware | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $runRoot 'hardware.json')
    if ($IsWindows) {
        $null = Get-Command npm.cmd -ErrorAction Stop
        # cmd's /c string parsing differs from CommandLineToArgvW. Resolve the bare
        # npm command through the child PATH instead of embedding a quoted path.
        $null = Invoke-Setup @($env:ComSpec, '/d', '/c', 'npm', '--version')
    }
    else { $null = Invoke-Setup @('npm', '--version') }

    $manifest = $planData.provenance
    # Retain exact reference scripts as data only. Never invoke privileged upstream prep.
    foreach ($entry in @(
        @('windows-prep.ps1', $manifest.hobl.windowsPrep), @('windows-run.ps1', $manifest.hobl.windowsRun),
        @('macos-prep.sh', $manifest.hobl.macosPrep), @('macos-run.sh', $manifest.hobl.macosRun))) {
        $uri = "https://raw.githubusercontent.com/microsoft/HOBL/$($manifest.hobl.commit)/$($entry[1])"
        Get-PinnedDownload $uri (Join-Path (Join-Path $runRoot 'provenance') $entry[0])
    }
    $null = Invoke-Setup @('git', 'init', $source)
    $null = Invoke-Setup @('git', '-c', 'core.hooksPath=', 'fetch', '--depth=1', $manifest.source.repository, $manifest.source.commit) $source
    # Long snapshot names need command-scoped longpaths; no global Git/registry change.
    $null = Invoke-Setup @('git', '-c', 'core.hooksPath=', '-c', 'core.longpaths=true', 'checkout', '--detach', 'FETCH_HEAD') $source
    Assert-HoblPath $source $runRoot -Recurse
    $head = Invoke-Setup @('git', 'rev-parse', 'HEAD') $source
    if ((Get-Content $head.stdout -Raw).Trim() -ne $manifest.source.commit) { throw 'Source commit mismatch.' }
    $globalJson = Get-Content (Join-Path $source 'global.json') -Raw | ConvertFrom-Json
    if ($globalJson.sdk.version -ne $manifest.toolchain.sdks[-1]) { throw 'Pinned source SDK mismatch.' }
    foreach ($entry in @(
        @('global.json', 'aspire-global.json'), @('eng\Versions.props', 'aspire-Versions.props'),
        @('Aspire.slnx', 'aspire-Aspire.slnx'), @('NuGet.config', 'aspire-NuGet.config'),
        @('eng\common\tools.sh', 'aspire-tools.sh'))) {
        Copy-Item -LiteralPath (Join-Path $source $entry[0]) -Destination (Join-Path (Join-Path $runRoot 'provenance') $entry[1])
    }
    Assert-HoblPath $dotnetRoot $runRoot
    $null = New-Item -ItemType Directory -Path $dotnetRoot -Force
    $installerName = if ($IsWindows) { 'dotnet-install.ps1' } else { 'dotnet-install.sh' }
    $installer = Join-Path $runRoot $installerName
    Get-PinnedDownload "https://raw.githubusercontent.com/dotnet/install-scripts/$($manifest.toolchain.installerCommit)/src/$installerName" $installer
    $installer | Set-Content (Join-Path $runRoot 'installer-path.txt')
    foreach ($sdk in $manifest.toolchain.sdks) {
        if ($IsWindows) {
            $null = Invoke-Setup @((Get-Process -Id $PID).Path, '-NoProfile', '-File', $installer, '-Version', $sdk, '-Architecture', 'arm64', '-InstallDir', $dotnetRoot, '-NoPath')
        }
        else {
            $null = Invoke-Setup @('/bin/bash', $installer, '--version', $sdk, '--architecture', 'arm64', '--install-dir', $dotnetRoot, '--no-path')
        }
    }
    foreach ($architecture in $manifest.toolchain.architectures) {
        $installRoot = if ($architecture -eq 'arm64') { $dotnetRoot } else { Join-Path $dotnetRoot 'x64' }
        foreach ($runtime in $manifest.toolchain.runtimes) {
            foreach ($framework in $manifest.toolchain.frameworks) {
                if ($IsWindows) {
                    $null = Invoke-Setup @((Get-Process -Id $PID).Path, '-NoProfile', '-File', $installer, '-Version', $runtime, '-Runtime', $framework, '-Architecture', $architecture, '-InstallDir', $installRoot, '-NoPath', '-SkipNonVersionedFiles')
                }
                else {
                    $null = Invoke-Setup @('/bin/bash', $installer, '--version', $runtime, '--runtime', $framework, '--architecture', $architecture, '--install-dir', $installRoot, '--no-path', '--skip-non-versioned-files')
                }
            }
        }
    }
    $dotnet = Join-Path $dotnetRoot $(if ($IsWindows) { 'dotnet.exe' } else { 'dotnet' })
    if ($IsWindows) {
        $bytes = [IO.File]::ReadAllBytes($dotnet)
        $pe = [BitConverter]::ToInt32($bytes, 0x3c)
        if ([BitConverter]::ToUInt16($bytes, $pe + 4) -ne 0xaa64) { throw 'Private dotnet host is not ARM64.' }
    }
    else { $null = Invoke-Setup @('/usr/bin/file', $dotnet) }
    $info = Invoke-Setup @($dotnet, '--info') $source
    if ((Get-Content $info.stdout -Raw) -notmatch 'Architecture:\s+arm64') { throw 'dotnet --info did not report native ARM64 host.' }
    $result.nativeToolchainVerified = $true
    $null = Invoke-Setup @($dotnet, '--list-sdks') $source
    $null = Invoke-Setup @($dotnet, '--list-runtimes') $source
    $null = Invoke-Setup @((Join-Path (Join-Path $dotnetRoot 'x64') $(if ($IsWindows) { 'dotnet.exe' } else { 'dotnet' })), '--info') $source
    if ($Platform -eq 'macos' -and $Profile -eq 'original') {
        $probe = New-HoblWrapperProbe $runRoot
        $routing = Invoke-Setup @('/bin/bash', '--noprofile', '--norc', $probe, $source) $source
        $selected = @(Select-String -LiteralPath $routing.stdout -Pattern '^HOBL_DOTNET_ROOT=(.+)$')
        if ($selected.Count -ne 1 -or $selected[0].Matches[0].Groups[1].Value -cne $dotnetRoot) {
            throw 'Pinned wrapper selected a different SDK root from the verified private install.'
        }
        $result.wrapperSelectedDotnetRoot = $dotnetRoot
    }
    $sdkVersion = Invoke-Setup @($dotnet, '--version') $source
    if ((Get-Content $sdkVersion.stdout -Raw).Trim() -ne $globalJson.sdk.version) { throw 'SDK selection drift.' }
    $sentinel = Join-Path $source '.hobl-owned-source'
    $outsideSentinel = Join-Path $runRoot 'outside-source-sentinel.txt'
    $token = [guid]::NewGuid().ToString('N')
    Set-Content $sentinel $token
    Set-Content $outsideSentinel $token
    foreach ($command in $planData.workload.prep) {
        $argv = @($command)
        if ($argv[0] -eq 'dotnet') { $argv[0] = $dotnet }
        $null = Invoke-Setup $argv $source
    }
    Save-SourceState
    for ($loop = 1; $loop -le $Loops; $loop++) {
        $iteration = [ordered]@{ index = $loop; phases = @(); scenarioRuntimeSeconds = 0.0
            compilerInvocations = $null; compilerCommandLinesObserved = 0; compilerCaptureKind = 'stdout-command-line-mentions-only'
            compiledOutputs = 0; builtArtifacts = 0; binlogs = @() }
        $result.iterations += $iteration
        foreach ($phase in $planData.workload.iteration) {
            if ($phase.phase -eq 'clean') {
                Assert-HoblPath $source $runRoot -Recurse
                if (-not (Test-Path (Join-Path $source '.git') -PathType Container)) { throw 'Owned clone .git missing.' }
            }
            $argv = @($phase.argv)
            if ($argv[0] -eq 'dotnet') { $argv[0] = $dotnet }
            $log = Join-Path $logs "iteration-$loop-$($phase.phase).log"
            $extra = @{}
            if ($phase.timed) {
                if ($DiagnosticBinlogs) { $argv += "/bl:$(Join-Path $logs "iteration-$loop.binlog")" }
                if ($IsMacOS) { $extra.TimingFile = Join-Path $logs "iteration-$loop-time.txt" }
            }
            $record = Invoke-HoblProcess -Argv $argv -WorkingDirectory $source -Log $log @common @extra
            $record.phase = $phase.phase
            $record.timed = $phase.timed
            $record.recipeArgv = $phase.argv
            $iteration.phases += $record
            if ((Get-Content $sentinel -Raw).Trim() -ne $token -or (Get-Content $outsideSentinel -Raw).Trim() -ne $token) { throw 'Source/outside sentinel altered.' }
            if ($phase.timed) {
                $iteration.scenarioRuntimeSeconds = $record.processWallSeconds
                $iteration.timingKind = 'process-start-exit-lifetime'
                if ($IsMacOS) {
                    $timing = Get-HoblUnixTime $extra.TimingFile
                    $iteration.scenarioRuntimeSeconds = $timing.real
                    $iteration.unixTime = $timing
                    $iteration.timingKind = 'upstream-unix-time-real'
                }
                # Minimal verbosity can omit csc command lines. Also require fresh intermediate
                # compiler outputs and bin artifacts, so exit 0 from an empty solution cannot pass.
                $iteration.compilerCommandLinesObserved = @(Select-String -LiteralPath $log -Pattern 'csc\.dll|csc\.exe' -CaseSensitive:$false).Count
                $freshOutputs = @(Get-HoblFreshOutputs (Join-Path $source 'artifacts') $record.startedUtc)
                $iteration.compiledOutputPaths = @($freshOutputs | Where-Object FullName -Match '[\\/]obj[\\/]' | ForEach-Object FullName)
                $iteration.builtArtifactPaths = @($freshOutputs | Where-Object FullName -Match '[\\/]bin[\\/]' | ForEach-Object FullName)
                $iteration.compiledOutputs = $iteration.compiledOutputPaths.Count
                $iteration.builtArtifacts = $iteration.builtArtifactPaths.Count
                # Arcade's original Mac wrapper can emit its own binlogs. Freeze
                # each iteration's logs before the next clean/build overwrites them,
                # without adding instrumentation to the upstream workload command.
                $binaryLogs = @(Get-HoblFreshOutputs (Join-Path $source 'artifacts') $record.startedUtc -Filter '*.binlog')
                for ($logIndex = 0; $logIndex -lt $binaryLogs.Count; $logIndex++) {
                    Copy-Item -LiteralPath $binaryLogs[$logIndex].FullName -Destination (Join-Path $logs "iteration-$loop-upstream-$logIndex.binlog")
                }
                $iteration.binlogs = @(Get-ChildItem $logs -Filter "iteration-$loop*.binlog" | ForEach-Object FullName)
            }
            Save-Result
        }
    }
    Save-SourceState
    $result.status = 'passed'
    Assert-HoblEvidence $result $Loops
    $result.completeFourLoopResult = $Loops -eq 4
    $result.iterations | ForEach-Object {
        [pscustomobject]@{ iteration = $_.index; scenario_runtime = $_.scenarioRuntimeSeconds; build_time = $_.scenarioRuntimeSeconds
            compiler_invocations = $_.compilerInvocations; compiler_command_lines_observed = $_.compilerCommandLinesObserved
            compiler_capture_kind = $_.compilerCaptureKind; compiled_outputs = $_.compiledOutputs; built_artifacts = $_.builtArtifacts }
    } | Export-Csv (Join-Path $runRoot 'metrics.csv') -NoTypeInformation
}
catch {
    $result.status = 'failed'
    $result.failure = $_.Exception.Message
    Write-Warning $result.failure
    # Preserve dirty-source evidence even when prep failed; never reset or silently accept regeneration.
    if ([datetime]::UtcNow -lt $deadline) {
        try { Save-SourceState } catch { $result.sourceStateFailure = $_.Exception.Message }
    }
}
finally {
    if ($result.nativeToolchainVerified) {
        $result.buildServerShutdownAttempted = $true
        try {
            # The SDK lives only in this run's private root. Request orderly shutdown
            # of its build servers after measurement; never kill machine processes by name.
            $cleanup = @{
                Argv = @($dotnet, 'build-server', 'shutdown')
                WorkingDirectory = $source
                Log = (Join-Path $logs 'build-server-shutdown.log')
                Environment = $childEnv
                TotalDeadline = $deadlines.total
                BudgetRoot = $runRoot
            }
            $result.buildServerShutdown = Invoke-HoblReservedCleanup @cleanup
        }
        catch {
            $result.buildServerShutdownFailure = $_.Exception.Message
            $result.status = 'failed'
            $result.completeFourLoopResult = $false
            $result.failure = "Owned SDK cleanup failed: $($_.Exception.Message). $($result.failure)"
        }
    }
    if ($IsWindows) {
        $ownedToolsPath = Join-Path (Join-Path $runRoot 'cli') '.dotnet\tools'
        $result.persistentUserPathContainsOwnedTools = $ownedToolsPath -in @([Environment]::GetEnvironmentVariable('Path', 'User') -split ';')
        if ($result.persistentUserPathContainsOwnedTools) {
            $result.status = 'failed'
            $result.completeFourLoopResult = $false
            $result.failure = "Unexpected persistent user PATH side effect for $ownedToolsPath. $($result.failure)"
        }
    }
    Save-Result
    Write-Host "Result: $($result.status); complete four-loop result: $($result.completeFourLoopResult). Evidence: $runRoot"
}
if ($result.status -ne 'passed') { exit 1 }
