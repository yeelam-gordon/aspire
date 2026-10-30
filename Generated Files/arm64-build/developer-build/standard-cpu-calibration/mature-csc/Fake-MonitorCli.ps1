param([string]$Root,[string]$Mode,[string]$Command,[string]$SessionId,
    [Parameter(ValueFromRemainingArguments)][string[]]$Options)
$ErrorActionPreference='Stop'
if($Command -ceq 'hold')
{
    @{pid=$PID;birthTicks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks;executable=(Get-Process -Id $PID).Path}|
        ConvertTo-Json|Set-Content (Join-Path $Root 'holder.json')
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while(-not(Test-Path (Join-Path $Root 'release.signal')) -and $timer.Elapsed.TotalSeconds -lt 25){Start-Sleep -Milliseconds 20}
    exit 0
}
if($Command -ceq 'stop')
{
    if($Mode -ceq 'stopTimeout'){Start-Sleep -Seconds 25;exit 8}
    $output=@($Options|Where-Object {$_ -clike '/output:*'})[0].Substring(8)
    [IO.File]::WriteAllText($output,'OWNED SYNTHETIC archive, not profiler data.')
    [IO.File]::WriteAllText((Join-Path $Root 'stop.signal'),'stop')
    $id=if($Mode -ceq 'stopWrong'){[Guid]::NewGuid().ToString()}else{$SessionId}
    [Console]::WriteLine("Session ${id}: {$id}")
    [Console]::WriteLine('  Stopped')
    exit 0
}
if($Command -cne 'start'){throw 'Only fake start/stop/hold supported.'}
if($Mode -ceq 'early0'){exit 0}
if($Mode -ceq 'early7'){exit 7}
[Console]::WriteLine('Microsoft (R) VS Standard Collector')
if($Mode -ceq 'stderr'){[Console]::Error.WriteLine('FAKE startup error');Start-Sleep -Milliseconds 150}
if($Mode -cne 'missing')
{
    $id=if($Mode -ceq 'wrongGuid'){[Guid]::NewGuid().ToString()}elseif($Mode -ceq 'substringGuid'){"${SessionId}x"}else{$SessionId}
    [Console]::WriteLine("Session ${id}: {$id}")
    [Console]::WriteLine($(if($Mode -ceq 'collision'){'  Error: session already exists'}else{'  Running'}))
}
$timer=[Diagnostics.Stopwatch]::StartNew()
$workReported=$false
while(-not(Test-Path (Join-Path $Root 'stop.signal')) -and $timer.Elapsed.TotalSeconds -lt 25)
{
    if(-not$workReported -and (Test-Path (Join-Path $Root 'work.marker')))
    {[Console]::WriteLine('  WORK_OBSERVED_AFTER_RUNNING');$workReported=$true}
    if($Mode -ceq 'later7' -and (Test-Path (Join-Path $Root 'work.marker'))){exit 7}
    Start-Sleep -Milliseconds 20
}
if($Mode -ceq 'later7'){exit 7}
if(-not$workReported -and (Test-Path (Join-Path $Root 'work.marker')))
{[Console]::WriteLine('  WORK_OBSERVED_AFTER_RUNNING')}
if($Mode -ceq 'drain')
{
    # This owned child deliberately inherits both pipe handles after the
    # monitor exits. The test releases/cleans it by its exact identity.
    $info=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $info.UseShellExecute=$false
    foreach($arg in @('-NoProfile','-File',$PSCommandPath,$Root,$Mode,'hold',$SessionId)){$info.ArgumentList.Add($arg)}
    $holder=[Diagnostics.Process]::Start($info)
    $timer.Restart()
    while(-not(Test-Path (Join-Path $Root 'holder.json')) -and $timer.Elapsed.TotalSeconds -lt 3){Start-Sleep -Milliseconds 20}
}
exit 0
