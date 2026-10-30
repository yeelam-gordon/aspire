[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidenceRoot,[Parameter(Mandatory)][string]$StageRoot)
. (Join-Path $PSScriptRoot 'Retention.ps1')
$result=Stage-MatureEvidence $EvidenceRoot $StageRoot
if($env:GITHUB_OUTPUT)
{
    "raw_files_available=$($result.rawFilesAvailable.ToString().ToLowerInvariant())" >> $env:GITHUB_OUTPUT
    "raw_recording_complete=$($result.finalizedRawStaged.ToString().ToLowerInvariant())" >> $env:GITHUB_OUTPUT
}
if(-not$result.stagePassed){throw "P49 retention incomplete: $($result.rawState). Closed metadata is independently uploadable; inspect retention-manifest/errors."}
