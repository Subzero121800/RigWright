<#
.SYNOPSIS
    Generates a winget manifest (zip + portable, no installer) for a published Rigwright release,
    ready to validate and submit to microsoft/winget-pkgs.

.DESCRIPTION
    Uses the stable release asset names written by tools\Build-Release.ps1:
        Rigwright-win-x64.zip, Rigwright-win-arm64.zip, Rigwright-<version>-SHA256SUMS.txt
    Then:
        winget validate .\dist\winget\<version>
        winget install --manifest .\dist\winget\<version>      # test on a clean VM
    Submit with `wingetcreate submit` or a PR to microsoft/winget-pkgs.

    The journal stays in C:\ProgramData\Rigwright (never beside the exe), so winget upgrades and
    uninstalls never lose undo history.

    Copyright (c) 2026 Joseph C McGinty Jr. & ResilientMind AI LLC. MIT License.
#>
param(
    [string]$Version,
    [string]$Repo = 'Subzero121800/RigWright',
    [string]$PackageId = 'ResilientMindAI.Rigwright',
    [string]$Publisher = 'ResilientMind AI LLC'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $Version) { Import-Module (Join-Path $root 'core\Engine.psm1') -Force -DisableNameChecking; $Version = (Get-RwInfo).version }
$sums = Join-Path $root "dist\Rigwright-$Version-SHA256SUMS.txt"
if (-not (Test-Path $sums)) { throw "Build the release first: $sums not found" }
$hash = @{}
foreach ($l in Get-Content $sums) { if ($l -match '^([0-9a-f]{64})\s+(\S+)$') { $hash[$Matches[2]] = $Matches[1].ToUpper() } }

$out = Join-Path $root "dist\winget\$Version"
New-Item -ItemType Directory -Force $out | Out-Null
$base = "https://github.com/$Repo/releases/download/v$Version"
$schema = '1.6.0'

$installers = foreach ($a in @(@('x64', 'win-x64'), @('arm64', 'win-arm64'))) {
    $file = "Rigwright-$($a[1]).zip"
    if (-not $hash.ContainsKey($file)) { continue }
@"
- Architecture: $($a[0])
  InstallerUrl: $base/$file
  InstallerSha256: $($hash[$file])
"@
}
if (-not $installers) { throw 'No release zips found in the checksum file' }

@"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.version.$schema.schema.json
PackageIdentifier: $PackageId
PackageVersion: $Version
DefaultLocale: en-US
ManifestType: version
ManifestVersion: $schema
"@ | Set-Content (Join-Path $out "$PackageId.yaml") -Encoding UTF8

@"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.installer.$schema.schema.json
PackageIdentifier: $PackageId
PackageVersion: $Version
InstallerType: zip
NestedInstallerType: portable
NestedInstallerFiles:
- RelativeFilePath: Rigwright\Rigwright.exe
  PortableCommandAlias: rigwright
MinimumOSVersion: 10.0.19044.0
Installers:
$($installers -join "`n")
ManifestType: installer
ManifestVersion: $schema
"@ | Set-Content (Join-Path $out "$PackageId.installer.yaml") -Encoding UTF8

@"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.defaultLocale.$schema.schema.json
PackageIdentifier: $PackageId
PackageVersion: $Version
PackageLocale: en-US
Publisher: $Publisher
PublisherUrl: https://github.com/$Repo
Author: Joseph C McGinty Jr.
PackageName: Rigwright
PackageUrl: https://github.com/$Repo
License: MIT
LicenseUrl: https://github.com/$Repo/blob/main/LICENSE
Copyright: Copyright (c) 2026 Joseph C McGinty Jr. & ResilientMind AI LLC
ShortDescription: Set up, tune and repair Windows with previewable, reversible changes and an optional AI assistant.
Description: Portable Windows utility for app installs (winget), privacy and performance tweaks with exact undo, debloat, startup apps, fixes and a policy cleaner. The optional AI assistant (Ollama or Claude Code) only proposes changes; you approve each one.
Tags:
- windows
- tweaks
- debloat
- privacy
- winget
- ollama
- portable
ReleaseNotesUrl: https://github.com/$Repo/releases/tag/v$Version
ManifestType: defaultLocale
ManifestVersion: $schema
"@ | Set-Content (Join-Path $out "$PackageId.locale.en-US.yaml") -Encoding UTF8

Write-Host "Manifest written to $out" -ForegroundColor Green
Write-Host "Next: winget validate `"$out`"   then   winget install --manifest `"$out`"" -ForegroundColor Gray
