"""Record the README demo GIF from the real app: plain-English request -> plan -> exact registry diff -> Apply -> Undo.

    python tools/make_demo_gif.py --phase apply     # applies 3 harmless, no-restart tweaks and records frames
    python tools/capture_screenshots.py ...         # (optional) capture pages while History is populated
    python tools/make_demo_gif.py --phase undo      # undoes exactly those tweaks, records the last frames, writes the GIF

Only DEMO_IDS are ever applied or undone. Run elevated. Frames go to dist/demo-frames, the GIF to docs/demo.gif.
Copyright (c) 2026 Joseph C McGinty Jr. & ResilientMind AI LLC. MIT License.
"""
import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import capture_screenshots as cs  # noqa: E402
from playwright.sync_api import sync_playwright  # noqa: E402
from PIL import Image, ImageDraw, ImageFont  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
FRAMES = ROOT / "dist" / "demo-frames"
DEMO_IDS = ["perf.startupDelay", "sys.verboseBsod", "ui.verboseStatus"]
PROMPT = "Remove the startup delay for my apps, and show details on blue screens and during sign-in. Nothing else."


def open_app(p, info, theme="dark"):
    b = p.chromium.launch(channel="msedge", headless=True)
    pg = b.new_page(viewport={"width": 1440, "height": 900}, color_scheme=theme)
    pg.goto(f"{info['url'].rstrip('/')}/?code={info['code']}#/home")
    pg.wait_for_selector("#nav a.active", timeout=30000)
    cs.settle(pg)
    return b, pg


def frame(pg, name, caption):
    pg.evaluate(cs.SCRUB_JS)
    path = FRAMES / f"{name}.png"
    pg.screenshot(path=str(path))
    (FRAMES / f"{name}.txt").write_text(caption, encoding="utf-8")
    print("  frame", name)


def go(pg, route):
    pg.evaluate(f"location.hash = '#/{route}'")
    cs.settle(pg, 120)


def wait_jobs(pg, timeout=300):
    end = time.time() + timeout
    pg.wait_for_timeout(800)
    while time.time() < end and not pg.locator("#jobCount").is_hidden():
        pg.wait_for_timeout(1000)
    pg.wait_for_timeout(800)


def phase_apply():
    FRAMES.mkdir(parents=True, exist_ok=True)
    for f in FRAMES.glob("*"):
        f.unlink()
    proc, info = cs.start_engine()
    try:
        with sync_playwright() as p:
            b, pg = open_app(p, info)
            go(pg, "assistant")
            pg.locator("#clearChat").click()
            original = pg.locator("#prov").input_value()
            pg.locator("#prov").select_option("ollama")  # real change event so the data-flow note is right
            pg.wait_for_timeout(600)
            (FRAMES / "provider.txt").write_text(original, encoding="utf-8")
            pg.locator("#prompt").fill(PROMPT)
            frame(pg, "01", "1. Ask in plain English")
            pg.locator("#send").click()
            end = time.time() + 600
            while time.time() < end and pg.locator("#chat .msg.assistant .spinner").count() > 0:
                pg.wait_for_timeout(1000)
            pg.wait_for_timeout(800)
            msg = pg.locator("#chat .msg.assistant").last
            proposal_ok = msg.locator("[data-act=apply]").count() > 0
            if proposal_ok:
                # Keep only the demo tweaks ticked; untick everything else (apps, fixes, commands, other tweaks).
                boxes = msg.locator("input[type=checkbox]")
                names = {"perf.startupDelay": "startup", "sys.verboseBsod": "blue screens", "ui.verboseStatus": "Verbose sign-in"}
                for i in range(boxes.count()):
                    cb = boxes.nth(i)
                    label = cb.locator("xpath=..").inner_text().lower()
                    keep = cb.get_attribute("data-kind") == "tweaks" and any(k.lower() in label for k in names.values())
                    if cb.is_checked() != keep and cb.is_enabled():
                        cb.click()
                msg.scroll_into_view_if_needed()
                frame(pg, "02", "2. The AI proposes catalog items - you tick what you want")
                msg.locator("[data-act=preview]").click()
                pg.wait_for_selector("#modalBody .plan-block, #modalBody .alert", timeout=120000)
                pg.wait_for_timeout(500)
                frame(pg, "03", "3. Exactly what will change, value by value")
                pg.locator("#modalX").click()
                ticked = msg.locator("input[data-kind=tweaks]:checked").count()
            else:
                ticked = 0
            if not ticked:
                # The model answered without usable tweaks: apply the same demo tweaks from the Tweaks page.
                print("  AI plan had no demo tweaks - using the Tweaks page")
                pg.evaluate(f"localStorage.setItem('rw.selTweaks', {json.dumps(json.dumps(DEMO_IDS))})")
                go(pg, "tweaks")
                pg.locator("#twPreview").click()
                pg.wait_for_selector("#modalBody .plan-block", timeout=120000)
                frame(pg, "03", "3. Exactly what will change, value by value")
                pg.locator("#modalX").click()
                pg.locator("#twApply").click()
            else:
                msg.locator("[data-act=apply]").click()
            pg.wait_for_timeout(1500)
            frame(pg, "04", "4. Apply: restore point first, every step logged live")
            wait_jobs(pg)
            frame(pg, "05", "4. Apply: restore point first, every step logged live")
            pg.locator("#drawerClose").click()
            go(pg, "history")
            for d in pg.locator("#hBody details").all():
                d.evaluate("el => el.open = true")
            pg.wait_for_timeout(400)
            frame(pg, "06", "5. History keeps the original values")
            b.close()
    finally:
        proc.kill()


