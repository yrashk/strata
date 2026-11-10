#!/usr/bin/env python3
"""Differential fuzzer for the JIT: random programs of the plain integer ISA
(every ALU function, immediates, loads and stores near the D-LS bounds and
misaligned, forward branches, a loop, calls through jal/jalr), run with the
JIT (-J) and with the interpreter (-j); the final registers (dumped to the
console), the trap count and the halt line must match.

   emu/jit/fuzz.py [-n N] [-s SEED] [--emu build/strata-emu] [--sasm build/sasm]

Faulting accesses go to a trap handler that adds the cause into x29 and
skips the instruction, so precise traps (pc, instret, register state at the
fault) are checked too. Registers x27..x31 are reserved: link, loop
counter, trap accumulator, handler scratch, memory base.
"""
import argparse, os, random, subprocess, sys, tempfile

OP = dict(ALU=0x00, ADDI=0x01, ANDI=0x02, ORI=0x03, XORI=0x04, SLLI=0x05, SRLI=0x06, SRAI=0x07,
          SLTI=0x08, SLTIU=0x09, LUI=0x0A, LD=0x10, LW=0x11, LWU=0x12, LH=0x13, LHU=0x14, LB=0x15,
          LBU=0x16, SD=0x18, SW=0x19, SH=0x1A, SB=0x1B, BEQ=0x20, BNE=0x21, BLT=0x22, BGE=0x23,
          BLTU=0x24, BGEU=0x25, JAL=0x28, JALR=0x29, XFER=0x30, CSRR=0x38, CSRW=0x39, SYS=0x3A)
CSR_CAUSE, CSR_EPC, CSR_TVEC, CSR_COREID = 2, 3, 5, 7
LINK, CNT, ACC, HS, BASE = 27, 28, 29, 30, 31
SPECIAL = [0, 1, 2, 3, 7, 8, 63, 64, 0xffff, 0x10000, 0x7fffffffffffffff, 0x8000000000000000,
           0xffffffffffffffff, 0xfffffffffffffffe, 0x8000, 0xf800, 0xfff8]


def r(op, rd, rs1, rs2, funct): return op << 26 | rd << 21 | rs1 << 16 | rs2 << 11 | funct
def i(op, rd, rs1, imm): return op << 26 | rd << 21 | rs1 << 16 | (imm & 0xffff)
def jal(rd, words): return OP['JAL'] << 26 | rd << 21 | (words & 0x1fffff)


