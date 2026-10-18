# Rigwright AI: turns plain-English requests into a reviewed, validated proposal.
# Providers: Ollama (local or LAN), Claude Code `claude -p` (local), Claude Code via the
# Rigwright bridge (LAN). The AI never executes anything - it only proposes; the user approves.
# Windows PowerShell 5.1 compatible. ASCII only.

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$script:ProposalSchema = [ordered]@{
    type = 'object'
    properties = [ordered]@{
        summary    = @{ type = 'string' }
        answer     = @{ type = 'string' }
        tweaks     = @{ type = 'array'; items = @{ type = 'object'; properties = [ordered]@{ id = @{ type = 'string' }; reason = @{ type = 'string' } }; required = @('id','reason') } }
        undoTweaks = @{ type = 'array'; items = @{ type = 'object'; properties = [ordered]@{ id = @{ type = 'string' }; reason = @{ type = 'string' } }; required = @('id','reason') } }
        apps       = @{ type = 'array'; items = @{ type = 'object'; properties = [ordered]@{ id = @{ type = 'string' }; reason = @{ type = 'string' } }; required = @('id','reason') } }
        fixes      = @{ type = 'array'; items = @{ type = 'object'; properties = [ordered]@{ id = @{ type = 'string' }; reason = @{ type = 'string' } }; required = @('id','reason') } }
        features   = @{ type = 'array'; items = @{ type = 'object'; properties = [ordered]@{ id = @{ type = 'string' }; reason = @{ type = 'string' } }; required = @('id','reason') } }
        commands   = @{ type = 'array'; items = @{ type = 'object'; properties = [ordered]@{ command = @{ type = 'string' }; explanation = @{ type = 'string' }; risk = @{ type = 'string'; enum = @('low','medium','high') } }; required = @('command','explanation','risk') } }
        warnings   = @{ type = 'array'; items = @{ type = 'string' } }
    }
    required = @('summary','answer','tweaks','undoTweaks','apps','fixes','features','commands','warnings')
}

# Commands matching these are never offered to the user, whatever the model says.
$script:BlockedPatterns = @(
    '(?i)\bformat(\.com)?\s+[a-z]:', '(?i)\bdiskpart\b', '(?i)\bclean\s+all\b', '(?i)Clear-Disk', '(?i)Initialize-Disk',
    '(?i)Remove-Partition', '(?i)\bbcdedit\b.*/delete', '(?i)vssadmin.*delete', '(?i)wmic\s+shadowcopy\s+delete',
    '(?i)\bcipher\s+/w', '(?i)Remove-Item.*\s[''"]?[a-z]:\\?[''"]?\s*(-|$)', '(?i)Remove-Item.*\\Windows\\System32',
    '(?i)rd\s+/s\s+/q\s+[a-z]:\\\s*$', '(?i)takeown.*System32', '(?i)reg\s+delete\s+HKLM\\SYSTEM\b', '(?i)Set-MpPreference.*-DisableRealtimeMonitoring\s+\$?true',
    '(?i)Invoke-Expression.*(DownloadString|irm|Invoke-RestMethod)', '(?i)iex\s*\(.*(DownloadString|irm)', '(?i)\birm\b.*\|\s*iex', '(?i)Stop-Computer', '(?i)shutdown\s+/[sp]'
)

function Get-RwAiContext {
    $cat = Get-RwCatalog
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('TWEAKS (id | name | category | risk | notes):')
    foreach ($t in $cat.tweaks) {
        $note = $t.description; if ($t.sideEffects) { $note += ' SIDE EFFECTS: ' + $t.sideEffects }
        if ($note.Length -gt 160) { $note = $note.Substring(0, 157) + '...' }
        [void]$sb.AppendLine("$($t.id) | $($t.name) | $($t.category) | $($t.risk) | $note")
    }
    [void]$sb.AppendLine(''); [void]$sb.AppendLine('APPS (winget id = name [category]). You may also suggest other exact winget ids if you are confident they exist:')
    foreach ($a in $cat.apps) { [void]$sb.AppendLine("$($a.winget) = $($a.name) [$($a.category)]") }
    [void]$sb.AppendLine(''); [void]$sb.AppendLine('FIXES (id | name | what it does):')
    foreach ($f in $cat.fixes) { [void]$sb.AppendLine("$($f.id) | $($f.name) | $($f.description)") }
    [void]$sb.AppendLine(''); [void]$sb.AppendLine('WINDOWS FEATURES (id | name):')
    foreach ($f in $cat.features) { [void]$sb.AppendLine("$($f.id) | $($f.name)") }
    return $sb.ToString()
}

