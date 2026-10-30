. (Join-Path $PSScriptRoot ([IO.Path]::Combine('..', 'compiler-cpu-counters', 'Compiler-Identity.ps1')))

function Write-PairedJson($Value, [string]$Path)
{
    ConvertTo-Json -InputObject $Value -Depth 30 | Set-Content -LiteralPath $Path
}

function New-PgoCandidate([byte[]]$Original)
{
    $baseline = [Text.Encoding]::UTF8.GetString($Original) | ConvertFrom-Json -AsHashtable
    foreach ($key in @('System.Runtime.TieredPGO', 'System.Runtime.TieredCompilation',
        'System.Runtime.TieredCompilation.QuickJit', 'System.Runtime.TieredCompilation.QuickJitForLoops',
        'System.Runtime.ReadyToRun'))
    {
        if ($baseline.runtimeOptions.configProperties.ContainsKey($key))
        {
            throw "Unexpected original SDK policy: $key"
        }
    }
    $candidate = [Text.Encoding]::UTF8.GetString($Original) | ConvertFrom-Json -AsHashtable
    $candidate.runtimeOptions.configProperties['System.Runtime.TieredPGO'] = $false
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $candidate -Depth 20))
    $check = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -AsHashtable
    $null = $check.runtimeOptions.configProperties.Remove('System.Runtime.TieredPGO')
    if ((ConvertTo-Json $check -Depth 20 -Compress) -cne (ConvertTo-Json $baseline -Depth 20 -Compress))
    {
        throw 'Candidate changes more than TieredPGO.'
    }
    return ,$bytes
}

function Get-PairedEdit([byte[]]$Original, [int]$Index)
{
    if ($Index -lt 1 -or $Index -gt 8) { throw 'Only the eight fixed edits are permitted.' }
    # Match the frozen P38 comment bytes, independently of platform line endings.
    $comment = [Text.Encoding]::UTF8.GetBytes("`r`n// P38 identical owned edit $Index; restored byte-for-byte.`r`n")
    return ,[byte[]]($Original + $comment)
}

function Compare-PairedTrees([string]$Reference, [string]$Actual)
{
    $paths = @(Get-ChildItem -LiteralPath $Reference -Recurse -File |
        ForEach-Object { [IO.Path]::GetRelativePath($Reference, $_.FullName) } | Sort-Object -CaseSensitive)
    $other = @(Get-ChildItem -LiteralPath $Actual -Recurse -File |
        ForEach-Object { [IO.Path]::GetRelativePath($Actual, $_.FullName) } | Sort-Object -CaseSensitive)
    $differences = @()
    if (($paths | ConvertTo-Json -Compress) -cne ($other | ConvertTo-Json -Compress))
    {
        $differences += 'manifest'
    }
    foreach ($relative in $paths)
    {
        $target = Join-Path $Actual $relative
        if (-not (Test-Path -LiteralPath $target) -or -not [Linq.Enumerable]::SequenceEqual[byte](
            [IO.File]::ReadAllBytes((Join-Path $Reference $relative)), [IO.File]::ReadAllBytes($target)))
        {
            $differences += $relative
        }
    }
    return @{ reference = $Reference; actual = $Actual; count = $paths.Count; differences = $differences
        passed = $paths.Count -gt 0 -and $differences.Count -eq 0 }
}

function Get-PairedOutputFiles([string]$Root)
{
    # Shared Windows/macOS P38 scope: all final bin files (including satellite
    # locales), plus emitted source/resources/XML/JSON/assemblies/PDBs under obj.
    # Non-emitted obj caches, file lists, editorconfig, response files and logs
    # are not compiler outputs. No locale/framework-specific exclusions.
    foreach ($project in @('Aspire.Hosting', 'Aspire.Hosting.Integration.Analyzers'))
    {
        foreach ($kind in @('bin', 'obj'))
        {
            $directory = Join-Path $Root ([IO.Path]::Combine('artifacts', $kind, $project, 'Debug'))
            if (-not (Test-Path -LiteralPath $directory)) { throw "Missing output root: $directory" }
            Get-ChildItem -LiteralPath $directory -Recurse -File |
                Where-Object { $kind -eq 'bin' -or $_.Extension -in @('.cs', '.resources', '.xml', '.json', '.dll', '.pdb') }
        }
    }
}

function Test-PairedDispatch([string]$Repository, [string]$Ref, [string]$Event, [string]$Source)
{
    return $Repository -ceq 'yeelam-gordon/aspire' -and
        $Ref -ceq 'refs/heads/perf/arm64-compiler-pgo' -and $Event -ceq 'workflow_dispatch' -and
        $Source -ceq '06efc928e31486923754398007f4f78003e04ee3'
}

function ConvertFrom-PairedMacState([string]$Line, [int]$ExpectedPid)
{
    # Native diagnostic shape (lstart is five fields, command may contain spaces):
    # 5673 3992 Z Fri Oct 30 01:23:45 2026 /owned/.dotnet/.../VBCSCompiler
    $match = [regex]::Match($Line.Trim(),
        '^(?<pid>\d+)\s+(?<parent>\d+)\s+(?<state>\S+)\s+(?<start>\S+\s+\S+\s+\d+\s+\S+\s+\d{4})\s+(?<path>.+)$')
    if (-not $match.Success -or [int]$match.Groups['pid'].Value -ne $ExpectedPid)
    {
        throw 'Malformed/mismatched native ps state; absence not established.'
    }
    return @{ pid = $ExpectedPid; parentPid = [int]$match.Groups['parent'].Value
        state = $match.Groups['state'].Value; nativeStart = $match.Groups['start'].Value
        nativePath = $match.Groups['path'].Value }
}

function Test-PairedAbsence([bool]$RuntimePresent, [int]$NativeExitCode, [string[]]$NativeLines)
{
    # ps exit 1 plus empty headerless output is the only accepted native absence.
    # Z/state output, permission errors, and PID reuse are never success fallbacks.
    return -not $RuntimePresent -and $NativeExitCode -eq 1 -and $NativeLines.Count -eq 0
}

function Get-PairedPendingIdentities($Observed, $Current, $ConfirmedExited)
{
    # A formerly observed compiler can disappear from name/path enumeration
    # while native ps still retains it (for example as a zombie). Never drop
    # that identity until a separate exact absence receipt has been confirmed.
    $pending = @{}
    foreach ($identity in @($Observed.Values) + @($Current))
    {
        $key = "$($identity.pid):$($identity.startTicks)"
        if (-not $ConfirmedExited.ContainsKey($key)) { $pending[$key] = $identity }
    }
    return @($pending.Values)
}
