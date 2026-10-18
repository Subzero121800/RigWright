<#
.SYNOPSIS
    End-to-end smoke test: starts the Rigwright server in a child process, exercises the API
    (auth, static files, catalog, read-only jobs), then stops it. Makes NO system changes.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$ready = Join-Path $env:TEMP ("rw-test-{0}.json" -f [guid]::NewGuid())
$boot = "Import-Module '$root\core\Engine.psm1','$root\core\AI.psm1','$root\core\Server.psm1' -DisableNameChecking; Start-RwServer -ReadyFile '$ready' -WatchPid $PID"
$p = Start-Process "$PSHOME\powershell.exe" -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $boot) -PassThru -WindowStyle Hidden
$fail = 0
function Check($name, [scriptblock]$test) {
    try { $r = & $test; if ($r -eq $false) { throw 'returned false' }; Write-Host "ok    $name" -ForegroundColor Green }
    catch { Write-Host "FAIL  $name - $($_.Exception.Message)" -ForegroundColor Red; $script:fail++ }
}
try {
    $deadline = (Get-Date).AddSeconds(30)
    while (-not (Test-Path $ready)) { if ((Get-Date) -gt $deadline -or $p.HasExited) { throw 'server did not start' }; Start-Sleep -Milliseconds 200 }
    Start-Sleep -Milliseconds 200
    $info = Get-Content -Raw $ready | ConvertFrom-Json
    $base = $info.url.TrimEnd('/')

    Check 'static index.html served with CSP' { $r = Invoke-WebRequest "$base/" -UseBasicParsing; ($r.Content -match 'Rigwright') -and $r.Headers['Content-Security-Policy'] }
    Check 'path traversal blocked' { try { Invoke-WebRequest "$base/..%2F..%2Fcore%2FEngine.psm1" -UseBasicParsing | Out-Null; $false } catch { $true } }
    Check 'API rejects missing token' { try { Invoke-RestMethod "$base/api/info" | Out-Null; $false } catch { $_.Exception.Response.StatusCode.value__ -eq 401 } }
    Check 'bad launch code rejected' { try { Invoke-RestMethod "$base/api/session" -Method Post -Body '{"code":"nope"}' -ContentType 'application/json' | Out-Null; $false } catch { $true } }
    $tok = (Invoke-RestMethod "$base/api/session" -Method Post -Body (@{ code = $info.code } | ConvertTo-Json) -ContentType 'application/json').token
    Check 'launch code exchanged for token' { [bool]$tok }
    Check 'launch code is single-use' { try { Invoke-RestMethod "$base/api/session" -Method Post -Body (@{ code = $info.code } | ConvertTo-Json) -ContentType 'application/json' | Out-Null; $false } catch { $true } }
    $h = @{ 'X-Rigwright-Token' = $tok }
    Check 'foreign Host header rejected' { try { Invoke-WebRequest "$base/api/info" -Headers ($h + @{ Host = 'evil.example' }) -UseBasicParsing | Out-Null; $false } catch { $true } }
    Check '/api/info' { (Invoke-RestMethod "$base/api/info" -Headers $h).app.name -eq 'Rigwright' }
    Check '/api/catalog has tweaks' { @((Invoke-RestMethod "$base/api/catalog" -Headers $h).tweaks).Count -gt 50 }
    Check '/api/settings' { (Invoke-RestMethod "$base/api/settings" -Headers $h).ai.provider }

    function RunJob($type, $jobArgs) {
        $id = (Invoke-RestMethod "$base/api/jobs" -Method Post -Headers $h -ContentType 'application/json' -Body (@{ type = $type; args = $jobArgs } | ConvertTo-Json -Depth 5)).id
        $t = (Get-Date).AddSeconds(120)
        do { Start-Sleep -Milliseconds 300; $j = Invoke-RestMethod "$base/api/jobs/$id" -Headers $h } while ($j.status -in 'queued', 'running' -and (Get-Date) -lt $t)
        if ($j.status -ne 'done') { throw "job $type ended as $($j.status): $($j.error)" }
        return $j.result
    }
    Check 'job: sysinfo' { (RunJob 'sysinfo' @{}).cpu }
    Check 'job: tweakStates' { $r = RunJob 'tweakStates' @{}; $r.'ui.darkMode'.state }
    Check 'job: plan preview' { $r = @(RunJob 'plan' @{ ids = @('ui.fileExtensions') }); $r[0].changes -match 'HideFileExt' }
    Check 'job: startup items' { $null -ne (RunJob 'startup' @{}) }
    Check 'job: claudeStatus reports install state' { $r = RunJob 'claudeStatus' @{}; $null -ne $r.installed }
    Check 'job: aiPreview marks Claude as cloud' { $r = RunJob 'aiPreview' @{ provider = 'claude-local' }; $r.cloud -eq $true -and $r.destination -match 'Anthropic' }
    Check 'job: aiPreview marks Ollama as local' { $r = RunJob 'aiPreview' @{ provider = 'ollama' }; $r.cloud -eq $false -and $r.systemPrompt -match 'CATALOG' }
    Check 'job: obfuscated command refused' { try { RunJob 'command' @{ command = '& ("Remove-" + "Item") C:\x' } | Out-Null; $false } catch { $_.Exception.Message -match 'blocked' } }
    Check 'job: blocked command refused' { try { RunJob 'command' @{ command = 'diskpart' } | Out-Null; $false } catch { $_.Exception.Message -match 'blocked' } }
    Check 'unknown job type rejected' { try { Invoke-RestMethod "$base/api/jobs" -Method Post -Headers $h -ContentType 'application/json' -Body '{"type":"rm-rf"}' | Out-Null; $false } catch { $true } }
    Check 'shutdown' { (Invoke-RestMethod "$base/api/shutdown" -Method Post -Headers $h).ok }
} finally {
    Start-Sleep 1
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $ready -Force -ErrorAction SilentlyContinue
}
Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed" -ForegroundColor Red; exit 1 } else { Write-Host 'All server checks passed' -ForegroundColor Green }
