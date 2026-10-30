[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Sdk,
    [Parameter(Mandatory)][string]$TraceEventPackage,
    [Parameter(Mandatory)][string]$Output
)
. (Join-Path $PSScriptRoot 'Helpers.ps1')
if (Test-Path -LiteralPath $Output) { throw 'Refusing build output overwrite.' }
$null = New-Item -ItemType Directory -Path $Output
$Output = (Resolve-Path $Output).Path
$version = '11.0.100-rc.2.26504.105'
$runtime = '11.0.0-rc.2.26504.105'
$hostPath = Join-Path $Sdk 'dotnet.exe'
if ((Get-CpuPeMachine $hostPath) -ne '0xAA64') { throw 'Compiler host must be native ARM64.' }
$refs = Join-Path $Sdk "packs\Microsoft.NETCore.App.Ref\$runtime\ref\net11.0"
$library = Join-Path $TraceEventPackage 'lib\netstandard2.0'
$traceEvent = Join-Path $library 'Microsoft.Diagnostics.Tracing.TraceEvent.dll'
if ([Reflection.AssemblyName]::GetAssemblyName($traceEvent).Version.ToString() -cne '3.1.28.0')
{
    throw 'Require existing pinned TraceEvent 3.1.28.'
}
foreach ($name in @('KnownWork', 'CpuDecoder'))
{
    $arguments = @('/nostdlib+', '/target:exe', '/langversion:preview',
        '/nullable:enable', '/deterministic+', '/debug:portable',
        "/out:`"$Output\$name.dll`"")
    $arguments += @(Get-ChildItem -LiteralPath $refs -Filter '*.dll' | ForEach-Object { "/reference:`"$($_.FullName)`"" })
    if ($name -eq 'CpuDecoder')
    {
        $arguments += @(Get-ChildItem -LiteralPath $library -Filter '*.dll' | ForEach-Object { "/reference:`"$($_.FullName)`"" })
    }
    $arguments += "`"$PSScriptRoot\$name.cs`""
    $rsp = Join-Path $Output "$name.rsp"
    $arguments | Set-Content -LiteralPath $rsp
    # Direct pinned csc has no compiler-server path: no MSBuild, restore or Arcade.
    # Equivalent to fixture-only UseSharedCompilation=false, without touching SDK files.
    $owned = Start-CpuProcess $hostPath @((Join-Path $Sdk "sdk\$version\Roslyn\bincore\csc.dll"), '/noconfig', "@$rsp") (Join-Path $Output "$name.compile")
    $receipt = Complete-CpuProcess $owned 60
    if ($receipt.timedOut -or $receipt.exitCode -ne 0) { throw "Standalone $name compilation failed." }
    Write-CpuJson @{ runtimeOptions = @{ tfm = 'net11.0'; framework = @{ name = 'Microsoft.NETCore.App'; version = $runtime }; rollForward = 'Disable' } } (Join-Path $Output "$name.runtimeconfig.json")
}
Get-ChildItem -LiteralPath $library -Filter '*.dll' | Copy-Item -Destination $Output
$native = Join-Path $Output 'arm64'
$null = New-Item -ItemType Directory -Path $native
Copy-Item -LiteralPath (Join-Path $TraceEventPackage 'build\native\arm64\KernelTraceControl.dll') -Destination $native
Write-CpuJson @{
    sdk = $Sdk; compilerVersion = $version; runtime = $runtime; traceEventVersion = '3.1.28'
    nativeKernelTraceControl = Get-CpuPeMachine (Join-Path $native 'KernelTraceControl.dll')
    sdkReadOnly = $true; msbuildOrRestore = $false; compilerServerUsed = $false
} (Join-Path $Output 'build.json')
