. (Join-Path $PSScriptRoot 'Failure.ps1')

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
    $rawFiles=[Collections.Generic.List[string]]::new()
    $finalized=$false
    $rawState='missing own successful start/stop receipt'

    function Add-RetentionError([Management.Automation.ErrorRecord]$Record,[string]$Phase)
    {
        $errors.Add(@{phase=$Phase;message=$Record.Exception.Message;error=$Record.ToString();stack=$Record.ScriptStackTrace})
        $null=Write-MatureFailure $Record (Join-Path $metadata 'retention-errors') $Phase 'staging' @()
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

    # A filename is not finalization. Only this recorded owned session's
    # successful, non-timeout start AND stop authorizes copying its raw archive.
    $capture=Join-Path $EvidenceRoot 'measurements\capture'
    $sessionPath=Join-Path $capture 'session-final.json'
    try
    {
        if(Test-Path -LiteralPath $sessionPath)
        {
            $state=Get-Content -LiteralPath $sessionPath -Raw|ConvertFrom-Json
            $guid=[Guid]::Empty
            $archive=Join-Path $capture 'mature-csc.diagsession'
            $owned=$state.started -and $state.stopAttempted -and [Guid]::TryParse($state.sessionId,[ref]$guid) -and
                $state.startReceipt.exitCode -eq 0 -and -not$state.startReceipt.timedOut -and $state.startReceipt.outputComplete -and
                $state.stopReceipt.exitCode -eq 0 -and -not$state.stopReceipt.timedOut -and $state.stopReceipt.outputComplete -and
                $state.startReceipt.arguments[0] -ceq 'start' -and $state.startReceipt.arguments[1] -ceq $state.sessionId -and
                $state.startReceipt.arguments -ccontains "/attach:$($state.identity.pid)" -and
                $state.stopReceipt.arguments[0] -ceq 'stop' -and $state.stopReceipt.arguments[1] -ceq $state.sessionId -and
                $state.stopReceipt.arguments -ccontains "/output:$archive" -and
                [IO.Path]::GetFullPath($state.output) -ceq $archive -and
                $state.identity.pid -gt 0 -and $state.identity.startTicks -gt 0
            if(-not$owned){throw 'Raw archive has no valid owned successful start/stop/finalized-output proof.'}
            if(-not(Test-Path -LiteralPath $archive) -or (Get-Item -LiteralPath $archive -Force).Length -eq 0){throw 'Finalized raw archive missing/empty.'}
            $destination=Join-Path $raw 'capture\mature-csc.diagsession'
            Copy-MatureClosedFile $archive $destination
            $rawFiles.Add('capture\mature-csc.diagsession')
            $finalized=$true
            $rawState='owned successfully finalized archive staged as a closed copy'
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
    $result=@{metadataRoot=$metadata;rawRoot=$raw;metadataFiles=@($copied.ToArray());excludedWithoutTraversal=@($omitted.ToArray())
        errors=@($errors.ToArray());finalizedRawStaged=$finalized;rawState=$rawState
        safeRawFiles=@($rawFiles.ToArray());rawFilesAvailable=$rawFiles.Count -gt 0
        stagePassed=$errors.Count -eq 0 -and $finalized
        safety='Only closed copied diagnostics, owned finalized archive and explicit manifested bin/obj outputs; no scratch/cache/home/checkout traversal.'}
    Write-MatureClosedJson $result (Join-Path $metadata 'retention-manifest.json')
    return $result
}