function Get-RwAiSystemPrompt {
    param([bool]$IncludeSystemInfo = $true)
    $sys = ''
    if ($IncludeSystemInfo) {
        try {
            $i = Get-RwSystemInfo
            $states = Get-RwTweakStates
            $applied = @($states.Keys | Where-Object { $states[$_].state -eq 'applied' }) -join ', '
            $drifted = @($states.Keys | Where-Object { $states[$_].drifted }) -join ', '
            $hist = @((Get-RwJournal)['history'] | Select-Object -Last 15 | ForEach-Object { "$($_.time) $($_.action) [$(@($_.items) -join ', ')] $($_.result)" }) -join "`n"
            $disks = @($i.disks | ForEach-Object { "$($_.drive) $($_.freeGB)/$($_.sizeGB)GB free" }) -join '; '
            $sys = @"
THIS PC:
OS: $($i.os) $($i.displayVersion) build $($i.build) ($($i.edition)), $($i.architecture)
Hardware: $($i.manufacturer) $($i.model); CPU $($i.cpu) ($($i.cores)C/$($i.threads)T); RAM $($i.ramGB) GB ($($i.ramFreeGB) free); GPU $($i.gpu -join ', ')
Disks: $disks; Laptop: $($i.laptop); Power plan: $($i.powerPlan); Uptime: $($i.uptimeHours) h; Temp files: $($i.tempGB) GB
Tweaks currently applied: $applied
Tweaks Windows has reverted (drifted): $drifted
Recent Rigwright actions:
$hist
"@
        } catch { $sys = "THIS PC: (system info unavailable: $($_.Exception.Message))" }
    }
    @"
You are the assistant inside Rigwright, a Windows 10/11 optimization and repair utility.
The user describes a goal or a problem in plain English. You respond ONLY with a JSON object
matching the provided schema. You never execute anything; the user reviews and approves.

Rules:
- Prefer catalog items (tweaks, fixes, features, apps) over custom commands. Use EXACT ids from the catalog.
- "tweaks" = tweaks to apply. "undoTweaks" = applied tweaks that should be reverted (e.g. they likely caused the user's problem).
- Only use "commands" when nothing in the catalog does the job. Commands must be single Windows PowerShell 5.1
  commands/one-liners, non-interactive, and reversible where possible. Rate risk honestly: low (read-only or trivially
  reversible), medium (changes settings), high (could break things or lose data). Never propose disk formatting,
  partition changes, deleting system files, disabling Windows Update/Defender services, or downloading and executing remote scripts.
- Be conservative: do not include high-risk tweaks unless the user clearly asked for that outcome. Mention side effects in "warnings".
- If the user only asks a question, put the explanation in "answer" and leave the action lists empty.
- "answer" is shown to the user: plain, friendly, concise (under 200 words). "summary" is one short line.
- For troubleshooting, look at "Recent Rigwright actions" and applied tweaks - if a tweak plausibly caused the problem, put it in undoTweaks.

$sys

CATALOG:
$(Get-RwAiContext)
"@
}

# ---------------------------------------------------------------- JSON helpers

function ConvertFrom-RwAiJson {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'The AI returned an empty response.' }
    $t = $Text.Trim()
    $t = $t -replace '(?s)^```(?:json)?\s*', '' -replace '(?s)\s*```$', ''
    try { return ($t | ConvertFrom-Json) } catch { }
    $s = $t.IndexOf('{'); $e = $t.LastIndexOf('}')
    if ($s -ge 0 -and $e -gt $s) { try { return ($t.Substring($s, $e - $s + 1) | ConvertFrom-Json) } catch { } }
    # Model answered in prose: wrap it so the user still sees it.
    return [pscustomobject]@{ summary = 'Answer'; answer = $Text; tweaks = @(); undoTweaks = @(); apps = @(); fixes = @(); features = @(); commands = @(); warnings = @('The model did not return structured actions.') }
}

function ConvertTo-RwJsonBody {
    # The leading comma stops PowerShell unrolling the byte[] into separate numbers on output.
    param($Object)
    return ,([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Object -Depth 20 -Compress)))
}

# ---------------------------------------------------------------- Ollama

# Windows PowerShell 5.1 defaults to old TLS versions; allow TLS 1.2 for Ollama behind an HTTPS reverse proxy.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

function Resolve-RwOllamaEndpoint {
    # "10.0.0.5" / "10.0.0.5:11434" / "http://host:11434/" -> "http://host:11434"
    param([string]$Endpoint)
    $e = "$Endpoint".Trim().TrimEnd('/')
    if (-not $e) { $e = 'http://localhost:11434' }
    if ($e -notmatch '^[a-z]+://') { $e = "http://$e" }
    if ($e -match '^[a-z]+://[^/:]+$') { $e = "${e}:11434" }
    return $e
}