def phase_undo():
    proc, info = cs.start_engine()
    try:
        with sync_playwright() as p:
            b, pg = open_app(p, info)
            go(pg, "history")
            for tid in DEMO_IDS:
                btn = pg.locator(f'#hBody [data-undo="{tid}"]')
                if btn.count():
                    btn.click()
                    wait_jobs(pg, 180)
                    pg.locator("#drawerClose").click()
                    go(pg, "history")
            frame(pg, "07", "6. Undo puts back exactly what was there")
            orig = FRAMES / "provider.txt"
            if orig.exists() and orig.read_text(encoding="utf-8") != "ollama":
                go(pg, "assistant")
                pg.locator("#prov").select_option(orig.read_text(encoding="utf-8"))  # restore the saved provider
                pg.wait_for_timeout(800)
            b.close()
    finally:
        proc.kill()
    build_gif()


def build_gif():
    frames = sorted(FRAMES.glob("*.png"))
    if not frames:
        raise SystemExit("no frames")
    try:
        font = ImageFont.truetype("C:/Windows/Fonts/segoeuib.ttf", 30)
    except OSError:
        font = ImageFont.load_default()
    imgs, durations = [], []
    for f in frames:
        im = Image.open(f).convert("RGB")
        cap = (f.with_suffix(".txt")).read_text(encoding="utf-8") if f.with_suffix(".txt").exists() else ""
        w, h = im.size
        canvas = Image.new("RGB", (w, h + 64), (15, 17, 21))
        canvas.paste(im, (0, 64))
        d = ImageDraw.Draw(canvas)
        d.rectangle([0, 0, w, 64], fill=(13, 118, 107))
        d.text((24, 15), cap, fill=(255, 255, 255), font=font)
        canvas = canvas.resize((1000, int((h + 64) * 1000 / w)), Image.LANCZOS)
        imgs.append(canvas.quantize(colors=128, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE))
        durations.append(3200 if f.stem in ("03", "06", "07") else 2600)
    out = ROOT / "docs" / "demo.gif"
    imgs[0].save(out, save_all=True, append_images=imgs[1:], duration=durations, loop=0, optimize=True, disposal=2)
    print(f"GIF written: {out} ({out.stat().st_size // 1024} KB, {sum(durations) / 1000:.1f} s)")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--phase", choices=["apply", "undo", "gif"], required=True)
    a = ap.parse_args()
    {"apply": phase_apply, "undo": phase_undo, "gif": build_gif}[a.phase]()
