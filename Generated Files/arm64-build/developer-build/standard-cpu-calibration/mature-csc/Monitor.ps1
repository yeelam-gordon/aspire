. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Helpers.ps1')

function Save-MatureMonitorState($State,[string]$Name)
{
    $saved=@{}
    foreach($key in $State.Keys|Where-Object {$_ -ne 'monitor'}){$saved[$key]=$State[$key]}
    Write-CpuJson $saved (Join-Path $State.directory $Name)
}

function Assert-MatureMonitorTarget($Identity)
{
    Assert-ExactCpuProcess ([pscustomobject]@{pid=$Identity.pid;birthTicks=$Identity.startTicks;executable=$Identity.executablePath})
}

function Test-MatureStatusText([string]$Text,[string]$SessionId,[string]$Status)
{
    # Installed standard CLI emits complete lines:
    #   Session <guid>: {<same-guid>}\r\n  Running\r\n
    # Stop emits the same header followed by "Stopped". Reject other IDs,
    # errors/collisions and unknown complete lines, not substring matches.
    $header=$false;$found=$false
    foreach($match in [regex]::Matches($Text,'[^\r\n]*(?:\r?\n)'))
    {
        $line=$match.Value.Trim()
        if($line -ceq '' -or $line -ceq 'Microsoft (R) VS Standard Collector'){continue}
        if($line -cmatch '^Session ([0-9a-fA-F-]{36}): \{([0-9a-fA-F-]{36})\}$')
        {
            if($Matches[1] -ine $SessionId -or $Matches[2] -ine $SessionId)
            {throw 'Standard CLI ACK has a foreign session GUID.'}
            $header=$true
        }
        elseif($header -and $line -ceq $Status -and -not$found){$found=$true}
        else{throw "Unexpected standard CLI status/error/collision line: $line"}
    }
    return $found
}

