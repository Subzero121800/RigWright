# Rigwright engine: catalog loading, tweak apply/undo with automatic state capture,
# app management (winget/choco), Windows features, fixes, debloat, startup apps,
# restore points, journal and logging.
# Windows PowerShell 5.1 compatible. Keep this file ASCII-only.

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$script:AppName    = 'Rigwright'
$script:AppVersion = '1.0.0'
$script:Root       = Split-Path -Parent $PSScriptRoot
$script:MachineDataDir = Join-Path $env:ProgramData 'Rigwright'
# Portable mode (Rigwright.ps1 -Portable) points this at .\data beside the app; otherwise ProgramData,
# so the undo journal survives deleting or moving the Rigwright folder.
$script:DataDir    = $script:MachineDataDir
$script:Portable   = $false
if ($env:RIGWRIGHT_DATA_DIR) { $script:DataDir = $env:RIGWRIGHT_DATA_DIR; $script:Portable = $true }
$script:LogSink    = $null   # scriptblock set by the job runner: param($line)
$script:Catalog    = $null
# winget progress-bar glyphs (block and box-drawing characters), built from code points to keep this file ASCII
$script:BoxRegex   = '[{0}-{1}{2}-{3}]' -f [char]0x2580, [char]0x259F, [char]0x2500, [char]0x257F

foreach ($d in @($script:DataDir, (Join-Path $script:DataDir 'logs'), (Join-Path $script:DataDir 'backups'))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

# ---------------------------------------------------------------- utilities

function Get-RwInfo {
    [pscustomobject]@{
        name      = $script:AppName
        version   = $script:AppVersion
        root      = $script:Root
        dataDir   = $script:DataDir
        portable  = $script:Portable
        copyright = 'Copyright (c) 2026 Joseph C McGinty Jr. & ResilientMind AI LLC'
        license   = 'MIT'
    }
}

function Set-RwLogSink { param([scriptblock]$Sink) $script:LogSink = $Sink }

function Write-RwLog {
    param([string]$Message, [ValidateSet('info','ok','warn','error','cmd')][string]$Level = 'info')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level.ToUpper(), $Message
    try {
        $file = Join-Path $script:DataDir ('logs\rigwright-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
        Add-Content -Path $file -Value $line -Encoding UTF8
    } catch { }
    if ($script:LogSink) { try { & $script:LogSink $line } catch { } }
}

function Test-RwAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-RwJson {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $raw | ConvertFrom-Json
}

function Write-RwJson {
    param([string]$Path, $Object)
    $json = ConvertTo-Json -InputObject $Object -Depth 20
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -Path $tmp -Destination $Path -Force
}

function ConvertTo-RwHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-RwHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        return ,@($InputObject | ForEach-Object { ConvertTo-RwHashtable $_ })
    }
    return $InputObject
}

function Invoke-RwNative {
    # Runs a native command, streams its output to the log, returns exit code.
    param([string]$FilePath, [string]$Arguments, [switch]$Quiet)
    Write-RwLog "$FilePath $Arguments" 'cmd'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    try { $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8 } catch { }
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $last = ''
    while (-not $p.StandardOutput.EndOfStream) {
        $l = $p.StandardOutput.ReadLine()
        if ($null -eq $l) { continue }
        # strip winget spinner / progress noise
        $clean = ($l -replace $script:BoxRegex, '' -replace '^\s*[-\\|/]\s*$', '').TrimEnd()
        if ($clean -and $clean -ne $last -and -not $Quiet) { Write-RwLog $clean 'info'; $last = $clean }
    }
    $p.WaitForExit()
    $err = $errTask.Result
    if ($err -and -not $Quiet) { foreach ($e in ($err -split "`r?`n")) { if ($e.Trim()) { Write-RwLog $e.Trim() 'warn' } } }
    return $p.ExitCode
}

# ---------------------------------------------------------------- settings

function Get-RwDefaultSettings {
    [ordered]@{
        ai = [ordered]@{
            provider    = 'ollama'          # ollama | claude-local | claude-lan
            ollama      = [ordered]@{ endpoint = 'http://localhost:11434'; model = ''; timeoutSec = 300 }
            claudeLocal = [ordered]@{ path = 'claude'; model = ''; timeoutSec = 300 }
            claudeLan   = [ordered]@{ endpoint = 'http://192.168.1.50:8765'; token = ''; model = ''; timeoutSec = 300 }
            includeSystemInfo = $true     # local Ollama
            shareWithCloud    = $false    # Claude providers send data to Anthropic: opt-in
        }
        safety = [ordered]@{
            restorePointBeforeChanges = $true
            allowAiCustomCommands     = $false   # off for new installs; unvetted commands are opt-in
            confirmHighRisk           = $true
        }
        ui = [ordered]@{ theme = 'system'; autoExitMinutes = 0; checkUpdates = $false; portableWarned = $false }
        server = [ordered]@{ lan = $false; port = 0 }
    }
}

function Merge-RwSettings {
    param($Base, $Over)
    if ($null -eq $Over) { return $Base }
    foreach ($k in @($Over.Keys)) {
        if ($Base.Contains($k) -and $Base[$k] -is [System.Collections.IDictionary] -and $Over[$k] -is [System.Collections.IDictionary]) {
            $Base[$k] = Merge-RwSettings $Base[$k] $Over[$k]
        } else { $Base[$k] = $Over[$k] }
    }
    return $Base
}

function Get-RwSettings {
    $path = Join-Path $script:DataDir 'settings.json'
    $saved = ConvertTo-RwHashtable (Read-RwJson $path)
    return (Merge-RwSettings (Get-RwDefaultSettings) $saved)
}

function Save-RwSettings {
    param($Settings)
    $merged = Merge-RwSettings (Get-RwSettings) (ConvertTo-RwHashtable $Settings)
    # Ollama never serves https itself; fix the most common endpoint mistakes on save.
    $ep = "$($merged.ai.ollama.endpoint)".Trim().TrimEnd('/')
    if ($ep -and $ep -notmatch '^[a-z]+://') { $ep = "http://$ep" }
    if ($ep -match '^https://[^/]+:11434$') { $ep = 'http://' + $ep.Substring(8) }
    if ($ep -match '^[a-z]+://[^/:]+$') { $ep = "${ep}:11434" }
    $merged.ai.ollama.endpoint = $ep
    Write-RwJson (Join-Path $script:DataDir 'settings.json') $merged
    return $merged
}

# ---------------------------------------------------------------- catalog

function Get-RwCatalog {
    param([switch]$Reload)
    if ($script:Catalog -and -not $Reload) { return $script:Catalog }
    $dir = Join-Path $script:Root 'catalog'
    $cat = [ordered]@{}
    foreach ($name in 'apps','tweaks','features','fixes','presets','debloat') {
        $data = Read-RwJson (Join-Path $dir "$name.json")
        if ($null -eq $data) { $data = @() }
        $cat[$name] = @($data)
    }
    $script:Catalog = $cat
    return $cat
}

function Get-RwTweak {
    param([string]$Id)
    (Get-RwCatalog).tweaks | Where-Object { $_.id -eq $Id } | Select-Object -First 1
}

# ---------------------------------------------------------------- journal

function Get-RwJournal {
    $j = ConvertTo-RwHashtable (Read-RwJson (Join-Path $script:DataDir 'journal.json'))
    if ($null -eq $j) { $j = [ordered]@{} }
    if (-not $j.Contains('tweaks'))  { $j['tweaks']  = [ordered]@{} }
    if (-not $j.Contains('appx'))    { $j['appx']    = @() }
    if (-not $j.Contains('history')) { $j['history'] = @() }
    return $j
}

function Save-RwJournal { param($Journal) Write-RwJson (Join-Path $script:DataDir 'journal.json') $Journal }

function Add-RwHistory {
    param([string]$Action, $Items, [string]$Result, [string]$Detail = '')
    $j = Get-RwJournal
    $entry = [ordered]@{ time = (Get-Date).ToString('o'); action = $Action; items = @($Items); result = $Result; detail = $Detail }
    $h = @($j['history']) + @($entry)
    if ($h.Count -gt 500) { $h = $h[($h.Count - 500)..($h.Count - 1)] }
    $j['history'] = $h
    Save-RwJournal $j
}

# ---------------------------------------------------------------- registry primitives

