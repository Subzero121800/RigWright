# The AI assistant

Rigwright's assistant turns plain-English requests into a **reviewable plan**. It is designed so that a confused
or misbehaving model **cannot hurt your PC**: it can only suggest, and every suggestion passes several checks
before you see it.

## Providers

| Provider | Where it runs | Cost | Setup |
|---|---|---|---|
| Ollama | this PC or any PC on your LAN | free | `ollama pull qwen3:8b` |
| Claude Code (this PC) | Anthropic's cloud, through your Claude Code login | your Claude plan or API usage | install Claude Code and run `claude` once to sign in |
| Claude Code (LAN bridge) | another PC on your LAN that has Claude Code | same as above | run `bridge/claude-bridge.ps1` on that PC |

### Choosing an Ollama model

Rigwright asks for strict JSON that matches a schema, so pick a model that follows instructions well:

| RAM / VRAM | Suggested model |
|---|---|
| 8 GB | `qwen3:4b`, `llama3.2:3b` (basic) |
| 16 GB | `qwen3:8b` (**recommended default**), `llama3.1:8b`, `gemma3:12b` |
| 24 GB+ / 12 GB+ VRAM | `qwen3:14b`, `qwen3:30b-a3b`, `gpt-oss:20b` |

The system prompt includes the whole catalog (about 8-10k tokens), so Rigwright requests a 32k context window
(`num_ctx`). Reasoning models' `<think>` blocks are stripped automatically.

### Ollama on another machine
On the server, set `OLLAMA_HOST=0.0.0.0` (System Properties → Environment Variables on Windows, or
`systemctl edit ollama` on Linux), restart Ollama, and allow TCP 11434 on the private network. In Rigwright, set
the endpoint to `http://<server-ip>:11434`.

### Claude Code options
- **Model:** leave it empty for your default, or use `sonnet` for faster, cheaper calls, or `opus` for the most
  careful plans.
- Rigwright passes `--tools ""` (no tools), `--output-format json`, `--json-schema` (structured output) and
  `--system-prompt-file`. It runs Claude in an empty temporary folder so no project settings or files are
  picked up.
- The answer header shows the cost Claude Code reports for the call.

### The LAN bridge

```
Rigwright PC ──HTTP (Bearer token)──► bridge PC: claude-bridge.ps1 ──► claude -p --tools ""
```

```powershell
.\claude-bridge.ps1 [-Port 8765] [-AllowFrom 192.168.1.20,192.168.1.21] [-Claude <path>] [-TimeoutSec 300]
.\claude-bridge.ps1 -ShowToken
.\claude-bridge.ps1 -RotateToken
```

| Endpoint | Purpose |
|---|---|
| `GET /v1/health` | Checks that `claude --version` works. Rigwright's **Test** button calls this first. |
| `POST /v1/run` | Body: `{ system, prompt, model, json, schema }`. Returns Claude Code's JSON output unchanged. |

On Windows, running the bridge as a normal user needs a one-time URL reservation and firewall rule. The bridge
prints the exact commands. On macOS and Linux, use PowerShell 7 (`brew install powershell` /
`apt install powershell`).

## What the AI can see

| Provider | Where the request goes | PC summary and history included? |
|---|---|---|
| Ollama | the endpoint you set: this PC or a machine on your LAN. **Nothing leaves your network.** | Yes, by default (*Share ... with Ollama*) |
| Claude Code (this PC) | **Anthropic**, through your Claude Code login | Only if you turn on *Share ... with Claude* (off by default) |
| Claude Code (LAN bridge) | **Anthropic**, through Claude Code on the bridge PC | Same switch as above (off by default) |

The PC summary contains:

- OS edition, version and build; CPU, RAM, GPU, disks, laptop/desktop, power plan, uptime and temp-file size
- which Rigwright tweaks are applied or drifted
- the last 15 Rigwright actions (to help with "what broke?" questions)

The catalog (tweak, app, fix and feature IDs, names, categories, risk levels and short descriptions), your message and up to the last 8 messages of the conversation are always sent. File contents, browser data, documents and credentials are never sent.

To see the exact text for the selected provider, use **View what is sent**: under the provider selector on the AI page, or in Settings.

## What the AI returns

```json
{
  "summary": "one line",
  "answer": "friendly explanation shown to the user",
  "tweaks":     [{ "id": "gaming.hags", "reason": "..." }],
  "undoTweaks": [{ "id": "net.preferIPv4", "reason": "likely cause of the VPN issue" }],
  "apps":       [{ "id": "Discord.Discord", "reason": "..." }],
  "fixes":      [{ "id": "fix.resetNetwork", "reason": "..." }],
  "features":   [{ "id": "feat.wsl", "reason": "..." }],
  "commands":   [{ "command": "Get-NetAdapter", "explanation": "...", "risk": "low" }],
  "warnings":   ["..."]
}
```

## Guard rails (in order)

1. **Schema.** Ollama and Claude are both constrained to the JSON schema. Prose answers are wrapped so you still
   see them, with no actions.
2. **Catalog validation.** Unknown tweak, fix and feature IDs are dropped, with a warning. Each tweak is shown
   with its real risk level, side effects and current state on this PC.
3. **Apps.** Catalog apps are marked verified. Other winget IDs are allowed but flagged *not in catalog - verify*
   and left **unticked**.
4. **Commands.**
   - They are unticked by default, and the "Allow custom commands" setting can switch them off entirely.
   - They are **off by default**, always unticked, and shown in a separate "Unvetted command (not from the catalog)" section.
   - They are vetted when proposed and again on the server right before running. Known-dangerous and obfuscated patterns are flagged and refused. This is a filter, not a sandbox: it cannot catch everything.
   - The check parses the command with PowerShell's parser and refuses commands whose name is computed at runtime (`& $x`, `& ('a'+'b')`), nested `powershell`/`cmd`, `-EncodedCommand` (any prefix), `FromBase64String`, `iex`/`Invoke-Expression` (including aliases), `[scriptblock]::Create`, `Add-Type`, downloads (`DownloadString`/`DownloadFile`, `Start-BitsTransfer`, `irm`/`iwr`, `certutil`), reflection, proxy-execution tools (`mshta`, `rundll32`...) and backtick or `[char]` obfuscation. See `tests/Test-CommandSafety.ps1`.
   - Commands that are not clearly read-only are rated at least medium risk, whatever the model says.
   - Destructive patterns that are always refused include disk formatting, diskpart/Clear-Disk/partition removal, BCD deletion, shadow-copy
     deletion, `cipher /w`, deleting drive roots or System32, `takeown` on System32, deleting `HKLM\SYSTEM`,
     disabling Defender real-time protection, `irm | iex`-style download-and-execute, and shutdown.
5. **Your approval.** Nothing runs until you press **Apply selected**. Medium- and high-risk items need
   confirmation. Use **Preview exact changes** to see every registry value first.
6. **Safety net.** Changes are applied with a restore point first and journaled, so you can undo them from
   **History & undo**.

## Good prompts

- "Make this PC faster for gaming but keep Xbox Game Pass and the Game Bar working."
- "Set this up for my parents: privacy basics, Firefox, VLC, LibreOffice, nothing risky."
- "My VPN connects but there's no internet since I used Rigwright." The AI checks your recent actions and may
  suggest undoing a network tweak.
- "Prepare a dev machine with WSL, VS Code, Git, Node LTS, Python, long paths and the classic right-click menu."
- "Explain what *Disable firmware-injected software (WPBT)* does and whether I need it."
