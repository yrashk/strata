#!/usr/bin/env python3
"""Prints the zoom box for asic/render.sh: 800 x 600 um around the right
edge of core 0's I-LS, half-way up (its macro row 7, byte 7, as
asic/mkconfig.py places it): the macros' edge, the logic strip's cells and
the wiring.

    asic/zoombox.py MACRO_PLACEMENT.cfg      ->  x0,y0,x1,y1
"""
import re
import sys

for line in open(sys.argv[1]):
    n, x, y, _ = line.split()
    if re.match(r"(g_core\[0\]\.u_core\.)?u_ils\.g_r\[7\]\.g_b\[7\]\.u_m$", n):
        x, y = float(x) + 431.86, float(y) + 242.0
        print(f"{x - 350:.0f},{y - 300:.0f},{x + 450:.0f},{y + 300:.0f}")
        break
else:
    sys.exit("zoombox: no u_ils.g_r[7].g_b[7] macro")
