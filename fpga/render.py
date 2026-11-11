#!/usr/bin/env python3
"""Draws a placed (and routed) ECP5 design the way a die shot looks.

    python3 fpga/render.py DESIGN OUT.png [--report report.json] [--placed]
                           [--web OUT-web.webp] [--title ...] [--note ...]
    python3 fpga/render.py DESIGN.json --extract DATA.json.gz [--report ...]

DESIGN is what `nextpnr-ecp5 --write` produced (fpga/pnr.sh; .gz is fine):
every cell carries its location in the attribute NEXTPNR_BEL
("X61/Y55/SLICEA.K0"), and after routing every net its wires and pips in
ROUTING. Or it is an extract (--extract): only what the pictures need, every
cell's site and group and every routed wire's name and group, a few MB
instead of a few hundred; fpga/results/ecp5-N/die-data.json.gz is one, so
the pictures can be redrawn without placing and routing again. --placed
leaves the routing out (the placement view). The fabric (logic
tiles, block RAM, multipliers, I/O) comes from fpga/ecp5/lfe5u-85f-bels.json,
written by fpga/ecp5/bels.py from nextpnr's chip database.

What is drawn:
- each logic tile (PLC) as four slices; in a slice, the two LUT4 sites on
  top and the two flip-flops below, each coloured by the part of the design
  the cell belongs to (fpga/classify.py); a carry cell (CCU2C) joins its two
  LUT sites into one bar, so carry chains show as columns;
- block RAM (DP16KD), multipliers (MULT18X18D, ALU54B) in their rows, used
  ones filled with their owner's colour; I/O pads around the edge;
- with routing: every routed wire as a line along its real span (1, 2 or 6
  tiles, on its track), in the colour of the net's owner, blurred into a glow.
  Without routing (a --no-route run) the cells glow instead.

Needs numpy and Pillow (fpga/README.md: a venv under build/ does). Fonts:
Space Grotesk and JetBrains Mono from build/fonts/ if they are there (the
site's fonts), else the system's.
"""
import argparse, gzip, json, math, os, re, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import classify  # noqa: E402

BG = (7, 10, 18)
SUBSTRATE = (11, 17, 32)
TILE = (16, 25, 42)
TILE_EDGE = (24, 38, 62)
EMPTY = (26, 38, 60)
TEXT = (207, 232, 255)
DIM = (91, 112, 136)
EDGE = (31, 111, 139)
CYAN = (77, 225, 255)
AMBER = (255, 179, 71)


def hexrgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


GCOL = [hexrgb(c) for _, _, c in classify.GROUPS]


def mix(a, b, t):
    return tuple(int(round(a[i] * (1 - t) + b[i] * t)) for i in range(3))


def font(kind, size, weight=400):
    names = {"sans": ["build/fonts/SpaceGrotesk.ttf", "/System/Library/Fonts/Avenir Next.ttc",
                      "/System/Library/Fonts/Helvetica.ttc", "DejaVuSans.ttf"],
             "mono": ["build/fonts/JetBrainsMono.ttf", "/System/Library/Fonts/Menlo.ttc",
                      "DejaVuSansMono.ttf"]}[kind]
    root = os.path.dirname(HERE)
    for n in names:
        p = n if os.path.isabs(n) else os.path.join(root, n)
        try:
            f = ImageFont.truetype(p if os.path.exists(p) else n, size)
        except OSError:
            continue
        try:
            f.set_variation_by_axes([weight])
        except (OSError, AttributeError, ValueError):
            pass
        return f
    return ImageFont.load_default()


# ---------------------------------------------------------------- the design
BEL = re.compile(r"^X(\d+)/Y(\d+)/(.+)$")


def read_json(path):
    with (gzip.open(path, "rt") if path.endswith(".gz") else open(path)) as f:
        return json.load(f)