function Invoke-RwOllamaRequest {
    # Ollama itself only speaks plain HTTP. If an https:// endpoint fails at the TLS layer, retry over http
    # and say so, instead of surfacing .NET's cryptic "connection was closed ... on a send".
    param([string]$Endpoint, [string]$Path, [string]$Method = 'Get', [byte[]]$Body, [int]$TimeoutSec = 8)
    $ep = Resolve-RwOllamaEndpoint $Endpoint
    $p = @{ Uri = $ep + $Path; Method = $Method; TimeoutSec = $TimeoutSec; UseBasicParsing = $true }
    if ($null -ne $Body) { $p.ContentType = 'application/json; charset=utf-8'; $p.Body = $Body }
    try { return (Invoke-RestMethod @p) }
    catch {
        $msg = $_.Exception.Message
        # Surface Ollama's own error text (e.g. "model not found") instead of a bare status code
        $resp = $null; try { $resp = $_.Exception.Response } catch { }
        if ($resp) {
            $detail = ''; try { $detail = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } catch { }
            try { $detail = ($detail | ConvertFrom-Json).error } catch { }
            if ($detail) { throw "Ollama error ($([int]$resp.StatusCode)): $detail" }
        }
        if ($ep -like 'https://*' -and $msg -match 'underlying connection was closed|SSL|TLS|secure channel') {
            $plain = 'http://' + $ep.Substring(8)
            $p.Uri = $plain + $Path
            try { $r = Invoke-RestMethod @p }
            catch { throw "Could not reach Ollama at $ep (TLS failed) or $plain ($($_.Exception.Message))." }
            Write-RwLog "Ollama answered over plain HTTP. Change the endpoint in Settings to $plain (Ollama does not use https)." 'warn'
            return $r
        }
        if ($msg -match 'Unable to connect|actively refused|timed out|No connection could be made') {
            throw "Cannot reach Ollama at $ep. Check that Ollama is running there, that OLLAMA_HOST=0.0.0.0 is set on that machine, and that port 11434 is open in its firewall. ($msg)"
        }
        throw
    }
}

function Get-RwOllamaModels {
    param([string]$Endpoint)
    $r = Invoke-RwOllamaRequest -Endpoint $Endpoint -Path '/api/tags'
    return ,@($r.models | ForEach-Object { [ordered]@{ name = $_.name; sizeGB = [math]::Round($_.size / 1GB, 1); family = $_.details.family; parameters = $_.details.parameter_size } })
}

function Invoke-RwOllama {
    param([string]$Endpoint, [string]$Model, [string]$System, [object[]]$Messages, [int]$TimeoutSec = 300, [switch]$Json)
    if (-not $Model) {
        $m = Get-RwOllamaModels $Endpoint
        if (-not $m.Count) { throw "No models on Ollama at $Endpoint. Run: ollama pull qwen3:8b" }
        $Model = $m[0].name
    }
    $msgs = @(@{ role = 'system'; content = $System }) + @($Messages)
    $body = [ordered]@{ model = $Model; messages = $msgs; stream = $false; options = @{ temperature = 0.2; num_ctx = 32768 } }
    if ($Json) { $body['format'] = $script:ProposalSchema }
    try {
        $r = Invoke-RwOllamaRequest -Endpoint $Endpoint -Path '/api/chat' -Method Post -Body (ConvertTo-RwJsonBody $body) -TimeoutSec $TimeoutSec
    } catch {
        if ($Json -and $_.Exception.Message -match '\(400\)|Bad Request|format') {
            # Older Ollama builds only accept format = "json"
            $body['format'] = 'json'
            $r = Invoke-RwOllamaRequest -Endpoint $Endpoint -Path '/api/chat' -Method Post -Body (ConvertTo-RwJsonBody $body) -TimeoutSec $TimeoutSec
        } else { throw }
    }
    $content = $r.message.content
    # Reasoning models may prefix <think> blocks
    $content = $content -replace '(?s)<think>.*?</think>', ''
    return [ordered]@{ text = $content; model = $r.model; meta = "Ollama $Model @ $(Resolve-RwOllamaEndpoint $Endpoint)" }
}

# ---------------------------------------------------------------- Claude Code (local)

function Resolve-RwClaudePath {
    param([string]$Path = 'claude')
    if ($Path -and (Test-Path $Path)) { return $Path }
    $c = Get-Command $Path -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in (Get-RwClaudeCandidates)) { if ($p -and (Test-Path $p)) { return $p } }
    throw 'Claude Code CLI not found. Install it from https://claude.com/claude-code or set its path in Settings.'
}

