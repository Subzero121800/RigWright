# Changelog

All notable changes to Rigwright are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-10-18 (public release)

The first public release combines the initial build below with these changes.

### Added
- Tweaks: throttle Delivery Optimization in the background, disable Windows Spotlight on the desktop, hide the
  "Learn about this picture" icon, disable the Connected Devices Platform service (side effects documented), and run
  Storage Sense weekly (#2, #3, #4, #6, #7).
- Apps: eM Client, Betterbird, Chocolatey, Chocolatey GUI, Shutter Encoder and Avidemux (#9, #10, #11).
- Debloat: 15 MSI and Acer preinstalled-app entries with verified package names and Store ids (#13).
- Fix: "Reset Microsoft Edge WebView2 runtime" (#14).
- Interactive screenshot gallery (docs/gallery.html, served by GitHub Pages) and README slideshow.
- **One-click "Install & connect Claude Code"** for people with a Claude subscription. It installs the official
  `Anthropic.ClaudeCode` winget package, adds it to PATH, opens `claude auth login --claudeai`, waits for sign-in,
  switches Rigwright to Claude Code and tests it. The Settings page shows live Claude Code status.
- **"View what is sent"** shows the exact AI context for the selected provider. A per-provider data-flow note sits
  under the provider selector.
- Separate sharing switches: PC summary with Ollama (on, stays on your network) and with Claude (off by default,
  sent to Anthropic).
- Parser-based custom-command vetting (`Get-RwCommandVerdict`). It refuses runtime-computed command names, nested
  shells, `-EncodedCommand` prefixes, `FromBase64String`, `iex` and aliases, `[scriptblock]::Create`, `Add-Type`,
  downloads, reflection, proxy-execution tools, and backtick/`[char]` obfuscation. Covered by
  `tests/Test-CommandSafety.ps1` (34 bypasses).
- Dashboard: disk-health cards labeled with drive letters and model; Secure Boot off is an amber card with
  steps and "Restart to firmware settings"; every warning has an action (Clean up drive, Clean temp files,
  Restart...); new "Recent changes" feed with Undo.
- Tweaks: sticky category jump bar, plus collapsible categories that remember their state.
- Optional Authenticode signing in `tools/Build-Release.ps1` (`-CertThumbprint`), with signature checks in
  `tools/Verify-Release.ps1`.
- Screenshot tool scrubs private IPs and email addresses from published captures.
- `docs/GOVERNED-AGENTS.md` write-up.
- **Portable mode** (`-Portable`): data lives in `.\data` beside the app, with a first-run warning. Read-only
  locations are refused with a clear message.
- In portable mode, a journal left in ProgramData by another copy is detected and can be imported so those
  changes can still be undone.
- **Settings → Rigwright data:** "Add to Start menu" (one `.lnk`; optional all-users and move to
  `%LocalAppData%\Programs`; journaled and undoable, with broken-shortcut repair) and "Remove Rigwright data from
  this PC" (warns when changes are still applied: Undo all / Remove anyway / Cancel).
- Opt-in "Check GitHub for new releases on startup" (off by default) and "Check for updates" in About. It never
  downloads anything.
- Release build is **self-contained by default**, for **x64 and ARM64**, as a plain folder (no scripts extracted
  to %TEMP%). It writes stable asset names, and adds a `SIGNED` marker when signed; launchers then use
  `RemoteSigned` instead of `Bypass`.
- The desktop app falls back to the browser when WebView2 is missing, and supports `-Portable`.
- `tools/Publish-Release.ps1` (GitHub Releases), `tools/New-WingetManifest.ps1` (portable winget manifest),
  `tools/Setup-GitHubRepo.ps1` (labels, good-first-issues, branch protection, secret scanning, About sidebar),
  `tools/make_demo_gif.py` (README demo).
- `tests/Test-Paths.ps1`: spaces, non-ASCII, other drive, OneDrive and read-only locations.
- Debloat false-positive issue template; system report field in bug reports; maintenance policy in CONTRIBUTING.
- LinkedIn link in the About page and README.
- Fixes & tools: star any fix or classic Windows tool to pin it to a **Favorites** section at the top, plus a
  **Most common** section (repair system files, reset network, reset Windows Update, clean temp, flush DNS,
  Defender quick scan).
- Every table sorts by clicking a column header (natural A-Z and numeric order); Install apps are alphabetical
  within each category.
- README gallery: window-sized 2x screenshots that follow the viewer's GitHub theme
  (`tools/capture_screenshots.py --gallery`).
- Clear message when the UAC prompt is declined.

### Changed
- Custom AI commands are **off by default** for new installs. They are always unticked, shown in an
  "Unvetted command (not from the catalog)" section, and described as "flagged and refused", not "blocked".
  Non-read-only commands are rated at least medium risk.
- Privacy wording is now provider-specific everywhere (UI, README, AI.md, PRIVACY.md). Only Ollama keeps data
  on your network.
- Debloat and README now say removed Store apps are reinstalled, not state-restored.
- Contrast raised to WCAG AA in both themes (muted text, light accent, primary buttons).
- US spelling throughout.
- "Exactly what will change" uses a non-breaking → between old and new values.
- The sidebar AI pill follows the provider actually in use on the AI page.
- Buy Me a Coffee link (README, About page, GitHub Sponsor button via `.github/FUNDING.yml`).
- Page-by-page screenshot collection in `docs/screenshots` (dark and light), plus `tools/capture_screenshots.py`
  to regenerate it.
- Action bars (Install, Tweaks, Debloat, Policy cleaner) are docked as a footer under the page instead of
  floating over the content.
- Windows features shows "needs admin" instead of "unavailable" when Rigwright is not elevated.

### Fixed
- Ollama and the Claude LAN bridge received an unrolled byte array instead of JSON (400 "cannot unmarshal
  number").
- Ollama `https://` endpoints now fall back to `http://` with a clear message. Bare IPs get `http://` and `:11434`
  added, TLS 1.2 is enabled, and Ollama's own error text is shown.
- A page that was still loading could overwrite the page you had navigated to with an error.

### Initial build (pre-release)

The original feature set. Created by Joseph C McGinty Jr. & ResilientMind AI LLC.

### Added

**Engine**
- Tweak engine with **state-capture undo**: the original registry values, service start types and scheduled-task
  states are journaled before the first change.
- Exact change preview: current value → new value for every key, service and task.
- Live tweak state (applied / not applied / partial / not for this PC) and **drift detection** with one-click
  reapply.
- OS build checks (`minBuild` / `maxBuild`), protected services, and an automatic restore point before every batch.
- Background job system with a live Activity console, cancellation and serialized changes. The UI never freezes.

**Catalog**
- 68 tweaks in 14 categories, including AI & Copilot opt-outs (Recall, Click to Do, Copilot, Notepad/Paint AI,
  Chrome on-device model, Edge sidebar).
- 6 presets: Recommended, Gaming PC, Maximum privacy, Work laptop, Old/slow PC, Developer.
- 127 curated apps in 11 categories, with verified winget IDs and Chocolatey fallback.
- Install / uninstall / upgrade, an Updates tab, search across the whole winget repository, and per-app installer
  arguments.
- 28 fixes and tools, plus 26 classic Windows tools one click away.
- Windows features page, including OpenSSH capabilities.

**Pages**
- Debloat with real installed-app inventory, 72 known-bloat entries with safety ratings, optional
  deprovisioning, and restore.
- Startup apps manager using the Task Manager mechanism.
- Policy cleaner for "managed by your organization", with automatic `.reg` backup.
- History & undo: original values, per-item undo, Undo everything, action log, restore points, registry
  backup, log viewer and system report.
- Profiles: export/import JSON with dry run, plus the headless `-Config -Run/-DryRun` command line.

**AI assistant**
- Providers: **Ollama** (local/LAN), **Claude Code** (`claude -p`, local) and **Claude Code over LAN** via the new
  cross-platform `bridge/claude-bridge.ps1`.
- Structured JSON proposals validated against the catalog. Custom commands are blocklisted on both the AI and
  server side, and nothing runs without approval.

**Security, apps and packaging**
- Local server with 256-bit session token, single-use launch codes, DNS-rebinding protection and strict CSP.
- Opt-in LAN access for Private network profiles.
- Optional **Rigwright.exe** desktop shell (.NET 9 + WebView2).
- Release build script with SHA-256 checksums, and a verification script.
- Tests: catalog validation (including live winget ID checks) and an end-to-end API/security smoke test.
- Documentation: README, LICENSE (MIT), Code of Conduct, Contributing, Security policy, architecture, AI guide,
  tweak schema, comparison, troubleshooting and privacy.
