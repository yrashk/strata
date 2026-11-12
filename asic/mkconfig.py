#!/usr/bin/env python3
"""Writes the LibreLane configuration and the macro placement for one run.

    asic/mkconfig.py OUTDIR NCORES PERIOD_NS MACROS.txt

MACROS.txt lists the SRAM macro instances of the flattened design, one per
line (asic/run.sh gets them from Yosys). Each 64 KiB store (a core's I-LS or
D-LS, or T2) is 16 rows x 8 columns of 512 x 8 macros, named
<store>.g_r[ROW].g_b[BYTE].u_m; a core's save table is 11 256 x 8 macros
side by side, <core>.u_ctab.g_b[BYTE].u_m.

Floorplan, in micrometres. A core is a tile: its I-LS block on the left, a
strip for its logic in the middle (the save table's macros at its foot), its
D-LS block on the right. One core is one tile. Several cores: tiles in rows
of up to three, with T2 and the system logic (far bus, inboxes, granule
walker) in a band below them.
"""
import json
import os
import re
import sys

out, ncores, period, macro_list = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
here = os.path.dirname(os.path.abspath(__file__))
pdk = os.environ.get("ASIC_PDK", "gf180mcuD")
threads = int(os.environ.get("ASIC_THREADS", "8"))

# the macros (their LEF: SIZE 431.860 BY 484.880, and BY 340.880)
MACRO = "gf180mcu_fd_ip_sram__sram512x8m8wm1"
MACRO_CT = "gf180mcu_fd_ip_sram__sram256x8m8wm1"
MW, MH = 431.86, 484.88
MH_CT = 340.88
# The macros' pins are all on one edge (the bottom, placed N). Rows go in
# pairs facing each other: the lower row flipped (FS, pins on top), a
# channel CH for the pins' wiring, the upper row N; between pairs the backs
# are GB apart. (With every row N over a 36 um channel, the channels could
# not take the wiring: 400,000 shorts in Metal2 / Metal3 after the first
# detailed-routing pass.)
GX, GB, CH = 12.0, 12.0, 120.0
COLS, ROWS = 8, 16           # one 64 KiB store


