#!/usr/bin/env python3
"""Cycles per instruction of pipelined Strata cores, over an instruction trace.

    strata-rtl -t TRACE ... ; pipe.py TRACE [NAME]     (TRACE may be - or *.gz)

The trace has one line per fetched instruction, `core pc ir` (sim/main.cpp,
written in S_F1). Each core's stream is timed on its own by an in-order,
single-issue model: an instruction enters execute at

    issue = max(the cycle the one before it lets it in,
                the cycles its source registers / capabilities are ready)

and lets the next one in at issue + 1 + its extra cycles + its redirect
penalty. Only "busy" cycles are counted, as the profiler of
research/smart-memory does: an instruction waiting for the world (a gift,
`twait`, `tany`, a full transfer queue, a load on an in-flight range) costs
nothing here, in every design alike. A far atomic in flight (S_AM) and the
tag-lookup sequencer (S_LG/LT/LW) are counted with fixed costs measured by
that profiler (AM_CYC, LTAG_CYC), equal in every design.

What the trace does not say is inferred from the next instruction of the
same core: a branch was taken when the next pc is not pc + 4; any other
instruction followed by a pc other than pc + 4 that is not a jump trapped
(or was stopped). The last instruction of each core is not counted.

The designs (penalties in cycles; DESIGNS below has the numbers):

  mc       today's multi-cycle core with STREAM = 0: F0, F1, EX (+ LD, DV,
           CT): a check of the model against the profiler's 3.22 etc.
  p3       three stages, F | X | W, at today's clock: the fetch reads one
           instruction per cycle (the I-LS word holds two); a transfer of
           control redirects the fetch from X in the same cycle (the target
           to the I-LS address, the ir -> pc path, 0.73 of today's deepest),
           so the instruction after it is lost: 1. A load's data returns in
           W: an instruction that uses it right away waits 1.
  p3r      as p3, the redirect registered first: 2.
  p3f      as p3, load data forwarded from the D-LS into X: no load-use wait.
  p3b      as p3, with p5b's predictor (below) in F: right 0, wrong 1.
  p5       F | I | D | E | M | W (F0, F1, decode/read, execute, memory,
           write back) at a faster clock: control resolved in E and the
           fetch redirected from a register: 3; jal's target in D: 2; load
           use 1; a capability written by the instruction just before is
           read in D (its granule is looked up there): 1; mul 6 / mulhu 8
           extra (the 32 x 32 multiplier at half today's period: two cycles
           per partial product); the save table read in D: csave /
           crestore cost no extra cycle.
  p5s      p5 with static prediction in D: backward branches taken (2 when
           right), forward not taken; a wrong guess 3.
  p5b      p5 with a predictor in F: 256 two-bit counters, a 64-entry
           branch target buffer (branches, jal), an 8-entry return stack
           (jal/jalr with rd != 0 push, `jalr x0, x1` pops): right 0, wrong 3;
           a taken branch or jal that misses the buffer is handled as in p5s.
  bN       barrel: N hardware threads in turn on p5's stages without
           forwarding or interlocks. With N >= 4 every result and every
           redirect is there by the thread's next turn, so each instruction
           of a thread costs N cycles, multiply and divide max(N, 1 + extra);
           reported per thread (throughput is N threads' worth when N are
           ready).
"""
import gzip
import sys
from collections import defaultdict

AM_CYC = 8.0     # S_AM cycles per far atomic: StrataOS session, 4,378,264 / 547,283 (research/smart-memory)
LTAG_CYC = 8.05  # S_LG + S_LT + S_LW per ltag / linst: swcache, 44,456 / 5,523

