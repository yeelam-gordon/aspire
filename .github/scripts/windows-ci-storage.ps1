[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('stock', 'refs', 'devdrive')][string]$Variant,
    [Parameter(Mandatory)][string]$EvidencePath,
    [switch]$LoadFunctionsOnly
)

$ErrorActionPreference = 'Stop'
function Assert-StorageAdmission([object]$Inventory)
{
    if ($Inventory.Variant -notin @('stock', 'refs', 'devdrive')) { throw 'Unknown storage treatment.' }
    if ($Inventory.Hosting -ne 'github-hosted' -or $Inventory.RunnerArchitecture -ne 'ARM64' -or
        $Inventory.OsArchitecture -ne 'Arm64' -or $Inventory.ProcessArchitecture -ne 'Arm64')
    {
        throw 'Storage comparison requires native ARM64 on an ephemeral GitHub-hosted runner.'
    }
    if (!$Inventory.RealTimeProtectionEnabled -or !$Inventory.AntivirusEnabled)
    {
        throw 'Active antivirus and real-time protection are required in both arms.'
    }
    if ($Inventory.Variant -eq 'stock') { return }
    if ($Inventory.Variant -eq 'devdrive' -and $Inventory.DevDriveSupported -ne $true)
    {
        throw 'Format-Volume does not support Dev Drive on this runner; do not initialize storage.'
    }
    if ($Inventory.DriveAssigned -ne $false) { throw 'D: is assigned or unknown; candidate is unqualified, not a no-op sample.' }
    $eligible = @($Inventory.Disks | Where-Object {
        $_.BusType -eq 'NVMe' -and $_.PartitionStyle -eq 'RAW' -and
        $_.IsBoot -eq $false -and $_.IsSystem -eq $false -and
        $_.IsOffline -eq $false -and $_.IsReadOnly -eq $false -and
        $_.NumberOfPartitions -eq 0 -and $_.Size -ge 50GB -and
        $_.Number -notin $Inventory.PartitionDiskNumbers
    })
    if ($eligible.Count -ne 1) { throw "Expected one unused raw NVMe disk; found$($eligible.Count)." }
    if ($Inventory.WorkspaceIsDirectory -ne $true -or $Inventory.WorkspaceIsReparsePoint -ne $false)
    {
        throw 'Workspace must be an ordinary directory.'
    }
    return $eligible[0]
}
function Move-CiWorkspace([IO.DirectoryInfo]$Workspace, [string]$Destination, [string]$TemporaryDirectory)
{
    Set-Location -LiteralPath $TemporaryDirectory
    [Environment]::CurrentDirectory = $TemporaryDirectory
    $null = New-Item -ItemType Directory -Path $Destination
    # Preserve the populated checkout, hidden metadata, ACLs and links. Robocopy
    # uses exit0-7 for completed copies; exit8+ is a failure, before any rename.
    & robocopy $Workspace.FullName $Destination /E /COPY:DATS /DCOPY:DAT /SL /SJ /R:2 /W:1 /NP
    $copyExit = $LASTEXITCODE
    if ($copyExit -ge 8) { throw "Workspace copy failed with robocopy exit$copyExit; original remains intact." }
    # GitHub's pwsh wrapper exits with LASTEXITCODE; normalize only Robocopy's
    # documented completed-copy codes, retaining the actual value in the receipt.
    $global:LASTEXITCODE = 0
    $backup = "$($Workspace.FullName).before-refs-$([guid]::NewGuid().ToString('N'))"
    Move-Item -LiteralPath $Workspace.FullName -Destination $backup
    try { $null = New-Item -ItemType Junction -Path $Workspace.FullName -Target $Destination }
    catch
    {
        Write-Error -ErrorAction Continue "Junction creation failed; restoring original workspace from$backup."
        Move-Item -LiteralPath $backup -Destination $Workspace.FullName
        throw
    }
    return [pscustomobject]@{ Backup = $backup; CopyExitCode = $copyExit }
}
if ($LoadFunctionsOnly) { return }

