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
$fixture = Join-Path $ResultsDirectory 'output-fixture'
try
{
    $reference = Join-Path $fixture 'reference'
    $actual = Join-Path $fixture 'actual'
    $null = New-Item -ItemType Directory -Path $reference,$actual
    Check 'Dynamic byte equality catches mismatch, missing, extra and empty manifests' {
        $name = [IO.Path]::Combine('locale with space', 'satellite.resources.dll')
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
        [IO.File]::WriteAllBytes((Join-Path $actual 'extra.pdb'), [byte[]]@(1))
        Require (-not (Compare-PairedTrees $reference $actual).passed)
        Remove-Item -LiteralPath (Join-Path $reference $name)
        Remove-Item -LiteralPath (Join-Path $actual 'extra.pdb')
        Require (-not (Compare-PairedTrees $reference $actual).passed)
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