function Read-MatureStderr($Monitor)
{
    $s=[IO.FileStream]::new("$($Monitor.prefix).stderr.log",[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    $r=[IO.StreamReader]::new($s)
    try{return $r.ReadToEnd()}finally{$r.Dispose()}
}

function Begin-MatureMonitor($State,[string[]]$Arguments)
{
    Assert-MatureMonitorTarget $State.identity
    $index=[Array]::IndexOf($Arguments,'start')
    if($index -lt 0 -or $Arguments[$index+1] -cne $State.sessionId -or
        $Arguments -cnotcontains '/monitor' -or $Arguments -cnotcontains "/attach:$($State.identity.pid)")
    {throw 'Monitor argv must bind the exact owned session and target with explicit /monitor.'}
    $monitor=Start-CpuProcess $State.tool $Arguments (Join-Path $State.directory 'start') -DeferStreamReads
    $monitor|Add-Member prefixText ([Text.StringBuilder]::new())
    $monitor|Add-Member pendingRead $null
    $monitor|Add-Member buffer ([char[]]::new(1024))
    $monitor|Add-Member stderrFile $null
    $State.monitor=$monitor
    $monitor.stderrFile=[IO.FileStream]::new("$($monitor.prefix).stderr.log",[IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,[IO.FileShare]::Read,1,[IO.FileOptions]::Asynchronous)
    # Drain stderr concurrently without a PowerShell callback/runspace. The
    # unbuffered private file also exposes startup errors before readiness.
    $monitor.stderr=$monitor.process.StandardError.BaseStream.CopyToAsync($monitor.stderrFile)
    $State.startReceipt=@{ready=$false;sessionId=$State.sessionId;pid=$monitor.pid;birthTicks=$monitor.birthTicks
        executable=$monitor.executable;arguments=$monitor.arguments;commandIndex=$index;startedUtc=$monitor.startedUtc.ToString('O')}
    Write-CpuJson $State.startReceipt "$($monitor.prefix).receipt.json"
}

function Wait-MatureMonitorReady($State,[double]$TimeoutSeconds)
{
    $monitor=$State.monitor
    $timer=[Diagnostics.Stopwatch]::StartNew()
    try
    {
        while($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
        {
            Assert-ExactCpuProcess $monitor
            if(-not[string]::IsNullOrWhiteSpace((Read-MatureStderr $monitor))){throw 'Standard monitor stderr before readiness.'}
            if($null -eq $monitor.pendingRead)
            {$monitor.pendingRead=$monitor.process.StandardOutput.ReadAsync($monitor.buffer,0,$monitor.buffer.Length)}
            if($monitor.pendingRead.IsCompleted)
            {
                $count=$monitor.pendingRead.GetAwaiter().GetResult()
                $monitor.pendingRead=$null
                if($count -eq 0){throw 'Monitor stdout ended before live Running readiness.'}
                $null=$monitor.prefixText.Append($monitor.buffer,0,$count)
                $prefix=$monitor.prefixText.ToString()
                $ready=Test-MatureStatusText $prefix $State.sessionId 'Running'
                if($ready)
                {
                    Assert-ExactCpuProcess $monitor
                    Assert-MatureMonitorTarget $State.identity
                    # The validated ACK is already in memory. Establish the
                    # stop obligation before ANY recording I/O can fail.
                    $State.started=$true
                    $State.startReceipt.ready=$true
                    $State.startReceipt.monitorAliveAtReady=$true
                    $State.startReceipt.targetIdentity=$State.identity
                    $State.startReceipt.readyUtc=[DateTime]::UtcNow.ToString('O')
                    $State.startReceipt.ackText=$prefix
                    # No outstanding incremental stdout read remains. Only now
                    # hand the rest of the same stream to ReadToEndAsync.
                    $monitor.stdout=$monitor.process.StandardOutput.ReadToEndAsync()
                }
                if(-not[string]::IsNullOrWhiteSpace((Read-MatureStderr $monitor))){throw 'Standard monitor stderr at readiness.'}
                [IO.File]::WriteAllText("$($monitor.prefix).stdout-prefix.log",$prefix)
                if($ready)
                {
                    Write-CpuJson $State.startReceipt "$($monitor.prefix).receipt.json"
                    return
                }
            }
            Start-Sleep -Milliseconds 10
        }
        throw 'Exact live Running readiness timed out; no session-stop authority.'
    }
    catch
    {
        $original=$_
        $State.startReceipt.failure=$original.ToString()
        $State.startReceipt.endedUtc=[DateTime]::UtcNow.ToString('O')
        try{Write-CpuJson $State.startReceipt "$($monitor.prefix).receipt.json"}
        catch{[Console]::Error.WriteLine("Secondary readiness-receipt persistence failure: $($_.Exception)")}
        throw $original
    }
}

function Complete-MatureMonitor($State,[int]$ExitTimeoutSeconds,[int]$DrainTimeoutSeconds)
{
    $monitor=$State.monitor
    $original=$null
    $persistenceErrors=[Collections.Generic.List[object]]::new()
    $cleanupErrors=[Collections.Generic.List[object]]::new()
    $drainErrors=[Collections.Generic.List[object]]::new()
    $receipt=@{pid=$monitor.pid;birthTicks=$monitor.birthTicks;executable=$monitor.executable;arguments=$monitor.arguments
        startedUtc=$monitor.startedUtc.ToString('O');exitTimeoutSeconds=$ExitTimeoutSeconds;drainTimeoutSeconds=$DrainTimeoutSeconds
        exitObserved=$false;exitCode=$null;timedOut=$null;outputComplete=$false
        persistenceComplete=$false;resourcesClosed=$false;captureComplete=$false}
    $State.monitorReceipt=$receipt
    try
    {
        $exited=$monitor.process.WaitForExit($ExitTimeoutSeconds*1000)
        $receipt.timedOut=-not$exited
        if(-not$exited){Stop-ExactCpuProcess $monitor}
        $receipt.exitObserved=$monitor.process.HasExited
        if($receipt.exitObserved){$receipt.exitCode=$monitor.process.ExitCode}
        $complete=$true
        $tail=''
        try
        {
            if($null -ne $monitor.pendingRead)
            {
                $count=$monitor.pendingRead.WaitAsync([TimeSpan]::FromSeconds($DrainTimeoutSeconds)).GetAwaiter().GetResult()
                $null=$monitor.prefixText.Append($monitor.buffer,0,$count)
                $monitor.pendingRead=$null
            }
            if($null -eq $monitor.stdout){$monitor.stdout=$monitor.process.StandardOutput.ReadToEndAsync()}
            $tail=$monitor.stdout.WaitAsync([TimeSpan]::FromSeconds($DrainTimeoutSeconds)).GetAwaiter().GetResult()
        }
        catch{$complete=$false;$drainErrors.Add(@{stream='stdout';error=$_.ToString()})}
        try{$monitor.stderr.WaitAsync([TimeSpan]::FromSeconds($DrainTimeoutSeconds)).GetAwaiter().GetResult();$monitor.stderrFile.Flush($true)}
        catch{$complete=$false;$drainErrors.Add(@{stream='stderr';error=$_.ToString()})}
        # Observations are authoritative in caller memory BEFORE recording I/O.
        # A failed log write must not erase a successful exit/drain observation.
        $receipt.outputComplete=$complete
        $receipt.drainErrors=@($drainErrors.ToArray())
        try{[IO.File]::WriteAllText("$($monitor.prefix).stdout.log",$monitor.prefixText.ToString()+$tail)}
        catch
        {
            $original=$_
            $persistenceErrors.Add(@{phase='monitor-stdout';error=$_.ToString();exception=$_.Exception.ToString();stack=$_.ScriptStackTrace})
            [Console]::Error.WriteLine("P49 monitor stdout persistence failure: $($_.Exception)")
            [Console]::Error.WriteLine($_.ScriptStackTrace)
        }
    }
    catch
    {
        if($null -eq $original){$original=$_}
        else{$cleanupErrors.Add(@{resource='completion';error=$_.ToString();exception=$_.Exception.ToString();stack=$_.ScriptStackTrace})}
    }
    finally
    {
        foreach($resource in @(@{name='stderr-file';value=$monitor.stderrFile},
            @{name='stdout-reader';value=$monitor.process.StandardOutput},@{name='stderr-reader';value=$monitor.process.StandardError}))
        {
            if($null -eq $resource.value){continue}
            try{$resource.value.Dispose()}
            catch
            {
                $cleanupErrors.Add(@{resource=$resource.name;error=$_.ToString();exception=$_.Exception.ToString();stack=$_.ScriptStackTrace})
                [Console]::Error.WriteLine("P49 secondary monitor stream-disposal failure ($($resource.name)): $($_.Exception)")
                if($null -eq $original){$original=$_}
            }
        }
    }
    $receipt.endedUtc=[DateTime]::UtcNow.ToString('O')
    $receipt.resourcesClosed=$cleanupErrors.Count -eq 0
    $receipt.cleanupErrors=@($cleanupErrors.ToArray())
    $receipt.persistenceErrors=@($persistenceErrors.ToArray())
    $receipt.persistenceComplete=$persistenceErrors.Count -eq 0
    $receipt.captureComplete=$receipt.outputComplete -and $receipt.resourcesClosed -and $receipt.persistenceComplete
    try{Write-CpuJson $receipt (Join-Path $State.directory 'monitor-final.receipt.json')}
    catch
    {
        $persistenceErrors.Add(@{phase='monitor-receipt';error=$_.ToString();exception=$_.Exception.ToString();stack=$_.ScriptStackTrace})
        $receipt.persistenceErrors=@($persistenceErrors.ToArray())
        $receipt.persistenceComplete=$false;$receipt.captureComplete=$false
        [Console]::Error.WriteLine("P49 secondary monitor receipt persistence failure: $($_.Exception)")
        if($null -eq $original){$original=$_}
    }
    if($null -ne $original){throw $original}
    return $receipt
}

function Invoke-MatureSessionStop($State,[string[]]$Arguments,[int]$TimeoutSeconds)
{
    if(-not$State.started -or -not$State.startReceipt.ready -or $State.stopAttempted)
    {throw 'Only this proved Running session may be stopped once.'}
    $index=[Array]::IndexOf($Arguments,'stop')
    if($index -lt 0 -or $Arguments[$index+1] -cne $State.sessionId -or $Arguments -cnotcontains "/output:$($State.output)")
    {throw 'Stop argv does not match owned session/output.'}
    $State.stopAttempted=$true
    $stop=Start-CpuProcess $State.tool $Arguments (Join-Path $State.directory 'stop')
    $State.stopReceipt=Complete-CpuProcess $stop $TimeoutSeconds
    $State.stopReceipt.commandIndex=$index
    $State.stopAcknowledged=$false
    if($State.stopReceipt.timedOut -or -not$State.stopReceipt.outputComplete -or $State.stopReceipt.exitCode -ne 0)
    {throw 'Owned standard stop failed/timed out/incomplete.'}
    $text=Get-Content (Join-Path $State.directory 'stop.stdout.log') -Raw
    if(-not(Test-MatureStatusText $text $State.sessionId 'Stopped')){throw 'Exact owned Stopped ACK missing.'}
    if(-not[string]::IsNullOrWhiteSpace((Get-Content (Join-Path $State.directory 'stop.stderr.log') -Raw))){throw 'Owned stop stderr was nonempty.'}
    $State.stopAcknowledged=$true
}

function Confirm-MatureMonitorCompletion($State,[int]$ExitTimeoutSeconds,[int]$DrainTimeoutSeconds)
{
    try
    {
        $receipt=Complete-MatureMonitor $State $ExitTimeoutSeconds $DrainTimeoutSeconds
        $stderr=[string](Get-Content (Join-Path $State.directory 'start.stderr.log') -Raw)
        if(-not$State.stopAcknowledged -or $receipt.timedOut -or -not$receipt.captureComplete -or $receipt.exitCode -ne 0 -or
            -not[string]::IsNullOrWhiteSpace($stderr))
        {throw 'Owned monitor/stop finalization incomplete or failed; no finalized recording eligibility.'}
    }
    catch
    {
        $original=$_
        try{Save-MatureMonitorState $State 'session-final.json'}
        catch
        {
            $State.observabilityErrors=@($State.observabilityErrors)+@(@{phase='monitor-final-state';error=$_.ToString();stack=$_.ScriptStackTrace})
            [Console]::Error.WriteLine("Secondary monitor-state persistence failure: $($_.Exception)")
        }
        throw $original
    }
    Save-MatureMonitorState $State 'session-final.json'
}
