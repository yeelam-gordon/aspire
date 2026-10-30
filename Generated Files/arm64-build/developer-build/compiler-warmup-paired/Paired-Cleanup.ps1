function Get-PairedCleanupReceipt($Identity)
{
    $key = "$($Identity.pid):$($Identity.startTicks)"
    if (-not $cleanupByKey.ContainsKey($key))
    {
        $receipt = @{ identity = $Identity; exitConfirmed = $false
            probes = [Collections.Generic.List[object]]::new()
            failures = [Collections.Generic.List[object]]::new() }
        $cleanupByKey[$key] = $receipt
        $cleanup.Add($receipt)
    }
    return $cleanupByKey[$key]
}

function Save-PairedCleanup
{
    Write-PairedJson @($cleanup.ToArray()) (Join-Path $ResultsDirectory 'cleanup.json')
}

function Add-PairedCleanupFailure($Receipt, [string]$Phase, $Failure)
{
    $Receipt.error = $Failure.ToString()
    $Receipt.failures.Add(@{ phase = $Phase; error = $Failure.ToString()
        stack = $Failure.ScriptStackTrace; utc = [DateTime]::UtcNow.ToString('O') })
}

function Read-PairedOwnedState($Identity, $Receipt,
    [ValidateSet('authority','post-ack-observation','absence')][string]$Phase)
{
    $key = "$($Identity.pid):$($Identity.startTicks)"
    $diagnostic = Get-ExitDiagnostic $Identity
    $process = $null
    try { $process = [Diagnostics.Process]::GetProcessById([int]$Identity.pid) }
    catch [ArgumentException] { $process = $null }
    # Only ArgumentException means a nonexistent, already validated positive PID.
    # Permission/query/property errors must propagate, not become false absence.
    try { $runtime = Get-PairedRuntimeFields $process }
    finally { if ($process) { $process.Dispose() } }
    $acknowledged = $shutdownRequests.ContainsKey($key) -and $shutdownRequests[$key].acknowledged
    $parentKey = $ownedParentProofs[$key]
    $parentReset = [bool]($parentKey -and $stopRequests.ContainsKey($parentKey) -and $stopRequests[$parentKey].stopIssued)
    $probe = @{ utc = [DateTime]::UtcNow.ToString('O'); runtime = $runtime; diagnostic = $diagnostic; phase = $Phase }
    if (-not $Receipt.ContainsKey('before')) { $Receipt.before = $diagnostic }
    try
    {
        $decision = Get-PairedProbeDecision $Identity $runtime $diagnostic $nativeBirths[$key] `
            $acknowledged $parentReset $sdkRoot $IsWindows $Phase
        $probe.state = $decision.state
        $probe.authorizesProcessAction = $decision.authorizesProcessAction
        $probe.confirmsAbsence = $decision.confirmsAbsence
        if (-not $IsWindows -and $probe.state -eq 'owned-live' -and -not $nativeBirths.ContainsKey($key))
        {
            $nativeBirths[$key] = $diagnostic.native.nativeStart
        }
    }
    catch
    {
        $probe.error = $_.ToString()
        $probe.stack = $_.ScriptStackTrace
        throw
    }
    finally { $Receipt.probes.Add($probe) }
    return $probe
}

function Request-PairedCompilerShutdown($Identity)
{
    $key = "$($Identity.pid):$($Identity.startTicks)"
    $receipt = Get-PairedCleanupReceipt $Identity
    try
    {
        if ($shutdownRequests.ContainsKey($key))
        {
            if (-not $shutdownRequests[$key].acknowledged) { throw 'Prior shutdown request failed; no automatic IPC retry.' }
            $receipt.afterRequest = Read-PairedOwnedState $Identity $receipt 'post-ack-observation'
            return
        }
        $probe = Read-PairedOwnedState $Identity $receipt 'authority'
        if ($probe.state -ne 'owned-live') { throw 'Compiler not live for its first owned shutdown request; graceful gate unproven.' }
        $pipe = Get-PairedPipe $Identity.commandEvidence
        $receipt.pipe = $pipe
        $shutdownRequests[$key] = @{ acknowledged = $false; identity = $Identity; attemptedUtc = [DateTime]::UtcNow }
        $nativeCompiler = Join-Path (Split-Path $config) $(if ($IsWindows) { 'VBCSCompiler.exe' } else { 'VBCSCompiler' })
        $receipt.graceful = Invoke-PairedCommand @('-shutdown', "-pipename:$pipe") `
            (Join-Path $ResultsDirectory "shutdown-$($Identity.pid)-$($Identity.startTicks)") @{} $nativeCompiler
        $shutdownRequests[$key].acknowledged = $true
        $receipt.shutdownAcknowledged = $true
        # An acknowledged request is NOT exit proof. In particular, do not
        # WaitForExit on a non-child Unix zombie before its owned parent reset.
        # This sample may catch the captured ?<E -> Z< transition. It can expose
        # contradictions/query failures, but unavailable fields do not grant
        # child authority or prevent the independently proved parent reset.
        # Only the later bounded absence phase may confirm exit.
        $receipt.afterRequest = Read-PairedOwnedState $Identity $receipt 'post-ack-observation'
    }
    catch { Add-PairedCleanupFailure $receipt 'compiler-shutdown-request' $_; throw }
    finally { Save-PairedCleanup }
}

