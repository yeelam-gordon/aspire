. (Join-Path $PSScriptRoot 'Guard.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Helpers.ps1')
. (Join-Path $PSScriptRoot 'Monitor.ps1')

function Start-MatureCollection($Identity, [string]$Directory, [hashtable]$State)
{
    $null=Assert-MatureContext
    if (Test-Path $Directory) { throw 'Refusing collection overwrite.' }
    $null=New-Item -ItemType Directory -Path $Directory
    $live=Get-Process -Id $Identity.pid -ErrorAction Stop
    if (-not (Test-OwnedProcessIdentity $Identity $live.Id $live.StartTime.ToUniversalTime().Ticks $live.Path $sdkRoot $true))
    { throw 'Compiler identity changed before attach.' }
    $vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $paths=@(& $vswhere -latest -products '*' -property installationPath)
    if ($LASTEXITCODE -ne 0 -or $paths.Count -ne 1) { throw 'Installed VS discovery failed.' }
    $collector=Join-Path $paths[0] 'Team Tools\DiagnosticsHub\Collector'
    $tool=Join-Path $collector 'VSDiagnostics.exe'
    $configPath=Join-Path $collector 'AgentConfigs\CPUUsageLow.json'
    $config=Get-Content $configPath -Raw|ConvertFrom-Json
    $agent=Join-Path $collector 'Agents\DiagnosticsHub.CpuAgent.dll'
    $runtime=Join-Path $collector 'DiagnosticsHub.StandardCollector.Runtime.dll'
    if (@($config.Agents).Count -ne 1 -or $config.Agents[0].Name -cne 'DiagnosticsHub.CpuAgent.dll' -or
        $config.Agents[0].CLSID -cne '4EA90761-2248-496C-B854-3C0399A591A4' -or
        $config.Agents[0].Config.cpuSampleRate -ne 100 -or $config.Agents[0].Config.attachToChildProcesses -eq $true -or
        (Get-CpuPeMachine $agent) -ne '0xAA64' -or (Get-CpuPeMachine $runtime) -ne '0xAA64')
    { throw 'Supplied native ARM64 Low CPU configuration failed.' }
    $values=@{sessionId=[Guid]::NewGuid().ToString();started=$false;stopAttempted=$false;tool=$tool;directory=$Directory
        identity=$Identity;configPath=$configPath;config=$config;serviceBefore=(Get-Service VSStandardCollectorService150).Status.ToString()
        files=@($tool,$agent,$runtime|ForEach-Object{$f=Get-Item $_;@{path=$_;bytes=$f.Length;version=$f.VersionInfo.FileVersion;machine=Get-CpuPeMachine $_}})}
    foreach($key in $values.Keys){$State[$key]=$values[$key]}
    Write-CpuJson $state (Join-Path $Directory 'session-before.json')
    $help=Start-CpuProcess $tool @('start','/help') (Join-Path $Directory 'start-help')
    $hr=Complete-CpuProcess $help 10
    if ($hr.exitCode -ne 0 -or $hr.timedOut -or (Get-Content (Join-Path $Directory 'start-help.stdout.log') -Raw) -notmatch 'parsable Guid')
    { throw 'Installed GUID-session help failed.' }
    $scratch=Join-Path $Directory 'scratch'; $null=New-Item -ItemType Directory -Path $scratch
    Begin-MatureMonitor $State @('start',$state.sessionId,"/attach:$($Identity.pid)","/loadConfig:$configPath","/scratchLocation:$scratch",'/monitor')
    try{Wait-MatureMonitorReady $State 12}
    catch
    {
        $original=$_
        try{Save-MatureMonitorState $State 'session-start.json'}
        catch{[Console]::Error.WriteLine("Secondary session-state persistence failure: $($_.Exception)")}
        throw $original
    }
    Save-MatureMonitorState $State 'session-start.json'
}

function Stop-MatureCollection($State)
{
    $null=Assert-MatureContext
    $State.output=Join-Path $State.directory 'mature-csc.diagsession'
    Invoke-MatureSessionStop $State @('stop',$State.sessionId,"/output:$($State.output)") 30
    $State.serviceAfter=(Get-Service VSStandardCollectorService150).Status.ToString()
}
