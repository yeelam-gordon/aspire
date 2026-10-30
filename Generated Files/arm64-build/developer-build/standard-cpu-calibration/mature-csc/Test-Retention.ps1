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
    $syntheticZip=[IO.Compression.ZipFile]::Open($archive,[IO.Compression.ZipArchiveMode]::Create)
    try
    {
        $writer=[IO.StreamWriter]::new($syntheticZip.CreateEntry('SYNTHETIC-NOT-PROFILER-DATA.txt').Open())
        try{$writer.Write('Owned readable archive fixture only.')}finally{$writer.Dispose()}
    }
    finally{$syntheticZip.Dispose()}
    $rawBytes=[IO.File]::ReadAllBytes($archive)
    $guid=[Guid]::NewGuid().ToString()
    $pidValue=$PID
    $identity=@{pid=$pidValue;startTicks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks;executablePath=(Get-Process -Id $PID).Path}
    $startArgs=@('start',$guid,"/attach:$pidValue",'/monitor')
    $session=@{syntheticFixture=$true;noCollectorStarted=$true;sessionId=$guid;started=$true;stopAttempted=$true;stopAcknowledged=$true;output=$archive
        identity=$identity
        startReceipt=@{ready=$true;sessionId=$guid;monitorAliveAtReady=$true;pid=$PID;birthTicks=$identity.startTicks
            executable=$identity.executablePath;targetIdentity=$identity;arguments=$startArgs;commandIndex=0;ackText="Session ${guid}: {$guid}`r`n  Running`r`n"}
        monitorReceipt=@{exitCode=0;timedOut=$false;outputComplete=$true;captureComplete=$true;pid=$PID;birthTicks=$identity.startTicks
            executable=$identity.executablePath;arguments=$startArgs}
        stopReceipt=@{exitCode=0;timedOut=$false;outputComplete=$true;commandIndex=0;arguments=@('stop',$guid,"/output:$archive")}}
    Write-MatureClosedJson $session (Join-Path $capture 'session-final.json')
    Write-MatureClosedJson $session.startReceipt (Join-Path $capture 'start.receipt.json')
    Write-MatureClosedJson $session.stopReceipt (Join-Path $capture 'stop.receipt.json')
    [IO.File]::WriteAllText((Join-Path $capture 'start.stdout-prefix.log'),"Session ${guid}: {$guid}`r`n  Running`r`n")
    [IO.File]::WriteAllText((Join-Path $capture 'stop.stdout.log'),"Session ${guid}: {$guid}`r`n  Stopped`r`n")
    Write-MatureClosedJson @{syntheticFixture=$true;failure=$null;completedCases=24;secondaryFailures=@();reportingFailures=@();restorationPassed=$true} (Join-Path $evidence 'measurements\final-state.json')
    Write-MatureClosedJson @{syntheticFixture=$true;qualifiedFileAndSampleGate=$true} (Join-Path $capture 'qualified-gate.json')
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
    $provisionalRoot=Join-Path $Output 'provisional-monitor-failure'
    $provisionalEvidence=Join-Path $provisionalRoot 'evidence'
    $provisionalCapture=Join-Path $provisionalEvidence 'measurements\capture'
    $null=New-Item -ItemType Directory -Path $provisionalCapture
    $provisional=$session|ConvertTo-Json -Depth 15|ConvertFrom-Json -AsHashtable
    $provisional.output=Join-Path $provisionalCapture 'mature-csc.diagsession'
    $provisional.stopReceipt.arguments=@('stop',$guid,"/output:$($provisional.output)")
    $provisional.monitorReceipt.exitCode=7
    [IO.File]::WriteAllBytes($provisional.output,$rawBytes)
    Write-MatureClosedJson $provisional (Join-Path $provisionalCapture 'session-final.json')
    Copy-MatureClosedFile (Join-Path $capture 'start.stdout-prefix.log') (Join-Path $provisionalCapture 'start.stdout-prefix.log')
    Copy-MatureClosedFile (Join-Path $capture 'stop.stdout.log') (Join-Path $provisionalCapture 'stop.stdout.log')
    try{throw 'ORIGINAL_MONITOR_EXIT_7'}
    catch{$null=Write-MatureFailure $_ (Join-Path $provisionalEvidence 'measurements\errors') 'owned-monitor-completion' 'primary' @()}
    $provisionalOutputs=Join-Path $provisionalRoot 'stage.outputs'
    $hadProvisionalOutput=Test-Path Env:GITHUB_OUTPUT;$oldProvisionalOutput=$env:GITHUB_OUTPUT
    $provisionalFailed=$false
    try
    {
        $env:GITHUB_OUTPUT=$provisionalOutputs
        try{& (Join-Path $PSScriptRoot 'Stage-Retention.ps1') -EvidenceRoot $provisionalEvidence -StageRoot (Join-Path $provisionalRoot 'retained')}
        catch{$provisionalFailed=$_.Exception.Message -like 'P49 retention incomplete:*'}
    }
    finally{if($hadProvisionalOutput){$env:GITHUB_OUTPUT=$oldProvisionalOutput}else{Remove-Item Env:GITHUB_OUTPUT}}
    $provisionalResult=Get-Content (Join-Path $provisionalRoot 'retained\metadata\retention-manifest.json') -Raw|ConvertFrom-Json
    $provisionalError=@(Get-ChildItem (Join-Path $provisionalResult.metadataRoot 'measurements\errors') -Filter '*.json')[0]
    if(-not$provisionalFailed -or -not$provisionalResult.provisionalRawStaged -or $provisionalResult.rawRecordingComplete -or
        $provisionalResult.stagePassed -or -not$provisionalResult.finalizedRawStaged -or
        ((Get-Content $provisionalOutputs) -join "`n") -cne "raw_files_available=true`nraw_recording_complete=false" -or
        (Get-Content $provisionalError.FullName -Raw|ConvertFrom-Json).message -cne 'ORIGINAL_MONITOR_EXIT_7' -or
        -not[Linq.Enumerable]::SequenceEqual[byte]($rawBytes,[IO.File]::ReadAllBytes((Join-Path $provisionalResult.rawRoot 'capture\mature-csc.diagsession'))))
    {throw 'Owned stopped archive/primary cause was discarded or monitor failure promoted to success.'}
    $eligibility=@()
    foreach($kind in @('noRunning','foreignAck','noStop','foreignOutput','liveArchive'))
    {
        $root=Join-Path $Output "eligibility-$kind"
        $source=Join-Path $root 'evidence'
        $cap=Join-Path $source 'measurements\capture'
        $null=New-Item -ItemType Directory -Path $cap
        $candidate=$session|ConvertTo-Json -Depth 15|ConvertFrom-Json -AsHashtable
        $candidate.output=Join-Path $cap 'mature-csc.diagsession'
        $candidate.stopReceipt.arguments=@('stop',$guid,"/output:$($candidate.output)")
        [IO.File]::WriteAllBytes($candidate.output,$rawBytes)
        if($kind -ceq 'noRunning'){$candidate.startReceipt.ready=$false}
        if($kind -ceq 'noStop'){$candidate.stopAcknowledged=$false}
        if($kind -ceq 'foreignOutput'){$candidate.output=Join-Path $root 'not-owned.diagsession'}
        Write-MatureClosedJson $candidate (Join-Path $cap 'session-final.json')
        $ackGuid=if($kind -ceq 'foreignAck'){[Guid]::NewGuid().ToString()}else{$guid}
        if($kind -ceq 'foreignAck')
        {
            # Mutate the authoritative validated ACK field, not just its
            # separately persisted transcript.
            $candidate.startReceipt.ackText="Session ${ackGuid}: {$ackGuid}`r`n  Running`r`n"
            [IO.File]::Delete((Join-Path $cap 'session-final.json'))
            Write-MatureClosedJson $candidate (Join-Path $cap 'session-final.json')
        }
        [IO.File]::WriteAllText((Join-Path $cap 'start.stdout-prefix.log'),"Session ${ackGuid}: {$ackGuid}`r`n  Running`r`n")
        Copy-MatureClosedFile (Join-Path $capture 'stop.stdout.log') (Join-Path $cap 'stop.stdout.log')
        $held=$null
        try
        {
            if($kind -ceq 'liveArchive')
            {$held=[IO.FileStream]::new((Join-Path $cap 'mature-csc.diagsession'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
            $rejected=Stage-MatureEvidence $source (Join-Path $root 'retained')
        }
        finally{if($null -ne $held){$held.Dispose()}}
        if($rejected.finalizedRawStaged -or $rejected.rawFilesAvailable -or $rejected.rawRecordingComplete -or $rejected.stagePassed)
        {throw "Unowned/unacknowledged/live archive retained: $kind"}
        $eligibility+=@{kind=$kind;rejected=$true;manifest=$rejected}
    }
    $metadataFault=Join-Path $Output 'metadata-copy-fault\evidence'
    $null=New-Item -ItemType Directory -Path $metadataFault
    [IO.File]::WriteAllText((Join-Path $metadataFault 'good.log'),'closed diagnostic must survive copy failure')
    $badPath=Join-Path $metadataFault 'unreadable.log'
    $bad=[IO.FileStream]::new($badPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{$partial=Stage-MatureEvidence $metadataFault (Join-Path $Output 'metadata-copy-fault\retained')}
    finally{$bad.Dispose()}
    if($partial.stagePassed -or $partial.errors.Count -lt 1 -or -not(Test-Path (Join-Path $partial.metadataRoot 'good.log')))
    {throw 'Metadata copy failure was swallowed or discarded other diagnostics.'}

    $compoundRoot=Join-Path $Output 'compound-copy-report-fault'
    $compoundEvidence=Join-Path $compoundRoot 'evidence'
    $null=New-Item -ItemType Directory -Path $compoundEvidence
    $compoundBadPath=Join-Path $compoundEvidence '00-unreadable.log'
    $compoundBad=[IO.FileStream]::new($compoundBadPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $laterPath=Join-Path $compoundEvidence 'zz-later-readable.log'
    $laterBytes=[Text.Encoding]::UTF8.GetBytes('Closed diagnostic copied AFTER both real filesystem failures.')
    [IO.File]::WriteAllBytes($laterPath,$laterBytes)
    $compoundStage=Join-Path $compoundRoot 'retained'
    $compoundOutput=Join-Path $compoundRoot 'stage.outputs'
    $compoundConsole=[IO.StringWriter]::new()
    $hadOutput=Test-Path Env:GITHUB_OUTPUT
    $oldOutput=$env:GITHUB_OUTPUT
    $compoundFailure=$null
    $breakpoint=$null
    try
    {
        # StageRoot must be new, so insert the owned file/directory collision
        # immediately before the REAL reporter writes. No reporter is replaced
        # or mocked: its filesystem persistence genuinely fails.
        $failureScript=Join-Path $PSScriptRoot 'Failure.ps1'
        $line=[Array]::IndexOf([string[]](Get-Content $failureScript),'    try{Write-MatureClosedJson $value $path}')+1
        if($line -le 0){throw 'Real reporter fault-injection location missing.'}
        $breakpoint=Set-PSBreakpoint -Script $failureScript -Line $line -Action {
            if($Phase -ceq 'metadata-copy-00-unreadable.log')
            {
                $later=Join-Path (Split-Path $Directory) 'zz-later-readable.log'
                [IO.File]::WriteAllText($Directory,"OWNED reporter path collision; laterAlreadyStaged=$([IO.File]::Exists($later))")
            }
        }
        $env:GITHUB_OUTPUT=$compoundOutput
        [Console]::SetError($compoundConsole)
        try{& (Join-Path $PSScriptRoot 'Stage-Retention.ps1') -EvidenceRoot $compoundEvidence -StageRoot $compoundStage}
        catch{$compoundFailure=$_}
    }
    finally
    {
        [Console]::SetError($originalConsole)
        if($null -ne $breakpoint){Remove-PSBreakpoint -Breakpoint $breakpoint}
        if($hadOutput){$env:GITHUB_OUTPUT=$oldOutput}else{Remove-Item Env:GITHUB_OUTPUT}
    }
    try
    {
        $compoundText=$compoundConsole.ToString()
        [IO.File]::WriteAllText((Join-Path $compoundRoot 'console.log'),$compoundText)
        $compoundManifest=Get-Content (Join-Path $compoundStage 'metadata\retention-manifest.json') -Raw|ConvertFrom-Json
        $outputs=@(Get-Content $compoundOutput)
        if($null -eq $compoundFailure -or $compoundFailure.Exception.Message -notlike 'P49 retention incomplete:*' -or
            $compoundManifest.stagePassed -or $compoundManifest.finalizedRawStaged -or $compoundManifest.rawFilesAvailable -or
            $compoundManifest.errors.Count -ne 1 -or $compoundManifest.reportingErrors.Count -ne 1 -or
            $compoundManifest.errors[0].phase -cne 'metadata-copy-00-unreadable.log' -or
            $compoundManifest.errors[0].message -notlike "*$compoundBadPath*" -or
            $compoundManifest.errors[0].exception -notmatch 'System.IO.IOException' -or
            $compoundManifest.errors[0].stack -notmatch 'Copy-MatureClosedFile' -or
            $compoundManifest.errors[0].invocation -notmatch 'Retention\.ps1:\d+ char:\d+' -or
            $compoundManifest.reportingErrors[0].originalPhase -cne 'metadata-copy-00-unreadable.log' -or
            $compoundManifest.reportingErrors[0].message -notlike '*retention-errors*' -or
            $compoundText -notlike "*$compoundBadPath*" -or $compoundText -notmatch 'secondary retention reporting failure' -or
            ($outputs -join "`n") -cne "raw_files_available=false`nraw_recording_complete=false" -or
            (Get-Content (Join-Path $compoundStage 'metadata\retention-errors') -Raw) -notlike '*laterAlreadyStaged=False')
        {throw 'Compound copy/persistence fault replaced original error, aborted retention or misreported stage outputs.'}
        $compoundZip=Join-Path $compoundRoot 'diagnostics-after-compound-fault.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $compoundStage 'metadata'),$compoundZip)
        $z=[IO.Compression.ZipFile]::OpenRead($compoundZip)
        try
        {
            $entry=@($z.Entries|Where-Object FullName -ceq 'zz-later-readable.log')[0]
            if($null -eq $entry){throw 'Later readable diagnostic missing from compound-fault ZIP.'}
            $bytes=[IO.MemoryStream]::new();$input=$entry.Open()
            try{$input.CopyTo($bytes)}finally{$input.Dispose()}
            try
            {
                if(-not[Linq.Enumerable]::SequenceEqual[byte]($laterBytes,$bytes.ToArray()))
                {throw 'Later readable diagnostic bytes changed after compound fault.'}
            }
            finally{$bytes.Dispose()}
        }
        finally{$z.Dispose()}
        $compoundStillLocked=$false
        try{$other=[IO.File]::OpenRead($compoundBadPath);$other.Dispose()}catch [IO.IOException]{$compoundStillLocked=$true}
        if(-not$compoundStillLocked){throw 'Compound fault lock was released before ZIP proof.'}
        $compoundProof=@{passed=$true;realCopyLockHeldThroughZip=$true;actualReporterPathCollision=$true
            manifest=$compoundManifest;outputs=$outputs;stageFailure=$compoundFailure.Exception.Message
            originalCopyErrorAuthoritative=$true;secondaryReportingErrorSeparate=$true;laterDiagnosticZipBytesEqual=$true
            console=(Join-Path $compoundRoot 'console.log');zip=$compoundZip}
        Write-MatureClosedJson $compoundProof (Join-Path $compoundRoot 'proof.json')
    }
    finally{$compoundBad.Dispose();$compoundConsole.Dispose()}
    Write-MatureClosedJson @{passed=$true;realScratchLockHeldThroughoutZip=$true;originalCauseRethrown=$true
        originalError=$primary;secondaryError=$secondary;rethrowStack=$caught.ScriptStackTrace;rethrowInvocation=$caught.InvocationInfo.PositionMessage
        consolePath=(Join-Path $evidence 'console.log')
        diagnosticsZip=$zip;rawZip=$rawZip;outputCorpusFiles=119;allOutputBytesEqual=$true;allMetadataZipBytesEqual=$true;all119RawZipBytesEqual=$true;hiddenObjIncluded=$true
        scratchLockInArchives=$false;negativeUnfinalizedRaw=$noFinal;copyFailureExplicit=$partial.errors
        compoundCopyAndReportingFailure=$compoundProof
        provisionalMonitorFailure=@{passed=$true;manifest=$provisionalResult;originalErrorPreserved=$true;archiveBytesEqual=$true;stageFailed=$provisionalFailed}
        invalidArchiveEligibility=$eligibility
        actualRecordings=0;servicesStarted=0;oldScratchGuidUsed=$false} (Join-Path $Output 'test-result.json')
}
finally
{
    [Console]::SetError($originalConsole)
    $lock.Dispose()
    $console.Dispose()
}
