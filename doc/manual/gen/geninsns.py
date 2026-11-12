#!/usr/bin/env python3
"""Generates the instruction-description chapters of the Strata manual.

    python3 gen/geninsns.py        (run from doc/manual)

Writes gen-insns-*.tex (one per instruction chapter), gen-opmap.tex (the
opcode map table) and gen-index.tex (the alphabetical instruction index).
Semantics follow emu/emu.c, the reference emulator.
"""
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")

OP = dict(ALU=0x00, ADDI=0x01, ANDI=0x02, ORI=0x03, XORI=0x04, SLLI=0x05, SRLI=0x06,
          SRAI=0x07, SLTI=0x08, SLTIU=0x09, LUI=0x0A, LD=0x10, LW=0x11, LWU=0x12,
          LH=0x13, LHU=0x14, LB=0x15, LBU=0x16, SD=0x18, SW=0x19, SH=0x1A, SB=0x1B,
          BEQ=0x20, BNE=0x21, BLT=0x22, BGE=0x23, BLTU=0x24, BGEU=0x25, JAL=0x28,
          JALR=0x29, XFER=0x30, TWAIT=0x31, TPOLL=0x32, TAMO=0x33, CAP=0x34,
          CAP2=0x35, TANY=0x36, CSRR=0x38, CSRW=0x39, SYS=0x3A, LTAG=0x3B, LINST=0x3C, XMAP=0x3D,
          XCALL=0x3E)


def b(v, n):
    return format(v, "0%db" % n)


# ------------------------------------------------------------------ layouts
# A layout is a list of (hi, lo, label, kind); kind: f fixed, v variable, z ignored.

def L_R(op, rd="rd", rs1="rs1", rs2="rs2", funct=None):
    lay = [(31, 26, b(op, 6), "f")]
    for (hi, lo, lab) in ((25, 21, rd), (20, 16, rs1), (15, 11, rs2)):
        if isinstance(lab, list):
            lay += lab
        elif lab is None:
            lay.append((hi, lo, b(0, hi - lo + 1), "z"))
        else:
            lay.append((hi, lo, lab, "v"))
    lay += funct
    return lay


def L_I(op, rd="rd", rs1="rs1", imm="imm16"):
    lay = [(31, 26, b(op, 6), "f")]
    for (hi, lo, lab) in ((25, 21, rd), (20, 16, rs1)):
        if lab is None:
            lay.append((hi, lo, b(0, hi - lo + 1), "z"))
        else:
            lay.append((hi, lo, lab, "v"))
    if isinstance(imm, list):
        lay += imm
    else:
        lay.append((15, 0, imm, "v"))
    return lay


def alu_funct(fn):
    return [(10, 4, b(0, 7), "f"), (3, 0, b(fn, 4), "f")]


def cap_funct(fn, slot=False, flag=0, flagvar=False):
    f = []
    f.append((10, 5, "slot", "v") if slot else (10, 5, b(0, 6), "z"))
    f.append((4, 4, "f", "v") if flagvar else (4, 4, str(flag), "f"))
    f.append((3, 0, b(fn, 4), "f"))
    return f


CD = [(25, 25, "0", "f"), (24, 21, "cd", "v")]
CS = [(20, 20, "0", "f"), (19, 16, "cs", "v")]


def L_X(sub):
    return [(31, 26, b(OP["XFER"], 6), "f"), (25, 23, b(sub, 3), "f"), (22, 19, "tag", "v"),
            (18, 14, "rl", "v"), (13, 10, "cs", "v"), (9, 5, "ro", "v"), (4, 0, "rn", "v")]


def encoding_tex(lay):
    bits = sorted({x for (hi, lo, _, _) in lay for x in (hi, lo)})
    out = ["\\begin{encoding}", "\\bitheader{%s}\\\\" % ",".join(map(str, bits))]
    boxes = []
    for (hi, lo, lab, kind) in lay:
        w = hi - lo + 1
        macro = {"f": "\\fx", "v": "\\fv", "z": "\\fz"}[kind]
        boxes.append("%s{%d}{%s}" % (macro, w, lab))
    out.append("".join(boxes))
    out.append("\\end{encoding}")
    return "\n".join(out)


# ------------------------------------------------------------------ entries
INSNS = []  # dicts


def ins(chapter, mn, title, lay, syntax, desc, op, exc, notes="", fmt="", opname=None, funct=""):
    INSNS.append(dict(chapter=chapter, mn=mn, title=title, lay=lay, syntax=syntax, desc=desc,
                      op=op.strip("\n"), exc=exc, notes=notes, fmt=fmt,
                      opname=opname, funct=funct))


ILLEGAL_ALU = [("illegal", r"\field{funct}\texttt{<10:4>} $\neq$ 0", "instruction word")]

# ---------------------------------------------------------------- integer
ALU_OPS = [
    # mnemonic, fn, title, description, pseudocode
    ("add", 0, "Add", r"Adds two registers. Overflow wraps modulo $2^{64}$.",
     "X[rd] = X[rs1] + X[rs2];"),
    ("sub", 1, "Subtract", r"Subtracts \reg{rs2} from \reg{rs1}, modulo $2^{64}$.",
     "X[rd] = X[rs1] - X[rs2];"),
    ("and", 2, "Bitwise AND", r"Bitwise AND of two registers.", "X[rd] = X[rs1] AND X[rs2];"),
    ("or", 3, "Bitwise OR", r"Bitwise inclusive OR of two registers.", "X[rd] = X[rs1] OR X[rs2];"),
    ("xor", 4, "Bitwise exclusive OR", r"Bitwise exclusive OR of two registers.",
     "X[rd] = X[rs1] XOR X[rs2];"),
    ("sll", 5, "Shift left logical",
     r"Shifts \reg{rs1} left by the amount in bits~5:0 of \reg{rs2}; zeros are shifted in.",
     "X[rd] = X[rs1] << UInt(X[rs2]<5:0>);"),
    ("srl", 6, "Shift right logical",
     r"Shifts \reg{rs1} right by the amount in bits~5:0 of \reg{rs2}; zeros are shifted in.",
     "X[rd] = X[rs1] >> UInt(X[rs2]<5:0>);       // logical"),
    ("sra", 7, "Shift right arithmetic",
     r"Shifts \reg{rs1} right by the amount in bits~5:0 of \reg{rs2}; copies of bit~63 are shifted in.",
     "X[rd] = ASR(X[rs1], UInt(X[rs2]<5:0>));"),
    ("slt", 8, "Set if less than",
     r"Writes 1 to \reg{rd} if \reg{rs1} is less than \reg{rs2} as signed integers, otherwise 0.",
     "X[rd] = if SInt(X[rs1]) < SInt(X[rs2]) then 1 else 0;"),
    ("sltu", 9, "Set if less than, unsigned",
     r"Writes 1 to \reg{rd} if \reg{rs1} is less than \reg{rs2} as unsigned integers, otherwise 0.",
     "X[rd] = if UInt(X[rs1]) < UInt(X[rs2]) then 1 else 0;"),
    ("mul", 10, "Multiply",
     r"Writes the low 64 bits of the product. The result is the same for signed and unsigned operands.",
     "X[rd] = (X[rs1] * X[rs2])<63:0>;"),
    ("mulhu", 11, "Multiply high, unsigned",
     r"Writes the high 64 bits of the 128-bit unsigned product. There is no signed variant.",
     "X[rd] = (UInt(X[rs1]) * UInt(X[rs2]))<127:64>;"),
    ("divu", 12, "Divide, unsigned",
     r"Unsigned division, rounding toward zero. Division by zero does not trap: it returns all ones.",
     """if X[rs2] == 0 then
    X[rd] = 0xFFFF_FFFF_FFFF_FFFF;
else
    X[rd] = UInt(X[rs1]) DIV UInt(X[rs2]);
end"""),
    ("remu", 13, "Remainder, unsigned",
     r"Unsigned remainder. Division by zero does not trap: it returns the dividend.",
     """if X[rs2] == 0 then
    X[rd] = X[rs1];
else
    X[rd] = UInt(X[rs1]) MOD UInt(X[rs2]);
end"""),
    ("div", 14, "Divide, signed",
     r"Signed division, rounding toward zero. Division by zero returns all ones ($-1$); "
     r"the overflowing case $-2^{63} \div -1$ returns $-2^{63}$. Neither traps.",
     """a = SInt(X[rs1]); d = SInt(X[rs2]);
if d == 0 then
    X[rd] = -1;
elsif a == -2^63 and d == -1 then
    X[rd] = -2^63;
else
    X[rd] = RoundTowardZero(a / d);
end"""),
    ("rem", 15, "Remainder, signed",
     r"Signed remainder; the result has the sign of the dividend. Division by zero returns the dividend; "
     r"$-2^{63} \bmod -1$ returns 0. Neither traps.",
     """a = SInt(X[rs1]); d = SInt(X[rs2]);
if d == 0 then
    X[rd] = X[rs1];
elsif a == -2^63 and d == -1 then
    X[rd] = 0;
else
    X[rd] = a - d * RoundTowardZero(a / d);
end"""),
]
for (mn, fn, title, desc, op) in ALU_OPS:
    ins("int", mn.upper(), title, L_R(OP["ALU"], funct=alu_funct(fn)), ["%s rd, rs1, rs2" % mn],
        desc, op, ILLEGAL_ALU, fmt="R", opname="ALU", funct="funct = %d" % fn,
        notes=r"Writes to \reg{x0} are discarded." if mn == "add" else "")

IMM_OPS = [
    ("addi", "ADDI", "Add immediate", "simm",
     r"Adds a sign-extended 16-bit immediate to \reg{rs1}.",
     "X[rd] = X[rs1] + SignExtend(imm16, 64);",
     r"\insn{addi rd, rs, 0} is the \insn{mv} pseudo-instruction and \insn{addi x0, x0, 0} is \insn{nop}."),
    ("slti", "SLTI", "Set if less than immediate", "simm",
     r"Writes 1 to \reg{rd} if \reg{rs1} is less than the sign-extended immediate, as signed integers.",
     "X[rd] = if SInt(X[rs1]) < SInt(SignExtend(imm16, 64)) then 1 else 0;", ""),
    ("sltiu", "SLTIU", "Set if less than immediate, unsigned", "simm",
     r"Writes 1 to \reg{rd} if \reg{rs1} is less than the \emph{sign-extended} immediate, compared as unsigned integers.",
     "X[rd] = if UInt(X[rs1]) < UInt(SignExtend(imm16, 64)) then 1 else 0;",
     r"\insn{sltiu rd, rs, 1} sets \reg{rd} to 1 exactly when \reg{rs} is zero."),
    ("andi", "ANDI", "Bitwise AND immediate", "zimm",
     r"Bitwise AND with a \emph{zero-extended} 16-bit immediate.",
     "X[rd] = X[rs1] AND ZeroExtend(imm16, 64);",
     r"Unlike \insn{addi}, the logical immediates are zero-extended, so \insn{andi} always clears bits 63:16."),
    ("ori", "ORI", "Bitwise OR immediate", "zimm",
     r"Bitwise OR with a zero-extended 16-bit immediate.",
     "X[rd] = X[rs1] OR ZeroExtend(imm16, 64);",
     r"\insn{lui} followed by \insn{ori} builds any 32-bit signed constant (this is how \insn{li} and \insn{la} expand)."),
    ("xori", "XORI", "Bitwise exclusive OR immediate", "zimm",
     r"Bitwise exclusive OR with a zero-extended 16-bit immediate.",
     "X[rd] = X[rs1] XOR ZeroExtend(imm16, 64);", ""),
]
for (mn, opn, title, kind, desc, op, notes) in IMM_OPS:
    syn = "%s rd, rs1, imm" % mn
    ins("int", mn.upper(), title, L_I(OP[opn]), [syn], desc, op, [], notes=notes, fmt="I", opname=opn)