function Invoke-RwClaudeCli {
    # Runs `claude -p` with all tools disabled, the prompt on stdin and a JSON schema for structured output.
    param([string]$ClaudePath, [string]$Model, [string]$System, [string]$Prompt, [int]$TimeoutSec = 300, [switch]$Json)
    $exe = Resolve-RwClaudePath $ClaudePath
    $work = Join-Path $env:TEMP 'rigwright-claude'
    if (-not (Test-Path $work)) { New-Item -ItemType Directory -Force $work | Out-Null }
    $sysFile = Join-Path $work ("sys-{0}.txt" -f [guid]::NewGuid())
    [IO.File]::WriteAllText($sysFile, $System, (New-Object Text.UTF8Encoding($false)))
    $cliArgs = "-p --output-format json --tools `"`" --system-prompt-file `"$sysFile`""
    if ($Json) {
        $schema = (ConvertTo-Json -InputObject $script:ProposalSchema -Depth 20 -Compress).Replace('"', '\"')
        $cliArgs += " --json-schema `"$schema`""
    }
    if ($Model) { $cliArgs += " --model `"$Model`"" }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($exe -like '*.cmd') { $psi.FileName = "$env:SystemRoot\System32\cmd.exe"; $psi.Arguments = "/d /c `"`"$exe`" $cliArgs`"" }
    else { $psi.FileName = $exe; $psi.Arguments = $cliArgs }
    $psi.WorkingDirectory = $work
    $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    try { $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8 } catch { }
    $p = [System.Diagnostics.Process]::Start($psi)
    $in = New-Object IO.StreamWriter($p.StandardInput.BaseStream, (New-Object Text.UTF8Encoding($false)))
    $in.Write($Prompt); $in.Close()
    $outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch { }; Remove-Item $sysFile -Force -ErrorAction SilentlyContinue; throw "Claude Code timed out after $TimeoutSec s" }
    $out = $outTask.Result; $err = $errTask.Result
    Remove-Item $sysFile -Force -ErrorAction SilentlyContinue
    if (-not $out.Trim()) { throw "Claude Code returned nothing (exit $($p.ExitCode)). $err" }
    return $out
}

function ConvertFrom-RwClaudeOutput {
    param([string]$Raw, [string]$Meta)
    $o = $null
    try { $o = $Raw | ConvertFrom-Json } catch { return [ordered]@{ text = $Raw; meta = $Meta } }
    if ($o.is_error) { throw "Claude Code error: $($o.result)" }
    $text = $o.result
    if ($o.structured_output) { $text = ConvertTo-Json -InputObject $o.structured_output -Depth 20 }
    $cost = ''; if ($o.total_cost_usd) { $cost = (' ($' + ('{0:N4}' -f $o.total_cost_usd) + ')') }
    return [ordered]@{ text = $text; meta = "$Meta$cost" }
}

function Invoke-RwClaudeLocal {
    param([string]$ClaudePath, [string]$Model, [string]$System, [string]$Prompt, [int]$TimeoutSec = 300, [switch]$Json)
    $raw = Invoke-RwClaudeCli -ClaudePath $ClaudePath -Model $Model -System $System -Prompt $Prompt -TimeoutSec $TimeoutSec -Json:$Json
    return (ConvertFrom-RwClaudeOutput $raw "Claude Code (local)")
}

# ---------------------------------------------------------------- Claude Code (LAN bridge)

function Invoke-RwClaudeLan {
    param([string]$Endpoint, [string]$Token, [string]$Model, [string]$System, [string]$Prompt, [int]$TimeoutSec = 300, [switch]$Json)
    $body = [ordered]@{ system = $System; prompt = $Prompt; model = $Model; json = [bool]$Json }
    if ($Json) { $body['schema'] = $script:ProposalSchema }
    try {
        $r = Invoke-WebRequest -Uri ($Endpoint.TrimEnd('/') + '/v1/run') -Method Post -UseBasicParsing -TimeoutSec ($TimeoutSec + 15) `
            -Headers @{ Authorization = "Bearer $Token" } -ContentType 'application/json; charset=utf-8' -Body (ConvertTo-RwJsonBody $body)
        $raw = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    } catch [System.Net.WebException] {
        $resp = $_.Exception.Response
        if (-not $resp) { throw "Cannot reach the Claude bridge at $Endpoint ($($_.Exception.Message)). Is claude-bridge.ps1 running and the firewall open?" }
        $code = [int]$resp.StatusCode
        $text = ''; try { $text = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } catch { }
        if ($code -eq 401) { throw 'The Claude bridge rejected the token. Copy it again from the bridge window (or run claude-bridge.ps1 -ShowToken).' }
        if ($code -eq 403) { throw 'The Claude bridge does not allow this PC (-AllowFrom).' }
        $msg = $text; try { $msg = ($text | ConvertFrom-Json).result } catch { }
        throw "Claude bridge error ($code): $msg"
    }
    return (ConvertFrom-RwClaudeOutput $raw "Claude Code (LAN $Endpoint)")
}

# ---------------------------------------------------------------- dispatcher

