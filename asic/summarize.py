#!/usr/bin/env python3
"""Summarises a LibreLane run of asic/run.sh as text.

    asic/summarize.py RUN_DIR PERIOD_NS > summary.txt

Area by cell class (from the final metrics), the SRAM macros, the clock
(worst setup slack per corner from the post-route STA: achievable period =
target period - worst slack), the critical path at the typical corner split
into cell and wire delay, and the run time of every step.
"""
import glob
import json
import os
import re
import sys

run, period = sys.argv[1], float(sys.argv[2])
# the metrics of the run's last step (final/metrics.json is only written when
# the flow gets to its end)
last = max((d for d in glob.glob(os.path.join(run, "[0-9]*-*"))
            if os.path.exists(os.path.join(d, "state_out.json"))),
           key=lambda d: int(os.path.basename(d).split("-")[0]))
m = json.load(open(os.path.join(last, "state_out.json")))["metrics"]
um2 = lambda v: f"{v / 1e6:9.3f} mm2"   # noqa: E731

print(f"run: {run}")
print(f"clock target: {period:g} ns ({1000 / period:.1f} MHz)\n")

print("== area")
print(f"die                {um2(m['design__die__area'])}")
print(f"core               {um2(m['design__core__area'])}")
print(f"SRAM macros        {um2(m['design__instance__area__macros'])}"
      f"   ({m['design__instance__count__macros']} x gf180mcu_fd_ip_sram__sram512x8m8wm1, 0.2094 mm2 each)")
print(f"standard cells     {um2(m['design__instance__area__stdcell'])}"
      f"   ({m['design__instance__count__stdcell']} cells)")
print(f"utilisation        {m['design__instance__utilization'] * 100:.1f}% of the core"
      f" (standard cells alone {m['design__instance__utilization__stdcell'] * 100:.1f}% of the area outside the macros)\n")

print("== standard cells by class (count, area)")
classes = sorted({k.split("class:")[1] for k in m if "__class:" in k})
for c in classes:
    n = m.get(f"design__instance__count__class:{c}", 0)
    a = m.get(f"design__instance__area__class:{c}", 0)
    if c != "macro":
        print(f"  {c:34s} {n:9d}  {um2(a)}")
print()

print("== timing, after routing (OpenSTA, parasitics from OpenRCX)")
corners = sorted({k.split("corner:")[1] for k in m if k.startswith("timing__setup__ws__corner:")})
for c in corners:
    ws = m[f"timing__setup__ws__corner:{c}"]
    tns = m.get(f"timing__setup__tns__corner:{c}", 0)
    hws = m.get(f"timing__hold__ws__corner:{c}", 0)
    p = period - ws
    r2r = m.get(f"timing__setup_r2r__ws__corner:{c}")
    rr = f"  reg-to-reg WNS {r2r:8.3f} ns -> {period - r2r:6.2f} ns" if r2r is not None else ""
    print(f"  {c:20s} setup WNS {ws:8.3f} ns  TNS {tns:10.2f}  hold WS {hws:7.3f}"
          f"  -> period {p:6.2f} ns = {1000 / p:6.1f} MHz{rr}")
print()


def path(rpt):
    """The first (worst) path of an OpenSTA max report: start, end, cell and
    wire delay (an input pin's increment is the wire to it)."""
    txt = open(rpt).read()
    blk = txt[txt.index("Startpoint:"):]
    blk = blk[:blk.index("slack")]
    start = re.search(r"Startpoint: (.*)", blk).group(1)
    end = re.search(r"Endpoint: (.*)", blk).group(1)
    cell = wire = 0.0
    hops = 0
    # the data path: from the startpoint's clock pin to "data arrival time"
    in_data = False
    for ln in blk.split("\n"):
        if "data arrival time" in ln:
            break
        mm = re.match(r"^\s*((?:[\d.e+-]+\s+)+)([v^])\s+(\S+)\s+\((\S+)\)", ln)
        if not mm:
            continue
        nums = mm.group(1).split()
        pin, typ = mm.group(3), mm.group(4)
        if not in_data:
            # skip the clock network up to the launching register's clock pin
            if re.search(r"/(CLK|CLKN)$", pin) and typ != "clock":
                in_data = True
            continue
        incr = float(nums[-2])
        if len(nums) >= 4:          # an output pin: fanout cap slew delay time
            cell += incr
            hops += 1
        else:                       # an input pin: slew delay time
            wire += incr
    return start, end, cell, wire, hops


tt = sorted(glob.glob(os.path.join(run, "*-openroad-stapostpnr", "nom_tt_*")))
if tt:
    s, e, c, w, h = path(os.path.join(tt[0], "max.rpt"))
    print(f"== critical path ({os.path.basename(tt[0])})")
    print(f"  from {s}\n  to   {e}")
    print(f"  {h} cells: {c:.2f} ns in cells, {w:.2f} ns in wires\n")

print("== run time per step (h:mm:ss)")
tot = 0.0
for d in sorted(glob.glob(os.path.join(run, "[0-9]*-*"))):
    rt = os.path.join(d, "runtime.txt")
    if not os.path.exists(rt):
        continue
    t = open(rt).read().strip()
    hh, mi, ss = t.split(":")
    sec = int(hh) * 3600 + int(mi) * 60 + float(ss)
    tot += sec
    if sec >= 1:
        print(f"  {os.path.basename(d):45s} {t[:8]}")
print(f"  {'total':45s} {int(tot // 3600)}:{int(tot % 3600 // 60):02d}:{int(tot % 60):02d}")
