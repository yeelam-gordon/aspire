[CmdletBinding()]
param([Parameter(Mandatory)][string]$RepositoryRoot,[Parameter(Mandatory)][string]$Output)
$ErrorActionPreference='Stop'
$base='d3f2f2ba5a0d5a04078323103129efadf4389354'
$prefix='Generated Files/arm64-build/developer-build/standard-cpu-calibration/mature-csc/'
function Get-OldText([string]$Path)
{
    $text=@(& git -C $RepositoryRoot show "${base}:$Path") -join "`n"
    if($LASTEXITCODE -ne 0){throw "Missing baseline: $Path"}
    return $text.Replace("`r`n","`n").TrimEnd()
}
$identical=@()
foreach($name in @('Collector.ps1','Analyze-Capture.ps1','BinlogReader.cs','Build-Tools.ps1','CompilerSymbols.cs',
    'Guard.ps1','Invoke-HostedProfile.ps1','Invoke-LocalControl.ps1','Setup-Hosted.ps1','Test-Guards.ps1','granularity-plan.json'))
{
    $old=Get-OldText "$prefix$name"
    $new=(Get-Content (Join-Path $PSScriptRoot $name) -Raw).Replace("`r`n","`n").TrimEnd()
    if($old -cne $new){throw "Non-observability source changed: $name"}
    $identical+=@{file=$name;identical=$true}
}
foreach($name in @('CpuDecoder.cs','Helpers.ps1','Bootstrap-Sdk.ps1','Build-Tools.ps1'))
{
    $path="Generated Files/arm64-build/developer-build/standard-cpu-calibration/$name"
    if((Get-OldText $path) -cne (Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) $name) -Raw).Replace("`r`n","`n").TrimEnd())
    {throw "Calibrated decoder/bootstrap/helper changed: $name"}
    $identical+=@{file=$path;identical=$true}
}
$oldText=Get-OldText "${prefix}Invoke-MatureProtocol.ps1"
$newText=Get-Content (Join-Path $PSScriptRoot 'Invoke-MatureProtocol.ps1') -Raw
$tokens=$null;$errors=$null
$oldAst=[Management.Automation.Language.Parser]::ParseInput($oldText,[ref]$tokens,[ref]$errors)
$newAst=[Management.Automation.Language.Parser]::ParseInput($newText,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Protocol parse failure.'}
$functions=@('Save-MatureOutputs','Invoke-MatureBuild','Read-MatureBuild')
foreach($name in $functions)
{
    $a=@($oldAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
    $b=@($newAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
    if($a.Count -ne 1 -or $b.Count -ne 1 -or
        $a[0].Extent.Text.Replace("`r`n","`n") -cne $b[0].Extent.Text.Replace("`r`n","`n"))
    {throw "Normal timed/proof/output function changed: $name"}
}
$names=@('Invoke-MatureBuild','Read-MatureBuild','Save-MatureOutputs','Invoke-PairedCommand','Read-PairedCpu',
    'Start-MatureCollection','Stop-MatureCollection','Restore-PairedSource','Reset-PrivateProcesses')
function Get-Calls($Ast)
{
    @($Ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in $names},$true)|
        ForEach-Object{$_.Extent.Text.Replace("`r`n","`n")})
}
$oldCalls=Get-Calls $oldAst;$newCalls=Get-Calls $newAst
if(($oldCalls -join "`n") -cne ($newCalls -join "`n")){throw 'Build/CPU/collector/cleanup command sequence changed.'}
@{passed=$true;base=$base;byteTextIdenticalFiles=$identical;exactFunctionBodies=$functions
    invariantCommandCalls=$oldCalls.Count;calls=$newCalls;full24CaseProofReusable=$true
    changedScope='Error/phase/cleanup reporting and independent staging/upload only; no warmup rerun needed.'}|
    ConvertTo-Json -Depth 6|Set-Content -LiteralPath $Output