function Invoke-RwAiRaw {
    param([string]$System, [object[]]$History, [string]$Prompt, [string]$Provider, [switch]$Json)
    $s = Get-RwSettings
    if (-not $Provider) { $Provider = $s.ai.provider }
    # Flatten history into a transcript for the CLI providers
    $transcript = ''
    foreach ($h in @($History)) { if ($h) { $transcript += "[$($h.role)]`n$($h.content)`n`n" } }
    $full = $Prompt; if ($transcript) { $full = "Conversation so far:`n$transcript`n[user]`n$Prompt" }
    switch ($Provider) {
        'ollama' {
            $msgs = @(); foreach ($h in @($History)) { if ($h) { $msgs += @{ role = $h.role; content = $h.content } } }
            $msgs += @{ role = 'user'; content = $Prompt }
            return (Invoke-RwOllama -Endpoint $s.ai.ollama.endpoint -Model $s.ai.ollama.model -System $System -Messages $msgs -TimeoutSec $s.ai.ollama.timeoutSec -Json:$Json)
        }
        'claude-local' { return (Invoke-RwClaudeLocal -ClaudePath $s.ai.claudeLocal.path -Model $s.ai.claudeLocal.model -System $System -Prompt $full -TimeoutSec $s.ai.claudeLocal.timeoutSec -Json:$Json) }
        'claude-lan'   { return (Invoke-RwClaudeLan -Endpoint $s.ai.claudeLan.endpoint -Token $s.ai.claudeLan.token -Model $s.ai.claudeLan.model -System $System -Prompt $full -TimeoutSec $s.ai.claudeLan.timeoutSec -Json:$Json) }
        default { throw "Unknown AI provider '$Provider'" }
    }
}

# ---------------------------------------------------------------- custom command vetting
# This is a filter for KNOWN-dangerous and obfuscated patterns, not a sandbox: PowerShell is too flexible for any
# deny-list to be complete. Anything that is not clearly read-only is flagged, every command is shown in full and
# unticked, and custom commands are off by default.

$script:ObfuscationPatterns = @(
    @{ p = '(?i)\b(powershell|pwsh)(\.exe)?\b'; why = 'starts another PowerShell (can hide an encoded command)' },
    @{ p = '(?i)\bcmd(\.exe)?\s+/[ck]\b'; why = 'starts cmd.exe with a command' },
    @{ p = '(?i)(^|[\s;|(])-(e|ec|en|enc|enco|encod|encode|encoded|encodedc|encodedco|encodedcom|encodedcomm|encodedcomma|encodedcomman|encodedcommand)(\s|:|$)'; why = 'uses -EncodedCommand' },
    @{ p = '(?i)FromBase64String'; why = 'decodes Base64 (hidden payload)' },
    @{ p = '(?i)(^|[^\w-])iex([^\w-]|$)'; why = 'uses iex (Invoke-Expression)' },
    @{ p = '(?i)Invoke-Expression'; why = 'uses Invoke-Expression' },
    @{ p = '(?i)\[\s*(System\.Management\.Automation\.)?scriptblock\s*\]\s*::\s*Create'; why = 'builds a script block from a string' },
    @{ p = '(?i)\.InvokeScript\s*\(|\.NewScriptBlock\s*\(|ExecutionContext\.InvokeCommand'; why = 'invokes code built at runtime' },
    @{ p = '(?i)\bAdd-Type\b'; why = 'compiles code with Add-Type' },
    @{ p = '(?i)DownloadString|DownloadFile|DownloadData|OpenRead\s*\('; why = 'downloads content from the internet' },
    @{ p = '(?i)\bStart-BitsTransfer\b|\bInvoke-WebRequest\b|\bInvoke-RestMethod\b|(^|[^\w-])(iwr|irm|curl|wget|bitsadmin|certutil)([^\w-]|$)'; why = 'downloads content from the internet' },
    @{ p = '(?i)Net\.WebClient|System\.Net\.Http|Net\.Sockets'; why = 'opens network connections' },
    @{ p = '(?i)Reflection\.Assembly|\[\s*Activator\s*\]|Runtime\.InteropServices|VirtualAlloc|GetDelegateForFunctionPointer'; why = 'loads or calls code in memory' },
    @{ p = '(?i)\bmshta\b|\brundll32\b|\bregsvr32\b|\bwscript\b|\bcscript\b|\bInstallUtil\b|\bmsbuild\b'; why = 'uses a script/binary proxy-execution tool' }
)

$script:DeniedCommands = @('Invoke-Expression','Add-Type','Invoke-Command','Start-Job','Register-ScheduledJob','Register-ScheduledTask','New-Service',
    'Set-ExecutionPolicy','Invoke-WebRequest','Invoke-RestMethod','Start-BitsTransfer','New-PSSession','Enter-PSSession','Import-Module','Set-Alias','New-Alias')

$script:ReadOnlyVerbs = @('Get','Test','Measure','Select','Where','Sort','Format','Resolve','Find','Show','Group','Compare','Out','Write','ConvertTo','ConvertFrom','ForEach','Join','Split')
$script:ReadOnlyNatives = @('ipconfig','ping','tracert','pathping','nslookup','netstat','systeminfo','whoami','hostname','driverquery','tasklist','getmac','route','arp')

