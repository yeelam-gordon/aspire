[CmdletBinding()]
param([Parameter(Mandatory)][string]$ResultsDirectory)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Paired-Helpers.ps1')
if (Test-Path -LiteralPath $ResultsDirectory) { throw 'Refusing fixture evidence overwrite.' }
$null = New-Item -ItemType Directory -Path $ResultsDirectory
$existing = Join-Path $PSScriptRoot ([IO.Path]::Combine('..', 'compiler-cpu-counters', 'Test-CompilerIdentity.ps1'))
& $existing -ResultsDirectory (Join-Path $ResultsDirectory 'p29-identity')
$checks = [Collections.Generic.List[object]]::new()
function Check([string]$Name, [scriptblock]$Body)
{
    & $Body
    $checks.Add(@{ name = $Name; passed = $true })
}
function Require([bool]$Condition)
{
    if (-not $Condition) { throw 'Paired fixture expectation failed.' }
}
function Reject([scriptblock]$Body)
{
    $rejected = $false
    try { & $Body | Out-Null } catch { $rejected = $true }
    Require $rejected
}
$original = [Text.Encoding]::UTF8.GetBytes('{"runtimeOptions":{"tfm":"net11.0","framework":{"name":"Microsoft.NETCore.App","version":"11.0.0"},"configProperties":{"System.GC.Server":true,"other":17}}}')
Check 'Normal policy is accepted without producing replacement bytes' {
    Require (@(Assert-PairedNormalPolicy $original).Count -eq 0)
}
Check 'Reject pre-tuned original SDK configs, including enabled PGO' {
    foreach ($key in @('System.Runtime.TieredPGO','System.Runtime.TieredCompilation','System.Runtime.TieredCompilation.QuickJit',
        'System.Runtime.TieredCompilation.QuickJitForLoops','System.Runtime.ReadyToRun'))
    {
        $parsed = [Text.Encoding]::UTF8.GetString($original) | ConvertFrom-Json -AsHashtable
        $parsed.runtimeOptions.configProperties[$key] = $true
        Reject { Assert-PairedNormalPolicy ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $parsed -Depth 20))) }
    }
}
Check 'Twenty edits have identical corresponding bytes and preserve source prefix' {
    $source = [byte[]]@(0xef,0xbb,0xbf,0x61,0x0a)
    foreach ($index in 1..20)
    {
        $first = Get-PairedEdit $source $index
        $second = Get-PairedEdit $source $index
        Require ([Linq.Enumerable]::SequenceEqual[byte]($first, $second))
        Require ([Linq.Enumerable]::SequenceEqual[byte]($source, [byte[]]$first[0..4]))
        Require ([Text.Encoding]::UTF8.GetString($first).EndsWith("// P44 identical owned edit $index; restored byte-for-byte.`r`n"))
    }
    Reject { Get-PairedEdit $source 0 }
    Reject { Get-PairedEdit $source 21 }
}
Check 'Fork/manual/ref/product guard permits only owned exact source' {
    $repo = 'yeelam-gordon/aspire'
    $ref = 'refs/heads/perf/arm64-compiler-warmup'
    $sha = '06efc928e31486923754398007f4f78003e04ee3'
    Require (Test-PairedDispatch $repo $ref 'workflow_dispatch' $sha)
    Require (-not (Test-PairedDispatch 'microsoft/aspire' $ref 'workflow_dispatch' $sha))
    Require (-not (Test-PairedDispatch $repo 'refs/heads/main' 'workflow_dispatch' $sha))
    Require (-not (Test-PairedDispatch $repo $ref 'push' $sha))
    Require (-not (Test-PairedDispatch $repo $ref 'pull_request' $sha))
    Require (-not (Test-PairedDispatch $repo $ref 'workflow_dispatch' '891d5a172210ae8fa1c7b1ea31ff86f12dc0a838'))
}
Check 'Harness EditCount binding defaults to twenty and accepts only one or twenty' {
    $tokens = $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'Measure-PairedWarmup.ps1'), [ref]$tokens, [ref]$errors)
    Require ($errors.Count -eq 0)
    # Bind the actual harness parameter block, without executing its body or
    # reading/touching any product root. This exercises ValidateSet itself.
    $bind = [scriptblock]::Create("$($ast.ParamBlock.Extent.Text)`nreturn `$EditCount")
    $required = @{ RepositoryRoot = 'unused'; ResultsDirectory = 'unused'; JobStartUtc = [DateTime]::UtcNow }
    Require ((& $bind @required) -eq 20)
    Require ((& $bind @required -EditCount 1) -eq 1)
    Require ((& $bind @required -EditCount 20) -eq 20)
    foreach ($invalid in @(0,2,7,8,19,21,-1))
    {
        Reject { & $bind @required -EditCount $invalid }
    }
}
Check 'Local smoke cannot become hosted reduced work or bypass exact source' {
    $sha = '06efc928e31486923754398007f4f78003e04ee3'
    Require (Test-PairedInvocation '' '' '' $sha 1 $true $false)
    Require (-not (Test-PairedInvocation '' '' '' $sha 20 $true $false))
    Require (-not (Test-PairedInvocation '' '' '' $sha 1 $false $false))
    Require (-not (Test-PairedInvocation '' '' '' $sha 1 $true $true))
    Require (-not (Test-PairedInvocation '' '' '' 'wrong-source' 1 $true $false))
    foreach ($metadata in @(
        @('yeelam-gordon/aspire','',''),
        @('','refs/heads/perf/arm64-compiler-warmup',''),
        @('','','workflow_dispatch')))
    {
        Require (-not (Test-PairedInvocation $metadata[0] $metadata[1] $metadata[2] $sha 1 $true $false))
    }
    Require (Test-PairedInvocation 'yeelam-gordon/aspire' 'refs/heads/perf/arm64-compiler-warmup' 'workflow_dispatch' $sha 20 $false $true)
    Require (-not (Test-PairedInvocation 'yeelam-gordon/aspire' 'refs/heads/perf/arm64-compiler-warmup' 'workflow_dispatch' $sha 1 $false $true))
    Require (-not (Test-PairedInvocation 'yeelam-gordon/aspire' 'refs/heads/perf/arm64-compiler-warmup' 'workflow_dispatch' $sha 1 $true $true))
}
Check 'Private pipe parsing rejects ambiguous or empty shutdown targets' {
    Require ((Get-PairedPipe '"/owned path/VBCSCompiler" -pipename:a_B-4') -ceq 'a_B-4')
    Require ((Get-PairedPipe '"Q:\owned path\VBCSCompiler.exe" "-pipename:a_B-4"') -ceq 'a_B-4')
    Reject { Get-PairedPipe 'VBCSCompiler -pipename:' }
    Reject { Get-PairedPipe 'VBCSCompiler -pipename:a -pipename:b' }
    Reject { Get-PairedPipe 'VBCSCompiler "-pipename:a' }
}
Check 'CPU endpoint rejection is explicit, never a zero fallback' {
    Assert-PairedCpuValues 1 2 3
    Reject { Assert-PairedCpuValues 1 2 0 }
    Reject { Assert-PairedCpuValues ([double]::NaN) 0 0 }
    Reject { Assert-PairedCpuValues -1 0 -1 }
}
Check 'Retained warm CPU identity selection does not rediscover and preserves singleton shape' {
    $tokens = $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'Measure-PairedWarmup.ps1'), [ref]$tokens, [ref]$errors)
    Require ($errors.Count -eq 0)
    $assignments = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -ceq '$current' -and $node.Right.Extent.Text -match '\$server'
    }, $true))
    Require ($assignments.Count -eq 1)
    # Execute the actual selection expression with both JSON-replayed and
    # in-memory identities. Native discovery must never run for a retained PID.
    $select = [scriptblock]::Create("param(`$server)`nfunction Get-PrivateProcesses { throw 'Unexpected rediscovery' }`n$($assignments[0].Extent.Text)`nreturn ,`$current")
    foreach ($identity in @(@{ pid = 41; startTicks = 123L }, [pscustomobject]@{ pid = 42; startTicks = 456L }))
    {
        $selected = & $select $identity
        Require ($selected.Count -eq 1 -and $selected[0].pid -eq $identity.pid -and
            $selected[0].startTicks -eq $identity.startTicks)
    }
}
Check 'Typed ARM64 Mach-O dylib is not an executable and universal policy stays strict' {
    $bytes = [byte[]]::new(32)
    [BitConverter]::GetBytes([uint32]0xFEEDFACFul).CopyTo($bytes, 0)
    [BitConverter]::GetBytes([uint32]0x0100000C).CopyTo($bytes, 4)
    [BitConverter]::GetBytes([uint32]6).CopyTo($bytes, 12)
    $library = Get-PairedRuntimeImageHeader $bytes $false
    Require ($library.arm64 -and $library.machOFileType -eq 6 -and $library.imageRole -ceq 'runtime-library')
    Require (-not (Get-NativeImageHeader $bytes).arm64)
    Reject { Get-PairedRuntimeImageHeader $bytes $true }
    [BitConverter]::GetBytes([uint32]2).CopyTo($bytes, 12)
    Require ((Get-NativeImageHeader $bytes).arm64)
    Reject { Get-PairedRuntimeImageHeader $bytes $false }
    [BitConverter]::GetBytes([uint32]6).CopyTo($bytes, 12)
    [BitConverter]::GetBytes([uint32]0x01000007).CopyTo($bytes, 4)
    Reject { Get-PairedRuntimeImageHeader $bytes $false }
    $fat = [byte[]]::new(32)
    $fat[0] = 0xca; $fat[1] = 0xfe; $fat[2] = 0xba; $fat[3] = 0xbe
    Reject { Get-PairedRuntimeImageHeader $fat $false }
    Reject { Get-PairedRuntimeImageHeader ([byte[]]@(0xcf,0xfa,0xed,0xfe)) $false }
}
Check 'Native Mac state parser retains zombie/start/path without liveness inference' {
    $parsed = ConvertFrom-PairedMacState ' 5673 3992 Z Fri Oct 30 01:23:45 2026 /owned path/.dotnet/VBCSCompiler' 5673
    Require ($parsed.state -ceq 'Z' -and $parsed.parentPid -eq 3992)
    Require ($parsed.nativeStart -ceq 'Fri Oct 30 01:23:45 2026')
    Require ($parsed.nativePath -ceq '/owned path/.dotnet/VBCSCompiler')
    Reject { ConvertFrom-PairedMacState '5674 3992 Z Fri Oct 30 01:23:45 2026 /owned/compiler' 5673 }
    Reject { ConvertFrom-PairedMacState '5673 unavailable' 5673 }
}
Check 'No runtime-wait, zombie, permissions, or query-error absence fallback' {
    Require (Test-PairedAbsence $false 1 @())
    Require (-not (Test-PairedAbsence $true 1 @()))
    Require (-not (Test-PairedAbsence $false 0 @('5673 3992 Z ...')) )
    Require (-not (Test-PairedAbsence $false 1 @('permission denied')) )
    Require (-not (Test-PairedAbsence $false 2 @()))
}
Check 'Retain observed identity missing from runtime enumeration until exact absence, distinguish PID reuse' {
    $old = @{ pid = 5673; startTicks = 123L }
    $new = @{ pid = 5673; startTicks = 456L }
    $observed = @{ '5673:123' = $old }
    $pending = @(Get-PairedPendingIdentities $observed @() @{})
    Require ($pending.Count -eq 1 -and $pending[0].startTicks -eq 123L)
    Require (@(Get-PairedPendingIdentities $observed @($old) @{}).Count -eq 1)
    Require (@(Get-PairedPendingIdentities $observed @() @{ '5673:123' = $true }).Count -eq 0)
    $pending = @(Get-PairedPendingIdentities $observed @($new) @{ '5673:123' = $true })
    Require ($pending.Count -eq 1 -and $pending[0].startTicks -eq 456L)
}
$captured = Get-Content (Join-Path $PSScriptRoot ([IO.Path]::Combine('fixtures','mac-unreaped-compiler.json'))) -Raw | ConvertFrom-Json
$epoch = [DateTime]$captured.epochUtc
$compiler = $captured.compiler
$parent = $captured.parent
$zombieDiagnostic = @{ psExitCode = 0; raw = @($captured.rawZombie)
    native = ConvertFrom-PairedMacState $captured.rawZombie $compiler.pid }
