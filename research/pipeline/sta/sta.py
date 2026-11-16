#!/usr/bin/env python3
"""A small static timing pass over a Yosys JSON netlist mapped to mini.lib.

    sta.py mapped.json [TOP [ROWS [PROBES [CUTS]]]]

(A copy of research/smart-memory/sta/sta.py, with PROBES: a comma-separated
list of net names. For each, the latest arrival over its bits from any
start point is printed, and the longest path from it to any end point:
where in the cycle a signal is ready, and how much logic still follows it.
The probes must survive mapping: core.sh gives them the keep attribute.
CUTS: a comma-separated list of probes to treat as if they were registered:
each is an end point and then a start point of its own class "cut NAME",
so the table shows the longest path that remains between registers, which
is what that cut of the core into stages would leave per stage.)

Delays are technology-independent: the logical-effort model d = p + g * h
per gate (h = fanout, capped at FOMAX: a real flow buffers beyond that),
reported in FO4 inverter delays (5 tau). Start points are flip-flop
outputs, memory read data (a registered read: the memory's clock-to-output
is NOT included) and inputs; end points are flip-flop inputs, memory
address / data / enable inputs and outputs. Both are put in classes by
name, and the longest path between each pair of classes is printed, so the
paths that begin or end at a Local Store can be told from the rest.
"""
import json
import re
import sys
from collections import defaultdict

FOMAX = 6
# (parasitic p, logical effort g) in tau
GATE = {
    "INV": (1, 1), "BUF": (2, 1), "NAND2": (2, 4 / 3), "NAND3": (3, 5 / 3), "NOR2": (2, 5 / 3),
    "NOR3": (3, 7 / 3), "AOI21": (3, 2), "OAI21": (3, 2), "AOI22": (4, 2), "XOR2": (4, 4),
    "XNOR2": (4, 4), "MUX2": (4, 2),
}
FO4 = 5.0

START_CLASSES = [
    ("D-LS read data", r"^u_dls\.mem"),
    ("I-LS read data", r"^u_ils\.mem"),
    ("save table read", r"^ctab"),
    ("ir (instruction)", r"^ir\b"),
    ("state / phase", r"^(state|lt_ph|lt_k|rs_|rpend|rl_|user|ipend|spp_user)"),
    ("integer registers x", r"^x\["),
    ("capability registers", r"^caps\["),
    ("granule table", r"^gt[23]\["),
    ("overlay map", r"^xm_"),
    ("pc", r"^pc\b"),
    ("Transfer Unit", r"^u_tu\."),
    ("mul / div", r"^u_(mul|div)\."),
    ("CSRs, tag lookup", r"^(csr_|s_|u_c|u_e|u_t|sscratch|xslot|lt_|ct_entry|brom)"),
    ("inputs", r"^IN:"),
]
END_CLASSES = [
    ("D-LS port A addr/data/we", r"^u_dls\.mem:(RD_ADDR|RD_EN|WR_ADDR|WR_DATA|WR_EN):A"),
    ("D-LS port B (unit)", r"^u_dls\.mem:"),
    ("I-LS port A addr", r"^u_ils\.mem:(RD_ADDR|RD_EN):A"),
    ("I-LS port B (unit)", r"^u_ils\.mem:"),
    ("save table", r"^ctab:"),
    ("integer registers x", r"^x\["),
    ("capability registers", r"^caps\["),
    ("pc", r"^pc\b"),
    ("ir (instruction)", r"^ir\b"),
    ("state / phase", r"^(state|lt_ph|lt_k|rs_|rpend|rl_|user|ipend|spp_user)"),
    ("overlay map", r"^xm_"),
    ("Transfer Unit", r"^u_tu\."),
    ("mul / div", r"^u_(mul|div)\."),
    ("CSRs, tag lookup", r"^(csr_|s_|u_c|u_e|u_t|sscratch|xslot|lt_|ct_entry|brom)"),
    ("outputs", r"^OUT:"),
]


def classify(name, classes):
    for label, rx in classes:
        if re.search(rx, name):
            return label
    return "other: " + name.split("[")[0].split(".")[0]


