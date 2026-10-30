. (Join-Path $PSScriptRoot 'Common-P38.ps1')
$directory = Join-Path $evidence 'block-1'
$records = @(Get-Content "$directory\results.json" -Raw | ConvertFrom-Json)
if ($records.Count -ne 28 -or (Test-Path "$directory\failure.json"))
{
    throw 'Incomplete single block: no promotion or retry.'
}
$arms = @('1-baseline','2-candidate','3-candidate','4-baseline')
$cases = @('cold','noop','edit1','edit2','edit3','edit4','edit5')
$comparisons = @()
$compilations = @()

function Compare-OutputTrees([string] $Reference, [string] $Actual)
{
    $paths = @(Get-ChildItem $Reference -Recurse -File |
        ForEach-Object { [IO.Path]::GetRelativePath($Reference, $_.FullName) } | Sort-Object)
    $actualPaths = @(Get-ChildItem $Actual -Recurse -File |
        ForEach-Object { [IO.Path]::GetRelativePath($Actual, $_.FullName) } | Sort-Object)
    $differences = @(Compare-Object $paths $actualPaths | ForEach-Object InputObject)
    foreach ($path in $paths)
    {
        $actualFile = Join-Path $Actual $path
        if ((Test-Path $actualFile) -and -not [Linq.Enumerable]::SequenceEqual[byte](
            [IO.File]::ReadAllBytes((Join-Path $Reference $path)),
            [IO.File]::ReadAllBytes($actualFile)))
        {
            $differences += $path
        }
    }
    return @{ reference = $Reference; actual = $Actual; files = $paths.Count
        bytes = [long]((Get-ChildItem $Reference -Recurse -File | Measure-Object Length -Sum).Sum)
        differences = $differences }
}

foreach ($case in $cases)
{
    $reference = Join-Path $directory "1-baseline\$case"
    $referenceData = Get-Content "$reference\csc.json" -Raw | ConvertFrom-Json
    $referenceCommands = ConvertTo-Json -InputObject @($referenceData.tasks |
        Select-Object project,target,commandLine,analyzerPaths | Sort-Object project,target,commandLine) -Depth 10 -Compress
    foreach ($arm in $arms)
    {
        $actual = Join-Path $directory "$arm\$case"
        $comparisons += Compare-OutputTrees "$reference\outputs" "$actual\outputs"
        $data = Get-Content "$actual\csc.json" -Raw | ConvertFrom-Json
        $commands = ConvertTo-Json -InputObject @($data.tasks |
            Select-Object project,target,commandLine,analyzerPaths | Sort-Object project,target,commandLine) -Depth 10 -Compress
        $unexpectedProjects = @($data.tasks | Where-Object {
            $_.project -notlike '*\Aspire.Hosting.csproj' -and
            $_.project -notlike '*\Aspire.Hosting.Integration.Analyzers.csproj'
        } | Select-Object -ExpandProperty project -Unique)
        $proof = Get-Content "$actual\compiler.json" -Raw | ConvertFrom-Json
        $compilations += @{
            arm = $arm; case = $case; commandsIdentical = $commands -ceq $referenceCommands
            cscCount = $data.cscCount; allSuccessful = $data.successful -and -not $data.unfinishedCscCount
            diagnosticCount = $data.diagnostics.Count; unexpectedProjects = $unexpectedProjects
            projects = @($data.tasks.project | Select-Object -Unique)
            processedByServer = @($data.tasks | Where-Object {
                -not $_.succeeded -or @($_.compilerServerMessages | Where-Object { $_ -match 'server - server processed compilation' }).Count -ne 1
            }).Count -eq 0
            compilerPid = $proof.identity.pid; nativeRuntime = $proof.modules
        }
    }
}
foreach ($arm in $arms)
{
    $comparisons += Compare-OutputTrees "$directory\$arm\cold\outputs" "$directory\$arm\noop\outputs"
}

function Median($Values)
{
    $sorted = @($Values | Sort-Object)
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2)
    {
        return [double]$sorted[$middle]
    }
    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2
}

