<#
.SYNOPSIS
    Rigwright Claude Code LAN bridge - lets Rigwright on other PCs use Claude Code installed on THIS machine.

.DESCRIPTION
    Exposes a tiny token-protected HTTP API on your private network:
        GET  /v1/health   -> checks that `claude` is installed and logged in
        POST /v1/run      -> runs `claude -p` with ALL TOOLS DISABLED and returns its JSON output
    Claude cannot read files or run commands through this bridge - it can only answer.

    Works with Windows PowerShell 5.1 and PowerShell 7 on Windows, macOS and Linux.
    Copyright (c) 2026 Joseph C McGinty Jr. & ResilientMind AI LLC. MIT License.

.EXAMPLE
    .\claude-bridge.ps1                         # port 8765, token generated and saved on first run
    .\claude-bridge.ps1 -Port 9000 -AllowFrom 192.168.1.20,192.168.1.21
    .\claude-bridge.ps1 -ShowToken
    .\claude-bridge.ps1 -RotateToken
#>
[CmdletBinding()]
param(
    [int]$Port = 8765,
    [string[]]$AllowFrom = @(),
    [string]$Claude = 'claude',
    [int]$TimeoutSec = 300,
    [switch]$ShowToken,
    [switch]$RotateToken
)

$ErrorActionPreference = 'Stop'
$onWindows = ($PSVersionTable.PSVersion.Major -le 5) -or $IsWindows
$home2 = if ($onWindows) { $env:USERPROFILE } else { $env:HOME }
$cfgDir = Join-Path $home2 '.rigwright-bridge'
if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null }
$tokenFile = Join-Path $cfgDir 'token'

function New-Token {
    $b = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    ([Convert]::ToBase64String($b)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}
if ($RotateToken -or -not (Test-Path $tokenFile)) {
    Set-Content -Path $tokenFile -Value (New-Token) -NoNewline -Encoding ASCII
    if (-not $onWindows) { & chmod 600 $tokenFile 2>$null }
}
$token = (Get-Content -Raw $tokenFile).Trim()
if ($ShowToken) { $token; return }

function Resolve-Claude {
    if (Test-Path $Claude) { return (Resolve-Path $Claude).Path }
    $c = Get-Command $Claude -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $candidates = @()
    if ($onWindows) { $candidates = @("$env:USERPROFILE\.local\bin\claude.exe", "$env:APPDATA\npm\claude.cmd") }
    else { $candidates = @("$env:HOME/.local/bin/claude", "$env:HOME/.claude/local/claude", '/usr/local/bin/claude', '/opt/homebrew/bin/claude') }
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    throw 'Claude Code (claude) was not found. Install it from https://claude.com/claude-code and sign in once by running: claude'
}
$claudeExe = Resolve-Claude

function Get-LanAddresses {
    try {
        [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
            Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' } |
            ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
            Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and -not $_.Address.ToString().StartsWith('169.254.') } |
            ForEach-Object { $_.Address.ToString() }
    } catch { @() }
}

function Invoke-Claude {
    param([string]$System, [string]$Prompt, [string]$Model, $Schema)
    $work = Join-Path ([IO.Path]::GetTempPath()) 'rigwright-bridge'
    if (-not (Test-Path $work)) { New-Item -ItemType Directory -Force $work | Out-Null }
    $sysFile = Join-Path $work ("sys-{0}.txt" -f [guid]::NewGuid())
    [IO.File]::WriteAllText($sysFile, [string]$System, (New-Object Text.UTF8Encoding($false)))
    $a = "-p --output-format json --tools `"`" --system-prompt-file `"$sysFile`""
    if ($Schema) { $a += ' --json-schema "' + (ConvertTo-Json -InputObject $Schema -Depth 20 -Compress).Replace('"', '\"') + '"' }
    if ($Model -and $Model -match '^[\w\.\-\[\]]+$') { $a += " --model $Model" }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($claudeExe -like '*.cmd') { $psi.FileName = "$env:SystemRoot\System32\cmd.exe"; $psi.Arguments = "/d /c `"`"$claudeExe`" $a`"" }
    else { $psi.FileName = $claudeExe; $psi.Arguments = $a }
    $psi.WorkingDirectory = $work
    $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::Start($psi)
    $w = New-Object IO.StreamWriter($p.StandardInput.BaseStream, (New-Object Text.UTF8Encoding($false)))
    $w.Write([string]$Prompt); $w.Close()
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch { }; Remove-Item $sysFile -Force -ErrorAction SilentlyContinue; throw "timed out after $TimeoutSec s" }
    Remove-Item $sysFile -Force -ErrorAction SilentlyContinue
    if (-not $o.Result.Trim()) { throw "claude returned no output (exit $($p.ExitCode)): $($e.Result)" }
    return $o.Result
}

function Send-Json {
    param($Ctx, $Obj, [int]$Status = 200, [string]$Raw)
    $text = $Raw; if (-not $text) { $text = ConvertTo-Json -InputObject $Obj -Depth 20 -Compress }
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $Ctx.Response.StatusCode = $Status
    $Ctx.Response.ContentType = 'application/json; charset=utf-8'
    $Ctx.Response.ContentLength64 = $bytes.Length
    try { $Ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length) } catch { }
    try { $Ctx.Response.OutputStream.Close() } catch { }
}