SHIFT_OPS = [
    ("slli", "SLLI", "Shift left logical immediate", "X[rd] = X[rs1] << UInt(imm16<5:0>);", "zeros"),
    ("srli", "SRLI", "Shift right logical immediate", "X[rd] = X[rs1] >> UInt(imm16<5:0>);   // logical", "zeros"),
    ("srai", "SRAI", "Shift right arithmetic immediate", "X[rd] = ASR(X[rs1], UInt(imm16<5:0>));", "copies of bit~63"),
]
for (mn, opn, title, op, fill) in SHIFT_OPS:
    ins("int", mn.upper(), title,
        L_I(OP[opn], imm=[(15, 6, b(0, 10), "z"), (5, 0, "shamt", "v")]),
        ["%s rd, rs1, shamt" % mn],
        r"Shifts \reg{rs1} by a constant amount 0--63; %s are shifted in." % fill, op, [],
        notes=r"Bits 15:6 of the immediate are ignored; the assembler rejects amounts outside 0--63.",
        fmt="I", opname=opn)

ins("int", "LUI", "Load upper immediate", L_I(OP["LUI"], rs1=None), ["lui rd, imm"],
    r"Places the 16-bit immediate in bits 31:16 of \reg{rd}, sign-extending it into bits 63:32 and "
    r"clearing bits 15:0.",
    "X[rd] = SignExtend(imm16, 64) << 16;", [],
    notes=r"The assembler accepts any value from $-32768$ to $65535$ and encodes its low 16 bits. "
          r"Bits 20:16 are ignored.", fmt="I", opname="LUI")

# ---------------------------------------------------------------- local store
LOADS = [("ld", "LD", 8, False, "doubleword"), ("lw", "LW", 4, True, "word, sign-extended"),
         ("lwu", "LWU", 4, False, "word, zero-extended"), ("lh", "LH", 2, True, "halfword, sign-extended"),
         ("lhu", "LHU", 2, False, "halfword, zero-extended"), ("lb", "LB", 1, True, "byte, sign-extended"),
         ("lbu", "LBU", 1, False, "byte, zero-extended")]
LS_EXC_L = lambda n: [("lsfault", r"\texttt{addr} $>$ \texttt{DLS\_SIZE} $-$ %d, or \texttt{addr} is not a multiple of %d" % (n, n)
                       if n > 1 else r"\texttt{addr} $\geq$ \texttt{DLS\_SIZE}", r"\texttt{addr}"),
                      ("pend", r"CCR.PTRAP = 1 and the bytes overlap the D-LS destination of an in-flight "
                               r"\insn{tget} (only in implementations with real transfer latency)", r"\texttt{addr}")]
LTITLE = dict(ld="Load doubleword", lw="Load word", lwu="Load word unsigned", lh="Load halfword",
              lhu="Load halfword unsigned", lb="Load byte", lbu="Load byte unsigned")
for (mn, opn, n, sgn, what) in LOADS:
    ext = "SignExtend" if sgn else "ZeroExtend"
    rd = "X[rd] = DLS.Read(addr, 8);" if n == 8 else "X[rd] = %s(DLS.Read(addr, %d), 64);" % (ext, n)
    op = """addr = X[rs1] + SignExtend(imm16, 64);
if addr > DLS_SIZE - %d or addr MOD %d != 0 then Trap(lsfault, addr); end
Stall while [addr, addr+%d) overlaps the destination of an in-flight tget;
%s""" % (n, n, n, rd)
    ins("ls", mn.upper(), LTITLE[mn],
        L_I(OP[opn]), ["%s rd, imm(rs1)" % mn],
        r"Loads a %s from the data Local Store at \reg{rs1} plus a sign-extended 16-bit offset. "
        r"The address must be naturally aligned. A load can only reach the D-LS: far memory is read with \insref{tget}." % what,
        op, LS_EXC_L(n),
        notes=r"The stall makes a preceding \insn{tget} into the same bytes appear complete; "
              r"a program never needs \insn{twait} for correctness (\S\ref{sec:asif}).",
        fmt="I", opname=opn)

STORES = [("sd", "SD", 8, "doubleword"), ("sw", "SW", 4, "word"), ("sh", "SH", 2, "halfword"), ("sb", "SB", 1, "byte")]
for (mn, opn, n, what) in STORES:
    val = "X[rs2]" if n == 8 else "X[rs2]<%d:0>" % (8 * n - 1)
    op = """addr = X[rs1] + SignExtend(imm16, 64);
if addr > DLS_SIZE - %d or addr MOD %d != 0 then Trap(lsfault, addr); end
Stall while [addr, addr+%d) overlaps the destination of an in-flight tget
                       or the source of an in-flight tput;
DLS.Write(addr, %d, %s);""" % (n, n, n, n, val)
    exc = [("lsfault", r"\texttt{addr} $>$ \texttt{DLS\_SIZE} $-$ %d, or \texttt{addr} is not a multiple of %d" % (n, n)
            if n > 1 else r"\texttt{addr} $\geq$ \texttt{DLS\_SIZE}", r"\texttt{addr}"),
           ("pend", r"CCR.PTRAP = 1 and the bytes overlap an in-flight \insn{tget} destination or \insn{tput} source",
            r"\texttt{addr}")]
    ins("ls", mn.upper(), "Store " + what,
        [(31, 26, b(OP[opn], 6), "f"), (25, 21, "rs2", "v"), (20, 16, "rs1", "v"), (15, 0, "imm16", "v")],
        ["%s rs2, imm(rs1)" % mn],
        r"Stores the low %d byte%s of \reg{rs2} to the data Local Store at \reg{rs1} plus a sign-extended "
        r"16-bit offset. The address must be naturally aligned." % (n, "s" if n > 1 else ""),
        op, exc,
        notes=r"S format: the data register is in bits 25:21, where other formats keep \field{rd}. "
              r"Because the store waits for an in-flight \insn{tput} that reads the same bytes, a buffer may be "
              r"refilled immediately after it is handed to \insn{tput}.",
        fmt="S", opname=opn)

# ---------------------------------------------------------------- control
BR = [("beq", "BEQ", "Branch if equal", "X[rs1] == X[rs2]", "equal"),
      ("bne", "BNE", "Branch if not equal", "X[rs1] != X[rs2]", "not equal"),
      ("blt", "BLT", "Branch if less than", "SInt(X[rs1]) < SInt(X[rs2])", "less than (signed)"),
      ("bge", "BGE", "Branch if greater or equal", "SInt(X[rs1]) >= SInt(X[rs2])", "greater than or equal (signed)"),
      ("bltu", "BLTU", "Branch if less than, unsigned", "UInt(X[rs1]) < UInt(X[rs2])", "less than (unsigned)"),
      ("bgeu", "BGEU", "Branch if greater or equal, unsigned", "UInt(X[rs1]) >= UInt(X[rs2])",
       "greater than or equal (unsigned)")]
for (mn, opn, title, cond, words) in BR:
    ins("ctl", mn.upper(), title,
        [(31, 26, b(OP[opn], 6), "f"), (25, 21, "rs1", "v"), (20, 16, "rs2", "v"), (15, 0, "off16", "v")],
        ["%s rs1, rs2, label" % mn],
        r"Branches to a PC-relative target if \reg{rs1} is %s \reg{rs2}. The offset is a signed count of "
        r"instructions, giving a range of $\pm$128~KiB." % words,
        """if %s then
    NextPC = PC + (SignExtend(off16, 64) << 2);
end""" % cond, [],
        notes=r"B format: the first source register is in bits 25:21. The assembler also provides "
              r"\insn{beqz}, \insn{bnez}, \insn{bltz}, \insn{bgez}, \insn{bgtz}, \insn{blez}, \insn{bgt}, \insn{ble}, "
              r"\insn{bgtu} and \insn{bleu} (Table~\ref{tab:pseudo})." if mn == "beq" else "",
        fmt="B", opname=opn)

ins("ctl", "JAL", "Jump and link",
    [(31, 26, b(OP["JAL"], 6), "f"), (25, 21, "rd", "v"), (20, 0, "off21", "v")],
    ["jal rd, label"],
    r"Writes the address of the next instruction to \reg{rd} and jumps to a PC-relative target. The offset "
    r"is a signed count of instructions, giving a range of $\pm$4~MiB, which covers the whole I-LS.",
    """X[rd] = PC + 4;
NextPC = PC + (SignExtend(off21, 64) << 2);""", [],
    notes=r"\insn{j label} is \insn{jal x0, label}; \insn{call label} is \insn{jal ra, label}. "
          r"Because every branch and jump is PC-relative, code is position-independent, which is what lets "
          r"overlays (\S\ref{sec:overlays}) run wherever they are loaded.", fmt="J", opname="JAL")
ins("ctl", "JALR", "Jump and link register", L_I(OP["JALR"]), ["jalr rd, rs1, imm"],
    r"Jumps to \reg{rs1} plus a sign-extended offset, with bits 1:0 of the target cleared, and writes the "
    r"address of the next instruction to \reg{rd}.",
    """target = (X[rs1] + SignExtend(imm16, 64)) AND NOT 3;
X[rd] = PC + 4;            // after reading X[rs1]: rd may equal rs1
NextPC = target;""", [],
    notes=r"\insn{ret} is \insn{jalr x0, ra, 0} and \insn{jr rs} is \insn{jalr x0, rs, 0}. A target outside "
          r"the I-LS is not detected here: the next fetch traps with \cause{ifault}.", fmt="I", opname="JALR")

# ---------------------------------------------------------------- transfers
XF_EXC = lambda need, lim, extra="": [
    ("capinv", r"\texttt{C[cs]} is not live (empty, or revocable and its granule revoked)", r"\texttt{X[ro]}"),
    ("perm", r"\texttt{C[cs]} lacks \perm{%s}, or is an endpoint (space 6)%s" % (need, extra), r"\texttt{X[ro]}"),
    ("xalign", r"space is not device space and any of \texttt{X[rl]}, \texttt{X[ro]}, \texttt{X[rn]} is not a multiple of 8", r"\texttt{X[ro]}"),
    ("bounds", r"device space: $\texttt{X[ro]} \geq \texttt{C[cs].len}$; any other space: $\texttt{X[ro]} + \texttt{X[rn]} > \texttt{C[cs].len}$",
     r"\texttt{X[ro]}"),
    ("lsfault", r"$\texttt{X[rl]} + \texttt{X[rn]} > %s$" % lim, r"\texttt{X[rl]}"),
]
XF_PEND = ("pend", r"CCR.PTRAP is set, \texttt{X[rn]} $\neq$ 0 and the D-LS range overlaps the destination of a "
                   r"device read of this core that is still in flight", r"\texttt{X[rl]}")