def main():
    path = sys.argv[1]
    d = json.load(open(path))
    mods = d["modules"]
    top = sys.argv[2] if len(sys.argv) > 2 else next(m for m in mods if mods[m].get("attributes", {}).get("top"))
    m = mods[top]
    # a name for every net bit
    bitname = {}
    for n, nd in m["netnames"].items():
        hide = nd.get("hide_name", 0)
        for i, b in enumerate(nd["bits"]):
            if isinstance(b, int) and (b not in bitname or not hide):
                if b in bitname and not bitname[b].startswith("$"):
                    continue
                bitname[b] = f"{n}[{i}]" if len(nd["bits"]) > 1 else n
    arr = {}          # bit -> (arrival tau, start class)
    ends = []         # (bit, end name)
    drivers = {}      # bit -> gate index
    gates = []
    fan = defaultdict(int)
    for n, p in m["ports"].items():
        for i, b in enumerate(p["bits"]):
            if not isinstance(b, int):
                continue
            if p["direction"] == "input":
                arr[b] = (0.0, classify("IN:" + n, START_CLASSES))
            else:
                ends.append((b, "OUT:" + n))
    for cn, c in m["cells"].items():
        t = c["type"]
        conn = c["connections"]
        if t in GATE:
            ins = [b for pin, bs in conn.items() if pin != "Y" for b in bs]
            out = conn["Y"][0]
            gates.append((t, ins, out))
            drivers[out] = len(gates) - 1
            for b in ins:
                if isinstance(b, int):
                    fan[b] += 1
        elif "DFF" in t:
            q = conn["Q"][0]
            qn = bitname.get(q, cn)
            arr[q] = (0.0, classify(qn, START_CLASSES))
            for pin in ("D", "E", "R"):
                for b in conn.get(pin, []):
                    if isinstance(b, int):
                        ends.append((b, qn))
                        fan[b] += 1
        elif t == "$mem_v2":
            nm = cn.lstrip("\\")
            nrd = int(c["parameters"]["RD_PORTS"], 2)
            width = int(c["parameters"]["WIDTH"], 2)
            abits = int(c["parameters"]["ABITS"], 2)
            clk_en = c["parameters"]["RD_CLK_ENABLE"]
            for i, b in enumerate(conn["RD_DATA"]):
                port = i // width
                sync = clk_en[len(clk_en) - 1 - port] == "1"
                if isinstance(b, int):
                    if sync:
                        arr[b] = (0.0, classify(nm, START_CLASSES))
                    else:
                        raise SystemExit(f"{nm}: asynchronous read port not handled")
            for pin in ("RD_ADDR", "RD_EN", "WR_ADDR", "WR_DATA", "WR_EN"):
                bs = conn.get(pin, [])
                per = {"RD_ADDR": abits, "RD_EN": 1, "WR_ADDR": abits, "WR_DATA": width, "WR_EN": width}[pin]
                for i, b in enumerate(bs):
                    if isinstance(b, int):
                        ends.append((b, f"{nm}:{pin}:{'AB'[min(i // per, 1)]}"))
                        fan[b] += 1
        elif t == "$scopeinfo":
            pass
        elif t in ("$anyseq", "$anyconst"):        # a cut point (core.sh CUTS): a start point of its own
            for b in conn["Y"]:
                if isinstance(b, int):
                    arr[b] = (0.0, "cut " + bitname.get(b, "?").split("[")[0])
        else:
            raise SystemExit(f"unknown cell type {t}")

    # arrival per start class: for every net, the best arrival from each class
    # (kept as a dict class -> tau), computed in topological order
    order = []
    seen = set()
    for gi0 in range(len(gates)):
        if gi0 in seen:
            continue
        stack = [(gi0, 0)]
        while stack:
            gi, k = stack.pop()
            if k == 0:
                if gi in seen:
                    continue
                seen.add(gi)
                stack.append((gi, 1))
                for b in gates[gi][1]:
                    if isinstance(b, int) and b in drivers and drivers[b] not in seen:
                        stack.append((drivers[b], 0))
            else:
                order.append(gi)
    cutbits = {}
    for cn in (sys.argv[5].split(",") if len(sys.argv) > 5 and sys.argv[5] else []):
        for n, nd in m["netnames"].items():
            if n == cn:
                for b in nd["bits"]:
                    if isinstance(b, int):
                        cutbits[b] = cn
    cut_ends = []
    at = {}
    for b, (t0, cl) in arr.items():
        at[b] = {cl: (t0, 0)}
    for gi in order:
        t, ins, out = gates[gi]
        p, g = GATE[t]
        dly = p + g * min(max(fan[out], 1), FOMAX)
        res = {}
        for b in ins:
            if not isinstance(b, int):
                continue
            for cl, (ta, lv) in at.get(b, {}).items():
                if cl not in res or ta + dly > res[cl][0]:
                    res[cl] = (ta + dly, lv + 1)
        at[out] = res
        if out in cutbits:
            cut_ends.append((out, "cut " + cutbits[out], res))
            at[out] = {"cut " + cutbits[out]: (0.0, 0)}
    for b, cn in cutbits.items():
        if b not in drivers and b in at and not any(k.startswith("cut ") for k in at[b]):
            cut_ends.append((b, "cut " + cn, at[b]))
            at[b] = {"cut " + cn: (0.0, 0)}
    table = {}
    for b, en, res in cut_ends:
        for cl, (ta, lv) in res.items():
            key = (cl, en)
            if key not in table or ta > table[key][0]:
                table[key] = (ta, lv, en)
    for b, en in ends:
        ec = classify(en, END_CLASSES)
        for cl, (ta, lv) in at.get(b, {}).items():
            key = (cl, ec)
            if key not in table or ta > table[key][0]:
                table[key] = (ta, lv, en)
    probes = [x for x in sys.argv[4].split(",") if x] if len(sys.argv) > 4 else []
    if probes:
        # the longest path from a net to any end point: backwards over the gates
        req = {b: 0.0 for b, _ in ends}
        for gi in reversed(order):
            t, ins, out = gates[gi]
            if out not in req:
                continue
            p, g = GATE[t]
            dly = p + g * min(max(fan[out], 1), FOMAX)
            for b in ins:
                if isinstance(b, int) and req.get(b, -1.0) < req[out] + dly:
                    req[b] = req[out] + dly
        print(f"{'probe':<20} {'bits':>4} {'arrives':>8} {'then':>8} {'total':>8}   (FO4)")
        for pn in probes:
            bits = []
            for n, nd in m["netnames"].items():
                if n == pn or n == "\\" + pn:
                    bits = [b for b in nd["bits"] if isinstance(b, int)]
            if not bits:
                print(f"{pn:<20} not in the netlist")
                continue
            a = max((max((v[0] for v in at.get(b, {}).values()), default=0.0) for b in bits), default=0.0)
            r = max((req.get(b, 0.0) for b in bits), default=0.0)
            worst = max((max((v[0] for v in at.get(b, {}).values()), default=0.0) + req.get(b, 0.0) for b in bits))
            print(f"{pn:<20} {len(bits):>4} {a / FO4:8.1f} {r / FO4:8.1f} {worst / FO4:8.1f}")
        print()
    rows = sorted(table.items(), key=lambda kv: -kv[1][0])
    print(f"{len(gates)} gates, {len(ends)} end points; delays in FO4 (tau / {FO4:g}), fanout capped at {FOMAX}")
    print(f"{'FO4':>6} {'gates':>5}  {'from':<24} {'to':<28} worst end point")
    for (sc, ec), (ta, lv, en) in rows[:int(sys.argv[3]) if len(sys.argv) > 3 else 60]:
        print(f"{ta / FO4:6.1f} {lv:5d}  {sc:<24} {ec:<28} {en}")
    print()
    print("worst path by start class:")
    best = {}
    for (sc, ec), v in table.items():
        if sc not in best or v[0] > best[sc][0]:
            best[sc] = (v[0], v[1], ec)
    for sc, (ta, lv, ec) in sorted(best.items(), key=lambda kv: -kv[1][0]):
        print(f"{ta / FO4:6.1f} {lv:5d}  {sc:<24} -> {ec}")
    print()
    print("worst path by end class:")
    best = {}
    for (sc, ec), v in table.items():
        if ec not in best or v[0] > best[ec][0]:
            best[ec] = (v[0], v[1], sc)
    for ec, (ta, lv, sc) in sorted(best.items(), key=lambda kv: -kv[1][0]):
        print(f"{ta / FO4:6.1f} {lv:5d}  {ec:<28} <- {sc}")


main()
