[CmdletBinding()]
param([Parameter(Mandatory)][string]$Output,[Parameter(Mandatory)][string]$ReferenceOutputs)
. (Join-Path $PSScriptRoot 'Retention.ps1')
if(Test-Path $Output){throw 'Refusing fault evidence overwrite.'}
$null=New-Item -ItemType Directory -Path $Output
$evidence=Join-Path $Output 'positive\evidence'
$capture=Join-Path $evidence 'measurements\capture'
$scratch=Join-Path $capture 'scratch\fixture-only'
$null=New-Item -ItemType Directory -Path $scratch
$lockPath=Join-Path $scratch 'lock'
$lock=[IO.FileStream]::new($lockPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
$state=@{primary=$null;secondary=[Collections.Generic.List[object]]::new()
    reportingErrors=[Collections.Generic.List[object]]::new();records=[Collections.Generic.List[string]]::new()
    directory=(Join-Path $evidence 'measurements\errors')}
$console=[IO.StringWriter]::new()
$originalConsole=[Console]::Error
$caught=$null

function Invoke-InjectedPrimary
{
    $inner=[IO.InvalidDataException]::new('INNER_CAUSE_SENTINEL')
    throw [InvalidOperationException]::new('PRIMARY_CAUSE_SENTINEL',$inner)
}
function Invoke-InjectedProtocol
{
    [CmdletBinding()]param()
    try{Invoke-InjectedPrimary}
    catch{Register-MatureFailure $state $_ 'collector-start-fixture' 'primary' @((Join-Path $capture 'start.receipt.json'))}
    finally
    {
        try{throw [IO.IOException]::new('SECONDARY_CLEANUP_SENTINEL')}
        catch{Register-MatureFailure $state $_ 'private-cleanup-fixture' 'cleanup' @((Join-Path $evidence 'measurements\cleanup.json'))}
    }
    $PSCmdlet.ThrowTerminatingError($state.primary)
}
try
{
    [Console]::SetError($console)
    try{Invoke-InjectedProtocol}catch{$caught=$_}
    [Console]::SetError($originalConsole)
    $consoleText=$console.ToString()
    [IO.File]::WriteAllText((Join-Path $evidence 'console.log'),$consoleText)
    if($null -eq $caught -or $caught.Exception.Message -notlike '*PRIMARY_CAUSE_SENTINEL*' -or
        $caught.ScriptStackTrace -notmatch 'Invoke-InjectedPrimary' -or
        $state.primary.Exception.InnerException.Message -cne 'INNER_CAUSE_SENTINEL' -or
        $state.secondary.Count -ne 1 -or $state.reportingErrors.Count -ne 0 -or
        $consoleText -notmatch 'PRIMARY_CAUSE_SENTINEL' -or $consoleText -notmatch 'INNER_CAUSE_SENTINEL' -or
        $consoleText -notmatch 'SECONDARY_CLEANUP_SENTINEL' -or $consoleText -notmatch 'Invoke-InjectedPrimary')
    {throw 'Original cause/context/secondary console preservation failed.'}
    $primary=Get-Content $state.records[0] -Raw|ConvertFrom-Json
    $secondary=Get-Content $state.records[1] -Raw|ConvertFrom-Json
    if($primary.phase -cne 'collector-start-fixture' -or $primary.invocation.lineNumber -le 0 -or
        $primary.scriptStackTrace -notmatch 'Invoke-InjectedPrimary' -or $secondary.kind -cne 'cleanup')
    {throw 'Durable original ErrorRecord fields were not preserved.'}

    $archive=Join-Path $capture 'mature-csc.diagsession'
    $rawBytes=[Text.Encoding]::UTF8.GetBytes('SYNTHETIC finalized-file staging fixture; NOT a profiler recording.')
    [IO.File]::WriteAllBytes($archive,$rawBytes)
    $guid=[Guid]::NewGuid().ToString()
    $pidValue=$PID
    $session=@{syntheticFixture=$true;noCollectorStarted=$true;sessionId=$guid;started=$true;stopAttempted=$true;output=$archive
        identity=@{pid=$pidValue;startTicks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks}
        startReceipt=@{exitCode=0;timedOut=$false;outputComplete=$true;arguments=@('start',$guid,"/attach:$pidValue")}
        stopReceipt=@{exitCode=0;timedOut=$false;outputComplete=$true;arguments=@('stop',$guid,"/output:$archive")}}
    Write-MatureClosedJson $session (Join-Path $capture 'session-final.json')
    Write-MatureClosedJson $session.startReceipt (Join-Path $capture 'start.receipt.json')
    Write-MatureClosedJson $session.stopReceipt (Join-Path $capture 'stop.receipt.json')
    $manifest=@(Get-Content (Join-Path $ReferenceOutputs 'manifest.json') -Raw|ConvertFrom-Json)
    if($manifest.Count -ne 119){throw 'Expected previously proved real 119-file output corpus.'}
    $outputCopy=Join-Path $evidence 'measurements\target-outputs'
    foreach($file in $manifest)
    {Copy-MatureClosedFile (Join-Path $ReferenceOutputs $file.relativePath) (Join-Path $outputCopy $file.relativePath)}
    Copy-MatureClosedFile (Join-Path $ReferenceOutputs 'manifest.json') (Join-Path $outputCopy 'manifest.json')
    # Real hidden attribute plus dot-generated obj filename must survive staging.
    $hidden=@($manifest|Where-Object relativePath -match '\\obj\\|^obj\\'|Where-Object relativePath -match 'AssemblyAttributes.cs$')[0]
    if($null -eq $hidden){throw 'Hidden emitted obj fixture missing.'}
    $hiddenPath=Join-Path $outputCopy $hidden.relativePath
    [IO.File]::SetAttributes($hiddenPath,([IO.File]::GetAttributes($hiddenPath) -bor [IO.FileAttributes]::Hidden))

    $locked=$false
    try{$other=[IO.File]::OpenRead($lockPath);$other.Dispose()}catch [IO.IOException]{$locked=$true}
    if(-not$locked){throw 'Fault fixture did not actually hold an unreadable FileShare.None lock.'}
    $stage=Stage-MatureEvidence $evidence (Join-Path $Output 'positive\retained')
    if(-not$stage.stagePassed -or -not$stage.finalizedRawStaged -or $stage.errors.Count -or
        @($stage.metadataFiles|Where-Object path -match 'scratch|\\lock$').Count)
    {throw 'Production stager did not isolate live scratch.'}
    $zip=Join-Path $Output 'diagnostics-while-locked.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($stage.metadataRoot,$zip)
    $rawZip=Join-Path $Output 'safe-raw-while-locked.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($stage.rawRoot,$rawZip)
    $z=[IO.Compression.ZipFile]::OpenRead($zip)
    try
    {
        $names=@($z.Entries.FullName)
        if(@($names|Where-Object{$_ -match 'scratch|(^|/)lock$'}).Count){throw 'Scratch lock entered diagnostics ZIP.'}
        $entry=@($z.Entries|Where-Object FullName -eq 'console.log')[0]
        $r=[IO.StreamReader]::new($entry.Open())
        try{$zipped=$r.ReadToEnd()}finally{$r.Dispose()}
        if($zipped -cne $consoleText){throw 'Diagnostic ZIP did not retain actual original console bytes.'}
        foreach($file in $stage.metadataFiles)
        {
            $name=$file.path.Replace('\','/')
            $entry=@($z.Entries|Where-Object FullName -ceq $name)[0]
            if($null -eq $entry){throw "Metadata ZIP entry missing: $name"}
            $bytes=[IO.MemoryStream]::new()
            $input=$entry.Open()
            try{$input.CopyTo($bytes)}finally{$input.Dispose()}
            try
            {
                if(-not[Linq.Enumerable]::SequenceEqual[byte](
                    [IO.File]::ReadAllBytes((Join-Path $evidence $file.path)),$bytes.ToArray()))
                {throw "Actual metadata/receipt bytes changed in ZIP: $name"}
            }
            finally{$bytes.Dispose()}
        }
    }
    finally{$z.Dispose()}
    foreach($file in $manifest)
    {
        $left=[IO.File]::ReadAllBytes((Join-Path $ReferenceOutputs $file.relativePath))
        $right=[IO.File]::ReadAllBytes((Join-Path $stage.rawRoot "target-outputs\$($file.relativePath)"))
        if(-not[Linq.Enumerable]::SequenceEqual[byte]($left,$right)){throw 'Full output bytes changed while staging.'}
    }
    $z=[IO.Compression.ZipFile]::OpenRead($rawZip)
    try
    {
        if(@($z.Entries|Where-Object FullName -match 'scratch|(^|/)lock$').Count){throw 'Scratch lock entered safe raw ZIP.'}
        foreach($file in $manifest)
        {
            $name="target-outputs/"+$file.relativePath.Replace('\','/')
            $entry=@($z.Entries|Where-Object FullName -ceq $name)[0]
            if($null -eq $entry){throw "Raw ZIP omitted output: $name"}
            $bytes=[IO.MemoryStream]::new();$input=$entry.Open()
            try{$input.CopyTo($bytes)}finally{$input.Dispose()}
            try
            {
                if(-not[Linq.Enumerable]::SequenceEqual[byte](
                    [IO.File]::ReadAllBytes((Join-Path $ReferenceOutputs $file.relativePath)),$bytes.ToArray()))
                {throw "Real 119-output bytes changed in raw ZIP: $name"}
            }
            finally{$bytes.Dispose()}
        }
    }
    finally{$z.Dispose()}
    if(-not[Linq.Enumerable]::SequenceEqual[byte]($rawBytes,[IO.File]::ReadAllBytes((Join-Path $stage.rawRoot 'capture\mature-csc.diagsession'))))
    {throw 'Finalized raw-file bytes changed.'}
    $stillLocked=$false
    try{$other=[IO.File]::OpenRead($lockPath);$other.Dispose()}catch [IO.IOException]{$stillLocked=$true}
    if(-not$stillLocked){throw 'ZIP proof happened after lock was released.'}

    $negative=Join-Path $Output 'unfinalized\evidence\measurements\capture'
    $null=New-Item -ItemType Directory -Path $negative
    [IO.File]::WriteAllBytes((Join-Path $negative 'mature-csc.diagsession'),$rawBytes)
    $noFinal=Stage-MatureEvidence (Join-Path $Output 'unfinalized\evidence') (Join-Path $Output 'unfinalized\retained')
    if($noFinal.finalizedRawStaged -or $noFinal.stagePassed -or $noFinal.rawFilesAvailable)
    {throw 'Filename-only/unfinalized raw was incorrectly staged as complete.'}
    $metadataFault=Join-Path $Output 'metadata-copy-fault\evidence'
    $null=New-Item -ItemType Directory -Path $metadataFault
    [IO.File]::WriteAllText((Join-Path $metadataFault 'good.log'),'closed diagnostic must survive copy failure')
    $badPath=Join-Path $metadataFault 'unreadable.log'
    $bad=[IO.FileStream]::new($badPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{$partial=Stage-MatureEvidence $metadataFault (Join-Path $Output 'metadata-copy-fault\retained')}
    finally{$bad.Dispose()}
    if($partial.stagePassed -or $partial.errors.Count -lt 1 -or -not(Test-Path (Join-Path $partial.metadataRoot 'good.log')))
    {throw 'Metadata copy failure was swallowed or discarded other diagnostics.'}
    Write-MatureClosedJson @{passed=$true;realScratchLockHeldThroughoutZip=$true;originalCauseRethrown=$true
        originalError=$primary;secondaryError=$secondary;rethrowStack=$caught.ScriptStackTrace;rethrowInvocation=$caught.InvocationInfo.PositionMessage
        consolePath=(Join-Path $evidence 'console.log')
        diagnosticsZip=$zip;rawZip=$rawZip;outputCorpusFiles=119;allOutputBytesEqual=$true;allMetadataZipBytesEqual=$true;all119RawZipBytesEqual=$true;hiddenObjIncluded=$true
        scratchLockInArchives=$false;negativeUnfinalizedRaw=$noFinal;copyFailureExplicit=$partial.errors
        actualRecordings=0;servicesStarted=0;oldScratchGuidUsed=$false} (Join-Path $Output 'test-result.json')
}
finally
{
    [Console]::SetError($originalConsole)
    $lock.Dispose()
    $console.Dispose()
}