function ConvertTo-RwRegPath {
    param([string]$Path)
    $p = $Path -replace '^HKEY_LOCAL_MACHINE', 'HKLM:' -replace '^HKEY_CURRENT_USER', 'HKCU:' `
               -replace '^HKEY_CLASSES_ROOT', 'Registry::HKEY_CLASSES_ROOT' -replace '^HKEY_USERS', 'Registry::HKEY_USERS'
    if ($p -match '^(HKLM|HKCU)\\') { $p = $p -replace '^(HKLM|HKCU)\\', '$1:\' }
    if ($p -match '^HKCR:?\\') { $p = $p -replace '^HKCR:?\\', 'Registry::HKEY_CLASSES_ROOT\' }
    if ($p -match '^HKU:?\\') { $p = $p -replace '^HKU:?\\', 'Registry::HKEY_USERS\' }
    return $p
}

function Get-RwRegValue {
    param([string]$Path, [string]$Name)
    $p = ConvertTo-RwRegPath $Path
    $r = [ordered]@{ path = $Path; name = $Name; keyExists = $false; exists = $false; type = $null; value = $null }
    if (-not (Test-Path -LiteralPath $p)) { return $r }
    $r.keyExists = $true
    $key = Get-Item -LiteralPath $p
    $names = @($key.GetValueNames())
    $lookup = $Name; if ($Name -eq '(default)') { $lookup = '' }
    if ($names -notcontains $lookup) { return $r }
    $r.exists = $true
    $kind = $key.GetValueKind($lookup)
    $val = $key.GetValue($lookup, $null, 'DoNotExpandEnvironmentNames')
    $r.type = $kind.ToString()
    if ($kind -eq 'Binary') { $r.value = (($val | ForEach-Object { $_.ToString('X2') }) -join '') }
    elseif ($kind -eq 'MultiString') { $r.value = @($val) }
    else { $r.value = $val }
    return $r
}

function Set-RwRegValue {
    param([string]$Path, [string]$Name, [string]$Type = 'DWord', $Value)
    $p = ConvertTo-RwRegPath $Path
    if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -Force | Out-Null }
    $v = $Value
    switch ($Type) {
        'DWord'  { $l = [int64]$Value; if ($l -gt [int]::MaxValue) { $l = $l - 4294967296 }; $v = [int]$l }
        'QWord'  { $v = [long]$Value }
        'Binary' { $hex = ([string]$Value) -replace '[^0-9A-Fa-f]', ''; $v = [byte[]](0..($hex.Length / 2 - 1) | ForEach-Object { [Convert]::ToByte($hex.Substring($_ * 2, 2), 16) }) }
        'MultiString' { $v = [string[]]@($Value) }
        default  { $v = [string]$Value }
    }
    $n = $Name; if ($Name -eq '(default)') { $n = '(default)' }
    New-ItemProperty -LiteralPath $p -Name $n -PropertyType $Type -Value $v -Force | Out-Null
}

function Remove-RwRegValue {
    param([string]$Path, [string]$Name)
    $p = ConvertTo-RwRegPath $Path
    if (Test-Path -LiteralPath $p) { Remove-ItemProperty -LiteralPath $p -Name $Name -Force -ErrorAction SilentlyContinue }
}

function Test-RwRegMatch {
    param($Entry)
    $cur = Get-RwRegValue $Entry.path $Entry.name
    if ($Entry.delete) { return (-not $cur.exists) }
    if (-not $cur.exists) { return $false }
    $want = $Entry.value
    if ($Entry.type -eq 'Binary') { return ((([string]$want) -replace '[^0-9A-Fa-f]', '').ToUpper() -eq [string]$cur.value) }
    if ($Entry.type -in 'DWord','QWord') {
        try { return ([int64]$cur.value -eq [int64]$want) -or ([uint32]([int64]$cur.value -band 0xFFFFFFFF) -eq [uint32]([int64]$want -band 0xFFFFFFFF)) } catch { return $false }
    }
    return ([string]$cur.value -eq [string]$want)
}

# ---------------------------------------------------------------- services / tasks primitives

function Get-RwServiceStartup {
    param([string]$Name)
    $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path $k)) { return $null }
    $props = Get-ItemProperty -Path $k
    $start = $props.Start
    $delayed = [int]($props.DelayedAutostart)
    switch ($start) {
        0 { 'Boot' } 1 { 'System' }
        2 { if ($delayed -eq 1) { 'AutomaticDelayedStart' } else { 'Automatic' } }
        3 { 'Manual' } 4 { 'Disabled' } default { "$start" }
    }
}

function Set-RwServiceStartup {
    param([string]$Name, [string]$Startup)
    $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path $k)) { Write-RwLog "Service $Name not present, skipped" 'warn'; return }
    if ($Startup -eq 'Disabled' -and $script:ProtectedServices -contains $Name) {
        Write-RwLog "Refusing to disable protected service $Name (would break Windows Update/security)" 'warn'; return
    }
    $scMode = @{ Automatic = 'auto'; AutomaticDelayedStart = 'delayed-auto'; Manual = 'demand'; Disabled = 'disabled' }[$Startup]
    $code = Invoke-RwNative "$env:SystemRoot\System32\sc.exe" "config `"$Name`" start= $scMode" -Quiet
    if ($code -ne 0) {
        # Some per-user / protected services refuse sc.exe; fall back to the registry value.
        $map = @{ Automatic = 2; AutomaticDelayedStart = 2; Manual = 3; Disabled = 4 }
        try {
            Set-ItemProperty -Path $k -Name Start -Value $map[$Startup] -Type DWord
            if ($Startup -eq 'AutomaticDelayedStart') { Set-ItemProperty -Path $k -Name DelayedAutostart -Value 1 -Type DWord }
        } catch { Write-RwLog "Could not change service $Name startup: $($_.Exception.Message)" 'warn'; return }
    }
    if ($Startup -eq 'Disabled') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
    Write-RwLog "Service $Name -> $Startup" 'ok'
}

function Get-RwTaskState {
    param([string]$Path, [string]$Name)
    $t = Get-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction SilentlyContinue
    if (-not $t) { return $null }
    if ($t.State -eq 'Disabled') { 'Disabled' } else { 'Enabled' }
}

function Set-RwTaskState {
    param([string]$Path, [string]$Name, [string]$State)
    $t = Get-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction SilentlyContinue
    if (-not $t) { Write-RwLog "Task $Path$Name not present, skipped" 'warn'; return }
    if ($State -eq 'Disabled') { $t | Disable-ScheduledTask | Out-Null } else { $t | Enable-ScheduledTask | Out-Null }
    Write-RwLog "Task $Path$Name -> $State" 'ok'
}

# ---------------------------------------------------------------- tweak state / plan / apply / undo

function Get-RwTweakState {
    param($Tweak)
    $checks = @()
    foreach ($r in @($Tweak.registry)) { if ($r) { $checks += (Test-RwRegMatch $r) } }
    foreach ($s in @($Tweak.services)) {
        if ($s) { $cur = Get-RwServiceStartup $s.name; if ($null -ne $cur) { $checks += ($cur -eq $s.startup) } }
    }
    foreach ($t in @($Tweak.tasks)) {
        if ($t) { $cur = Get-RwTaskState $t.path $t.name; if ($null -ne $cur) { $checks += ($cur -eq $t.state) } }
    }
    if ($Tweak.detect) {
        try { $checks += [bool](& ([scriptblock]::Create($Tweak.detect))) } catch { }
    }
    if ($checks.Count -eq 0) { return 'unknown' }
    $on = @($checks | Where-Object { $_ }).Count
    if ($on -eq $checks.Count) { return 'applied' }
    if ($on -eq 0) { return 'not-applied' }
    return 'partial'
}

