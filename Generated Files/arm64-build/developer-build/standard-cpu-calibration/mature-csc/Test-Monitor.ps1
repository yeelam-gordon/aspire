[CmdletBinding()]
param([Parameter(Mandatory)][string]$Output)
. (Join-Path $PSScriptRoot 'Monitor.ps1')
. (Join-Path $PSScriptRoot 'Failure.ps1')
if(Test-Path $Output){throw 'Refusing monitor proof overwrite.'}
$null=New-Item -ItemType Directory -Path $Output
$fake=Join-Path $PSScriptRoot 'Fake-MonitorCli.ps1'
$self=Get-Process -Id $PID
$results=@()
foreach($mode in @('success','wrongGuid','substringGuid','missing','early0','early7','collision','stderr','later7','stopWrong','stopTimeout','drain','workFailure','foreignTarget','foreignTargetPath','foreignMonitor','foreignMonitorPath'))
{
    $root=Join-Path $Output $mode;$null=New-Item -ItemType Directory -Path $root
    $state=@{sessionId=[Guid]::NewGuid().ToString();started=$false;stopAttempted=$false;tool=$self.Path;directory=$root
        output=(Join-Path $root 'mature-csc.diagsession')
        identity=@{pid=$PID;startTicks=$self.StartTime.ToUniversalTime().Ticks;executablePath=$self.Path}}
    if($mode -ceq 'foreignTarget'){$state.identity.startTicks++}
    if($mode -ceq 'foreignTargetPath'){$state.identity.executablePath+='.foreign'}
    $primary=$null;$secondary=@();$work=$null;$birth=$null;$foreignRefused=$false
    try
    {
        try
        {
            Begin-MatureMonitor $state @('-NoProfile','-File',$fake,$root,$mode,'start',$state.sessionId,"/attach:$PID",'/monitor')
            $birth=$state.monitor.birthTicks
            if($mode -ceq 'foreignMonitor'){$state.monitor.birthTicks++}
            if($mode -ceq 'foreignMonitorPath'){$state.monitor.executable+='.foreign'}
            Wait-MatureMonitorReady $state $(if($mode -ceq 'missing'){0.5}else{4})
            Assert-ExactCpuProcess $state.monitor
            $work=@{utc=[DateTime]::UtcNow.ToString('O');monitorAlive=$true;readyUtc=$state.startReceipt.readyUtc}
            Write-MatureClosedJson $work (Join-Path $root 'work.marker')
            if($mode -ceq 'workFailure'){throw 'ORIGINAL_WORK_FAILURE'}
        }
        catch
        {
            $primary=$_
            $null=Write-MatureFailure $_ (Join-Path $root 'errors') 'readiness-or-work' 'primary' @()
        }
        finally
        {
            if($state.started)
            {
                try{Invoke-MatureSessionStop $state @('-NoProfile','-File',$fake,$root,$mode,'stop',$state.sessionId,"/output:$($state.output)") 1}
                catch{if($null -eq $primary){$primary=$_}else{$secondary+=$_.ToString()}}
                try{Confirm-MatureMonitorCompletion $state 1 1}
                catch{if($null -eq $primary){$primary=$_}else{$secondary+=$_.ToString()}}
            }
            elseif($state.monitor)
            {
                try{$null=Complete-MatureMonitor $state 0 1}
                catch{$foreignRefused=$mode -in @('foreignMonitor','foreignMonitorPath');$secondary+=$_.ToString()}
            }
        }
    }
    finally
    {
        if($state.monitor)
        {
            if($mode -in @('foreignMonitor','foreignMonitorPath'))
            {
                if($state.monitor.process.HasExited){throw 'Foreign monitor identity was incorrectly cleaned up.'}
                $state.monitor.birthTicks=$birth
                $state.monitor.executable=$self.Path
                $null=Complete-MatureMonitor $state 0 1
            }
            elseif(-not$state.monitor.process.HasExited){Stop-ExactCpuProcess $state.monitor}
        }
        $holderPath=Join-Path $root 'holder.json'
        if(Test-Path $holderPath)
        {
            $holder=Get-Content $holderPath -Raw|ConvertFrom-Json
            [IO.File]::WriteAllText((Join-Path $root 'release.signal'),'release')
            $p=Get-Process -Id $holder.pid -ErrorAction SilentlyContinue
            if($null -ne $p -and -not$p.WaitForExit(2000)){Stop-ExactCpuProcess $holder}
        }
    }
    Write-MatureClosedJson @{mode=$mode;primary=if($primary){$primary.Exception.ToString()}else{$null}
        stack=if($primary){$primary.ScriptStackTrace}else{$null};secondary=$secondary
        stopAcknowledged=$state.stopAcknowledged;monitorReceipt=$state.monitorReceipt;work=$work} (Join-Path $root 'case-state.json')
    $reject=$mode -in @('wrongGuid','substringGuid','missing','early0','early7','collision','stderr','foreignTarget','foreignTargetPath','foreignMonitor','foreignMonitorPath')
    if($reject -and ($state.started -or $state.stopAttempted -or $null -ne $work -or $null -eq $primary))
    {throw "Rejected readiness incorrectly authorized work/stop: $mode"}
    if(-not$reject -and ($null -eq $work -or -not$state.started -or -not$state.stopAttempted -or
        ([DateTime]$work.utc) -lt ([DateTime]$state.startReceipt.readyUtc)))
    {throw "Work/stop did not follow live exact Running readiness: $mode"}
    if($mode -ceq 'success' -and ($null -ne $primary -or -not$state.stopAcknowledged -or $state.monitorReceipt.exitCode -ne 0 -or -not$state.monitorReceipt.outputComplete))
    {throw 'Successful fake monitor lifecycle failed.'}
    if($mode -ceq 'success')
    {
        $stdout=Get-Content (Join-Path $root 'start.stdout.log') -Raw
        if(([regex]::Matches($stdout,'(?m)^\s*Running\s*$')).Count -ne 1 -or
            $stdout -notmatch 'WORK_OBSERVED_AFTER_RUNNING')
        {throw 'Incremental prefix and remaining stdout were lost, duplicated or read concurrently.'}
    }
    if($mode -cne 'success' -and $null -eq $primary){throw "Negative lifecycle accepted: $mode"}
    if($mode -ceq 'workFailure' -and ($primary.Exception.Message -cne 'ORIGINAL_WORK_FAILURE' -or -not$state.stopAcknowledged -or $state.monitorReceipt.exitCode -ne 0))
    {throw 'Caller-owned readiness state did not survive the work exception.'}
    if($mode -ceq 'drain' -and $state.monitorReceipt.outputComplete){throw 'Real inherited-pipe drain failure was not detected.'}
    if($mode -in @('foreignMonitor','foreignMonitorPath') -and -not$foreignRefused){throw 'Foreign monitor cleanup was not refused.'}
    if($null -ne $work -and ([DateTime]$work.utc) -ge ([DateTime]$state.monitorReceipt.endedUtc)){throw 'Work marker followed monitor completion.'}
    $results+=@{mode=$mode;passed=$true;ready=$state.started;work=$work;stopAttempted=$state.stopAttempted
        stopAcknowledged=$state.stopAcknowledged;monitorReceipt=$state.monitorReceipt
        primary=if($primary){$primary.ToString()}else{$null};secondary=$secondary;foreignCleanupRefused=$foreignRefused}
}
Write-MatureClosedJson @{passed=$true;cases=$results;actualCollectors=0;servicesTouched=0;githubCaptureContextFaked=$false
    productionBounds=@{readinessSeconds=12;stopSeconds=30;monitorExitSeconds=30;drainSeconds=5}
    fixtureBounds='Readiness 4s (missing ACK .5s), stop/exit/drain 1s; no production timeout extended.'} (Join-Path $Output 'tests.json')
