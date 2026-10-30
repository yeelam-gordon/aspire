. (Join-Path $PSScriptRoot 'Helpers.ps1')

function Get-NativeSdkInstallerArguments([string]$Installer, [string]$Sdk, [string]$Version, [string]$Evidence)
{
    # SDK is the official installer's default product. Runtime accepts only shared
    # runtimes, not "sdk": https://learn.microsoft.com/dotnet/core/tools/dotnet-install-script
    return @('-NoProfile', '-File', $Installer, '-Version', $Version,
        '-Architecture', 'arm64', '-InstallDir', $Sdk, '-NoPath',
        '-ZipPath', (Join-Path $Evidence 'sdk-payload.archive'), '-DownloadTimeout', '120')
}

function Invoke-NativeSdkInstaller([string]$Installer, [string]$Sdk, [string]$Version, [string]$Evidence)
{
    if (-not [IO.Path]::IsPathFullyQualified($Sdk) -or (Test-Path -LiteralPath $Sdk))
    {
        throw 'SDK installation requires a fresh absolute target; no overlay/installed-version skip.'
    }
    if (Test-Path -LiteralPath (Join-Path $Evidence 'installer.receipt.json'))
    {
        throw 'Refusing installer invocation overwrite or retry.'
    }
    if (-not (Test-Path -LiteralPath $Evidence)) { $null = New-Item -ItemType Directory -Path $Evidence }
    $workspace = Join-Path $Evidence 'process-work'
    $null = New-Item -ItemType Directory -Path $workspace
    $arguments = @(Get-NativeSdkInstallerArguments $Installer $Sdk $Version $Evidence)
    Write-CpuJson @{
        executable = (Get-Process -Id $PID).Path; arguments = $arguments
        installer = $Installer; sdk = $Sdk; targetExistedBefore = $false
        processWorkspace = $workspace; pathModificationRequested = $false; runtimeArgument = 'omitted: SDK default'
    } (Join-Path $Evidence 'invocation.json')
    $saved = @{}
    # Scope installer download/extraction scratch to the owned evidence directory.
    # These are process-only variables, restored even when the child fails.
    foreach ($name in @('TEMP', 'TMP', 'DOTNET_ROOT', 'DOTNET_CLI_HOME', 'DOTNET_CLI_UI_LANGUAGE',
        'DOTNET_GENERATE_ASPNET_CERTIFICATE', 'DOTNET_ADD_GLOBAL_TOOLS_TO_PATH', 'DOTNET_NOLOGO',
        'DOTNET_CLI_TELEMETRY_OPTOUT'))
    {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    try
    {
        $env:TEMP = $workspace; $env:TMP = $workspace
        $env:DOTNET_ROOT = $Sdk; $env:DOTNET_CLI_HOME = $workspace
        $env:DOTNET_CLI_UI_LANGUAGE = 'en'
        $env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
        $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH = 'false'
        $env:DOTNET_NOLOGO = 'true'; $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
        $child = Start-CpuProcess (Get-Process -Id $PID).Path $arguments (Join-Path $Evidence 'installer')
        $receipt = Complete-CpuProcess $child 300
        if ($receipt.timedOut -or $receipt.exitCode -ne 0)
        {
            # Do not discard the original error as eng/common's location fallback
            # does. Both raw streams and the exact child receipt survive failure.
            throw "Official SDK installer failed. Original stdout/stderr and receipt: $Evidence"
        }
        Confirm-NativeSdk $Sdk $Version $Evidence $receipt
        return $receipt
    }
    finally
    {
        foreach ($name in $saved.Keys)
        {
            if ($null -eq $saved[$name])
            {
                # Preserve missing versus empty variables; binding $null to the
                # .NET string setter can otherwise leave an empty process value.
                Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue
            }
            else
            {
                [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
            }
        }
    }
}

function Invoke-NativeSdkBootstrap([string]$RepositoryRoot, [string]$Sdk, [string]$Evidence)
{
    if (-not $IsWindows -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -cne 'Arm64' -or
        [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() -cne 'Arm64')
    {
        throw 'SDK bootstrap requires native ARM64 Windows/PowerShell.'
    }
    if (Test-Path -LiteralPath $Sdk) { throw 'Private SDK must be absent before bootstrap.' }
    if (Test-Path -LiteralPath $Evidence) { throw 'Refusing bootstrap evidence overwrite.' }
    $version = (Get-Content (Join-Path $RepositoryRoot 'global.json') -Raw | ConvertFrom-Json).sdk.version
    if ($version -cne '11.0.100-rc.2.26504.105') { throw 'Unexpected P44 SDK pin.' }
    $null = New-Item -ItemType Directory -Path $Evidence
    $uri = 'https://builds.dotnet.microsoft.com/dotnet/scripts/v1/dotnet-install.ps1'
    $installer = Join-Path $Evidence 'official-dotnet-install.ps1'
    try
    {
        $response = Invoke-WebRequest $uri -OutFile $installer -PassThru -TimeoutSec 60
        Write-CpuJson @{
            uri = $uri; finalUri = $response.BaseResponse.RequestMessage.RequestUri.AbsoluteUri
            statusCode = [int]$response.StatusCode; downloadedUtc = [DateTime]::UtcNow.ToString('O')
            bytes = (Get-Item -LiteralPath $installer).Length
            etag = $response.Headers.ETag; lastModified = $response.Headers.'Last-Modified'
            executedInput = $installer; sdkVersion = $version; toolOrFeedOverride = $false
        } (Join-Path $Evidence 'installer-provenance.json')
    }
    catch
    {
        $_ | Out-String | Set-Content (Join-Path $Evidence 'download-failure.txt')
        throw
    }
    $null = Invoke-NativeSdkInstaller $installer $Sdk $version $Evidence
}

function Confirm-NativeSdk([string]$Sdk, [string]$Version, [string]$Evidence, $Receipt)
{
    $hostPath = Join-Path $Sdk 'dotnet.exe'
    $runtime = Join-Path $Sdk 'shared\Microsoft.NETCore.App\11.0.0-rc.2.26504.105\coreclr.dll'
    if ((Get-CpuPeMachine $hostPath) -ne '0xAA64' -or (Get-CpuPeMachine $runtime) -ne '0xAA64')
    {
        throw 'Fresh SDK host/runtime is not native ARM64.'
    }
    foreach ($command in @('--version', '--info', '--list-sdks', '--list-runtimes'))
    {
        $name = $command.TrimStart('-')
        $child = Start-CpuProcess $hostPath @($command) (Join-Path $Evidence $name)
        $result = Complete-CpuProcess $child 15
        if ($result.timedOut -or $result.exitCode -ne 0) { throw "Fresh SDK $command failed." }
    }
    if ((Get-Content (Join-Path $Evidence 'version.stdout.log') -Raw).Trim() -cne $Version)
    {
        throw 'Fresh SDK reported a different version.'
    }
    # dotnet --info prints " Base Path: C:\owned\sdk\sdk\<version>\".
    # Verify actual SDK resolution, not just a similarly named directory.
    $info = Get-Content (Join-Path $Evidence 'info.stdout.log') -Raw
    $basePath = [regex]::Match($info, '(?m)^\s*Base Path:\s*(?<path>[^\r\n]+)')
    $expectedBase = Join-Path $Sdk "sdk\$Version"
    if (-not $basePath.Success -or
        -not [string]::Equals($basePath.Groups['path'].Value.Trim().TrimEnd('\'), $expectedBase, [StringComparison]::OrdinalIgnoreCase) -or
        $info -notmatch '(?m)^\s+Architecture:\s+arm64\s*$')
    {
        throw 'Actual SDK base path/native host identity did not match the fresh target.'
    }
    Write-CpuJson @{
        sdk = $Sdk; version = $Version; basePath = $expectedBase; fresh = $true
        hostMachine = Get-CpuPeMachine $hostPath; runtimeMachine = Get-CpuPeMachine $runtime
        hostFileVersion = (Get-Item -LiteralPath $hostPath).VersionInfo.FileVersion
        runtimeFileVersion = (Get-Item -LiteralPath $runtime).VersionInfo.FileVersion
        installerReceipt = $Receipt; productRestore = $false; sharedEngCommonModified = $false
    } (Join-Path $Evidence 'native-sdk.json')
}
