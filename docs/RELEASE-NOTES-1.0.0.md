# Rigwright 1.0.0

Set up, tune and repair Windows 10/11 with changes you can preview, record and undo. Includes an optional AI
assistant: fully local with Ollama, or Claude through Claude Code.

Created by **Joseph C McGinty Jr. & ResilientMind AI LLC** · [LinkedIn](https://www.linkedin.com/in/joseph-mcginty-jr/) · MIT License

## Download

| Your PC | File |
|---|---|
| Most Windows PCs (Intel / AMD) | **Rigwright-win-x64.zip** |
| Snapdragon / Copilot+ PCs (ARM) | **Rigwright-win-arm64.zip** |

1. Download the zip, right-click it, choose **Extract All...**, and pick a folder such as `C:\Tools`.
2. Open the `Rigwright` folder and double-click **Rigwright.exe**.
3. Choose **Yes** when Windows asks for permission. Rigwright needs it to change settings.

Rigwright is portable. **It installs nothing**: no installer, no services, and nothing left running when you
close it. If Windows SmartScreen says "Windows protected your PC" (this build is not yet code-signed), click
**More info → Run anyway**. To verify the download, run `tools\Verify-Release.ps1`, or compare the zip's SHA-256
with `Rigwright-1.0.0-SHA256SUMS.txt`.

## Highlights

- **Exact undo.** The original value of every registry value, service and scheduled task is recorded before
  anything changes, and Undo puts back exactly that.
- **Exact preview.** See every key and value, current → new, before you apply.
- **Live state and drift detection.** See which tweaks are applied, and which ones Windows quietly reverted.
- **AI assistant** (optional). Describe what you want in plain English and get a checklist of catalog items.
  The AI only proposes; nothing runs until you approve it.
  - **Ollama:** runs on this PC or your network. Nothing leaves your network.
  - **Claude Code:** your request is sent to Anthropic. PC details are shared only if you allow it.
    There is a one-click **Install & connect Claude Code** for Claude subscribers.
- **Favorites and Most common** on Fixes & tools, and every table sorts by clicking a column header.
- 68 tweaks, 127 apps (winget), 28 fixes, Windows features, debloat, startup apps, a policy cleaner for
  "managed by your organization", profiles and a headless command line.

## What Rigwright changes and how to undo it

| What | How it changes Windows | How to undo |
|---|---|---|
| **Tweaks** | Registry values, service start types, scheduled tasks; a few run a documented script (e.g. power plan) | **History & undo → Undo** (one item or everything). It restores the recorded original. Script tweaks run their documented undo script. |
| **Every batch of changes** | Creates a **System Restore point** first | **History & undo → Restore points → Open System Restore** |
| **Debloat** | Removes Store apps (optionally deprovisions them for new users) | **Debloat → Restore removed...** reinstalls them. This is a reinstall, not an exact state restore. Deprovisioned apps return for new users only after a reinstall. |
| **Install apps** | Installs through winget (Chocolatey as fallback) | **Install apps → Uninstall** |
| **Windows features** | Enables or disables optional features | Toggle them back on the same page (a restart may be needed) |
| **Startup apps** | Uses the same on/off switch as Task Manager | Toggle back on the same page, or in Task Manager |
| **Policy cleaner** | Removes Group Policy values you select | Double-click the automatic `.reg` backup in the Rigwright data folder |
| **Fixes** | One-off repairs (SFC/DISM, reset Windows Update or network, DNS presets...) | Described on each fix; DNS presets have "Set DNS: automatic" |
| **Start menu shortcut** (optional) | Creates one `.lnk`, nothing else | **History & undo → Shortcuts → Undo** |
| **Rigwright's own data** | `C:\ProgramData\Rigwright` (or `.\data` in portable mode) | **Settings → Remove Rigwright data from this PC** (it checks for changes that are still applied first) |

Rigwright never disables Windows Update, its repair service, Defender or the Microsoft Store, whatever a tweak
or the AI asks.

## Requirements

Windows 10 21H2+ or Windows 11 (x64 or ARM64). Windows PowerShell 5.1 is built in. No .NET install is needed.
winget is required for app installs, and Rigwright offers to install it if it is missing. The AI is optional.

## Known limitations

- This release is not yet code-signed, so SmartScreen shows "unknown publisher" (see above).
- The custom-command filter flags and refuses known-dangerous patterns, but it is a filter, not a sandbox.
  Custom AI commands are therefore off by default.
- There is no image builder (MicroWin-style ISO customization) yet. It is on the roadmap.

Full details: [CHANGELOG.md](https://github.com/Subzero121800/RigWright/blob/main/CHANGELOG.md) ·
[Privacy](https://github.com/Subzero121800/RigWright/blob/main/docs/PRIVACY.md) ·
[Security](https://github.com/Subzero121800/RigWright/blob/main/SECURITY.md)

If Rigwright saved you time, you can [support Joseph C McGinty Jr. on Buy Me a Coffee](https://buymeacoffee.com/jcinc).
