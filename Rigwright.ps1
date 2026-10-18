<#
.SYNOPSIS
    Rigwright - AI-assisted Windows setup, tuning and repair utility.

.DESCRIPTION
    Starts the elevated Rigwright engine and opens the UI in its own app window.
    Copyright (c) 2026 Joseph C McGinty Jr. & ResilientMind AI LLC. MIT License.

.EXAMPLE
    .\Rigwright.ps1                      # normal GUI start
    .\Rigwright.ps1 -Browser             # open in the default browser instead of an app window
    .\Rigwright.ps1 -Lan                 # also allow other devices on your private network to open the UI
    .\Rigwright.ps1 -Config my.json -Run # headless: apply an exported profile (for scripts / RMM / new PCs)
    .\Rigwright.ps1 -Config my.json -DryRun
    .\Rigwright.ps1 -Portable            # keep settings, undo journal and logs in .\data beside the app
#>
[CmdletBinding()]
param(
    [switch]$Browser,
    [switch]$Lan,
    [int]$Port = 0,
    [string]$Config,
    [switch]$Run,
    [switch]$DryRun,
    [switch]$Version,
    [switch]$Portable,
    # internal
    [switch]$Server,
    [string]$ReadyFile,
    [int]$WatchPid = 0
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

# Portable mode: everything lives in .\data beside the app. Must be decided before the engine loads.
if ($Portable) {
    $pd = Join-Path $root 'data'
    try {
        New-Item -ItemType Directory -Force -Path $pd -ErrorAction Stop | Out-Null
        $probe = Join-Path $pd ('.write-test-{0}' -f [guid]::NewGuid())
        [IO.File]::WriteAllText($probe, 'ok'); Remove-Item $probe -Force
    } catch {
        Write-Host ''
        Write-Host "  Portable mode needs a writable folder, but $root is read-only." -ForegroundColor Red
        Write-Host '  Copy Rigwright to a writable location (for example a USB drive or C:\Tools), or start it without -Portable.' -ForegroundColor Yellow
        Start-Sleep 6; exit 2
    }
    $env:RIGWRIGHT_DATA_DIR = $pd
}
Import-Module (Join-Path $root 'core\Engine.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'core\AI.psm1') -Force -DisableNameChecking

if ($Version) { $i = Get-RwInfo; "$($i.name) $($i.version)  -  $($i.copyright)"; return }

$isAdmin = Test-RwAdmin

# Signed releases run under RemoteSigned; unsigned development builds need Bypass for this one process.
$execPolicy = 'Bypass'
try { if ((Get-AuthenticodeSignature -FilePath $PSCommandPath).Status -eq 'Valid') { $execPolicy = 'RemoteSigned' } } catch { }

function Start-RwElevated {
    param([string[]]$ArgList, [switch]$Hidden)
    $psArgs = @('-NoProfile', '-ExecutionPolicy', $execPolicy, '-File', "`"$PSCommandPath`"") + $ArgList
    if ($Portable) { $psArgs += '-Portable' }
    $sp = @{ FilePath = "$PSHOME\powershell.exe"; ArgumentList = $psArgs; PassThru = $true }
    if ($Hidden) { $sp['WindowStyle'] = 'Hidden' }
    if (-not $isAdmin) { $sp['Verb'] = 'RunAs' }
    Start-Process @sp
}

# ---------------------------------------------------------------- headless profile mode
if ($Config) {
    if (-not $isAdmin) {
        $a = @('-Config', "`"$Config`""); if ($Run) { $a += '-Run' }; if ($DryRun) { $a += '-DryRun' }
        $p = Start-RwElevated $a; $p.WaitForExit(); exit $p.ExitCode
    }
    Set-RwLogSink { param($l) Write-Host $l }
    $prof = Get-Content -Raw -Encoding UTF8 $Config | ConvertFrom-Json
    if (-not $Run -and -not $DryRun) { $DryRun = $true; Write-Host 'No -Run given: showing a dry run. Add -Run to apply.' -ForegroundColor Yellow }
    try { Invoke-RwProfile -Profile $prof -DryRun:$DryRun; exit 0 } catch { Write-Host $_ -ForegroundColor Red; exit 1 }
}

# ---------------------------------------------------------------- server process (elevated, usually hidden)
if ($Server) {
    if (-not $isAdmin) { throw 'The Rigwright server must run elevated.' }
    Import-Module (Join-Path $root 'core\Server.psm1') -Force -DisableNameChecking
    $s = Get-RwSettings
    $useLan = $Lan -or [bool]$s.server.lan
    $p = $Port; if ($p -le 0 -and $s.server.port) { $p = [int]$s.server.port }
    Start-RwServer -Port $p -Lan:$useLan -ReadyFile $ReadyFile -WatchPid $WatchPid
    return
}

# ---------------------------------------------------------------- launcher (normal double-click path)
$localBase = Join-Path $env:LOCALAPPDATA 'Rigwright'
if ($Portable) { $localBase = $env:RIGWRIGHT_DATA_DIR }
$runDir = Join-Path $localBase 'run'
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$ready = Join-Path $runDir ("ready-{0}.json" -f [guid]::NewGuid())

Write-Host ''
Write-Host '  Rigwright' -ForegroundColor Cyan -NoNewline
Write-Host "  $((Get-RwInfo).version)  -  (c) 2026 Joseph C McGinty Jr. & ResilientMind AI LLC" -ForegroundColor DarkGray
Write-Host '  Starting the engine (approve the administrator prompt)...' -ForegroundColor Gray

$a = @('-Server', '-ReadyFile', "`"$ready`"", '-WatchPid', $PID)
if ($Lan) { $a += '-Lan' }
if ($Port -gt 0) { $a += @('-Port', $Port) }
try { $srv = Start-RwElevated $a -Hidden }
catch {
    Write-Host ''
    Write-Host '  Rigwright needs administrator permission to change Windows settings, and the prompt was declined.' -ForegroundColor Yellow
    Write-Host '  Nothing was changed. Start Rigwright again and choose Yes when Windows asks.' -ForegroundColor Gray
    Start-Sleep 6; exit 1
}

$deadline = (Get-Date).AddSeconds(90)
while (-not (Test-Path $ready)) {
    if ((Get-Date) -gt $deadline -or $srv.HasExited) {
        Write-Host "  The engine did not start. See the log in $((Get-RwInfo).dataDir)\logs" -ForegroundColor Red
        Start-Sleep 5; exit 1
    }
    Start-Sleep -Milliseconds 250
}
Start-Sleep -Milliseconds 150
$info = Get-Content -Raw $ready | ConvertFrom-Json
Remove-Item $ready -Force -ErrorAction SilentlyContinue
$url = "$($info.url)?code=$($info.code)"

$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
$appBrowser = $edge; if (-not $appBrowser) { $appBrowser = $chrome }

Write-Host "  Engine running at $($info.url)" -ForegroundColor Green
if ($Browser -or -not $appBrowser) {
    Start-Process $url
    Write-Host '  Opened in your browser. Keep this window open; press Enter here to stop Rigwright.' -ForegroundColor Gray
    [void](Read-Host)
} else {
    # Separate profile => its own process we can wait on; window closes => engine stops.
    $profileDir = Join-Path $localBase 'browser'
    $win = Start-Process $appBrowser -PassThru -ArgumentList @("--app=$url", "--user-data-dir=`"$profileDir`"", '--window-size=1360,900', '--no-first-run', '--no-default-browser-check', '--disable-features=Translate')
    Write-Host '  Rigwright window opened. Closing it stops the engine.' -ForegroundColor Gray
    $win.WaitForExit()
    # Chromium may hand off to an already-running instance of the same profile; wait for it too.
    while (Get-CimInstance Win32_Process -Filter "Name='$(Split-Path $appBrowser -Leaf)'" | Where-Object { $_.CommandLine -like "*$profileDir*" }) { Start-Sleep 1 }
}

# The engine watches this launcher's process id and stops itself when we exit.
Write-Host '  Stopping Rigwright...' -ForegroundColor Gray