function Get-RwOsBuild { [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild }

function Test-RwTweakApplicable {
    # Returns $null when applicable, otherwise the reason it is not.
    param($Tweak)
    $b = Get-RwOsBuild
    if ($Tweak.minBuild -and $b -lt [int]$Tweak.minBuild) { return "requires Windows build $($Tweak.minBuild)+ (this PC: $b)" }
    if ($Tweak.maxBuild -and $b -gt [int]$Tweak.maxBuild) { return "only for Windows builds up to $($Tweak.maxBuild) (this PC: $b)" }
    return $null
}

# Services Rigwright refuses to disable: breaking these is the #1 cause of "Windows Update broken" reports.
$script:ProtectedServices = @('WaaSMedicSvc','wuauserv','UsoSvc','BITS','CryptSvc','TrustedInstaller','WinDefend','SecurityHealthService','mpssvc','RpcSs','DcomLaunch','AppXSvc','ClipSVC','StateRepository','Winmgmt','EventLog','Schedule')

function Get-RwTweakStates {
    # state: applied | not-applied | partial | unknown | n/a
    # drifted = Rigwright applied it earlier but Windows (e.g. a feature update) changed it back.
    $out = [ordered]@{}
    $journal = Get-RwJournal
    foreach ($t in (Get-RwCatalog).tweaks) {
        $state = 'unknown'
        $reason = Test-RwTweakApplicable $t
        if ($reason) { $state = 'n/a' } else { try { $state = Get-RwTweakState $t } catch { } }
        $j = $journal.tweaks.Contains($t.id)
        $out[$t.id] = [ordered]@{ state = $state; journaled = $j; drifted = ($j -and $state -in @('not-applied','partial')); reason = $reason }
    }
    return $out
}

function Format-RwValue { param($v) if ($null -eq $v) { '(not set)' } elseif ($v -is [array]) { ($v -join ';') } else { "$v" } }

function Get-RwPlan {
    # Returns a human readable list of exactly what would change.
    param([string[]]$Ids, [switch]$Undo)
    $journal = Get-RwJournal
    $plan = @()
    foreach ($id in $Ids) {
        $t = Get-RwTweak $id
        if (-not $t) { $plan += [ordered]@{ id = $id; name = $id; changes = @('Unknown tweak id - will be skipped') }; continue }
        $changes = @()
        $orig = $null
        if ($Undo -and $journal.tweaks.Contains($id)) { $orig = $journal.tweaks[$id].original }
        foreach ($r in @($t.registry)) {
            if (-not $r) { continue }
            $cur = Get-RwRegValue $r.path $r.name
            if ($Undo) {
                $o = $null
                if ($orig) { $o = @($orig.registry) | Where-Object { $_.path -eq $r.path -and $_.name -eq $r.name } | Select-Object -First 1 }
                if ($o) {
                    if ($o.exists) { $changes += "Registry $($r.path)\$($r.name): $(Format-RwValue $cur.value) -> $(Format-RwValue $o.value) (restored from journal)" }
                    else { $changes += "Registry $($r.path)\$($r.name): delete value (did not exist before)" }
                } elseif ($r.PSObject.Properties['undo']) {
                    if ($r.undo -eq $null -or $r.undo -eq '<delete>') { $changes += "Registry $($r.path)\$($r.name): delete value (Windows default)" }
                    else { $changes += "Registry $($r.path)\$($r.name): $(Format-RwValue $cur.value) -> $(Format-RwValue $r.undo) (Windows default)" }
                } else { $changes += "Registry $($r.path)\$($r.name): delete value (Windows default)" }
            } else {
                if ($r.delete) { $changes += "Registry $($r.path)\$($r.name): delete value (currently $(Format-RwValue $cur.value))" }
                else {
                    $same = Test-RwRegMatch $r
                    $suffix = ''; if ($same) { $suffix = ' (already set)' }
                    $changes += "Registry $($r.path)\$($r.name) [$($r.type)]: $(Format-RwValue $cur.value) -> $(Format-RwValue $r.value)$suffix"
                }
            }
        }
        foreach ($s in @($t.services)) {
            if (-not $s) { continue }
            $cur = Get-RwServiceStartup $s.name
            if ($null -eq $cur) { $changes += "Service $($s.name): not installed (skip)"; continue }
            $target = $s.startup
            if ($Undo) {
                $target = $s.undo; if (-not $target) { $target = 'Manual' }
                if ($orig) { $o = @($orig.services) | Where-Object { $_.name -eq $s.name } | Select-Object -First 1; if ($o -and $o.startup) { $target = $o.startup } }
            }
            $changes += "Service $($s.name) startup: $cur -> $target"
        }
        foreach ($tk in @($t.tasks)) {
            if (-not $tk) { continue }
            $cur = Get-RwTaskState $tk.path $tk.name
            if ($null -eq $cur) { $changes += "Task $($tk.path)$($tk.name): not present (skip)"; continue }
            $target = $tk.state; if ($Undo) { $target = 'Enabled'; if ($tk.state -eq 'Enabled') { $target = 'Disabled' } }
            $changes += "Scheduled task $($tk.path)$($tk.name): $cur -> $target"
        }
        if (-not $Undo -and $t.script) { $changes += "Runs script:`n$($t.script)" }
        if ($Undo -and $t.undoScript) { $changes += "Runs undo script:`n$($t.undoScript)" }
        if ($Undo -and -not $t.undoScript -and $t.script -and -not $t.registry -and -not $t.services) { $changes += 'No automatic undo is available for this tweak.' }
        $plan += [ordered]@{ id = $id; name = $t.name; risk = $t.risk; restart = $t.restart; changes = $changes }
    }
    return ,$plan
}

function Invoke-RwTweak {
    param([string]$Id, [switch]$Undo)
    $t = Get-RwTweak $Id
    if (-not $t) { Write-RwLog "Unknown tweak '$Id' skipped" 'warn'; return $false }
    $na = Test-RwTweakApplicable $t
    if ($na -and -not $Undo) { Write-RwLog "Skipped $($t.name): $na" 'warn'; return $false }
    $verb = 'Applying'; if ($Undo) { $verb = 'Reverting' }
    Write-RwLog "${verb}: $($t.name)" 'info'
    $journal = Get-RwJournal

    if (-not $Undo) {
        # Capture original state once (first apply wins so undo returns to the true original).
        if (-not $journal.tweaks.Contains($Id)) {
            $orig = [ordered]@{ registry = @(); services = @(); tasks = @() }
            foreach ($r in @($t.registry)) { if ($r) { $orig.registry += (Get-RwRegValue $r.path $r.name) } }
            foreach ($s in @($t.services)) { if ($s) { $orig.services += [ordered]@{ name = $s.name; startup = (Get-RwServiceStartup $s.name) } } }
            foreach ($tk in @($t.tasks))   { if ($tk) { $orig.tasks += [ordered]@{ path = $tk.path; name = $tk.name; state = (Get-RwTaskState $tk.path $tk.name) } } }
            $journal.tweaks[$Id] = [ordered]@{ appliedAt = (Get-Date).ToString('o'); original = $orig }
            Save-RwJournal $journal
        }
        foreach ($r in @($t.registry)) {
            if (-not $r) { continue }
            try {
                if ($r.delete) { Remove-RwRegValue $r.path $r.name; Write-RwLog "Deleted $($r.path)\$($r.name)" 'ok' }
                else { Set-RwRegValue $r.path $r.name $r.type $r.value; Write-RwLog "Set $($r.path)\$($r.name) = $(Format-RwValue $r.value)" 'ok' }
            } catch { Write-RwLog "Registry $($r.path)\$($r.name): $($_.Exception.Message)" 'error' }
        }
        foreach ($s in @($t.services)) { if ($s) { try { Set-RwServiceStartup $s.name $s.startup } catch { Write-RwLog $_.Exception.Message 'error' } } }
        foreach ($tk in @($t.tasks))   { if ($tk) { try { Set-RwTaskState $tk.path $tk.name $tk.state } catch { Write-RwLog $_.Exception.Message 'error' } } }
        if ($t.script) { Invoke-RwScript $t.script $t.name }
    } else {
        $orig = $null
        if ($journal.tweaks.Contains($Id)) { $orig = $journal.tweaks[$Id].original }
        foreach ($r in @($t.registry)) {
            if (-not $r) { continue }
            try {
                $o = $null
                if ($orig) { $o = @($orig.registry) | Where-Object { $_.path -eq $r.path -and $_.name -eq $r.name } | Select-Object -First 1 }
                if ($o) {
                    if ($o.exists) { Set-RwRegValue $r.path $r.name $o.type $o.value; Write-RwLog "Restored $($r.path)\$($r.name) = $(Format-RwValue $o.value)" 'ok' }
                    else { Remove-RwRegValue $r.path $r.name; Write-RwLog "Removed $($r.path)\$($r.name)" 'ok' }
                } elseif ($r.PSObject.Properties['undo'] -and $null -ne $r.undo -and $r.undo -ne '<delete>') {
                    $ut = $r.type; if ($r.undoType) { $ut = $r.undoType }
                    Set-RwRegValue $r.path $r.name $ut $r.undo; Write-RwLog "Set $($r.path)\$($r.name) = $(Format-RwValue $r.undo) (default)" 'ok'
                } else { Remove-RwRegValue $r.path $r.name; Write-RwLog "Removed $($r.path)\$($r.name) (default)" 'ok' }
            } catch { Write-RwLog "Registry $($r.path)\$($r.name): $($_.Exception.Message)" 'error' }
        }
        foreach ($s in @($t.services)) {
            if (-not $s) { continue }
            $target = $s.undo; if (-not $target) { $target = 'Manual' }
            if ($orig) { $o = @($orig.services) | Where-Object { $_.name -eq $s.name } | Select-Object -First 1; if ($o -and $o.startup) { $target = $o.startup } }
            try { Set-RwServiceStartup $s.name $target } catch { Write-RwLog $_.Exception.Message 'error' }
        }
        foreach ($tk in @($t.tasks)) {
            if (-not $tk) { continue }
            $target = 'Enabled'; if ($tk.state -eq 'Enabled') { $target = 'Disabled' }
            if ($orig) { $o = @($orig.tasks) | Where-Object { $_.path -eq $tk.path -and $_.name -eq $tk.name } | Select-Object -First 1; if ($o -and $o.state) { $target = $o.state } }
            try { Set-RwTaskState $tk.path $tk.name $target } catch { Write-RwLog $_.Exception.Message 'error' }
        }
        if ($t.undoScript) { Invoke-RwScript $t.undoScript "$($t.name) (undo)" }
        if ($journal.tweaks.Contains($Id)) { $journal.tweaks.Remove($Id); Save-RwJournal $journal }
    }
    return $true
}

function Invoke-RwScript {
    param([string]$Script, [string]$Label)
    Write-RwLog "Running script for $Label" 'cmd'
    try {
        $out = & ([scriptblock]::Create($Script)) 2>&1
        foreach ($o in @($out)) { if ($null -ne $o -and "$o".Trim()) { Write-RwLog "$o" 'info' } }
        Write-RwLog "Script for $Label finished" 'ok'
    } catch { Write-RwLog "Script for $Label failed: $($_.Exception.Message)" 'error' }
}

function Invoke-RwTweaks {
    param([string[]]$Ids, [switch]$Undo, [switch]$NoRestorePoint)
    $settings = Get-RwSettings
    if (-not $NoRestorePoint -and $settings.safety.restorePointBeforeChanges) {
        $what = 'apply'; if ($Undo) { $what = 'undo' }
        New-RwRestorePoint "Rigwright: before $what of $($Ids.Count) tweak(s)" | Out-Null
    }
    $restart = @()
    $ok = 0
    foreach ($id in $Ids) {
        if (Invoke-RwTweak -Id $id -Undo:$Undo) { $ok++ }
        $t = Get-RwTweak $id
        if ($t -and $t.restart -and $t.restart -ne 'none') { $restart += $t.restart }
    }
    if ($restart -contains 'explorer') {
        Write-RwLog 'Restarting Explorer to apply shell changes' 'info'
        Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Milliseconds 800
        if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    }
    $action = 'tweaks.apply'; if ($Undo) { $action = 'tweaks.undo' }
    Add-RwHistory $action $Ids "$ok/$($Ids.Count) ok"
    $needReboot = $restart -contains 'reboot'
    if ($needReboot) { Write-RwLog 'Some changes need a reboot to take full effect.' 'warn' }
    Write-RwLog "Done: $ok of $($Ids.Count) succeeded." 'ok'
    return [ordered]@{ ok = $ok; total = $Ids.Count; rebootRequired = $needReboot }
}

# ---------------------------------------------------------------- restore points

function New-RwRestorePoint {
    param([string]$Description = 'Rigwright checkpoint')
    try {
        $srKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        $rpDisabled = $false
        try { $rpDisabled = ((Get-ItemProperty $srKey -ErrorAction Stop).RPSessionInterval -eq 0) } catch { }
        try { Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop } catch { }
        # Windows only allows one restore point per 24h by default; lift that for this call.
        $freqKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        $prev = (Get-ItemProperty $freqKey -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
        Set-ItemProperty $freqKey -Name SystemRestorePointCreationFrequency -Value 0 -Type DWord
        Write-RwLog "Creating restore point: $Description" 'info'
        Checkpoint-Computer -Description $Description -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        if ($null -eq $prev) { Remove-ItemProperty $freqKey -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue }
        else { Set-ItemProperty $freqKey -Name SystemRestorePointCreationFrequency -Value $prev -Type DWord }
        Write-RwLog 'Restore point created' 'ok'
        return $true
    } catch {
        Write-RwLog "Restore point could not be created: $($_.Exception.Message)" 'warn'
        return $false
    }
}

function Get-RwRestorePoints {
    try { @(Get-ComputerRestorePoint -ErrorAction Stop | Sort-Object SequenceNumber -Descending | ForEach-Object {
        [ordered]@{ sequence = $_.SequenceNumber; description = $_.Description; created = ([Management.ManagementDateTimeConverter]::ToDateTime($_.CreationTime)).ToString('o') } }) }
    catch { @() }
}

# ---------------------------------------------------------------- registry backup

function Backup-RwRegistry {
    param([string[]]$Keys = @('HKCU\Software\Microsoft\Windows\CurrentVersion','HKLM\SOFTWARE\Policies'))
    $dir = Join-Path $script:DataDir ('backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $i = 0
    foreach ($k in $Keys) {
        $i++
        $file = Join-Path $dir ("{0:D2}-{1}.reg" -f $i, ($k -replace '[\\:]', '_'))
        Invoke-RwNative "$env:SystemRoot\System32\reg.exe" "export `"$k`" `"$file`" /y" -Quiet | Out-Null
    }
    Write-RwLog "Registry backup written to $dir" 'ok'
    return $dir
}

# ---------------------------------------------------------------- system info

function Get-RwSystemInfo {
    $os  = Get-CimInstance Win32_OperatingSystem
    $cs  = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $gpu = @(Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name })
    $disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        [ordered]@{ drive = $_.DeviceID; sizeGB = [math]::Round($_.Size / 1GB, 1); freeGB = [math]::Round($_.FreeSpace / 1GB, 1) } })
    $bat = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
    $cv  = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $plan = ''
    try { $plan = ((& "$env:SystemRoot\System32\powercfg.exe" /getactivescheme) -replace '.*\((.*)\).*', '$1').Trim() } catch { }
    $secureBoot = $null; try { $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop } catch { }
    $tpm = $null; try { $t = Get-Tpm -ErrorAction Stop; $tpm = [bool]$t.TpmPresent } catch { }
    $phys = @()
    try {
        $phys = @(Get-PhysicalDisk -ErrorAction Stop | ForEach-Object {
            $letters = @()
            try { $letters = @(Get-Partition -DiskNumber $_.DeviceId -ErrorAction Stop | Where-Object { $_.DriveLetter } | ForEach-Object { "$($_.DriveLetter):" }) } catch { }
            [ordered]@{ name = $_.FriendlyName; media = "$($_.MediaType)"; bus = "$($_.BusType)"; health = "$($_.HealthStatus)"; sizeGB = [math]::Round($_.Size / 1GB); letters = $letters }
        })
    } catch { }
    [ordered]@{
        computer     = $env:COMPUTERNAME
        user         = $env:USERNAME
        os           = $os.Caption
        edition      = $cv.EditionID
        displayVersion = $cv.DisplayVersion
        build        = "$($cv.CurrentBuild).$($cv.UBR)"
        architecture = $os.OSArchitecture
        manufacturer = $cs.Manufacturer
        model        = $cs.Model
        cpu          = $cpu.Name.Trim()
        cores        = $cpu.NumberOfCores
        threads      = $cpu.NumberOfLogicalProcessors
        ramGB        = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        ramFreeGB    = [math]::Round($os.FreePhysicalMemory * 1KB / 1GB, 1)
        gpu          = $gpu
        disks        = $disks
        physicalDisks = $phys
        laptop       = ($bat.Count -gt 0)
        batteryPct   = $(if ($bat.Count) { $bat[0].EstimatedChargeRemaining } else { $null })
        powerPlan    = $plan
        uptimeHours  = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
        lastBoot     = $os.LastBootUpTime.ToString('o')
        secureBoot   = $secureBoot
        tpm          = $tpm
        isAdmin      = (Test-RwAdmin)
        winget       = [bool](Get-RwWinget)
        choco        = [bool](Get-Command choco -ErrorAction SilentlyContinue)
        tempGB       = [math]::Round(((Get-ChildItem $env:TEMP -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) / 1GB, 2)
    }
}

# ---------------------------------------------------------------- apps (winget / choco)

function Get-RwWinget {
    $c = Get-Command winget -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path $p) { return $p }
    $pkg = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
    if ($pkg) { return $pkg.FullName }
    return $null
}

