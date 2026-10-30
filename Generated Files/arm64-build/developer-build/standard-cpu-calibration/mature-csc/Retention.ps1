. (Join-Path $PSScriptRoot 'Failure.ps1')
. (Join-Path $PSScriptRoot 'Monitor.ps1')

function Copy-MatureClosedFile([string]$Source,[string]$Destination)
{
    $null=[IO.Directory]::CreateDirectory((Split-Path $Destination))
    # FileShare.Read excludes a concurrent writer. The uploaded file is a new,
    # flushed/closed copy, never a path into a live collector work directory.
    $input=[IO.FileStream]::new($Source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $pending="$Destination.pending"
    try
    {
        $output=[IO.FileStream]::new($pending,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$input.CopyTo($output);$output.Flush($true)}finally{$output.Dispose()}
    }
    finally{$input.Dispose()}
    [IO.File]::Move($pending,$Destination,$false)
}

function Stage-MatureEvidence([string]$EvidenceRoot,[string]$StageRoot)
{
    $EvidenceRoot=[IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\')
    $StageRoot=[IO.Path]::GetFullPath($StageRoot).TrimEnd('\')
    if([IO.Path]::GetFileName($EvidenceRoot) -cne 'evidence')
    {throw 'Only the lane controlled evidence directory may be staged, never a checkout/home root.'}
    if($StageRoot.StartsWith($EvidenceRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or $StageRoot -ceq $EvidenceRoot)
    {throw 'Upload stage must be outside source evidence/work directories.'}
    if(Test-Path -LiteralPath $StageRoot){throw 'Refusing staged evidence overwrite.'}
    $metadata=Join-Path $StageRoot 'metadata'
    $raw=Join-Path $StageRoot 'raw'
    $null=New-Item -ItemType Directory -Path $metadata
    $copied=[Collections.Generic.List[object]]::new()
    $omitted=[Collections.Generic.List[object]]::new()
    $errors=[Collections.Generic.List[object]]::new()
    $reportingErrors=[Collections.Generic.List[object]]::new()
    $rawFiles=[Collections.Generic.List[string]]::new()
    $finalized=$false
    $recordingComplete=$false
    $rawState='missing own successful start/stop receipt'

    function Add-RetentionError([Management.Automation.ErrorRecord]$Record,[string]$Phase)
    {
        $errors.Add(@{phase=$Phase;message=$Record.Exception.Message;error=$Record.ToString();stack=$Record.ScriptStackTrace
            exception=$Record.Exception.ToString();invocation=$Record.InvocationInfo.PositionMessage})
        try{$null=Write-MatureFailure $Record (Join-Path $metadata 'retention-errors') $Phase 'staging' @()}
        catch
        {
            # Persistence can fail after the original copy error was printed.
            # Do not let that secondary error abort later copies or the manifest,
            # and never recursively use the failed reporter to report itself.
            $reportingErrors.Add(@{kind='retention-error-persistence';originalPhase=$Phase
                message=$_.Exception.Message;error=$_.ToString();stack=$_.ScriptStackTrace
                exceptionType=$_.Exception.GetType().FullName;invocation=$_.InvocationInfo.PositionMessage})
            [Console]::Error.WriteLine("P49 secondary retention reporting failure; originalPhase=$Phase")
            [Console]::Error.WriteLine($_.Exception.ToString())
            [Console]::Error.WriteLine($_.InvocationInfo.PositionMessage)
            [Console]::Error.WriteLine($_.ScriptStackTrace)
        }
    }
    function Copy-MetadataDirectory([string]$Directory)
    {
        # Prune BEFORE enumerating children: even walking collector scratch can
        # encounter locked/protected entries. Never use a recursive broad glob.
        foreach($item in Get-ChildItem -LiteralPath $Directory -Force -ErrorAction Stop)
        {
            $relative=[IO.Path]::GetRelativePath($EvidenceRoot,$item.FullName)
            try
            {
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Reparse point not permitted in retained evidence: $relative"}
            if($item.PSIsContainer)
            {
                if($item.Name -in @('.git','scratch','process-work','cache','symbol-cache','sdk-before','plain-outputs','target-outputs','contents','known-work','mature-csc'))
                {$omitted.Add(@{path=$relative;reason='excluded work/raw/cache tree; not traversed'});continue}
                Copy-MetadataDirectory $item.FullName
            }
            elseif($item.Extension -in @('.json','.jsonl','.log','.txt','.binlog','.ps1','.rsp','.bin'))
            {
                $destination=Join-Path $metadata $relative
                Copy-MatureClosedFile $item.FullName $destination
                $copied.Add(@{path=$relative;bytes=$item.Length})
            }
            }
            catch{Add-RetentionError $_ "metadata-copy-$relative"}
        }
    }
    try
    {
        if(-not(Test-Path -LiteralPath $EvidenceRoot)){throw 'Controlled evidence directory missing.'}
        Copy-MetadataDirectory $EvidenceRoot
    }
    catch{Add-RetentionError $_ 'metadata-copy'}

    # Ownership + acknowledged export allows retention, even when later monitor
    # failure makes the protocol incomplete. Never discard such a closed archive
    # or promote provisional evidence to successful profiling.
    $capture=Join-Path $EvidenceRoot 'measurements\capture'
    $sessionPath=Join-Path $capture 'session-final.json'
    try
    {
        if(Test-Path -LiteralPath $sessionPath)
        {
            $state=Get-Content -LiteralPath $sessionPath -Raw|ConvertFrom-Json
            $guid=[Guid]::Empty
            $archive=Join-Path $capture 'mature-csc.diagsession'
            # Keep full executable argv evidence, including a script-host prefix
            # in the real fake-CLI proof. Production VSDiagnostics uses index0.
            $startIndex=$state.startReceipt.commandIndex
            $stopIndex=$state.stopReceipt.commandIndex
            $owned=$state.started -and $state.startReceipt.ready -and $state.startReceipt.monitorAliveAtReady -and
                $state.startReceipt.sessionId -ceq $state.sessionId -and
                $state.startReceipt.targetIdentity.pid -eq $state.identity.pid -and
                $state.startReceipt.targetIdentity.startTicks -eq $state.identity.startTicks -and
                $state.startReceipt.targetIdentity.executablePath -ceq $state.identity.executablePath -and
                $state.stopAttempted -and $state.stopAcknowledged -and [Guid]::TryParse($state.sessionId,[ref]$guid) -and
                $state.stopReceipt.exitCode -eq 0 -and -not$state.stopReceipt.timedOut -and $state.stopReceipt.outputComplete -and
                $null -ne $startIndex -and $startIndex -ge 0 -and $startIndex+1 -lt $state.startReceipt.arguments.Count -and
                $state.startReceipt.arguments[$startIndex] -ceq 'start' -and $state.startReceipt.arguments[$startIndex+1] -ceq $state.sessionId -and
                $state.startReceipt.arguments -ccontains "/attach:$($state.identity.pid)" -and
                $state.startReceipt.arguments -ccontains '/monitor' -and
                $null -ne $stopIndex -and $stopIndex -ge 0 -and $stopIndex+1 -lt $state.stopReceipt.arguments.Count -and
                $state.stopReceipt.arguments[$stopIndex] -ceq 'stop' -and $state.stopReceipt.arguments[$stopIndex+1] -ceq $state.sessionId -and
                $state.stopReceipt.arguments -ccontains "/output:$archive" -and
                [IO.Path]::GetFullPath($state.output) -ceq $archive -and
                $state.identity.pid -gt 0 -and $state.identity.startTicks -gt 0
            if(-not$owned){throw 'Raw archive has no valid owned successful start/stop/finalized-output proof.'}
            # The validated ACK is captured in caller-owned readiness state
            # before its separate prefix file is written. Prefix persistence
            # failure must not discard an otherwise acknowledged owned export.
            if(-not(Test-MatureStatusText $state.startReceipt.ackText $state.sessionId 'Running') -or
                -not(Test-MatureStatusText (Get-Content (Join-Path $capture 'stop.stdout.log') -Raw) $state.sessionId 'Stopped'))
            {throw 'Exact owned Running/Stopped transcript ACK missing.'}
            if(-not(Test-Path -LiteralPath $archive) -or (Get-Item -LiteralPath $archive -Force).Length -eq 0){throw 'Finalized raw archive missing/empty.'}
            $destination=Join-Path $raw 'capture\mature-csc.diagsession'
            # Keep a read-only sharing lock across ZIP validation AND copying:
            # a concurrent writer/live blob cannot qualify as a closed archive.
            $input=[IO.FileStream]::new($archive,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            try
            {
                $zip=[IO.Compression.ZipArchive]::new($input,[IO.Compression.ZipArchiveMode]::Read,$true)
                try
                {
                    if($zip.Entries.Count -eq 0){throw 'Owned archive ZIP is empty.'}
                    foreach($entry in $zip.Entries)
                    {
                        $stream=$entry.Open()
                        try{$stream.CopyTo([IO.Stream]::Null)}finally{$stream.Dispose()}
                    }
                    Copy-MatureClosedFile $archive $destination
                }
                finally{$zip.Dispose()}
            }
            finally{$input.Dispose()}
            $rawFiles.Add('capture\mature-csc.diagsession')
            $finalized=$true
            $monitor=$state.monitorReceipt
            $monitorComplete=$monitor.pid -eq $state.startReceipt.pid -and $monitor.birthTicks -eq $state.startReceipt.birthTicks -and
                $monitor.executable -ceq $state.startReceipt.executable -and
                ($monitor.arguments -join "`n") -ceq ($state.startReceipt.arguments -join "`n") -and
                $monitor.exitCode -eq 0 -and -not$monitor.timedOut -and $monitor.outputComplete -and $monitor.captureComplete
            $protocolPath=Join-Path $EvidenceRoot 'measurements\final-state.json'
            $gatePath=Join-Path $capture 'qualified-gate.json'
            if($monitorComplete -and (Test-Path $protocolPath) -and (Test-Path $gatePath))
            {
                $protocol=Get-Content $protocolPath -Raw|ConvertFrom-Json
                $gate=Get-Content $gatePath -Raw|ConvertFrom-Json
                $recordingComplete=$null -eq $protocol.failure -and $protocol.completedCases -eq 24 -and
                    $protocol.secondaryFailures.Count -eq 0 -and $protocol.reportingFailures.Count -eq 0 -and
                    $protocol.restorationPassed -and $gate.qualifiedFileAndSampleGate
            }
            $rawState=if($recordingComplete){'owned closed archive; monitor/work/qualified gates complete'}else{'PROVISIONAL owned closed archive retained; monitor/protocol/quality incomplete or failed'}
        }
    }
    catch{$rawState=$_.Exception.Message;Add-RetentionError $_ 'finalized-raw-copy'}
    foreach($name in @('plain-outputs','target-outputs'))
    {
        $directory=Join-Path $EvidenceRoot "measurements\$name"
        $manifest=Join-Path $directory 'manifest.json'
        if(-not(Test-Path -LiteralPath $manifest)){continue}
        try
        {
            $files=@(Get-Content -LiteralPath $manifest -Raw|ConvertFrom-Json)
            foreach($file in $files)
            {
                $relative=$file.relativePath
                $source=[IO.Path]::GetFullPath((Join-Path $directory $relative))
                if([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)' -or
                    -not$source.StartsWith($directory+'\',[StringComparison]::OrdinalIgnoreCase) -or
                    $relative -notmatch '^(bin|obj)[\\/]')
                {throw 'Output manifest escaped controlled bin/obj roots.'}
                if((Get-Item -LiteralPath $source -Force).Length -ne $file.bytes){throw "Closed output length mismatch: $relative"}
                $path=Join-Path $name $relative
                Copy-MatureClosedFile $source (Join-Path $raw $path)
                $rawFiles.Add($path)
            }
            Copy-MatureClosedFile $manifest (Join-Path $raw "$name\manifest.json")
            $rawFiles.Add("$name\manifest.json")
        }
        catch{Add-RetentionError $_ "closed-output-$name"}
    }
    if($finalized -and $errors.Count -gt 0)
    {$recordingComplete=$false;$rawState='PROVISIONAL owned closed archive retained; retention errors present'}
    $result=@{metadataRoot=$metadata;rawRoot=$raw;metadataFiles=@($copied.ToArray());excludedWithoutTraversal=@($omitted.ToArray())
        errors=@($errors.ToArray());reportingErrors=@($reportingErrors.ToArray());finalizedRawStaged=$finalized;rawState=$rawState
        rawRecordingComplete=$recordingComplete;provisionalRawStaged=$finalized -and -not$recordingComplete
        safeRawFiles=@($rawFiles.ToArray());rawFilesAvailable=$rawFiles.Count -gt 0
        stagePassed=$errors.Count -eq 0 -and $recordingComplete
        safety='Only closed copied diagnostics, owned finalized archive and explicit manifested bin/obj outputs; no scratch/cache/home/checkout traversal.'}
    Write-MatureClosedJson $result (Join-Path $metadata 'retention-manifest.json')
    return $result
}