def load(path):
    d = read_json(path)
    top = [v for v in d["modules"].values() if v["attributes"].get("top")]
    return top[0] if top else list(d["modules"].values())[0]


def net_group(name):
    return classify.GROUP_INDEX[classify.group(name)]


# ---------------------------------------------------------------- blur
def box(a, r, axis):
    if r < 1:
        return a
    c = np.cumsum(a, axis=axis, dtype=np.float32)
    n = a.shape[axis]
    pad = [(0, 0)] * a.ndim
    pad[axis] = (r + 1, r)
    c = np.pad(c, pad, mode="edge")
    sl_hi = [slice(None)] * a.ndim
    sl_lo = [slice(None)] * a.ndim
    sl_hi[axis] = slice(2 * r + 1, 2 * r + 1 + n)
    sl_lo[axis] = slice(0, n)
    out = (c[tuple(sl_hi)] - c[tuple(sl_lo)]) / (2 * r + 1)
    # the left edge padding repeats c[0], not 0
    return out


def blur(a, sigma):
    """About a Gaussian: three box passes per axis (on the first two axes)."""
    r = max(1, int(round(math.sqrt(12 * sigma * sigma / 3 + 1) - 1) // 2))
    for _ in range(3):
        a = box(a, r, 0)
        a = box(a, r, 1)
    return a


def extract(top_json, report_path=None):
    """What the pictures need from nextpnr's JSON: every placed cell's site,
    group and whether it is half of a carry cell, and every routed net's
    group (that of the cell driving it) and wires (the clock tree left out:
    it would light everything)."""
    m = [v for v in top_json["modules"].values() if v["attributes"].get("top")]
    top = m[0] if m else list(top_json["modules"].values())[0]
    cg = classify.assign(top)
    cells = []
    for n, c in top["cells"].items():
        bel = c["attributes"].get("NEXTPNR_BEL")
        if bel:
            cells.append([bel, cg[n], 1 if c["parameters"].get("MODE", "") == "CCU2" else 0])
    bit_owner = {}
    for n, c in top["cells"].items():
        for p, bits in c.get("connections", {}).items():
            if c.get("port_directions", {}).get(p) == "output":
                for b in bits:
                    if isinstance(b, int):
                        bit_owner[b] = cg[n]
    nets = []
    for n, v in top["netnames"].items():
        r = v["attributes"].get("ROUTING")
        if not r or n.startswith("clk") or "$glbnet" in n or "$gbuf" in n:
            continue
        g = next((bit_owner[b] for b in v["bits"] if isinstance(b, int) and b in bit_owner), None)
        if g is None:
            g = net_group(n)
        nets.append([g, [w for w in r.split(";")[0::3] if w]])
    data = {"strata-die": 1, "groups": [k for k, _, _ in classify.GROUPS], "cells": cells, "nets": nets}
    if report_path and os.path.exists(report_path):
        rep = read_json(report_path)
        data["report"] = {"utilization": {k: v for k, v in rep.get("utilization", {}).items()
                                          if k in ("TRELLIS_COMB", "TRELLIS_FF", "DP16KD", "MULT18X18D")},
                          "fmax": rep.get("fmax", {})}
    return data


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("design", help="nextpnr's JSON (placed or routed), or an extract")
    ap.add_argument("out", nargs="?")
    ap.add_argument("--extract", help="write what the pictures need to this .json.gz and stop")
    ap.add_argument("--placed", action="store_true", help="the placement only: leave the routing out")
    ap.add_argument("--report", help="nextpnr --report JSON (utilisation, Fmax)")
    ap.add_argument("--web", help="also write a small version (PNG or WebP by extension)")
    ap.add_argument("--web-width", type=int, default=1600)
    ap.add_argument("--tile", type=int, default=32, help="pixels per tile")
    ap.add_argument("--title", default="Strata: one core on a Lattice ECP5-85F")
    ap.add_argument("--note", action="append", default=[], help="a line under the title (repeatable)")
    ap.add_argument("--wires", type=float, default=1.2, help="brightness of the routed wires")
    ap.add_argument("--haze", type=float, default=0.4, help="brightness of the blurred routing glow")
    ap.add_argument("--glow", type=float, default=0.7, help="opacity of the routing layer")
    ap.add_argument("--fabric", default=os.path.join(HERE, "ecp5", "lfe5u-85f-bels.json"))
    a = ap.parse_args()

    T = a.tile
    fab = json.load(open(a.fabric))
    plc = {tuple(int(v) for v in s.replace("X", "").replace("Y", "").split("/")) for s in fab["PLC"]}
    allbels = [b for k in fab if k != "PLC" for b in fab[k]]
    NX = max(int(BEL.match(b)[1]) for b in allbels) + 1
    NY = max(int(BEL.match(b)[2]) for b in allbels) + 1

    data = read_json(a.design)
    if not data.get("strata-die"):
        data = extract(data, a.report)
    if a.extract:
        with gzip.open(a.extract, "wt", compresslevel=9) as f:
            json.dump(data, f, separators=(",", ":"))
        print(a.extract, len(data["cells"]), "cells,", sum(len(w) for _, w in data["nets"]), "wires")
        return

    # placed cells by location
    slices = {}      # (x, y, slice letter) -> {"K0": (g, mode), "FF0": g, ...}
    blocks = {}      # bel name -> group
    lut_count = [0] * len(GCOL)
    for bel, g, carry in data["cells"]:
        m = BEL.match(bel)
        x, y, b = int(m[1]), int(m[2]), m[3]
        if b.startswith("SLICE"):
            s_, part = b[5], b.split(".")[1]
            slices.setdefault((x, y, s_), {})[part] = (g, "CCU2" if carry else "")
            if part.startswith("K"):
                lut_count[g] += 1
        else:
            blocks[bel] = g
    report = data.get("report")

    # ------------------------------------------------ canvas: 4:3, die centred
    dw, dh = NX * T, NY * T
    top_m, bot_m = int(dh * 0.105), int(dh * 0.165)
    H = dh + top_m + bot_m
    W = max(int(H * 4 / 3), dw + 2 * int(T * 3))
    ox, oy = (W - dw) // 2, top_m

    # routing / glow, in die pixels
    best = np.zeros((dh, dw), np.float32)
    owner = np.zeros((dh, dw), np.int8)
    total = np.zeros((dh, dw), np.float32)
    span_re = re.compile(r"^([HV])0([0126])([NSEW])(\d\d)(\d\d)$")
    dirs = {"N": (0, -1), "S": (0, 1), "E": (1, 0), "W": (-1, 0)}
    segs = []        # x0, y0, x1, y1, group
    local = []       # x, y, group
    for g, wires in ([] if a.placed else data["nets"]):
        for w in wires:
            m = BEL.match(w)
            if not m:
                continue
            x, y, wn = int(m[1]), int(m[2]), m[3]
            s = span_re.match(wn)
            if s and s[2] != "0":
                span, (dx, dy), track, seg = int(s[2]), dirs[s[3]], int(s[4]), int(s[5])
                sx, sy = x - seg * dx, y - seg * dy
                ex, ey = sx + span * dx, sy + span * dy
                off = (0.12 + 0.76 * ((track * 5 + span) % 8) / 7.0)
                if s[1] == "H":
                    py0 = py1 = (sy + off) * T
                    px0, px1 = (sx + 0.5) * T, (ex + 0.5) * T
                else:
                    px0 = px1 = (sx + off) * T
                    py0, py1 = (sy + 0.5) * T, (ey + 0.5) * T
                segs.append((px0, py0, px1, py1, g))
            else:
                local.append(((x + 0.5) * T, (y + 0.5) * T, g))

    # a --no-route run still has the fixed connections (carry chains, inside
    # slices): routed means general routing, wires that span tiles
    routed = len(segs) > 100
    if not a.out:
        ap.error("an output file, or --extract")
    if routed:
        seg = np.array(segs, np.float32) if segs else np.zeros((0, 5), np.float32)
        for gi in range(len(GCOL)):
            sg = seg[seg[:, 4] == gi]
            acc = np.zeros(dh * dw, np.float32)
            if len(sg):
                L = np.maximum(2, (np.hypot(sg[:, 2] - sg[:, 0], sg[:, 3] - sg[:, 1]) / 1.2).astype(np.int64))
                for lo in range(0, len(sg), 200000):
                    s2, L2 = sg[lo:lo + 200000], L[lo:lo + 200000]
                    idx = np.repeat(np.arange(len(s2)), L2)
                    start = np.repeat(np.cumsum(L2) - L2, L2)
                    t = (np.arange(len(idx)) - start) / np.repeat(L2 - 1, L2)
                    px = s2[idx, 0] + (s2[idx, 2] - s2[idx, 0]) * t
                    py = s2[idx, 1] + (s2[idx, 3] - s2[idx, 1]) * t
                    ok = (px >= 0) & (px < dw) & (py >= 0) & (py < dh)
                    acc += np.bincount(py[ok].astype(np.int64) * dw + px[ok].astype(np.int64),
                                       minlength=dh * dw).astype(np.float32)
            lg = [p for p in local if p[2] == gi]
            if lg:
                lp = np.array(lg, np.float32)
                ok = (lp[:, 0] < dw) & (lp[:, 1] < dh)
                acc += 0.6 * np.bincount(lp[ok, 1].astype(np.int64) * dw + lp[ok, 0].astype(np.int64),
                                         minlength=dh * dw).astype(np.float32)
            acc = blur(acc.reshape(dh, dw)[:, :, None], 0.9)[:, :, 0]
            # each pixel takes the colour of the group with the most wire
            # there (a mix of all eight would be grey), its brightness the
            # total amount of wire
            better = acc > best
            best = np.where(better, acc, best)
            owner = np.where(better, gi, owner)
            total += acc
        pal = np.array(GCOL, np.float32) / 255.0
        col = pal[owner]
        # exposure from the data: the busiest 1% of the die saturates
        nz = total[total > 0]
        total /= max(1e-6, float(np.percentile(nz, 99))) if nz.size else 1.0
        fine = col * total[:, :, None]
        soft = blur(fine, T * 0.45)
        sl = soft.max(axis=2)
        nz = sl[sl > 0]
        soft /= max(1e-6, float(np.percentile(nz, 99))) if nz.size else 1.0
        layer = 1.0 - np.exp(-(a.wires * fine + a.haze * soft))
        layer *= a.glow
    else:
        layer = None

    # ------------------------------------------------ the die
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    # background grid like the site's
    for gx in range(0, W, T * 2):
        d.line([(gx, 0), (gx, H)], fill=(10, 16, 28))
    for gy in range(0, H, T * 2):
        d.line([(0, gy), (W, gy)], fill=(10, 16, 28))
    pad = T // 2
    d.rounded_rectangle([ox - pad, oy - pad, ox + dw + pad, oy + dh + pad], radius=T // 2,
                        fill=SUBSTRATE, outline=mix(EDGE, BG, 0.35), width=max(2, T // 12))
    die = Image.new("RGB", (dw, dh), SUBSTRATE)
    dd = ImageDraw.Draw(die)

    # logic tiles
    sw = (T - 2) / 4.0
    for (x, y) in plc:
        x0, y0 = x * T, y * T
        dd.rectangle([x0 + 1, y0 + 1, x0 + T - 2, y0 + T - 2], fill=TILE)
    # slices: LUT sites and flip-flops
    lut_h = int(T * 0.30)
    ff_h = int(T * 0.15)
    for (x, y) in plc:
        for si, s in enumerate("ABCD"):
            cells = slices.get((x, y, s), {})
            sx0 = x * T + 1 + si * sw + 0.7
            sx1 = sx0 + sw - 1.6
            yy = y * T + 2
            k0, k1 = cells.get("K0"), cells.get("K1")
            carry = (k0 and k0[1] == "CCU2") or (k1 and k1[1] == "CCU2")
            if carry and k0:
                c = GCOL[k0[0]]
                dd.rectangle([sx0, yy, sx1, yy + 2 * lut_h], fill=mix(c, (255, 255, 255), 0.08))
                dd.rectangle([sx0 + 1, yy + lut_h - 0.5, sx1 - 1, yy + lut_h + 0.5], fill=mix(c, BG, 0.45))
            else:
                for j, k in enumerate((k0, k1)):
                    c = GCOL[k[0]] if k else EMPTY
                    dd.rectangle([sx0, yy + j * (lut_h + 1), sx1, yy + j * (lut_h + 1) + lut_h - 1], fill=c)
            yy2 = y * T + 2 + 2 * lut_h + 3
            for j, part in enumerate(("FF0", "FF1")):
                f = cells.get(part)
                c = mix(GCOL[f[0]], BG, 0.25) if f else mix(EMPTY, TILE, 0.4)
                dd.rectangle([sx0, yy2 + j * (ff_h + 1), sx1, yy2 + j * (ff_h + 1) + ff_h - 1], fill=c)

    # hard blocks
    def block(bel, w, h, label=None):
        m = BEL.match(bel)
        x, y = int(m[1]), int(m[2])
        g = blocks.get(bel)
        x0, y0 = x * T + 2, y * T + 2
        x1, y1 = x0 + w * T - 4, y0 + h * T - 4
        if g is None:
            dd.rounded_rectangle([x0, y0, x1, y1], radius=T // 6, fill=(14, 22, 38), outline=(36, 54, 84), width=2)
        else:
            c = GCOL[g]
            dd.rounded_rectangle([x0, y0, x1, y1], radius=T // 6, fill=mix(c, BG, 0.35), outline=c, width=2)
            # a block RAM's word lines
            for k in range(1, 4):
                yl = y0 + (y1 - y0) * k / 4
                dd.line([(x0 + 4, yl), (x1 - 4, yl)], fill=mix(c, BG, 0.1), width=1)
    for b in fab.get("DP16KD", []):
        block(b, 2, 1)
    for b in fab.get("MULT18X18D", []):
        block(b, 1, 1)
    for b in fab.get("ALU54B", []):
        block(b, 2, 1)
    for b in fab.get("EHXPLLL", []) + fab.get("DCUA", []):
        m = BEL.match(b)
        x, y = int(m[1]), int(m[2])
        dd.rounded_rectangle([x * T + 2, y * T + 2, x * T + T - 2, y * T + T - 2], radius=T // 5,
                             fill=(18, 28, 48), outline=(46, 70, 104), width=2)
    for b in fab.get("TRELLIS_IO", []):
        m = BEL.match(b)
        x, y, p = int(m[1]), int(m[2]), m[3]
        k = "ABCD".find(p[-1]) if p[-1] in "ABCD" else 0
        if x == 0 or x == NX - 1:
            px, py = x * T + T * 0.25, y * T + 2 + k * (T - 4) / 4
            box_ = [px, py + 1, px + T * 0.5, py + (T - 4) / 4 - 1]
        else:
            px, py = x * T + 2 + k * (T - 4) / 4, y * T + T * 0.25
            box_ = [px + 1, py, px + (T - 4) / 4 - 1, py + T * 0.5]
        used = b in blocks
        dd.rectangle(box_, fill=AMBER if used else (30, 44, 66))

    arr = np.asarray(die).astype(np.float32) / 255.0
    marks = arr.copy()
    if layer is not None:
        # routing under the cells: screen blend
        arr = 1 - (1 - arr) * (1 - layer)
        arr = np.maximum(arr, marks * 0.92)
    # bloom of the bright marks
    lum = marks.max(axis=2, keepdims=True)
    bright = marks * (lum > 0.45)
    bloom = blur(bright, T * 0.35) * (0.55 if layer is None else 0.35)
    arr = 1 - (1 - arr) * (1 - np.clip(bloom, 0, 1))
    die = Image.fromarray((np.clip(arr, 0, 1) * 255).astype(np.uint8))
    img.paste(die, (ox, oy))
    d = ImageDraw.Draw(img)

    # ------------------------------------------------ labels on the die
    total = sum(lut_count) or 1
    grid = np.zeros((len(GCOL), NY, NX), np.float32)
    for (x, y, s), cells in slices.items():
        for part, (g, _) in cells.items():
            if part.startswith("K"):
                grid[g, y, x] += 1
    win = 14
    taken = []
    lab_font = font("sans", int(T * 1.05), 600)
    order = sorted(range(len(GCOL)), key=lambda i: -lut_count[i])
    for gi in order:
        if lut_count[gi] < 0.015 * total and gi != classify.GROUP_INDEX["ls"]:
            continue
        gg = grid[gi]
        if gi == classify.GROUP_INDEX["ls"]:
            gg = np.zeros((NY, NX), np.float32)
            for bel, g in blocks.items():
                if g == gi:
                    m = BEL.match(bel)
                    gg[int(m[2]), int(m[1])] += 8
        c = np.cumsum(np.cumsum(np.pad(gg, ((1, 0), (1, 0))), 0), 1)
        s = c[win:, win:] - c[:-win, win:] - c[win:, :-win] + c[:-win, :-win]
        best = None
        for idx in np.argsort(s, axis=None)[::-1][:4000]:
            yy, xx = np.unravel_index(idx, s.shape)
            cx, cy = xx + win / 2, yy + win / 2
            if all(abs(cx - tx) > 26 or abs(cy - ty) > 7 for tx, ty in taken):
                best = (cx, cy)
                break
        if not best:
            continue
        taken.append(best)
        label = classify.GROUPS[gi][1]
        px, py = ox + best[0] * T, oy + best[1] * T
        tw = d.textlength(label, font=lab_font)
        hgt = int(T * 1.7)
        r = T * 0.40
        wtot = T * 0.55 + 2 * r + T * 0.45 + tw + T * 0.75
        bx0, by0 = px - wtot / 2, py - hgt / 2
        bx1, by1 = px + wtot / 2, py + hgt / 2
        ov = Image.new("RGBA", img.size, (0, 0, 0, 0))
        od = ImageDraw.Draw(ov)
        od.rounded_rectangle([bx0, by0, bx1, by1], radius=hgt // 2, fill=(7, 10, 18, 220),
                             outline=GCOL[gi] + (255,), width=max(2, T // 14))
        img = Image.alpha_composite(img.convert("RGBA"), ov).convert("RGB")
        d = ImageDraw.Draw(img)
        d.ellipse([bx0 + T * 0.55, py - r, bx0 + T * 0.55 + 2 * r, py + r], fill=GCOL[gi])
        d.text((bx0 + T * 0.55 + 2 * r + T * 0.45, py), label, font=lab_font, fill=TEXT, anchor="lm")

    # ------------------------------------------------ title, numbers, legend
    tf = font("sans", int(top_m * 0.36), 700)
    sf = font("sans", int(top_m * 0.15), 400)
    mf = font("mono", int(top_m * 0.13), 500)
    x0 = ox - pad
    d.text((x0, top_m * 0.12), a.title, font=tf, fill=(255, 255, 255))
    # numbers, top right
    nums = []
    if report:
        u = report.get("utilization", {})
        def ut(k, lab):
            if k in u and u[k]["used"]:
                nums.append((lab, f"{u[k]['used']:,} / {u[k]['available']:,}",
                             f"{100 * u[k]['used'] / u[k]['available']:.1f}%"))
        ut("TRELLIS_COMB", "LUT4")
        ut("TRELLIS_FF", "flip-flops")
        ut("DP16KD", "block RAM")
        ut("MULT18X18D", "multipliers")
        fm = report.get("fmax", {})
        for k, v in fm.items():
            nums.append(("Fmax", f"{v['achieved']:.1f} MHz", f"target {v['constraint']:.0f} MHz"))
            break
    xr = ox + dw + pad
    yy = top_m * 0.14
    statw = 0
    for lab, val, pct in nums:
        d.text((xr, yy), f"{lab}  {val}  {pct}", font=mf, fill=TEXT, anchor="ra")
        statw = max(statw, d.textlength(f"{lab}  {val}  {pct}", font=mf))
        yy += top_m * 0.165
    # the notes under the title, wrapped short of the numbers
    maxw = xr - statw - T * 2 - x0

    def wrap(f):
        out = []
        for note in a.note:
            line = ""
            for w in note.split():
                t = (line + " " + w).strip()
                if line and d.textlength(t, font=f) > maxw:
                    out.append(line)
                    line = w
                else:
                    line = t
            out.append(line)
        return out
    lines, step = wrap(sf), top_m * 0.19
    if len(lines) > 2:
        sf = font("sans", int(top_m * 0.125), 400)
        lines, step = wrap(sf), top_m * 0.145
    yy = top_m * 0.12 + top_m * 0.43
    for line in lines[:3]:
        d.text((x0, yy), line, font=sf, fill=(138, 163, 189))
        yy += step

    # legend: 2 rows of 4
    lf = font("sans", int(bot_m * 0.11), 500)
    pf = font("mono", int(bot_m * 0.08), 400)
    ly0 = oy + dh + pad + bot_m * 0.10
    colw = (dw + 2 * pad) / 4
    for i, (k, lab, _) in enumerate(classify.GROUPS):
        cx = x0 + (i % 4) * colw
        cy = ly0 + (i // 4) * bot_m * 0.28
        sz = bot_m * 0.12
        d.rounded_rectangle([cx, cy, cx + sz, cy + sz], radius=sz * 0.25, fill=GCOL[i])
        d.text((cx + sz * 1.5, cy - sz * 0.08), lab, font=lf, fill=TEXT)
        share = f"{100 * lut_count[i] / total:.1f}% of the LUT4 sites used"
        if k == "ls":
            nb = sum(1 for b, g in blocks.items() if g == i and "EBR" in b)
            share = f"{nb} block RAMs"
        d.text((cx + sz * 1.5, cy + sz * 1.05), share, font=pf, fill=DIM)
    foot = ["Each logic tile: four slices, two LUT4 sites over two flip-flops; a carry cell is one bar. "
            + ("The glow is the routed wiring, coloured by the net's owner." if layer is not None else
               "Placement only: not routed."),
            "Colours follow the RTL signal each cell is named after (fpga/classify.py): exact for "
            "registers and memories, the nearest named signal for logic."]
    for i, line in enumerate(foot):
        d.text((x0, ly0 + bot_m * (0.60 + 0.105 * i)), line, font=pf, fill=DIM)

    img.save(a.out, optimize=True)
    print(a.out, img.size, "routed" if routed else "placed", "LUTs by group:",
          {classify.GROUPS[i][0]: lut_count[i] for i in range(len(GCOL))})
    if a.web:
        w = a.web_width
        sm = img.resize((w, int(H * w / W)), Image.LANCZOS)
        if a.web.endswith(".webp"):
            sm.save(a.web, quality=88, method=6)
        elif a.web.endswith((".jpg", ".jpeg")):
            sm.save(a.web, quality=90, optimize=True, progressive=True)
        else:
            sm.save(a.web, optimize=True)
        print(a.web, sm.size)


if __name__ == "__main__":
    main()
