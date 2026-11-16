#!/usr/bin/env python3
"""Tables from the profiler's PROF lines (prof/ls_prof.sv).

    report.py NAME.out [NAME.out ...]

One block per run, all cores summed. "Busy" cycles leave out reset, halt
and the cycles an instruction only waits for something outside the core
(another core's gift, a device, the far bus behind its own transfers).
"""
import sys
from collections import defaultdict

STATES = ["RST", "F0", "F1", "EX", "CT", "LD", "LG", "LT", "LW", "DV", "AM", "HALT", "RQ"]
# kinds whose extra S_EX cycles are waits for the outside world
WAITS = {"cap", "cap2", "twait", "tany", "sys", "tamo"}


def pct(a, b):
    return f"{100.0 * a / b:5.1f}%" if b else "    -"


def run(path):
    st = defaultdict(int)
    ex = defaultdict(int)
    ret = defaultdict(int)
    v = defaultdict(lambda: defaultdict(int))
    iss = defaultdict(lambda: [0, 0])
    hd = defaultdict(int)
    hi = defaultdict(int)
    for line in open(path, errors="replace"):
        if not line.startswith("PROF "):
            continue
        f = line.split()
        k = f[2]
        if k == "state":
            st[STATES[int(f[3])]] += int(f[4])
        elif k == "kind":
            ex[f[3]] += int(f[4])
            ret[f[3]] += int(f[5])
        elif k == "iss":
            iss[(f[3], int(f[4]))][0] += int(f[5])
            iss[(f[3], int(f[4]))][1] += int(f[6])
        elif k == "isssup":
            iss[(f[3], "sup")][0] += int(f[4])
            iss[(f[3], "sup")][1] += int(f[5])
        elif k == "hist":
            hd[int(f[3])] += int(f[4])
            hi[int(f[3])] += int(f[5])
        elif k == "tues":
            v["tues"][int(f[3])] += int(f[4])
        elif k != "words":
            for i, x in enumerate(f[3:]):
                v[k][i] += int(x)
    total = sum(st.values())
    live = total - st["HALT"] - st["RST"]
    instr = sum(ret.values())
    # S_EX cycles beyond one per retired instruction
    extra = {k: ex[k] - ret[k] for k in ex}
    wait = sum(c for k, c in extra.items() if k in WAITS)
    xfer_q = extra.get("xfer", 0)                 # the unit's queue was full / tag busy
    hz = v["stall"][1] + v["stall"][2]            # loads / stores waiting for a transfer
    f0s = v["stall"][0]
    busy = live - wait - hz - f0s - xfer_q
    print(f"== {path}")
    print(f"cycles {total}, not reset/halt {live}, instructions {instr}")
    print(f"  waiting (gifts, twait, tany, halt drain, atomics) {wait} ({pct(wait, live)} of live)")
    print(f"  loads/stores waiting for a transfer {hz} ({pct(hz, live)}), fetch waiting {f0s} ({pct(f0s, live)}), "
          f"issue waiting {xfer_q} ({pct(xfer_q, live)})")
    print(f"  busy cycles {busy}: {busy / instr:.2f} per instruction" if instr else "")
    print("  busy cycles by state:")
    f0 = st["F0"] - f0s
    exb = st["EX"] - wait - hz - xfer_q
    for name, c in [("F0 fetch address -> I-LS", f0), ("F1 instruction word", st["F1"]), ("EX", exb),
                    ("LD load data", st["LD"]), ("LG/LT/LW tag lookup", st["LG"] + st["LT"] + st["LW"]),
                    ("DV multiply/divide", st["DV"]), ("CT save table", st["CT"]), ("AM far atomic", st["AM"]),
                    ("RQ", st["RQ"])]:
        if c:
            print(f"    {name:<28} {c:>12} {pct(c, busy)}")
    print("  instructions by kind (share of instructions; S_EX cycles each):")
    for k, c in sorted(ret.items(), key=lambda kv: -kv[1]):
        if c:
            print(f"    {k:<8} {c:>12} {pct(c, instr)}  {ex[k] / c:8.2f}")
    m = v["mode"]
    print(f"  user cycles {m[0]} ({pct(m[0], m[0] + m[1])}), supervisor {m[1]}; instructions user {m[2]}, supervisor {m[3]}")
    p = v["ports"]
    sh = v["share"]
    u = v["unified"]
    print("  Local Store port use (cycles; share of live cycles):")
    print(f"    I-LS port A read  {p[0]:>12} {pct(p[0], live)}   of them the word fetched last: {u[2]} ({pct(u[2], p[0])})")
    print(f"    D-LS port A read  {p[1]:>12} {pct(p[1], live)}   (tag lookup {sh[4]})")
    print(f"    D-LS port A write {p[2]:>12} {pct(p[2], live)}   (linst {sh[5]})")
    print(f"    D-LS port B read  {p[3]:>12} {pct(p[3], live)}   (tput)")
    print(f"    D-LS port B write {p[4]:>12} {pct(p[4], live)}   (tget)")
    print(f"    I-LS port B write {p[5]:>12} {pct(p[5], live)}   (tgetx)")
    print(f"    D-LS used at all  {sh[2]:>12} {pct(sh[2], live)}   both ports at once {sh[0]} ({pct(sh[0], sh[2])} of its use)")
    print(f"    I-LS used at all  {sh[3]:>12} {pct(sh[3], live)}   both ports at once {sh[1]}")
    print(f"    one memory for both: used {u[0]} ({pct(u[0], live)}), core and unit in the same cycle {u[1]} "
          f"({pct(u[1], live)} of live cycles, {pct(u[1], p[3] + p[4] + p[5])} of the unit's beats)")
    t = v["tues"]
    tb = v["tubusy"]
    beats = tb[1] + tb[2]
    print(f"  Transfer Unit: busy {tb[0]} cycles ({pct(tb[0], live)} of live); request {t[1]}, transfer {t[2]}, retire {t[3]}; "
          f"beats in {tb[1]}, out {tb[2]}" + (f"; {(t[1] + t[2] + t[3]) / beats:.2f} cycles per beat" if beats else ""))
    names = {2: "T2", 3: "T3", 4: "device", 5: "core control", "sup": "(issued in supervisor mode)"}
    for (kind, sp), (n, b) in sorted(iss.items(), key=lambda kv: str(kv[0])):
        if n:
            print(f"    {kind:<5} {names.get(sp, sp):<28} {n:>9} commands {b:>12} bytes  ({b / n:8.1f} per command)")
    pr = v["pairs"]
    ld, stc = ret["load"], ret["store"]
    print(f"  loads {ld}, stores {stc}: load then use by the next instruction {pr[0]} ({pct(pr[0], ld)} of loads); "
          f"load-op-store to one address {pr[1]} ({pct(pr[1], stc)} of stores)")
    print(f"    sp/gp-relative loads {pr[2]} ({pct(pr[2], ld)}), stores {pr[3]} ({pct(pr[3], stc)}); "
          f"64-bit loads {pr[4]} ({pct(pr[4], ld)}), stores {pr[5]} ({pct(pr[5], stc)})")
    for name, h in (("D-LS port A", hd), ("I-LS fetch", hi)):
        tot = sum(h.values())
        if not tot:
            continue
        top = sorted(h.items(), key=lambda kv: -kv[1])
        acc = 0
        cover = []
        for n, (b, c) in enumerate(top, 1):
            acc += c
            if n in (1, 2, 4, 8, 16):
                cover.append(f"{n} KiB: {100.0 * acc / tot:.1f}%")
        print(f"  {name}: {sum(1 for c in h.values() if c)} of 64 1-KiB blocks touched; the busiest blocks hold " + ", ".join(cover))
    print()


for a in sys.argv[1:]:
    run(a)
