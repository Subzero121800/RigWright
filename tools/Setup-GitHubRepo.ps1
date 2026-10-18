<#
.SYNOPSIS
    One-time GitHub setup for the Rigwright repository before (or right after) it goes public:
    labels, "good first issue" issues, branch protection on main, secret scanning + push protection,
    and private vulnerability reporting.

.DESCRIPTION
    Needs the GitHub CLI signed in as the repository owner:
        winget install GitHub.cli
        gh auth login
    Safe to re-run: existing labels and issues with the same title are skipped.
    Secret scanning and push protection are free on public repositories.

    Copyright (c) 2026 Joseph C McGinty Jr. & ResilientMind AI LLC. MIT License.
.EXAMPLE
    .\tools\Setup-GitHubRepo.ps1 -Repo Subzero121800/RigWright
#>
param([string]$Repo = 'Subzero121800/RigWright', [switch]$SkipIssues)
$ErrorActionPreference = 'Stop'
$gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
if (-not $gh) { $gh = "$env:ProgramFiles\GitHub CLI\gh.exe" }
if (-not (Test-Path $gh)) { throw 'GitHub CLI not found. Run: winget install GitHub.cli   then: gh auth login' }
& $gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE) { throw 'Not signed in. Run: gh auth login' }

Write-Host "Configuring $Repo" -ForegroundColor Cyan

# ---------------------------------------------------------------- repository About sidebar
& $gh repo edit $Repo --description 'Set up, tune and repair Windows 10/11 with exact undo, a policy cleaner and an optional AI assistant (Ollama local or Claude Code). Portable, installs nothing.' --homepage 'https://www.linkedin.com/in/joseph-mcginty-jr/' --add-topic windows --add-topic windows-11 --add-topic powershell --add-topic debloat --add-topic privacy --add-topic winget --add-topic ollama --add-topic claude-code --add-topic portable | Out-Null
Write-Host '  About: description, website (LinkedIn) and topics set'

# ---------------------------------------------------------------- labels
$labels = @(
    @('good first issue', '7057ff', 'Small, well-defined - a great first contribution'),
    @('catalog', '0e8a16', 'Apps, tweaks, fixes, features or debloat entries (JSON only)'),
    @('tweak request', '1d76db', 'A new tweak for the catalog'),
    @('app request', '5319e7', 'A new app for the Install page'),
    @('debloat', 'fbca04', 'Debloat list entries and safety ratings'),
    @('ai', 'c5def5', 'AI assistant, providers and guard rails'),
    @('security', 'b60205', 'Security-relevant change (see SECURITY.md)'),
    @('engine', 'd93f0b', 'Engine/server changes - maintainer review required')
)
$existing = @(& $gh label list --repo $Repo --limit 200 --json name | ConvertFrom-Json | ForEach-Object { $_.name })
foreach ($l in $labels) {
    if ($existing -contains $l[0]) { & $gh label edit $l[0] --repo $Repo --color $l[1] --description $l[2] | Out-Null }
    else { & $gh label create $l[0] --repo $Repo --color $l[1] --description $l[2] | Out-Null }
    Write-Host "  label: $($l[0])"
}

# ---------------------------------------------------------------- good first issues (catalog additions)
if (-not $SkipIssues) {
    $issues = @(
        @('Tweak: disable "Show recommended websites" in Start (Windows 11 24H2+)', 'tweak request'),
        @('Tweak: turn off "Delivery Optimization" upload in the background throttle settings', 'tweak request'),
        @('Tweak: disable Windows Spotlight on the desktop background', 'tweak request'),
        @('Tweak: hide "Learn about this picture" desktop icon', 'tweak request'),
        @('Tweak: disable automatic Microsoft account sign-in prompts (MSA SSO nags)', 'tweak request'),
        @('Tweak: disable the Connected Devices Platform service (CDPUserSvc) - with side effects documented', 'tweak request'),
        @('Tweak: enable "Turn on Storage Sense" cleanup schedule (weekly)', 'tweak request'),
        @('Tweak: disable "Get even more out of Windows" post-update screen (ScoobeSystemSettingEnabled already partly covered)', 'tweak request'),
        @('App: add Thunderbird alternatives - eM Client, Betterbird (verify winget ids)', 'app request'),
        @('App: add Scoop / Chocolatey GUI entries to Utilities', 'app request'),
        @('App: add HandBrake alternatives - Shutter Encoder, Avidemux (verify winget ids)', 'app request'),
        @('App: add RustDesk back once it is available in winget again', 'app request'),
        @('Debloat: review OEM entries for MSI and Acer preinstalled apps', 'debloat'),
        @('Fix: add "Reset Microsoft Edge WebView2 runtime" repair', 'catalog')
    )
    $have = @(& $gh issue list --repo $Repo --state all --limit 500 --json title | ConvertFrom-Json | ForEach-Object { $_.title })
    $body = @'
Catalog-only change - no engine code needed.

1. Read [docs/TWEAK-SCHEMA.md](../blob/main/docs/TWEAK-SCHEMA.md) and [CONTRIBUTING.md](../blob/main/CONTRIBUTING.md).
2. Add the entry to the right file in `catalog/` with an honest `risk`, `sideEffects`, `minBuild` and a `source` link.
3. Run `.\tests\Test-Catalog.ps1` (add `-Winget` for apps).
4. For tweaks: apply, confirm state = applied, undo, confirm state = not applied, in a VM or Windows Sandbox.
'@
    foreach ($i in $issues) {
        if ($have -contains $i[0]) { Write-Host "  issue exists: $($i[0])"; continue }
        & $gh issue create --repo $Repo --title $i[0] --body $body --label 'good first issue' --label 'catalog' --label $i[1] | Out-Null
        Write-Host "  issue: $($i[0])"
    }
}

# ---------------------------------------------------------------- branch protection on main
$protection = @{
    required_status_checks        = @{ strict = $true; contexts = @('test') }
    enforce_admins                = $false
    required_pull_request_reviews = @{ required_approving_review_count = 0; dismiss_stale_reviews = $true }
    restrictions                  = $null
    allow_force_pushes            = $false
    allow_deletions               = $false
    required_linear_history       = $true
} | ConvertTo-Json -Depth 5 -Compress
$tmp = New-TemporaryFile; Set-Content $tmp $protection -Encoding ASCII
& $gh api -X PUT "repos/$Repo/branches/main/protection" --input $tmp.FullName -H 'Accept: application/vnd.github+json' | Out-Null
if ($LASTEXITCODE) { Write-Host '  branch protection: failed (private repos need GitHub Pro; free on public repos)' -ForegroundColor Yellow } else { Write-Host '  branch protection on main: CI required, no force-push, no deletion' }
Remove-Item $tmp -Force

# ---------------------------------------------------------------- secret scanning, push protection, vulnerability reporting
$sec = '{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}'
$tmp = New-TemporaryFile; Set-Content $tmp $sec -Encoding ASCII
& $gh api -X PATCH "repos/$Repo" --input $tmp.FullName | Out-Null
if ($LASTEXITCODE) { Write-Host '  secret scanning: could not enable (free on public repos; private repos need GitHub Advanced Security)' -ForegroundColor Yellow } else { Write-Host '  secret scanning + push protection: enabled' }
Remove-Item $tmp -Force
& $gh api -X PUT "repos/$Repo/private-vulnerability-reporting" | Out-Null
if ($LASTEXITCODE) { Write-Host '  private vulnerability reporting: could not enable (enable it under Settings > Code security)' -ForegroundColor Yellow } else { Write-Host '  private vulnerability reporting: enabled' }

Write-Host 'Done.' -ForegroundColor Green
