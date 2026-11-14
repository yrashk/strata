#!/usr/bin/env python3
"""vi-syntax.py: the keyword tables of vi's syntax highlighting.

    python3 tools/vi-syntax.py OUT.s      (make: OUT = build/vi-syntax.s)
    python3 tools/vi-syntax.py OUT.fs     (make: OUT = build/forth-os/vi-syntax.fs)

An OUT ending in .fs is the same tables for lang/forth/vi.fs, the Forth port,
as Forth source: lines `CLASS kw word word ...` (words of one class, in the
table's order) between `kw-begin` and `N kw-end` (N: 1 assembly, 2 Forth),
which vi.fs interprets once to build its tables in far memory. The class
numbers are vi.s's H_* constants, read from os/progs/vi.s.

Writes a Strata assembly include with three tables that os/progs/vi.s looks
words up in: Strata assembly (mnemonics by category, CSR names, x registers,
c registers and transfer tags), Strata Forth (the defining words, the
control words and the Strata words) and C (keywords and type names). The
lists come from the same places as the site's highlighter and the compiler,
so the editor and the site never disagree and neither drifts from the real
tools:
  - asm/sasm.c, through tools/web-code.py's asm_keywords() (mnemonics by
    opcode, pseudo-instructions, CSR and register names);
  - lang/forth/README.md, through tools/web-code.py's forth_keywords() (the
    Strata words);
  - site/hl.js (F_DEF, F_DW, F_NAMED, F_CTL: the standard Forth words the
    site colours, and which of them take a name or a character after them);
  - lang/cc/cc.c's kw_names (the keywords cc knows; C99's _Complex and
    _Imaginary, which it does not, are added) and the typedef names of the
    headers in lang/cc/lib/include (size_t, uint8_t, FILE ...; bool).
The C table is only in the .s output (the Forth port colours no C).

Table format (both tables): an index of 96 halfwords, one per first byte
0x21..0x80 (the offset of the first entry starting with that byte, from the
end of the index, 192 bytes; the last one is the end of the table), then the entries sorted
by first byte: {u8 length, u8 class, bytes}. Words are lower case in the
assembly and Forth tables (vi folds case when it looks a word up there) and
as they are in the C one (looked up as they are). The class names (H_*) are constants that
vi.s defines before it includes this file; a Forth class may carry
H_NAME (the next word is a name being defined), H_CHAR (the next word is a
character) or both (H_LOCALS: "{" opens a list of locals).
"""
import importlib.util
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

spec = importlib.util.spec_from_file_location("web_code", os.path.join(ROOT, "tools", "web-code.py"))
web_code = importlib.util.module_from_spec(spec)
spec.loader.exec_module(web_code)

ASM_CLASS = {"alu": "H_ALU", "mem": "H_MEM", "branch": "H_BRANCH", "xfer": "H_XFER",
             "cap": "H_CAP", "sys": "H_SYS", "page": "H_PAGE", "pseudo": "H_PSEUDO"}


def hl_set(src, name):
    """The words of `const NAME = new Set(("..." + "...").split(" "))` in site/hl.js."""
    m = re.search(r"const " + name + r" = new Set\((.*?)\.split\(\" \"\)\)", src, re.S)
    if not m:
        sys.exit(f"vi-syntax.py: cannot find {name} in site/hl.js")
    return " ".join(re.findall(r'"([^"]*)"', m.group(1))).split()


def asm_table():
    k = web_code.asm_keywords()
    words = {}
    for cat, names in k["mnemonics"].items():
        for w in names:
            words.setdefault(w, ASM_CLASS[cat])
    for w in k["csrs"]:
        words.setdefault(w, "H_CSR")
    for w in k["xregs"]:
        words.setdefault(w, "H_XREG")
    # c0..c15 and tg0..tg15: the pattern site/hl.js colours as c registers
    for i in range(16):
        words.setdefault(f"c{i}", "H_CREG")
        words.setdefault(f"tg{i}", "H_CREG")
    return words


def forth_table():
    hl = open(os.path.join(ROOT, "site", "hl.js"), encoding="utf-8").read()
    f_def, f_dw = hl_set(hl, "F_DEF"), hl_set(hl, "F_DW")
    f_named, f_ctl = set(hl_set(hl, "F_NAMED")), hl_set(hl, "F_CTL")
    words = {}
    # the order of site/hl.js's tests: definitions, "{", defining words, control, Strata
    for w in f_def:
        words.setdefault(w, "H_FDEF|H_NAME" if w == ":" else "H_FDEF")
    words.setdefault("{", "H_FLOC|H_LOCALS")
    for w in f_dw:
        flag = "|H_NAME" if w in f_named else "|H_CHAR" if w in ("[char]", "char") else ""
        words.setdefault(w, "H_FDW" + flag)
    for w in f_ctl:
        words.setdefault(w, "H_FCTL")
    for w in web_code.forth_keywords()["strata"]:
        words.setdefault(w, "H_FST")
    return words


