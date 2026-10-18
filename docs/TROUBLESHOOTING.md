# Troubleshooting

Logs: `C:\ProgramData\Rigwright\logs\rigwright-YYYY-MM-DD.log`. You can also open them in **History & undo → Log file**.

## Starting Rigwright

**"The engine did not start."**
- Check that you accepted the UAC prompt.
- Look at the newest log file.
- Run the engine directly in an elevated PowerShell to see the error:
  `powershell -ExecutionPolicy Bypass -File .\Rigwright.ps1 -Server -ReadyFile $env:TEMP\rw.json`

**The page says "needs a launch link".**
Launch codes are single-use and last 5 minutes. Start Rigwright again from its shortcut, or create a new link in
**Settings → Access from other devices**.

**Scripts are blocked by execution policy.**
Use `Start-Rigwright.cmd` or `Rigwright.exe`; both pass `-ExecutionPolicy Bypass` for that process only. If
Windows marks downloaded files as blocked, run `Get-ChildItem -Recurse | Unblock-File` in the Rigwright folder
**after** verifying the checksums.

**Running from a network share or a mapped drive.**
Rigwright runs from `\\server\share\Rigwright` or from a mapped drive such as `R:\Rigwright`. The launchers pass
`-ExecutionPolicy Bypass` for their own process and hand the elevated engine the `\\server\share` form of the path,
because mapped drive letters do not exist in elevated processes. Windows may show its "Open File - Security Warning"
for `Rigwright.exe` on a share that is not in the Local intranet zone; choose Run. Settings and the undo journal are
stored on the local PC (`C:\ProgramData\Rigwright`), not on the share, unless you start with `-Portable`.

**Rigwright.exe shows "WebView2 Runtime is missing".**
Install it from the Install page (*Runtimes → WebView2 Runtime*) or with
`winget install Microsoft.EdgeWebView2Runtime`.

**Rigwright.exe does nothing on a PC without .NET 9.**
Install the *.NET Desktop Runtime 9*, or build a self-contained exe with
`tools\Build-Release.ps1 -SelfContained`.

### `git clone` fails with "RPC failed; curl 92 HTTP/2 stream reset" or "early EOF"

The repository includes about 45 MB of screenshots, and some connections or proxies reset large HTTP/2 transfers.
Run the clone from a normal folder such as `~\Downloads` (not `C:\Windows\System32`) and tell Git to use HTTP/1.1:

```powershell
git config --global http.version HTTP/1.1
git clone --depth 1 https://github.com/Subzero121800/RigWright.git
```

If it still fails, download the release zip instead; it contains everything needed to run Rigwright.

## Tweaks

**A tweak shows "partly applied".**
Some of its values match and some don't. Windows or another tool changed part of it. Apply it again, or undo it.

**A tweak shows "reverted by Windows".**
A feature update put the setting back. Use **Reapply** on the Dashboard.

**Settings says "Some settings are managed by your organization".**
Tweaks badged **policy** write Group Policy keys, which is how Windows shows that message. Undo those tweaks, or
use the **Policy cleaner** to remove leftover values from any tool. On a real work or school PC, leave the
policies alone.

**Undo didn't restore something.**
Undo restores what Rigwright recorded the *first* time it applied the tweak. If the tweak was applied by another
tool first, Rigwright uses the Windows default. You can always use a restore point
(**History & undo → Restore points**).

**"Restore point could not be created".**
System Restore is off. Turn it on with **Fixes & tools → Turn on System Restore**.

## Apps

**winget is missing or broken.**
Run **Fixes & tools → Repair winget**.

**An install fails with an exit code.**
- Look at the Activity console for winget's message.
- Some installers need the app closed first, or a reboot.
- If Chocolatey is installed and the catalog entry has a `choco` ID, Rigwright retries with Chocolatey
  automatically.

**"Installed" badges are missing.**
Rigwright uses `winget export`, which only lists apps that winget can match to a package ID. Apps installed some
other way may not appear.

## AI

**Ollama: "Could not reach Ollama".**
- Check that Ollama is running (look for the tray icon, or run `ollama list`).
- For a remote server, check `OLLAMA_HOST=0.0.0.0` and the firewall.

**Ollama: slow or poor answers.**
Use a bigger model (see [AI.md](AI.md)). The first request after loading a model is slower.

**Claude Code: "not found".**
Set the full path to `claude.exe` in Settings (often `%USERPROFILE%\.local\bin\claude.exe`).

**Claude Code: "error" or "not logged in".**
Run `claude` once in a normal terminal and sign in.

**LAN bridge: "rejected the token".**
Copy the token again (`claude-bridge.ps1 -ShowToken`).

**LAN bridge: "cannot reach".**
Make sure the bridge window is open, the URL uses the bridge PC's LAN IP, and the firewall rule exists (the bridge
prints the commands).

**"The model did not return structured actions".**
The model answered in prose. Try again, or switch to a stronger model.

## Resetting Rigwright

1. Undo everything (**History & undo → Undo everything**).
2. Close Rigwright.
3. Delete `C:\ProgramData\Rigwright` and `%LOCALAPPDATA%\Rigwright`.
