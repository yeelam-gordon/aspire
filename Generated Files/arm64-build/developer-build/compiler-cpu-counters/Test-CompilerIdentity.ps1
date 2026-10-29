[CmdletBinding()]
param([string]$ResultsDirectory = (Join-Path $PSScriptRoot 'source-checks'))

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Compiler-Identity.ps1')
$null = New-Item -ItemType Directory -Path $ResultsDirectory -Force
$checks = [Collections.Generic.List[object]]::new()
function Check([string]$Name, [scriptblock]$Body)
{
    & $Body
    $checks.Add([pscustomobject]@{ name = $Name; passed = $true })
}
function Require([bool]$Condition)
{
    if (-not $Condition) { throw 'Fixture expectation failed.' }
}
function Reject([scriptblock]$Body)
{
    $failed = $false
    try { & $Body | Out-Null } catch { $failed = $true }
    Require $failed
}

$mac = '/Users/runner/work/aspire owned/product/.dotnet'
$macCompiler = "$mac/sdk/11/Roslyn/bincore/VBCSCompiler"
$macDll = "$macCompiler.dll"
$win = 'Q:\owned\.dotnet'
$winCompiler = "$win\sdk\11\Roslyn\bincore\VBCSCompiler.exe"

Check 'Mac apphost: preserved PID/PPID/comm+args format with spaces' {
    $tail = "$macCompiler `"$macCompiler`" -pipename:abc"
    $parsed = ConvertFrom-MacProcessLine " 123 45 $tail" 123
    Require ($parsed.parentId -eq 45 -and $parsed.commandEvidence -ceq $tail)
    Require ((Get-CompilerProcessKind 'VBCSCompiler' $macCompiler $parsed.commandEvidence $mac $false) -eq 'compiler')
}
Check 'Mac private dotnet exec DLL' {
    $tail = "$mac/dotnet `"$mac/dotnet`" exec `"$macDll`" -pipename:abc"
    $parsed = ConvertFrom-MacProcessLine " 124 45 $tail" 124
    Require ((Get-CompilerProcessKind 'dotnet' "$mac/dotnet" $parsed.commandEvidence $mac $false) -eq 'compiler')
}
Check 'Windows apphost and case-insensitive owned root' {
    Require ((Get-CompilerProcessKind 'VBCSCompiler' $winCompiler "`"$winCompiler`" -pipename:abc" $win.ToLowerInvariant() $true) -eq 'compiler')
}
Check 'Windows private dotnet exec DLL' {
    Require ((Get-CompilerProcessKind 'dotnet' "$win\dotnet.exe" "`"$win\dotnet.exe`" exec `"$win\sdk\11\Roslyn\bincore\VBCSCompiler.dll`" -pipename:abc" $win $true) -eq 'compiler')
}
Check 'MSBuild helper is not compiler' {
    Require ((Get-CompilerProcessKind 'dotnet' "$mac/dotnet" "$mac/dotnet $mac/dotnet $mac/sdk/11/MSBuild.dll /nodemode:1" $mac $false) -eq 'msbuild-helper')
    Require ((Get-CompilerProcessKind 'MSBuild' "$mac/sdk/11/MSBuild" "$mac/sdk/11/MSBuild $mac/sdk/11/MSBuild -nodemode:1" $mac $false) -eq 'msbuild-helper')
}
Check 'Build launcher is not compiler' {
    Require ((Get-CompilerProcessKind 'dotnet' "$mac/dotnet" "$mac/dotnet $mac/dotnet build src/Aspire.Hosting/Aspire.Hosting.csproj" $mac $false) -eq 'other-private-sdk-process')
}
Check 'Reject other root, sibling prefix, traversal and Mac case mismatch' {
    Require (-not (Test-PrivateSdkPath '/other/.dotnet/dotnet' $mac $false))
    Require (-not (Test-PrivateSdkPath "$mac-other/dotnet" $mac $false))
    Require (-not (Test-PrivateSdkPath "$mac/../other/dotnet" $mac $false))
    Require (-not (Test-PrivateSdkPath $macCompiler $mac.ToUpperInvariant() $false))
    Require ((Get-CompilerProcessKind 'dotnet' "$mac/dotnet" "/other/dotnet exec /other/sdk/VBCSCompiler.dll" $mac $false) -ne 'compiler')
    Require ((Get-CompilerProcessKind 'dotnet' "$mac/dotnet" "$mac/dotnet exec `"$mac/../other/VBCSCompiler.dll`"" $mac $false) -ne 'compiler')
    Require ((Get-CompilerProcessKind 'dotnet' "$mac/dotnet" "$mac/dotnet /other/MSBuild.dll /nodemode:1" $mac $false) -ne 'msbuild-helper')
    Require ((Get-CompilerProcessKind 'dotnet' "$mac/dotnet" "$mac/dotnet `"$mac/../other/MSBuild.dll`" /nodemode:1" $mac $false) -ne 'msbuild-helper')
}
Check 'Reject DLL suffix lookalike and dotnet without exec' {
    Require ((Get-CompilerProcessKind 'dotnet' "$mac/dotnet" "$mac/dotnet exec `"$macDll.backup`"" $mac $false) -ne 'compiler')
    Require ((Get-CompilerProcessKind 'dotnet' "$mac/dotnet" "$mac/dotnet `"$macDll`"" $mac $false) -ne 'compiler')
}
Check 'Reject malformed/missing/mismatched ps fields' {
    Reject { ConvertFrom-MacProcessLine '123 45' 123 }
    Reject { ConvertFrom-MacProcessLine 'abc 45 command' 123 }
    Reject { ConvertFrom-MacProcessLine '123 nope command' 123 }
    Reject { ConvertFrom-MacProcessLine '124 45 command' 123 }
    Reject { ConvertFrom-MacProcessLine "123 45 `n124 45 other" 123 }
}
Check 'Exact PID, birth time, executable and root guards' {
    $identity = [pscustomobject]@{ pid = 123; startTicks = 456L; executablePath = $macCompiler }
    Require (Test-OwnedProcessIdentity $identity 123 456 $macCompiler $mac $false)
    Require (-not (Test-OwnedProcessIdentity $identity 124 456 $macCompiler $mac $false))
    Require (-not (Test-OwnedProcessIdentity $identity 123 457 $macCompiler $mac $false))
    Require (-not (Test-OwnedProcessIdentity $identity 123 456 '/other/VBCSCompiler' $mac $false))
    Require (-not (Test-OwnedProcessIdentity $identity 123 456 "$mac/sdk/other/VBCSCompiler" $mac $false))
}
Check 'Thin executable ARM64 Mach-O header and x64 rejection' {
    $bytes = [byte[]]::new(32)
    [BitConverter]::GetBytes([uint32]0xFEEDFACFul).CopyTo($bytes, 0)
    [BitConverter]::GetBytes([uint32]0x0100000C).CopyTo($bytes, 4)
    [BitConverter]::GetBytes([uint32]2).CopyTo($bytes, 12)
    Require ((Get-NativeImageHeader $bytes).arm64)
    [BitConverter]::GetBytes([uint32]0x01000007).CopyTo($bytes, 4)
    Require (-not (Get-NativeImageHeader $bytes).arm64)
    [BitConverter]::GetBytes([uint32]0x0100000C).CopyTo($bytes, 4)
    [BitConverter]::GetBytes([uint32]6).CopyTo($bytes, 12)
    Require (-not (Get-NativeImageHeader $bytes).arm64)
}
Check 'ARM64 PE header and x64 rejection' {
    $bytes = [byte[]]::new(128)
    $bytes[0] = 0x4d; $bytes[1] = 0x5a
    [BitConverter]::GetBytes([int]64).CopyTo($bytes, 0x3c)
    [BitConverter]::GetBytes([uint32]0x4550).CopyTo($bytes, 64)
    [BitConverter]::GetBytes([uint16]0xAA64).CopyTo($bytes, 68)
    Require ((Get-NativeImageHeader $bytes).arm64)
    $fixture = Join-Path $ResultsDirectory 'native-header.fixture'
    if (Test-Path -LiteralPath $fixture) { throw 'Refusing to overwrite an existing native-header fixture.' }
    try
    {
        [IO.File]::WriteAllBytes($fixture, $bytes)
        Require ((Get-NativeImageIdentity $fixture).header.arm64)
        [BitConverter]::GetBytes([uint16]0x8664).CopyTo($bytes, 68)
        [IO.File]::WriteAllBytes($fixture, $bytes)
        Reject { Get-NativeImageIdentity $fixture }
    }
    finally { Remove-Item -LiteralPath $fixture -ErrorAction SilentlyContinue }
    [BitConverter]::GetBytes([uint16]0x8664).CopyTo($bytes, 68)
    Require (-not (Get-NativeImageHeader $bytes).arm64)
    [BitConverter]::GetBytes([int]2000).CopyTo($bytes, 0x3c)
    Reject { Get-NativeImageHeader $bytes }
}
Check 'Reject truncated, universal and unknown native headers' {
    Reject { Get-NativeImageHeader ([byte[]]@(0xcf, 0xfa, 0xed, 0xfe)) }
    $fat = [byte[]]::new(32)
    $fat[0] = 0xca; $fat[1] = 0xfe; $fat[2] = 0xba; $fat[3] = 0xbe
    Reject { Get-NativeImageHeader $fat }
    Reject { Get-NativeImageHeader ([byte[]]::new(64)) }
}

[pscustomobject]@{
    scope = 'Pure source fixtures only: no process launch, build, counter sampling, idle observation or Mac API execution.'
    checks = @($checks.ToArray())
    macRunnerCoverage = 'unverified'
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $ResultsDirectory 'identity-fixtures.json')
Write-Host "$($checks.Count) identity/header/safety fixture groups passed; no workload executed."