function Install-RwWinget {
    Write-RwLog 'winget not found - installing App Installer from Microsoft' 'info'
    try {
        $tmp = Join-Path $env:TEMP 'Microsoft.DesktopAppInstaller.msixbundle'
        Invoke-WebRequest -UseBasicParsing 'https://aka.ms/getwinget' -OutFile $tmp
        Add-AppxPackage -Path $tmp
        Write-RwLog 'winget installed' 'ok'
    } catch { Write-RwLog "winget install failed: $($_.Exception.Message)" 'error' }
}

function Get-RwInstalledApps {
    # Uses `winget export`, which returns structured JSON instead of a width-truncated table.
    $wg = Get-RwWinget
    if (-not $wg) { return @() }
    $tmp = Join-Path $env:TEMP ("rw-export-{0}.json" -f [guid]::NewGuid())
    Invoke-RwNative $wg "export -o `"$tmp`" --accept-source-agreements --include-versions --disable-interactivity" -Quiet | Out-Null
    $ids = @()
    if (Test-Path $tmp) {
        $j = Read-RwJson $tmp
        foreach ($src in @($j.Sources)) { foreach ($p in @($src.Packages)) { $ids += [ordered]@{ id = $p.PackageIdentifier; version = $p.Version; source = $src.SourceDetails.Name } } }
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
    return ,$ids
}

function ConvertFrom-RwWingetTable {
    param([string[]]$Lines)
    $rows = @()
    $hdrIdx = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -match '^\s*Name\s+Id\s+Version') { $hdrIdx = $i; break } }
    if ($hdrIdx -lt 0) { return ,$rows }
    $hdr = $Lines[$hdrIdx]
    $cols = @()
    foreach ($m in [regex]::Matches($hdr, '\S+')) { $cols += [ordered]@{ name = $m.Value; start = $m.Index } }
    for ($i = $hdrIdx + 2; $i -lt $Lines.Count; $i++) {
        $l = $Lines[$i]
        if (-not $l.Trim() -or $l -match '^\d+ (upgrades|package)' -or $l -match '^-+$') { continue }
        $row = [ordered]@{}
        for ($c = 0; $c -lt $cols.Count; $c++) {
            $s = $cols[$c].start
            $e = $(if ($c + 1 -lt $cols.Count) { $cols[$c + 1].start } else { $l.Length })
            if ($s -ge $l.Length) { $row[$cols[$c].name.ToLower()] = ''; continue }
            if ($e -gt $l.Length) { $e = $l.Length }
            $row[$cols[$c].name.ToLower()] = $l.Substring($s, $e - $s).Trim()
        }
        if ($row['id']) { $rows += $row }
    }
    return ,$rows
}

function Invoke-RwWingetCapture {
    param([string]$Arguments)
    $wg = Get-RwWinget
    if (-not $wg) { return @() }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $wg; $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    try { $psi.StandardOutputEncoding = [Text.Encoding]::UTF8 } catch { }
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd(); $null = $p.StandardError.ReadToEnd(); $p.WaitForExit()
    # winget redraws progress with CR; keep the final text of each line
    return ,@(($out -split "`n") | ForEach-Object { ($_ -split "`r")[-1] })
}

function Find-RwApp {
    param([string]$Query)
    $lines = Invoke-RwWingetCapture "search --query `"$($Query -replace '"','')`" --accept-source-agreements --disable-interactivity"
    return (ConvertFrom-RwWingetTable $lines)
}

