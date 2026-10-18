// Rigwright desktop shell.
// Copyright (c) 2026 Joseph C McGinty Jr. & ResilientMind AI LLC. MIT License.
//
// Runs unelevated, starts the elevated Rigwright engine (Rigwright.ps1 -Server) and hosts the UI
// in a WebView2 window. The engine watches this process and stops when the window closes.

using System.Diagnostics;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace Rigwright.Desktop;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.Run(new MainForm());
    }
}

internal sealed class MainForm : Form
{
    private readonly WebView2 _web = new() { Dock = DockStyle.Fill };
    private readonly Label _status = new()
    {
        Dock = DockStyle.Fill,
        TextAlign = ContentAlignment.MiddleCenter,
        Font = new Font("Segoe UI", 11f),
        Text = "Starting the Rigwright engine...\nApprove the administrator prompt to continue.",
    };
    private Process? _engine;
    private readonly bool _portable = Environment.GetCommandLineArgs().Any(a => a.Equals("-Portable", StringComparison.OrdinalIgnoreCase) || a.Equals("--portable", StringComparison.OrdinalIgnoreCase));

    public MainForm()
    {
        Text = "Rigwright";
        Width = 1360;
        Height = 900;
        MinimumSize = new Size(760, 560);
        StartPosition = FormStartPosition.CenterScreen;
        using var icon = typeof(MainForm).Assembly.GetManifestResourceStream("Rigwright.Desktop.rigwright.ico");
        if (icon != null) Icon = new Icon(icon);
        Controls.Add(_status);
        Shown += async (_, _) => await StartAsync();
    }

    private static string? FindScript()
    {
        // Look next to the exe, then walk up (supports running from desktop\bin\Release\...).
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        for (var i = 0; i < 6 && dir != null; i++, dir = dir.Parent)
        {
            var p = Path.Combine(dir.FullName, "Rigwright.ps1");
            if (File.Exists(p)) return p;
        }
        return null;
    }

    private async Task StartAsync()
    {
        var script = FindScript();
        if (script == null)
        {
            Fail("Rigwright.ps1 was not found. Keep Rigwright.exe in the Rigwright folder.");
            return;
        }

        var appDir = Path.GetDirectoryName(script)!;
        // Portable mode keeps everything in .\data beside the app; otherwise per-user LocalAppData (runtime files only).
        var localBase = _portable ? Path.Combine(appDir, "data") : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Rigwright");
        var runDir = Path.Combine(localBase, "run");
        Directory.CreateDirectory(runDir);
        var ready = Path.Combine(runDir, $"ready-{Guid.NewGuid():N}.json");
        var ps = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");

        try
        {
            _engine = Process.Start(new ProcessStartInfo
            {
                FileName = ps,
                // Signed releases (marked by the SIGNED file written at build time) run under RemoteSigned.
                Arguments = $"-NoProfile -ExecutionPolicy {(File.Exists(Path.Combine(appDir, "SIGNED")) ? "RemoteSigned" : "Bypass")} -WindowStyle Hidden -File \"{script}\" -Server -ReadyFile \"{ready}\" -WatchPid {Environment.ProcessId}{(_portable ? " -Portable" : "")}",
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden,
            });
        }
        catch (System.ComponentModel.Win32Exception)
        {
            Fail("Administrator permission is needed to change Windows settings. Close this window and try again.");
            return;
        }

        var deadline = DateTime.UtcNow.AddSeconds(90);
        while (!File.Exists(ready))
        {
            if (DateTime.UtcNow > deadline || (_engine?.HasExited ?? true))
            {
                Fail(@"The engine did not start. See the log in C:\ProgramData\Rigwright\logs.");
                return;
            }
            await Task.Delay(250);
        }
        await Task.Delay(150);

        string url;
        try
        {
            using var doc = JsonDocument.Parse(await File.ReadAllTextAsync(ready));
            url = $"{doc.RootElement.GetProperty("url").GetString()}?code={doc.RootElement.GetProperty("code").GetString()}";
            File.Delete(ready);
        }
        catch (Exception ex)
        {
            Fail("Could not read the engine address: " + ex.Message);
            return;
        }

        try
        {
            var dataDir = Path.Combine(localBase, "webview2");
            var env = await CoreWebView2Environment.CreateAsync(null, dataDir);
            await _web.EnsureCoreWebView2Async(env);
        }
        catch (WebView2RuntimeNotFoundException)
        {
            Fail("The Microsoft Edge WebView2 Runtime is missing, so Rigwright opened in your browser instead.\nKeep this window open while you use Rigwright; closing it stops the engine.");
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
            return;
        }

        var core = _web.CoreWebView2;
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.AreDefaultContextMenusEnabled = true;
        core.DocumentTitleChanged += (_, _) => Text = core.DocumentTitle;
        // External links open in the user's browser; only the local engine is shown in-app.
        var origin = new Uri(url).GetLeftPart(UriPartial.Authority);
        core.NewWindowRequested += (_, e) => { e.Handled = true; OpenExternal(e.Uri); };
        core.NavigationStarting += (_, e) =>
        {
            if (!e.Uri.StartsWith(origin, StringComparison.OrdinalIgnoreCase)) { e.Cancel = true; OpenExternal(e.Uri); }
        };

        Controls.Remove(_status);
        Controls.Add(_web);
        _web.Source = new Uri(url);
    }

    private static void OpenExternal(string uri)
    {
        if (uri.StartsWith("https://", StringComparison.OrdinalIgnoreCase) || uri.StartsWith("http://", StringComparison.OrdinalIgnoreCase))
            Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true });
    }

    private void Fail(string message) => _status.Text = message;
}
