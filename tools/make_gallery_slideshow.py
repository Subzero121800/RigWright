"""Build the README slideshow GIFs from the gallery screenshots: 9 slides, captioned, auto-advancing, looping.

    python tools/make_gallery_slideshow.py            # writes docs/screenshots/gallery/slideshow-{dark,light}.gif
    python tools/make_gallery_slideshow.py --no-fade  # hard cuts only (smaller files)
    python tools/make_gallery_slideshow.py --width 1000

Reads docs/screenshots/gallery/{dark,light}/*.png in GALLERY order, scales each to 1200x750 (16:10), draws a caption
band along the bottom with an "n / 9" counter, and writes a GIF with 2.8 s per slide and a 6-frame crossfade.
Each GIF is kept under 9 MB (GitHub's camo proxy refuses images over 10 MB): if a build is too big it is retried
with fewer crossfade frames, then at 1000x625. No app, network, or elevation needed; only Pillow.
Copyright (c) 2026 Joseph C McGinty Jr. & ResilientMind AI LLC. MIT License.
"""
import argparse
import io
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
GALLERY_DIR = ROOT / "docs" / "screenshots" / "gallery"

# Same order and wording as docs/gallery.html and the README gallery.
GALLERY = [
    ("01-dashboard.png", "Dashboard: PC health at a glance, with a one-click action on every warning."),
    ("04-tweaks.png", "Tweaks with live state. Every setting shows exactly what it changes."),
    ("15-preview-modal.png", "Preview before applying: current value → new value, and a restore point first."),
    ("17-ai-conversation.png", "AI assistant suggests a plan from the catalog; nothing runs until you approve."),
    ("03-install-apps.png", "Install apps: 127 curated apps via winget, sortable, plus search across all of winget."),
    ("05-debloat.png", "Debloat lists what is really installed, with a safety rating for each app."),
    ("08-fixes-and-tools.png", "Fixes & tools with Favorites and a Most common section at the top."),
    ("10-history-and-undo.png", "History & undo: original values are recorded, so any change can be undone."),
    ("12-settings.png", "Settings: Ollama or Claude Code, with clear per-provider privacy switches."),
]

HOLD_MS = 2800          # time each slide stays on screen
FADE_FRAMES = 6         # crossfade frames between slides (0 = hard cut)
FADE_FRAME_MS = 50      # duration of each crossfade frame
SIZE_LIMIT = 9 * 1024 * 1024
ACCENT = (15, 159, 143)

THEMES = {
    # band colour (RGBA), text colour, counter colour
    "dark": {"band": (10, 14, 16, 215), "text": (255, 255, 255), "counter": (190, 200, 205)},
    "light": {"band": (255, 255, 255, 225), "text": (20, 25, 28), "counter": (90, 100, 108)},
}


def load_font(size, bold=False):
    """Segoe UI when available (Windows), otherwise DejaVu/Pillow's default."""
    candidates = ["segoeuib.ttf", "segoeui.ttf"] if bold else ["segoeui.ttf"]
    candidates += ["DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf", "arialbd.ttf" if bold else "arial.ttf"]
    for name in candidates:
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    try:
        return ImageFont.load_default(size=size)
    except TypeError:  # very old Pillow: load_default() takes no size
        return ImageFont.load_default()


def fit_caption(draw, text, font, max_width):
    """Wrap the caption to at most two lines; nothing in GALLERY needs more."""
    words = text.split()
    lines, cur = [], ""
    for w in words:
        trial = (cur + " " + w).strip()
        if draw.textlength(trial, font=font) <= max_width or not cur:
            cur = trial
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines[:2]


