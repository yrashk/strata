# mkasm.py SASM SASM.C OUT: the instruction table of cc's asm("...") statements,
# a member of cc.lib (asm.tab), made from the assembler itself.
#
# The mnemonics and their operand kinds are read from the table in asm/sasm.c;
# the instruction words and where each operand goes in them are found by
# assembling every instruction with sasm: once with all operands zero (the
# base word), and once per operand with that operand 1 (the bit that changes
# is its place). So the compiler's table cannot disagree with the assembler.
#
# A record is 32 bytes: name[12], u32 base word, then per operand (5 at most)
# a kind and a shift:
#   x c g   an integer, capability or transfer-tag register
#   i       a 16-bit number      k   a small number (6 bits)
#   m       a memory operand: off(reg), or {a C variable}
#   b j     a label: a branch's 16-bit, a jal's 21-bit distance
#   M       the rest of the line is transfer tags: their mask
import re, struct, subprocess, sys, tempfile, os
sasm, src, out = sys.argv[1:4]
KINDS = {
    "F_R": "xxx", "F_I": "xxi", "F_IU": "xxi", "F_SH": "xxk", "F_LUI": "xi", "F_LD": "xm", "F_ST": "xm",
    "F_B": "xxb", "F_JAL": "xj", "F_JALR": "xxi", "F_XF": "gxcxx", "F_TWAIT": "M", "F_TPOLL": "xM",
    "F_AMO": "xcxx", "F_C_CDCS": "cc", "F_C_CDCSRX": "ccx", "F_C_RDCS": "xc", "F_C_CSRX": "cx", "F_C_CD": "c",
    "F_C_CSSLOT": "ck", "F_C_CDSLOT": "ck", "F_CSRR": "xi", "F_CSRW": "ix", "F_SYS": "", "F_LTAG": "xx",
    "F_LINST": "x", "F_XMAP": "kxcx", "F_XUNMAP": "k", "F_XCALL": "xcx", "F_XRET": "x",
    "F_C2_CDCS": "cc", "F_C2_SEND": "cc", "F_C2_MKEP": "cx", "F_C2_CSRX": "cx",
}
text = open(src).read()
tab = text[text.index("static const Insn insns[]"):]
tab = tab[:tab.index("};")]
insns = [(n, KINDS[f]) for n, f in re.findall(r'\{"([\w.]+)",\s*(F_\w+)', tab)]
insns = [(n, "x" if n == "cpoll" else k) for n, k in insns]
insns += [("nop", ""), ("mv", "xx"), ("seqz", "xx"), ("snez", "xx"), ("neg", "xx"), ("j", "j"), ("jr", "x"),
          ("ret", ""), ("tfence", ""), ("beqz", "xb"), ("bnez", "xb"), ("bltz", "xb"), ("bgez", "xb"),
          ("bgtz", "xb"), ("blez", "xb"), ("bgt", "xxb"), ("ble", "xxb"), ("bgtu", "xxb"), ("bleu", "xxb")]
ZERO = {"x": "x0", "c": "c0", "g": "tg0", "i": "0", "k": "0", "m": "0(x0)", "b": "L", "j": "L", "M": "tg0"}
ONE = {"x": "x1", "c": "c1", "g": "tg1", "i": "1", "k": "1"}

def word(name, ops):
    d = tempfile.mkdtemp()
    open(d + "/a.s", "w").write("L: %s %s\n" % (name, ", ".join(ops)))
    subprocess.run([sasm, "-o", d + "/a.stx", d + "/a.s"], check=True, stdout=subprocess.DEVNULL)
    w = struct.unpack_from("<I", open(d + "/a.stx", "rb").read(), 24)[0]
    if "tg0" in ops[-1:]: w &= ~1               # (the sample tag of a tag list)
    os.remove(d + "/a.s"); os.remove(d + "/a.stx"); os.rmdir(d)
    return w

blob = b""
for name, kinds in insns:
    zero = [ZERO[k] for k in kinds]
    base = word(name, zero)
    ops = b""
    for i, k in enumerate(kinds):
        sh = 0
        if k in ONE:
            diff = word(name, zero[:i] + [ONE[k]] + zero[i + 1:]) ^ base
            assert diff and diff & (diff - 1) == 0, (name, i, hex(diff))
            sh = diff.bit_length() - 1
        ops += bytes([ord(k), sh])
    assert len(name) < 12 and len(kinds) <= 5, name
    blob += name.encode().ljust(12, b"\0") + struct.pack("<I", base) + ops.ljust(16, b"\0")
open(out, "wb").write(blob)