ins("xfer", "TGET", "Transfer get (far to D-LS)", L_X(0), ["tget tag, rl, cs, ro, rn"],
    r"Copies \reg{rn} bytes from offset \reg{ro} of the segment named by capability \reg{cs} into the data "
    r"Local Store at \reg{rl}, using transfer tag \field{tag}. The transfer is checked completely when it "
    r"issues and takes effect, architecturally, at its issue point: the hardware stalls any later access "
    r"that would observe it incomplete.",
    """cap = C[cs]; ls = X[rl]; off = X[ro]; n = X[rn];
CheckTransfer(cap, GET, ls, off, n, DLS_SIZE);      // may trap; nothing has moved yet
WaitPendingReads(ls, n);                            // ordered after device reads in flight
if cap.space == DEV then
    for i = 0 to n-1 do DLS[ls+i] = Device.Read(cap.base + off, i); end  // one byte per beat
else
    DLS[ls .. ls+n-1] = Far.Read(cap.space, cap.base + off, n);
end
MarkBusy(tag) until the transfer completes;         // visible through tpoll and tany""",
    XF_EXC("R", r"\texttt{DLS\_SIZE}", r", or names core-control space (space 5)") + [XF_PEND],
    notes=r"A memory transfer moves whole doublewords; device transfers move one byte per beat, beat $i$ "
          r"addressing device offset \texttt{base + X[ro]} + $i$, and may have any length and alignment "
          r"(\S\ref{sec:devxfer}). Issuing on a tag that is still busy waits for that tag. A zero-length "
          r"transfer is checked and then does nothing. A device read that has nothing to deliver yet (console "
          r"input, the console break port, the timer's WAIT register, the framebuffer controller's VSYNC "
          r"register) stays in flight until the device completes it; while it is in flight its tag is busy and "
          r"loads, stores and transfers that touch its D-LS bytes wait, exactly as for any other transfer. A "
          r"core has at most four device reads in flight (issuing a fifth waits), and software must keep at "
          r"most one read of the break port in flight per core.",
    fmt="X", opname="XFER", funct="sub = 0")
ins("xfer", "TPUT", "Transfer put (D-LS to far)", L_X(1), ["tput tag, rl, cs, ro, rn"],
    r"Copies \reg{rn} bytes from the data Local Store at \reg{rl} to offset \reg{ro} of the segment named by "
    r"\reg{cs}. The bytes copied are the ones in the D-LS at the issue point: later stores to them wait. "
    r"Through a core-control capability (space 5) it stops cores instead of writing memory "
    r"(\S\ref{sec:corectl}).",
    """cap = C[cs]; ls = X[rl]; off = X[ro]; n = X[rn];
CheckTransfer(cap, PUT, ls, off, n, DLS_SIZE);
WaitPendingReads(ls, n);                            // ordered after device reads in flight
if cap.space == DEV then
    for i = 0 to n-1 do Device.Write(cap.base + off, i, DLS[ls+i]); end  // one byte per beat
elsif cap.space == CORE then
    for i = 0 to n-1 by 8 do
        k = (cap.base + off + i) DIV 8;                  // one doubleword per core
        if k < N and DLS.Read(ls+i, 8)<0> == 1 then
            Core[k].IPEND = 1;                           // taken as a stop trap in user mode
        end
    end
else
    Far.Write(cap.space, cap.base + off, n, DLS[ls .. ls+n-1]);
end
MarkBusy(tag) until the transfer completes;""",
    XF_EXC("W", r"\texttt{DLS\_SIZE}") + [XF_PEND],
    notes=r"A \insn{tput} to a device moves one byte per beat: beat $i$ goes to device offset "
          r"\texttt{base + X[ro]} + $i$, except that a transfer starting at a stream port (console output, "
          r"the block device's submission port) delivers every byte to that stream. An 8-byte device register "
          r"takes its new value when its byte 7 is written (\S\ref{sec:devxfer}). A core-control doubleword "
          r"with bit~0 clear has no effect. A \insn{tput} whose D-LS source overlaps the destination of an "
          r"in-flight device read waits for that read, so it sends the bytes the read delivers.",
    fmt="X", opname="XFER", funct="sub = 1")
ins("xfer", "TGETX", "Transfer get to instruction Local Store", L_X(2), ["tgetx tag, rl, cs, ro, rn"],
    r"Copies \reg{rn} bytes from offset \reg{ro} of a memory segment into the \emph{instruction} Local Store "
    r"at \reg{rl}. It is the only way to place instructions in the I-LS at run time. Every overlay-map entry "
    r"whose I-LS slot overlaps the destination range is invalidated, so the map never points at replaced code.",
    """cap = C[cs]; ls = X[rl]; off = X[ro]; n = X[rn];
CheckTransfer(cap, GETX, ls, off, n, ILS_SIZE);
sl = if XSLOT != 0 then 1 << XSLOT else 4;               // bytes an entry covers in the I-LS
for e = 0 to 15 do
    if XMAP[e].valid and XMAP[e].ils < ls + n and ls < XMAP[e].ils + sl then
        XMAP[e].valid = FALSE;
    end
end
ILS[ls .. ls+n-1] = Far.Read(cap.space, cap.base + off, n);
MarkBusy(tag) until the transfer completes;""",
    XF_EXC("X", r"\texttt{ILS\_SIZE}", r", or names device or core-control space"),
    notes=r"Instruction fetch from a range an in-flight \insn{tgetx} is filling stalls, so a program may jump "
          r"to freshly loaded code immediately; there is no instruction-synchronisation barrier. "
          r"\insn{tgetx} writes the I-LS only, so it never waits for a pending device read.",
    fmt="X", opname="XFER", funct="sub = 2")
ins("xfer", "TWAIT", "Wait for transfer tags",
    [(31, 26, b(OP["TWAIT"], 6), "f"), (25, 16, b(0, 10), "z"), (15, 0, "mask", "v")],
    ["twait tg0, tg3, ...", "twait mask"],
    r"Waits until every transfer issued with a tag whose bit is set in \field{mask} has completed. "
    r"Because transfers are as-if-synchronous, \insn{twait} never changes a program's results; it exists to "
    r"control \emph{when} the core waits, e.g.\ before reading timing-visible state, or to retire a console "
    r"break read before its buffer is reused.",
    """while (BusyTags() AND ZeroExtend(mask, 16)) != 0 do Stall; end""", [],
    notes=r"The assembler accepts a list of tags or one mask expression. \insn{tfence} is \insn{twait 0xffff}.",
    fmt="I", opname="TWAIT")
ins("xfer", "TPOLL", "Poll transfer tags",
    [(31, 26, b(OP["TPOLL"], 6), "f"), (25, 21, "rd", "v"), (20, 16, b(0, 5), "z"), (15, 0, "mask", "v")],
    ["tpoll rd, tg0, tg3, ...", "tpoll rd, mask"],
    r"Writes to \reg{rd} the subset of the tags in \field{mask} whose transfers are still in flight, "
    r"without waiting.",
    """X[rd] = ZeroExtend(BusyTags() AND mask, 64);""", [],
    notes=r"\insn{tpoll} is \emph{timing-visible}: its result depends on transfer latency. In the reference "
          r"emulator every memory transfer completes at issue, so only the tags of pending device reads "
          r"(console input, the break port, the timer's WAIT, VSYNC) are ever reported busy.",
    fmt="I", opname="TPOLL")
ins("xfer", "TANY", "Wait for any event",
    [(31, 26, b(OP["TANY"], 6), "f"), (25, 21, "rd", "v"), (20, 16, "rs1", "v"), (15, 0, b(0, 16), "z")],
    ["tany rd, rs1"],
    r"Waits until at least one of the event sources selected by \reg{rs1} is ready and writes the mask of "
    r"ready sources to \reg{rd}. Bits 15:0 of \reg{rs1} select transfer tags \reg{tg0}--\reg{tg15}; a tag is "
    r"ready when no transfer issued on it is in flight. Bit~16 selects the inbox; it is ready when a gift "
    r"from any sender is waiting; the inbox belongs to the supervisor, so selecting it in user mode traps. "
    r"\IS has no interrupts: a device signals an event by completing a transfer, "
    r"and \insn{tany} is how a core sleeps until one of several such completions, or a capability, arrives "
    r"(\S\ref{sec:events}).",
    """want = X[rs1]<16:0>;
if want<16> == 1 and Mode == User then Trap(priv, instr); end
loop
    ready = ZeroExtend(NOT BusyTags() AND want<15:0>, 17);
    if want<16> == 1 and Inbox[self] holds a gift from any node then ready<16> = 1; end
    if want == 0 or ready != 0 then break; end
    Stall;
end
X[rd] = ZeroExtend(ready, 64);""",
    [("priv", r"executed in user mode with bit~16 of \reg{rs1} set", "instruction word")],
    notes=r"Bits 63:17 of \reg{rs1} are ignored. With no source selected, \insn{tany} returns 0 at once. "
          r"Several sources may be reported ready together. The result is timing-visible. \insn{tany} does not "
          r"remove anything from the inbox: the waiting gift is taken with \insn{ctake} or \insn{crecv}. "
          r"A pending stop request (\S\ref{sec:corectl}) ends the wait of a user-mode core with a \cause{stop} trap. "
          r"User-mode programs may wait for tags; a supervisor that runs programs written for the bare machine "
          r"emulates the inbox bit for them (\S\ref{sec:userinbox}).",
    fmt="I", opname="TANY")

AMO = [("add", 0, "Far atomic add", "new = old + X[rs2];"),
       ("swap", 1, "Far atomic swap", "new = X[rs2];"),
       ("cas", 2, "Far atomic compare and swap", "new = if old == X[rd] then X[rs2] else old;   // X[rd] read before it is written"),
       ("and", 3, "Far atomic AND", "new = old AND X[rs2];"),
       ("or", 4, "Far atomic OR", "new = old OR X[rs2];")]
for (nm, fn, title, upd) in AMO:
    mn = "tamo." + nm
    ins("xfer", mn.upper(), title,
        L_R(OP["TAMO"], funct=[(10, 7, "cs", "v"), (6, 3, b(0, 4), "f"), (2, 0, b(fn, 3), "f")]),
        ["%s rd, cs, rs1, rs2" % mn],
        (r"Atomically reads the doubleword at offset \reg{rs1} of the atomic segment \reg{cs}, "
         r"writes back a new value and returns the old one in \reg{rd}. The read-modify-write happens at the "
         r"memory itself and is indivisible: atomics on the same doubleword from all cores are linearizable. "
         r"The instruction first waits until none of this core's transfers to T2 or T3 is in flight, so every "
         r"far access the core issued before it is complete before the atomic is.") +
        (r" For \insn{tamo.cas}, \reg{rd} holds the expected value on entry; the new value \reg{rs2} is stored only "
         r"if the old value equals it, and \reg{rd} receives the old value either way." if nm == "cas" else ""),
        """cap = C[cs]; off = X[rs1];
if not Live(cap) then Trap(capinv, off); end
if not cap.A then Trap(perm, off); end
if off MOD 8 != 0 then Trap(xalign, off); end
if cap.len < 8 or off > cap.len - 8 then Trap(bounds, off); end
WaitMemory();                               // publication rule (invariant I4)
atomically
    old = Far.Read(cap.space, cap.base + off, 8);
    %s
    Far.Write(cap.space, cap.base + off, 8, new);
end
X[rd] = old;""" % upd,
        [("illegal", r"\field{funct}\texttt{<6:3>} $\neq$ 0, or \field{funct}\texttt{<2:0>} $>$ 4", "instruction word"),
         ("capinv", r"\texttt{C[cs]} is not live", r"\texttt{X[rs1]}"),
         ("perm", r"\texttt{C[cs]} lacks \perm{A}", r"\texttt{X[rs1]}"),
         ("xalign", r"\texttt{X[rs1]} is not a multiple of 8", r"\texttt{X[rs1]}"),
         ("bounds", r"$\texttt{C[cs].len} < 8$ or $\texttt{X[rs1]} > \texttt{C[cs].len} - 8$", r"\texttt{X[rs1]}")],
        notes=(r"Only \insn{catomic} creates \perm{A} capabilities, so an atomic segment is reachable only by "
               r"atomics: a plain read-modify-write of shared state cannot be expressed. Atomics do not use a tag "
               r"and are complete when the instruction retires."
               if nm == "add" else ""),
        fmt="R", opname="TAMO", funct="funct<2:0> = %d" % fn)

