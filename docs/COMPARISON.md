# Rigwright compared with typical Windows tweak tools

Rigwright started from a review of the public issue trackers, forums and documentation of popular Windows
tweak, debloat and setup tools (among them O&O ShutUp10++, Win11Debloat, Sophia Script, privacy.sexy, Winhance,
Winpilot and UniGetUI). This page records what users of such tools praise, what they complain about, and how
Rigwright responds to each point.

## What users like about all-in-one tools (kept and expanded)

| Praised | In Rigwright |
|---|---|
| One free, open-source tool for apps, tweaks, fixes and updates | Same scope, plus debloat, startup, a policy cleaner, history and an AI assistant |
| winget/Chocolatey installs without bundleware | winget first, Chocolatey fallback, per-app installer arguments, full winget search, Updates tab |
| Essential vs. advanced split for beginners | Explicit risk levels, a *recommended* flag and 6 purpose-built presets |
| One-click fixes (Windows Update reset, network reset, SFC/DISM) | 28 fixes, including Defender full and offline scans, which users requested |
| Config export for multi-PC rollouts | JSON profiles, a dry run, and a headless `-Config -Run` with exit codes |

## Common complaints and how Rigwright handles them

| Complaint (recurring across tweak-tool issue trackers) | Rigwright's approach |
|---|---|
| **Undo doesn't really undo.** Undo writes hard-coded "defaults", which leaves policy keys behind and the "managed by your organization" banner. | **State-capture journal**: the true original value is recorded before the first change and restored exactly. Values that didn't exist are deleted. A separate **Policy cleaner** removes leftover policies after a full backup. |
| **Tweaks drift or regress after Windows updates.** Service lists go stale and preference toggles break on new builds. | Live **state detection** for every tweak, plus **drift detection** with one-click reapply. Builds are checked with `minBuild` / `maxBuild`. The services tweak is a short, conservative list of services switched to Manual, not Disabled. |
| **Windows Update broken** by "disable updates" options that leave the update stack half-off. | There is no "disable updates" option. **Protected services** cannot be disabled. Update options are deferral, version pin, pause and "no auto restart", all reversible. |
| **Collateral damage**: VPN without internet after IPv6/Teredo tweaks, Xbox services stuck, Edge removal breaking WebView2 apps | IPv6 is never disabled; there is a "Prefer IPv4" option instead. Xbox packages are marked "check note" and never pre-selected. Edge removal is not offered. Every tweak lists its side effects. The AI can spot a likely culprit in your recent history and suggest undoing it. |
| **Automation hangs / UI freezes** during long jobs | Every operation is a background job, with a live log console, cancellation and a queue for changes. |
| **No visibility into what a tweak does**, no dry run, thin logs | **Exact preview** (current -> new for every value), daily logs, an action history, an exportable system report, and profile dry runs. |
| **`irm \| iex` trust problems and antivirus flags** | Distributed as a release zip with **SHA-256 sums** and a verification script. Nothing is downloaded and executed at runtime. The UI is local only and token-protected. |
| **Explanations too thin** | Every tweak has a plain-language description and side effects. The AI can explain any tweak in context. |
| **Category mistakes, stale app IDs** | The catalog test suite checks every winget ID against the live repository. All are verified for each release. |
| **Title bar clipped / small-screen issues** | Responsive layout that works down to phone width (useful with LAN access). |

## Frequently requested features that are included

- A log console with readable per-step output
- A full Defender scan button
- Disabling Windows Search indexing
- Blocking Chrome's on-device LLM download
- Restoring "managed by organization" back to local (the Policy cleaner)
- Dynamic search of the whole winget repository instead of only a fixed list
- Better updating of installed programs (the Updates tab)

## Ideas borrowed from other tools

| From | Idea |
|---|---|
| O&O ShutUp10++ | Recommended / limited / not-recommended ratings, so every tweak shows its risk level, plus drift detection after feature updates |
| Sophia Script / privacy.sexy | Every change can be reverted, scripts must ship with an undo, and OS build checks |
| Winhance | Reading and showing the live state of each setting |
| Win11Debloat | Conservative defaults, plus optional deprovisioning for new user accounts |
| UniGetUI | An Updates view and search across the whole repository |
| Winpilot ("Clippy") | A built-in assistant, here running on local or LAN models with strict guard rails |

## Not in 1.0 (roadmap)

- **Image builder**: ISO customization, autounattend.xml, `$OEM$`, driver injection.
- **Default User / Sysprep mode**: apply per-user tweaks to new accounts.
- Scoop and more package sources.
- CI that applies and undoes every tweak in Windows Sandbox VMs on each Insider build.
- Localization.
- Code-signed releases and a winget manifest for Rigwright itself.
