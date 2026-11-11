#!/usr/bin/env python3
"""Draws the floorplan over a die render: each SRAM store tinted and named,
the logic left as it is, a scale bar; and makes the web-sized copies.

    annotate.py FULL.png MACRO_PLACEMENT.cfg DIE_W DIE_H OUT.png [WEB_PREFIX]

Needs Pillow (build/asic/venv has it).
"""
import re
import sys
from PIL import Image, ImageDraw, ImageFont

full, cfg, W, H, out = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4]), sys.argv[5]
web = sys.argv[6] if len(sys.argv) > 6 else None
MW, MH = 431.86, 484.88

img = Image.open(full).convert("RGB")
sx, sy = img.width / W, img.height / H
X = lambda x: x * sx                      # noqa: E731
Y = lambda y: img.height - y * sy         # noqa: E731

# a store: its macros' bounding box
stores = {}
for line in open(cfg):
    n, x, y, _ = line.split()
    m = re.match(r"(.*)\.g_r\[\d+\]\.g_b\[\d+\]\.u_m$", n) or re.match(r"(.*)\.g_b\[\d+\]\.u_m$", n)
    h = 340.88 if "u_ctab" in n else MH
    x, y = float(x), float(y)
    b = stores.setdefault(m.group(1), [x, y, x + MW, y + h])
    b[:] = [min(b[0], x), min(b[1], y), max(b[2], x + MW), max(b[3], y + h)]

COL = {"ils": (80, 170, 255), "dls": (90, 220, 140), "t2": (255, 179, 71), "ct": (230, 110, 200)}


def label(key):
    core = re.search(r"g_core\[(\d+)\]", key)
    c = f"core {core.group(1)} " if core else ""
    if key.endswith("u_ils"):
        return "ils", f"{c}I-LS 64 KiB"
    if key.endswith("u_dls"):
        return "dls", f"{c}D-LS 64 KiB"
    if key.endswith("u_ctab"):
        return "ct", "save table" if not c else f"{c.strip()} CTAB"
    return "t2", "T2 64 KiB"


over = Image.new("RGBA", img.size, (0, 0, 0, 0))
d = ImageDraw.Draw(over)
fs = max(14, int(img.width / 55))
try:
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf", fs)
    small = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", int(fs * 0.7))
except OSError:
    font = small = ImageFont.load_default()
for key, (x0, y0, x1, y1) in stores.items():
    kind, text = label(key)
    c = COL[kind]
    box = [X(x0), Y(y1), X(x1), Y(y0)]
    d.rectangle(box, fill=c + (46,), outline=c + (255,), width=max(2, fs // 8))
    tw = d.textlength(text, font=font)
    cx, cy = (box[0] + box[2]) / 2, (box[1] + box[3]) / 2
    d.rectangle([cx - tw / 2 - fs / 3, cy - fs * 0.7, cx + tw / 2 + fs / 3, cy + fs * 0.7], fill=(0, 0, 0, 170))
    d.text((cx - tw / 2, cy - fs * 0.6), text, font=font, fill=c + (255,))

# scale bar: 1 mm
bx, by = X(W * 0.02), img.height - fs * 1.2
d.rectangle([bx, by, bx + X(1000), by + fs * 0.3], fill=(255, 255, 255, 230))
d.text((bx + X(1000) + fs * 0.4, by - fs * 0.35), "1 mm", font=small, fill=(255, 255, 255, 230))

res = Image.alpha_composite(img.convert("RGBA"), over).convert("RGB")
res.save(out, optimize=True)
if web:
    for src, suffix in ((res, "-annotated"), (img, "-full")):
        w = 1600
        src.resize((w, int(src.height * w / src.width)), Image.LANCZOS).save(
            f"{web}{suffix}.png", optimize=True)
