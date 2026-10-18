# Privacy

Rigwright is created by Joseph C McGinty Jr. & ResilientMind AI LLC. **It has no telemetry, no analytics, no
accounts and no cloud backend.** It only contacts the internet when you ask it to do something that needs the
internet.

## Network connections Rigwright makes

| When | To | Why |
|---|---|---|
| Installing, upgrading or searching apps | winget sources (Microsoft CDN, msstore), or Chocolatey | to get packages, using winget's or Chocolatey's own connections |
| "Repair winget" when winget is missing | `aka.ms/getwinget` (Microsoft) | to download App Installer |
| Defender scans and signature updates | Microsoft | Windows' own update mechanism |
| AI requests with **Ollama** | the endpoint you set (this PC or your LAN) | the model runs where you choose |
| AI requests with **Claude Code** | **Anthropic**, through your Claude Code login (directly, or from the bridge PC) | inference |
| "Install & connect Claude Code" | winget (Microsoft CDN) for `Anthropic.ClaudeCode`; the Claude sign-in page in your browser | install and sign-in |
| DNS presets / time sync fixes | the DNS or NTP servers you select | as configured |

There are no other outbound connections. The UI loads nothing from the internet: no fonts, CDNs or trackers.

## What is sent to an AI provider

| Provider | What is sent | Where it goes |
|---|---|---|
| **Ollama** | Your message, up to the last 8 messages of the conversation, the Rigwright catalog, and (by default) the PC summary | The Ollama endpoint you set: this PC or a machine on your network. **Nothing leaves your network.** |
| **Claude Code (this PC)** | Your message, up to the last 8 messages, the catalog. The PC summary is included **only** if you turn on *Share ... with Claude* (off by default) | **Anthropic** (Claude), through Claude Code's login on this PC |
| **Claude Code (LAN bridge)** | Same as above | Your bridge PC on the LAN, which forwards it to **Anthropic** |

**The PC summary** contains: OS edition, version and build; hardware maker and model; CPU, RAM and GPU; disk sizes and free space;
laptop or desktop; power plan; uptime; temp-file size; which Rigwright tweaks are applied or reverted; and your last 15 Rigwright
actions. It does not include your computer name, user name, files, documents, browser data, passwords or credentials.

The two sharing switches are in **Settings → AI provider**: one for Ollama (on by default, stays on your network) and one for Claude
(off by default, sent to Anthropic). **View exactly what is sent** shows the full text for the selected provider before you send anything.
With Claude, Anthropic's terms and privacy policy apply to the request.

## What is stored locally

| Location | Contents |
|---|---|
| `C:\ProgramData\Rigwright\` | settings (including the bridge token), the change journal, logs, registry backups |
| `%LOCALAPPDATA%\Rigwright\` | the app window's browser profile, runtime files |
| Browser `localStorage` for the Rigwright page | your selections, filters and AI chat history (the last 40 messages) |
| `~/.rigwright-bridge/token` (bridge PC) | the bridge token |

Delete these folders to remove all Rigwright data. **New conversation** on the AI page clears the stored chat.
