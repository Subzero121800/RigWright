"""Capture a page-by-page screenshot collection of the Rigwright UI.

Starts the Rigwright engine, opens every page in Microsoft Edge (via Playwright), waits for each
page to finish loading, and saves full-page PNGs to docs/screenshots (or --out).

    python -m pip install playwright
    python tools/capture_screenshots.py [--out DIR] [--theme dark|light|both] [--ai "prompt"]
    python tools/capture_screenshots.py --gallery   # README gallery (window-sized, 2x)

Run it from an elevated terminal for screenshots that show administrator-only data
(Windows features, all-users app inventory). Makes no system changes.

Copyright (c) 2026 Joseph C McGinty Jr. & ResilientMind AI LLC. MIT License.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent.parent
PAGES = [
    ("01-dashboard", "home"),
    ("02-ai-assistant", "assistant"),
    ("03-install-apps", "install"),
    ("04-tweaks", "tweaks"),
    ("05-debloat", "debloat"),
    ("06-startup-apps", "startup"),
    ("07-windows-features", "features"),
    ("08-fixes-and-tools", "fixes"),
    ("09-policy-cleaner", "policies"),
    ("10-history-and-undo", "history"),
    ("11-profiles", "profiles"),
    ("12-settings", "settings"),
    ("13-about", "about"),
]


def start_engine():
    ready = Path(tempfile.gettempdir()) / f"rw-shots-{uuid.uuid4().hex}.json"
    core = ROOT / "core"
    boot = (
        f"Import-Module '{core / 'Engine.psm1'}','{core / 'AI.psm1'}','{core / 'Server.psm1'}' -DisableNameChecking; "
        f"Start-RwServer -ReadyFile '{ready}'"
    )
    proc = subprocess.Popen(
        [os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe"), "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", boot],
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    deadline = time.time() + 60
    while not ready.exists():
        if time.time() > deadline or proc.poll() is not None:
            proc.kill()
            sys.exit("Rigwright engine did not start")
        time.sleep(0.2)
    time.sleep(0.3)
    info = json.loads(ready.read_text())
    ready.unlink(missing_ok=True)
    return proc, info


def settle(page, timeout_s=120):
    """Wait until the view has no spinners (background jobs finished)."""
    page.wait_for_timeout(600)
    end = time.time() + timeout_s
    while time.time() < end:
        if page.locator("#view .spinner").count() == 0:
            break
        page.wait_for_timeout(500)
    page.wait_for_timeout(500)


FULL_PAGE_CSS = """
.app { height: auto !important; min-height: 100vh; align-items: stretch; }
.sidebar { position: static !important; height: auto !important; }
.composer { position: static !important; }
.view { overflow: visible !important; }
.actionbar { position: static !important; }
"""


# Published screenshots must not show private addresses, account emails or the computer name.
HOST = os.environ.get("COMPUTERNAME", "")
SCRUB_JS = r"""(host) => {
  const ip = /\b(?:10\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])|192\.168)\.\d{1,3}\.\d{1,3}\b/g;
  const mail = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;
  const home = /([A-Za-z]:\\Users\\)[^\\<>"\n]+/g;
  const fix = (s) => { s = s.replace(ip, "<lan-ip>").replace(mail, "you@example.com").replace(home, "$1you"); return host ? s.split(host).join("MY-PC") : s; };
  const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let n = w.nextNode(); n; n = w.nextNode()) { const v = fix(n.nodeValue); if (v !== n.nodeValue) n.nodeValue = v; }
  document.querySelectorAll("input, textarea").forEach((el) => { const v = fix(el.value); if (v !== el.value) el.value = v; });
  document.querySelectorAll("option").forEach((el) => { const v = fix(el.textContent); if (v !== el.textContent) el.textContent = v; });
}"""


def shoot(page, out: Path, name: str):
    page.evaluate(SCRUB_JS, HOST)
    path = out / f"{name}.png"
    page.screenshot(path=str(path), full_page=True)
    print(f"  saved {path.name}")


def extras(page, out: Path):
    """Exact-change preview, the preview dialog and the live activity console."""
    page.evaluate("location.hash = '#/tweaks'")
    settle(page)
    page.locator("#twGroups details").first.locator("summary").click()
    page.wait_for_timeout(2500)
    shoot(page, out, "14-tweak-exact-changes")

    page.locator("#preset").select_option("gaming")
    page.locator("#twPreview").click()
    page.wait_for_selector("#modalBody .plan-block, #modalBody .alert", timeout=300000)
    page.wait_for_timeout(500)
    page.evaluate(SCRUB_JS, HOST)
    page.screenshot(path=str(out / "15-preview-modal.png"))
    print("  saved 15-preview-modal.png")
    page.locator("#modalX").click()

    page.locator("#activityBtn").click()
    page.wait_for_timeout(800)
    page.locator("#jobList li[data-id]").first.click()
    page.wait_for_timeout(800)
    page.evaluate(SCRUB_JS, HOST)
    page.screenshot(path=str(out / "16-activity-console.png"))
    print("  saved 16-activity-console.png")
    page.locator("#drawerClose").click()


def ai_conversation(page, out: Path, prompt: str, provider: str | None, full: bool = True):
    page.evaluate("location.hash = '#/assistant'")
    settle(page)
    page.locator("#clearChat").click()
    original = page.locator("#prov").input_value()
    if provider:
        page.locator("#prov").select_option(provider)  # real change event: data-flow note and pill update
        page.wait_for_timeout(600)
    page.locator("#prompt").fill(prompt)
    page.locator("#send").click()
    print("  waiting for the AI (can take a few minutes on a local model)...")
    end = time.time() + 600  # poll from Python: the page's CSP forbids string evaluation
    while time.time() < end and page.locator("#chat .msg.assistant .spinner").count() > 0:
        page.wait_for_timeout(1000)
    page.wait_for_timeout(800)
    if full:
        shoot(page, out, "17-ai-conversation")
    else:
        page.evaluate(SCRUB_JS, HOST)
        page.screenshot(path=str(out / "17-ai-conversation.png"))
        print("  saved 17-ai-conversation.png")
    if provider and original != provider:
        page.locator("#prov").select_option(original)  # put the user's saved provider back
        page.wait_for_timeout(600)


# README gallery: window-sized (not full-page) shots at 2x, so every image has the same 16:10 shape and stays readable.
GALLERY = [
    ("01-dashboard", "home"),
    ("03-install-apps", "install"),
    ("05-debloat", "debloat"),
    ("08-fixes-and-tools", "fixes"),
    ("10-history-and-undo", "history"),
    ("12-settings", "settings"),
]
# Seeded into the throwaway browser profile so the Fixes shot shows the Favorites section.
GALLERY_INIT = """try {
  localStorage.setItem('rw.fixFavs', JSON.stringify(['fix.sfcDism', 'fix.flushDns', 'fix.batteryReport']));
  localStorage.setItem('rw.panelFavs', JSON.stringify(['devmgmt', 'services']));
} catch (e) {}"""


def gallery(page, out: Path, ai_prompt: str | None, provider: str | None):
    for name, route in GALLERY:
        page.evaluate(f"location.hash = '#/{route}'")
        settle(page)
        page.evaluate(SCRUB_JS, HOST)
        page.screenshot(path=str(out / f"{name}.png"))
        print(f"  saved {name}.png")
    page.evaluate("location.hash = '#/tweaks'")
    settle(page)
    page.locator("#twGroups details").first.locator("summary").click()
    page.wait_for_timeout(1000)
    end = time.time() + 60  # the exact-change preview is a background job; wait for it to replace "Loading..."
    while time.time() < end and page.locator("#twGroups :text-is('Loading...')").count() > 0:
        page.wait_for_timeout(500)
    page.wait_for_timeout(400)
    page.evaluate(SCRUB_JS, HOST)
    page.screenshot(path=str(out / "04-tweaks.png"))
    print("  saved 04-tweaks.png")
    page.locator("#preset").select_option("gaming")
    page.locator("#twPreview").click()
    page.wait_for_selector("#modalBody .plan-block, #modalBody .alert", timeout=300000)
    page.wait_for_timeout(500)
    page.evaluate(SCRUB_JS, HOST)
    page.screenshot(path=str(out / "15-preview-modal.png"))
    print("  saved 15-preview-modal.png")
    page.locator("#modalX").click()
    if ai_prompt:
        ai_conversation(page, out, ai_prompt, provider, full=False)


def capture(theme: str, out: Path, ai_prompt: str | None, provider: str | None = None, ai_only: bool = False, only=None, is_gallery: bool = False):
    proc, info = start_engine()
    base = info["url"].rstrip("/")
    print(f"Engine at {base} - theme {theme}")
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(channel="msedge", headless=True)
            ctx = browser.new_context(viewport={"width": 1440, "height": 900}, color_scheme=theme, device_scale_factor=2 if is_gallery else 1)
            if is_gallery:
                ctx.add_init_script(GALLERY_INIT)
            page = ctx.new_page()
            errors = []
            page.on("pageerror", lambda e: errors.append(str(e)))
            page.goto(f"{base}/?code={info['code']}#/home")
            page.wait_for_selector("#nav a.active", timeout=30000)
            if is_gallery:
                gallery(page, out, ai_prompt, provider)
                browser.close()
                for e in errors:
                    print(f"  JS ERROR: {e}")
                return
            page.add_style_tag(content=FULL_PAGE_CSS)  # let the inner scroll area grow so full_page captures everything
            if not ai_only or only:
                for name, route in [x for x in PAGES if not only or x[1] in only]:
                    page.evaluate(f"location.hash = '#/{route}'")
                    settle(page)
                    shoot(page, out, name)
                if not ai_only and not only:
                    extras(page, out)
            if ai_prompt:
                ai_conversation(page, out, ai_prompt, provider)
            browser.close()
            for e in errors:
                print(f"  JS ERROR: {e}")
    finally:
        proc.kill()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / "docs" / "screenshots"))
    ap.add_argument("--theme", choices=["dark", "light", "both"], default="both")
    ap.add_argument("--ai", default="Make this PC faster for gaming but keep Xbox Game Pass working, and install Discord and Steam.")
    ap.add_argument("--no-ai", action="store_true")
    ap.add_argument("--ai-only", action="store_true", help="only capture the AI conversation shot")
    ap.add_argument("--pages", help="comma-separated routes to capture only, e.g. about,settings")
    ap.add_argument("--gallery", action="store_true", help="window-sized 2x shots for the README in docs/screenshots/gallery/<theme>")
    ap.add_argument("--provider", choices=["ollama", "claude-local", "claude-lan"], help="AI provider for the conversation shot (default: saved setting)")
    a = ap.parse_args()
    themes = ["dark", "light"] if a.theme == "both" else [a.theme]
    for t in themes:
        if a.gallery:
            out = Path(a.out) / "gallery" / t
        else:
            out = Path(a.out) / t if len(themes) > 1 else Path(a.out)
        out.mkdir(parents=True, exist_ok=True)
        capture(t, out, None if (a.no_ai or (t != themes[0] and not a.gallery)) else a.ai, a.provider, a.ai_only, a.pages.split(",") if a.pages else None, a.gallery)
    print("Done.")


if __name__ == "__main__":
    main()