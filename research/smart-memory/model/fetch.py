#!/usr/bin/env python3
"""Fetch-cost and instruction-pair model over an instruction trace.

    strata-rtl -t TRACE ... ; fetch.py TRACE      (or - for stdin)

The trace has one line per fetched instruction: `core pc ir` (sim/main.cpp).
Today every instruction costs two fetch cycles (S_F0, S_F1) before S_EX.
An I-LS word is 64 bits and holds two instructions, and the I-LS read port
is idle in S_F1 and S_EX, so three cheaper fetch schemes are counted:

  word     keep the 64-bit word read last: an instruction in it needs no read
  stream   as word, and the I-LS reads the following word by itself while the
           core executes (an incrementer at the memory): only a transfer of
           control to another word costs the two cycles, and one more when it
           lands on the second instruction of its word (the word after it is
           then needed one cycle before it can have arrived)
  stream+  as stream, with a taken branch's target given to the I-LS in S_EX
           (one cycle instead of two: the path pc_br -> I-LS address)

It also counts the instruction pairs a memory-operand instruction or an
ALU at the Local Store could merge.
"""
import sys
from collections import defaultdict

OP_LOAD = range(0x10, 0x17)
OP_STORE = range(0x18, 0x1C)
OP_BRANCH = range(0x20, 0x26)
OP_ALUI = range(0x01, 0x0A)


def main():
    f = sys.stdin if sys.argv[1] == "-" else open(sys.argv[1])
    last_word = {}
    n = 0
    base = word = stream = streamp = 0
    seq = redirect = redirect_odd = 0
    prev = {}      # core -> (op, rd, rs1, imm, pc)
    prev2 = {}
    ld = ld_use = ld_use_dead = ld_op_st = st = 0
    ld_ld_seq = st_st_seq = 0
    inc_mem = 0
    for line in f:
        p = line.split()
        if len(p) != 3:
            continue
        try:
            core, pc, ir = int(p[0]), int(p[1], 16), int(p[2], 16)
        except ValueError:
            continue
        n += 1
        w = pc >> 3
        lw = last_word.get(core)
        base += 2
        if lw == w:
            pass
        elif lw is not None and w == lw + 1 and prev[core][4] + 4 == pc:
            word += 2
            seq += 1
        else:
            word += 2
            redirect += 1
            odd = (pc >> 2) & 1
            redirect_odd += odd
            stream += 2 + odd
            streamp += 1 + odd
        last_word[core] = w

        op = ir >> 26
        rd, rs1, rs2 = (ir >> 21) & 31, (ir >> 16) & 31, (ir >> 11) & 31
        imm = ir & 0xFFFF
        pv = prev.get(core)
        pv2 = prev2.get(core)
        if op in OP_LOAD:
            ld += 1
            if pv and pv[0] in OP_LOAD and pv[2] == rs1 and pv[1] != rs1 and ((imm - pv[3]) & 0xFFFF) == 8:
                ld_ld_seq += 1
        if op in OP_STORE:
            st += 1
            if pv and pv[0] in OP_STORE and pv[2] == rs1 and ((imm - pv[3]) & 0xFFFF) in (8, 0xFFF8):
                st_st_seq += 1
            # load; op; store back to the same base and offset, of the op's result
            if (pv and pv2 and pv2[0] in OP_LOAD and (pv[0] == 0 or pv[0] in OP_ALUI) and pv2[2] == rs1 and
                    pv2[3] == imm and pv[1] == rd and pv2[1] != rs1):
                ld_op_st += 1
                if pv[0] == 1 and pv[2] == pv2[1]:
                    inc_mem += 1
        if pv and pv[0] in OP_LOAD and pv[1] != 0:
            uses = False
            if op == 0 or op in OP_BRANCH:
                # R: rs1, rs2; B: rs1 field is in rd's place (op rs1 rs2 off16)
                a, b = (rs1, rs2) if op == 0 else (rd, rs1)
                uses = pv[1] in (a, b)
            elif op in OP_ALUI:
                uses = rs1 == pv[1]
            if uses:
                ld_use += 1
                if (op == 0 or op in OP_ALUI) and rd == pv[1]:
                    ld_use_dead += 1       # the loaded value is overwritten by the result
        prev2[core] = pv
        prev[core] = (op, rd, rs1, imm, pc)

    def per(x):
        return f"{x / n:.3f}"
    print(f"instructions {n}")
    print(f"  next instruction in the same 64-bit word {n - seq - redirect} ({100 * (n - seq - redirect) / n:.1f}%), "
          f"sequential into the next word {seq} ({100 * seq / n:.1f}%), "
          f"transfer to another word {redirect} ({100 * redirect / n:.1f}%; {redirect_odd} to a second instruction)")
    print("  fetch cycles per instruction: today " + per(base) + ", word " + per(word) + ", stream " + per(stream) +
          ", stream+ " + per(streamp))
    print(f"  loads {ld} ({100 * ld / n:.1f}%), stores {st} ({100 * st / n:.1f}%)")
    if ld:
        print(f"  load then use by the next instruction (ALU or branch): {ld_use} ({100 * ld_use / ld:.1f}% of loads); "
              f"with the loaded register overwritten by the result: {ld_use_dead} ({100 * ld_use_dead / ld:.1f}%)")
        print(f"  load; op; store back to the same address: {ld_op_st} ({100 * ld_op_st / max(st, 1):.1f}% of stores); "
              f"of them addi (increment in place): {inc_mem}")
        print(f"  load after a load of the next word off the same base: {ld_ld_seq} ({100 * ld_ld_seq / ld:.1f}% of loads); "
              f"store after a store 8 bytes away: {st_st_seq} ({100 * st_st_seq / max(st, 1):.1f}% of stores)")


main()
