$ErrorActionPreference='Stop'

function Write-MatureClosedJson($Value,[string]$Path)
{
    $parent=Split-Path $Path
    if(-not(Test-Path -LiteralPath $parent)){$null=New-Item -ItemType Directory -Path $parent}
    $pending="$Path.$([Guid]::NewGuid().ToString('N')).pending"
    $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 30))
    $stream=[IO.FileStream]::new($pending,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes);$stream.Flush($true)}finally{$stream.Dispose()}
    [IO.File]::Move($pending,$Path,$false)
}

function Write-MatureFailure([Management.Automation.ErrorRecord]$Record,[string]$Directory,
    [string]$Phase,[string]$Kind,[string[]]$ReceiptPaths)
{
    # Console first: durable storage/staging can fail independently. Preserve
    # the real cause/position/stack even if no artifact can ever be uploaded.
    [Console]::Error.WriteLine("P49 $Kind failure; phase=$Phase")
    [Console]::Error.WriteLine($Record.Exception.ToString())
    [Console]::Error.WriteLine($Record.InvocationInfo.PositionMessage)
    [Console]::Error.WriteLine($Record.ScriptStackTrace)
    $inners=@()
    for($inner=$Record.Exception.InnerException;$null -ne $inner;$inner=$inner.InnerException)
    {$inners+=@{type=$inner.GetType().FullName;message=$inner.Message;stack=$inner.StackTrace}}
    $value=@{
        kind=$Kind;phase=$Phase;recordedUtc=[DateTime]::UtcNow.ToString('O');observerPid=$PID
        message=$Record.Exception.Message;exceptionType=$Record.Exception.GetType().FullName
        exception=$Record.Exception.ToString();innerCauses=$inners
        fullyQualifiedErrorId=$Record.FullyQualifiedErrorId;category=$Record.CategoryInfo.ToString()
        errorDetails=$Record.ErrorDetails.Message;scriptStackTrace=$Record.ScriptStackTrace
        invocation=@{scriptName=$Record.InvocationInfo.ScriptName;lineNumber=$Record.InvocationInfo.ScriptLineNumber
            offset=$Record.InvocationInfo.OffsetInLine;line=$Record.InvocationInfo.Line
            invocationName=$Record.InvocationInfo.InvocationName;position=$Record.InvocationInfo.PositionMessage}
        receiptPaths=@($ReceiptPaths|ForEach-Object{@{path=$_;exists=[IO.File]::Exists($_)}})
    }
    $name="$Kind-$([Guid]::NewGuid().ToString('N')).json"
    $path=Join-Path $Directory $name
    try{Write-MatureClosedJson $value $path}
    catch
    {
        [Console]::Error.WriteLine("P49 failure-record persistence failed: $($_.Exception)")
        throw
    }
    return $path
}

function Register-MatureFailure([hashtable]$State,[Management.Automation.ErrorRecord]$Record,
    [string]$Phase,[string]$Kind,[string[]]$ReceiptPaths)
{
    if($null -eq $State.primary){$State.primary=$Record;$State.primaryPhase=$Phase}
    elseif(-not[object]::ReferenceEquals($State.primary,$Record)){$State.secondary.Add($Record)}
    else{return}
    try
    {
        $path=Write-MatureFailure $Record $State.directory $Phase $Kind $ReceiptPaths
        $State.records.Add($path)
    }
    catch
    {
        # Reporting failure is explicit secondary state, never a replacement
        # for the primary ErrorRecord which the caller must rethrow.
        $State.reportingErrors.Add(@{phase=$Phase;error=$_.ToString();stack=$_.ScriptStackTrace})
        [Console]::Error.WriteLine("P49 secondary observability failure: $($_.Exception)")
    }
}