function Get-RwCommandVerdict {
    # Returns @{ refused; reasons; readOnly }. Refused commands are never run, even if the user ticks them.
    param([string]$Command)
    $reasons = New-Object System.Collections.ArrayList
    foreach ($p in $script:BlockedPatterns) { if ($Command -match $p) { [void]$reasons.Add('matches a known destructive pattern'); break } }
    foreach ($o in $script:ObfuscationPatterns) { if ($Command -match $o.p) { [void]$reasons.Add($o.why) } }
    if (([regex]::Matches($Command, '`')).Count -gt 2) { [void]$reasons.Add('uses many backtick escapes (obfuscation)') }
    if ($Command -match '\$\{?env:\w*\}?\s*\[|\[char\]\s*\d+\s*\+|-join\s*\(\s*\[char') { [void]$reasons.Add('assembles text from characters (obfuscation)') }

    $readOnly = $true
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Command, [ref]$tokens, [ref]$errs)
    if ($errs -and $errs.Count) { [void]$reasons.Add("does not parse: $($errs[0].Message)") }
    else {
        foreach ($cmd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $first = $cmd.CommandElements[0]
            if ($cmd.InvocationOperator -ne 'Unknown' -and -not ($first -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $first.StringConstantType -eq 'BareWord')) {
                [void]$reasons.Add('runs a command whose name is computed at runtime'); $readOnly = $false; continue
            }
            if (-not ($first -is [System.Management.Automation.Language.StringConstantExpressionAst])) { [void]$reasons.Add('runs a command whose name is computed at runtime'); $readOnly = $false; continue }
            $name = $first.Value
            $alias = Get-Alias -Name $name -ErrorAction SilentlyContinue
            if ($alias) { $name = $alias.ResolvedCommandName }
            if ($script:DeniedCommands -contains $name) { [void]$reasons.Add("uses $name") }
            $leaf = ($name -replace '^.*[\\/]', '') -replace '\.(exe|com|cmd|bat)$', ''
            $verb = ($name -split '-')[0]
            if (-not (($name -match '-' -and $script:ReadOnlyVerbs -contains $verb) -or $script:ReadOnlyNatives -contains $leaf.ToLower())) { $readOnly = $false }
            if ($verb -eq 'Out' -and $name -notin 'Out-String','Out-Host','Out-Null') { $readOnly = $false }
        }
        foreach ($t in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeExpressionAst] -or $n -is [System.Management.Automation.Language.TypeConstraintAst] }, $true)) {
            if ("$($t.TypeName.FullName)" -match '(?i)scriptblock|reflection|assembly|activator|marshal|webclient|net\.http|powershell$|runspace') { [void]$reasons.Add("uses the .NET type [$($t.TypeName.FullName)]") }
        }
        # Any assignment, redirection to a file or method call that is not on a read-only cmdlet output makes it a change
        if ($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FileRedirectionAst] -or $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true).Count) { $readOnly = $false }
    }
    $uniq = @($reasons | Select-Object -Unique)
    return [ordered]@{ refused = ($uniq.Count -gt 0); reasons = $uniq; readOnly = ($readOnly -and $uniq.Count -eq 0) }
}

function Test-RwBlockedCommand {
    param([string]$Command)
    return [bool](Get-RwCommandVerdict $Command).refused
}

function Resolve-RwAiProposal {
    # Validates every suggestion against the catalog and safety rules before the user sees it.
    param($Raw)
    $cat = Get-RwCatalog
    $s = Get-RwSettings
    $states = Get-RwTweakStates
    $res = [ordered]@{
        summary = "$($Raw.summary)"; answer = "$($Raw.answer)"
        tweaks = @(); undoTweaks = @(); apps = @(); fixes = @(); features = @(); commands = @(); warnings = @(@($Raw.warnings) | Where-Object { $_ })
    }
    foreach ($x in @($Raw.tweaks)) {
        if (-not $x) { continue }
        $t = $cat.tweaks | Where-Object { $_.id -eq $x.id } | Select-Object -First 1
        if (-not $t) { $res.warnings += "Ignored unknown tweak id '$($x.id)'."; continue }
        $st = $states[$t.id]
        $res.tweaks += [ordered]@{ id = $t.id; name = $t.name; risk = $t.risk; reason = "$($x.reason)"; state = $st.state; sideEffects = $t.sideEffects }
    }
    foreach ($x in @($Raw.undoTweaks)) {
        if (-not $x) { continue }
        $t = $cat.tweaks | Where-Object { $_.id -eq $x.id } | Select-Object -First 1
        if (-not $t) { continue }
        $res.undoTweaks += [ordered]@{ id = $t.id; name = $t.name; risk = $t.risk; reason = "$($x.reason)"; state = $states[$t.id].state }
    }
    foreach ($x in @($Raw.apps)) {
        if (-not $x -or -not $x.id) { continue }
        $a = $cat.apps | Where-Object { $_.winget -eq $x.id -or $_.id -eq $x.id -or $_.name -eq $x.id } | Select-Object -First 1
        if ($a) { $res.apps += [ordered]@{ id = $a.winget; name = $a.name; reason = "$($x.reason)"; verified = $true } }
        elseif ($x.id -match '^[\w\-\.\+]+$') { $res.apps += [ordered]@{ id = $x.id; name = $x.id; reason = "$($x.reason)"; verified = $false } }
    }
    foreach ($x in @($Raw.fixes)) {
        if (-not $x) { continue }
        $f = $cat.fixes | Where-Object { $_.id -eq $x.id } | Select-Object -First 1
        if ($f) { $res.fixes += [ordered]@{ id = $f.id; name = $f.name; reason = "$($x.reason)"; risk = $f.risk } }
    }
    foreach ($x in @($Raw.features)) {
        if (-not $x) { continue }
        $f = $cat.features | Where-Object { $_.id -eq $x.id } | Select-Object -First 1
        if ($f) { $res.features += [ordered]@{ id = $f.id; name = $f.name; reason = "$($x.reason)" } }
    }
    foreach ($x in @($Raw.commands)) {
        if (-not $x -or -not $x.command) { continue }
        if (-not $s.safety.allowAiCustomCommands) { $res.warnings += 'The AI suggested a custom command, but custom commands are turned off in Settings.'; continue }
        $v = Get-RwCommandVerdict "$($x.command)"
        $risk = "$($x.risk)"; if ($risk -notin 'low','medium','high') { $risk = 'high' }
        # The model's own rating is only trusted for clearly read-only commands
        if (-not $v.readOnly -and $risk -eq 'low') { $risk = 'medium' }
        if ($v.refused) { $risk = 'high' }
        $res.commands += [ordered]@{ command = "$($x.command)"; explanation = "$($x.explanation)"; risk = $risk; blocked = $v.refused; reasons = @($v.reasons); readOnly = $v.readOnly }
        if ($v.refused) { $res.warnings += "Refused a command the AI suggested (flagged: $(@($v.reasons) -join '; ')). Known-dangerous patterns are flagged and refused, but no filter can catch everything - review every custom command." }
    }
    return $res
}

