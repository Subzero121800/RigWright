<#
.SYNOPSIS
    Builds a Rigwright release: runs the tests, publishes the desktop app, assembles
    dist\Rigwright-<version>\, zips it and writes SHA256SUMS.txt.

.PARAMETER SelfContained
    Bundle the .NET runtime into Rigwright.exe (bigger, but runs on PCs without .NET 9 Desktop Runtime).
.PARAMETER SkipDesktop
    Build only the PowerShell edition (no .exe).
.PARAMETER CertThumbprint
    Authenticode-sign Rigwright.exe and every .ps1/.psm1 with this code-signing certificate from
    Cert:\CurrentUser\My or Cert:\LocalMachine\My (e.g. a SignPath / Azure Trusted Signing / OV/EV cert).
    Can also be set with the RIGWRIGHT_SIGN_THUMBPRINT environment variable. Unsigned builds still get SHA256SUMS.
.PARAMETER AzureSigningMetadata
    Sign with Azure Artifact Signing (formerly Trusted Signing) instead of a local certificate: path to the
    metadata.json (Endpoint, CodeSigningAccountName, CertificateProfileName). Requires signtool (Windows SDK) and
    the Microsoft.ArtifactSigning.Client / Azure.CodeSigning.Dlib package; pass its DLL with -AzureSigningDlib.
    Sign in first with `az login` (or set the AZURE_* environment variables).
.PARAMETER TimestampServer
    RFC 3161 timestamp server so signatures stay valid after the certificate expires.

    Copyright (c) 2026 Joseph C McGinty Jr. & ResilientMind AI LLC. MIT License.
#>
param([switch]$FrameworkDependent, [switch]$SelfContained, [string[]]$Arch = @('win-x64', 'win-arm64'), [switch]$SkipDesktop, [switch]$SkipTests,
      [string]$CertThumbprint = $env:RIGWRIGHT_SIGN_THUMBPRINT, [string]$TimestampServer = 'http://timestamp.digicert.com',
      [string]$AzureSigningMetadata = $env:RIGWRIGHT_AZURE_SIGNING_METADATA, [string]$AzureSigningDlib = $env:RIGWRIGHT_AZURE_SIGNING_DLIB)
# -SelfContained is accepted for compatibility; self-contained is now the default.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'core\Engine.psm1') -Force -DisableNameChecking
$ver = (Get-RwInfo).version
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null

if (-not $SkipTests) {
    & (Join-Path $root 'tests\Test-Catalog.ps1'); if ($LASTEXITCODE) { throw 'Catalog tests failed' }
    & (Join-Path $root 'tests\Test-Server.ps1');  if ($LASTEXITCODE) { throw 'Server tests failed' }
    & (Join-Path $root 'tests\Test-CommandSafety.ps1'); if ($LASTEXITCODE) { throw 'Command-safety tests failed' }
}

function Invoke-RwSign {
    # Authenticode-sign every exe and script in $Dir. Returns $true when signed.
    param([string]$Dir)
    $targets = @(Get-ChildItem $Dir -Recurse -File -Include *.ps1, *.psm1, *.exe)
    $signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
    if ($AzureSigningMetadata) {
        if (-not $signtool) { throw 'signtool.exe not found - install the Windows SDK (winget install Microsoft.WindowsSDK.10.0.26100)' }
        if (-not (Test-Path $AzureSigningDlib)) { throw "Azure signing dlib not found: $AzureSigningDlib" }
        Write-Host "Signing $($targets.Count) files with Azure Artifact Signing" -ForegroundColor Cyan
        foreach ($t in $targets) {
            & $signtool.FullName sign /fd SHA256 /tr 'http://timestamp.acs.microsoft.com' /td SHA256 /d Rigwright /dlib $AzureSigningDlib /dmdf $AzureSigningMetadata $t.FullName | Out-Null
            if ($LASTEXITCODE) { throw "Azure signing failed on $($t.Name)" }
        }
        return $true
    }
    if ($CertThumbprint) {
        $cert = Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -CodeSigningCert -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $CertThumbprint.Replace(' ', '').ToUpper() } | Select-Object -First 1
        if (-not $cert) { throw "Code-signing certificate $CertThumbprint not found in the CurrentUser or LocalMachine store" }
        Write-Host "Signing $($targets.Count) files with $($cert.Subject)" -ForegroundColor Cyan
        foreach ($t in $targets) {
            if ($t.Extension -eq '.exe' -and $signtool) {
                & $signtool.FullName sign /sha1 $cert.Thumbprint /fd SHA256 /tr $TimestampServer /td SHA256 /d Rigwright $t.FullName | Out-Null
                if ($LASTEXITCODE) { throw "signtool failed on $($t.Name)" }
            } else {
                $r = Set-AuthenticodeSignature -FilePath $t.FullName -Certificate $cert -HashAlgorithm SHA256 -TimestampServer $TimestampServer
                if ($r.Status -ne 'Valid') { throw "Signing $($t.Name) failed: $($r.StatusMessage)" }
            }
        }
        return $true
    }
    return $false
}