$partitions = @(Get-Partition)
$protection = Get-MpComputerStatus
$preference = Get-MpPreference
$formatCommand = Get-Command Format-Volume -ErrorAction Stop
$workspace = Get-Item -LiteralPath $env:GITHUB_WORKSPACE -Force
$inventory = [pscustomobject]@{
    Variant = $Variant
    Hosting = $env:STORAGE_HOSTING
    RunnerArchitecture = $env:STORAGE_RUNNER_ARCH
    OsArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    ProcessArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    RealTimeProtectionEnabled = $protection.RealTimeProtectionEnabled
    AntivirusEnabled = $protection.AntivirusEnabled
    DevDriveSupported = $formatCommand.Parameters.ContainsKey('DevDrive')
    DriveAssigned = [bool](@($partitions | Where-Object DriveLetter -EQ 'D').Count -or
        @(Get-Volume | Where-Object DriveLetter -EQ 'D').Count -or
        @(Get-PSDrive -PSProvider FileSystem | Where-Object Name -EQ 'D').Count)
    Disks = @(Get-Disk)
    PartitionDiskNumbers = @($partitions.DiskNumber)
    WorkspaceIsDirectory = $workspace.PSIsContainer
    WorkspaceIsReparsePoint = [bool]($workspace.Attributes -band [IO.FileAttributes]::ReparsePoint)
}
$disk = Assert-StorageAdmission $inventory
$began = [DateTime]::UtcNow
$record = [ordered]@{
    variant = $Variant; source = $env:GITHUB_SHA; runId = $env:GITHUB_RUN_ID
    runAttempt = $env:GITHUB_RUN_ATTEMPT; imageOS = $env:ImageOS; imageVersion = $env:ImageVersion
    osArchitecture = $inventory.OsArchitecture; processArchitecture = $inventory.ProcessArchitecture
    logicalProcessors = [Environment]::ProcessorCount
    realTimeProtectionBefore = $protection.RealTimeProtectionEnabled
    antivirusBefore = $protection.AntivirusEnabled
    workspaceLogical = $workspace.FullName
    workspacePhysical = $workspace.FullName
    filesystem = (Get-Volume -FilePath $workspace.FullName).FileSystem
    diskInitialized = $false
    protectionPolicyOverridden = $false
    defenderPerformanceModeStatus = $preference.PerformanceModeStatus
    effectiveVolumeProtectionMayDiffer = ($Variant -eq 'devdrive')
    devDriveCreated = $false
    workspaceBackup = $null
}
if ($Variant -ne 'stock')
{
    # Revalidate immediately before the only destructive operation. Never clear,
    # resize or format a previously partitioned disk, including on self-hosted CI.
    $inventory.Disks = @(Get-Disk)
    $inventory.PartitionDiskNumbers = @((Get-Partition).DiskNumber)
    $disk = Assert-StorageAdmission $inventory
    $partition = Initialize-Disk -InputObject $disk -PartitionStyle GPT -PassThru |
        New-Partition -UseMaximumSize -DriveLetter D
    # Dev Drive uses ReFS and can change default per-volume scan scheduling.
    # Keep plain ReFS as a separate control; never force trust, remove filters,
    # disable protection or add exclusions to manufacture a performance result.
    # https://learn.microsoft.com/defender-endpoint/microsoft-defender-endpoint-antivirus-performance-mode
    $volume = if ($Variant -eq 'devdrive')
    {
        $partition | Format-Volume -DevDrive -FileSystem ReFS -NewFileSystemLabel 'AspireBuild' -Confirm:$false
    }
    else
    {
        $partition | Format-Volume -FileSystem ReFS -NewFileSystemLabel 'AspireBuild' -Confirm:$false
    }
    if ($volume.FileSystem -ne 'ReFS' -or $volume.DriveLetter -ne 'D')
    {
        throw 'New storage volume is not the expected ReFS D: volume.'
    }
    if ($Variant -eq 'devdrive')
    {
        $query = @(& fsutil devdrv query D: 2>&1)
        $queryExit = $LASTEXITCODE
        if ($queryExit -ne 0) { throw "New Dev Drive could not be queried:exit$queryExit; $($query -join ' ')" }
        $record.devDriveCreated = $true
        $record.devDriveQuery = @($query | ForEach-Object { "$_" })
        $record.devDriveQueryExitCode = $queryExit
    }
    $migration = @(Move-CiWorkspace $workspace 'D:\workspace' $env:RUNNER_TEMP)[-1]
    $null = New-Item -ItemType Directory -Path 'D:\build-temp'
    "TEMP=D:\build-temp" >> $env:GITHUB_ENV
    "TMP=D:\build-temp" >> $env:GITHUB_ENV
    $record.workspacePhysical = 'D:\workspace'
    $record.workspaceBackup = $migration.Backup
    $record.filesystem = 'ReFS'
    $record.diskInitialized = $true
    $record.diskNumber = $disk.Number
    $record.copyExitCode = $migration.CopyExitCode
}
$after = Get-MpComputerStatus
if (!$after.RealTimeProtectionEnabled -or !$after.AntivirusEnabled)
{
    throw 'Protection is not enabled after storage preparation; do not build.'
}
$record.realTimeProtectionAfter = $after.RealTimeProtectionEnabled
$record.antivirusAfter = $after.AntivirusEnabled
$record.preparationSeconds = ([DateTime]::UtcNow - $began).TotalSeconds
$record.packageCache = $env:NUGET_PACKAGES
$record.tempForFollowingSteps = if ($Variant -ne 'stock') { 'D:\build-temp' } else { $env:TEMP }
$parent = Split-Path -Parent $EvidencePath
$null = [IO.Directory]::CreateDirectory($parent)
$record | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $EvidencePath -Encoding utf8
Write-Output "Storage prepared:$Variant, filesystem:$($record.filesystem); antivirus is enabled, volume scan behavior is recorded separately."
