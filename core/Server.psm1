# Rigwright local server: serves the web UI and a token-protected JSON API.
# Every slow or state-changing operation runs as a background job so the UI never freezes.
# Changes are serialized through a single-runspace pool (one change at a time, others queue).
# Windows PowerShell 5.1 compatible. ASCII only.

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$script:Jobs     = [hashtable]::Synchronized(@{})
$script:JobSeq   = 0
$script:Running  = $false
$script:LastPing = Get-Date

# Job type -> PowerShell code run inside a worker runspace. $a holds the request arguments.
$script:JobCode = @{
    sysinfo         = 'Get-RwSystemInfo'
    tweakStates     = 'Get-RwTweakStates'
    plan            = 'Get-RwPlan -Ids @($a.ids) -Undo:([bool]$a.undo)'
    tweaksApply     = 'Invoke-RwTweaks -Ids @($a.ids)'
    tweaksUndo      = 'Invoke-RwTweaks -Ids @($a.ids) -Undo'
    reapplyDrifted  = '$s = Get-RwTweakStates; $ids = @($s.Keys | Where-Object { $s[$_].drifted }); if ($ids.Count) { Invoke-RwTweaks -Ids $ids } else { Write-RwLog "Nothing has drifted." "ok" }'
    undoAll         = '$ids = @((Get-RwJournal).tweaks.Keys); if ($ids.Count) { Invoke-RwTweaks -Ids $ids -Undo } else { Write-RwLog "No Rigwright tweaks are recorded in the journal." "ok" }'
    appsInstalled   = 'Get-RwInstalledApps'
    appsUpgradable  = 'Get-RwUpgradableApps'
    appsSearch      = 'Find-RwApp -Query $a.query'
    appsInstall     = 'Install-RwApps -Ids @($a.ids) -Mode install'
    appsUninstall   = 'Install-RwApps -Ids @($a.ids) -Mode uninstall'
    appsUpgrade     = 'Install-RwApps -Ids @($a.ids) -Mode upgrade'
    appsUpgradeAll  = 'Update-RwAllApps'
    featureStates   = 'Get-RwFeatureStates'
    featuresEnable  = 'Set-RwFeatures -Ids @($a.ids) -Enable $true'
    featuresDisable = 'Set-RwFeatures -Ids @($a.ids) -Enable $false'
    fixes           = 'Invoke-RwFixes -Ids @($a.ids)'
    appx            = 'Get-RwAppxInventory'
    appxRemove      = 'Remove-RwAppx -Packages @($a.packages) -IncludeProvisioned:([bool]$a.provisioned)'
    appxRestore     = 'Restore-RwAppx -Packages @($a.packages)'
    startup         = 'Get-RwStartupItems'
    startupSet      = 'Set-RwStartupItem -Name $a.name -Key $a.key -Enabled ([bool]$a.enabled)'
    policies        = 'Get-RwPolicyValues'
    policiesRemove  = 'Remove-RwPolicyValues -Entries @($a.entries)'
    restorePoint    = 'New-RwRestorePoint -Description $(if ($a.description) { $a.description } else { "Rigwright manual checkpoint" })'
    restorePoints   = 'Get-RwRestorePoints'
    registryBackup  = 'Backup-RwRegistry'
    report          = 'Export-RwReport'
    profileApply    = 'Invoke-RwProfile -Profile $a.profile -DryRun:([bool]$a.dryRun)'
    command         = 'if (Test-RwBlockedCommand $a.command) { throw "This command is blocked by Rigwright safety rules." }; Invoke-RwCommand -Command $a.command'
    ai              = 'Invoke-RwAi -Prompt $a.prompt -History @($a.history) -Provider $a.provider'
    aiTest          = 'Test-RwAiProvider -Provider $a.provider'
    otherJournal    = 'Get-RwOtherJournal'
    importJournal   = 'Import-RwJournal'
    removeData      = 'Remove-RwData -Force:([bool]$a.force)'
    startMenuAdd    = 'Add-RwStartMenu -AllUsers:([bool]$a.allUsers) -Move:([bool]$a.move)'
    startMenuRemove = 'Remove-RwStartMenu -Path $a.path'
    startMenuHealth = 'Get-RwShortcutHealth'
    startMenuRepair = 'Repair-RwStartMenu'
    checkUpdates    = 'Test-RwUpdate'
    aiPreview       = 'Get-RwAiPreview -Provider $a.provider'
    claudeStatus    = 'Get-RwClaudeStatus'
    claudeSetup     = 'Install-RwClaudeCode'
    driveCleanup    = 'if ("$($a.drive)" -notmatch ''^[A-Za-z]:?$'') { throw ''Invalid drive'' }; $d = $a.drive.Substring(0,1); Start-Process "$env:SystemRoot\System32\cleanmgr.exe" "/d $d"; Write-RwLog "Disk Cleanup opened for ${d}:" ''ok'''
    restartPc       = 'Write-RwLog ''Restarting in 60 seconds (run shutdown /a to cancel)'' ''warn''; & "$env:SystemRoot\System32\shutdown.exe" /r /t 60 /c "Restart requested from Rigwright" | Out-Null'
    firmwareRestart = 'Write-RwLog ''Restarting into UEFI firmware settings in 30 seconds'' ''warn''; & "$env:SystemRoot\System32\shutdown.exe" /r /fw /t 30 | Out-Null'
    aiModels        = '$s = Get-RwSettings; $ep = $(if ($a.endpoint) { $a.endpoint } else { $s.ai.ollama.endpoint }); Get-RwOllamaModels -Endpoint $ep'
    applyProposal   = @'
$p = $a.proposal
$s = Get-RwSettings
if ($s.safety.restorePointBeforeChanges) { New-RwRestorePoint 'Rigwright: before AI-assisted changes' | Out-Null }
if (@($p.undoTweaks).Count) { Invoke-RwTweaks -Ids @($p.undoTweaks) -Undo -NoRestorePoint | Out-Null }
if (@($p.tweaks).Count)     { Invoke-RwTweaks -Ids @($p.tweaks) -NoRestorePoint | Out-Null }
if (@($p.fixes).Count)      { Invoke-RwFixes -Ids @($p.fixes) | Out-Null }
if (@($p.features).Count)   { Set-RwFeatures -Ids @($p.features) -Enable $true | Out-Null }
if (@($p.apps).Count)       { Install-RwApps -Ids @($p.apps) -Mode install | Out-Null }
foreach ($c in @($p.commands)) {
    if (-not $c) { continue }
    if (Test-RwBlockedCommand $c) { Write-RwLog "Blocked: $c" 'error'; continue }
    if (-not $s.safety.allowAiCustomCommands) { Write-RwLog 'Custom commands are disabled in Settings.' 'warn'; break }
    Invoke-RwCommand -Command $c
}
Write-RwLog 'All approved actions finished.' 'ok'
'@
}

