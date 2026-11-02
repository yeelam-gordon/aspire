# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

[CmdletBinding()]
param([Parameter(Mandatory)][string]$SourceRoot)

. (Join-Path $PSScriptRoot 'Hobl.ps1')
$manifest = Get-Content (Join-Path $PSScriptRoot 'manifest.json') -Raw | ConvertFrom-Json -AsHashtable
$head = & git -C $SourceRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $head -ne $manifest.source.commit) { throw 'Use the exact pinned source clone.' }
$inputs = @('global.json', 'eng/common/tools.sh', 'eng/common/pipeline-logging-functions.sh')
& git -C $SourceRoot -c core.longpaths=true diff --exit-code HEAD -- @inputs
if ($LASTEXITCODE -ne 0) { throw 'Pinned routing inputs have local modifications.' }
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$fixture = Join-Path $repoRoot ('artifacts\hobl\routing-validation-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $fixture 'source'
$null = New-Item -ItemType Directory -Path (Join-Path $source 'eng\common')
foreach ($relative in $inputs) {
    Copy-Item -LiteralPath (Join-Path $SourceRoot $relative) -Destination (Join-Path $source $relative)
}
$correct = Get-HoblDotnetRoot $fixture 'macos' 'original'
$wrong = Get-HoblDotnetRoot $fixture 'macos' 'aligned'
$version = $manifest.toolchain.sdks[-1]
$correctVersion = Join-Path (Join-Path $correct 'sdk') $version
$null = New-Item -ItemType Directory -Path $correctVersion
$null = New-Item -ItemType Directory -Path (Join-Path (Join-Path $wrong 'sdk') $version)
$probe = New-HoblWrapperProbe $fixture
$bash = if ($IsWindows) {
    Join-Path (Split-Path (Split-Path (Get-Command git.exe).Source -Parent) -Parent) 'bin\bash.exe'
}
else { '/bin/bash' }
if (-not (Test-Path -LiteralPath $bash)) { throw "Required Bash is unavailable: $bash" }
$environment = @{ DOTNET_INSTALL_DIR = $wrong; TEMP = $fixture; TMP = $fixture; TMPDIR = $fixture }
$common = @{ WorkingDirectory = $source; Environment = $environment
    Deadline = [datetime]::UtcNow.AddSeconds(30); BudgetRoot = $fixture; BudgetBytes = 10MB }
$record = Invoke-HoblProcess -Argv @($bash, '--noprofile', '--norc', $probe, $source) -Log (Join-Path $fixture 'selected.log') @common
$selected = @(Select-String -LiteralPath $record.stdout -Pattern '^HOBL_DOTNET_ROOT=(.+)$')
if ($selected.Count -ne 1 -or $selected[0].Matches[0].Groups[1].Value -ne $correct) {
    throw 'Pinned tools.sh did not select the original Mac source/.dotnet root.'
}
# The decoy SDK remains present: removing only the owned empty expected SDK
# directory must fail, rather than silently falling back to DOTNET_INSTALL_DIR.
Assert-HoblPath $correctVersion $fixture
Remove-Item -LiteralPath $correctVersion
$rejected = $false
try {
    $null = Invoke-HoblProcess -Argv @($bash, '--noprofile', '--norc', $probe, $source) -Log (Join-Path $fixture 'missing.log') @common
}
catch { $rejected = $true }
if (-not $rejected) { throw 'Pinned wrapper silently used the unverified decoy SDK.' }
[ordered]@{
    status = 'passed'; sourceCommit = $head; selectedRoot = $correct; ignoredDecoy = $wrong
    missingCorrectSdkRejected = $true; kind = 'Pinned Bash bootstrap routing fixture, not a Mac workload execution'
} | ConvertTo-Json | Set-Content (Join-Path $fixture 'result.json')
Write-Host "PASS: pinned tools.sh selects source/.dotnet despite DOTNET_INSTALL_DIR; missing SDK fails without installation. Evidence: $fixture"
