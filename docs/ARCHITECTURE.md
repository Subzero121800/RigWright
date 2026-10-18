# Architecture

Rigwright has three parts: the PowerShell **engine**, a local **server** with background jobs, and a web **UI**.
The UI is shown either in an app-mode browser window or in the `Rigwright.exe` WebView2 shell.

```
 ┌──────────────── you (unelevated) ─────────────────┐        ┌──────────── elevated ─────────────┐
 │                                                   │        │                                   │
 │  Rigwright.exe (WebView2)  or  Edge --app window  │  HTTP  │  Rigwright.ps1 -Server            │
 │  web/index.html + app.js + app.css                ├───────►│   Server.psm1  (HttpListener)     │
 │  - token in sessionStorage                        │ 127.0. │     ├─ auth / routing / static    │
 │  - polls /api/jobs/<id>?since=n for live logs     │  0.1   │     ├─ read pool  (4 runspaces)   │
 │                                                   │        │     └─ write pool (1 runspace)    │
 └───────────────────────────────────────────────────┘        │   Engine.psm1   AI.psm1           │
                                                              └──────┬───────────────┬────────────┘
                                                                     │               │
                                     registry / services / tasks /   │               │ HTTP or process
                                     winget / DISM / Appx / powercfg │               ▼
                                                                     ▼     Ollama │ claude -p │ bridge
                                                       C:\ProgramData\Rigwright (settings, journal, logs, backups)
```

## Startup sequence

1. `Rigwright.ps1` (unelevated) starts `powershell -File Rigwright.ps1 -Server -ReadyFile <path> -WatchPid <pid>`
   elevated and hidden. The desktop shell does the same thing.
2. The server picks a free loopback port, generates a session token, and writes a **ready file** containing the
   port and a **single-use launch code**. It never writes the token itself.
3. The launcher opens `http://127.0.0.1:<port>/?code=<code>`. The page exchanges the code for the token
   (`POST /api/session`), removes the code from the address bar and stores the token in `sessionStorage`.
4. When the launcher process exits, the server notices through `WatchPid` and shuts down.

## Engine (`core/Engine.psm1`)

| Area | Key functions |
|---|---|
| Catalog | `Get-RwCatalog`, `Get-RwTweak` |
| Tweaks | `Get-RwTweakState(s)`, `Get-RwPlan`, `Invoke-RwTweak(s)`, `Test-RwTweakApplicable` |
| Journal | `Get-RwJournal`, `Save-RwJournal`, `Add-RwHistory` |
| Primitives | `Get/Set/Remove-RwRegValue`, `Get/Set-RwServiceStartup`, `Get/Set-RwTaskState` |
| Safety | `New-RwRestorePoint`, `Backup-RwRegistry`, `$ProtectedServices` |
| Apps | `Get-RwInstalledApps` (`winget export`), `Find-RwApp`, `Get-RwUpgradableApps`, `Install-RwApps`, `Update-RwAllApps` |
| Other pages | `Get/Set-RwFeatures`, `Invoke-RwFixes`, `Get/Remove/Restore-RwAppx`, `Get/Set-RwStartupItem`, `Get/Remove-RwPolicyValues` |
| Profiles | `Export-RwProfile`, `Invoke-RwProfile` |

### How undo works
When a tweak is first applied, `Invoke-RwTweak` records the current state of every registry value, service and
task it touches under `journal.tweaks[<id>].original`. Undo restores those values exactly. A value that did not
exist before is deleted rather than set to a default.

If there is no journal entry (for example, the tweak was applied by another tool), undo falls back to the
tweak's declared `undo` values, then to deleting the value. For script tweaks, `undoScript` runs. A successful
undo removes the journal entry.

### How state and drift detection work
`Get-RwTweakState` compares the live values with the tweak's targets and runs its `detect` script if it has one.
The result is *applied*, *not-applied* or *partial*. A tweak counts as **drifted** when it has a journal entry
(Rigwright applied it) but the live state is no longer *applied*. That usually means Windows reverted it during
an update.

## Server (`core/Server.psm1`)

`HttpListener` handles requests one at a time on the main thread. Anything slow or state-changing becomes a
**job**:

- Read-only jobs (system info, states, previews, AI calls) run in a pool of 4 runspaces.
- **Mutating** jobs run in a pool with a single runspace, so changes queue and never overlap.
- Each job has a synchronized log list. The engine's `Write-RwLog` writes to it through `Set-RwLogSink`, and the
  UI fetches new lines incrementally.
- Job types are a fixed allow-list (`$JobCode`). The client cannot send code.

## AI (`core/AI.psm1`)

1. `Get-RwAiSystemPrompt` builds the system prompt from the rules, a system snapshot (hardware, applied and
   drifted tweaks, recent actions) and a compact catalog.
2. `Invoke-RwAiRaw` calls one of three providers:
   - **Ollama:** `POST /api/chat` with `format` set to the proposal JSON schema. Falls back to `"json"` for older
     builds.
   - **Claude Code (local):** `claude -p --output-format json --tools "" --system-prompt-file … --json-schema …`.
     The prompt is sent on stdin, and the working directory is an empty temp folder.
   - **Claude Code (LAN):** `POST <bridge>/v1/run`. The bridge runs the same command on the remote machine.
3. `Resolve-RwAiProposal` validates the result: catalog IDs only, apps marked verified or unverified, risk
   normalized, and custom commands vetted by `Get-RwCommandVerdict` (parser- and pattern-based; flagged and refused, not sandboxed).

## UI (`web/`)

Single-page vanilla JS with no dependencies. It uses hash routing (`#/tweaks`), stores per-viewer conveniences
(selections, filters, chat history) in `localStorage`, and keeps the session token in `sessionStorage` only.

## Data on disk

| Path | Contents |
|---|---|
| `C:\ProgramData\Rigwright\settings.json` | settings, including the AI endpoints and bridge token |
| `C:\ProgramData\Rigwright\journal.json` | original values, removed apps, action history (last 500) |
| `C:\ProgramData\Rigwright\logs\rigwright-YYYY-MM-DD.log` | daily logs |
| `C:\ProgramData\Rigwright\backups\` | registry and policy `.reg` exports |
| `%LOCALAPPDATA%\Rigwright\browser`, `webview2` | the app window's private browser profile |
