function Test-PrivateSdkPath([string]$Path, [string]$SdkRoot, [bool]$Windows)
{
    $comparison = if ($Windows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $normalized = $Path.Replace('\', '/')
    $prefix = $SdkRoot.Replace('\', '/').TrimEnd('/') + '/'
    # Process paths are absolute; reject lexical parent traversal as well as root
    # lookalikes so fixtures and command-line evidence cannot broaden ownership.
    return $normalized.StartsWith($prefix, $comparison) -and $normalized -notmatch '(^|/)\.\.?(/|$)'
}

function Get-CompilerProcessKind([string]$Name, [string]$Executable, [string]$CommandEvidence, [string]$SdkRoot, [bool]$Windows)
{
    if (-not (Test-PrivateSdkPath $Executable $SdkRoot $Windows)) { return 'other-private-sdk-process' }
    $options = if ($Windows) { [Text.RegularExpressions.RegexOptions]::IgnoreCase } else { [Text.RegularExpressions.RegexOptions]::None }
    # Preserve the private-path shape from Measure-DeveloperBuild.ps1. The root
    # itself may contain spaces; quotes/whitespace delimit the executable or DLL.
    $compilerPattern = '(?:^|[\s"])(?<compilerPath>' + [regex]::Escape($SdkRoot.TrimEnd([char[]]'\/')) +
        '[\\/](?:[^"\s]+[\\/])*VBCSCompiler(?:\.exe|\.dll)?)(?=["\s]|$)'
    $leaf = ($Executable -split '[\\/]')[-1]
    $compilerMatch = [regex]::Match($CommandEvidence, $compilerPattern, $options)
    if ($compilerMatch.Success -and (Test-PrivateSdkPath $compilerMatch.Groups['compilerPath'].Value $SdkRoot $Windows) -and
        (($Name -eq 'VBCSCompiler' -and $leaf -in @('VBCSCompiler', 'VBCSCompiler.exe')) -or
         ($Name -eq 'dotnet' -and $CommandEvidence -match '\s+exec\s+')))
    {
        return 'compiler'
    }
    $helperPattern = '(?:^|[\s"])(?<helperPath>' + [regex]::Escape($SdkRoot.TrimEnd([char[]]'\/')) +
        '[\\/](?:[^"\s]+[\\/])*MSBuild(?:\.exe|\.dll)?)(?=["\s]|$)'
    $helperMatch = [regex]::Match($CommandEvidence, $helperPattern, $options)
    if ($helperMatch.Success -and (Test-PrivateSdkPath $helperMatch.Groups['helperPath'].Value $SdkRoot $Windows) -and
        $CommandEvidence -match '[/-](nodemode|taskhost)(?=[:\s]|$)')
    {
        return 'msbuild-helper'
    }
    return 'other-private-sdk-process'
}

function ConvertFrom-MacProcessLine([string]$Line, [int]$ExpectedPid)
{
    # Keep the existing `ps -o 'pid=,ppid=,comm=,args='` delimiter contract:
    #   123 45 /owned/.dotnet/dotnet /owned/.dotnet/dotnet exec "/owned/.dotnet/sdk/11/Roslyn/bincore/VBCSCompiler.dll" -pipename:abc
    #   124 45 /owned/.dotnet/sdk/11/Roslyn/bincore/VBCSCompiler /owned/.dotnet/sdk/11/Roslyn/bincore/VBCSCompiler -pipename:abc
    # Split into THREE fields only: PID, PPID, and the untouched comm+args tail.
    # Paths/arguments in that tail may contain spaces; do not tokenize them.
    $fields = $Line.Trim() -split '\s+', 3
    $processId = $parentId = 0
    if ($Line -match '[\r\n]' -or $fields.Count -ne 3 -or -not [int]::TryParse($fields[0], [ref]$processId) -or
        -not [int]::TryParse($fields[1], [ref]$parentId) -or $processId -ne $ExpectedPid -or
        $processId -le 0 -or $parentId -lt 0 -or [string]::IsNullOrWhiteSpace($fields[2]))
    {
        throw 'Missing/malformed or mismatched private-PID ps identity.'
    }
    return [pscustomobject]@{ processId = $processId; parentId = $parentId; commandEvidence = $fields[2] }
}

function Test-OwnedProcessIdentity($Identity, [int]$ProcessId, [long]$StartTicks, [string]$Executable, [string]$SdkRoot, [bool]$Windows)
{
    $comparison = if ($Windows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return $ProcessId -eq $Identity.pid -and $StartTicks -eq $Identity.startTicks -and
        (Test-PrivateSdkPath $Executable $SdkRoot $Windows) -and
        [string]::Equals($Executable, $Identity.executablePath, $comparison)
}

function Get-NativeImageHeader([byte[]]$Bytes)
{
    if ($Bytes.Length -ge 64 -and $Bytes[0] -eq 0x4d -and $Bytes[1] -eq 0x5a)
    {
        $pe = [BitConverter]::ToInt32($Bytes, 0x3c)
        if ($pe -lt 0 -or $pe -gt $Bytes.Length - 6 -or [BitConverter]::ToUInt32($Bytes, $pe) -ne 0x4550)
        {
            throw 'Invalid/truncated PE header.'
        }
        $machine = [BitConverter]::ToUInt16($Bytes, $pe + 4)
        return [pscustomobject]@{ format = 'PE'; cpuType = ('0x{0:X4}' -f $machine); arm64 = $machine -eq 0xAA64 }
    }
    # Thin, little-endian Mach-O64: CF FA ED FE, then cpu_type_t at byte 4.
    # CPU_TYPE_ARM64 = CPU_TYPE_ARM | CPU_ARCH_ABI64 = 0x0100000C.
    # https://github.com/apple-oss-distributions/xnu/blob/main/EXTERNAL_HEADERS/mach-o/loader.h
    # https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/machine.h
    # Universal/fat or swapped headers are deliberately rejected: a slice list
    # alone would not prove the actual executing compiler architecture.
    if ($Bytes.Length -ge 32 -and [BitConverter]::ToUInt32($Bytes, 0) -eq 0xFEEDFACFul)
    {
        $cpu = [BitConverter]::ToUInt32($Bytes, 4)
        $fileType = [BitConverter]::ToUInt32($Bytes, 12)
        return [pscustomobject]@{
            format = 'Mach-O64-thin'; cpuType = ('0x{0:X8}' -f $cpu)
            arm64 = $cpu -eq 0x0100000C -and $fileType -eq 2
        }
    }
    throw 'Unsupported/truncated native image header (including universal Mach-O).'
}

function Get-NativeImageIdentity([string]$Executable)
{
    # Read only a bounded header, not process modules or a system-wide image list.
    $stream = [IO.File]::OpenRead($Executable)
    try
    {
        $bytes = [byte[]]::new([int][math]::Min(4096, $stream.Length))
        $stream.ReadExactly($bytes, 0, $bytes.Length)
        $header = Get-NativeImageHeader $bytes
        if (-not $header.arm64) { throw 'Compiler/SDK executable is not a supported native ARM64 image.' }
        return [pscustomobject]@{ executablePath = $Executable; header = $header }
    }
    finally { $stream.Dispose() }
}
