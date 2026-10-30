[CmdletBinding()]
param([Parameter(Mandatory)][string]$Output)
. (Join-Path $PSScriptRoot 'Inventory.ps1')
if(Test-Path $Output){throw 'Refusing test evidence overwrite.'}
$null=New-Item -ItemType Directory -Path $Output
$valid=@{actions='true';repository='yeelam-gordon/aspire';ref='refs/heads/perf/arm64-activation-inventory';event='workflow_dispatch'
    attempt='1';environment='github-hosted';os='Windows';arch='ARM64';image='win11-vs2026-arm64';processArch='Arm64';osArch='Arm64'}
if(-not(Test-InventoryContext $valid)){throw 'Valid pure inventory context rejected.'}
$negatives=@(foreach($name in $valid.Keys)
{
    $wrong=$valid.Clone();$wrong[$name]=if($name -eq 'attempt'){'2'}else{'unowned'}
    if(Test-InventoryContext $wrong){throw "Accepted foreign/rerun context: $name"}
    @{field=$name;rejected=$true}
})
$hostEntry=@{classExists=$true;appId=$script:InventoryHost;appExists=$true;localService='VSStandardCollectorService150'}
$service=@{exists=$true;imageAllowed=$true;image=@{exists=$true}}
$routes=@(foreach($case in @('present','missingHost','wrongAppId','missingAppId','wrongService','missingService','foreignPath','missingImage'))
{
    $h=$hostEntry.Clone();$s=$service.Clone();$s.image=@{exists=$true}
    $expected=switch($case)
    {
        'present'{'PresentStaticRoute'}
        'missingHost'{$h.classExists=$false;'MissingHostClass'}
        'wrongAppId'{$h.appId='{00000000-0000-0000-0000-000000000000}';'UnexpectedHostAppId'}
        'missingAppId'{$h.appExists=$false;'MissingHostAppId'}
        'wrongService'{$h.localService='unowned';'UnexpectedLocalService'}
        'missingService'{$s.exists=$false;'MissingServiceKey'}
        'foreignPath'{$s.imageAllowed=$false;'UnexpectedServiceImagePath'}
        'missingImage'{$s.image.exists=$false;'MissingServiceImage'}
    }
    $actual=Get-InventoryRoute $h $s
    if($actual -cne $expected){throw "Incorrect missing/present route semantics: $case"}
    @{case=$case;actual=$actual;activationSuccessClaimed=$false}
})
Assert-InventoryHelpCommand $script:InventoryCli @('start','/help')
$helpNegatives=@(foreach($case in @(
    @{name='foreignExecutable';exe='C:\unowned\VSDiagnostics.exe';arguments=@('start','/help')},
    @{name='sessionStart';exe=$script:InventoryCli;arguments=@('start',[Guid]::NewGuid().ToString())},
    @{name='status';exe=$script:InventoryCli;arguments=@('status')},
    @{name='stop';exe=$script:InventoryCli;arguments=@('stop','1')},
    @{name='extraArgument';exe=$script:InventoryCli;arguments=@('start','/help','/attach:1')},
    @{name='wrongVerb';exe=$script:InventoryCli;arguments=@('stop','/help')}))
{
    $rejected=$false
    try{Assert-InventoryHelpCommand $case.exe $case.arguments}catch{$rejected=$true}
    if(-not$rejected){throw "Unsafe CLI command accepted: $($case.name)"}
    @{case=$case.name;rejected=$true}
})
# Actual hosted entry invocation in the real local context must reject before
# creating its output. No GitHub environment is fabricated for this test.
$psi=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
foreach($a in @('-NoProfile','-File',(Join-Path $PSScriptRoot 'Invoke-HostedInventory.ps1'))){$psi.ArgumentList.Add($a)}
$p=[Diagnostics.Process]::Start($psi);$stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
$testBirth=$p.StartTime.ToUniversalTime().Ticks
try
{
    if(-not$p.WaitForExit(10000)){throw 'Hosted-entry rejection timed out.'}
    [IO.File]::WriteAllText((Join-Path $Output 'local-hosted-entry.stderr.log'),$stderr.GetAwaiter().GetResult())
    [IO.File]::WriteAllText((Join-Path $Output 'local-hosted-entry.stdout.log'),$stdout.GetAwaiter().GetResult())
    if($p.ExitCode -eq 0){throw 'Actual local hosted entry was accepted.'}
}
finally
{
    if(-not$p.HasExited)
    {
        $live=Get-Process -Id $p.Id
        if($live.StartTime.ToUniversalTime().Ticks -ne $testBirth -or $live.Path -cne $psi.FileName)
        {throw 'Owned guard-test process identity changed; refusing cleanup.'}
        Stop-Process -Id $p.Id;$null=$p.WaitForExit(5000)
    }
    $p.StandardOutput.Dispose();$p.StandardError.Dispose();$p.Dispose()
}
$outsidePeRejected=$false
try{$null=Get-InventoryPe 'C:\unowned\component.dll'}catch{$outsidePeRejected=$true}
if(-not$outsidePeRejected){throw 'Arbitrary PE path was accepted.'}
# Real owned output-path collision: the actual fixed help child starts, its
# first receipt fails, cleanup must still exit/close it and retain the error.
$script=Join-Path $PSScriptRoot 'Inventory.ps1'
$line=@(Select-String -LiteralPath $script -SimpleMatch "'help'{Invoke-InventoryHelp `$Output}")[0].LineNumber
if($line -le 0){throw 'Help probe call location missing.'}
$breakpoint=Set-PSBreakpoint -Script $script -Line $line -Action {
    $null=[IO.Directory]::CreateDirectory((Join-Path $Output 'help-start.json'))
}
$failed=$false
try
{
    try{Invoke-ActivationInventory (Join-Path $Output 'failed-probe')}
    catch{$failed=$_.Exception.Message -like 'Read-only inventory incomplete*'}
}
finally{Remove-PSBreakpoint -Breakpoint $breakpoint}
$partial=Get-Content (Join-Path $Output 'failed-probe\inventory.json') -Raw|ConvertFrom-Json
$help=Get-Content (Join-Path $Output 'failed-probe\help-final.json') -Raw|ConvertFrom-Json
if(-not$failed -or $partial.inventoryComplete -or $partial.errors.Count -ne 1 -or $partial.errors[0].phase -cne 'help' -or
    -not$help.exited -or $help.probeComplete -or -not(Test-Path (Join-Path $Output 'failed-probe\error-help.json')) -or
    ($help.identity.arguments -join ' ') -cne 'start /help')
{throw 'Failed probe did not retain closed metadata/own help cleanup proof.'}
Write-InventoryJson @{passed=$true;contextNegatives=$negatives;routes=$routes;helpCommandNegatives=$helpNegatives
    actualLocalHostedEntryRejected=$true;outsidePeRejected=$outsidePeRejected
    actualFailedProbeRetained=$true;failedHelpExited=$help.exited
    githubContextFaked=$false;actualCliInvocations=1;actualCollectorSessions=0} (Join-Path $Output 'tests.json')
