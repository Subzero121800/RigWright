# Catalog format

All catalog files are UTF-8 JSON arrays in `catalog/`. Run `.\tests\Test-Catalog.ps1` after editing them.

## tweaks.json

| Field | Type | Required | Meaning |
|---|---|---|---|
| `id` | string | yes | Unique, `category.name` style, e.g. `privacy.telemetry`. **Never rename a shipped id**: journals and profiles refer to it. |
| `name` | string | yes | Short user-facing title. |
| `category` | string | yes | Group heading in the UI. |
| `risk` | `low` \| `medium` \| `high` | yes | Honest risk rating. Medium and high require confirmation. |
| `recommended` | bool | | Part of the Recommended preset and filter. |
| `description` | string | yes | What it does and why, in plain language. |
| `sideEffects` | string | | Everything a user might notice afterwards. Shown in yellow. |
| `policy` | bool | | `true` if it writes under a `\Policies\` key. Shows a badge about "managed by your organization". |
| `minBuild` / `maxBuild` | int | | Windows build range, e.g. `22000` for Windows 11, `26100` for 24H2. |
| `restart` | `none` \| `explorer` \| `reboot` | | Explorer is restarted automatically. Reboot is announced. |
| `registry` | array | | See below. |
| `services` | array | | `{ "name": "DiagTrack", "startup": "Disabled", "undo": "Automatic" }`. `startup` is one of `Automatic`, `AutomaticDelayedStart`, `Manual`, `Disabled`. |
| `tasks` | array | | `{ "path": "\\Microsoft\\Windows\\...\\", "name": "TaskName", "state": "Disabled" }` |
| `script` | string | | Windows PowerShell 5.1 code run on apply. Engine functions such as `Invoke-RwNative` and `Get-RwWinget` are available. |
| `undoScript` | string | if `script` | Code run on undo. |
| `detect` | string | recommended with `script` | Expression that returns `$true` when the tweak is in effect. |
| `source` | string | | Documentation URL. |

### Registry entries

```json
{ "path": "HKCU\\Software\\...\\Advanced", "name": "HideFileExt", "type": "DWord", "value": 0, "undo": 1 }
{ "path": "HKLM\\SOFTWARE\\Policies\\...", "name": "SomeValue", "delete": true }
```

- `path` may start with `HKLM`, `HKCU`, `HKU` (e.g. `HKU\\.DEFAULT\\...`, `HKU\\S-1-5-20\\...`) or `HKCR`.
  Missing keys are created.
- `type` is one of `DWord`, `QWord`, `String`, `ExpandString`, `Binary` (hex string such as `"9012038010000000"`)
  or `MultiString` (array).
- `undo` is optional. Normally undo restores the journaled original. `undo` is only the fallback when there is
  no journal entry. Omit it (or use `"<delete>"`) when the Windows default is "value absent".
- `delete: true` removes the value on apply.

### Checklist for a new tweak
- [ ] Works on a clean VM of every build in `minBuild..maxBuild`.
- [ ] State reads *applied* after apply and *not applied* after undo.
- [ ] Undo leaves no trace (compare `reg export` before and after).
- [ ] `risk`, `sideEffects` and `policy` are filled in honestly.
- [ ] `source` link included.

## apps.json

```json
{ "id": "videolan.vlc", "name": "VLC", "winget": "VideoLAN.VLC", "category": "Multimedia",
  "choco": "vlc", "description": "Plays almost any video or audio file",
  "extraArgs": "--location \"C:\\Games\"" }
```

- `extraArgs` is optional. It is appended to `winget install`, for installers that otherwise prompt.
- A 12-character uppercase ID (e.g. `9NKSQGP7F2NH`) is treated as a Microsoft Store ID (`--source msstore`).
- `choco` is used as the fallback when winget fails and Chocolatey is installed.

## fixes.json

```json
{ "id": "fix.flushDns", "name": "Flush DNS cache", "category": "Network", "risk": "low",
  "duration": "fast", "description": "...", "script": "Clear-DnsClientCache; \"done\"" }
```

`duration` is one of `fast`, `medium`, `slow`. Output strings are logged.

## features.json

```json
{ "id": "feat.wsl", "name": "Windows Subsystem for Linux", "description": "...",
  "features": ["Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform"],
  "capabilities": [], "script": "optional post-enable code" }
```

`features` are DISM optional features. `capabilities` are Features on Demand (e.g.
`OpenSSH.Server~~~~0.0.1.0`).

## debloat.json

```json
{ "package": "Microsoft.BingNews", "name": "Microsoft News", "category": "Microsoft",
  "safe": true, "note": "", "storeId": "9WZDNCRFHVFW" }
```

`package` may contain wildcards (`*CandyCrush*`). `safe: false` items are never pre-selected and should carry a
`note`. `storeId` lets Rigwright reinstall the app through winget's msstore source.

## presets.json

```json
{ "id": "gaming", "name": "Gaming PC", "description": "...", "tweaks": ["gaming.gameMode", "..."] }
```

## Profiles (user files)

```json
{ "format": "rigwright-profile", "version": 1, "name": "My PC",
  "tweaks": ["..."], "apps": ["winget ids"], "features": ["feat.wsl"] }
```
