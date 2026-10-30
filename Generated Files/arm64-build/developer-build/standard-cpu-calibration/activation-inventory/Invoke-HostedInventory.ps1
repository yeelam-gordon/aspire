[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'Inventory.ps1')
$context=@{actions=$env:GITHUB_ACTIONS;repository=$env:GITHUB_REPOSITORY;ref=$env:GITHUB_REF;event=$env:GITHUB_EVENT_NAME
    attempt=$env:GITHUB_RUN_ATTEMPT;environment=$env:RUNNER_ENVIRONMENT;os=$env:RUNNER_OS;arch=$env:RUNNER_ARCH
    image=$env:ImageOS;processArch=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    osArch=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()}
if(-not(Test-InventoryContext $context)){throw 'Only exact owned manual attempt1 hosted Windows ARM64 inventory is permitted.'}
$workspace=[IO.Path]::GetFullPath($env:GITHUB_WORKSPACE).TrimEnd('\')+'\'
if(-not$PSScriptRoot.StartsWith($workspace,[StringComparison]::OrdinalIgnoreCase)){throw 'Inventory code outside owned workspace.'}
$head=(& git -C $PSScriptRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $head -cne $env:GITHUB_SHA){throw 'Instrumentation differs from dispatched source.'}
$output=Join-Path $env:GITHUB_WORKSPACE 'activation-inventory-results'
Invoke-ActivationInventory $output
