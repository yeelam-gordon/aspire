[CmdletBinding()]
param([Parameter(Mandatory)][string]$Sdk,[Parameter(Mandatory)][string]$TraceEventPackage,[Parameter(Mandatory)][string]$Output)
$p48=Split-Path $PSScriptRoot -Parent
& (Join-Path $p48 'Build-Tools.ps1') -Sdk $Sdk -TraceEventPackage $TraceEventPackage -Output $Output
. (Join-Path $p48 'Helpers.ps1')
$version='11.0.100-rc.2.26504.105'
$sdkBin=Join-Path $Sdk "sdk\$version"
$refs=Join-Path $Sdk 'packs\Microsoft.NETCore.App.Ref\11.0.0-rc.2.26504.105\ref\net11.0'
foreach($name in @('BinlogReader','CompilerSymbols'))
{
    $args=@('/nostdlib+','/target:exe','/langversion:preview','/nullable:enable','/deterministic+','/debug:portable',"/out:`"$Output\$name.dll`"")
    $args+=@(Get-ChildItem $refs -Filter '*.dll'|ForEach-Object{"/reference:`"$($_.FullName)`""})
    if($name -eq 'BinlogReader'){$args+=@("/reference:`"$sdkBin\Microsoft.Build.dll`"","/reference:`"$sdkBin\Microsoft.Build.Framework.dll`"")}
    else{$args+=@("/reference:`"$Output\Microsoft.Diagnostics.Tracing.TraceEvent.dll`"","/reference:`"$Output\Microsoft.Diagnostics.FastSerialization.dll`"")}
    $args+="`"$PSScriptRoot\$name.cs`""
    $rsp=Join-Path $Output "$name.rsp"; $args|Set-Content $rsp
    $child=Start-CpuProcess (Join-Path $Sdk 'dotnet.exe') @((Join-Path $sdkBin 'Roslyn\bincore\csc.dll'),'/noconfig',"@$rsp") (Join-Path $Output "$name.compile")
    $receipt=Complete-CpuProcess $child 60
    if($receipt.exitCode -ne 0 -or $receipt.timedOut){throw "$name compilation failed."}
    Copy-Item (Join-Path $Output 'CpuDecoder.runtimeconfig.json') (Join-Path $Output "$name.runtimeconfig.json")
}
foreach($file in @('Microsoft.Build.dll','Microsoft.Build.Framework.dll','Microsoft.Build.Utilities.Core.dll','Microsoft.NET.StringTools.dll','System.Resources.Extensions.dll','Newtonsoft.Json.dll'))
{Copy-Item (Join-Path $sdkBin $file) $Output}