# ---------------------------------------------------------------- capabilities
CAPINV_CS = ("capinv", r"\texttt{C[cs]} is not live", r"\texttt{cs}")
ILL_CD = ("illegal", r"bit 25 (\field{cd} high bit) is 1", "instruction word")
ILL_CS = ("illegal", r"bit 20 (\field{cs} high bit) is 1", "instruction word")
ILL_BOTH = ("illegal", r"bit 25 or bit 20 is 1", "instruction word")
CAPOP_CD = ("capop", r"$\texttt{cd} \neq \texttt{cs}$ and \texttt{C[cd]} holds a live non-\perm{D} capability", r"\texttt{cd}")
PRIV = ("priv", r"executed in user mode", "instruction word")

ins("cap", "CMOV", "Capability move", L_R(OP["CAP"], rd=CD, rs1=CS, rs2=None, funct=cap_funct(0)), ["cmov cd, cs"],
    r"Moves capability \reg{cs} to \reg{cd}. A linear (non-\perm{D}) capability leaves \reg{cs} empty: it is "
    r"moved, never copied. A copyable (\perm{D}) capability is copied. The revocable flag and generation travel with it.",
    """cap = C[cs];
if not Live(cap) then Trap(capinv, cs); end
if cd != cs and not Replaceable(C[cd]) then Trap(capop, cd); end
C[cd] = cap;
if cd != cs and Linear(cap) then C[cs] = NULLCAP; end""",
    [ILL_BOTH, CAPINV_CS, CAPOP_CD],
    notes=r"No instruction silently destroys a live linear capability: to discard one, use \insref{cclear}.",
    fmt="R", opname="CAP", funct="0")
ins("cap", "CSPLIT", "Capability split", L_R(OP["CAP"], rd=CD, rs1=CS, rs2="rx", funct=cap_funct(1)),
    ["csplit cd, cs, rx"],
    r"Splits segment \reg{cs} at byte offset \reg{rx}: \reg{cs} keeps $[\textit{base}, \textit{base}+\reg{rx})$ "
    r"and \reg{cd} receives the rest. Both pieces keep the space, permissions, revocable flag and "
    r"generation. Either piece may be empty. The offset must be a multiple of 8: every capability's base is "
    r"8-byte aligned (\S\ref{sec:capalign}); a revoker (\perm{V}) is cut only at multiples of the 256~KiB "
    r"granule (\S\ref{sec:domains}).",
    """cap = C[cs]; k = X[rx];
if not Live(cap) then Trap(capinv, cs); end
if cd == cs or UInt(k) > cap.len or k MOD 8 != 0 or (cap.V and k MOD GRANULE != 0)
   or not Replaceable(C[cd]) then Trap(capop, k); end
C[cd] = Cap(valid: TRUE, space: cap.space, perms: cap.perms,
            base: cap.base + k, len: cap.len - k, rv: cap.rv, gen: cap.gen);
C[cs].len = k;""",
    [ILL_BOTH, CAPINV_CS, ("capop", r"$\texttt{cd} = \texttt{cs}$, or $\texttt{X[rx]} > \texttt{C[cs].len}$, "
                                    r"or \texttt{X[rx]} is not a multiple of 8 (of 256~KiB for a revoker), "
                                    r"or \texttt{C[cd]} holds a live non-\perm{D} capability", r"\texttt{X[rx]}")],
    notes=r"Splitting is how work is divided between cores: split, then \insref{cgive} each piece. A piece "
          r"of a revocable capability dies when its granule is revoked, wherever it has been given. The rule is the same "
          r"in every space, device space included: device ports and windows are 8-byte aligned, and transfers "
          r"reach single device bytes by offset. Lengths need not be multiples of 8.",
    fmt="R", opname="CAP", funct="1")
ins("cap", "CJOIN", "Capability join", L_R(OP["CAP"], rd=CD, rs1=CS, rs2=None, funct=cap_funct(2)),
    ["cjoin cd, cs"],
    r"Appends segment \reg{cs} to segment \reg{cd} and empties \reg{cs}. The two must be in the same space, "
    r"have identical permissions, the same revocable flag and the same generation, and \reg{cs} must "
    r"begin exactly where \reg{cd} ends; a revocable \reg{cs} must not begin a unit (its base is not the "
    r"first byte of a granule with the head bit set, \S\ref{sec:domains}). The result keeps the revocable "
    r"flag and generation. Memory therefore never moves from one revocable region or unit to another, or out "
    r"of one, by joining.",
    """d = C[cd]; s = C[cs];
if not Live(s) or not Live(d) then Trap(capinv, cs); end
if cd == cs or d.space != s.space or d.perms != s.perms or d.rv != s.rv or d.gen != s.gen
   or d.base + d.len != s.base
   or (s.rv and s.base MOD GRANULE == 0 and HEAD[Granule(s.space, s.base)])
   then Trap(capop, cs); end
C[cd].len = d.len + s.len;
C[cs] = NULLCAP;""",
    [ILL_BOTH, ("capinv", r"\texttt{C[cs]} or \texttt{C[cd]} is not live", r"\texttt{cs}"),
     ("capop", r"$\texttt{cd} = \texttt{cs}$; spaces, permissions, revocable flags or generations differ; $\texttt{C[cd].base} + \texttt{C[cd].len} \neq \texttt{C[cs].base}$; or a revocable \texttt{C[cs]} begins a unit", r"\texttt{cs}")],
    notes=r"Order matters: \insn{cjoin c4, c5} requires \reg{c5} to follow \reg{c4}. Joining is the inverse of "
          r"\insn{csplit}; together with \insn{ctake cd, rs} it lets a core reassemble pieces deterministically.",
    fmt="R", opname="CAP", funct="2")
ins("cap", "CSHARE", "Capability share (make read-only, copyable)",
    L_R(OP["CAP"], rd=CD, rs1=CS, rs2=None, funct=cap_funct(3)), ["cshare cd, cs"],
    r"Converts \reg{cs} into a copyable, non-writable capability in \reg{cd}: \perm{R} and \perm{X} are kept, "
    r"\perm{W}, \perm{A} and \perm{V} are dropped and \perm{D} is added. A linear source is consumed. For memory "
    r"that is not revocable the conversion is irrevocable: the segment can never be written again. For revocable "
    r"memory, \insn{crevoke} or \insn{cundom} ends every share and returns the segment to its owner.",
    """cap = C[cs];
if not Live(cap) then Trap(capinv, cs); end
if not (cap.R or cap.X) then Trap(perm, cs); end
if cd != cs and not Replaceable(C[cd]) then Trap(capop, cd); end
WaitMemory();                               // publication rule (invariant I4)
C[cd] = Cap(valid: TRUE, space: cap.space, perms: (cap.perms AND {R,X}) OR {D},
            base: cap.base, len: cap.len, rv: cap.rv, gen: cap.gen);
if cd != cs and Linear(cap) then C[cs] = NULLCAP; end""",
    [ILL_BOTH, CAPINV_CS, ("perm", r"\texttt{C[cs]} has neither \perm{R} nor \perm{X}", r"\texttt{cs}"), CAPOP_CD],
    notes=r"Waiting for the core's in-flight memory transfers first guarantees that every write through the "
          r"writable capability has landed before any copy can be read.",
    fmt="R", opname="CAP", funct="3")
ins("cap", "CATOMIC", "Capability make atomic", L_R(OP["CAP"], rd=CD, rs1=CS, rs2=None, funct=cap_funct(4)),
    ["catomic cd, cs"],
    r"Converts a writable memory capability into an \emph{atomic-only}, copyable capability "
    r"(permissions exactly \perm{A}+\perm{D}). The source is always consumed when $\texttt{cd} \neq \texttt{cs}$. "
    r"The segment can afterwards be accessed only by \insn{tamo}, by any number of holders. For memory that is "
    r"not revocable the conversion is irrevocable; for revocable memory, a revocation ends it.",
    """cap = C[cs];
if not Live(cap) then Trap(capinv, cs); end
if not cap.W or cap.space not in {T2, T3} then Trap(perm, cs); end
if cd != cs and not Replaceable(C[cd]) then Trap(capop, cd); end
WaitMemory();                               // publication rule (invariant I4)
C[cd] = Cap(valid: TRUE, space: cap.space, perms: {A, D}, base: cap.base, len: cap.len,
            rv: cap.rv, gen: cap.gen);
if cd != cs then C[cs] = NULLCAP; end""",
    [ILL_BOTH, CAPINV_CS, ("perm", r"\texttt{C[cs]} lacks \perm{W}, or is not T2 or T3 memory", r"\texttt{cs}"), CAPOP_CD],
    fmt="R", opname="CAP", funct="4")
ins("cap", "CRESTRICT", "Capability restrict permissions",
    L_R(OP["CAP"], rd=CD, rs1=CS, rs2="rmask", funct=cap_funct(5)), ["crestrict cd, cs, rmask"],
    r"Like \insn{cmov}, but the permissions of the result are ANDed with bits 5:0 of \reg{rmask} "
    r"(bit 0 \perm{R}, 1 \perm{W}, 2 \perm{X}, 3 \perm{A}, 4 \perm{D}, 5 \perm{V}). Permissions can only be removed.",
    """cap = C[cs];
if not Live(cap) then Trap(capinv, cs); end
if cd != cs and not Replaceable(C[cd]) then Trap(capop, cd); end
C[cd] = cap; C[cd].perms = cap.perms AND X[rmask]<5:0>;
if cd != cs and Linear(cap) then C[cs] = NULLCAP; end""",
    [ILL_BOTH, CAPINV_CS, CAPOP_CD],
    notes=r"Linearity is decided by the \emph{source}: restricting a copyable capability copies it even if "
          r"the result loses \perm{D}. Clearing \perm{D} can therefore make a linear copy of a copyable "
          r"capability; this is harmless because \perm{W} is never combined with \perm{D} outside device and "
          r"core-control space. Restricting an endpoint to \perm{W} or \perm{R} makes a send-only or "
          r"receive-only endpoint.",
    fmt="R", opname="CAP", funct="5")
