$ErrorActionPreference='Stop'
$script:InventoryCli='C:\Program Files\Microsoft Visual Studio\18\Enterprise\Team Tools\DiagnosticsHub\Collector\VSDiagnostics.exe'
$script:InventoryService='C:\Program Files (x86)\Microsoft Visual Studio\Shared\Common\DiagnosticsHub.Collection.Service\StandardCollector.Service.exe'
$script:InventoryHost='{F2DC0F57-0B99-49E3-BE80-936DBAA54EE0}'

function Write-InventoryJson($Value,[string]$Path)
{
    $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 20))
    $pending="$Path.$([Guid]::NewGuid().ToString('N')).pending"
    $s=[IO.FileStream]::new($pending,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$s.Write($bytes);$s.Flush($true)}finally{$s.Dispose()}
    [IO.File]::Move($pending,$Path,$true)
}

function Test-InventoryContext($Context)
{
    return $Context.actions -ceq 'true' -and $Context.repository -ceq 'yeelam-gordon/aspire' -and
        $Context.ref -ceq 'refs/heads/perf/arm64-activation-inventory' -and $Context.event -ceq 'workflow_dispatch' -and
        $Context.attempt -ceq '1' -and $Context.environment -ceq 'github-hosted' -and $Context.os -ceq 'Windows' -and
        $Context.arch -ceq 'ARM64' -and $Context.image -ceq 'win11-vs2026-arm64' -and
        $Context.processArch -ceq 'Arm64' -and $Context.osArch -ceq 'Arm64'
}

function Assert-InventoryHelpCommand([string]$Executable,[string[]]$Arguments)
{
    if($Executable -cne $script:InventoryCli -or $Arguments.Count -ne 2 -or
        $Arguments[0] -cne 'start' -or $Arguments[1] -cne '/help')
    {throw 'Inventory permits only the fixed installed CLI argv start /help; no executable/argument override.'}
}

function Get-InventoryPe([string]$Path)
{
    # File references are fixed caller literals or the exact allowlisted service
    # image, never arbitrary registry-provided code/data paths.
    $allowed=@($script:InventoryCli,$script:InventoryService,
        (Join-Path (Split-Path $script:InventoryCli) 'DiagnosticsHub.StandardCollector.Host.Interop.dll'),
        (Join-Path (Split-Path $script:InventoryCli) 'DiagnosticsHub.StandardCollector.Interop.dll'))
    if($Path -cnotin $allowed){throw 'PE reference outside fixed component property allowlist.'}
    if(-not[IO.File]::Exists($Path)){return @{path=$Path;exists=$false}}
    $s=[IO.File]::OpenRead($Path);$pe=[Reflection.PortableExecutable.PEReader]::new($s)
    try
    {
        $f=Get-Item $Path
        $result=@{path=$Path;exists=$true;bytes=$f.Length;version=$f.VersionInfo.FileVersion
            machine=$pe.PEHeaders.CoffHeader.Machine.ToString();managed=$pe.HasMetadata}
        if($pe.HasMetadata){$result.corFlags=$pe.PEHeaders.CorHeader.Flags.ToString()}
        return $result
    }
    finally{$pe.Dispose();$s.Dispose()}
}