# Job types that change the system: run one at a time.
$script:MutatingTypes = @('tweaksApply','tweaksUndo','reapplyDrifted','undoAll','appsInstall','appsUninstall','appsUpgrade','appsUpgradeAll',
    'featuresEnable','featuresDisable','fixes','appxRemove','appxRestore','startupSet','policiesRemove','restorePoint','registryBackup',
    'profileApply','command','applyProposal','claudeSetup','restartPc','firmwareRestart','importJournal','removeData','startMenuAdd','startMenuRemove','startMenuRepair')

function New-RwRunspacePool {
    param([int]$Max)
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    try { $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass } catch { }
    $iss.ImportPSModule(@((Join-Path $PSScriptRoot 'Engine.psm1'), (Join-Path $PSScriptRoot 'AI.psm1')))
    $pool = [runspacefactory]::CreateRunspacePool(1, $Max, $iss, $Host)
    $pool.ApartmentState = 'STA'
    $pool.Open()
    return $pool
}

$script:WorkerScript = @'
param($job, $code, $a)
$job.status = 'running'
$job.started = (Get-Date).ToString('o')
$log = $job.log
Set-RwLogSink ({ param($l) [void]$log.Add($l) }.GetNewClosure())
try {
    $out = @(& ([scriptblock]::Create($code)))
    if ($out.Count -eq 1) { $job.result = $out[0] } elseif ($out.Count -gt 1) { $job.result = $out } else { $job.result = $null }
    $job.status = 'done'
} catch {
    $job.error = $_.Exception.Message
    [void]$log.Add(('{0} [ERROR] {1}' -f (Get-Date -Format 'HH:mm:ss'), $_.Exception.Message))
    $job.status = 'failed'
} finally {
    $job.ended = (Get-Date).ToString('o')
    Set-RwLogSink $null
}
'@