function Stop-PairedOwnedParent($Identity)
{
    $key = "$($Identity.pid):$($Identity.startTicks)"
    $receipt = Get-PairedCleanupReceipt $Identity
    try
    {
        if ($Identity.kind -notin @('msbuild-helper','launched-command') -or
            $Identity.startTicks -lt $JobStartUtc.ToUniversalTime().Ticks -or
            -not (Test-PrivateSdkPath $Identity.executablePath $sdkRoot $IsWindows))
        {
            throw 'Not an exact owned node/launch command; never stop a compiler or unproved parent.'
        }
        $probe = Read-PairedOwnedState $Identity $receipt 'authority'
        if ($probe.state -in @('absent','owned-zombie','pending-exit')) { return }
        if ($probe.state -ne 'owned-live') { throw 'Parent runtime/native identity is unresolved; refusing stop.' }
        if ($stopRequests.ContainsKey($key)) { throw 'Prior parent stop remains unresolved; no repeated kill.' }
        # This target came from the independently validated ownership registry,
        # not merely the compiler's numeric PPID. Recheck birth/path immediately
        # before the only permitted PID-specific node stop.
        $process = [Diagnostics.Process]::GetProcessById([int]$Identity.pid)
        try { $fresh = Get-PairedRuntimeFields $process }
        finally { $process.Dispose() }
        if (-not $fresh.complete -or
            -not (Test-OwnedProcessIdentity $Identity $fresh.pid $fresh.startTicks $fresh.executablePath $sdkRoot $IsWindows))
        {
            throw 'Parent PID/birth/path changed before stop; refusing reuse.'
        }
        $stopRequests[$key] = @{ identity = $Identity; attemptedUtc = [DateTime]::UtcNow; stopIssued = $false }
        Stop-Process -Id $Identity.pid -Force
        $stopRequests[$key].stopIssued = $true
        $receipt.stopIssued = $true
    }
    catch { Add-PairedCleanupFailure $receipt 'owned-parent-stop' $_; throw }
    finally { Save-PairedCleanup }
}

function Confirm-PairedPrivateAbsence($Identity)
{
    $key = "$($Identity.pid):$($Identity.startTicks)"
    $receipt = Get-PairedCleanupReceipt $Identity
    try
    {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        do
        {
            $probe = Read-PairedOwnedState $Identity $receipt 'absence'
            if ($probe.state -eq 'absent')
            {
                $receipt.exitConfirmed = $true
                $receipt.after = $probe.diagnostic
                $confirmedExited[$key] = $true
                return
            }
            Start-Sleep -Milliseconds 100
        } while ($timer.Elapsed.TotalSeconds -lt 10)
        $receipt.afterFailure = $probe.diagnostic
        throw "Owned exit unconfirmed after parent reset: $($probe.state); no zombie/unknown absence fallback."
    }
    catch { Add-PairedCleanupFailure $receipt 'native-and-runtime-absence' $_; throw }
    finally { Save-PairedCleanup }
}

function Reset-PrivateProcesses
{
    if ($script:resetInProgress) { throw 'Recursive private reset refused.' }
    $script:resetInProgress = $true
    try
    {
        $current = @(Get-PrivateProcesses)
        $owned = @(Get-PairedPendingIdentities $observed $current $confirmedExited)
        $plan = Get-PairedCleanupPlan $owned $sdkRoot $JobStartUtc $IsWindows
        foreach ($edge in $plan.parentEdges)
        {
            $ownedParentProofs["$($edge.compiler.pid):$($edge.compiler.startTicks)"] = "$($edge.parent.pid):$($edge.parent.startTicks)"
        }
        Write-PairedJson $plan (Join-Path $ResultsDirectory "cleanup-plan-$($cleanupPlans.Count).json")
        $cleanupPlans.Add($plan)
        Invoke-PairedCleanupPlan $plan `
            { param($identity) Request-PairedCompilerShutdown $identity } `
            { param($identity) Stop-PairedOwnedParent $identity } `
            { param($identity) Confirm-PairedPrivateAbsence $identity }
        if (@(Get-PrivateProcesses).Count) { throw 'Private processes remain after exact reset.' }
    }
    finally { $script:resetInProgress = $false }
}
