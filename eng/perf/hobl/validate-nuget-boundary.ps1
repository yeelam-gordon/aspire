# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SdkDirectory,
    [Parameter(Mandatory)][string]$SourceConfig
)

. (Join-Path $PSScriptRoot 'Hobl.ps1')
if ((Split-Path $SdkDirectory -Leaf) -ne '10.0.100-preview.5.25277.114') { throw 'Use the pinned SDK NuGet engine.' }
Add-Type -Path (Join-Path $SdkDirectory 'NuGet.Common.dll')
Add-Type -Path (Join-Path $SdkDirectory 'NuGet.Configuration.dll')
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$fixture = Join-Path $repoRoot ('artifacts\hobl-nuget-fixture-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixture
function Get-PolicyState {
    param($Settings)
    $state = [ordered]@{}
    foreach ($sectionName in @('auditSources', 'disabledPackageSources', 'fallbackPackageFolders', 'trustedSigners')) {
        $rows = foreach ($item in $Settings.GetSection($sectionName).Items) {
            $attributes = [ordered]@{}
            foreach ($attribute in $item.GetAttributes().GetEnumerator() | Sort-Object Key) {
                $attributes[$attribute.Key] = $attribute.Value
            }
            $row = [ordered]@{ element = $item.ElementName; attributes = $attributes }
            if ($item -is [NuGet.Configuration.AuthorItem]) {
                $row.certificates = @($item.Certificates | ForEach-Object {
                    [ordered]@{ fingerprint = $_.Fingerprint; hashAlgorithm = $_.HashAlgorithm.ToString(); allowUntrustedRoot = $_.AllowUntrustedRoot }
                })
            }
            $row
        }
        $state[$sectionName] = @($rows)
    }
    $state.signatureValidation = [NuGet.Configuration.SettingsUtility]::GetSignatureValidationMode($Settings).ToString()
    $state.fallbackPaths = @([NuGet.Configuration.SettingsUtility]::GetFallbackPackageFolders($Settings))
    $provider = [NuGet.Configuration.PackageSourceProvider]::new($Settings)
    $state.dotnet9Enabled = @($provider.LoadPackageSources() | Where-Object Name -EQ 'dotnet9')[0].IsEnabled
    $state.effectiveAuditSources = @($provider.LoadAuditSources() | ForEach-Object {
        [ordered]@{ name = $_.Name; source = $_.Source; enabled = $_.IsEnabled }
    })
    return $state
}
try {
    $boundaryRoot = Join-Path $fixture 'boundary'
    $child = Join-Path $boundaryRoot 'source'
    $null = New-Item -ItemType Directory -Path $child
    $original = Get-Content -LiteralPath $SourceConfig -Raw
    Copy-Item -LiteralPath $SourceConfig -Destination (Join-Path $child 'NuGet.config')
    # The source clears packageSources, not inherited packageSourceMapping.
    # An ancestor's exact ghost-feed mapping consequently beats source "*" rules.
    $fallback = Join-Path $fixture 'fallback'
    $null = New-Item -ItemType Directory -Path $fallback
    $escapedFallback = [Security.SecurityElement]::Escape($fallback)
    $fingerprint = '0' * 64
    Set-Content (Join-Path $fixture 'NuGet.Config') @"
<configuration>
  <config><add key="signatureValidationMode" value="require" /></config>
  <packageSources><add key="hobl-fixture-ghost" value="https://invalid.example/unused" /></packageSources>
  <packageSourceMapping>
    <packageSource key="hobl-fixture-ghost">
      <package pattern="Microsoft.Diagnostics.Runtime" />
      <package pattern="NuGet.Common" />
    </packageSource>
  </packageSourceMapping>
  <auditSources>
    <clear />
    <add key="fixture-audit" value="https://pkgs.dev.azure.com/dnceng/public/_packaging/hobl-fixture-audit/nuget/v3/index.json" />
  </auditSources>
  <disabledPackageSources><add key="dotnet9" value="true" /></disabledPackageSources>
  <fallbackPackageFolders><clear /><add key="fixture-fallback" value="$escapedFallback" /></fallbackPackageFolders>
  <trustedSigners>
    <clear />
    <author name="fixture-author">
      <certificate fingerprint="$fingerprint" hashAlgorithm="SHA256" allowUntrustedRoot="false" />
    </author>
  </trustedSigners>
</configuration>
"@
    $beforeSettings = [NuGet.Configuration.Settings]::LoadDefaultSettings($child)
    $before = [NuGet.Configuration.PackageSourceMapping]::GetPackageSourceMapping(
        $beforeSettings)
    if ($before.GetConfiguredPackageSources('Microsoft.Diagnostics.Runtime') -notcontains 'hobl-fixture-ghost') {
        throw 'Fixture did not reproduce ancestor routing.'
    }
    $policyBefore = Get-PolicyState $beforeSettings
    if ($policyBefore.signatureValidation -ne 'Require' -or $policyBefore.dotnet9Enabled -or
        $policyBefore.fallbackPaths -notcontains $fallback -or
        $policyBefore.effectiveAuditSources.Count -ne 1 -or
        $policyBefore.effectiveAuditSources[0].name -ne 'fixture-audit' -or
        @($policyBefore.trustedSigners | Where-Object element -EQ 'author').Count -ne 1) {
        throw "Fixture did not establish audit/disabled/fallback/trusted/signature policy: $($policyBefore | ConvertTo-Json -Depth 15 -Compress)"
    }
    $null = New-HoblNuGetBoundary $boundaryRoot
    $afterSettings = [NuGet.Configuration.Settings]::LoadDefaultSettings($child)
    $after = [NuGet.Configuration.PackageSourceMapping]::GetPackageSourceMapping(
        $afterSettings)
    foreach ($package in @('Microsoft.Diagnostics.Runtime', 'NuGet.Common')) {
        $feeds = @($after.GetConfiguredPackageSources($package))
        if ($feeds -notcontains 'dotnet-public' -or $feeds -contains 'hobl-fixture-ghost' -or $feeds -contains 'dotnet-tools') {
            throw "Source routing not isolated for $package`: $($feeds -join ',')"
        }
    }
    $policyAfter = Get-PolicyState $afterSettings
    if (($policyBefore | ConvertTo-Json -Depth 15 -Compress) -cne ($policyAfter | ConvertTo-Json -Depth 15 -Compress)) {
        throw 'Mapping boundary changed audit/disabled/fallback/trusted/signature policy.'
    }
    if ((Get-Content -LiteralPath $SourceConfig -Raw) -cne $original -or
        (Get-Content (Join-Path $child 'NuGet.config') -Raw) -cne $original) {
        throw 'Source NuGet.config was modified.'
    }
    Write-Host 'PASS: pinned NuGet engine resolves ghost mapping and preserves actual audit, disabled-source, fallback, trusted-author and require-signature settings; source configs unchanged. No network used.'
}
finally {
    Assert-HoblPath $fixture $repoRoot -Recurse
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