for (mn, fn, title, val, d) in [
        ("cbase", 6, "Capability read base", "cap.base", r"the base of capability \reg{cs} (an absolute far address; for an endpoint, its node number)"),
        ("clen", 7, "Capability read length", "cap.len", r"the length in bytes of capability \reg{cs}"),
        ("cperms", 8, "Capability read permissions", "ZeroExtend(cap.space, 3) << 8 OR ZeroExtend(cap.perms, 6)",
         r"the space and permissions of \reg{cs}: bits 5:0 are \perm{R} \perm{W} \perm{X} \perm{A} \perm{D} \perm{V}, "
         r"bits 10:8 the space (2 T2, 3 T3, 4 device, 5 core control, 6 endpoint)")]:
    ins("cap", mn.upper(), title, L_R(OP["CAP"], rs1=CS, rs2=None, funct=cap_funct(fn)), ["%s rd, cs" % mn],
        r"Writes to integer register \reg{rd} %s." % d,
        """cap = C[cs];
if not Live(cap) then Trap(capinv, cs); end
X[rd] = %s;""" % val, [ILL_CS, CAPINV_CS],
        notes=r"Capabilities can be inspected but never forged: no instruction turns an integer into a capability. "
              r"The revocable flag and the generation cannot be read."
        if mn == "cbase" else "", fmt="R", opname="CAP", funct=str(fn))
ins("cap", "CVALID", "Capability test live", L_R(OP["CAP"], rs1=CS, rs2=None, funct=cap_funct(14)),
    ["cvalid rd, cs"], r"Writes 1 to \reg{rd} if \reg{cs} holds a live capability, otherwise 0. Never traps on an "
    r"empty register or a revoked capability.",
    "X[rd] = if Live(C[cs]) then 1 else 0;", [ILL_CS],
    notes=r"A revocable capability whose granule has been revoked reads as not live, exactly like an empty register.",
    fmt="R", opname="CAP", funct="14")
ins("cap", "CGIVE", "Capability give to another node",
    L_R(OP["CAP"], rd=None, rs1=CS, rs2="rx", funct=cap_funct(9)), ["cgive cs, rx"],
    r"Sends capability \reg{cs} to the inbox of node \reg{rx}: nodes $0 \ldots N-1$ are cores and node $N$ is "
    r"block device~0. A linear capability leaves \reg{cs} empty; a copyable one is copied. The instruction "
    r"first waits until none of this core's transfers to T2 or T3 is in flight, so everything the giver wrote "
    r"is in memory, and everything it read has been read, before the receiver can use the capability. A core's inbox keeps a separate "
    r"two-entry queue for each sender; if this core's queue at the destination is full, the instruction waits. "
    r"Gifts from other senders never make it wait.",
    """cap = C[cs]; t = X[rx];
if not Live(cap) then Trap(capinv, cs); end
if (Mode == User and CORECOUNT == 0)
   or (CORECOUNT != 0 and UInt(t) >= CORECOUNT) then Trap(capop, t); end
node = t + COREBASE;                                // physical node number
if node > N or (node < N and Core[node].halted) then Trap(capop, node); end
WaitMemory();                                         // publication rule (invariant I4)
while Inbox[node][PhysicalCoreID] is full do Block; end      // this sender's queue only
Inbox[node][PhysicalCoreID].Append(cap);
if Linear(cap) then C[cs] = NULLCAP; end""",
    [ILL_CS, CAPINV_CS,
     ("capop", r"user mode with $\texttt{corecount} = 0$, or $\texttt{corecount} \neq 0$ and $\texttt{X[rx]} \geq \texttt{corecount}$", r"\texttt{X[rx]}"),
     ("capop", r"physical node $> N$, or names a core that has halted", r"physical node")],
    notes=r"Each core inbox holds two gifts per sender; the block device has one four-entry inbox. Node numbers "
          r"are relative to \csr{corebase} (\S\ref{sec:supervised}); in user mode \insn{cgive} reaches only the "
          r"cores of the program's window, and a user-mode program reaches other nodes only through endpoint "
          r"capabilities (\insref{csend}). A core may give to itself.", fmt="R", opname="CAP", funct="9")
ins("cap", "CTAKE", "Capability take from inbox",
    L_R(OP["CAP"], rd=CD, rs1=None, rs2="rs", funct=cap_funct(10, flagvar=True)), ["ctake cd", "ctake cd, rs"],
    r"Removes a capability from this core's inbox and places it in \reg{cd}, waiting until one is available. "
    r"With a sender operand (\field{f} = 1) it takes the oldest gift from sender \reg{rs}. Without one "
    r"(\field{f} = 0) it takes the oldest gift of the \emph{lowest-numbered} sender that has one. "
    r"CSR \csr{takefrom} records the sender. Supervisor mode only: the inbox belongs to the supervisor.",
    """if Mode == User then Trap(priv, instr); end
if not Replaceable(C[cd]) then Trap(capop, cd); end   // checked before waiting
if f == 1 then
    s = X[rs] + COREBASE;                                // physical sender
    while s > N or Inbox[self][s] is empty do Block; end
else
    while every Inbox[self][0..N] is empty do Block; end
    s = lowest n with Inbox[self][n] not empty;
end
C[cd] = Inbox[self][s].RemoveOldest();
TAKEFROM = s - COREBASE;""",
    [ILL_CD, PRIV, ("capop", r"\texttt{C[cd]} holds a live non-\perm{D} capability", r"\texttt{cd}")],
    notes=r"Which gift an any-sender \insn{ctake} returns depends on timing when several nodes may give "
          r"concurrently (a higher-numbered sender's gift is taken if a lower one's has not arrived yet); use "
          r"\insn{ctake cd, rs} for deterministic fan-in (\S\ref{sec:determinism}). "
          r"The gift from the block device arrives from node $N$. A gift may be a capability that has "
          r"been revoked since it was given; it arrives dead. In user mode \insn{ctake} always traps with "
          r"\cause{priv}; a supervisor emulates it for programs written for the bare machine "
          r"(\S\ref{sec:userinbox}).", fmt="R", opname="CAP", funct="10")
ins("cap", "CPOLL", "Capability poll inbox",
    L_R(OP["CAP"], rs1=None, rs2=None, funct=cap_funct(15)), ["cpoll rd"],
    r"Writes to \reg{rd} a bit mask of the senders that have at least one gift waiting in this core's inbox "
    r"(bit $i$ set for sender $i$, relative to \csr{corebase}). Never waits. Supervisor mode only.",
    """if Mode == User then Trap(priv, instr); end
m = 0;
for n = 0 to N do
    s = n - COREBASE;
    if Inbox[self][n] not empty and UInt(s) < 64 then m = m OR (1 << s); end
end
X[rd] = m;""", [PRIV],
    notes=r"Like \insn{tpoll}, \insn{cpoll} is timing-visible whenever a gift may be in transit, even from a single sender. "
          r"With at most 15 cores and one block device there are at most 16 senders, so the mask fits bits 15:0.",
    fmt="R", opname="CAP", funct="15")
ins("cap", "CCLEAR", "Capability clear", L_R(OP["CAP"], rd=CD, rs1=None, rs2=None, funct=cap_funct(11)),
    ["cclear cd"],
    r"Empties capability register \reg{cd}. This is the only way to discard a live linear capability; "
    r"the authority it carried is lost for good.",
    "C[cd] = NULLCAP;", [ILL_CD], fmt="R", opname="CAP", funct="11")
ins("cap", "CSAVE", "Capability save to table",
    L_R(OP["CAP"], rd=None, rs1=CS, rs2=None, funct=cap_funct(12, slot=True)), ["csave cs, slot"],
    r"Stores capability \reg{cs} in slot \field{slot} (0--63) of the per-core capability save table. "
    r"A linear capability is moved; a copyable one is copied. The save table belongs to the supervisor. "
    r"The immediate reaches only slots 0--63; \insn{csavex} reaches every slot of the table, whose size "
    r"$\textit{CTAB}$ the platform table gives (256 by default).",
    """if Mode == User then Trap(priv, instr); end
cap = C[cs];
if not Live(cap) then Trap(capinv, cs); end
if not Replaceable(CTAB[slot]) then Trap(capop, slot); end
CTAB[slot] = cap;
if Linear(cap) then C[cs] = NULLCAP; end""",
    [ILL_CS, PRIV, CAPINV_CS, ("capop", r"\texttt{CTAB[slot]} holds a live non-\perm{D} capability", r"\field{slot}")],
    notes=r"The save table is not memory: no other instruction reads or writes it, so capabilities cannot be "
          r"forged through it, and user-mode code cannot reach it at all. A supervisor keeps there the "
          r"capabilities that must survive while a program owns the capability registers.",
    fmt="R", opname="CAP", funct="12")
ins("cap", "CRESTORE", "Capability restore from table",
    L_R(OP["CAP"], rd=CD, rs1=None, rs2=None, funct=cap_funct(13, slot=True)), ["crestore cd, slot"],
    r"Loads capability register \reg{cd} from save-table slot \field{slot}. A linear capability leaves the "
    r"slot empty; a copyable one stays in the slot as well. Supervisor mode only. The immediate reaches only "
    r"slots 0--63; \insn{crestorex} reaches every slot.",
    """if Mode == User then Trap(priv, instr); end
cap = CTAB[slot];
if not Live(cap) then Trap(capinv, slot); end
if not Replaceable(C[cd]) then Trap(capop, cd); end
C[cd] = cap;
if Linear(cap) then CTAB[slot] = NULLCAP; end""",
    [ILL_CD, PRIV, ("capinv", r"\texttt{CTAB[slot]} is not live", r"\field{slot}"),
     ("capop", r"\texttt{C[cd]} holds a live non-\perm{D} capability", r"\texttt{cd}")],
    fmt="R", opname="CAP", funct="13")

# ---- second capability group: revocation by address and endpoints (OP_CAP2)
def cap2_funct(fn):
    return [(10, 4, b(0, 7), "z"), (3, 0, b(fn, 4), "f")]


ILL_C2 = ("illegal", r"bit 25 or bit 20 is 1, or \field{funct}\texttt{<3:0>} $>$ 7", "instruction word")
CE_RD = [(25, 25, "0", "f"), (24, 21, "ce", "v")]
CE_RS = [(20, 20, "0", "f"), (19, 16, "ce", "v")]
REVOKER_INV = ("capinv", r"\texttt{C[cs]} is not a revoker: not live, or lacks \perm{V}", r"\texttt{cs}")
CAPOP_C2 = ("capop", r"$\texttt{cd} = \texttt{cs}$, or \texttt{C[cd]} holds a live non-\perm{D} capability", r"\texttt{cd}")

ins("cap", "CDOM", "Capability make revocable",
    L_R(OP["CAP2"], rd=CD, rs1=CS, rs2=None, funct=cap2_funct(0)), ["cdom cd, cs"],
    r"Makes the region of the writable, linear, non-revocable memory capability \reg{cs} revocable. The "
    r"region must be whole granules: base and length multiples of 256~KiB, length not 0. It becomes one "
    r"unit, and every granule of it gets the generation one past the highest any of them had. \reg{cd} "
    r"receives the \term{working capability}: the same segment and permissions, revocable, with that "
    r"generation. \reg{cs} becomes the region's \term{revoker}: the same segment with permission \perm{V} "
    r"only, not revocable, remembering the permissions. Every capability later derived from the working "
    r"capability is revocable too, and \insref{crevoke} or \insref{cundom} on the revoker kills all of them at "
    r"once.",
    """if Mode == User then Trap(priv, instr); end
s = C[cs];
if not Live(s) then Trap(capinv, cs); end
if cd == cs or not s.W or s.D or s.rv or s.space not in {T2, T3} or s.len == 0
   or s.base MOD GRANULE != 0 or s.len MOD GRANULE != 0
   or not Replaceable(C[cd]) then Trap(capop, cs); end
a = Granule(s.space, s.base);  b = a + s.len / GRANULE;
g = 1 + max(GEN[a .. b-1]);                 // newer than any capability based there
for k in a .. b-1 do GEN[k] = g; HEAD[k] = (k == a); end
if b < end of the space's granules then HEAD[b] = TRUE; end   // the unit ends here
C[cd] = Cap(valid: TRUE, space: s.space, perms: s.perms, base: s.base, len: s.len,
            rv: TRUE, gen: g);
C[cs] = Cap(valid: TRUE, space: s.space, perms: {V}, base: s.base, len: s.len,
            rv: FALSE, gen: s.perms);       // a revoker remembers the permissions""",
    [ILL_C2, PRIV, CAPINV_CS,
     ("capop", r"$\texttt{cd} = \texttt{cs}$; \texttt{C[cs]} lacks \perm{W}, has \perm{D}, is revocable already, "
               r"is not T2 or T3 memory, is empty, or its base or length is not a multiple of 256~KiB; or "
               r"\texttt{C[cd]} holds a live non-\perm{D} capability", r"\texttt{cs}")],
    notes=r"The granule table is machine-wide (\S\ref{sec:domains}); the number of revocable regions is limited "
          r"only by memory. The revoker is linear and grants no access; a supervisor normally keeps it in its "
          r"save table. A source that is revocable already is refused, so two revokers never cover one granule.",
    fmt="R", opname="CAP2", funct="0")