function Start-RwJob {
    param([string]$Type, $JobArgs)
    if (-not $script:JobCode.ContainsKey($Type)) { throw "Unknown job type '$Type'" }
    $script:JobSeq++
    $id = 'j{0}' -f $script:JobSeq
    $job = [hashtable]::Synchronized(@{
        id = $id; type = $Type; status = 'queued'; created = (Get-Date).ToString('o'); started = $null; ended = $null
        log = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        result = $null; error = $null; label = "$($JobArgs.label)"
    })
    $pool = $script:ReadPool; if ($script:MutatingTypes -contains $Type) { $pool = $script:WritePool }
    $ps = [powershell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($script:WorkerScript).AddArgument($job).AddArgument($script:JobCode[$Type]).AddArgument($JobArgs)
    $job.ps = $ps
    $job.handle = $ps.BeginInvoke()
    $script:Jobs[$id] = $job
    return $id
}

function Get-RwJobView {
    param($Job, [int]$Since = 0, [switch]$Brief)
    $count = $Job.log.Count
    $v = [ordered]@{ id = $Job.id; type = $Job.type; label = $Job.label; status = $Job.status; created = $Job.created; started = $Job.started; ended = $Job.ended; logCount = $count; error = $Job.error }
    if (-not $Brief) {
        $lines = @(); if ($Since -lt $count) { $lines = @($Job.log.GetRange($Since, $count - $Since)) }
        $v['log'] = $lines
        $v['result'] = $Job.result
    }
    return $v
}

function Update-RwJobs {
    foreach ($j in @($script:Jobs.Values)) {
        if ($j.ps -and $j.status -in @('done','failed','cancelled') -and $j.handle.IsCompleted) {
            try { [void]$j.ps.EndInvoke($j.handle) } catch { }
            $j.ps.Dispose(); $j.ps = $null
        }
    }
    # keep the 200 most recent jobs
    if ($script:Jobs.Count -gt 200) {
        $old = @($script:Jobs.Values | Where-Object { $_.status -in 'done','failed','cancelled' } | Sort-Object created | Select-Object -First ($script:Jobs.Count - 200))
        foreach ($o in $old) { $script:Jobs.Remove($o.id) }
    }
}

# ---------------------------------------------------------------- HTTP helpers

function Send-RwResponse {
    param($Ctx, [int]$Status = 200, [byte[]]$Bytes, [string]$ContentType = 'application/json; charset=utf-8')
    $res = $Ctx.Response
    $res.StatusCode = $Status
    $res.ContentType = $ContentType
    $res.Headers['Cache-Control'] = 'no-store'
    $res.Headers['X-Content-Type-Options'] = 'nosniff'
    $res.Headers['Referrer-Policy'] = 'no-referrer'
    if ($ContentType -like 'text/html*') {
        $res.Headers['Content-Security-Policy'] = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'"
    }
    if (-not $Bytes) { $Bytes = [byte[]]@() }
    $res.ContentLength64 = $Bytes.Length
    try { $res.OutputStream.Write($Bytes, 0, $Bytes.Length) } catch { }
    try { $res.OutputStream.Close() } catch { }
}

function Send-RwJson {
    param($Ctx, $Object, [int]$Status = 200)
    $json = ConvertTo-Json -InputObject $Object -Depth 25 -Compress
    if ($null -eq $json) { $json = 'null' }
    Send-RwResponse $Ctx $Status ([Text.Encoding]::UTF8.GetBytes($json))
}

function Read-RwBody {
    param($Ctx)
    $req = $Ctx.Request
    if (-not $req.HasEntityBody) { return $null }
    $sr = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
    $text = $sr.ReadToEnd(); $sr.Close()
    if (-not $text.Trim()) { return $null }
    return ($text | ConvertFrom-Json)
}

$script:Mime = @{ '.html' = 'text/html; charset=utf-8'; '.js' = 'application/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'
                  '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.ico' = 'image/x-icon'; '.json' = 'application/json; charset=utf-8'; '.woff2' = 'font/woff2' }

function Send-RwStatic {
    param($Ctx, [string]$Path)
    $webRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $PSScriptRoot) 'web'))
    if ($Path -eq '/' -or -not $Path) { $Path = '/index.html' }
    $full = [IO.Path]::GetFullPath((Join-Path $webRoot ($Path.TrimStart('/') -replace '/', '\')))
    if (-not $full.StartsWith($webRoot, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
        Send-RwResponse $Ctx 404 ([Text.Encoding]::UTF8.GetBytes('Not found')) 'text/plain'; return
    }
    $ext = [IO.Path]::GetExtension($full).ToLower()
    $ct = $script:Mime[$ext]; if (-not $ct) { $ct = 'application/octet-stream' }
    Send-RwResponse $Ctx 200 ([IO.File]::ReadAllBytes($full)) $ct
}

# ---------------------------------------------------------------- routing

function Invoke-RwRoute {
    param($Ctx)
    $req = $Ctx.Request
    $path = $req.Url.AbsolutePath
    $method = $req.HttpMethod

    # DNS-rebinding protection: in local mode only accept loopback host names.
    if (-not $script:Lan) {
        $hostOnly = ($req.UserHostName -replace ':\d+$', '').ToLower()
        if ($hostOnly -notin @('127.0.0.1','localhost','[::1]')) { Send-RwResponse $Ctx 403 ([Text.Encoding]::UTF8.GetBytes('Forbidden host')) 'text/plain'; return }
    }

    if (-not $path.StartsWith('/api/')) { Send-RwStatic $Ctx $path; return }

    # One-time launch codes are exchanged for the session token, so the real token never
    # appears on a command line or in browser history.
    if ($path -eq '/api/session' -and $method -eq 'POST') {
        $b = Read-RwBody $Ctx
        $code = "$($b.code)"
        $now = Get-Date
        $hit = $script:LaunchCodes | Where-Object { $_.code -eq $code -and $_.expires -gt $now } | Select-Object -First 1
        $script:LaunchCodes = @($script:LaunchCodes | Where-Object { $_.code -ne $code -and $_.expires -gt $now })
        if ($hit) { Send-RwJson $Ctx @{ token = $script:Token } } else { Start-Sleep -Milliseconds 400; Send-RwJson $Ctx @{ error = 'invalid or expired code' } 401 }
        return
    }

    $tok = $req.Headers['X-Rigwright-Token']
    if (-not $tok -or $tok -ne $script:Token) { Send-RwJson $Ctx @{ error = 'unauthorized' } 401; return }
    $script:LastPing = Get-Date

    switch -Regex ($path) {
        '^/api/info$' {
            $i = Get-RwInfo
            $b = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
            Send-RwJson $Ctx ([ordered]@{ app = $i; isAdmin = (Test-RwAdmin); lan = $script:Lan; computer = $env:COMPUTERNAME
                build = [int]$b.CurrentBuild; displayVersion = $b.DisplayVersion; product = $(if ([int]$b.CurrentBuild -ge 22000) { $b.ProductName.Replace('Windows 10', 'Windows 11') } else { $b.ProductName }); pid = $PID })
            return
        }
        '^/api/catalog$' { Send-RwJson $Ctx (Get-RwCatalog -Reload); return }
        '^/api/settings$' {
            if ($method -eq 'POST') { Send-RwJson $Ctx (Save-RwSettings (Read-RwBody $Ctx)) } else { Send-RwJson $Ctx (Get-RwSettings) }
            return
        }
        '^/api/journal$' { Send-RwJson $Ctx (Get-RwJournal); return }
        '^/api/log$' {
            $f = Join-Path (Get-RwInfo).dataDir ('logs\rigwright-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
            $t = ''; if (Test-Path $f) { $t = (Get-Content $f -Tail 1000 -Encoding UTF8) -join "`n" }
            Send-RwResponse $Ctx 200 ([Text.Encoding]::UTF8.GetBytes($t)) 'text/plain; charset=utf-8'
            return
        }
        '^/api/open$' {
            # Opens a legacy control panel / folder. Only whitelisted targets.
            $b = Read-RwBody $Ctx
            $allowed = @{
                control = 'control.exe'; compmgmt = 'compmgmt.msc'; devmgmt = 'devmgmt.msc'; diskmgmt = 'diskmgmt.msc'; services = 'services.msc'
                eventvwr = 'eventvwr.msc'; taskschd = 'taskschd.msc'; gpedit = 'gpedit.msc'; regedit = 'regedit.exe'; network = 'ncpa.cpl'
                power = 'powercfg.cpl'; programs = 'appwiz.cpl'; sound = 'mmsys.cpl'; system = 'sysdm.cpl'; region = 'intl.cpl'; time = 'timedate.cpl'
                firewall = 'firewall.cpl'; printers = 'control printers'; restore = 'rstrui.exe'; msconfig = 'msconfig.exe'; resmon = 'resmon.exe'
                taskmgr = 'taskmgr.exe'; users = 'netplwiz.exe'; mouse = 'main.cpl'; internet = 'inetcpl.cpl'; datadir = (Get-RwInfo).dataDir
            }
            $target = $allowed["$($b.target)"]
            if (-not $target) { Send-RwJson $Ctx @{ error = 'not allowed' } 400; return }
            if ($target -eq 'control printers') { Start-Process control.exe -ArgumentList 'printers' }
            elseif ($target -like '*.msc') { Start-Process mmc.exe -ArgumentList $target }
            elseif ($target -like '*.cpl') { Start-Process control.exe -ArgumentList $target }
            else { Start-Process $target }
            Send-RwJson $Ctx @{ ok = $true }
            return
        }
        '^/api/jobs$' {
            if ($method -eq 'POST') {
                $b = Read-RwBody $Ctx
                try { $id = Start-RwJob -Type $b.type -JobArgs $b.args; Send-RwJson $Ctx @{ id = $id } }
                catch { Send-RwJson $Ctx @{ error = $_.Exception.Message } 400 }
            } else {
                Update-RwJobs
                $list = @($script:Jobs.Values | Sort-Object created -Descending | Select-Object -First 50 | ForEach-Object { Get-RwJobView $_ -Brief })
                Send-RwJson $Ctx $list
            }
            return
        }
        '^/api/jobs/(j\d+)/cancel$' {
            $j = $script:Jobs[$Matches[1]]
            if ($j -and $j.ps -and $j.status -in 'queued','running') { try { [void]$j.ps.BeginStop($null, $null) } catch { }; $j.status = 'cancelled'; [void]$j.log.Add("$(Get-Date -Format 'HH:mm:ss') [WARN] Cancelled by user") }
            Send-RwJson $Ctx @{ ok = $true }
            return
        }
        '^/api/jobs/(j\d+)$' {
            $j = $script:Jobs[$Matches[1]]
            if (-not $j) { Send-RwJson $Ctx @{ error = 'no such job' } 404; return }
            $since = 0; [void][int]::TryParse($req.QueryString['since'], [ref]$since)
            Send-RwJson $Ctx (Get-RwJobView $j -Since $since)
            Update-RwJobs
            return
        }
        '^/api/launchcode$' {
            $c = New-RwLaunchCode
            $urls = @("http://127.0.0.1:$($script:Port)/?code=$c")
            if ($script:Lan) {
                foreach ($ip in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' })) {
                    $urls += "http://$($ip.IPAddress):$($script:Port)/?code=$c"
                }
            }
            Send-RwJson $Ctx @{ code = $c; urls = $urls; expiresInSec = 300 }
            return
        }
        '^/api/ping$' { Send-RwJson $Ctx @{ ok = $true; time = (Get-Date).ToString('o') }; return }
        '^/api/shutdown$' { Send-RwJson $Ctx @{ ok = $true }; $script:Running = $false; return }
        default { Send-RwJson $Ctx @{ error = "unknown endpoint $path" } 404; return }
    }
}

$script:LaunchCodes = @()

function New-RwToken {
    param([int]$Bytes = 32)
    $b = New-Object byte[] $Bytes
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    ([Convert]::ToBase64String($b)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-RwLaunchCode {
    $c = New-RwToken 18
    $script:LaunchCodes = @($script:LaunchCodes) + @([pscustomobject]@{ code = $c; expires = (Get-Date).AddMinutes(5) })
    return $c
}

function Get-RwFreePort {
    $l = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); return $p
}

function Start-RwServer {
    param([int]$Port = 0, [switch]$Lan, [string]$ReadyFile, [int]$WatchPid = 0)
    if ($Port -le 0) { $Port = Get-RwFreePort }
    $script:Token = New-RwToken
    $script:Port = $Port
    $script:Lan = [bool]$Lan
    $script:ReadPool  = New-RwRunspacePool -Max 4
    $script:WritePool = New-RwRunspacePool -Max 1

    $listener = New-Object System.Net.HttpListener
    if ($Lan) {
        $listener.Prefixes.Add("http://+:$Port/")
        $rule = "Rigwright UI (TCP $Port)"
        if (-not (Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $rule -Direction Inbound -Protocol TCP -LocalPort $Port -Profile Private -Action Allow | Out-Null
        }
    } else {
        $listener.Prefixes.Add("http://127.0.0.1:$Port/")
        $listener.Prefixes.Add("http://localhost:$Port/")
    }
    $listener.Start()
    $script:Running = $true
    $url = "http://127.0.0.1:$Port/"
    Write-RwLog "Rigwright server listening on $url (LAN: $Lan)" 'ok'
    if ($ReadyFile) {
        # The ready file lives in the user's LocalAppData (private to this user) and carries a first launch code only.
        Set-Content -Path $ReadyFile -Value (@{ port = $Port; url = $url; pid = $PID; code = (New-RwLaunchCode) } | ConvertTo-Json -Compress) -Encoding ASCII
    }

    try {
        while ($script:Running) {
            $task = $listener.GetContextAsync()
            while (-not $task.Wait(500)) {
                if (-not $script:Running) { break }
                if ($WatchPid -gt 0 -and -not (Get-Process -Id $WatchPid -ErrorAction SilentlyContinue)) {
                    Write-RwLog 'Launcher closed - shutting down' 'info'; $script:Running = $false; break
                }
                $idle = (Get-RwSettings).ui.autoExitMinutes
                if ($idle -gt 0 -and ((Get-Date) - $script:LastPing).TotalMinutes -gt $idle) {
                    Write-RwLog "No UI activity for $idle minutes - shutting down" 'info'; $script:Running = $false
                }
            }
            if (-not $script:Running) { break }
            $ctx = $task.Result
            try { Invoke-RwRoute $ctx }
            catch {
                Write-RwLog "API error: $($_.Exception.Message)" 'error'
                try { Send-RwJson $ctx @{ error = $_.Exception.Message } 500 } catch { }
            }
        }
    } finally {
        $listener.Stop(); $listener.Close()
        foreach ($j in @($script:Jobs.Values)) { if ($j.ps) { try { $j.ps.Stop() } catch { } } }
        $script:ReadPool.Close(); $script:WritePool.Close()
        if ($ReadyFile) { Remove-Item $ReadyFile -Force -ErrorAction SilentlyContinue }
        Write-RwLog 'Rigwright server stopped' 'info'
    }
}

Export-ModuleMember -Function Start-RwServer, Start-RwJob, Get-RwFreePort, New-RwToken
