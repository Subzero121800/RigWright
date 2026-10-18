<#
.SYNOPSIS
    Publishes a built Rigwright release to GitHub Releases: tags v<version>, uploads the x64/arm64 zips and
    the checksum file, and uses docs\RELEASE-NOTES-<version>.md as the release notes.

.DESCRIPTION
    Run tools\Build-Release.ps1 first. Needs the GitHub CLI signed in as the repository owner:
        winget install GitHub.cli ; gh auth login
    The stable asset names make this permanent link always point at the newest release:
        https://github.com/<owner>/<repo>/releases/latest/download/Rigwright-win-x64.zip
    (Anonymous downloads require the repository to be public.)

    Copyright (c) 2026 Joseph C McGinty Jr. & ResilientMind AI LLC. MIT License.
#>
param([string]$Repo = 'Subzero121800/RigWright', [switch]$Draft, [switch]$Prerelease)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'core\Engine.psm1') -Force -DisableNameChecking
$ver = (Get-RwInfo).version
$tag = "v$ver"
$gh = (Get-Command gh -ErrorAction SilentlyContinue).Source; if (-not $gh) { $gh = "$env:ProgramFiles\GitHub CLI\gh.exe" }
if (-not (Test-Path $gh)) { throw 'GitHub CLI not found: winget install GitHub.cli' }
& $gh auth status 2>&1 | Out-Null; if ($LASTEXITCODE) { throw 'Sign in first: gh auth login' }

$dist = Join-Path $root 'dist'
$assets = @('Rigwright-win-x64.zip', 'Rigwright-win-arm64.zip', "Rigwright-$ver-SHA256SUMS.txt") | ForEach-Object { Join-Path $dist $_ } | Where-Object { Test-Path $_ }
if ($assets.Count -lt 2) { throw 'Release files missing - run tools\Build-Release.ps1 first.' }
$notes = Join-Path $root "docs\RELEASE-NOTES-$ver.md"
if (-not (Test-Path $notes)) { throw "Release notes not found: $notes" }

# Verify the checksums before uploading anything
foreach ($l in Get-Content (Join-Path $dist "Rigwright-$ver-SHA256SUMS.txt")) {
    if ($l -match '^([0-9a-f]{64})\s+(\S+)$') {
        $got = (Get-FileHash (Join-Path $dist $Matches[2]) -Algorithm SHA256).Hash.ToLower()
        if ($got -ne $Matches[1]) { throw "Checksum mismatch for $($Matches[2])" }
    }
}

$exists = $false
# A missing release writes to stderr, which PowerShell 5.1 turns into a terminating error under 'Stop'
$eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& $gh release view $tag --repo $Repo *> $null; if (-not $LASTEXITCODE) { $exists = $true }
$ErrorActionPreference = $eap
if ($exists) {
    Write-Host "Release $tag exists - replacing its assets" -ForegroundColor Yellow
    & $gh release upload $tag @assets --repo $Repo --clobber
} else {
    $flags = @(); if ($Draft) { $flags += '--draft' }; if ($Prerelease) { $flags += '--prerelease' }
    & $gh release create $tag @assets --repo $Repo --title "Rigwright $ver" --notes-file $notes --target main --latest @flags
}
if ($LASTEXITCODE) { throw 'gh release failed' }
Write-Host "Published: https://github.com/$Repo/releases/tag/$tag" -ForegroundColor Green
Write-Host "Permanent download link: https://github.com/$Repo/releases/latest/download/Rigwright-win-x64.zip"
