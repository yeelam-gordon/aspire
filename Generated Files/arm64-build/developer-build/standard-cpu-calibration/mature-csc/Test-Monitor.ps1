[CmdletBinding()]
param([Parameter(Mandatory)][string]$Output)
. (Join-Path $PSScriptRoot 'Monitor.ps1')
. (Join-Path $PSScriptRoot 'Failure.ps1')
. (Join-Path $PSScriptRoot 'Retention.ps1')
if(Test-Path $Output){throw 'Refusing monitor proof overwrite.'}
$null=New-Item -ItemType Directory -Path $Output
$fake=Join-Path $PSScriptRoot 'Fake-MonitorCli.ps1'
$self=Get-Process -Id $PID
$results=@()
foreach($mode in @('success','wrongGuid','substringGuid','missing','early0','early7','collision','stderr','later7','stopWrong','stopTimeout','drain','workFailure','foreignTarget','foreignTargetPath','foreignMonitor','foreignMonitorPath','prefixPersist','stdoutPersist','readyReceiptPersist','monitorReceiptPersist'))
{
    $caseRoot=Join-Path $Output $mode
    $readinessFault=$mode -in @('prefixPersist','readyReceiptPersist')
    $completionFault=$mode -in @('stdoutPersist','monitorReceiptPersist')
    $root=if($readinessFault -or $completionFault){Join-Path $caseRoot 'evidence\measurements\capture'}else{$caseRoot}
    $null=New-Item -ItemType Directory -Path $root
    $state=@{sessionId=[Guid]::NewGuid().ToString();started=$false;stopAttempted=$false;tool=$self.Path;directory=$root
        output=(Join-Path $root 'mature-csc.diagsession')
        identity=@{pid=$PID;startTicks=$self.StartTime.ToUniversalTime().Ticks;executablePath=$self.Path}}
    if($mode -ceq 'foreignTarget'){$state.identity.startTicks++}
    if($mode -ceq 'foreignTargetPath'){$state.identity.executablePath+='.foreign'}
    $primary=$null;$secondary=@();$work=$null;$birth=$null;$foreignRefused=$false;$breakpoint=$null;$faultProof=$null
    try
    {
        try
        {
            Begin-MatureMonitor $state @('-NoProfile','-File',$fake,$root,$mode,'start',$state.sessionId,"/attach:$PID",'/monitor')
            $birth=$state.monitor.birthTicks
            if($mode -ceq 'foreignMonitor'){$state.monitor.birthTicks++}
            if($mode -ceq 'foreignMonitorPath'){$state.monitor.executable+='.foreign'}
            if($readinessFault)
            {
                # Insert a real path collision only on a read that contains the
                # exact valid Running ACK, not an earlier banner/header chunk.
                $script=Join-Path $PSScriptRoot 'Monitor.ps1'
                $needle=if($mode -ceq 'prefixPersist'){'[IO.File]::WriteAllText("$($monitor.prefix).stdout-prefix.log",$prefix)'}else{'                    Write-CpuJson $State.startReceipt "$($monitor.prefix).receipt.json"'}
                $line=@(Select-String -LiteralPath $script -SimpleMatch $needle)[0].LineNumber
                if($line -le 0){throw 'Ready-prefix persistence location missing.'}
                $breakpoint=Set-PSBreakpoint -Script $script -Line $line -Action {
                    if(Test-MatureStatusText $prefix $State.sessionId 'Running')
                    {
                        $suffix=if($State.directory -like '*\readyReceiptPersist\*'){'receipt.json'}else{'stdout-prefix.log'}
                        $path="$($monitor.prefix).$suffix"
                        if([IO.File]::Exists($path)){[IO.File]::Copy($path,"$path.before");[IO.File]::Delete($path)}
                        $null=[IO.Directory]::CreateDirectory($path)
                        @{validRunningInMemory=$true;callerOwnedBeforeIo=$State.started;readyBeforeIo=$State.startReceipt.ready
                            guid=$State.sessionId;monitorAlive=-not$monitor.process.HasExited}|
                            ConvertTo-Json|Set-Content (Join-Path $State.directory 'fault-injection.json')
                    }
                }
            }
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
                if($completionFault)
                {
                    if(-not$state.monitor.process.WaitForExit(2000)){throw 'Fake monitor did not exit before completion fault injection.'}
                    $path=if($mode -ceq 'stdoutPersist'){"$($state.monitor.prefix).stdout.log"}else{Join-Path $root 'monitor-final.receipt.json'}
                    $null=[IO.Directory]::CreateDirectory($path)
                    @{monitorAlreadyExited=$true;observedExitCode=$state.monitor.process.ExitCode}|
                        ConvertTo-Json|Set-Content (Join-Path $root 'fault-injection.json')
                }
                try{Confirm-MatureMonitorCompletion $state 1 1}
                catch
                {
                    if($null -eq $primary){$primary=$_}else{$secondary+=$_.ToString()}
                    $null=Write-MatureFailure $_ (Join-Path $root 'errors') 'monitor-completion' 'primary' @()
                }
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
        if($null -ne $breakpoint){Remove-PSBreakpoint -Breakpoint $breakpoint}
        if($state.monitor)
        {
            if($mode -in @('foreignMonitor','foreignMonitorPath'))
            {
                if($state.monitor.process.HasExited){throw 'Foreign monitor identity was incorrectly cleaned up.'}
                $state.monitor.birthTicks=$birth
                $state.monitor.executable=$self.Path
                Stop-ExactCpuProcess $state.monitor
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
    if(-not$reject -and -not$readinessFault -and ($null -eq $work -or -not$state.started -or -not$state.stopAttempted -or
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
    if($readinessFault -or $completionFault)
    {
        $injection=Get-Content (Join-Path $root 'fault-injection.json') -Raw|ConvertFrom-Json
        $failedPath=switch($mode)
        {
            'prefixPersist'{"$($state.monitor.prefix).stdout-prefix.log"}
            'readyReceiptPersist'{"$($state.monitor.prefix).receipt.json"}
            'stdoutPersist'{"$($state.monitor.prefix).stdout.log"}
            'monitorReceiptPersist'{Join-Path $root 'monitor-final.receipt.json'}
        }
        $expectedFunction=if($readinessFault){'Wait-MatureMonitorReady'}else{'Complete-MatureMonitor'}
        $stopCalls=@(Get-Content (Join-Path $root 'stop-invocations.jsonl'))
        if($null -eq $primary -or $primary.Exception.Message -notlike "*$failedPath*" -or
            $primary.ScriptStackTrace -notmatch $expectedFunction -or -not$state.started -or -not$state.stopAcknowledged -or
            $stopCalls.Count -ne 1 -or $stopCalls[0] -cne $state.sessionId -or $state.monitorReceipt.exitCode -ne 0)
        {throw "Filesystem fault erased original error, ownership or exactly-once stop: $mode"}
        if($readinessFault -and ($null -ne $work -or -not$injection.callerOwnedBeforeIo -or
            -not$injection.validRunningInMemory -or -not$injection.readyBeforeIo -or -not$injection.monitorAlive))
        {throw 'Prefix fault was not injected on a validated Running read before work.'}
        if($completionFault -and (-not$injection.monitorAlreadyExited -or
            -not$state.monitorReceipt.exitObserved -or -not$state.monitorReceipt.outputComplete -or
            $state.monitorReceipt.persistenceComplete -or $state.monitorReceipt.captureComplete -or
            -not$state.monitorReceipt.resourcesClosed -or $state.monitorReceipt.persistenceErrors.Count -ne 1))
        {throw 'Completion log fault erased observed exit/drains or became success-shaped.'}
        $stderrPath=Join-Path $root 'start.stderr.log'
        $exclusive=[IO.FileStream]::new($stderrPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $exclusive.Dispose()
        $closedReaders=0
        foreach($reader in @($state.monitor.process.StandardOutput,$state.monitor.process.StandardError))
        {
            try{$null=$reader.Peek()}
            catch
            {
                if($_.Exception -is [ObjectDisposedException] -or $_.Exception.InnerException -is [ObjectDisposedException])
                {$closedReaders++;continue}
                throw
            }
        }
        if($closedReaders -ne 2 -or $state.monitor.stderrFile.CanWrite){throw 'Own redirected readers/stderr writer leaked after persistence fault.'}
        Write-MatureClosedJson @{syntheticFixture=$true;failure=$primary.ToString();completedCases=0;restorationPassed=$true
            secondaryFailures=$secondary;reportingFailures=@()} (Join-Path $caseRoot 'evidence\measurements\final-state.json')
        $outputs=Join-Path $caseRoot 'stage.outputs'
        $hadOutput=Test-Path Env:GITHUB_OUTPUT;$oldOutput=$env:GITHUB_OUTPUT
        $stageFailed=$false
        try
        {
            $env:GITHUB_OUTPUT=$outputs
            try{& (Join-Path $PSScriptRoot 'Stage-Retention.ps1') -EvidenceRoot (Join-Path $caseRoot 'evidence') -StageRoot (Join-Path $caseRoot 'retained')}
            catch{$stageFailed=$_.Exception.Message -like 'P49 retention incomplete:*'}
        }
        finally{if($hadOutput){$env:GITHUB_OUTPUT=$oldOutput}else{Remove-Item Env:GITHUB_OUTPUT}}
        $staged=Get-Content (Join-Path $caseRoot 'retained\metadata\retention-manifest.json') -Raw|ConvertFrom-Json
        if($mode -ceq 'monitorReceiptPersist')
        {$savedReceipt=(Get-Content (Join-Path $staged.metadataRoot 'measurements\capture\session-final.json') -Raw|ConvertFrom-Json).monitorReceipt}
        else{$savedReceipt=Get-Content (Join-Path $staged.metadataRoot 'measurements\capture\monitor-final.receipt.json') -Raw|ConvertFrom-Json}
        if(-not$stageFailed -or $staged.stagePassed -or $staged.rawRecordingComplete -or -not$staged.provisionalRawStaged -or
            $savedReceipt.exitCode -ne 0 -or -not$savedReceipt.outputComplete -or
            ((Get-Content $outputs) -join "`n") -cne "raw_files_available=true`nraw_recording_complete=false" -or
            -not[Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes($stderrPath),
                [IO.File]::ReadAllBytes((Join-Path $staged.metadataRoot 'measurements\capture\start.stderr.log'))))
        {throw 'Persistence-fault diagnostics/receipt/stderr were discarded or raw promoted to complete.'}
        $faultProof=@{passed=$true;injection=$injection;originalException=$primary.Exception.ToString();originalStack=$primary.ScriptStackTrace
            stopCalls=$stopCalls;work=$work;stderrExclusivelyReadable=$true;redirectedReadersClosed=2
            receipt=$state.monitorReceipt;stage=$staged;stageOutputs=@(Get-Content $outputs)}
        Write-MatureClosedJson $faultProof (Join-Path $caseRoot 'fault-proof.json')
    }
    $results+=@{mode=$mode;passed=$true;ready=$state.started;work=$work;stopAttempted=$state.stopAttempted
        stopAcknowledged=$state.stopAcknowledged;monitorReceipt=$state.monitorReceipt
        primary=if($primary){$primary.ToString()}else{$null};secondary=$secondary;foreignCleanupRefused=$foreignRefused;filesystemFault=$faultProof}
}
Write-MatureClosedJson @{passed=$true;cases=$results;actualCollectors=0;servicesTouched=0;githubCaptureContextFaked=$false
    productionBounds=@{readinessSeconds=12;stopSeconds=30;monitorExitSeconds=30;drainSeconds=5}
    fixtureBounds='Readiness 4s (missing ACK .5s), stop/exit/drain 1s; no production timeout extended.'} (Join-Path $Output 'tests.json')