def render_slide(path, caption, n, total, width, height, theme):
    """Scale a screenshot to width x height and draw the caption band along the bottom."""
    img = Image.open(path).convert("RGB")
    img = img.resize((width, height), Image.LANCZOS)
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)

    t = THEMES[theme]
    scale = width / 1200
    font = load_font(round(26 * scale))
    small = load_font(round(18 * scale))
    pad_x, pad_y = round(28 * scale), round(16 * scale)
    counter = f"{n} / {total}"
    counter_w = od.textlength(counter, font=small)
    lines = fit_caption(od, caption, font, width - 2 * pad_x - counter_w - round(40 * scale))
    line_h = round(34 * scale)
    band_h = pad_y * 2 + line_h * len(lines)
    top = height - band_h

    od.rectangle([0, top, width, height], fill=t["band"])
    od.rectangle([0, top, width, top + max(2, round(3 * scale))], fill=ACCENT + (255,))
    y = top + pad_y
    for line in lines:
        od.text((pad_x, y), line, font=font, fill=t["text"] + (255,))
        y += line_h
    od.text((width - pad_x - counter_w, top + pad_y + round(5 * scale)), counter, font=small, fill=t["counter"] + (255,))

    return Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")


def quantize(frame):
    """Adaptive 256-colour palette with Floyd-Steinberg dithering."""
    return frame.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.FLOYDSTEINBERG)


def build_gif(slides, fade_frames):
    """Return GIF bytes: each slide held HOLD_MS, with fade_frames crossfade frames before the next slide."""
    frames, durations = [], []
    total = len(slides)
    for i, slide in enumerate(slides):
        frames.append(quantize(slide))
        durations.append(HOLD_MS)
        if fade_frames:
            nxt = slides[(i + 1) % total]
            for k in range(1, fade_frames + 1):
                alpha = k / (fade_frames + 1)
                frames.append(quantize(Image.blend(slide, nxt, alpha)))
                durations.append(FADE_FRAME_MS)
    buf = io.BytesIO()
    frames[0].save(
        buf, format="GIF", save_all=True, append_images=frames[1:], duration=durations, loop=0,
        optimize=False, disposal=1,
    )
    return buf.getvalue()


def build_theme(theme, width, fade_frames, out_dir):
    height = width * 10 // 16
    src_dir = GALLERY_DIR / theme
    missing = [f for f, _ in GALLERY if not (src_dir / f).exists()]
    if missing:
        sys.exit(f"missing in {src_dir}: {', '.join(missing)}")

    # Try the requested settings first, then progressively cheaper ones until the GIF fits under SIZE_LIMIT.
    attempts = [(width, fade_frames), (width, fade_frames // 2), (width, 0)]
    if width > 1000:
        attempts += [(1000, fade_frames), (1000, fade_frames // 2), (1000, 0)]
    seen = set()
    for w, fades in attempts:
        if (w, fades) in seen:
            continue
        seen.add((w, fades))
        h = w * 10 // 16
        slides = [render_slide(src_dir / f, cap, i + 1, len(GALLERY), w, h, theme) for i, (f, cap) in enumerate(GALLERY)]
        data = build_gif(slides, fades)
        if len(data) <= SIZE_LIMIT:
            break
        print(f"  {theme}: {w}x{h}, {fades} fade frames -> {len(data) / 1e6:.2f} MB, too big; retrying smaller")
    else:
        print(f"  {theme}: warning, smallest build is still {len(data) / 1e6:.2f} MB (limit {SIZE_LIMIT / 1e6:.0f} MB)")

    out = out_dir / f"slideshow-{theme}.gif"
    out.write_bytes(data)
    print(f"{out.relative_to(ROOT)}: {w}x{h}, {len(GALLERY)} slides, {fades} fade frames, {len(data) / 1e6:.2f} MB ({len(data):,} bytes)")
    return out


def main():
    ap = argparse.ArgumentParser(description="Build docs/screenshots/gallery/slideshow-{dark,light}.gif")
    ap.add_argument("--width", type=int, default=1200, help="frame width (height is 10/16 of it); default 1200")
    ap.add_argument("--no-fade", action="store_true", help="hard cuts between slides instead of a crossfade")
    ap.add_argument("--theme", choices=["dark", "light"], help="build only one theme")
    args = ap.parse_args()

    fade = 0 if args.no_fade else FADE_FRAMES
    for theme in ([args.theme] if args.theme else ["dark", "light"]):
        build_theme(theme, args.width, fade, GALLERY_DIR)


if __name__ == "__main__":
    main()
