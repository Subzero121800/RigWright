<#
.SYNOPSIS
    Runs Rigwright's engine from awkward locations: a path with spaces, a non-ASCII path, another drive
    (e.g. USB), a OneDrive-synced folder, and a read-only folder (portable mode must refuse cleanly).
    Requires an elevated PowerShell (the engine runs elevated). Makes no system changes; temp copies are removed.
#>
$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $PSScriptRoot
$fail = 0
function Pass($m) { Write-Host "ok    $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL  $m" -ForegroundColor Red; $script:fail++ }

$isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host 'Run this test from an elevated PowerShell.' -ForegroundColor Yellow; exit 2 }

function Copy-Rw([string]$Dest) {
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    foreach ($i in 'core', 'catalog', 'web', 'Rigwright.ps1', 'Start-Rigwright.cmd') { Copy-Item -LiteralPath (Join-Path $src $i) -Destination $Dest -Recurse -Force }
}

function Test-Start([string]$Dir, [switch]$Portable, [string]$Label) {
    $ready = Join-Path $env:TEMP ("rw-path-{0}.json" -f [guid]::NewGuid())
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Dir 'Rigwright.ps1')`"", '-Server', '-ReadyFile', "`"$ready`"", '-WatchPid', $PID)
    if ($Portable) { $args += '-Portable' }
    $p = Start-Process "$PSHOME\powershell.exe" -ArgumentList $args -PassThru -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds(40)
    while (-not (Test-Path $ready) -and -not $p.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
    if (-not (Test-Path $ready)) { if (-not $p.HasExited) { $p.Kill() }; Fail "$Label - engine did not start (exit $($p.ExitCode))"; return }
    Start-Sleep -Milliseconds 200
    $info = Get-Content -Raw $ready | ConvertFrom-Json
    try {
        $tok = (Invoke-RestMethod "$($info.url)api/session" -Method Post -Body (@{ code = $info.code } | ConvertTo-Json) -ContentType 'application/json').token
        $i = Invoke-RestMethod "$($info.url)api/info" -Headers @{ 'X-Rigwright-Token' = $tok }
        $expect = $(if ($Portable) { Join-Path $Dir 'data' } else { Join-Path $env:ProgramData 'Rigwright' })
        if ([IO.Path]::GetFullPath($i.app.dataDir).TrimEnd('\') -ne [IO.Path]::GetFullPath($expect).TrimEnd('\')) { Fail "$Label - data dir $($i.app.dataDir), expected $expect" }
        elseif ($Portable -and -not (Test-Path -LiteralPath (Join-Path $Dir 'data\settings.json') -PathType Leaf) -and -not (Test-Path -LiteralPath (Join-Path $Dir 'data'))) { Fail "$Label - portable data folder missing" }
        else { Pass "$Label (data: $($i.app.dataDir))" }
        Invoke-RestMethod "$($info.url)api/shutdown" -Method Post -Headers @{ 'X-Rigwright-Token' = $tok } | Out-Null
    } catch { Fail "$Label - $($_.Exception.Message)" }
    finally { Start-Sleep 1; if (-not $p.HasExited) { $p.Kill() }; Remove-Item $ready -Force -ErrorAction SilentlyContinue }
}

$base = Join-Path $env:TEMP ("rw paths " + [guid]::NewGuid().ToString('N').Substring(0, 6))
$cases = [ordered]@{
    'path with spaces'  = Join-Path $base 'Program Files Style\My Rigwright'
    'non-ASCII path'    = Join-Path $base ("Rigwr{0}ght T{1}st {2}" -f [char]0x00EF, [char]0x00E9, [char]0x6E2C)
}
$other = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -ne "$env:SystemDrive\" -and $_.Free -gt 1GB } | Select-Object -First 1
if ($other) { $cases['other drive (USB-style)'] = Join-Path $other.Root ("RigwrightPathTest-" + [guid]::NewGuid().ToString('N').Substring(0, 6)) }
if ($env:OneDrive -and (Test-Path $env:OneDrive)) { $cases['OneDrive-synced folder'] = Join-Path $env:OneDrive ("RigwrightPathTest-" + [guid]::NewGuid().ToString('N').Substring(0, 6)) }

try {
    foreach ($k in $cases.Keys) {
        Copy-Rw $cases[$k]
        Test-Start $cases[$k] -Label "$k, normal mode"
        Test-Start $cases[$k] -Portable -Label "$k, portable mode"
    }

    # Read-only location (nothing new can be created there, like a write-protected stick or a locked share):
    # portable mode must refuse with exit code 2 and a clear message, not crash.
    $ro = Join-Path $base 'read only'
    Copy-Rw $ro
    & "$env:SystemRoot\System32\icacls.exe" $ro /deny '*S-1-1-0:(W,AD)' | Out-Null
    $p = Start-Process "$PSHOME\powershell.exe" -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $ro 'Rigwright.ps1')`"", '-Portable', '-Version') -PassThru -WindowStyle Hidden -Wait
    if ($p.ExitCode -eq 2) { Pass 'read-only folder: -Portable refused with exit code 2' } else { Fail "read-only folder: expected exit 2, got $($p.ExitCode)" }
    & "$env:SystemRoot\System32\icacls.exe" $ro /remove:d '*S-1-1-0' | Out-Null
} finally {
    foreach ($d in @($base) + @($cases.Values)) { if ($d -and (Test-Path -LiteralPath $d)) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } }
}

Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed" -ForegroundColor Red; exit 1 } else { Write-Host 'All path checks passed' -ForegroundColor Green }