ins("cap", "CREVOKE", "Capability revoke",
    L_R(OP["CAP2"], rd=CD, rs1=CS, rs2=None, funct=cap2_funct(1)), ["crevoke cd, cs"],
    r"Revokes the range of the revoker \reg{cs}: every unit the range touches is revoked whole, by advancing "
    r"its granules' generations, so every revocable capability based there dies, wherever it is held "
    r"(capability registers and save tables of every core, inboxes, the block device). The range becomes a "
    r"unit of its own, and so does what is left of a touched unit on either side. \reg{cd} receives a fresh "
    r"working capability for the range, with the permissions the revoker remembers and the new generation. "
    r"The revoker stays in \reg{cs}.",
    """if Mode == User then Trap(priv, instr); end
r = C[cs];
if not IsRevoker(r) then Trap(capinv, cs); end
if cd == cs or not Replaceable(C[cd]) then Trap(capop, cd); end
if r.len == 0 then Trap(capop, cs); end
g = RevokeUnits(r);                         // every revocable capability based there is now dead
C[cd] = Cap(valid: TRUE, space: r.space, perms: r.gen<5:0>, base: r.base, len: r.len,
            rv: TRUE, gen: g);""",
    [ILL_C2, PRIV, REVOKER_INV, CAPOP_C2, ("capop", r"the revoker is empty (length 0)", r"\texttt{cs}")],
    notes=r"Revocation costs one instruction regardless of how many copies exist: a revocable capability is checked "
          r"against its granule's generation on every use (\texttt{Live}). Because every capability that could "
          r"reach the range is dead, minting a new writable one keeps the single-writer invariant. A revoker "
          r"piece cut at granule boundaries revokes just its part of a region: this is how StrataOS keeps one "
          r"revoker for all its arenas (\S\ref{sec:os-mem}). In an implementation the instruction takes about one "
          r"cycle per granule of the units it touches.",
    fmt="R", opname="CAP2", funct="1")
ins("cap", "CUNDOM", "Capability make non-revocable",
    L_R(OP["CAP2"], rd=CD, rs1=CS, rs2=None, funct=cap2_funct(2)), ["cundom cd, cs"],
    r"Revokes the range of the revoker \reg{cs} exactly as \insref{crevoke} does, then consumes the revoker: "
    r"\reg{cd} receives an ordinary, non-revocable capability for the range with the permissions the "
    r"revoker remembers.",
    """if Mode == User then Trap(priv, instr); end
r = C[cs];
if not IsRevoker(r) then Trap(capinv, cs); end
if cd == cs or not Replaceable(C[cd]) then Trap(capop, cd); end
if r.len == 0 then Trap(capop, cs); end
RevokeUnits(r);
C[cd] = Cap(valid: TRUE, space: r.space, perms: r.gen<5:0>, base: r.base, len: r.len,
            rv: FALSE, gen: 0);
C[cs] = NULLCAP;""",
    [ILL_C2, PRIV, REVOKER_INV, CAPOP_C2, ("capop", r"the revoker is empty (length 0)", r"\texttt{cs}")],
    notes=r"\insn{cundom} is the inverse of \insref{cdom}: one instruction takes back the whole range, including "
          r"pieces that were shared, made atomic or given away, and makes it ordinary memory again.",
    fmt="R", opname="CAP2", funct="2")
ins("cap", "CSEND", "Capability send through endpoint",
    L_R(OP["CAP2"], rd=CE_RD, rs1=CS, rs2=None, funct=cap2_funct(3)), ["csend cs, ce"],
    r"Gives capability \reg{cs} to the node named by endpoint capability \reg{ce}, exactly as \insn{cgive} "
    r"does, except that the destination comes from the endpoint rather than from an integer register and is "
    r"not subject to the core window. The endpoint must permit sending (\perm{W}).",
    """e = C[ce]; g = C[cs];
if not Live(e) or e.space != EP or not e.W then Trap(capinv, ce); end
if not Live(g) then Trap(capinv, cs); end
node = e.base;                                      // a physical node number
if node > N or (node < N and Core[node].halted) then Trap(capop, node); end
WaitMemory();                                         // publication rule (invariant I4)
while Inbox[node][PhysicalCoreID] is full do Block; end
Inbox[node][PhysicalCoreID].Append(g);
if Linear(g) then C[cs] = NULLCAP; end""",
    [ILL_C2, ("capinv", r"\texttt{C[ce]} is not a live endpoint with \perm{W}", r"\texttt{ce}"),
     ("capinv", r"\texttt{C[cs]} is not live", r"\texttt{cs}"),
     ("capop", r"the endpoint names a node $> N$ or a core that has halted", r"node")],
    notes=r"Encoding: the endpoint is in the \field{rd} position and the capability sent in the \field{rs1} "
          r"position. \insn{csend} is available in user mode: an endpoint is the way a supervisor lets a program "
          r"talk to a node outside its window (StrataOS gives every program send-only endpoints to the cores of its servers).",
    fmt="R", opname="CAP2", funct="3")
ins("cap", "CRECV", "Capability receive through endpoint",
    L_R(OP["CAP2"], rd=CD, rs1=CE_RS, rs2=None, funct=cap2_funct(4)), ["crecv cd, ce"],
    r"Takes the oldest gift from the node named by endpoint capability \reg{ce} into \reg{cd}, waiting until "
    r"there is one. The endpoint must permit receiving (\perm{R}). It is \insn{ctake cd, rs} with the sender "
    r"named by a capability instead of a window-relative number.",
    """e = C[ce];
if not Live(e) or e.space != EP or not e.R then Trap(capinv, ce); end
if not Replaceable(C[cd]) then Trap(capop, cd); end   // checked before waiting
n = e.base;
while Inbox[self][n] is empty do Block; end
C[cd] = Inbox[self][n].RemoveOldest();
TAKEFROM = n - COREBASE;""",
    [ILL_C2, ("capinv", r"\texttt{C[ce]} is not a live endpoint with \perm{R}", r"\texttt{ce}"),
     ("capop", r"\texttt{C[cd]} holds a live non-\perm{D} capability", r"\texttt{cd}")],
    notes=r"Not privileged: unlike \insn{ctake}, \insn{crecv} executes in user mode, because holding an "
          r"endpoint with \perm{R} is itself the authority to receive from that node. A supervisor that keeps "
          r"the inbox to itself gives programs send-only endpoints. Gifts from other senders stay in their own "
          r"queues.",
    fmt="R", opname="CAP2", funct="4")
ins("cap", "CMKEP", "Capability make endpoint",
    L_R(OP["CAP2"], rd=CD, rs1=[(20, 20, "0", "f"), (19, 16, b(0, 4), "z")], rs2="rx", funct=cap2_funct(5)),
    ["cmkep cd, rx"],
    r"Creates in \reg{cd} an endpoint capability for physical node \reg{rx}: space 6, base = the node number, "
    r"length 1, permissions \perm{R}\perm{W}\perm{D} (send, receive, copyable). Supervisor mode only.",
    """if Mode == User then Trap(priv, instr); end
if not Replaceable(C[cd]) then Trap(capop, cd); end
if UInt(X[rx]) > N then Trap(capop, X[rx]); end
C[cd] = Cap(valid: TRUE, space: EP, perms: {R, W, D}, base: X[rx], len: 1, dom: 0, gen: 0);""",
    [ILL_C2, PRIV, ("capop", r"\texttt{C[cd]} holds a live non-\perm{D} capability", r"\texttt{cd}"),
     ("capop", r"$\texttt{X[rx]} > N$", r"\texttt{X[rx]}")],
    notes=r"An endpoint conveys no access to memory: transfers through it trap with \cause{perm}. It is the only "
          r"capability an instruction creates from an integer, which is why making one is privileged.",
    fmt="R", opname="CAP2", funct="5")

ins("cap", "CSAVEX", "Capability save to table, register slot",
    L_R(OP["CAP2"], rd=None, rs1=CS, rs2="rx", funct=cap2_funct(6)), ["csavex cs, rx"],
    r"Stores capability \reg{cs} in save-table slot \reg{rx}, which may be any slot of the table "
    r"($0 \le \reg{rx} < \textit{CTAB}$, the table's size from the platform table: 256 by default, at least 64). "
    r"Otherwise it is \insn{csave}: a linear capability is moved, a copyable one copied; slots 0--63 are the "
    r"ones \insn{csave} names with its immediate. Supervisor mode only.",
    """if Mode == User then Trap(priv, instr); end
s = UInt(X[rx]);
if s >= CTAB then Trap(capop, X[rx]); end
cap = C[cs];
if not Live(cap) then Trap(capinv, cs); end
if not Replaceable(CTAB[s]) then Trap(capop, X[rx]); end
CTAB[s] = cap;
if Linear(cap) then C[cs] = NULLCAP; end""",
    [ILL_C2, PRIV, ("capop", r"$\texttt{X[rx]} \ge \textit{CTAB}$ (checked first)", r"\texttt{X[rx]}"), CAPINV_CS,
     ("capop", r"\texttt{CTAB[X[rx]]} holds a live non-\perm{D} capability", r"\texttt{X[rx]}")],
    notes=r"The whole 64-bit value of \reg{rx} is the slot: a value of $2^{16}$ is out of range, not slot 0. "
          r"A supervisor that keeps more capabilities than 64 (StrataOS keeps every switched-out thread's "
          r"memory capabilities on its core) uses this form; the immediate forms are for fixed slots.",
    fmt="R", opname="CAP2", funct="6")
ins("cap", "CRESTOREX", "Capability restore from table, register slot",
    L_R(OP["CAP2"], rd=CD, rs1=[(20, 20, "0", "f"), (19, 16, b(0, 4), "z")], rs2="rx", funct=cap2_funct(7)),
    ["crestorex cd, rx"],
    r"Loads capability register \reg{cd} from save-table slot \reg{rx} ($0 \le \reg{rx} < \textit{CTAB}$). "
    r"Otherwise it is \insn{crestore}: a linear capability leaves the slot empty, a copyable one stays. "
    r"Supervisor mode only.",
    """if Mode == User then Trap(priv, instr); end
s = UInt(X[rx]);
if s >= CTAB then Trap(capop, X[rx]); end
cap = CTAB[s];
if not Live(cap) then Trap(capinv, X[rx]); end
if not Replaceable(C[cd]) then Trap(capop, cd); end
C[cd] = cap;
if Linear(cap) then CTAB[s] = NULLCAP; end""",
    [ILL_C2, PRIV, ("capop", r"$\texttt{X[rx]} \ge \textit{CTAB}$ (checked first)", r"\texttt{X[rx]}"),
     ("capinv", r"\texttt{CTAB[X[rx]]} is not live", r"\texttt{X[rx]}"),
     ("capop", r"\texttt{C[cd]} holds a live non-\perm{D} capability", r"\texttt{cd}")],
    fmt="R", opname="CAP2", funct="7")