function Invoke-RwAi {
    param([string]$Prompt, [object[]]$History, [string]$Provider)
    $s = Get-RwSettings
    if (-not $Provider) { $Provider = $s.ai.provider }
    $sys = Get-RwAiSystemPrompt -IncludeSystemInfo (Test-RwShareSystemInfo $Provider)
    $r = Invoke-RwAiRaw -System $sys -History $History -Prompt $Prompt -Provider $Provider -Json
    $obj = ConvertFrom-RwAiJson $r.text
    $p = Resolve-RwAiProposal $obj
    $p['provider'] = $r.meta
    return $p
}

function Test-RwCloudProvider { param([string]$Provider) return ($Provider -like 'claude*') }

function Test-RwShareSystemInfo {
    # Local Ollama and cloud (Claude via Anthropic) have separate consent switches; cloud defaults to off.
    param([string]$Provider)
    $s = Get-RwSettings
    if (Test-RwCloudProvider $Provider) { return [bool]$s.ai.shareWithCloud }
    return [bool]$s.ai.includeSystemInfo
}

function Get-RwAiPreview {
    # Exactly what will be sent with each request (shown by "View what is sent").
    param([string]$Provider)
    $s = Get-RwSettings
    if (-not $Provider) { $Provider = $s.ai.provider }
    $share = Test-RwShareSystemInfo $Provider
    $dest = switch ($Provider) {
        'ollama'       { "Ollama at $(Resolve-RwOllamaEndpoint $s.ai.ollama.endpoint) - stays on the machines you control" }
        'claude-local' { 'Anthropic (Claude), through Claude Code on this PC' }
        'claude-lan'   { "Anthropic (Claude), through the Claude Code bridge at $($s.ai.claudeLan.endpoint)" }
        default        { $Provider }
    }
    return [ordered]@{ provider = $Provider; destination = $dest; cloud = (Test-RwCloudProvider $Provider); includesSystemInfo = $share
                       systemPrompt = (Get-RwAiSystemPrompt -IncludeSystemInfo $share); plus = 'Your message and up to the last 8 messages of this conversation.' }
}

# ---------------------------------------------------------------- Claude Code: status and one-click setup