$zipSums = @()
foreach ($rid in $Arch) {
    # Layout inside the zip: Rigwright\Rigwright.exe + core\ catalog\ web\ bridge\ tools\ ... + SHA256SUMS.txt
    # Scripts ship as plain files beside the exe: nothing is embedded and extracted to %TEMP% at runtime.
    $stage = Join-Path $dist "stage-$rid"
    $out = Join-Path $stage 'Rigwright'
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Force $out | Out-Null
    foreach ($item in 'core','catalog','web','bridge','docs','tests','tools','Rigwright.ps1','Start-Rigwright.cmd','README.md','LICENSE','CHANGELOG.md','SECURITY.md','CONTRIBUTING.md','CODE_OF_CONDUCT.md') {
        $src = Join-Path $root $item
        if (Test-Path $src) { Copy-Item $src -Destination $out -Recurse -Force }
    }
    Remove-Item (Join-Path $out 'tests\last-*.txt'), (Join-Path $out 'docs\screenshots') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $out 'tools\*.py') -Force -ErrorAction SilentlyContinue

    if (-not $SkipDesktop) {
        $sc = 'true'; if ($FrameworkDependent) { $sc = 'false' }
        $pub = Join-Path $root "desktop\bin\publish\$rid"
        & dotnet publish (Join-Path $root 'desktop\Rigwright.Desktop.csproj') -c Release -r $rid --self-contained $sc `
            -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=$sc -o $pub
        if ($LASTEXITCODE) { throw "dotnet publish failed for $rid" }
        Copy-Item (Join-Path $pub 'Rigwright.exe') $out -Force
    }

    # Signing happens before checksums so SHA256SUMS covers the signed files.
    if (Invoke-RwSign $out) { Set-Content (Join-Path $out 'SIGNED') "Authenticode-signed release $ver ($rid). Launchers use the RemoteSigned execution policy." -Encoding ASCII }
    else { Write-Host "$rid is not code-signed (no -CertThumbprint or -AzureSigningMetadata). SmartScreen will show 'unknown publisher'." -ForegroundColor Yellow }

    $lines = Get-ChildItem $out -Recurse -File | Sort-Object FullName | ForEach-Object {
        '{0}  {1}' -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.FullName.Substring($out.Length + 1).Replace('\', '/')
    }
    $lines | Set-Content (Join-Path $out 'SHA256SUMS.txt') -Encoding ASCII

    # Stable asset names so https://github.com/<owner>/<repo>/releases/latest/download/Rigwright-win-x64.zip always works
    $zip = Join-Path $dist "Rigwright-$rid.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path $out -DestinationPath $zip
    $zipSums += '{0}  {1}' -f (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower(), (Split-Path $zip -Leaf)
    Remove-Item $stage -Recurse -Force
    Write-Host "Built $zip" -ForegroundColor Green
}
$zipSums | Set-Content (Join-Path $dist "Rigwright-$ver-SHA256SUMS.txt") -Encoding ASCII

Write-Host ''
Write-Host "Release $ver ready in $dist" -ForegroundColor Green
$zipSums