# ---------------------------------------------------------------- system
ins("sys", "CSRR", "Read control and status register",
    [(31, 26, b(OP["CSRR"], 6), "f"), (25, 21, "rd", "v"), (20, 16, b(0, 5), "z"), (15, 0, "csr", "v")],
    ["csrr rd, csr"],
    r"Copies a CSR to \reg{rd}. The CSR may be named (Table~\ref{tab:csrs}) or given as a number. "
    r"\csr{cause}, \csr{epc}, \csr{tval} and \csr{tvec} are banked: they read the copy of the current "
    r"privilege mode. Reading an unassigned CSR number returns 0.",
    """if Mode == User and csr in {sscratch, ipend} then Trap(priv, instr); end
X[rd] = CSR[csr];      // see Table for the value each CSR reads as""",
    [("priv", r"user mode reads \csr{sscratch} or \csr{ipend}", "instruction word")],
    notes=r"\csr{cycle} and \csr{stalls} are timing-visible. \csr{coreid}, \csr{ncores} "
          r"and \csr{takefrom} read values relative to the core window.", fmt="I", opname="CSRR")
ins("sys", "CSRW", "Write control and status register",
    [(31, 26, b(OP["CSRW"], 6), "f"), (25, 21, b(0, 5), "z"), (20, 16, "rs1", "v"), (15, 0, "csr", "v")],
    ["csrw csr, rs1"],
    r"Copies \reg{rs1} to a writable CSR. Writes to read-only or unassigned CSRs are ignored. The banked "
    r"trap CSRs are written in the current mode's copy. The supervisor's state (\csr{status}, the core window "
    r"and CSRs 19--24) cannot be written in user mode.",
    """if Mode == User and csr in {status, corebase, corecount, ucause, uepc,
                              utval, utvec, sscratch, ipend} then Trap(priv, instr); end
if CSR[csr] is writable then CSR[csr] = X[rs1]; end""",
    [("priv", r"user mode writes \csr{status}, \csr{corebase}, \csr{corecount} or CSRs 19--24", "instruction word")],
    notes=r"Note the operand order: the CSR comes first. Writing \csr{status} changes only bit~1 (SPP): bit~0 "
          r"always reflects the current mode.", fmt="I", opname="CSRW")
ins("sys", "HALT", "Halt core (or return to supervisor)",
    [(31, 26, b(OP["SYS"], 6), "f"), (25, 16, b(0, 10), "z"), (15, 0, b(0, 16), "f")], ["halt"],
    r"Waits for all of this core's in-flight transfers to complete, device reads included. In supervisor mode it then stops the "
    r"core; \reg{a0} is conventionally the exit code. In user mode it does not stop the core: it traps to the "
    r"supervisor with cause \cause{halt}, which is how a program run by an operating system ends.",
    """DrainTransfers();                         // invariant I4
if Mode == User then
    Trap(halt, 0);                        // always to the supervisor
else
    Halted = TRUE;                        // the core never fetches again
end""", [("halt", r"executed in user mode", "0")],
    notes=r"A halted core cannot receive gifts: \insn{cgive} to it traps \cause{capop}. Its capabilities, and "
          r"the memory only they named, are lost unless they are revocable, which the holder of the revoker "
          r"can revoke. The drain comes first in both modes: a user-mode \insn{halt} traps only after the "
          r"core's transfers have completed. A device read that may never complete must therefore be retired "
          r"before halting; for a read of the console break port, write the release port first "
          r"(\S\ref{sec:break}).", fmt="I", opname="SYS", funct="imm16 = 0")
ins("sys", "ERET", "Return from trap",
    [(31, 26, b(OP["SYS"], 6), "f"), (25, 16, b(0, 10), "z"), (15, 0, b(1, 16), "f")], ["eret"],
    r"Returns from a trap handler. In user mode it continues at \csr{uepc} and stays in user mode. In "
    r"supervisor mode it continues at the supervisor's \csr{epc} and enters the mode recorded in "
    r"\csr{status}.SPP: user mode if SPP is 0, supervisor mode if it is 1. After a trap the \csr{epc} of the "
    r"mode that took it holds the address of the trapping instruction, so \insn{eret} re-executes it; a "
    r"handler that wants to skip it adds 4 first.",
    """if Mode == User then
    NextPC = UEPC;
else
    NextPC = SEPC;
    Mode = if STATUS.SPP == 1 then Supervisor else User;
end""", [("illegal", r"$\field{imm16} > 2$ (an unassigned SYS function)", "instruction word")],
    notes=r"A supervisor starts a program by setting \csr{epc} to its entry, clearing \csr{status}.SPP and "
          r"executing \insn{eret}. \insn{eret} restores no other state.", fmt="I", opname="SYS", funct="imm16 = 1")
ins("sys", "SVC", "Supervisor call",
    [(31, 26, b(OP["SYS"], 6), "f"), (25, 16, b(0, 10), "z"), (15, 0, b(2, 16), "f")], ["svc"],
    r"Traps from user mode to the supervisor with cause \cause{svc}. It is a program's explicit request to "
    r"the supervisor of its core: block, yield, receive. The trap always goes to the supervisor, never to "
    r"the program's own handler. \csr{epc} of the supervisor holds the address of the \insn{svc}; the "
    r"supervisor returns to the instruction after it by adding 4. The instruction has no operands: arguments "
    r"and results are passed in registers by software convention. In supervisor mode \insn{svc} is an "
    r"illegal instruction.",
    """if Mode == User then
    Trap(svc, 0);                         // always to the supervisor
else
    Trap(illegal, instr);
end""", [("svc", r"executed in user mode", "0"),
         ("illegal", r"executed in supervisor mode", "instruction word")],
    notes=r"\insn{svc} always traps, so it never retires and \csr{instret} does not count it. It does not "
          r"wait for the core's transfers. The StrataOS convention passes the function number in \reg{a0} "
          r"(\S\ref{sec:os-svc}). The encoding is the one the instruction-synchronisation barrier "
          r"\insn{isync} of earlier editions had; that instruction no longer exists.",
    fmt="I", opname="SYS", funct="imm16 = 2")
ins("sys", "LTAG", "Look up software-cache tag", L_I(OP["LTAG"], imm=[(15, 0, b(0, 16), "z")]),
    ["ltag rd, rs1"],
    r"Looks up far offset \reg{rs1} in the set-associative tag table described by CSRs \csr{ttag}, "
    r"\csr{tdata} and \csr{tgeom} (\S\ref{sec:swcache}). On a hit, \reg{rd} receives the D-LS address of the "
    r"cached byte. On a miss, \reg{rd} receives the D-LS address of the victim line's storage with bit~63 set.",
    """lsh = TGEOM<5:0>; lsets = TGEOM<11:6>; ways = TGEOM<15:12>;
line = X[rs1] >> lsh;  set = line AND ((1 << lsets) - 1);
span = (ways + 1) * 8;  eb = TTAG + set * span;  key = (line << 1) OR 1;
if ways == 0 or eb MOD 8 != 0 or eb > DLS_SIZE - span then Trap(lsfault, eb); end
ctr = DLS.Read(eb + 8*ways, 8);  victim = if ctr < ways then ctr else 0;
X[rd] = (TDATA + ((set*ways + victim) << lsh)) OR (1 << 63);       // miss
for w = 0 to ways-1 do
    if DLS.Read(eb + 8*w, 8) == key then                          // hit
        X[rd] = TDATA + ((set*ways + w) << lsh) + (X[rs1] AND ((1 << lsh) - 1));
        break;
    end
end""",
    [("lsfault", r"$\textit{ways} = 0$, or the set's table entry is misaligned or outside the D-LS", r"entry address \texttt{eb}"),
     ("pend", r"CCR.PTRAP = 1 and the set's entry overlaps an in-flight \insn{tget} destination", r"\texttt{eb}")],
    notes=r"The tag table is ordinary D-LS memory that software initialises (zero = invalid). A miss result is "
          r"negative as a signed number, so \insn{bltz} detects it.", fmt="I", opname="LTAG")
ins("sys", "LINST", "Install software-cache tag",
    [(31, 26, b(OP["LINST"], 6), "f"), (25, 21, b(0, 5), "z"), (20, 16, "rs1", "v"), (15, 0, b(0, 16), "z")],
    ["linst rs1"],
    r"Records the line containing far offset \reg{rs1} in the current victim way of its set and advances "
    r"the set's replacement counter, which cycles $0, 1, \ldots, \textit{ways}-1$.",
    """(compute lsh, ways, set, eb, key, victim exactly as LTAG; same lsfault check)
DLS.Write(eb + 8*victim, 8, key);
DLS.Write(eb + 8*ways, 8, if victim + 1 == ways then 0 else victim + 1);""",
    [("lsfault", r"as \insn{ltag}", r"\texttt{eb}"),
     ("pend", r"CCR.PTRAP = 1 and the entry overlaps an in-flight \insn{tget} destination or \insn{tput} source", r"\texttt{eb}")],
    notes=r"\insn{linst} does not check whether the line is already present; call it only after an \insn{ltag} miss.",
    fmt="I", opname="LINST")
XIDX = [(25, 25, "0", "f"), (24, 21, "idx", "v")]
ins("sys", "XMAP", "Overlay map",
    L_R(OP["XMAP"], rd=XIDX, rs1="rils", rs2="roff",
        funct=[(10, 5, b(0, 6), "z"), (4, 4, "0", "f"), (3, 0, "cs", "v")]),
    ["xmap idx, rils, cs, roff"],
    r"Sets overlay-map entry \field{idx} (0 to $\textit{NXMAP}-1$) to map far address $\texttt{C[cs].base} + \reg{roff}$ to "
    r"I-LS address \reg{rils}. Software calls this after loading the code with \insn{tgetx}. With "
    r"\csr{xslot} = 0 the entry maps that one far address; with \csr{xslot} = $n$ it maps the $2^n$-byte "
    r"unit that starts there to the $2^n$-byte I-LS slot at \reg{rils}, and the far address must be a "
    r"multiple of $2^n$.",
    """cap = C[cs];
if not Live(cap) then Trap(capinv, cs); end
if not cap.X then Trap(perm, cs); end
if UInt(X[roff]) >= cap.len then Trap(bounds, X[roff]); end
if XSLOT != 0 and (cap.base + X[roff]) MOD (1 << XSLOT) != 0 then Trap(xalign, X[roff]); end
if X[rils] MOD 4 != 0 or UInt(X[rils]) >= ILS_SIZE then Trap(lsfault, X[rils]); end
XMAP[idx] = (valid: TRUE, space: cap.space, far: cap.base + X[roff], ils: X[rils]);""",
    [("illegal", r"$\field{idx} \geq \textit{NXMAP}$ (always when bit 25 is 1)", "instruction word"),
     ("capinv", r"\texttt{C[cs]} is not live", r"\texttt{cs}"),
     ("perm", r"\texttt{C[cs]} lacks \perm{X}", r"\texttt{cs}"),
     ("bounds", r"$\texttt{X[roff]} \geq \texttt{C[cs].len}$", r"\texttt{X[roff]}"),
     ("xalign", r"$\csr{xslot} = n \neq 0$ and the far address is not a multiple of $2^n$", r"\texttt{X[roff]}"),
     ("lsfault", r"\texttt{X[rils]} misaligned or $\geq$ \texttt{ILS\_SIZE}", r"\texttt{X[rils]}")],
    notes=r"Entries are not checked for duplicates; a lookup uses the lowest-numbered matching entry. The map "
          r"is per-core state and is available in user mode. $\textit{NXMAP}$, the number of entries, is a "
          r"property of the platform (4--16, 16 by default; the platform table's header says). The alignment "
          r"is checked against \csr{xslot} when the entry is made; a lookup ignores the bits of the entry's far "
          r"address below the current \csr{xslot}.",
    fmt="R", opname="XMAP", funct="funct<4> = 0")