function Get-RwClaudeCandidates {
    @("$env:USERPROFILE\.local\bin\claude.exe", "$env:LOCALAPPDATA\Microsoft\WinGet\Links\claude.exe", "$env:ProgramFiles\WinGet\Links\claude.exe",
      "$env:APPDATA\npm\claude.cmd", "$env:LOCALAPPDATA\Programs\claude\claude.exe", "$env:LOCALAPPDATA\AnthropicClaude\claude.exe") +
    @(Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Anthropic.ClaudeCode*\claude.exe", "$env:ProgramFiles\WinGet\Packages\Anthropic.ClaudeCode*\claude.exe" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}

function Update-RwProcessPath {
    $env:Path = ([Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')).Trim(';')
}

function Get-RwClaudeStatus {
    $st = [ordered]@{ installed = $false; path = ''; version = ''; loggedIn = $false; authMethod = ''; email = ''; onPath = $false }
    Update-RwProcessPath
    $exe = $null
    try { $exe = Resolve-RwClaudePath ((Get-RwSettings).ai.claudeLocal.path) } catch { }
    if (-not $exe) { return $st }
    $st.installed = $true; $st.path = $exe
    $st.onPath = [bool](Get-Command claude -ErrorAction SilentlyContinue)
    try { $st.version = "$(& $exe --version 2>$null)".Trim() } catch { }
    try {
        $j = (& $exe auth status --json 2>$null | Out-String) | ConvertFrom-Json
        $st.loggedIn = [bool]$j.loggedIn; $st.authMethod = "$($j.authMethod)"; $st.email = "$($j.email)"
    } catch { }
    return $st
}

function Add-RwUserPath {
    param([string]$Dir)
    $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @("$cur" -split ';' | Where-Object { $_ })
    if ($parts -notcontains $Dir) {
        [Environment]::SetEnvironmentVariable('Path', (@($parts) + $Dir) -join ';', 'User')
        Write-RwLog "Added $Dir to your PATH (new PowerShell windows will find 'claude')" 'ok'
    } else { Write-RwLog "$Dir is already on your PATH" 'ok' }
    Update-RwProcessPath
}

function Install-RwClaudeCode {
    # One click: install Claude Code, put it on PATH, sign in with your Claude subscription, point Rigwright at it, test.
    param([int]$LoginWaitSec = 600)
    $st = Get-RwClaudeStatus
    if (-not $st.installed) {
        Write-RwLog 'Installing Claude Code (winget package Anthropic.ClaudeCode)...' 'info'
        $wg = Get-RwWinget
        if (-not $wg) { Install-RwWinget; $wg = Get-RwWinget }
        if ($wg) { [void](Invoke-RwNative $wg 'install --id Anthropic.ClaudeCode --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity') }
        $st = Get-RwClaudeStatus
        if (-not $st.installed) {
            $npm = Get-Command npm -ErrorAction SilentlyContinue
            if ($npm) {
                Write-RwLog 'winget did not provide Claude Code - trying npm (@anthropic-ai/claude-code)' 'warn'
                [void](Invoke-RwNative $npm.Source 'install -g @anthropic-ai/claude-code')
                $st = Get-RwClaudeStatus
            }
        }
        if (-not $st.installed) { throw 'Claude Code could not be installed automatically. Install it from https://claude.com/claude-code, then press the button again.' }
        Write-RwLog "Claude Code installed: $($st.version)" 'ok'
    } else { Write-RwLog "Claude Code already installed: $($st.version) ($($st.path))" 'ok' }

    Add-RwUserPath (Split-Path -Parent $st.path)

    if (-not $st.loggedIn) {
        Write-RwLog 'Opening Claude sign-in. Log in with your Claude subscription in the browser window that opens.' 'info'
        $cmd = "& '$($st.path)' auth login --claudeai; Write-Host ''; Write-Host 'You can close this window and return to Rigwright.' -ForegroundColor Green; Start-Sleep 8"
        Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoProfile', '-Command', $cmd) | Out-Null
        $deadline = (Get-Date).AddSeconds($LoginWaitSec)
        $n = 0
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 3
            $st = Get-RwClaudeStatus
            if ($st.loggedIn) { break }
            $n++; if ($n % 10 -eq 0) { Write-RwLog 'Still waiting for you to finish signing in...' 'info' }
        }
        if (-not $st.loggedIn) { throw 'Sign-in was not completed. Press the button again to retry.' }
    }
    Write-RwLog "Signed in to Claude ($($st.authMethod)$(if ($st.email) { ', ' + $st.email }))" 'ok'

    $saved = Save-RwSettings @{ ai = @{ provider = 'claude-local'; claudeLocal = @{ path = $st.path } } }
    Write-RwLog 'Rigwright now uses Claude Code on this PC as its AI provider.' 'ok'
    $t = Test-RwAiProvider -Provider 'claude-local'
    Write-RwLog "Test OK in $($t.ms) ms - Claude replied '$($t.reply)'" 'ok'
    return [ordered]@{ status = $st; test = $t; provider = $saved.ai.provider }
}

function Test-RwAiProvider {
    param([string]$Provider)
    $s = Get-RwSettings
    if (-not $Provider) { $Provider = $s.ai.provider }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    if ($Provider -eq 'claude-lan') {
        $h = Invoke-RestMethod -Uri ($s.ai.claudeLan.endpoint.TrimEnd('/') + '/v1/health') -Headers @{ Authorization = "Bearer $($s.ai.claudeLan.token)" } -TimeoutSec 8 -UseBasicParsing
        if (-not $h.ok) { throw "Bridge reachable but Claude Code is not ready: $($h.error)" }
    }
    $r = Invoke-RwAiRaw -System 'You are a connectivity test. Reply with exactly: OK' -History @() -Prompt 'Reply with OK' -Provider $Provider
    $sw.Stop()
    return [ordered]@{ ok = $true; provider = $r.meta; reply = "$($r.text)".Trim(); ms = $sw.ElapsedMilliseconds }
}

Export-ModuleMember -Function *