# ------------------------------------------------------------------ listen
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:$Port/")
try { $listener.Start() }
catch {
    if ($onWindows) {
        Write-Host "Could not listen on port $Port. Run this once in an ADMINISTRATOR PowerShell to allow it:" -ForegroundColor Yellow
        Write-Host "  netsh http add urlacl url=http://+:$Port/ user=`"$env:USERDOMAIN\$env:USERNAME`""
        Write-Host "  New-NetFirewallRule -DisplayName 'Rigwright Claude bridge' -Direction Inbound -Protocol TCP -LocalPort $Port -Profile Private -Action Allow"
        Write-Host 'Then run this script again as your normal user.'
    } else { Write-Host "Could not listen on port $Port : $($_.Exception.Message)" -ForegroundColor Red }
    exit 1
}

$ips = @(Get-LanAddresses)
Write-Host ''
Write-Host '  Rigwright Claude Code bridge' -ForegroundColor Cyan
Write-Host "  claude: $claudeExe"
foreach ($ip in $ips) { Write-Host "  URL   : http://${ip}:$Port" -ForegroundColor Green }
Write-Host "  Token : $token" -ForegroundColor Green
Write-Host '  Paste the URL and token into Rigwright > Settings > Claude Code on another PC.'
if ($AllowFrom.Count) { Write-Host "  Only accepting: $($AllowFrom -join ', ')" }
Write-Host '  Press Ctrl+C to stop.'
Write-Host ''

$fails = @{}
try {
    while ($listener.IsListening) {
        $task = $listener.GetContextAsync()
        while (-not $task.Wait(500)) { }
        $ctx = $task.Result
        $remote = $ctx.Request.RemoteEndPoint.Address.ToString()
        $path = $ctx.Request.Url.AbsolutePath
        try {
            if ($AllowFrom.Count -and $AllowFrom -notcontains $remote -and $remote -notin '127.0.0.1', '::1') { Send-Json $ctx @{ error = 'forbidden' } 403; continue }
            if ($fails[$remote] -ge 10) { Send-Json $ctx @{ error = 'too many failed attempts - restart the bridge' } 429; continue }
            $auth = [string]$ctx.Request.Headers['Authorization']
            if ($auth -ne "Bearer $token") {
                $fails[$remote] = 1 + [int]$fails[$remote]
                Write-Host "$(Get-Date -Format T) $remote rejected (bad token)" -ForegroundColor Yellow
                Start-Sleep -Milliseconds 500
                Send-Json $ctx @{ error = 'unauthorized' } 401; continue
            }
            $fails.Remove($remote)
            if ($path -eq '/v1/health') {
                $ver = ''
                try { $ver = (& $claudeExe --version 2>$null | Out-String).Trim() } catch { }
                Send-Json $ctx @{ ok = [bool]$ver; version = $ver; host = [Environment]::MachineName }
            } elseif ($path -eq '/v1/run' -and $ctx.Request.HttpMethod -eq 'POST') {
                $sr = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
                $body = $sr.ReadToEnd() | ConvertFrom-Json
                Write-Host "$(Get-Date -Format T) $remote run ($([string]$body.prompt).Length chars)"
                $schema = $null; if ($body.json -and $body.schema) { $schema = $body.schema }
                $out = Invoke-Claude -System $body.system -Prompt $body.prompt -Model $body.model -Schema $schema
                Send-Json $ctx $null 200 $out
            } else { Send-Json $ctx @{ error = 'not found' } 404 }
        } catch {
            Write-Host "$(Get-Date -Format T) error: $($_.Exception.Message)" -ForegroundColor Red
            Send-Json $ctx @{ type = 'result'; is_error = $true; result = $_.Exception.Message } 500
        }
    }
} finally { $listener.Stop(); $listener.Close() }
