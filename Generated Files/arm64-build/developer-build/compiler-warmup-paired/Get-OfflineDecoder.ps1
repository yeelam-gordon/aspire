[CmdletBinding()]
param([Parameter(Mandatory)][string]$Destination)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $Destination) { throw 'Refusing decoder acquisition overwrite.' }
$null = New-Item -ItemType Directory -Path $Destination
$Destination = (Resolve-Path $Destination).Path
# Reuse P41's exact managed TraceEvent reader version, OFFLINE only. This is
# neither a profiler installation nor loaded into any measured/diagnostic app.
# No NuGet config, package manifest, product SDK or runtimeconfig is modified.
$index = 'https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-public/nuget/v3/index.json'
$resources = (Invoke-RestMethod $index).resources
$bases = @($resources | Where-Object { $_.'@type' -eq 'PackageBaseAddress/3.0.0' })
if ($bases.Count -ne 1 -or $bases[0].'@id' -notlike 'https://pkgs.dev.azure.com/dnceng/*')
{
    throw 'Approved offline-library package base unavailable.'
}
$uri = $bases[0].'@id'.TrimEnd('/') + '/microsoft.diagnostics.tracing.traceevent/3.1.28/microsoft.diagnostics.tracing.traceevent.3.1.28.nupkg'
$archive = Join-Path $Destination 'traceevent-3.1.28.zip'
Invoke-WebRequest $uri -OutFile $archive
Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $Destination 'contents')
$files = @(Get-ChildItem (Join-Path $Destination 'contents') -Recurse -Filter 'Microsoft.Diagnostics.Tracing.TraceEvent.dll' -File |
    Where-Object { $_.FullName -match '[\\/]netstandard2.0[\\/]' })
if ($files.Count -ne 1) { throw 'Expected one portable offline decoder library.' }
$library = $files[0].DirectoryName
if (-not (Test-Path (Join-Path $library 'Microsoft.Diagnostics.FastSerialization.dll'))) { throw 'Offline serialization dependency missing.' }
@{ feed = $index; archiveUrl = $uri; library = $library
    assembly = [Reflection.AssemblyName]::GetAssemblyName($files[0].FullName).FullName
    purpose = 'P41-compatible offline nettrace decoding only; no target instrumentation package' } |
    ConvertTo-Json | Set-Content (Join-Path $Destination 'identity.json')
return $library
