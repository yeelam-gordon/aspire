[CmdletBinding()]
param([Parameter(Mandatory)][string]$Sdk, [Parameter(Mandatory)][string]$Binaries, [Parameter(Mandatory)][string]$Output)
. (Join-Path $PSScriptRoot 'Helpers.ps1')
# Must precede output creation, discovery, helper launch and collector access.
# There is deliberately no local/force/dry-run capture switch.
$context = Assert-HostedCpuContext
$expected = [IO.Path]::GetFullPath((Join-Path $env:GITHUB_WORKSPACE 'standard-cpu-results\evidence\calibration'))
if ([IO.Path]::GetFullPath($Output) -cne $expected) { throw 'Unexpected hosted capture evidence root.' }
if (Test-Path -LiteralPath $Output) { throw 'Refusing recording overwrite.' }
$null = New-Item -ItemType Directory -Path $Output
Write-CpuJson $context (Join-Path $Output 'hosted-context.json')
$serviceBefore = Get-Service VSStandardCollectorService150 -ErrorAction SilentlyContinue
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$installations = @(& $vswhere -products '*' -latest -property installationPath)
if ($LASTEXITCODE -ne 0 -or $installations.Count -ne 1) { throw 'Installed Visual Studio discovery failed.' }
$collector = Join-Path $installations[0] 'Team Tools\DiagnosticsHub\Collector'
$tool = Join-Path $collector 'VSDiagnostics.exe'
$agent = Join-Path $collector 'Agents\DiagnosticsHub.CpuAgent.dll'
$runtime = Join-Path $collector 'DiagnosticsHub.StandardCollector.Runtime.dll'
$configPath = Join-Path $collector 'AgentConfigs\CPUUsageLow.json'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if (@($config.Agents).Count -ne 1 -or $config.Agents[0].Name -cne 'DiagnosticsHub.CpuAgent.dll' -or
    $config.Agents[0].CLSID -cne '4EA90761-2248-496C-B854-3C0399A591A4' -or
    $config.Agents[0].Config.cpuSampleRate -ne 100 -or
    $config.Agents[0].Config.attachToChildProcesses -eq $true -or
    (Get-CpuPeMachine $agent) -ne '0xAA64' -or (Get-CpuPeMachine $runtime) -ne '0xAA64')
{
    throw 'Installed standard low CPU config/native ARM64 agent preflight failed.'
}
Write-CpuJson @{
    collector = $collector; config = $config; configPath = $configPath
    files = @($tool, $agent, $runtime | ForEach-Object {
        $file = Get-Item -LiteralPath $_
        @{ path = $_; bytes = $file.Length; version = $file.VersionInfo.FileVersion; peMachine = Get-CpuPeMachine $_ }
    })
    elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    serviceBefore = if ($null -ne $serviceBefore) { $serviceBefore.Status.ToString() } else { 'not present' }
    acquisitionScope = 'Dedicated ephemeral hosted job; /attach selects owned target, not a claim about physical per-process acquisition.'
} (Join-Path $Output 'collector-preflight.json')
foreach ($command in @('start', 'stop', 'expandDiagSession'))
{
    $help = Start-CpuProcess $tool @($command, '/help') (Join-Path $Output "$command-help")
    $helpReceipt = Complete-CpuProcess $help 10
    if ($helpReceipt.timedOut -or $helpReceipt.exitCode -ne 0) { throw "Installed $command help failed." }
}
if ((Get-Content (Join-Path $Output 'start-help.stdout.log') -Raw) -notmatch 'parsable Guid')
{
    throw 'Installed collector does not confirm GUID session IDs; no guessed fallback.'
}

