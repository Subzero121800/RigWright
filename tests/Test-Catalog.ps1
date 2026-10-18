<#
.SYNOPSIS
    Validates the Rigwright catalog: JSON schema basics, unique ids, preset references,
    PowerShell syntax of every embedded script and (optionally) that every winget id exists.
.EXAMPLE
    .\tests\Test-Catalog.ps1             # fast structural checks
    .\tests\Test-Catalog.ps1 -Winget     # also query winget for every app id (slow, needs network)
#>
param([switch]$Winget)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$cat = Join-Path $root 'catalog'
$fail = 0
function Fail($m) { Write-Host "FAIL  $m" -ForegroundColor Red; $script:fail++ }
function Pass($m) { Write-Host "ok    $m" -ForegroundColor Green }

$data = @{}
foreach ($n in 'tweaks','apps','fixes','features','debloat','presets') {
    try { $parsed = Get-Content -Raw -Encoding UTF8 (Join-Path $cat "$n.json") | ConvertFrom-Json; $data[$n] = @($parsed | ForEach-Object { $_ }); Pass "$n.json parses ($($data[$n].Count) items)" }
    catch { Fail "$n.json: $($_.Exception.Message)" }
}

foreach ($n in 'tweaks','apps','fixes','features','presets') {
    $d = $data[$n] | Group-Object id | Where-Object Count -gt 1
    if ($d) { Fail "$n has duplicate ids: $($d.Name -join ', ')" } else { Pass "$n ids unique" }
}

$validTypes = 'DWord','QWord','String','ExpandString','Binary','MultiString'
foreach ($t in $data.tweaks) {
    foreach ($f in 'id','name','category','risk','description') { if (-not $t.$f) { Fail "tweak $($t.id) missing $f" } }
    if ($t.risk -notin 'low','medium','high') { Fail "tweak $($t.id) bad risk '$($t.risk)'" }
    if (-not ($t.registry -or $t.services -or $t.tasks -or $t.script)) { Fail "tweak $($t.id) does nothing" }
    if ($t.script -and -not $t.undoScript -and -not $t.registry) { Write-Host "warn  tweak $($t.id) has a script without undoScript" -ForegroundColor Yellow }
    foreach ($r in @($t.registry)) { if ($r -and -not $r.delete -and $r.type -notin $validTypes) { Fail "tweak $($t.id) registry $($r.name) bad type $($r.type)" } }
    foreach ($k in 'script','undoScript','detect') {
        if ($t.$k) { $e = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($t.$k, [ref]$null, [ref]$e); if ($e) { Fail "tweak $($t.id) $k syntax: $($e[0].Message)" } }
    }
}
Pass 'tweak structure checked'

foreach ($f in $data.fixes) {
    $e = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($f.script, [ref]$null, [ref]$e)
    if ($e) { Fail "fix $($f.id) syntax: $($e[0].Message)" }
}
Pass 'fix scripts parse'

$ids = $data.tweaks | ForEach-Object id
foreach ($p in $data.presets) { foreach ($i in $p.tweaks) { if ($ids -notcontains $i) { Fail "preset $($p.id) -> unknown tweak $i" } } }
Pass 'preset references checked'

foreach ($m in Get-ChildItem (Join-Path $root 'core') -Filter *.psm1) {
    $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($m.FullName, [ref]$null, [ref]$e)
    if ($e) { Fail "$($m.Name): $($e[0].Message) (line $($e[0].Extent.StartLineNumber))" } else { Pass "$($m.Name) parses" }
    $bad = Select-String -Path $m.FullName -Pattern '[^\x00-\x7F]' | Select-Object -First 1
    if ($bad) { Fail "$($m.Name) has non-ASCII characters (line $($bad.LineNumber)) - Windows PowerShell 5.1 may misread them" }
}

if ($Winget) {
    $wg = (Get-Command winget -ErrorAction SilentlyContinue).Source
    if (-not $wg) { Fail 'winget not found' } else {
        foreach ($a in $data.apps) {
            $src = ''; if ($a.winget -match '^[0-9A-Z]{12}$') { $src = '--source msstore' }
            $out = & $wg show --id $a.winget --exact $src --accept-source-agreements --disable-interactivity 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0 -or $out -match 'No package found') { Fail "winget id not found: $($a.winget) ($($a.name))" } else { Pass "winget $($a.winget)" }
        }
    }
}

Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed" -ForegroundColor Red; exit 1 } else { Write-Host 'All checks passed' -ForegroundColor Green; exit 0 }
