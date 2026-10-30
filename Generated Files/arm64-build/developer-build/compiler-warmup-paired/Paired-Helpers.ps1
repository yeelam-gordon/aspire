. (Join-Path $PSScriptRoot ([IO.Path]::Combine('..', 'compiler-cpu-counters', 'Compiler-Identity.ps1')))

function Write-PairedJson($Value, [string]$Path)
{
    ConvertTo-Json -InputObject $Value -Depth 30 | Set-Content -LiteralPath $Path
}

function Assert-PairedNormalPolicy([byte[]]$Original)
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
}

function Get-PairedEdit([byte[]]$Original, [int]$Index)
{
    if ($Index -lt 1 -or $Index -gt 20) { throw 'Only the twenty fixed edits are permitted.' }
    # Identical by index across lifetimes/platforms, regardless of native newline.
    $comment = [Text.Encoding]::UTF8.GetBytes("`r`n// P44 identical owned edit $Index; restored byte-for-byte.`r`n")
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

function Get-PairedEmbeddedDebug([string]$Outputs)
{
    foreach ($project in @('Aspire.Hosting','Aspire.Hosting.Integration.Analyzers'))
    {
        $directory = Join-Path $Outputs ([IO.Path]::Combine('bin', $project))
        $files = @(Get-ChildItem -LiteralPath $directory -Recurse -Filter "$project.dll" -File)
        if (-not $files.Count) { throw "Missing primary output assembly: $project" }
        foreach ($file in $files)
        {
            $stream = [IO.File]::OpenRead($file.FullName)
            $pe = [Reflection.PortableExecutable.PEReader]::new($stream)
            try
            {
                $types = @($pe.ReadDebugDirectory() | ForEach-Object { $_.Type.ToString() })
                if ('EmbeddedPortablePdb' -notin $types) { throw 'Expected original embedded PDB quality.' }
                @{ path = [IO.Path]::GetRelativePath($Outputs, $file.FullName)
                    debugDirectoryTypes = $types; completeAssemblyBytesCompared = $true }
            }
            finally { $pe.Dispose(); $stream.Dispose() }
        }
    }
}

function Test-PairedDispatch([string]$Repository, [string]$Ref, [string]$Event, [string]$Source)
{
    return $Repository -ceq 'yeelam-gordon/aspire' -and
        $Ref -ceq 'refs/heads/perf/arm64-compiler-warmup' -and $Event -ceq 'workflow_dispatch' -and
        $Source -ceq '06efc928e31486923754398007f4f78003e04ee3'
}

function Test-PairedInvocation([string]$Repository, [string]$Ref, [string]$Event,
    [string]$Source, [int]$EditCount, [bool]$LocalSmoke, [bool]$GitHubActions)
{
    if ($LocalSmoke)
    {
        # Local smoke must not fabricate a hosted event or bypass the hosted
        # twenty-edit protocol. The exact product source gate remains mandatory.
        return $EditCount -eq 1 -and -not $GitHubActions -and
            [string]::IsNullOrEmpty($Repository) -and [string]::IsNullOrEmpty($Ref) -and
            [string]::IsNullOrEmpty($Event) -and $Source -ceq '06efc928e31486923754398007f4f78003e04ee3'
    }

    return $EditCount -eq 20 -and (Test-PairedDispatch $Repository $Ref $Event $Source)
}

function Get-PairedPipe([string]$Command)
{
    # Native server commands observed on Windows:
    # ".../VBCSCompiler.exe" "-pipename:EXACT_PRIVATE_NAME"
    # macOS/native command can instead have an unquoted -pipename:NAME token.
    $matches = [regex]::Matches($Command, '(?:^|\s)(?:"-pipename:(?<pipe>[^"\s]+)"|-pipename:(?<pipe>[^"\s]+))(?=\s|$)')
    if ($matches.Count -ne 1) { throw 'Exactly one owned compiler pipe required.' }
    return $matches[0].Groups['pipe'].Value
}

function Assert-PairedCpuValues([double]$User, [double]$Kernel, [double]$Total)
{
    # Getters are sequential, not atomic. Preserve each read timestamp; reject
    # inconsistent/unsupported endpoints instead of manufacturing zero CPU.
    if (-not [double]::IsFinite($User) -or -not [double]::IsFinite($Kernel) -or
        -not [double]::IsFinite($Total) -or $User -lt 0 -or $Kernel -lt 0 -or
        $Total -lt 0 -or [math]::Abs($Total - $User - $Kernel) -gt 0.05)
    {
        throw 'Unsupported/inconsistent process CPU endpoint.'
    }
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

function Get-PairedRuntimeImageHeader([byte[]]$Bytes, [bool]$Windows)
{
    $header = Get-NativeImageHeader $Bytes
    if ($Windows)
    {
        if ($header.format -ne 'PE' -or -not $header.arm64) { throw 'Runtime library must be native ARM64 PE.' }
        return $header
    }

    # P29's executable helper intentionally requires MH_EXECUTE (2). Loaded
    # libcoreclr/libclrjit/libhostpolicy are MH_DYLIB (6), not apphosts; keep
    # their role check separate without accepting universal/fat images.
    # https://github.com/apple-oss-distributions/xnu/blob/main/EXTERNAL_HEADERS/mach-o/loader.h
    if ($header.format -ne 'Mach-O64-thin' -or $header.cpuType -ne '0x0100000C' -or
        [BitConverter]::ToUInt32($Bytes, 12) -ne 6)
    {
        throw 'Runtime library must be a thin native ARM64 MH_DYLIB image.'
    }

    return @{ format = $header.format; cpuType = $header.cpuType; arm64 = $true
        machOFileType = 6; imageRole = 'runtime-library' }
}
