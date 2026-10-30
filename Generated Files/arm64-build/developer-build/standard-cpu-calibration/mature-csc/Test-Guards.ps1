[CmdletBinding()]
param([Parameter(Mandatory)][string]$RepositoryRoot,[Parameter(Mandatory)][string]$SdkRoot,
    [Parameter(Mandatory)][string]$ToolsDirectory,[Parameter(Mandatory)][string]$Output)
. (Join-Path $PSScriptRoot 'Guard.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Helpers.ps1')
if(Test-Path $Output){throw 'Guard output exists.'}
$null=New-Item -ItemType Directory -Path $Output
$valid=@{actions='true';repository='yeelam-gordon/aspire';ref='refs/heads/perf/arm64-mature-cpu-profile'
    event='workflow_dispatch';runnerEnvironment='github-hosted';runnerOS='Windows';runnerArch='ARM64'
    imageOS='win11-vs2026-arm64';osArch='Arm64';processArch='Arm64';runId='123';runAttempt='1'}
if(-not(Test-MatureContext $valid)){throw 'Valid pure dispatch fixture rejected.'}
$negatives=@()
foreach($key in $valid.Keys)
{
    $wrong=$valid.Clone();$wrong[$key]=if($key -eq 'runAttempt'){'2'}else{'unowned'}
    $rejected=-not(Test-MatureContext $wrong)
    if(-not$rejected){throw "Guard accepted invalid $key"}
    $negatives+=@{field=$key;value=$wrong[$key];rejected=$rejected}
}
$local=@()
if($env:GITHUB_ACTIONS -cne 'true')
{
    foreach($entry in @('Invoke-HostedProfile.ps1','Invoke-MatureProtocol.ps1'))
    {
        $forbidden=Join-Path $Output $entry
        $arguments=@('-NoProfile','-File',(Join-Path $PSScriptRoot $entry),'-RepositoryRoot',$RepositoryRoot,
            '-SdkRoot',$SdkRoot,'-ResultsDirectory',$forbidden,'-ToolsDirectory',$ToolsDirectory)
        if($entry -eq 'Invoke-MatureProtocol.ps1'){$arguments+='-HostedCapture'}
        $child=Start-CpuProcess (Get-Process -Id $PID).Path $arguments (Join-Path $Output $entry)
        $r=Complete-CpuProcess $child 10
        $rejected=$r.exitCode -ne 0 -and -not$r.timedOut -and -not(Test-Path $forbidden)
        if(-not$rejected){throw "Local capture side-effect guard failed: $entry"}
        $local+=@{entry=$entry;rejectedBeforeOutput=$rejected;receipt=$r}
    }
}
Write-CpuJson @{passed=$true;contextNegatives=$negatives;actualLocalCaptureRejections=$local
    noGithubEnvironmentFaked=$true;collectorOperations=0} (Join-Path $Output 'tests.json')