function Get-RwUpgradableApps {
    $lines = Invoke-RwWingetCapture 'upgrade --accept-source-agreements --include-unknown --disable-interactivity'
    return (ConvertFrom-RwWingetTable $lines)
}

function Install-RwApps {
    param([string[]]$Ids, [ValidateSet('install','uninstall','upgrade')][string]$Mode = 'install')
    $wg = Get-RwWinget
    if (-not $wg -and $Mode -ne 'uninstall') { Install-RwWinget; $wg = Get-RwWinget }
    $cat = (Get-RwCatalog).apps
    $ok = 0; $fail = @()
    foreach ($id in $Ids) {
        $entry = $cat | Where-Object { $_.winget -eq $id -or $_.id -eq $id } | Select-Object -First 1
        $wid = $id; if ($entry -and $entry.winget) { $wid = $entry.winget }
        $label = $wid; if ($entry) { $label = "$($entry.name) ($wid)" }
        Write-RwLog "$Mode $label" 'info'
        $code = 1
        if ($wg -and $wid) {
            $src = ''; if ($wid -match '^[0-9A-Z]{12}$') { $src = ' --source msstore' }
            $extra = ''; if ($entry -and $entry.extraArgs) { $extra = " $($entry.extraArgs)" }
            switch ($Mode) {
                'install'   { $code = Invoke-RwNative $wg "install --id `"$wid`" --exact$src --silent --accept-package-agreements --accept-source-agreements --disable-interactivity$extra" }
                'uninstall' { $code = Invoke-RwNative $wg "uninstall --id `"$wid`" --exact --silent --accept-source-agreements --disable-interactivity" }
                'upgrade'   { $code = Invoke-RwNative $wg "upgrade --id `"$wid`" --exact$src --silent --accept-package-agreements --accept-source-agreements --disable-interactivity" }
            }
            # -1978335189 = APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE / already installed-ish codes treated as success
            if ($code -in @(-1978335189, -1978335135)) { $code = 0 }
        }
        if ($code -ne 0 -and $entry -and $entry.choco -and (Get-Command choco -ErrorAction SilentlyContinue)) {
            Write-RwLog "winget failed ($code), trying Chocolatey package $($entry.choco)" 'warn'
            $verb = @{ install = 'install'; uninstall = 'uninstall'; upgrade = 'upgrade' }[$Mode]
            $code = Invoke-RwNative (Get-Command choco).Source "$verb $($entry.choco) -y --no-progress"
        }
        if ($code -eq 0) { $ok++; Write-RwLog "${label}: $Mode OK" 'ok' } else { $fail += $wid; Write-RwLog "${label}: $Mode failed (exit $code)" 'error' }
    }
    Add-RwHistory "apps.$Mode" $Ids "$ok/$($Ids.Count) ok" ($fail -join ', ')
    return [ordered]@{ ok = $ok; total = $Ids.Count; failed = $fail }
}

function Update-RwAllApps {
    $wg = Get-RwWinget
    if (-not $wg) { Write-RwLog 'winget not available' 'error'; return }
    $code = Invoke-RwNative $wg 'upgrade --all --include-unknown --silent --accept-package-agreements --accept-source-agreements --disable-interactivity'
    Add-RwHistory 'apps.upgrade-all' @() "exit $code"
    return [ordered]@{ exitCode = $code }
}

# ---------------------------------------------------------------- Windows optional features

function Get-RwFeatureStates {
    $out = [ordered]@{}
    if (-not (Test-RwAdmin)) {
        # DISM only reports optional features to administrators
        foreach ($f in (Get-RwCatalog).features) { $out[$f.id] = 'needs admin' }
        return $out
    }
    foreach ($f in (Get-RwCatalog).features) {
        $states = @()
        foreach ($n in @($f.features)) {
            if (-not $n) { continue }
            try { $s = Get-WindowsOptionalFeature -Online -FeatureName $n -ErrorAction Stop; $states += "$($s.State)" } catch { $states += 'Unavailable' }
        }
        foreach ($n in @($f.capabilities)) {
            if (-not $n) { continue }
            try { $s = Get-WindowsCapability -Online -Name $n -ErrorAction Stop; if ("$($s.State)" -eq 'Installed') { $states += 'Enabled' } else { $states += 'Disabled' } } catch { $states += 'Unavailable' }
        }
        if (-not $states.Count) { $states = @('Unavailable') }
        $st = 'mixed'
        if (@($states | Where-Object { $_ -eq 'Enabled' }).Count -eq $states.Count) { $st = 'enabled' }
        elseif (@($states | Where-Object { $_ -match 'Disabled' }).Count -eq $states.Count) { $st = 'disabled' }
        elseif (@($states | Where-Object { $_ -eq 'Unavailable' }).Count -eq $states.Count) { $st = 'unavailable' }
        $out[$f.id] = $st
    }
    return $out
}

function Set-RwFeatures {
    param([string[]]$Ids, [bool]$Enable = $true)
    $ok = 0
    foreach ($id in $Ids) {
        $f = (Get-RwCatalog).features | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if (-not $f) { Write-RwLog "Unknown feature $id" 'warn'; continue }
        foreach ($n in @($f.capabilities)) {
            if (-not $n) { continue }
            try {
                if ($Enable) { Add-WindowsCapability -Online -Name $n -ErrorAction Stop | Out-Null; Write-RwLog "Installed capability $n" 'ok' }
                else { Remove-WindowsCapability -Online -Name $n -ErrorAction Stop | Out-Null; Write-RwLog "Removed capability $n" 'ok' }
            } catch { Write-RwLog "${n}: $($_.Exception.Message)" 'error' }
        }
        foreach ($n in @($f.features)) {
            if (-not $n) { continue }
            try {
                if ($Enable) { Enable-WindowsOptionalFeature -Online -FeatureName $n -All -NoRestart -ErrorAction Stop | Out-Null; Write-RwLog "Enabled $n" 'ok' }
                else { Disable-WindowsOptionalFeature -Online -FeatureName $n -NoRestart -ErrorAction Stop | Out-Null; Write-RwLog "Disabled $n" 'ok' }
            } catch { Write-RwLog "${n}: $($_.Exception.Message)" 'error' }
        }
        if ($f.script -and $Enable) { Invoke-RwScript $f.script $f.name }
        $ok++
    }
    $a = 'features.disable'; if ($Enable) { $a = 'features.enable' }
    Add-RwHistory $a $Ids "$ok/$($Ids.Count)"
    Write-RwLog 'Feature changes usually require a reboot.' 'warn'
    return [ordered]@{ ok = $ok; total = $Ids.Count; rebootRequired = $true }
}

# ---------------------------------------------------------------- fixes / maintenance

function Invoke-RwFixes {
    param([string[]]$Ids)
    $ok = 0
    foreach ($id in $Ids) {
        $f = (Get-RwCatalog).fixes | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if (-not $f) { Write-RwLog "Unknown fix $id" 'warn'; continue }
        Write-RwLog "Running: $($f.name)" 'info'
        Invoke-RwScript $f.script $f.name
        $ok++
    }
    Add-RwHistory 'fixes.run' $Ids "$ok/$($Ids.Count)"
    return [ordered]@{ ok = $ok; total = $Ids.Count }
}

# ---------------------------------------------------------------- debloat (AppX)

function Get-RwAppxInventory {
    $known = (Get-RwCatalog).debloat
    $pkgs = @()
    try { $pkgs = @(Get-AppxPackage -AllUsers -ErrorAction Stop) } catch { $pkgs = @(Get-AppxPackage) }
    $prov = @()
    try { $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | ForEach-Object { $_.DisplayName }) } catch { }
    $seen = @{}
    $out = @()
    foreach ($p in $pkgs) {
        if ($p.IsFramework -or $p.NonRemovable -or $p.SignatureKind -eq 'System') { continue }
        if ($seen.ContainsKey($p.Name)) { continue }
        $seen[$p.Name] = $true
        $k = $known | Where-Object { $p.Name -like $_.package } | Select-Object -First 1
        $out += [ordered]@{
            package     = $p.Name
            name        = $(if ($k) { $k.name } else { $p.Name })
            publisher   = ($p.Publisher -replace '^CN=([^,]+).*', '$1')
            version     = "$($p.Version)"
            provisioned = ($prov -contains $p.Name)
            known       = [bool]$k
            category    = $(if ($k) { $k.category } else { 'Other' })
            safe        = $(if ($k) { [bool]$k.safe } else { $false })
            note        = $(if ($k) { $k.note } else { '' })
            storeId     = $(if ($k) { $k.storeId } else { '' })
        }
    }
    return ,@($out | Sort-Object @{ e = { -not $_.known } }, name)
}

function Remove-RwAppx {
    param([string[]]$Packages, [switch]$IncludeProvisioned)
    $settings = Get-RwSettings
    if ($settings.safety.restorePointBeforeChanges) { New-RwRestorePoint "Rigwright: before removing $($Packages.Count) app(s)" | Out-Null }
    $j = Get-RwJournal
    $removed = @()
    foreach ($name in $Packages) {
        Write-RwLog "Removing $name" 'info'
        try {
            $ps = @(Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue)
            foreach ($p in $ps) { try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop } catch { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction SilentlyContinue } }
            if ($IncludeProvisioned) {
                Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $name } | ForEach-Object {
                    Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null
                    Write-RwLog "Deprovisioned $name (new users will not get it)" 'ok'
                }
            }
            $k = (Get-RwCatalog).debloat | Where-Object { $name -like $_.package } | Select-Object -First 1
            $removed += [ordered]@{ package = $name; time = (Get-Date).ToString('o'); storeId = $(if ($k) { $k.storeId } else { '' }) }
            Write-RwLog "Removed $name" 'ok'
        } catch { Write-RwLog "${name}: $($_.Exception.Message)" 'error' }
    }
    $j['appx'] = @($j['appx']) + $removed
    Save-RwJournal $j
    Add-RwHistory 'debloat.remove' $Packages "$($removed.Count)/$($Packages.Count)"
    return [ordered]@{ removed = $removed.Count; total = $Packages.Count }
}

function Restore-RwAppx {
    param([string[]]$Packages)
    $j = Get-RwJournal
    $wg = Get-RwWinget
    foreach ($name in $Packages) {
        $rec = @($j['appx']) | Where-Object { $_.package -eq $name } | Select-Object -Last 1
        # Re-register from the image first (works when only the per-user copy was removed)
        $prov = Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($prov) {
            try { Add-AppxPackage -DisableDevelopmentMode -Register "$($prov.InstallLocation)\AppxManifest.xml" -ErrorAction Stop; Write-RwLog "Re-registered $name" 'ok'; continue } catch { }
        }
        if ($rec -and $rec.storeId -and $wg) {
            Invoke-RwNative $wg "install --id $($rec.storeId) --source msstore --accept-package-agreements --accept-source-agreements --disable-interactivity" | Out-Null
        } else { Write-RwLog "No automatic reinstall source for $name - reinstall it from the Microsoft Store." 'warn' }
    }
    Add-RwHistory 'debloat.restore' $Packages 'done'
}

# ---------------------------------------------------------------- startup apps

$script:StartupSources = @(
    @{ scope = 'User';    run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';             approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
    @{ scope = 'Machine'; run = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';             approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
    @{ scope = 'Machine32'; run = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
)

function Get-RwStartupItems {
    $items = @()
    foreach ($src in $script:StartupSources) {
        if (-not (Test-Path $src.run)) { continue }
        $k = Get-Item $src.run
        foreach ($n in $k.GetValueNames()) {
            if (-not $n) { continue }
            $enabled = $true
            $a = Get-RwRegValue $src.approved $n
            if ($a.exists -and $a.value -and ([string]$a.value).Substring(0, 2) -ne '02' -and ([string]$a.value).Substring(0, 2) -ne '06') { $enabled = $false }
            $items += [ordered]@{ name = $n; command = [string]$k.GetValue($n); scope = $src.scope; kind = 'registry'; enabled = $enabled; key = $src.scope }
        }
    }
    $folders = @(
        @{ scope = 'User'; path = [Environment]::GetFolderPath('Startup'); approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' },
        @{ scope = 'Machine'; path = [Environment]::GetFolderPath('CommonStartup'); approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
    )
    foreach ($f in $folders) {
        if (-not (Test-Path $f.path)) { continue }
        foreach ($file in Get-ChildItem $f.path -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' }) {
            $enabled = $true
            $a = Get-RwRegValue $f.approved $file.Name
            if ($a.exists -and $a.value -and ([string]$a.value).Substring(0, 2) -ne '02' -and ([string]$a.value).Substring(0, 2) -ne '06') { $enabled = $false }
            $items += [ordered]@{ name = $file.Name; command = $file.FullName; scope = $f.scope; kind = 'folder'; enabled = $enabled; key = "Folder$($f.scope)" }
        }
    }
    return ,$items
}

function Set-RwStartupItem {
    # Uses the same StartupApproved mechanism as Task Manager, so it is fully reversible there too.
    param([string]$Name, [string]$Key, [bool]$Enabled)
    $approved = switch ($Key) {
        'User'          { 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
        'Machine'       { 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
        'Machine32'     { 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
        'FolderUser'    { 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
        'FolderMachine' { 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
    }
    if (-not $approved) { throw "Unknown startup key $Key" }
    $hex = '020000000000000000000000'
    if (-not $Enabled) {
        $ft = [BitConverter]::GetBytes((Get-Date).ToFileTimeUtc())
        $hex = '03000000' + (($ft | ForEach-Object { $_.ToString('X2') }) -join '')
    }
    Set-RwRegValue $approved $Name 'Binary' $hex
    $state = 'disabled'; if ($Enabled) { $state = 'enabled' }
    Write-RwLog "Startup item '$Name' $state" 'ok'
    Add-RwHistory 'startup.toggle' @($Name) $state
}

# ---------------------------------------------------------------- policy cleaner ("managed by your organization")

$script:PolicyRoots = @('HKLM:\SOFTWARE\Policies','HKCU:\SOFTWARE\Policies','HKLM:\SOFTWARE\WOW6432Node\Policies')

function Get-RwPolicyValues {
    # Lists every policy value on the machine and flags the ones a Rigwright tweak sets.
    $mine = @{}
    foreach ($t in (Get-RwCatalog).tweaks) {
        foreach ($r in @($t.registry)) { if ($r) { $mine[((ConvertTo-RwRegPath $r.path) + '|' + $r.name).ToLower()] = $t.name } }
    }
    $managed = $false
    try { $managed = [bool](Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction Stop | Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ProviderID }) } catch { }
    $out = @()
    foreach ($root in $script:PolicyRoots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($k in @(Get-Item $root) + @(Get-ChildItem $root -Recurse -ErrorAction SilentlyContinue)) {
            $path = $k.Name -replace '^HKEY_LOCAL_MACHINE', 'HKLM:' -replace '^HKEY_CURRENT_USER', 'HKCU:'
            foreach ($n in $k.GetValueNames()) {
                if (-not $n) { continue }
                $key = ($path + '|' + $n).ToLower()
                $v = $k.GetValue($n)
                if ($v -is [byte[]]) { $v = (($v | ForEach-Object { $_.ToString('X2') }) -join '') }
                $out += [ordered]@{ path = $path; name = $n; value = "$v"; setBy = $(if ($mine.ContainsKey($key)) { $mine[$key] } else { '' }) }
            }
        }
    }
    return [ordered]@{ mdmEnrolled = $managed; values = $out }
}

function Remove-RwPolicyValues {
    param($Entries)  # array of @{ path; name }
    $dir = Join-Path $script:DataDir ('backups\policies-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($root in @('HKLM\SOFTWARE\Policies','HKCU\SOFTWARE\Policies')) {
        Invoke-RwNative "$env:SystemRoot\System32\reg.exe" "export `"$root`" `"$dir\$($root -replace '\\','_').reg`" /y" -Quiet | Out-Null
    }
    Write-RwLog "Policy backup saved to $dir (double-click the .reg files to restore)" 'ok'
    $n = 0
    foreach ($e in @($Entries)) {
        try { Remove-RwRegValue $e.path $e.name; $n++; Write-RwLog "Removed policy $($e.path)\$($e.name)" 'ok' } catch { Write-RwLog $_.Exception.Message 'error' }
    }
    # Remove now-empty policy keys so Settings stops showing the banner
    foreach ($root in $script:PolicyRoots) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -Recurse -ErrorAction SilentlyContinue | Sort-Object { $_.Name.Length } -Descending | ForEach-Object {
            if ($_.ValueCount -eq 0 -and $_.SubKeyCount -eq 0) { Remove-Item $_.PSPath -Force -ErrorAction SilentlyContinue }
        }
    }
    & "$env:SystemRoot\System32\gpupdate.exe" /target:computer /force 2>&1 | Out-Null
    Add-RwHistory 'policies.remove' @($Entries | ForEach-Object { "$($_.path)\$($_.name)" }) "$n removed" $dir
    return [ordered]@{ removed = $n; backup = $dir }
}

# ---------------------------------------------------------------- report

function Export-RwReport {
    $info = Get-RwSystemInfo
    $states = Get-RwTweakStates
    $j = Get-RwJournal
    [ordered]@{
        generated = (Get-Date).ToString('o'); app = (Get-RwInfo); system = $info
        appliedTweaks = @($states.Keys | Where-Object { $states[$_].state -eq 'applied' })
        driftedTweaks = @($states.Keys | Where-Object { $states[$_].drifted })
        history = @($j['history'] | Select-Object -Last 100)
    }
}

# ---------------------------------------------------------------- data location, removal, other copies

function Get-RwJournalActiveCount { param($Journal) @($Journal.tweaks.Keys).Count + @($Journal['shortcuts']).Count }

function Get-RwOtherJournal {
    # In portable mode, a journal in ProgramData means another copy of Rigwright changed this PC.
    if (-not $script:Portable) { return $null }
    $p = Join-Path $script:MachineDataDir 'journal.json'
    $j = ConvertTo-RwHashtable (Read-RwJson $p)
    if (-not $j -or -not $j.Contains('tweaks')) { return $null }
    $n = @($j.tweaks.Keys).Count
    if (-not $n) { return $null }
    return [ordered]@{ path = $p; active = $n; ids = @($j.tweaks.Keys) }
}

function Import-RwJournal {
    # Merge another copy's journal into this one (existing entries win, so originals are never overwritten).
    param([string]$Path = (Join-Path $script:MachineDataDir 'journal.json'))
    $other = ConvertTo-RwHashtable (Read-RwJson $Path)
    if (-not $other) { throw "No journal at $Path" }
    $j = Get-RwJournal
    $n = 0
    foreach ($k in @($other.tweaks.Keys)) { if (-not $j.tweaks.Contains($k)) { $j.tweaks[$k] = $other.tweaks[$k]; $n++ } }
    $j['appx'] = @($j['appx']) + @($other['appx'] | Where-Object { $_ })
    $j['history'] = @(@($other['history']) + @($j['history']) | Where-Object { $_ } | Sort-Object { $_.time })
    Save-RwJournal $j
    Write-RwLog "Imported $n recorded change(s) from $Path - they can be undone from this copy now." 'ok'
    return [ordered]@{ imported = $n }
}

function Remove-RwData {
    # Removes everything Rigwright stored on this PC. Refuses (returns the count) while changes are still applied, unless -Force.
    param([switch]$Force)
    $j = Get-RwJournal
    $active = Get-RwJournalActiveCount $j
    if ($active -and -not $Force) { return [ordered]@{ removed = $false; active = $active } }
    foreach ($s in @($j['shortcuts'])) { if ($s -and $s.path -and (Test-Path -LiteralPath $s.path)) { Remove-Item -LiteralPath $s.path -Force -ErrorAction SilentlyContinue } }
    $targets = @($script:DataDir, (Join-Path $env:LOCALAPPDATA 'Rigwright'))
    if (-not $script:Portable) { $targets += $script:MachineDataDir }
    $done = @()
    foreach ($t in ($targets | Select-Object -Unique)) {
        $full = [IO.Path]::GetFullPath($t)
        # Only ever delete a folder that is clearly Rigwright's own
        if ($full -notmatch '\\Rigwright(\\data)?\\?$' -and $full -notmatch '\\data\\?$') { continue }
        if (Test-Path -LiteralPath $full) {
            Get-ChildItem -LiteralPath $full -Force -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
            $done += $full
        }
    }
    return [ordered]@{ removed = $true; active = $active; folders = $done; note = 'Files in use by the open window are removed when Rigwright closes, or you can delete them by hand.' }
}

# ---------------------------------------------------------------- Start menu shortcut (user-initiated, journaled)

function Get-RwLaunchTarget {
    param([string]$Root = $script:Root)
    $exe = Join-Path $Root 'Rigwright.exe'
    if (Test-Path -LiteralPath $exe) { return [ordered]@{ target = $exe; args = $(if ($script:Portable) { '-Portable' } else { '' }); dir = $Root } }
    $cmd = Join-Path $Root 'Start-Rigwright.cmd'
    return [ordered]@{ target = $cmd; args = $(if ($script:Portable) { '-Portable' } else { '' }); dir = $Root }
}

function New-RwShortcut {
    param([string]$Path, $Launch)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($Path)
    $lnk.TargetPath = $Launch.target
    $lnk.Arguments = $Launch.args
    $lnk.WorkingDirectory = $Launch.dir
    $ico = Join-Path $Launch.dir 'Rigwright.exe'; if (Test-Path -LiteralPath $ico) { $lnk.IconLocation = "$ico,0" }
    $lnk.Description = 'Rigwright - AI-assisted Windows setup, tuning and repair'
    $lnk.Save()
}

function Add-RwStartMenu {
    # Creates one shortcut. No registry keys, services, file associations or uninstall entry.
    param([switch]$AllUsers, [switch]$Move)
    $root = $script:Root
    $moved = $null
    if ($Move) {
        $dest = Join-Path $env:LOCALAPPDATA 'Programs\Rigwright'
        if ([IO.Path]::GetFullPath($root).TrimEnd('\') -ne [IO.Path]::GetFullPath($dest).TrimEnd('\')) {
            if (Test-Path -LiteralPath $dest) { throw "$dest already exists. Remove it first or add the shortcut without moving." }
            Write-RwLog "Copying Rigwright to $dest" 'info'
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            Get-ChildItem -LiteralPath $root -Force | Where-Object { $_.Name -notin '.git', 'dist', 'data' } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $dest -Recurse -Force }
            $moved = [ordered]@{ from = $root; to = $dest }
            $root = $dest
            Write-RwLog "Copied. You can delete the old copy at $($moved.from) after closing Rigwright." 'ok'
        }
    }
    $base = [Environment]::GetFolderPath('Programs'); if ($AllUsers) { $base = [Environment]::GetFolderPath('CommonPrograms') }
    $path = Join-Path $base 'Rigwright.lnk'
    New-RwShortcut -Path $path -Launch (Get-RwLaunchTarget -Root $root)
    $j = Get-RwJournal
    $j['shortcuts'] = @(@($j['shortcuts'] | Where-Object { $_ -and $_.path -ne $path }) + @([ordered]@{ path = $path; target = $root; allUsers = [bool]$AllUsers; moved = $moved; time = (Get-Date).ToString('o') }))
    Save-RwJournal $j
    Add-RwHistory 'startmenu.add' @($path) 'ok' $(if ($moved) { "moved to $($moved.to)" } else { '' })
    Write-RwLog "Start menu shortcut created: $path" 'ok'
    return [ordered]@{ path = $path; moved = $moved }
}

function Remove-RwStartMenu {
    param([string]$Path)
    $j = Get-RwJournal
    $list = @($j['shortcuts'] | Where-Object { $_ })
    if ($Path) { $list = @($list | Where-Object { $_.path -eq $Path }) }
    foreach ($s in $list) {
        if (Test-Path -LiteralPath $s.path) { Remove-Item -LiteralPath $s.path -Force; Write-RwLog "Removed shortcut $($s.path)" 'ok' }
        if ($s.moved -and $s.moved.to -and (Test-Path -LiteralPath $s.moved.to)) {
            if ([IO.Path]::GetFullPath($script:Root).TrimEnd('\') -eq [IO.Path]::GetFullPath($s.moved.to).TrimEnd('\')) {
                Write-RwLog "Not removing $($s.moved.to): Rigwright is running from it. Delete it after closing Rigwright." 'warn'
            } else { Remove-Item -LiteralPath $s.moved.to -Recurse -Force -ErrorAction SilentlyContinue; Write-RwLog "Removed copied folder $($s.moved.to)" 'ok' }
        }
    }
    $j['shortcuts'] = @($j['shortcuts'] | Where-Object { $_ -and ($list.path -notcontains $_.path) })
    Save-RwJournal $j
    Add-RwHistory 'startmenu.remove' @($list | ForEach-Object { $_.path }) 'ok'
    return [ordered]@{ removed = @($list).Count }
}

function Get-RwShortcutHealth {
    # Shortcuts whose target folder no longer exists (Rigwright was moved) can be repaired to point here.
    $out = @()
    foreach ($s in @((Get-RwJournal)['shortcuts'])) {
        if (-not $s) { continue }
        $ok = $false
        try { $ok = (Test-Path -LiteralPath $s.path) -and (Test-Path -LiteralPath ((New-Object -ComObject WScript.Shell).CreateShortcut($s.path).TargetPath)) } catch { }
        $out += [ordered]@{ path = $s.path; ok = $ok }
    }
    return ,$out
}

function Repair-RwStartMenu {
    $j = Get-RwJournal
    $n = 0
    foreach ($s in @($j['shortcuts'])) { if ($s) { New-RwShortcut -Path $s.path -Launch (Get-RwLaunchTarget); $s.target = $script:Root; $n++ } }
    Save-RwJournal $j
    Write-RwLog "Repaired $n shortcut(s) to point at $($script:Root)" 'ok'
    return [ordered]@{ repaired = $n }
}

# ---------------------------------------------------------------- update check (opt-in, never downloads)

$script:ReleaseApi = 'https://api.github.com/repos/Subzero121800/RigWright/releases/latest'

function Test-RwUpdate {
    try {
        $r = Invoke-RestMethod -Uri $script:ReleaseApi -Headers @{ 'User-Agent' = "Rigwright/$($script:AppVersion)"; Accept = 'application/vnd.github+json' } -TimeoutSec 10 -UseBasicParsing
    } catch {
        $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        if ($code -eq 404) { return [ordered]@{ ok = $true; newer = $false; current = $script:AppVersion; message = 'No published releases found yet (or the repository is not public).' } }
        throw "Could not reach GitHub: $($_.Exception.Message)"
    }
    $latest = "$($r.tag_name)".TrimStart('v', 'V')
    $newer = $false
    try { $newer = ([version]$latest) -gt ([version]$script:AppVersion) } catch { $newer = $latest -ne $script:AppVersion }
    return [ordered]@{ ok = $true; newer = $newer; current = $script:AppVersion; latest = $latest; url = "$($r.html_url)"; name = "$($r.name)"; published = "$($r.published_at)" }
}
# ---------------------------------------------------------------- custom commands (AI-proposed, user-approved)

function Invoke-RwCommand {
    param([string]$Command)
    Write-RwLog "Running approved command: $Command" 'cmd'
    try {
        $out = & ([scriptblock]::Create($Command)) 2>&1 | Out-String -Width 200
        foreach ($l in ($out -split "`r?`n")) { if ($l.Trim()) { Write-RwLog $l.TrimEnd() 'info' } }
        Write-RwLog 'Command finished' 'ok'
        Add-RwHistory 'command.run' @($Command) 'ok'
    } catch {
        Write-RwLog "Command failed: $($_.Exception.Message)" 'error'
        Add-RwHistory 'command.run' @($Command) 'failed' $_.Exception.Message
    }
}

# ---------------------------------------------------------------- profiles (export / import)

function Export-RwProfile {
    param([string[]]$Tweaks, [string[]]$Apps, [string[]]$Features, [string]$Name = 'My profile')
    [ordered]@{
        format   = 'rigwright-profile'
        version  = 1
        name     = $Name
        created  = (Get-Date).ToString('o')
        computer = $env:COMPUTERNAME
        tweaks   = @($Tweaks)
        apps     = @($Apps)
        features = @($Features)
    }
}

function Invoke-RwProfile {
    # Headless apply (used by -Config on the command line and by the import screen).
    param($Profile, [switch]$DryRun)
    $p = ConvertTo-RwHashtable $Profile
    Write-RwLog "Profile '$($p.name)': $(@($p.tweaks).Count) tweaks, $(@($p.apps).Count) apps, $(@($p.features).Count) features" 'info'
    if ($DryRun) {
        foreach ($item in (Get-RwPlan -Ids @($p.tweaks))) { Write-RwLog "[dry-run] $($item.name)" 'info'; foreach ($c in $item.changes) { Write-RwLog "    $c" 'info' } }
        foreach ($a in @($p.apps)) { Write-RwLog "[dry-run] install $a" 'info' }
        foreach ($f in @($p.features)) { Write-RwLog "[dry-run] enable feature $f" 'info' }
        return
    }
    if (@($p.tweaks).Count) { Invoke-RwTweaks -Ids @($p.tweaks) | Out-Null }
    if (@($p.apps).Count) { Install-RwApps -Ids @($p.apps) -Mode install | Out-Null }
    if (@($p.features).Count) { Set-RwFeatures -Ids @($p.features) -Enable $true | Out-Null }
}

Export-ModuleMember -Function * -Variable AppName, AppVersion, DataDir, Root
