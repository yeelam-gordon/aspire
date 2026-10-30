[CmdletBinding()]
param([Parameter(Mandatory)][string]$RepositoryRoot, [Parameter(Mandatory)][string]$Output)
. (Join-Path $PSScriptRoot 'Bootstrap-Sdk.ps1')
if (Test-Path -LiteralPath $Output) { throw 'Refusing bootstrap test evidence overwrite.' }
$null = New-Item -ItemType Directory -Path $Output
$sdk = Join-Path $Output 'must-not-be-installed'
$evidence = Join-Path $Output 'negative'
$originalEnvironment = @{}
foreach ($name in @('PATH', 'TEMP', 'TMP', 'DOTNET_ROOT', 'DOTNET_CLI_HOME', 'DOTNET_NOLOGO'))
{
    $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$caught = $false
try
{
    $null = Invoke-NativeSdkInstaller (Join-Path $PSScriptRoot 'bootstrap-tests\ThrowingInstaller.ps1') $sdk '11.0.100-rc.2.26504.105' $evidence
}
catch { $caught = $true }
$bound = Get-Content (Join-Path $Output 'actual-bound-arguments.json') -Raw | ConvertFrom-Json
$receipt = Get-Content (Join-Path $evidence 'installer.receipt.json') -Raw | ConvertFrom-Json
$stderr = Get-Content (Join-Path $evidence 'installer.stderr.log') -Raw
$passed = $caught -and $receipt.exitCode -ne 0 -and -not $receipt.timedOut -and $receipt.outputComplete -and
    $bound.version -ceq '11.0.100-rc.2.26504.105' -and $bound.architecture -ceq 'arm64' -and
    $bound.installDir -ceq $sdk -and $bound.noPath -and -not $bound.runtimeBound -and
    -not $bound.keepZip -and $bound.downloadTimeout -eq 120 -and $bound.zipPath -ceq (Join-Path $evidence 'sdk-payload.archive') -and
    $stderr.Contains('SDK_BOOTSTRAP_SENTINEL: original controlled installer failure') -and
    -not (Test-Path -LiteralPath $sdk)
if (-not $passed) { throw 'Actual SDK argv/original-error retention fixture failed.' }
foreach ($name in $originalEnvironment.Keys)
{
    if ([Environment]::GetEnvironmentVariable($name, 'Process') -cne $originalEnvironment[$name])
    {
        throw "SDK failure leaked process environment: $name"
    }
}

$existing = Join-Path $Output 'existing-sdk'
$null = New-Item -ItemType Directory -Path $existing
$existingRejected = $false
try
{
    $null = Invoke-NativeSdkInstaller (Join-Path $PSScriptRoot 'bootstrap-tests\ThrowingInstaller.ps1') $existing '11.0.100-rc.2.26504.105' (Join-Path $Output 'must-not-exist')
}
catch { $existingRejected = $true }
if (-not $existingRejected -or (Test-Path (Join-Path $Output 'must-not-exist')))
{
    throw 'Existing SDK overlay was not rejected before side effects.'
}
$localSetupRejected = $null
if ($env:GITHUB_ACTIONS -cne 'true')
{
    $forbidden = Join-Path $Output 'forbidden-local-setup'
    $child = Start-CpuProcess (Get-Process -Id $PID).Path @(
        '-NoProfile', '-File', (Join-Path $PSScriptRoot 'Setup-Hosted.ps1'),
        '-RepositoryRoot', $RepositoryRoot, '-Evidence', $forbidden
    ) (Join-Path $Output 'local-setup-rejection')
    $result = Complete-CpuProcess $child 10
    $localSetupRejected = $result.exitCode -ne 0 -and -not $result.timedOut -and -not (Test-Path $forbidden)
    if (-not $localSetupRejected) { throw 'Hosted setup local guard failed.' }
}
Write-CpuJson @{
    passed = $true; actualBoundArguments = $bound; originalFailureRetained = $true
    negativeReceipt = $receipt; existingTargetRejectedBeforeSideEffects = $existingRejected
    hostedSetupLocalRejection = $localSetupRejected; processEnvironmentRestored = $true
    actualSdkInstallation = $false; recordings = 0
} (Join-Path $Output 'tests.json')