$session = [Guid]::NewGuid().ToString()
$started = $false
$stopAttempted = $false
$stopReceipt = $null
$failure = $null
$cleanupFailure = $null
$helper = $null
$fixture = Join-Path $Output 'fixture'
try
{
    $helper = Start-KnownCpuFixture $Sdk $Binaries $fixture
    $ready = Assert-KnownCpuFixture $helper $fixture $Sdk
    Write-CpuJson @{ sessionId = $session; identity = $ready; started = $false; retries = 0 } (Join-Path $Output 'session.json')
    $scratch = Join-Path $Output 'scratch'
    $null = New-Item -ItemType Directory -Path $scratch
    Assert-ExactCpuProcess $helper
    $start = Start-CpuProcess $tool @('start', $session, "/attach:$($helper.pid)", "/loadConfig:$configPath", "/scratchLocation:$scratch") (Join-Path $Output 'collector-start')
    $startReceipt = Complete-CpuProcess $start 12
    # Exit-zero receipt for this exact GUID is ownership. A collision, denial or
    # timeout never becomes authority to stop an existing/ambiguous session.
    if ($startReceipt.timedOut -or $startReceipt.exitCode -ne 0) { throw 'Standard session start failed/ambiguous; no stop, retry or new ID.' }
    $started = $true
    Write-CpuJson @{ sessionId = $session; identity = $ready; started = $true; startReceipt = $startReceipt; retries = 0 } (Join-Path $Output 'session.json')
    Set-Content -LiteralPath (Join-Path $fixture 'go') -Value 'attached owned known-work calibration'
    Wait-CpuFile (Join-Path $fixture 'done') $helper 15
}
catch { $failure = $_.ToString() }
finally
{
    if ($started -and -not $stopAttempted)
    {
        $stopAttempted = $true
        try
        {
            $stop = Start-CpuProcess $tool @('stop', $session, "/output:$(Join-Path $Output 'known-work.diagsession')") (Join-Path $Output 'collector-stop')
            $stopReceipt = Complete-CpuProcess $stop 30
            if ($stopReceipt.timedOut -or $stopReceipt.exitCode -ne 0) { throw 'Owned collector finalization failed/unknown; not retried.' }
        }
        catch { $cleanupFailure = $_.ToString() }
    }
    if ($null -ne $helper)
    {
        try { Close-KnownCpuFixture $helper $fixture }
        catch { $cleanupFailure = "$cleanupFailure`n$($_.ToString())" }
    }
    $serviceAfter = Get-Service VSStandardCollectorService150 -ErrorAction SilentlyContinue
    Write-CpuJson @{
        sessionId = $session; started = $started; stopAttempted = $stopAttempted
        stopReceipt = $stopReceipt; primaryFailure = $failure; cleanupFailure = $cleanupFailure
        helperExited = $null -eq $helper -or $helper.process.HasExited
        serviceAfter = if ($null -ne $serviceAfter) { $serviceAfter.Status.ToString() } else { 'not present' }
        serviceStoppedByWorker = $false; finalCollectorLoss = 'unknown, not zero'
    } (Join-Path $Output 'finalization.json')
}
if ($null -ne $failure -or $null -ne $cleanupFailure) { throw "Calibration failed. Primary: $failure Cleanup: $cleanupFailure" }
$archive = Join-Path $Output 'known-work.diagsession'
if (-not (Test-Path -LiteralPath $archive) -or (Get-Item -LiteralPath $archive).Length -eq 0) { throw 'Finalized output missing/empty.' }
$expand = Start-CpuProcess $tool @('expandDiagSession', $archive) (Join-Path $Output 'collector-expand')
$expandReceipt = Complete-CpuProcess $expand 30
if ($expandReceipt.timedOut -or $expandReceipt.exitCode -ne 0) { throw 'Standard archive expansion failed; no alternate parser.' }
# Independently exercise the public diagsession-aware reader on the same owned
# archive. Missing/multiple ETLs or opaque CPU payloads are explicit limitations.
$decoder = Start-CpuProcess (Join-Path $Sdk 'dotnet.exe') @(
    (Join-Path $Binaries 'CpuDecoder.dll'), $archive,
    (Join-Path $fixture 'ready.json'), (Join-Path $fixture 'phases.json'),
    (Join-Path $Output 'decode')
) (Join-Path $Output 'decoder')
$decodeReceipt = Complete-CpuProcess $decoder 90
if ($decodeReceipt.timedOut -or $decodeReceipt.exitCode -ne 0) { throw 'Owned archive CPU decode failed; retained without retry.' }
$cpu = Get-Content (Join-Path $Output 'decode\cpu.json') -Raw | ConvertFrom-Json
$burn = @($cpu.phases | Where-Object name -eq 'Burn')
$sleep = @($cpu.phases | Where-Object name -eq 'Sleep')
$burnSamples = ($burn | Measure-Object samples -Sum).Sum
$sleepSamples = ($sleep | Measure-Object samples -Sum).Sum
$knownSamples = ($burn | Measure-Object knownMethodSamples -Sum).Sum
Write-CpuJson @{
    burnSamples = $burnSamples; sleepSamples = $sleepSamples; knownMethodSamples = $knownSamples
    cpuDiscrimination = ($burn | Measure-Object cpuSeconds -Sum).Sum -gt 1 -and ($sleep | Measure-Object cpuSeconds -Sum).Sum -lt 0.5
    sampleDiscrimination = $burnSamples -gt (4 * $sleepSamples + 10)
    symbolizedKnownMethod = $knownSamples -gt 0; decoderEventsLost = $cpu.decoderReportedEventsLost
    finalCollectorLoss = 'unknown; no guessed interpretation of undocumented stop-output fields'
    acceptedAsCompleteAttribution = $false
} (Join-Path $Output 'calibration-quality.json')
# Even usable stacks cannot erase an unknown final-loss discriminator.
throw 'Calibration retained for inspection; final collector loss/quality remains unverified. No retry.'