function Get-InventoryPublicGuids
{
    $root=Split-Path $script:InventoryCli
    $allowed=@{
        'DiagnosticsHub.StandardCollector.Host.Interop.dll'=@('DiagnosticsHub.StandardCollector.Host.Interop.StandardCollectorHostClass',
            'DiagnosticsHub.StandardCollector.Host.Interop.IStandardCollectorService')
        'DiagnosticsHub.StandardCollector.Interop.dll'=@('DiagnosticsHub.StandardCollector.Interop.StandardCollectorServiceClass')
    }
    foreach($name in $allowed.Keys)
    {
        $path=Join-Path $root $name;$file=Get-InventoryPe $path
        if(-not$file.exists){$file;continue}
        $s=[IO.File]::OpenRead($path);$pe=[Reflection.PortableExecutable.PEReader]::new($s)
        try
        {
            # Public GUID attributes only: no vendor assembly execution,
            # private types, method bodies, manifests or binary copying.
            $reader=[Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($pe)
            $file.publicGuids=@(foreach($h in $reader.TypeDefinitions)
            {
                $type=$reader.GetTypeDefinition($h)
                $typeName="$($reader.GetString($type.Namespace)).$($reader.GetString($type.Name))"
                if($typeName -cnotin $allowed[$name] -or
                    ($type.Attributes -band [Reflection.TypeAttributes]::VisibilityMask) -ne [Reflection.TypeAttributes]::Public){continue}
                foreach($a in $type.GetCustomAttributes())
                {
                    $attr=$reader.GetCustomAttribute($a)
                    if($attr.Constructor.Kind -ne [Reflection.Metadata.HandleKind]::MemberReference){continue}
                    $member=$reader.GetMemberReference([Reflection.Metadata.MemberReferenceHandle]$attr.Constructor)
                    if($member.Parent.Kind -ne [Reflection.Metadata.HandleKind]::TypeReference){continue}
                    $owner=$reader.GetTypeReference([Reflection.Metadata.TypeReferenceHandle]$member.Parent)
                    if($reader.GetString($owner.Namespace) -cne 'System.Runtime.InteropServices' -or
                        $reader.GetString($owner.Name) -cne 'GuidAttribute'){continue}
                    $blob=$reader.GetBlobReader($attr.Value)
                    if($blob.ReadUInt16() -ne 1){throw 'Unexpected public GUID attribute prolog.'}
                    @{type=$typeName;guid=$blob.ReadSerializedString()}
                }
            })
            $file
        }
        finally{$pe.Dispose();$s.Dispose()}
    }
}

function Get-InventoryRegistration
{
    foreach($view in @([Microsoft.Win32.RegistryView]::Registry64,[Microsoft.Win32.RegistryView]::Registry32))
    {
        foreach($hive in @([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryHive]::CurrentUser))
        {
            $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey($hive,$view)
            try
            {
                $class=$base.OpenSubKey("SOFTWARE\Classes\CLSID\$script:InventoryHost",$false)
                $app=$base.OpenSubKey("SOFTWARE\Classes\AppID\$script:InventoryHost",$false)
                try
                {
                    @{hive=$hive.ToString();view=$view.ToString();hostClsid=$script:InventoryHost
                        classExists=$null -ne $class;appExists=$null -ne $app
                        appId=if($null -ne $class){$class.GetValue('AppID')}else{$null}
                        localService=if($null -ne $app){$app.GetValue('LocalService')}else{$null}}
                }
                finally{if($class){$class.Dispose()};if($app){$app.Dispose()}}
            }
            finally{$base.Dispose()}
        }
    }
}

function Get-InventoryService
{
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
    try
    {
        $key=$base.OpenSubKey('SYSTEM\CurrentControlSet\Services\VSStandardCollectorService150',$false)
        if($null -eq $key){return @{exists=$false;imageAllowed=$false;image=@{exists=$false}}}
        try
        {
            $path=[string]$key.GetValue('ImagePath')
            $allowed=$path -ceq "`"$script:InventoryService`"" -or $path -ceq $script:InventoryService
            return @{exists=$true;start=$key.GetValue('Start');imagePath=$path;imageAllowed=$allowed
                image=if($allowed){Get-InventoryPe $script:InventoryService}else{@{exists=$false;notRead='ImagePath outside exact component allowlist'}}}
        }
        finally{$key.Dispose()}
    }
    finally{$base.Dispose()}
}

function Get-InventoryRoute($Registration,$Service)
{
    if(-not$Registration.classExists){return 'MissingHostClass'}
    if($Registration.appId -ine $script:InventoryHost){return 'UnexpectedHostAppId'}
    if(-not$Registration.appExists){return 'MissingHostAppId'}
    if($Registration.localService -cne 'VSStandardCollectorService150'){return 'UnexpectedLocalService'}
    if(-not$Service.exists){return 'MissingServiceKey'}
    if(-not$Service.imageAllowed){return 'UnexpectedServiceImagePath'}
    if(-not$Service.image.exists){return 'MissingServiceImage'}
    return 'PresentStaticRoute'
}

function Invoke-InventoryHelp([string]$Output)
{
    # Not parameterized by executable or CLI argv; validator is also tested.
    $arguments=@('start','/help');Assert-InventoryHelpCommand $script:InventoryCli $arguments
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ActivationInventoryMachine
{
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWow64Process2(IntPtr process, out ushort machine, out ushort native);
}
'@
    $info=[Diagnostics.ProcessStartInfo]::new($script:InventoryCli)
    $info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($a in $arguments){$info.ArgumentList.Add($a)}
    $p=[Diagnostics.Process]::Start($info)
    $identity=@{pid=$p.Id;birthTicks=$p.StartTime.ToUniversalTime().Ticks;executable=$script:InventoryCli;arguments=$arguments}
    $stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
    $observations=@();$timer=[Diagnostics.Stopwatch]::StartNew()
    $original=$null
    $result=@{identity=$identity;exited=$false;probeComplete=$false;cleanupErrors=@()}
    try
    {
        Write-InventoryJson $identity (Join-Path $Output 'help-start.json')
        while(-not$p.HasExited -and $timer.Elapsed.TotalSeconds -lt 10)
        {
            [ushort]$machine=0;[ushort]$native=0
            if(-not[ActivationInventoryMachine]::IsWow64Process2($p.Handle,[ref]$machine,[ref]$native))
            {throw "Own help architecture query failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"}
            $pair=@{processMachine=('0x{0:X4}' -f $machine);nativeMachine=('0x{0:X4}' -f $native)}
            if($observations.Count -eq 0 -or ($observations[-1]|ConvertTo-Json -Compress) -cne ($pair|ConvertTo-Json -Compress)){$observations+=$pair}
            Start-Sleep -Milliseconds 5
        }
        if(-not$p.HasExited){throw 'Own fixed help exceeded10s bound; no retry.'}
        $text=$stdout.WaitAsync([TimeSpan]::FromSeconds(5)).GetAwaiter().GetResult()
        $errorText=$stderr.WaitAsync([TimeSpan]::FromSeconds(5)).GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $Output 'help.stdout.log'),$text)
        [IO.File]::WriteAllText((Join-Path $Output 'help.stderr.log'),$errorText)
        if($p.ExitCode -ne 0 -or $observations.Count -eq 0 -or -not[string]::IsNullOrWhiteSpace($errorText))
        {throw 'Help/architecture inventory incomplete; no default success.'}
        $result.probeComplete=$true
        return $result
    }
    catch
    {
        $original=$_
        $result.failure=@{error=$_.ToString();exception=$_.Exception.ToString();stack=$_.ScriptStackTrace}
        throw $original
    }
    finally
    {
        try
        {
            if(-not$p.HasExited)
            {
                $live=Get-Process -Id $identity.pid
                if($live.StartTime.ToUniversalTime().Ticks -ne $identity.birthTicks -or $live.Path -cne $script:InventoryCli)
                {throw 'Own help identity changed; refusing cleanup.'}
                Stop-Process -Id $identity.pid
                if(-not$p.WaitForExit(5000)){throw 'Own help cleanup exit unconfirmed.'}
            }
        }
        catch
        {
            $result.cleanupErrors+=@{error=$_.ToString();stack=$_.ScriptStackTrace}
            [Console]::Error.WriteLine("Own help cleanup failure: $($_.Exception)")
            if($null -eq $original){$original=$_}
        }
        finally
        {
            $result.exited=$p.HasExited
            $result.exitCode=if($p.HasExited){$p.ExitCode}else{$null}
            $result.observations=$observations;$result.exitUtc=[DateTime]::UtcNow.ToString('O')
            foreach($resource in @($p.StandardOutput,$p.StandardError,$p))
            {
                try{$resource.Dispose()}
                catch
                {
                    $result.cleanupErrors+=@{error=$_.ToString();stack=$_.ScriptStackTrace}
                    [Console]::Error.WriteLine("Secondary own help resource failure: $($_.Exception)")
                    if($null -eq $original){$original=$_}
                }
            }
            try{Write-InventoryJson $result (Join-Path $Output 'help-final.json')}
            catch
            {
                [Console]::Error.WriteLine("Secondary help-final persistence failure: $($_.Exception)")
                if($null -eq $original){throw}
            }
        }
        if($null -ne $original){throw $original}
    }
}

function Invoke-ActivationInventory([string]$Output)
{
    if(Test-Path -LiteralPath $Output){throw 'Refusing inventory overwrite.'}
    $null=New-Item -ItemType Directory -Path $Output
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try{$elevated=[Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}
    finally{$identity.Dispose()}
    $report=@{utc=[DateTime]::UtcNow.ToString('O');inventoryComplete=$false;activationTested=$false
        source=(& git -C $PSScriptRoot rev-parse HEAD).Trim();repository=$env:GITHUB_REPOSITORY;ref=$env:GITHUB_REF;attempt=$env:GITHUB_RUN_ATTEMPT
        imageOS=$env:ImageOS;imageVersion=$env:ImageVersion;os=[Runtime.InteropServices.RuntimeInformation]::OSDescription
        shellArch=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
        osArch=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString();elevated=$elevated
        probes=@{};errors=[Collections.Generic.List[object]]::new();reportingErrors=[Collections.Generic.List[object]]::new()
        limits='Static machine route is not COM success; HKCU overlays/ARM32+x86 view differences and caller activation context are not resolved. Inner failing CLSID/CLSCTX remains vendor/runner diagnostic gap.'}
    foreach($phase in @('publicGuids','registration','service','cliPe','help'))
    {
        try
        {
            $report.probes[$phase]=switch($phase)
            {
                'publicGuids'{@(Get-InventoryPublicGuids)}
                'registration'{@(Get-InventoryRegistration)}
                'service'{Get-InventoryService}
                'cliPe'{Get-InventoryPe $script:InventoryCli}
                'help'{Invoke-InventoryHelp $Output}
            }
        }
        catch
        {
            $record=@{phase=$phase;exception=$_.Exception.ToString();error=$_.ToString();stack=$_.ScriptStackTrace;position=$_.InvocationInfo.PositionMessage}
            $report.errors.Add($record)
            [Console]::Error.WriteLine("Read-only inventory failed: $phase $($_.Exception)")
            try{Write-InventoryJson $record (Join-Path $Output "error-$phase.json")}
            catch
            {
                $report.reportingErrors.Add(@{phase=$phase;error=$_.ToString();stack=$_.ScriptStackTrace})
                [Console]::Error.WriteLine("Secondary inventory error-record persistence failure: $($_.Exception)")
            }
        }
        finally
        {
            try{Write-InventoryJson $report (Join-Path $Output 'inventory.json')}
            catch
            {
                $report.reportingErrors.Add(@{phase="snapshot-$phase";error=$_.ToString();stack=$_.ScriptStackTrace})
                [Console]::Error.WriteLine("Secondary inventory snapshot persistence failure: $($_.Exception)")
            }
        }
    }
    $report.machineRoutes=@(foreach($r in @($report.probes.registration|Where-Object hive -eq 'LocalMachine'))
    {@{view=$r.view;state=Get-InventoryRoute $r $report.probes.service;activationReady='not tested'}})
    $report.inventoryComplete=$report.errors.Count -eq 0 -and $report.reportingErrors.Count -eq 0
    Write-InventoryJson $report (Join-Path $Output 'inventory.json')
    if(-not$report.inventoryComplete){throw 'Read-only inventory incomplete; closed errors/data retained.'}
}
