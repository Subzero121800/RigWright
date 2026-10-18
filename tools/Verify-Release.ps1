<#
.SYNOPSIS
    Verifies every file of an extracted Rigwright release against SHA256SUMS.txt.
    Run this before launching a copy you downloaded.
.EXAMPLE
    .\tools\Verify-Release.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sums = Join-Path $root 'SHA256SUMS.txt'
if (-not (Test-Path $sums)) { Write-Host 'SHA256SUMS.txt not found - this is not a packaged release.' -ForegroundColor Yellow; exit 2 }
$bad = 0; $n = 0
foreach ($line in Get-Content $sums) {
    if ($line -notmatch '^([0-9a-f]{64})\s+(.+)$') { continue }
    $want = $Matches[1]; $rel = $Matches[2]; $n++
    $p = Join-Path $root ($rel -replace '/', '\')
    if (-not (Test-Path $p)) { Write-Host "MISSING   $rel" -ForegroundColor Red; $bad++; continue }
    $got = (Get-FileHash $p -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $want) { Write-Host "MODIFIED  $rel" -ForegroundColor Red; $bad++ }
}
if ($bad) { Write-Host "$bad of $n files do not match. Do not run this copy." -ForegroundColor Red; exit 1 }
Write-Host "All $n files match SHA256SUMS.txt." -ForegroundColor Green

# Authenticode: a signed release must have only Valid signatures; an unsigned one is reported, not failed.
$signable = @(Get-ChildItem $root -Recurse -File -Include *.exe, *.ps1, *.psm1)
$sig = $signable | ForEach-Object { Get-AuthenticodeSignature $_.FullName }
$valid = @($sig | Where-Object Status -eq 'Valid')
$broken = @($sig | Where-Object { $_.Status -notin 'Valid', 'NotSigned' })
if ($broken.Count) {
    foreach ($s in $broken) { Write-Host "BAD SIGNATURE ($($s.Status))  $($s.Path)" -ForegroundColor Red }
    Write-Host 'Some signatures are invalid. Do not run this copy.' -ForegroundColor Red; exit 1
}
if ($valid.Count -eq $signable.Count -and $valid.Count) {
    $pub = ($valid | Select-Object -First 1).SignerCertificate.Subject
    Write-Host "All $($valid.Count) executables and scripts are signed by: $pub" -ForegroundColor Green
} elseif ($valid.Count) {
    Write-Host "$($valid.Count) of $($signable.Count) executables/scripts are signed; the rest are unsigned." -ForegroundColor Yellow
} else {
    Write-Host 'This release is not code-signed. The checksums above are your integrity check.' -ForegroundColor Yellow
}