ins("sys", "XUNMAP", "Overlay unmap",
    [(31, 26, b(OP["XMAP"], 6), "f"), (25, 25, "0", "f"), (24, 21, "idx", "v"), (20, 5, b(0, 16), "z"),
     (4, 4, "1", "f"), (3, 0, b(0, 4), "z")],
    ["xunmap idx"], r"Invalidates overlay-map entry \field{idx} (0 to $\textit{NXMAP}-1$).",
    "XMAP[idx].valid = FALSE;", [("illegal", r"$\field{idx} \geq \textit{NXMAP}$ (always when bit 25 is 1)", "instruction word")],
    notes=r"\insn{tgetx} also invalidates every entry whose I-LS slot it overwrites.",
    fmt="R", opname="XMAP", funct="funct<4> = 1")
ins("sys", "XCALL", "Overlay call",
    L_R(OP["XCALL"], rs1="roff", rs2=None, funct=[(10, 5, b(0, 6), "z"), (4, 4, "0", "f"), (3, 0, "cs", "v")]),
    ["xcall rd, cs, roff"],
    r"Calls the code at far address $\texttt{C[cs].base} + \reg{roff}$ if the overlay map says it is "
    r"resident: on a hit it jumps to the mapped I-LS address and writes a link to \reg{rd}. On a miss it "
    r"traps with cause \cause{xmiss}; the handler loads the code, maps it and returns with \insn{eret}, which "
    r"re-executes the \insn{xcall}. When \csr{xslot} is nonzero and the \insn{xcall} itself executes inside a "
    r"mapped slot, the link is a \term{far link}: the far address of the next instruction with bit~63 set, "
    r"which \insref{xret} resolves. The caller's unit may then be evicted while the callee runs.",
    """cap = C[cs];
if not Live(cap) then Trap(capinv, cs); end
if not cap.X then Trap(perm, cs); end
if UInt(X[roff]) >= cap.len then Trap(bounds, X[roff]); end
key = cap.base + X[roff];
n = XSLOT;  sl = 1 << n;                                   // n = 0: exact mapping
e = lowest entry with XMAP[e].valid and XMAP[e].space == cap.space
                      and key >> n == XMAP[e].far >> n;     // the slot holding the far address
if no such e then Trap(xmiss, key); end
link = PC + 4;
if n != 0 and a valid entry f has XMAP[f].ils <= PC < XMAP[f].ils + sl then        // lowest such f
    link = (1 << 63) OR ((XMAP[f].far AND NOT (sl - 1)) + (PC + 4 - XMAP[f].ils));  // far link
end
X[rd] = link;
NextPC = XMAP[e].ils + (key MOD sl);""",
    [("capinv", r"\texttt{C[cs]} is not live", r"\texttt{cs}"),
     ("perm", r"\texttt{C[cs]} lacks \perm{X}", r"\texttt{cs}"),
     ("bounds", r"$\texttt{X[roff]} \geq \texttt{C[cs].len}$", r"\texttt{X[roff]}"),
     ("xmiss", r"no valid overlay entry maps the far address", r"far address \texttt{base + X[roff]}")],
    notes=r"For \cause{xmiss}, \csr{tval} is the absolute far address, not the offset; the handler subtracts "
          r"\insn{cbase} to recover the offset (see the \texttt{overlay} example, \S\ref{sec:ex-overlay}). "
          r"Bits 10:5 of \field{funct} are ignored; bit~4 selects \insn{xret}.",
    fmt="R", opname="XCALL", funct="funct<4> = 0")
ins("sys", "XRET", "Overlay return",
    [(31, 26, b(OP["XCALL"], 6), "f"), (25, 21, b(0, 5), "z"), (20, 16, "rs1", "v"), (15, 5, b(0, 11), "z"),
     (4, 4, "1", "f"), (3, 0, b(0, 4), "z")],
    ["xret rs1"],
    r"Returns through a link left by \insn{xcall}. An ordinary link (bit~63 clear) is an I-LS address and "
    r"\insn{xret} jumps to it like \insn{jr}. A far link (bit~63 set) is looked up in the overlay map like an "
    r"\insn{xcall} target, in any space: if the unit holding the return address is resident, \insn{xret} "
    r"jumps to the corresponding I-LS address; if it has been evicted, it traps with \cause{xmiss} so that "
    r"the handler can bring it back, and \insn{eret} retries the return.",
    """a = X[rs1];
if a<63> == 0 then
    NextPC = a AND NOT 3;
else
    key = ZeroExtend(a<62:0>, 64);
    n = XSLOT;
    e = lowest entry with XMAP[e].valid and key >> n == XMAP[e].far >> n;
    if no such e then Trap(xmiss, a); end
    NextPC = XMAP[e].ils + (key MOD (1 << n));
end""",
    [("xmiss", r"a far link whose unit is not mapped", r"the link \texttt{X[rs1]}, bit~63 set")],
    notes=r"Code that may be called through \insn{xcall} from paged code returns with \insn{xret ra} instead of "
          r"\insn{ret}; with an ordinary link the two behave identically. A miss handler distinguishes a "
          r"return miss by bit~63 of \csr{tval}.",
    fmt="R", opname="XCALL", funct="funct<4> = 1")


# ------------------------------------------------------------------ chapter output
CHAPTERS = {
    "int": "Integer computation", "ls": "Local Store access", "ctl": "Control transfer",
    "xfer": "Transfers and far atomics", "cap": "Capability instructions",
    "sys": "System, software-cache and overlay instructions",
}


def no_exc(e):
    """The Exceptions text of an entry whose table is empty (LaTeX markup)."""
    return ("None. (An instruction fetch fault, \\cause{ifault}, can occur for any instruction.)"
            if e["mn"] == "ADD" else "None.")


def entry_tex(e):
    key = e["mn"].lower()
    out = []
    out.append("\\begin{instruction}{%s}{%s}{%s}" % (e["mn"], e["title"], key))
    out.append(e["desc"])
    out.append("\\insthead{Encoding}")
    out.append(encoding_tex(e["lay"]))
    out.append("\\insthead{Assembler syntax}")
    out.append("\\begin{syntax}")
    out += e["syntax"]
    out.append("\\end{syntax}")
    out.append("\\insthead{Operation}")
    out.append("\\begin{pseudo}")
    out.append(e["op"])
    out.append("\\end{pseudo}")
    out.append("\\insthead{Exceptions}")
    if e["exc"]:
        out.append("\\begin{exctable}")
        for (c, cond, tv) in e["exc"]:
            out.append("%s & %s & %s\\\\" % (c, cond, tv))
        out.append("\\end{exctable}")
    else:
        out.append(no_exc(e))
    if e["notes"]:
        out.append("\\insthead{Notes}")
        out.append(e["notes"])
    out.append("\\end{instruction}")
    return "\n".join(out) + "\n"


def outputs():
    """Every generated file, as {file name: LaTeX text}, in the order written.
    gen/genweb.py reads the same data (INSNS, OP) for the website."""
    files = {}
    for ch in CHAPTERS:
        lst = [e for e in INSNS if e["chapter"] == ch]
        t = "%% generated by gen/geninsns.py: do not edit\n"
        for e in lst:
            t += entry_tex(e) + "\n"
        files["gen-insns-%s.tex" % ch] = t
    # summary tables per chapter
    for ch in CHAPTERS:
        lst = [e for e in INSNS if e["chapter"] == ch]
        t = "%% generated\n\\begin{center}\\small\n\\begin{tabularx}{\\linewidth}{@{}>{\\ttfamily}l X l r@{}}\n\\toprule\n"
        t += "\\textrm{\\bfseries Mnemonic} & \\textbf{Operation} & \\textbf{Format} & \\textbf{Page}\\\\\\midrule\n"
        for e in lst:
            t += "\\insref{%s} & %s & %s & \\pageref{insn:%s}\\\\\n" % (e["mn"].lower(), e["title"], e["fmt"], e["mn"].lower())
        t += "\\bottomrule\n\\end{tabularx}\n\\end{center}\n"
        files["gen-summary-%s.tex" % ch] = t
    # alphabetical index
    t = "%% generated\n\\begin{longtable}{@{}>{\\ttfamily}l l l l r@{}}\n"
    t += "\\caption{Alphabetical index of instructions}\\label{tab:insindex}\\\\\n\\toprule\n"
    hdr = "\\textrm{\\bfseries Mnemonic} & \\textbf{Description} & \\textbf{Opcode} & \\textbf{Function} & \\textbf{Page}\\\\\\midrule\n"
    t += hdr + "\\endfirsthead\n\\toprule\n" + hdr + "\\endhead\n\\bottomrule\n\\endfoot\n"
    for e in sorted(INSNS, key=lambda e: e["mn"].lower()):
        t += "\\insref{%s} & %s & \\texttt{0x%02X} %s & %s & \\pageref{insn:%s}\\\\\n" % (
            e["mn"].lower(), e["title"], OP[e["opname"]], e["opname"], e["funct"], e["mn"].lower())
    t += "\\end{longtable}\n"
    files["gen-index.tex"] = t
    # opcode map: 8 x 8 grid of primary opcodes
    names = {v: k for (k, v) in OP.items()}
    t = "%% generated\n\\begin{table}[htbp]\\centering\\small\n"
    t += ("\\caption{Primary opcode map: \\field{op} = bits 31:26. Row gives bits 31:29, column bits 28:26. "
          "Empty cells are illegal.}\\label{tab:opmap}\n")
    t += "\\begin{tabular}{@{}c|*{8}{>{\\centering\\arraybackslash}p{4.2em}}@{}}\n\\toprule\n"
    t += " & " + " & ".join("\\texttt{%s}" % b(i, 3) for i in range(8)) + "\\\\\\midrule\n"
    for r in range(8):
        cells = []
        for c in range(8):
            v = r * 8 + c
            cells.append("\\texttt{\\footnotesize %s}" % names[v] if v in names else "")
        t += "\\texttt{%s} & " % b(r, 3) + " & ".join(cells) + "\\\\[2pt]\n"
    t += "\\bottomrule\n\\end{tabular}\n\\end{table}\n"
    files["gen-opmap.tex"] = t
    return files


def main():
    for name, text in outputs().items():
        with open(os.path.join(OUT, name), "w") as f:
            f.write(text)
    print("%d instructions" % len(INSNS))


if __name__ == "__main__":
    main()