# C's statements (the rest of cc.c's keywords are declaration words or types)
C_CTL = "if else for while do switch case default break continue goto return".split()
C_TYPES = "void char short int long float double signed unsigned _Bool _Complex _Imaginary".split()


def c_table():
    cc = open(os.path.join(ROOT, "lang", "cc", "cc.c"), encoding="utf-8").read()
    m = re.search(r"char \*kw_names\[\] = \{(.*?)\};", cc, re.S)
    if not m:
        sys.exit("vi-syntax.py: cannot find kw_names in lang/cc/cc.c")
    kws = re.findall(r'"([^"]*)"', m.group(1)) + ["_Complex", "_Imaginary"]
    words = {}
    for w in kws:
        words[w] = "H_CCTL" if w in C_CTL else "H_CTYPE" if w in C_TYPES else "H_CKW"
    inc = os.path.join(ROOT, "lang", "cc", "lib", "include")
    for name in sorted(os.listdir(inc)):
        h = open(os.path.join(inc, name), encoding="utf-8").read()
        for t in re.findall(r"^typedef\b[^;]*?\b(\w+)\s*;", h, re.M):
            words.setdefault(t, "H_CTYPE")
        for t in re.findall(r"^#define\s+(\w+)\s+_Bool\s*$", h, re.M):
            words.setdefault(t, "H_CTYPE")
    return words


def emit(out, label, words, what, fold=True):
    ents = sorted((w.lower() if fold else w, c) for w, c in words.items()
                  if w and 0x21 <= ord(w[0]) < 0x7f and len(w) < 256)
    out.append("        .align 2                        ; (the index is halfwords)")
    out.append(f"{label}:".ljust(40) + f"; {what}: {len(ents)} words")
    off, offs, i = 0, [], 0
    for b in range(0x21, 0x81):
        while i < len(ents) and ord(ents[i][0][0]) < b:
            off += 2 + len(ents[i][0])
            i += 1
        offs.append(off)
    for j in range(0, len(offs), 8):
        row = offs[j:j + 8]
        lo = 0x21 + j
        out.append(f"        .half {', '.join(str(o) for o in row)}"
                   .ljust(40) + f"; index: first bytes 0x{lo:02x}..0x{lo + len(row) - 1:02x}")
    for w, c in ents:
        text = w.replace("\\", "\\\\").replace('"', '\\"')
        out.append(f"        .byte {len(w)}, {c}".ljust(40) + f"; {w}: length, class")
        out.append(f'        .ascii "{text}"'.ljust(40) + "; ... its letters")


def classes():
    """vi.s's H_* constants: name -> number."""
    src = open(os.path.join(ROOT, "os", "progs", "vi.s"), encoding="utf-8").read()
    return {m.group(1): int(m.group(2), 0)
            for m in re.finditer(r"^(H_[A-Z]+)\s*=\s*(0x[0-9A-Fa-f]+|\d+)", src, re.M)}


def emit_forth(out, words, n, what, h):
    ents = sorted((w.lower(), c) for w, c in words.items()
                  if w and 0x21 <= ord(w[0]) < 0x7f and len(w) < 256)
    out.append(f"\\ {what}: {len(ents)} words")
    out.append("kw-begin")
    line, cls = [], None
    for w, c in ents:
        v = 0
        for part in c.split("|"):
            v |= h[part]
        if line and (v != cls or sum(len(x) + 1 for x in line) + len(w) > 150):
            out.append(f"{cls} kw " + " ".join(line))
            line = []
        cls = v
        line.append(w)
    if line:
        out.append(f"{cls} kw " + " ".join(line))
    out.append(f"{n} kw-end")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    if sys.argv[1].endswith(".fs"):
        h = classes()
        out = ["\\ vi-syntax.fs: vi.fs's keyword tables, generated by tools/vi-syntax.py from asm/sasm.c,",
               "\\ lang/forth/README.md and site/hl.js (classes: os/progs/vi.s's H_*). Do not edit."]
        emit_forth(out, asm_table(), 1, "Strata assembly", h)
        emit_forth(out, forth_table(), 2, "Strata Forth", h)
        with open(sys.argv[1], "w") as f:
            f.write("\n".join(out) + "\n")
        return
    out = ["; vi-syntax.s: vi's keyword tables, generated by tools/vi-syntax.py from",
           "; asm/sasm.c, lang/forth/README.md and site/hl.js. Do not edit.",
           "",
           "        .data                           ; D-LS: looked up by kw_find"]
    emit(out, "kw_asm", asm_table(), "Strata assembly")
    emit(out, "kw_fth", forth_table(), "Strata Forth")
    emit(out, "kw_c", c_table(), "C", fold=False)
    out.append("        .text                           ; back to code")
    with open(sys.argv[1], "w") as f:
        f.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