def gen(rng):
    code = []
    data = [rng.choice(SPECIAL) if rng.random() < 0.4 else rng.getrandbits(64) for _ in range(27)]
    # prologue: core 0 only; trap handler; registers from .data; memory base; loop count
    code += [i(OP['CSRR'], HS, 0, CSR_COREID), None]  # bnez HS, park (patched)
    bnez_park = 1
    code += [None, i(OP['CSRW'], 0, HS, CSR_TVEC)]   # addi HS, x0, handler (patched)
    li_handler = 2
    for g in range(1, 27):
        code.append(i(OP['LD'], g, 0, 8 * g))
    base = rng.choice([0x8000, 0xf800, 0xfff0, 0x0010])
    code.append(i(OP['LUI'], BASE, 0, 0) if base >= 0x8000 else i(OP['ADDI'], BASE, 0, base))
    if base >= 0x8000: code.append(i(OP['ORI'], BASE, BASE, base))
    iters = rng.choice([1, 3, 50, 400])
    code.append(i(OP['ADDI'], CNT, 0, iters))
    loop = len(code)
    nsub = 3
    body_len = rng.randint(5, 300)
    calls = []
    body_start = len(code)
    for k in range(body_len):
        here = len(code)
        left = body_start + body_len - here - 1
        x = rng.random()
        rd = rng.choice([0] + list(range(1, 27)) * 3)
        rs1, rs2 = rng.randrange(32), rng.randrange(32)
        if x < 0.35:
            code.append(r(OP['ALU'], rd, rs1, rs2, rng.randrange(16)))
        elif x < 0.6:
            op = rng.choice(['ADDI', 'ANDI', 'ORI', 'XORI', 'SLLI', 'SRLI', 'SRAI', 'SLTI', 'SLTIU', 'LUI'])
            imm = rng.choice([0, 1, -1, 63, 64, 0x7fff, -0x8000, 0xffff, rng.getrandbits(16)])
            code.append(i(OP[op], rd, rs1, imm))
        elif x < 0.8:
            op = rng.choice(['LD', 'LW', 'LWU', 'LH', 'LHU', 'LB', 'LBU', 'SD', 'SW', 'SH', 'SB'])
            b = BASE if rng.random() < 0.9 else rs1
            off = rng.randrange(-0x800, 0x820) & ~(rng.choice([0, 0, 0, 7, 3, 1]))
            if op.startswith('S') and b == BASE and base < 0x7100 + 256 and base + off >= 0 and base + off < 0x7200:
                off = 0  # keep stores off the dump area
            v = rng.randrange(32) if op.startswith('S') else rd
            code.append(i(OP[op], v, b, off))
        elif x < 0.93 and left > 1:
            op = rng.choice(['BEQ', 'BNE', 'BLT', 'BGE', 'BLTU', 'BGEU'])
            skip = rng.randint(1, min(6, left))
            code.append(i(OP[op], rs1 if rng.random() < 0.8 else rs2, rs2, skip + 1))
        else:
            calls.append(len(code))
            code.append(None)  # jal LINK, sub (patched)
    code.append(i(OP['ADDI'], CNT, CNT, -1))
    code.append(i(OP['BNE'], CNT, 0, loop - len(code)))
    # dump x1..x31 at 0x7000, print 256 bytes
    for g in range(1, 32):
        code.append(i(OP['SD'], g, 0, 0x7000 + 8 * g))
    code.append(i(OP['ADDI'], 10, 0, 0x7000))
    code.append(i(OP['ADDI'], 11, 0, 256))
    code.append(OP['XFER'] << 26 | 1 << 23 | 15 << 19 | 10 << 14 | 2 << 10 | 0 << 5 | 11)
    code.append(i(OP['ADDI'], 10, 0, 0))
    park = len(code)
    code.append(i(OP['SYS'], 0, 0, 0))
    handler = len(code)
    code += [i(OP['CSRR'], HS, 0, CSR_CAUSE), r(OP['ALU'], ACC, ACC, HS, 0), i(OP['SLLI'], HS, ACC, 3),
             r(OP['ALU'], ACC, ACC, HS, 4),
             i(OP['CSRR'], HS, 0, CSR_EPC), i(OP['ADDI'], HS, HS, 4), i(OP['CSRW'], 0, HS, CSR_EPC),
             i(OP['SYS'], 0, 0, 1)]
    subs = []
    for s in range(nsub):
        subs.append(len(code))
        for _ in range(rng.randint(1, 12)):
            code.append(r(OP['ALU'], rng.randint(1, 26), rng.randrange(32), rng.randrange(32), rng.randrange(16)))
        code.append(i(OP['JALR'], 0, LINK, 0))
    code[bnez_park] = i(OP['BNE'], HS, 0, park - bnez_park)
    code[li_handler] = i(OP['ADDI'], HS, 0, handler * 4)
    for c in calls:
        code[c] = jal(LINK, rng.choice(subs) - c)
    src = ['        .data'] + ['        .dword 0x%x' % v for v in [0] + data] + ['        .text']
    src += ['        .word 0x%08x' % w for w in code]
    return '\n'.join(src) + '\n'


