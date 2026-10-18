# Security Policy

Rigwright runs with administrator rights and changes system settings, so we take security seriously.
This document explains how to report a vulnerability and how Rigwright is designed to protect you.

## Supported versions

| Version | Supported |
|---|---|
| 1.0.x (latest) | Yes |
| < 1.0 | No |

Security fixes are released as patch versions. Please always use the latest release.

## Reporting a vulnerability

**Do not open a public issue for security problems.** Use one of these instead:

1. **GitHub private vulnerability reporting.** On the repository, go to the **Security** tab and choose
   **Report a vulnerability**. This is the preferred method.
2. Email the maintainers, **Joseph C McGinty Jr. & ResilientMind AI LLC**, at **`<security contact email>`**.

Please include:

- the affected version and Windows build
- clear steps to reproduce, and the impact
- any proof of concept, kept to the minimum needed to demonstrate the issue

What you can expect from us:

- acknowledgement within **3 business days**
- a status update within **10 business days**
- a fix or mitigation for confirmed high/critical issues, targeted within **30 days**
- credit in the release notes if you would like it

We support coordinated disclosure. Please give us a reasonable time to release a fix before publishing details.
Good-faith research that follows this policy will not be pursued legally.

**In scope:** the Rigwright engine, local server and API, UI, LAN bridge, desktop shell, release packaging and
catalog content (for example, a tweak that silently weakens security).

**Out of scope:** vulnerabilities in Windows, winget, Ollama or Claude Code themselves (report those to their
vendors), and attacks that need an already-compromised administrator account.

## Security model

### Process and privilege separation
- The window (browser app window or `Rigwright.exe`) runs **unelevated**. Only the engine process runs elevated.
- The engine watches the launcher's process ID and exits when the window closes. It can also exit after a
  configurable idle time.

### Local server
- By default the server binds to **127.0.0.1 only**.
- Requests whose `Host` header is not a loopback name are rejected, which protects against **DNS rebinding**.
- Every `/api/*` call needs a **256-bit random session token** in the `X-Rigwright-Token` header. Browsers
  cannot attach that header to cross-site requests without a CORS preflight, and the server never grants one.
- The token is never put on a command line or in a URL. The launcher passes a **single-use launch code that
  expires after 5 minutes**, and the page exchanges it for the token, which is kept only in `sessionStorage`.
  Failed exchanges are slowed down.
- Static files are served with a strict **Content-Security-Policy** (`default-src 'self'`, no inline scripts,
  `frame-ancestors 'none'`), `nosniff` and `no-referrer`. The UI loads nothing from the internet.
- Static file paths are canonicalized to prevent path traversal.
- Job types are a fixed allow-list. The "open a classic tool" endpoint only accepts named targets.

### LAN mode (opt-in)
- LAN mode is off by default. Turning it on adds a firewall rule for **Private** network profiles only.
- Token authentication still applies. Access links are single-use and expire after 5 minutes.
- Traffic is plain HTTP. Only enable LAN mode on networks you trust, or tunnel it (for example over Tailscale or
  WireGuard).

### AI safety
- **The AI never executes anything.** It returns a JSON proposal. Rigwright validates every item against the
  catalog and drops unknown tweak, fix and feature IDs.
- Apps that are not in the catalog are flagged as unverified and left unticked.
- Custom commands are **off by default**. When enabled they are always unticked, shown in full and labeled
  "Unvetted command (not from the catalog)". Known-dangerous and obfuscated patterns are **flagged and refused**,
  using PowerShell's own parser plus pattern checks, when proposed and again right before running. This is a
  filter, not a sandbox, and it cannot be complete. The blocklist covers disk/partition destruction, boot-configuration deletion,
  shadow-copy deletion, wiping System32, turning off Defender real-time protection, and download-and-execute
  patterns.
- Claude Code is invoked with **`--tools ""`** (every tool disabled) in an empty temporary working directory,
  so it cannot read your files or run commands.
- Medium- and high-risk selections need confirmation. High risk can optionally require typing `APPLY`.

### Claude Code LAN bridge
- Bearer-token authentication. The token is generated with a CSPRNG and stored in your profile, with mode 600
  on Unix.
- An optional source-IP allow-list (`-AllowFrom`).
- Ten failed attempts from an address lock that address out until the bridge restarts.
- Claude runs with all tools disabled, exactly as above.
- Traffic is plain HTTP on your LAN, so use it on trusted networks or over a VPN.

### System safety
- A **restore point** is created before each batch of changes, and the original values of everything changed
  are journaled (`C:\ProgramData\Rigwright\journal.json`).
- **Protected services** (Windows Update, its medic service, BITS, Defender, Security Center, firewall, Store
  and others) can never be disabled.
- The policy cleaner saves a full `.reg` backup before removing anything.

### Supply chain
- Releases include `SHA256SUMS.txt` for every file, and the zip has its own `.sha256`. Verify with
  `tools\Verify-Release.ps1` before running.
- Rigwright never asks you to run `irm ... | iex`.
- The UI has no third-party runtime dependencies. The desktop shell depends only on Microsoft's WebView2 SDK.
- App installs use winget's signed manifests (and Chocolatey as an optional fallback).

## Hardening tips for users

- Download only from the official repository's Releases page, and verify the checksums.
- Keep LAN mode off unless you need it.
- On shared PCs, use a dedicated Windows account for administration.
- Review **History & undo** after AI-assisted changes.