$summaries = @(
    foreach ($index in 1..4)
    {
        $items = @($records | Where-Object index -EQ $index)
        $edits = @($items | Where-Object case -Like 'edit*')
        $mature = @($items | Where-Object case -In @('edit3','edit4','edit5'))
        @{
            index = $index; arm = $items[0].arm
            coldWall = ($items | Where-Object case -EQ 'cold').wallSeconds
            coldMainCsc = ($items | Where-Object case -EQ 'cold').mainCscSeconds
            noopWall = ($items | Where-Object case -EQ 'noop').wallSeconds
            editMedianWall = Median $edits.wallSeconds
            matureMedianWall = Median $mature.wallSeconds
            editMedianMainCsc = Median $edits.mainCscSeconds
            matureMedianMainCsc = Median $mature.mainCscSeconds
        }
    }
)
$baseline = @($summaries | Where-Object arm -EQ 'baseline')
$candidate = @($summaries | Where-Object arm -EQ 'candidate')
$coldGain = 1 - (Median $candidate.coldWall) / (Median $baseline.coldWall)
$matureGain = 1 - (Median $candidate.matureMedianWall) / (Median $baseline.matureMedianWall)
$coldSeparated = ($candidate.coldWall | Measure-Object -Maximum).Maximum -lt ($baseline.coldWall | Measure-Object -Minimum).Minimum
$matureSeparated = ($candidate.matureMedianWall | Measure-Object -Maximum).Maximum -lt ($baseline.matureMedianWall | Measure-Object -Minimum).Minimum
$state = Get-Content "$directory\final-state.json" -Raw | ConvertFrom-Json
$cleanup = @(Get-Content "$directory\cleanup.json" -Raw | ConvertFrom-Json)
$quality = @($comparisons | Where-Object { $_.differences.Count -or $_.files -eq 0 }).Count -eq 0 -and
    @($compilations | Where-Object {
        -not $_.commandsIdentical -or -not $_.allSuccessful -or -not $_.processedByServer -or
        $_.diagnosticCount -or $_.unexpectedProjects.Count
    }).Count -eq 0 -and
    $state.sourceBytesRestored -and $state.sourceTimestampRestored -and
    $state.configBytesRestored -and $state.configTimestampRestored -and
    $state.sourceHead -eq '06efc928e31486923754398007f4f78003e04ee3' -and
    $state.sourceStatus.Count -eq 0 -and $state.remainingOwnedCompilers.Count -eq 0 -and -not $state.failure -and
    @($state.remainingWorkers | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath.StartsWith("$private\", [StringComparison]::OrdinalIgnoreCase)
    }).Count -eq 0 -and @($cleanup | Where-Object { -not $_.exitConfirmed }).Count -eq 0
$coldEligible = $quality -and $coldGain -ge 0.05 -and $coldSeparated -and $matureGain -gt -0.05
$warmEligible = $quality -and $matureGain -ge 0.05 -and $matureSeparated -and $coldGain -gt -0.05
$result = @{
    qualityPassed = $quality; arms = $summaries; cases = $records
    exactCommands = @(
        foreach ($record in $records)
        {
            Get-Content "$($record.directory)\build.result.json" -Raw | ConvertFrom-Json
        }
    )
    protocol = Get-Content "$directory\protocol.json" -Raw | ConvertFrom-Json
    setupRestore = Get-Content "$evidence\repository-restore.result.json" -Raw | ConvertFrom-Json
    untimedPreparationFailures = @(
        "$evidence\preflight-serialization-failure-01\failure.json",
        "$evidence\prewarm-proof-failure-02\failure.json"
    )
    warmupBuildsPerMode = 1
    timedArms = 4
    runtimeconfigSnapshots = @("$directory\baseline.runtimeconfig.json", "$directory\candidate.runtimeconfig.json")
    scripts = @("$evidence\Common-P38.ps1", "$evidence\Measure-P38.ps1", "$evidence\Verify-P38.ps1")
    producerPrototype = @{
        path = "$evidence\roslyn-compiler-pgo.prototype.patch"
        source = 'dotnet/roslyn@cf91b80aa2f0eb5b64d7bdb544170d9744883f72'
        validation = Get-Content "$evidence\producer-patch-validation.json" -Raw | ConvertFrom-Json
        built = $false
        appliedToProduct = $false
        adopted = $false
    }
    coldMedianGainFraction = $coldGain; matureMedianGainFraction = $matureGain
    bothCandidatesBeatBothBaselinesCold = $coldSeparated
    bothCandidatesBeatBothBaselinesMatureEdits = $matureSeparated
    coldEligible = $coldEligible; matureEligible = $warmEligible
    promotion = if ($coldEligible -or $warmEligible) { 'Eligible for separately gated matched evidence, NOT adoption.' } else { 'REJECT promotion; no retries or CI.' }
    outputComparisons = $comparisons; compilationChecks = $compilations; finalState = $state
    cleanupReceipts = $cleanup
    confidence = @{
        measurement = 'High: actual complete single block, native identities, binlogs and byte comparisons.'
        causality = 'Medium at best: two arms per mode in one order-controlled block, not twenty independent edit replicates.'
        windowsMacParity = 'Low/unmeasured: no matched Mac/Release evidence or product adoption.'
    }
}
Write-Json $result (Join-Path $evidence 'REPORT.json')
$summaries | ForEach-Object { [pscustomobject] $_ } | Format-Table index,arm,coldWall,noopWall,editMedianWall,matureMedianWall,coldMainCsc,editMedianMainCsc
$result.promotion
if (-not $quality)
{
    throw 'Quality/output/restoration gate failed; evidence retained.'
}