def inval():
    """tgetx over code that has run: the new code must run (a0 = 100 + 100 * 100)."""
    c = [i(OP['CSRR'], 5, 0, CSR_COREID), None, i(OP['ADDI'], 10, 0, 0)]
    for k in range(2):
        c += [i(OP['ADDI'], 6, 0, 16 * k), i(OP['ADDI'], 7, 0, 16 * k), i(OP['ADDI'], 28, 0, 16),
              i(OP['ORI'], 29, 0, 0x8000),
              OP['XFER'] << 26 | 1 << 23 | 1 << 19 | 6 << 14 | 1 << 10 | 7 << 5 | 28,   # tput tg1, t1, c1, t2, t3
              OP['XFER'] << 26 | 2 << 23 | 1 << 19 | 29 << 14 | 1 << 10 | 7 << 5 | 28,  # tgetx tg1, t4, c1, t2, t3
              i(OP['ADDI'], 30, 0, 100)]
        loop = len(c)
        c += [i(OP['JALR'], 1, 29, 0), i(OP['ADDI'], 30, 30, -1)]
        c.append(i(OP['BNE'], 30, 0, loop - len(c)))
    c.append(i(OP['SYS'], 0, 0, 0))
    c[1] = i(OP['BNE'], 5, 0, len(c) - 2)  # other cores: straight to the halt (a0 = 0)
    code = [i(OP['ADDI'], 10, 10, 1), i(OP['JALR'], 0, 1, 0), 0, 0,
            i(OP['ADDI'], 10, 10, 100), i(OP['JALR'], 0, 1, 0), 0, 0]
    return '\n'.join(['        .data'] + ['        .word 0x%08x' % w for w in code] + ['        .text'] +
                     ['        .word 0x%08x' % w for w in c]) + '\n'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-n', type=int, default=200)
    ap.add_argument('-s', type=int, default=1)
    ap.add_argument('--emu', default='build/strata-emu')
    ap.add_argument('--sasm', default='build/sasm')
    ap.add_argument('--keep', action='store_true')
    a = ap.parse_args()
    tmp = tempfile.mkdtemp()
    bad = 0
    s, img = os.path.join(tmp, 'inval.s'), os.path.join(tmp, 'inval.stx')
    open(s, 'w').write(inval())
    subprocess.run([a.sasm, '-o', img, s], check=True)
    for mode in ('-j', '-J'):
        p = subprocess.run([a.emu, '-c', '1', '-g', 'none', mode, img], capture_output=True, stdin=subprocess.DEVNULL)
        if b'a0=10100 ' not in p.stderr:
            bad += 1
            print('MISMATCH invalidation test %s: %s' % (mode, p.stderr.decode().strip()))
    for k in range(a.n):
        rng = random.Random(a.s * 1000003 + k)
        s = os.path.join(tmp, 'f.s')
        img = os.path.join(tmp, 'f.stx')
        open(s, 'w').write(gen(rng))
        subprocess.run([a.sasm, '-o', img, s], check=True)
        out = []
        for mode in ('-j', '-J'):
            p = subprocess.run([a.emu, '-c', '1', '-T', 'virtual', '-g', 'none', '-m', '50000000', mode, img],
                               capture_output=True, stdin=subprocess.DEVNULL)
            out.append((p.returncode, p.stdout, p.stderr))
        if out[0] != out[1]:
            bad += 1
            keep = os.path.join(tmp, 'bad%d.s' % k)
            os.rename(s, keep)
            print('MISMATCH seed %d case %d (%s)' % (a.s, k, keep))
            print('  interp:', out[0][0], out[0][2].decode().strip())
            print('  jit:   ', out[1][0], out[1][2].decode().strip())
            ri = out[0][1]; rj = out[1][1]
            for g in range(1, 32):
                vi, vj = ri[8 * g:8 * g + 8], rj[8 * g:8 * g + 8]
                if vi != vj:
                    print('  x%d: %s vs %s' % (g, vi.hex(), vj.hex()))
    print('fuzz: %d programs, %d mismatches' % (a.n, bad))
    sys.exit(1 if bad else 0)


main()