# per design: redirect from execute, jal (target known in D), load latency,
# capability latency, mul / mulhu / div extra, save-table extra,
# branch prediction ("none", "btfn", "bp"), right-taken cost, wrong cost
DESIGNS = {
    "p3":  dict(red=1, jal=1, ld=2, cap=1, mul=3, mulhu=4, div=65, ct=1, bp="none"),
    "p3r": dict(red=2, jal=2, ld=2, cap=1, mul=3, mulhu=4, div=65, ct=1, bp="none"),
    "p3f": dict(red=1, jal=1, ld=1, cap=1, mul=3, mulhu=4, div=65, ct=1, bp="none"),
    "p3b": dict(red=1, jal=1, ld=2, cap=1, mul=3, mulhu=4, div=65, ct=1, bp="bp"),
    "p5":  dict(red=3, jal=2, ld=2, cap=2, mul=6, mulhu=8, div=65, ct=0, bp="none"),
    "p5s": dict(red=3, jal=2, ld=2, cap=2, mul=6, mulhu=8, div=65, ct=0, bp="btfn", right=2),
    "p5b": dict(red=3, jal=2, ld=2, cap=2, mul=6, mulhu=8, div=65, ct=0, bp="bp", right=2),
}
BARRELS = (4, 5, 8)

# classes
ALU, LUI, LOAD, STORE, BR, JAL, JALR, XFER, WAITK, TAMO, CAP, CSRR, CSRW, SYS, LTAG, XMAP, XCALL, XRET, CAP2, ILL = range(20)
CNAMES = ["alu", "lui", "load", "store", "branch", "jal", "jalr", "xfer", "twait/tpoll/tany", "tamo", "cap", "csrr",
          "csrw", "sys", "ltag/linst", "xmap", "xcall", "xret", "cap2", "illegal"]
CSR_SERIAL = {15, 16, 18, 24, 25}   # corebase, corecount, status, ipend, xslot: the next instruction depends on them


def decode(ir):
    """(class, x sources, x destination or 0, cap sources, cap destinations, extra kind, serialising)"""
    op = ir >> 26
    rd, rs1, rs2 = (ir >> 21) & 31, (ir >> 16) & 31, (ir >> 11) & 31
    funct = ir & 0x7FF
    if op == 0:
        a = funct & 15
        ex = "mul" if a == 10 else "mulhu" if a == 11 else "div" if a >= 12 else None
        return ALU, (rs1, rs2), rd, (), (), ex, False
    if 1 <= op <= 9:
        return ALU, (rs1,), rd, (), (), None, False
    if op == 0x0A:
        return LUI, (), rd, (), (), None, False
    if 0x10 <= op <= 0x16:
        return LOAD, (rs1,), rd, (), (), None, False
    if 0x18 <= op <= 0x1B:
        return STORE, (rs1, rd), 0, (), (), None, False
    if 0x20 <= op <= 0x25:
        return BR, (rd, rs1), 0, (), (), None, False
    if op == 0x28:
        return JAL, (), rd, (), (), None, False
    if op == 0x29:
        return JALR, (rs1,), rd, (), (), None, False
    if op == 0x30:
        sub = (ir >> 23) & 7
        return XFER, ((ir >> 14) & 31, (ir >> 5) & 31, ir & 31), 0, ((ir >> 10) & 15,), (), None, sub == 2
    if op == 0x31:
        return WAITK, (), 0, (), (), None, False
    if op == 0x32:
        return WAITK, (), rd, (), (), None, False
    if op == 0x36:
        return WAITK, (rs1,), rd, (), (), None, False
    if op == 0x33:
        return TAMO, (rs1, rs2, rd), rd, ((funct >> 7) & 15,), (), "am", False
    if op == 0x34:
        fn = funct & 15
        cd, cs = rd & 15, rs1 & 15
        xs = (rs2,) if fn in (1, 5, 9, 10) else ()
        xd = rd if fn in (6, 7, 8, 14, 15) else 0
        cr = (cs,) if fn in (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 14) else ()
        if fn in (0, 1, 2, 3, 4, 5, 10, 11, 13):
            cr = cr + (cd,)                      # the destination's liveness is checked (cd_ok)
        cw = ((cd,) if fn in (0, 1, 2, 3, 4, 5, 10, 11, 13) else ()) + ((cs,) if fn in (0, 1, 2, 3, 4, 5, 9, 12) else ())
        return CAP, xs, xd, cr, cw, "ct" if fn in (12, 13) else None, False
    if op == 0x35:
        fn = funct & 15
        cd, cs = rd & 15, rs1 & 15
        xs = (rs2,) if fn in (5, 6, 7) else ()
        return CAP2, xs, 0, (cs, cd), (cd, cs), "ct" if fn in (6, 7) else None, fn <= 2
    if op == 0x38:
        return CSRR, (), rd, (), (), None, False
    if op == 0x39:
        return CSRW, (rs1,), 0, (), (), None, (ir & 0xFFFF) in CSR_SERIAL
    if op == 0x3A:
        return SYS, (), 0, (), (), None, False
    if op in (0x3B, 0x3C):
        return LTAG, (rs1,), rd if op == 0x3B else 0, (), (), "ltag", False
    if op == 0x3D:
        return XMAP, (rs1, rs2), 0, (funct & 15,), (), None, False
    if op == 0x3E:
        if funct & 16:
            return XRET, (rs1,), 0, (), (), None, False
        return XCALL, (rs1,), rd, (funct & 15,), (), None, False
    return ILL, (), 0, (), (), None, False


