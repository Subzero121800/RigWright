# Contributing to Rigwright

Thanks for helping make Windows less annoying for everyone. Rigwright is created and maintained by
**Joseph C McGinty Jr. & ResilientMind AI LLC**, and it welcomes contributions of every size: a new app in the
catalog, a tweak, a bug report, docs, translations or code.

By participating you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Maintenance policy

- **Catalog PRs** (apps, tweaks, fixes, debloat entries) are reviewed **weekly**.
- **Engine, server, AI and security changes** are made or approved by the maintainer only. Please open an issue to discuss them before writing code.
- Security reports follow [SECURITY.md](SECURITY.md) and are handled first.
- Issues labeled `good first issue` are small catalog additions that make a good first contribution.

## Ground rules

Rigwright's reputation depends on **never breaking someone's PC**. Every contribution must respect these
rules.

1. **Reversible.** A tweak must be undoable. Registry, service and scheduled-task changes are undone
   automatically through the journal. If a tweak uses `script`, it **must** also provide an `undoScript` and,
   ideally, a `detect` script.
2. **Honest.** Set `risk` truthfully (`low` / `medium` / `high`). Put every user-visible downside in
   `sideEffects`. Set `"policy": true` if the tweak writes under a `\Policies\` key.
3. **Targeted.** Declare `minBuild` / `maxBuild` if a tweak only applies to some Windows versions.
4. **No updater or security sabotage.** Do not add tweaks that disable Windows Update, its repair service,
   Defender or Store infrastructure. The engine refuses to disable protected services anyway.
5. **No remote code.** Tweaks, fixes and features must not download and execute scripts from the internet.
6. **Evidence.** Link to Microsoft documentation or another reliable source in `source`. "It feels faster" is
   not evidence. Placebo tweaks will be declined.
7. **ASCII only** in `.ps1` / `.psm1` files. Windows PowerShell 5.1 reads BOM-less files as ANSI.

## Adding to the catalog

Catalog files live in `catalog/`. The full format is in [docs/TWEAK-SCHEMA.md](docs/TWEAK-SCHEMA.md).

### Add an app

Add an object to `catalog/apps.json`:

```json
{ "id": "videolan.vlc", "name": "VLC", "winget": "VideoLAN.VLC", "category": "Multimedia",
  "choco": "vlc", "description": "Plays almost any video or audio file" }
```

Confirm that the ID exists with `winget show --id VideoLAN.VLC --exact`, then run `.\tests\Test-Catalog.ps1 -Winget`.

### Add a tweak

```json
{
  "id": "explorer.compactView",
  "name": "Compact view in File Explorer",
  "category": "Explorer",
  "risk": "low",
  "recommended": false,
  "description": "Reduces the spacing between items in File Explorer.",
  "registry": [
    { "path": "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced", "name": "UseCompactMode", "type": "DWord", "value": 1, "undo": 0 }
  ],
  "restart": "explorer",
  "minBuild": 22000,
  "source": "https://learn.microsoft.com/..."
}
```

## Development setup

You need Windows 10/11 and Windows PowerShell 5.1. The .NET 9 SDK is optional and only needed for `desktop/`.

```powershell
git clone <your fork>
cd Rigwright
.\Rigwright.ps1              # run from source
.\tests\Test-Catalog.ps1     # fast checks
.\tests\Test-Server.ps1      # API and security smoke test (makes no system changes)
.\tests\Test-CommandSafety.ps1  # AI custom-command filter
.\tests\Test-Paths.ps1       # spaces, non-ASCII, other drives, OneDrive, read-only (elevated)
```

**Please test tweaks in a VM or Windows Sandbox** (enable it on the Windows features page). Apply, check that
the state reads *applied*, undo, and check that it reads *not applied* again.

### Code style

- **PowerShell:** 4-space indentation, `Verb-RwNoun` function names, `Write-RwLog` for all output, and no aliases
  in committed code. Must be compatible with Windows PowerShell 5.1: no ternary operator, `??`, `?.` or
  `-Parallel`.
- **JavaScript:** vanilla ES2020, no external libraries or CDNs (the UI runs under a strict CSP). Always escape
  dynamic text with `esc()`.
- **C#:** default .NET formatting, nullable enabled.

## Pull requests

1. Fork, create a branch (`feat/...`, `fix/...`, `catalog/...`), and keep each PR focused on one change.
2. Run both test scripts. CI runs them on `windows-latest`.
3. Fill in the PR template: what changed, how you tested it, and which Windows builds you tested on.
4. For tweaks, include before/after evidence (registry export, screenshot or documentation link).
5. Update `CHANGELOG.md` under **Unreleased**.

## Reporting bugs and asking for features

Use the issue templates. For bugs, please attach the **system report** (History & undo → Action log → Export
system report) and the day's log from `C:\ProgramData\Rigwright\logs`. Remove anything you consider private
first.

**Security issues must not be reported in public issues.** See [SECURITY.md](SECURITY.md).

## License of contributions

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE) of this
project, Copyright (c) 2026 Joseph C McGinty Jr. & ResilientMind AI LLC.
