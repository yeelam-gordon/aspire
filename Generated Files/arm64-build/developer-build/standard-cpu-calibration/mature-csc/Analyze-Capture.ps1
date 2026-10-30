[CmdletBinding()]
param([Parameter(Mandatory)][string]$ResultsDirectory,[Parameter(Mandatory)][string]$SdkRoot,[Parameter(Mandatory)][string]$ToolsDirectory)
. (Join-Path $PSScriptRoot 'Guard.ps1')
$null=Assert-MatureContext
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Helpers.ps1')
$capture=Join-Path $ResultsDirectory 'capture'
$state=Get-Content (Join-Path $capture 'session-final.json') -Raw|ConvertFrom-Json
$proof=Get-Content (Join-Path $ResultsDirectory 'target\compiler.json') -Raw|ConvertFrom-Json
$work=Get-Content (Join-Path $ResultsDirectory 'work-proof.json') -Raw|ConvertFrom-Json
$cases=Get-Content (Join-Path $ResultsDirectory 'cases.json') -Raw|ConvertFrom-Json
$target=@($cases|Where-Object name -eq 'target')[0]
$identity=@{pid=$proof.identity.pid;imagePath=$proof.identity.executablePath;birthUtc=$proof.identity.startUtc
    commandContains="-pipename:$(Get-PairedPipe $proof.identity.commandEvidence)";assembly='';knownMethod='';sdkRoot=$SdkRoot}
Write-CpuJson $identity (Join-Path $capture 'target-identity.json')
$windows=@{
    command=@{name='command';startUtc=$target.command.startUtc;endUtc=$target.command.exitUtc;cpuSeconds=$target.cpuDeltaSeconds}
    csc=@{name='main-csc';startUtc=$work.mainCsc.startedUtc;endUtc=$work.mainCsc.finishedUtc;cpuSeconds=-1}
}
$hostPath=Join-Path $SdkRoot 'dotnet.exe'
$decoder=Join-Path $ToolsDirectory 'CpuDecoder.dll'
$expand=Start-CpuProcess $state.tool @('expandDiagSession',$state.output) (Join-Path $capture 'expand')
$r=Complete-CpuProcess $expand 30
if($r.exitCode -ne 0 -or $r.timedOut){throw 'Standard archive expansion failed.'}
foreach($key in $windows.Keys)
{
    $path=Join-Path $capture "window-$key.json"
    Write-CpuJson @($windows[$key]) $path
    $child=Start-CpuProcess $hostPath @($decoder,$state.output,(Join-Path $capture 'target-identity.json'),$path,(Join-Path $capture "decode-$key")) (Join-Path $capture "decode-$key")
    $r=Complete-CpuProcess $child 120
    if($r.exitCode -ne 0 -or $r.timedOut){throw "Owned $key CPU decode failed."}
}
$quality=Start-CpuProcess $hostPath @($decoder,'etl-quality',(Join-Path $capture 'decode-command\expanded.etl'),(Join-Path $capture 'quality')) (Join-Path $capture 'quality')
$r=Complete-CpuProcess $quality 120
if($r.exitCode -ne 0 -or $r.timedOut){throw 'Strict ETW quality processing failed.'}
$symbols=Start-CpuProcess $hostPath @($decoder,'symbols',(Join-Path $capture 'decode-csc\owned-recording.etlx'),
    (Join-Path $capture 'target-identity.json'),(Join-Path $capture 'window-csc.json'),$SdkRoot,
    (Join-Path $capture 'symbols-csc')) (Join-Path $capture 'symbols-csc')
$symbolReceipt=Complete-CpuProcess $symbols 180
if($symbolReceipt.exitCode -ne 0 -or $symbolReceipt.timedOut){throw 'Exact owned runtime/Roslyn symbol inspection incomplete.'}
$q=Get-Content (Join-Path $capture 'quality\etl-quality.json') -Raw|ConvertFrom-Json
$cpu=Get-Content (Join-Path $capture 'decode-csc\cpu.json') -Raw|ConvertFrom-Json
$pass=$q.completed -and $q.strictConversionCompleted -and $q.headers.Count -eq 1 -and
    $q.headers[0].EventsLost -eq 0 -and $q.headers[0].BuffersLost -eq 0 -and
    ([DateTime]$q.headers[0].endUtc) -ge ([DateTime]$work.mainCsc.finishedUtc) -and
    $cpu.phases[0].samples -gt 0 -and $cpu.phases[0].capHits -eq 0
Write-CpuJson @{qualifiedFileAndSampleGate=$pass;quality=$q;mainCscCoverage=$cpu.phases
    vendorUpstreamDrop='unknown, not zero';stackUnwindCompleteness='not separately exposed'
    statistical=$true;requestExclusive=$false;cpuSecondsForCscWindow='unavailable: command CPU endpoint delta only'
    attribution='Exclusive observed leaf samples and inclusive contexts with unknown denominator retained; no wall-gain inference'
    nativeMethodCoverage=Get-Content (Join-Path $capture 'symbols-csc\after.json') -Raw|ConvertFrom-Json
    symbolMatches=Get-Content (Join-Path $capture 'symbols-csc\lookup-results.json') -Raw|ConvertFrom-Json
    granularity='Use only resolved leaf/module identities, retain unknown denominator. Full native/compiler coverage not implied by probe.'
    fullCommandWindow=$windows.command;mainCscWindow=$windows.csc} (Join-Path $capture 'qualified-gate.json')
if(-not $pass){throw 'Prospective qualified ETW/sample gate failed; retain output, no retry.'}