def bpc(d, outcome):
    """The redirect cost of a predictor outcome in design d."""
    return {"right": 0, "none": 0, "btbmiss": d["jal"], "wrong": d["red"]}[outcome or "none"]


class Pred:
    """Two-bit counters, a direct-mapped target buffer, a return stack."""

    def __init__(self):
        self.ctr = [1] * 256
        self.btb = [None] * 64
        self.ras = []

    def btb_hit(self, pc, target):
        e = self.btb[(pc >> 2) & 63]
        return e is not None and e[0] == pc and e[1] == target

    def btb_set(self, pc, target):
        self.btb[(pc >> 2) & 63] = (pc, target)


class Core:
    def __init__(self):
        self.prev = None                           # (pc, ir) waiting for its successor
        self.free = {k: 0 for k in DESIGNS}        # the cycle the next instruction may enter execute
        self.xr = {k: [0] * 32 for k in DESIGNS}   # register ready cycles
        self.cr = {k: [0] * 16 for k in DESIGNS}   # capability ready cycles
        self.pred = Pred()
        self.hx = [None, None]                     # loads' destinations, one and two instructions back
        self.hc = ()                               # capabilities written by the instruction before


def main():
    path = sys.argv[1]
    name = sys.argv[2] if len(sys.argv) > 2 else path
    f = sys.stdin if path == "-" else gzip.open(path, "rt") if path.endswith(".gz") else open(path)
    cores = defaultdict(Core)
    cache = {}
    n = 0
    mc = 0.0
    cyc = {k: 0.0 for k in DESIGNS}
    stall = {k: defaultdict(float) for k in DESIGNS}
    barrel = {b: 0.0 for b in BARRELS}
    cls_n = [0] * 20
    taken = brs = back_taken = back = fwd_taken = traps = serial = 0
    ld_use1 = ld_use2 = cap_use1 = 0
    p5b_right = p5b_wrong = p5b_btbmiss = 0

    for line in f:
        p = line.split()
        if len(p) != 3:
            continue
        try:
            cid, pc, ir = int(p[0]), int(p[1], 16), int(p[2], 16)
        except ValueError:
            continue
        c = cores[cid]
        pv = c.prev
        c.prev = (pc, ir)
        if pv is None:
            continue
        ppc, pir = pv
        npc = pc
        dec = cache.get(pir)
        if dec is None:
            dec = cache[pir] = decode(pir)
        cl, xs, xd, cs_, cw, exk, ser = dec
        n += 1
        cls_n[cl] += 1
        seq = npc == ppc + 4

        # what kind of transfer of control
        redirect = None           # None, "br", "jal", "ind" (resolved in execute), "trap"
        if cl == BR:
            brs += 1
            off = pir & 0xFFFF
            bwd = off >= 0x8000
            back += bwd
            if not seq:
                taken += 1
                redirect = "br"
                back_taken += bwd
                fwd_taken += not bwd
        elif cl == JAL:
            redirect = "jal" if not seq else None
        elif cl in (JALR, XCALL, XRET) or (cl == SYS and (pir & 0xFFFF) == 1):
            redirect = "ind" if not seq else None
        elif not seq:
            redirect = "trap"
            traps += 1
        if ser:
            serial += 1

        # extra cycles of a multi-cycle instruction
        def extra(d):
            if exk is None:
                return 0
            if exk == "am":
                return AM_CYC
            if exk == "ltag":
                return LTAG_CYC
            if exk == "ct":
                return d["ct"]
            return d[exk]

        # today's core (STREAM = 0)
        mc += 3 + (1 if cl == LOAD else 0) + (AM_CYC if exk == "am" else LTAG_CYC if exk == "ltag" else
                                              1 if exk == "ct" else 3 if exk == "mul" else 4 if exk == "mulhu"
                                              else 65 if exk == "div" else 0)

        # the predictor's view (shared by the designs that use it)
        pr = c.pred
        bp_cost = None             # the predictor's outcome: "right", "btbmiss" (taken, target from D), "wrong", "none"
        if cl == BR:
            i = (ppc >> 2) & 255
            pt = pr.ctr[i] >= 2
            tgt = (ppc + ((pir & 0xFFFF) - (0x10000 if pir & 0x8000 else 0)) * 4) & 0xFFFFFFFFFFFFFFFF
            hit = pr.btb_hit(ppc, tgt)
            if not seq:
                if pt and hit:
                    bp_cost = "right"
                    p5b_right += 1
                elif pt:
                    bp_cost = "btbmiss"  # predicted taken, target from D
                    p5b_btbmiss += 1
                else:
                    bp_cost = "wrong"
                    p5b_wrong += 1
                pr.ctr[i] = min(3, pr.ctr[i] + 1)
                pr.btb_set(ppc, tgt)
            else:
                if pt:
                    bp_cost = "wrong" if hit else "none"   # a predicted-taken from the buffer fetched the wrong path
                    p5b_wrong += hit
                else:
                    bp_cost = "none"
                pr.ctr[i] = max(0, pr.ctr[i] - 1)
        elif cl == JAL:
            if not seq:
                if pr.btb_hit(ppc, npc):
                    bp_cost = "right"
                    p5b_right += 1
                else:
                    bp_cost = "btbmiss"
                    p5b_btbmiss += 1
                pr.btb_set(ppc, npc)
            if xd:
                pr.ras.append(ppc + 4)
                del pr.ras[:-8]
        elif cl == JALR:
            rd = (pir >> 21) & 31
            rs1 = (pir >> 16) & 31
            if rd == 0 and rs1 == 1:
                guess = pr.ras.pop() if pr.ras else None
                bp_cost = "right" if guess == npc else "wrong"
                if guess == npc:
                    p5b_right += 1
                else:
                    p5b_wrong += 1
            else:
                bp_cost = "wrong"
                if xd:
                    pr.ras.append(ppc + 4)
                    del pr.ras[:-8]

        for k, d in DESIGNS.items():
            xr = c.xr[k]
            crd = c.cr[k]
            t = c.free[k]
            ready = t
            for r in xs:
                if r and xr[r] > ready:
                    ready = xr[r]
            src_wait = ready - t
            cready = ready
            for r in cs_:
                if crd[r] > cready:
                    cready = crd[r]
            cap_wait = cready - ready
            issue = cready
            if src_wait:
                stall[k]["load use"] += src_wait
            if cap_wait:
                stall[k]["capability use"] += cap_wait
            e = extra(d)
            if exk in ("mul", "mulhu", "div"):
                stall[k]["mul/div"] += e
            elif exk == "ct":
                stall[k]["save table"] += e
            elif e:
                stall[k]["far atomic, ltag"] += e
            # the redirect penalty
            if redirect is None:
                r = 0
            elif d["bp"] == "bp" and bp_cost is not None:
                r = bpc(d, bp_cost)
            elif redirect == "br" and d["bp"] == "btfn":
                r = d["right"] if (pir & 0x8000) else d["red"]
            elif redirect == "jal":
                r = d["jal"]
            else:
                r = d["red"]
            # BTFN / predictor: a backward branch not taken was fetched down the wrong path
            if redirect is None and cl == BR:
                if d["bp"] == "btfn" and (pir & 0x8000):
                    r = d["red"]
                elif d["bp"] == "bp":
                    r = bpc(d, bp_cost)
            if ser and redirect is None:
                r = max(r, d["red"])            # flush: the instructions behind it were fetched too early
            if r:
                stall[k]["control" if redirect != "trap" and not ser else "traps, serialising"] += r
            c.free[k] = issue + 1 + e + r
            if xd:
                xr[xd] = issue + (d["ld"] if cl == LOAD else 1 + e)
            for r2 in cw:
                crd[r2] = issue + d["cap"]
            cyc[k] += c.free[k] - t

        # barrels: a thread's turn comes every N cycles
        occ = 1 + (6 if exk == "mul" else 8 if exk == "mulhu" else 65 if exk == "div" else
                   AM_CYC if exk == "am" else LTAG_CYC if exk == "ltag" else 0)
        for b in BARRELS:
            barrel[b] += max(b, occ)

        # statistics: a load result used by the next / second next instruction
        hx = c.hx
        if hx[0] is not None and hx[0] in xs:
            ld_use1 += 1
        elif hx[1] is not None and hx[1] in xs:
            ld_use2 += 1
        if c.hc and any(r in c.hc for r in cs_):
            cap_use1 += 1
        hx[1] = hx[0]
        hx[0] = xd if (cl == LOAD and xd) else None
        c.hc = cw

    if not n:
        print("no instructions")
        return
    print(f"== {name}: {n} instructions, {len(cores)} cores")
    print("  mix: " + ", ".join(f"{CNAMES[i]} {100 * cls_n[i] / n:.1f}%" for i in range(20) if cls_n[i]))
    print(f"  branches {brs} ({100 * brs / n:.1f}%), taken {taken} ({100 * taken / max(brs, 1):.1f}%); "
          f"backward {back}, of them taken {back_taken} ({100 * back_taken / max(back, 1):.1f}%); "
          f"forward taken {fwd_taken} ({100 * fwd_taken / max(brs - back, 1):.1f}% of forward)")
    print(f"  traps/stops {traps}, serialising instructions {serial}; load used by the next instruction "
          f"{ld_use1} ({100 * ld_use1 / max(cls_n[LOAD], 1):.1f}% of loads), by the one after {ld_use2}; "
          f"capability used by the next {cap_use1}")
    print(f"  predictor (p5b): right {p5b_right}, wrong {p5b_wrong}, taken but not in the buffer {p5b_btbmiss}")
    print(f"  {'design':<6} {'CPI':>6}   stalls per instruction")
    print(f"  {'mc':<6} {mc / n:6.3f}   (today's core, STREAM = 0)")
    for k in DESIGNS:
        s = ", ".join(f"{a} {v / n:.3f}" for a, v in sorted(stall[k].items(), key=lambda kv: -kv[1]) if v)
        print(f"  {k:<6} {cyc[k] / n:6.3f}   {s}")
    for b in BARRELS:
        print(f"  b{b:<5} {barrel[b] / n:6.3f}   per thread; the pipeline {b / (barrel[b] / n):.3f} instructions per cycle "
              f"with {b} threads ready")


main()