def rows_h(rows, mh):
    return (rows // 2) * (2 * mh + CH + GB)


def row_y(rr, rows, mh):
    """Row rr (0 at the top) of a grid of `rows`: its y offset and orientation."""
    k = rows - 1 - rr                    # from the bottom
    pair, upper = divmod(k, 2)
    y = GB / 2 + pair * (2 * mh + CH + GB) + (mh + CH if upper else 0)
    return y, "N" if upper else "FS"


SW = COLS * (MW + GX)        # a store block
SH = rows_h(ROWS, MH)
LW = float(os.environ.get("ASIC_STRIP_UM", "3000"))  # a core's logic strip
M = 120.0                    # die margin (pins, the PDN ring)

names = [l.strip() for l in open(macro_list) if l.strip()]
stores, ctabs = {}, {}
for n in names:
    m = re.match(r"(.*)\.g_r\[(\d+)\]\.g_b\[(\d+)\]\.u_m$", n)
    c = re.match(r"(?:(.*)\.)?u_ctab\.g_b\[(\d+)\]\.u_m$", n)
    if m:
        stores.setdefault(m.group(1), []).append((int(m.group(2)), int(m.group(3)), n))
    elif c:
        ctabs.setdefault(c.group(1) or "", []).append((int(c.group(2)), n))
    else:
        sys.exit(f"unexpected macro instance name {n}")


def place_store(cells, x0, y0, rows=ROWS, cols=COLS, flip_cols=False):
    """A store's macros as a grid at (x0, y0); row 0 at the top. With more
    than ROWS rows of one store wanted as fewer, taller grids are folded
    (T2 below the cores is 8 rows of 16)."""
    lines = []
    for r, b, n in sorted(cells):
        rr, cc = r, b
        if rows != ROWS:                 # fold: row r -> (r % rows, b + COLS * (r // rows))
            rr, cc = r % rows, b + COLS * (r // rows)
        if flip_cols:
            cc = cols - 1 - cc
        x = x0 + cc * (MW + GX) + GX / 2
        dy, o = row_y(rr, rows, MH)
        lines.append(f"{n} {x:.2f} {y0 + dy:.2f} {o}")
    return lines


def place_ctab(cells, x0, y0, per_row=3):
    """A save table's macros at the foot of a logic strip [x0, x0 + LW)."""
    w = per_row * (MW + GX)
    rows = (len(cells) + per_row - 1) // per_row
    rows += rows % 2
    lines = []
    for b, n in sorted(cells):
        r, c = divmod(b, per_row)
        x = x0 + (LW - w) / 2 + c * (MW + GX) + GX / 2
        dy, o = row_y(rows - 1 - r, rows, MH_CT)
        lines.append(f"{n} {x:.2f} {y0 + dy:.2f} {o}")
    return lines


placement = []
tile_w, tile_h = 2 * SW + LW, SH
if ncores == 1:
    die_w, die_h = tile_w + 2 * M, tile_h + 2 * M
    placement += place_store(stores["u_ils"], M, M)
    placement += place_store(stores["u_dls"], M + SW + LW, M, flip_cols=True)
    placement += place_ctab(ctabs[""], M + SW, M)
else:
    per_row = min(ncores, 3)
    nrows = (ncores + per_row - 1) // per_row
    t2_w, t2_h = 2 * COLS * (MW + GX), rows_h(ROWS // 2, MH)
    band_h = t2_h + 600.0         # T2 plus room for the system logic around it
    die_w = per_row * tile_w + 2 * M
    die_h = nrows * tile_h + band_h + 2 * M
    for c in range(ncores):
        tr, tc = divmod(c, per_row)
        x0 = M + tc * tile_w
        y0 = M + band_h + (nrows - 1 - tr) * tile_h
        p = f"g_core[{c}].u_core"
        placement += place_store(stores[f"{p}.u_ils"], x0, y0)
        placement += place_store(stores[f"{p}.u_dls"], x0 + SW + LW, y0, flip_cols=True)
        placement += place_ctab(ctabs[p], x0 + SW, y0)
    t2 = [k for k in stores if k.startswith("u_t2")]
    if t2:
        placement += place_store(stores[t2[0]], (die_w - t2_w) / 2, M + 300.0,
                                 rows=ROWS // 2, cols=2 * COLS)

if len(placement) != len(names):
    sys.exit(f"placed {len(placement)} of {len(names)} macros")
with open(os.path.join(out, "macro_placement.cfg"), "w") as f:
    f.write("\n".join(placement) + "\n")

sram = "pdk_dir::libs.ref/gf180mcu_fd_ip_sram"
cfg = {
    "meta": {
        "version": 2,
        "flow": "Classic",
        # signoff checks that take hours on a die this size and say nothing
        # about area or timing; see asic/README.md
        "substituting_steps": {
            # OpenSTA's worst_clock_skew did not finish in 25 minutes on the
            # ideal (pre-CTS) clock of one core; the timing that matters is
            # STAPostPNR's
            "OpenROAD.STAPrePNR": None,
            "OpenROAD.STAMidPNR": None,
            "Magic.SpiceExtraction": None,
            "Checker.IllegalOverlap": None,
            "Magic.WriteLEF": None,
            "Odb.CheckDesignAntennaProperties": None,   # needs Magic's LEF
            "Magic.StreamOut": None,
            "KLayout.XOR": None,
            "Checker.XOR": None,
        },
    },
    "DESIGN_NAME": "strata_core" if ncores == 1 else "strata_asic_top",
    "VERILOG_FILES": ["dir::src/strata.v"],
    "SYNTH_PARAMETERS": [f"NCORES={ncores}"],
    # ABC: the OpenROAD-flow-scripts area script (strash; dch; map). LibreLane's
    # default "AREA 0" (fx; mfs; resyn2; retime; choice2; amap) ran over 75
    # minutes on one core without finishing.
    "SYNTH_STRATEGY": os.environ.get("ASIC_SYNTH_STRATEGY", "AREA 3"),
    # several cores: synthesise module by module, flatten afterwards (the
    # flat 2- and 6-core netlists made ABC run out of the container's 16 GB)
    "SYNTH_HIERARCHY_MODE": "flatten" if ncores == 1 else "deferred_flatten",
    "CLOCK_PORT": "clk",
    "CLOCK_PERIOD": period,
    # input / output delays: 5% of the period (LibreLane's default is 20%).
    # The pins are the far bus, gift and granule ports, which on a chip are
    # wires to the bus and the other cores, not board I/O.
    "IO_DELAY_CONSTRAINT": 5,
    "FP_SIZING": "absolute",
    "DIE_AREA": [0, 0, round(die_w, 2), round(die_h, 2)],
    # low, with two sites of padding per cell: the strips have room, and the
    # register-file and granule-table read multiplexers routed into a million
    # Metal2 / Metal3 shorts at 30% (and the placer packed them at 60%)
    "PL_TARGET_DENSITY_PCT": int(os.environ.get("ASIC_DENSITY", "22")),
    # global placement without the routability and timing loops: with them,
    # one core's placement oscillated (overflow ~0.5) for 90 minutes and
    # 21,000 iterations without converging
    "PL_ROUTABILITY_DRIVEN": False,
    "PL_TIMING_DRIVEN": False,
    # buffers that the resizer puts on long wires over a macro block move to
    # the channels between macro rows (up to half a macro's height away)
    "PL_MAX_DISPLACEMENT_X": 1000,
    "PL_MAX_DISPLACEMENT_Y": 600,
    "GPL_CELL_PADDING": 2,
    "DPL_CELL_PADDING": 2,
    "MACROS": {
        mac: {
            "gds": [f"{sram}/gds/{mac}.gds"],
            "lef": [f"{sram}/lef/{mac}.lef"],
            "lib": {"*": [f"{sram}/lib/{mac}__tt_025C_5v00.lib"]},
            "vh": [f"dir::{mac}.bb.v"],
            "instances": {},
        } for mac in (MACRO, MACRO_CT)
    },
    "MACRO_PLACEMENT_CFG": "dir::macro_placement.cfg",
    "PDN_MACRO_CONNECTIONS": [".*u_m VDD VSS VDD VSS"],
    "PDN_CFG": "dir::pdn_cfg.tcl",
    "FP_MACRO_HORIZONTAL_HALO": 6,
    "FP_MACRO_VERTICAL_HALO": 6,
    # split long wires before the slew / capacitance repair: the address and
    # data nets of a store reach 128 macros over 8 mm
    "DESIGN_REPAIR_MAX_WIRE_LENGTH": float(os.environ.get("ASIC_MAX_WIRE_UM", "800")),
    # without this the resizer buffers with delay cells (dlyb_1: slews over
    # 1 ns, 1.6 ns per stage); hold repair then uses buffers too
    "EXTRA_EXCLUDED_CELLS": ["gf180mcu_fd_sc_mcu7t5v0__dly*"],
    # global routing: at most 10 rip-up iterations, leaving what congestion
    # is left to the detailed router (one core spent 4 minutes per
    # iteration, 50 allowed)
    "GRT_OVERFLOW_ITERS": 10,
    "GRT_ALLOW_CONGESTION": True,
    "DRT_THREADS": threads,
    "DRT_OPT_ITERS": int(os.environ.get("ASIC_DRT_ITERS", "64")),
    "STA_THREADS": min(threads, 4),
    # post-route STA at the three nominal-interconnect corners (LibreLane's
    # nine took an hour on one core, mostly in the clock-skew reports)
    "STA_CORNERS": ["nom_tt_025C_5v00", "nom_ss_125C_4v50", "nom_ff_n40C_5v50"],
    "PRIMARY_GDSII_STREAMOUT_TOOL": "klayout",
    "RUN_MAGIC_DRC": False,
    "RUN_KLAYOUT_DRC": False,
    "RUN_LVS": False,
    "RUN_EQY": False,
    "RUN_LINTER": False,
    "RUN_IRDROP_REPORT": False,
    "RUN_KLAYOUT_XOR": False,
    "RUN_MAGIC_STREAMOUT": False,
    "RUN_MAGIC_WRITE_LEF": False,
    # no post-CTS timing repair: OpenROAD's repair_timing (2026-02-17) died
    # without a message in its first iteration three times on one core
    # (with and without gate cloning); the clock reported is what placement,
    # design repair (slew, capacitance, long wires) and CTS give
    "RUN_POST_CTS_RESIZER_TIMING": False,
    "RUN_POST_GRT_RESIZER_TIMING": False,
    "RUN_POST_GRT_DESIGN_REPAIR": False,
    "ERROR_ON_MAGIC_DRC": False,
    "ERROR_ON_LVS_ERROR": False,
    "ERROR_ON_TR_DRC": os.environ.get("ASIC_DRT_STRICT", "1") == "1",
}
with open(os.path.join(out, "config.json"), "w") as f:
    json.dump(cfg, f, indent=2)
print(f"die {die_w / 1000:.3f} x {die_h / 1000:.3f} mm, {len(placement)} macros")