$nullRuntime = Get-PairedRuntimeFields ([pscustomobject]@{ Id = $compiler.pid; StartTime = $null; Path = $null })
Check 'Unavailable zombie properties are explicit typed state, not a null method or absence' {
    Require ($nullRuntime.present -and -not $nullRuntime.complete -and -not $nullRuntime.startTimeAvailable)
    Require ($null -eq $nullRuntime.startTicks)
    Require ((Get-PairedExitState $compiler $nullRuntime $zombieDiagnostic $captured.nativeStart $true $false $captured.sdkRoot $false) -ceq 'owned-zombie')
    Reject { Get-PairedExitState $compiler $nullRuntime $zombieDiagnostic $captured.nativeStart $false $false $captured.sdkRoot $false }
}
Check 'Captured zombie requests then resets only proved parent before compiler absence' {
    $plan = Get-PairedCleanupPlan @($parent,$compiler) $captured.sdkRoot $epoch $false
    Require ($plan.parentEdges.Count -eq 1 -and $plan.parentEdges[0].parent.pid -eq 7995)
    $events = [Collections.Generic.List[string]]::new()
    $state = @{ parentStopped = $false }
    Invoke-PairedCleanupPlan $plan {
        param($identity)
        $events.Add("request:$($identity.pid)")
        Require ((Get-PairedExitState $compiler $nullRuntime $zombieDiagnostic $captured.nativeStart $true $false $captured.sdkRoot $false) -ceq 'owned-zombie')
    } {
        param($identity)
        Require ($identity.pid -eq $parent.pid -and $identity.kind -eq 'msbuild-helper')
        $events.Add("stop:$($identity.pid)")
        $state.parentStopped = $true
    } {
        param($identity)
        Require $state.parentStopped
        $events.Add("absent:$($identity.pid)")
        Require ((Get-PairedExitState $identity @{present=$false;complete=$false} @{psExitCode=1;raw=@()} `
            $captured.nativeStart $true $true $captured.sdkRoot $false) -ceq 'absent')
    }
    Require ($events.IndexOf('request:8003') -lt $events.IndexOf('stop:7995'))
    Require ($events.IndexOf('stop:7995') -lt $events.IndexOf('absent:8003'))
}
Check 'No unproved numeric PPID, frontend, foreign path, old epoch or reused PID becomes a stop target' {
    $foreignParent = $parent | ConvertTo-Json | ConvertFrom-Json
    $foreignParent.executablePath = '/foreign/MSBuild'
    Reject { Get-PairedCleanupPlan @($foreignParent,$compiler) $captured.sdkRoot $epoch $false }
    $old = $parent | ConvertTo-Json | ConvertFrom-Json
    $old.startTicks = $epoch.AddSeconds(-1).Ticks
    Reject { Get-PairedCleanupPlan @($old,$compiler) $captured.sdkRoot $epoch $false }
    $reused = $parent | ConvertTo-Json | ConvertFrom-Json
    $reused.startTicks++
    Reject { Get-PairedCleanupPlan @($parent,$reused,$compiler) $captured.sdkRoot $epoch $false }
    $frontend = $parent | ConvertTo-Json | ConvertFrom-Json
    $frontend.kind = 'other-private-sdk-process'
    Reject { Get-PairedCleanupPlan @($frontend,$compiler) $captured.sdkRoot $epoch $false }
    $withoutParent = Get-PairedCleanupPlan @($compiler) $captured.sdkRoot $epoch $false
    Require ($withoutParent.parents.Count -eq 0 -and $withoutParent.parentEdges.Count -eq 0)
    Require (@($withoutParent.parents | Where-Object pid -EQ 8003).Count -eq 0)
}
Check 'Zombie transitions preserve PID reuse, native query errors, unknown fields and parent proof failures' {
    Reject { Get-PairedExitState $compiler $nullRuntime $zombieDiagnostic 'Fri Oct 30 04:38:21 2026' $true $false $captured.sdkRoot $false }
    $reusedRuntime = @{present=$true;complete=$true;pid=8003;startTicks=$compiler.startTicks+1;executablePath=$compiler.executablePath}
    Reject { Get-PairedExitState $compiler $reusedRuntime $zombieDiagnostic $captured.nativeStart $true $false $captured.sdkRoot $false }
    Reject { Get-PairedExitState $compiler $nullRuntime @{psExitCode=1;raw=@('permission denied')} $captured.nativeStart $true $false $captured.sdkRoot $false }
    Reject { Get-PairedExitState $compiler $nullRuntime @{psExitCode=2;raw=@()} $captured.nativeStart $true $false $captured.sdkRoot $false }
    $foreign = @{psExitCode=0;raw=@('captured');native=@{state='Z<';nativeStart=$captured.nativeStart;parentPid=12345}}
    Reject { Get-PairedExitState $compiler $nullRuntime $foreign $captured.nativeStart $true $false $captured.sdkRoot $false }
    $adopted = @{psExitCode=0;raw=@('captured');native=@{state='Z<';nativeStart=$captured.nativeStart;parentPid=1}}
    Reject { Get-PairedExitState $compiler $nullRuntime $adopted $captured.nativeStart $true $false $captured.sdkRoot $false }
    Require ((Get-PairedExitState $compiler $nullRuntime $adopted $captured.nativeStart $true $true $captured.sdkRoot $false) -ceq 'owned-zombie')
}
Check 'Cleanup callback failure propagates without silently running later phases' {
    $events = [Collections.Generic.List[string]]::new()
    $plan = Get-PairedCleanupPlan @($parent,$compiler) $captured.sdkRoot $epoch $false
    Reject { Invoke-PairedCleanupPlan $plan { throw 'request failed' } { $events.Add('stop') } { $events.Add('absence') } }
    Require ($events.Count -eq 0)
}
$transition = Get-Content (Join-Path $PSScriptRoot ([IO.Path]::Combine('fixtures','mac-ack-exit-transition.json'))) -Raw | ConvertFrom-Json
$exiting = @{psExitCode=0;raw=@($transition.samples[1].raw);native=ConvertFrom-PairedMacState $transition.samples[1].raw $transition.compiler.pid}
Check 'Post-ACK captured unavailable fields are observation-only, never action or absence authority' {
    $decision = Get-PairedProbeDecision $transition.compiler $transition.runtimeDuringTransition $exiting `
        $transition.nativeStart $true $false $transition.sdkRoot $false 'post-ack-observation'
    Require ($decision.state -ceq 'observation-only' -and -not $decision.authorizesProcessAction -and -not $decision.confirmsAbsence)
    Reject { Get-PairedProbeDecision $transition.compiler $transition.runtimeDuringTransition $exiting `
        $transition.nativeStart $true $false $transition.sdkRoot $false 'authority' }
    Reject { Get-PairedProbeDecision $transition.compiler $transition.runtimeDuringTransition $exiting `
        $transition.nativeStart $true $false $transition.sdkRoot $false 'absence' }
    $absentObservation = Get-PairedProbeDecision $transition.compiler @{present=$false;complete=$false} @{psExitCode=1;raw=@()} `
        $transition.nativeStart $true $true $transition.sdkRoot $false 'post-ack-observation'
    Require (-not $absentObservation.confirmsAbsence)
}
Check 'Actual request phase reaches independently proved parent reset after ACK observation then strict absence' {
    & {
        . (Join-Path $PSScriptRoot 'Paired-Cleanup.ps1')
        $sdkRoot = $transition.sdkRoot
        $config = Join-Path $sdkRoot 'unused-runtimeconfig.json'
        $ResultsDirectory = 'unused-fixture-result'
        $cleanup = [Collections.Generic.List[object]]::new()
        $cleanupByKey = @{}
        $shutdownRequests = @{}
        $events = [Collections.Generic.List[string]]::new()
        $fixtureState = @{ parentStopped = $false; observation = $null }
        function Save-PairedCleanup { }
        function Invoke-PairedCommand { $events.Add('ipc-ack'); return @{exitCode=0} }
        function Read-PairedOwnedState($Identity, $Receipt, $Phase)
        {
            if ($Phase -eq 'authority')
            {
                return @{state='owned-live'}
            }
            if ($Phase -ne 'post-ack-observation') { throw 'Request used an invalid observation phase.' }
            $fixtureState.observation = Get-PairedProbeDecision $transition.compiler $transition.runtimeDuringTransition $exiting `
                $transition.nativeStart $true $false $transition.sdkRoot $false $Phase
            $events.Add("sample:$($exiting.native.state)")
            return $fixtureState.observation
        }
        $plan = Get-PairedCleanupPlan @($transition.parent,$transition.compiler) $transition.sdkRoot `
            ([DateTime]'2026-10-30T05:39:00Z') $false
        Invoke-PairedCleanupPlan $plan {
            param($identity)
            Request-PairedCompilerShutdown $identity
        } {
            param($identity)
            Require ($identity.pid -eq $transition.parent.pid -and $identity.kind -eq 'msbuild-helper')
            Require ($plan.parentEdges[0].parent.startTicks -eq $identity.startTicks)
            $events.Add('proved-parent-reset')
            $fixtureState.parentStopped = $true
        } {
            param($identity)
            Require $fixtureState.parentStopped
            if ($identity.kind -eq 'compiler')
            {
                $z = @{psExitCode=0;raw=@($transition.samples[2].raw);native=ConvertFrom-PairedMacState $transition.samples[2].raw $identity.pid}
                $decision = Get-PairedProbeDecision $identity $transition.runtimeDuringTransition $z $transition.nativeStart `
                    $true $true $transition.sdkRoot $false 'absence'
                Require ($decision.state -eq 'owned-zombie' -and -not $decision.confirmsAbsence)
                $events.Add('sample:Z<')
            }
            $final = Get-PairedProbeDecision $identity @{present=$false;complete=$false} @{psExitCode=1;raw=@()} `
                $transition.nativeStart $true $true $transition.sdkRoot $false 'absence'
            Require $final.confirmsAbsence
            $events.Add("absent:$($identity.pid)")
        }
        Require ($events.IndexOf('ipc-ack') -lt $events.IndexOf('sample:?<E'))
        Require ($events.IndexOf('sample:?<E') -lt $events.IndexOf('proved-parent-reset'))
        Require ($events.IndexOf('proved-parent-reset') -lt $events.IndexOf('sample:Z<'))
        Require ($events.IndexOf('sample:Z<') -lt $events.IndexOf('absent:4622'))
        Require (-not $fixtureState.observation.authorizesProcessAction -and -not $fixtureState.observation.confirmsAbsence)
    }
}
Check 'Observation cannot hide query errors, concrete reuse/path/parent contradictions or missing ACK' {
    Reject { Get-PairedProbeDecision $transition.compiler $transition.runtimeDuringTransition $exiting $transition.nativeStart `
        $false $false $transition.sdkRoot $false 'post-ack-observation' }
    Reject { Get-PairedProbeDecision $transition.compiler $transition.runtimeDuringTransition @{psExitCode=1;raw=@('permission denied')} `
        $transition.nativeStart $true $false $transition.sdkRoot $false 'post-ack-observation' }
    $changed = $transition.runtimeDuringTransition | ConvertTo-Json | ConvertFrom-Json
    $changed.startTicks = $transition.compiler.startTicks + 1
    Reject { Get-PairedProbeDecision $transition.compiler $changed $exiting $transition.nativeStart `
        $true $false $transition.sdkRoot $false 'post-ack-observation' }
    $changed.startTicks = $null
    $changed.executablePath = '/foreign/compiler'
    Reject { Get-PairedProbeDecision $transition.compiler $changed $exiting $transition.nativeStart `
        $true $false $transition.sdkRoot $false 'post-ack-observation' }
    Reject { Get-PairedProbeDecision $transition.compiler $transition.runtimeDuringTransition $exiting 'different birth' `
        $true $false $transition.sdkRoot $false 'post-ack-observation' }
    $badParent = @{psExitCode=0;raw=@('captured');native=@{pid=4622;parentPid=12345;nativeStart=$transition.nativeStart;nativePath='(VBCSCompiler)'}}
    Reject { Get-PairedProbeDecision $transition.compiler $transition.runtimeDuringTransition $badParent $transition.nativeStart `
        $true $false $transition.sdkRoot $false 'post-ack-observation' }
}
Check 'Identity contradiction aborts plan before any parent action, while unrelated unknown states get no authority' {
    $plan = Get-PairedCleanupPlan @($transition.parent,$transition.compiler) $transition.sdkRoot ([DateTime]'2026-10-30T05:39:00Z') $false
    $state = @{ parentAction = $false }
    $bad = @{present=$true;complete=$true;pid=4622;startTicks=$transition.compiler.startTicks+1;executablePath=$transition.compiler.executablePath}
    Reject {
        Invoke-PairedCleanupPlan $plan {
            Get-PairedProbeDecision $transition.compiler $bad $exiting $transition.nativeStart $true $false $transition.sdkRoot $false 'post-ack-observation'
        } { $state.parentAction = $true } { throw 'No confirmation expected.' }
    }
    Require (-not $state.parentAction)
}
$fixture = Join-Path $ResultsDirectory 'output-fixture'
try
{
    $reference = Join-Path $fixture 'reference'
    $actual = Join-Path $fixture 'actual'
    $null = New-Item -ItemType Directory -Path $reference,$actual
    Check 'Dynamic byte equality catches mismatch, missing, extra and empty manifests' {
        $name = [IO.Path]::Combine('bin', 'locale with space', 'satellite.resources.dll')
        foreach ($root in @($reference,$actual))
        {
            $file = Join-Path $root $name
            $null = New-Item -ItemType Directory -Path (Split-Path $file)
            [IO.File]::WriteAllBytes($file, [byte[]]@(0,1,2))
        }
        Require ((Compare-PairedTrees $reference $actual).passed)
        [IO.File]::WriteAllBytes((Join-Path $actual $name), [byte[]]@(0,1,3))
        Require (-not (Compare-PairedTrees $reference $actual).passed)
        Remove-Item -LiteralPath (Join-Path $actual $name)
        Require (-not (Compare-PairedTrees $reference $actual).passed)
        [IO.File]::WriteAllBytes((Join-Path $actual ([IO.Path]::Combine('bin','extra.pdb'))), [byte[]]@(1))
        Require (-not (Compare-PairedTrees $reference $actual).passed)
        Remove-Item -LiteralPath (Join-Path $reference $name)
        Remove-Item -LiteralPath (Join-Path $actual ([IO.Path]::Combine('bin','extra.pdb')))
        Require (-not (Compare-PairedTrees $reference $actual).passed)
    }
    Check 'Real hidden attributes and dot-generated files are inventoried copied compared and archived in controlled trees' {
        $product = Join-Path $fixture 'hidden-product'
        $paths = @(
            [IO.Path]::Combine('artifacts','obj','Aspire.Hosting','Debug','net10.0','.NETCoreApp,Version=v10.0.AssemblyAttributes.cs'),
            [IO.Path]::Combine('artifacts','obj','Aspire.Hosting.Integration.Analyzers','Debug','netstandard2.0','.NETStandard,Version=v2.0.AssemblyAttributes.cs'),
            [IO.Path]::Combine('artifacts','bin','Aspire.Hosting','Debug','net10.0','visible.dll')
        )
        $attributes = @{}
        try
        {
            foreach ($path in $paths)
            {
                $file = Join-Path $product $path
                $null = New-Item -ItemType Directory -Path (Split-Path $file) -Force
                [IO.File]::WriteAllText($file, "fixture bytes: $path")
                $attributes[$file] = [IO.File]::GetAttributes($file)
                if ($IsWindows -and $file.EndsWith('.cs'))
                {
                    [IO.File]::SetAttributes($file, $attributes[$file] -bor [IO.FileAttributes]::Hidden)
                    Require (([IO.File]::GetAttributes($file) -band [IO.FileAttributes]::Hidden) -ne 0)
                }
            }
            $null = New-Item -ItemType Directory -Path (Join-Path $product ([IO.Path]::Combine('artifacts','bin','Aspire.Hosting.Integration.Analyzers','Debug'))) -Force
            $selected = @(Get-PairedOutputFiles $product)
            Require (($selected.FullName | Sort-Object | ConvertTo-Json -Compress) -ceq
                (@($paths | ForEach-Object { Join-Path $product $_ }) | Sort-Object | ConvertTo-Json -Compress))
            $copies = @((Join-Path $fixture 'hidden-reference'),(Join-Path $fixture 'hidden-actual'))
            foreach ($copy in $copies)
            {
                foreach ($file in $selected)
                {
                    $relative = [IO.Path]::GetRelativePath((Join-Path $product 'artifacts'), $file.FullName)
                    $target = Join-Path $copy $relative
                    $null = New-Item -ItemType Directory -Path (Split-Path $target) -Force
                    Copy-Item -LiteralPath $file.FullName -Destination $target -Force
                }
            }
            Require ((Compare-PairedTrees $copies[0] $copies[1]).passed)
            $hiddenRelative = [IO.Path]::GetRelativePath((Join-Path $product 'artifacts'), (Join-Path $product $paths[0]))
            $changed = [IO.File]::Open((Join-Path $copies[1] $hiddenRelative), [IO.FileMode]::Open, [IO.FileAccess]::Write)
            try
            {
                $changed.SetLength(0)
                $changed.Write([Text.Encoding]::UTF8.GetBytes('changed hidden bytes'))
            }
            finally { $changed.Dispose() }
            Require (-not (Compare-PairedTrees $copies[0] $copies[1]).passed)
            $zip = Join-Path $fixture 'controlled-output.zip'
            [IO.Compression.ZipFile]::CreateFromDirectory($copies[0], $zip)
            $archive = [IO.Compression.ZipFile]::OpenRead($zip)
            try
            {
                $entry = $archive.Entries | Where-Object { $_.FullName.Replace('\','/') -ceq $hiddenRelative.Replace('\','/') }
                Require ([bool]$entry)
                $stream = $entry.Open()
                $memory = [IO.MemoryStream]::new()
                try
                {
                    $stream.CopyTo($memory)
                    Require ([Linq.Enumerable]::SequenceEqual[byte](
                        [IO.File]::ReadAllBytes((Join-Path $product $paths[0])), $memory.ToArray()))
                }
                finally { $memory.Dispose(); $stream.Dispose() }
            }
            finally { $archive.Dispose() }
        }
        finally
        {
            foreach ($file in $attributes.Keys) { [IO.File]::SetAttributes($file, $attributes[$file]) }
        }
    }
    Check 'Shared output selection includes every locale and framework but not obj caches' {
        $root = Join-Path $fixture 'product'
        foreach ($project in @('Aspire.Hosting','Aspire.Hosting.Integration.Analyzers'))
        {
            foreach ($kind in @('bin','obj'))
            {
                $directory = Join-Path $root ([IO.Path]::Combine('artifacts',$kind,$project,'Debug','net10.0','ja'))
                $null = New-Item -ItemType Directory -Path $directory -Force
                foreach ($name in @('output.dll','output.pdb','generated.cs','doc.xml','data.json','x.resources','state.cache','build.log'))
                {
                    [IO.File]::WriteAllText((Join-Path $directory $name), $name)
                }
            }
        }
        $files = @(Get-PairedOutputFiles $root)
        Require ($files.Count -eq 28)
        Require (@($files | Where-Object { $_.FullName -match '[\\/]obj[\\/]' -and $_.Extension -in @('.cache','.log') }).Count -eq 0)
        Require (@($files | Where-Object { $_.FullName -match '[\\/]bin[\\/]' }).Count -eq 16)
    }
}
finally { Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }
Write-PairedJson @{ scope = 'Pure source fixtures; no compiler/build/restore/counter tool or Mac API execution.'
    checks = @($checks.ToArray()); macRunnerCoverage = 'unverified'; failed = 0 } (Join-Path $ResultsDirectory 'paired-fixtures.json')
Write-Host "$($checks.Count) paired helper groups passed; P29 groups retained; no workload executed."
