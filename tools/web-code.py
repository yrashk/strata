#!/usr/bin/env python3
"""web-code.py: the data behind the site's source browser (site/code/).

    python3 tools/web-code.py OUTDIR      (make web-code: OUTDIR = build/web-code)

Copies every Strata assembly and Forth source of the repository into
OUTDIR/src/<path> and writes OUTDIR/manifest.json: the files grouped by area
(path, lines, bytes, language, title and description from the file's header
comment, a "run in browser" link where the play page can run it) and the
keyword lists the highlighter uses. The keyword lists are read from the
assembler (asm/sasm.c: mnemonics by opcode, pseudo-instructions,
directives, CSR and register names) and from lang/forth/README.md (the
Strata words), so they never drift from the real tools. Only the standard
library is used; the sources themselves stay where they are.
"""
import glob
import json
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The areas of the tree, in order. A file goes to the first group whose
# patterns match it (globs relative to the repository root).
GROUPS = [
    ("Examples", ["examples/*.s", "examples/lib/*.s"]),
    ("Self-hosted assembler", ["os/progs/as.s"]),
    ("StrataOS kernel", ["os/kernel.s", "os/kunits/*.s"]),
    ("Servers & programs", ["os/servers/*.s", "os/progs/*.s", "os/ws/*.s"]),
    ("Libraries", ["os/lib/*.s", "os/lib/*/*.s"]),
    ("Firmware", ["firmware/*.s"]),
    ("Forth", ["lang/forth/forth.s", "lang/forth/bare/*.s", "lang/forth/core.fs",
               "lang/forth/demos/*.fs", "lang/forth/tests/*.fs"]),
    ("Conformance tests", ["conformance/tests/*.s", "conformance/tests/lib/*.s"]),
]

# What the play page (site/play/play.js, PRESETS and ?run=) can run.
RUN = {
    "examples/gfx.s": "gfx",
    "examples/hello.s": "hello",
    "examples/mandel.s": "mandel",
    "os/kernel.s": "os",
    "firmware/bootrom.s": "os",
    "lang/forth/forth.s": "forth",
    "lang/forth/core.fs": "forth",
}


def read(path):
    with open(os.path.join(ROOT, path), encoding="utf-8", errors="replace") as f:
        return f.read()


# ---------------------------------------------------------------- keywords
def c_block(src, start):
    """The text of the C initializer that starts at regex `start`."""
    m = re.search(start, src)
    if not m:
        sys.exit(f"web-code.py: cannot find {start!r} in asm/sasm.c")
    end = src.index("};", m.end())
    return src[m.end():end]


def asm_keywords():
    src = read("asm/sasm.c")
    cat_of = [
        (r"OP_(ALU|ADDI|SLTI|SLTIU|ANDI|ORI|XORI|SLLI|SRLI|SRAI|LUI)$", "alu"),
        (r"OP_(LD|LW|LWU|LH|LHU|LB|LBU|SD|SW|SH|SB|LTAG|LINST)$", "mem"),
        (r"OP_(B\w+|JAL|JALR)$", "branch"),
        (r"OP_(XFER|TWAIT|TPOLL|TANY|TAMO)$", "xfer"),
        (r"OP_(CAP|CAP2)$", "cap"),
        (r"OP_(CSRR|CSRW|SYS)$", "sys"),
        (r"OP_(XMAP|XCALL)$", "page"),
    ]
    mn = {}
    for name, op in re.findall(r'\{"([a-z.]+)",\s*F_\w+(?:\s*/\*.*?\*/)?,\s*(OP_\w+)',
                               c_block(src, r"static const Insn insns\[\] = \{")):
        cat = next((c for rx, c in cat_of if re.match(rx, op)), "alu")
        mn.setdefault(cat, []).append(name)
    at = src.index("static int pseudo(")
    pseudo_src = src[at:src.index("/* ---", at)]
    for name in re.findall(r'strcmp\(m, "([a-z.]+)"\)', pseudo_src) + \
            re.findall(r'\{"([a-z]+)", OP_B', pseudo_src):
        cat = ("branch" if name in ("j", "call", "ret", "jr") or name.startswith("b")
               else "xfer" if name == "tfence" else "pseudo")
        mn.setdefault(cat, []).append(name)
    dsrc = src[src.index("static int directive("):]
    dirs = set(re.findall(r'strcmp\(d, "(\.[a-z]+)"\)', dsrc))
    dirs |= set(re.findall(r'\{"(\.[a-z]+)", SK_', src))
    dirs |= set(re.findall(r'strncmp\(p, "(\.[a-z]+)"', src))
    csrs = re.findall(r'"([a-z0-9]+)"', c_block(src, r"static const char \*csr_names\[\] = \{"))
    xregs = re.findall(r'"([a-z0-9]+)"', c_block(src, r"static const char \*xreg_names\[32\] = \{"))
    if "fp" not in xregs and 'strcmp(s, "fp")' in src:
        xregs.append("fp")
    if len(mn.get("alu", [])) < 10 or len(csrs) < 10 or len(xregs) < 32:
        sys.exit("web-code.py: the tables in asm/sasm.c have changed shape; update the parser")
    return {
        "mnemonics": {k: sorted(set(v)) for k, v in mn.items()},
        "directives": sorted(dirs),
        "csrs": [c for c in csrs if not c.startswith("reserved")],
        "xregs": xregs,
    }


def forth_keywords():
    """The Strata words: everything in backticks in the README's 'Word list
    highlights' table, without the stack comments."""
    md = read("lang/forth/README.md")
    m = re.search(r"^## Word list highlights\n(.*?)^## ", md, re.S | re.M)
    words = set()
    rows = "\n".join(l for l in m.group(1).splitlines() if l.startswith("|")) if m else ""
    if rows:
        for code in re.findall(r"`([^`]+)`", rows):
            code = re.sub(r"\([^)]*\)", " ", code)
            for w in code.split():
                if w not in ("...", "--") and not w.startswith("%"):
                    words.add(w.lower())
    # far memory, cores and capabilities words named in the README's prose
    for w in re.findall(r"`([a-z0-9@!/+.-]+)`", md):
        if w in ("far@", "far!", "spawn", "await", "give", "take", "tag", "cap"):
            words.add(w)
    return {"strata": sorted(words)}


# ---------------------------------------------------------------- headers
RULE = re.compile(r"^[=\-~*#]{6,}\s*$")


def header(text, lang):
    """(title, description) from the comment block at the top of a file:
    the "name.s: title" line, then the first prose paragraph (usage blocks,
    indented examples and "Run:" lines are skipped; of a bullet list, the
    first bullet is kept)."""
    lines = []
    for raw in text.splitlines():
        s = raw.strip()
        m = re.match(r"^\\ ?(.*)$" if lang == "forth" else r"^(?:;+|#|//) ?(.*)$", s)
        if m:
            lines.append(m.group(1).rstrip())
            continue
        if s == "" and lines:
            lines.append("")
            continue
        if s == "":
            continue
        break
    lines = [l for l in lines if not RULE.match(l.strip())]
    while lines and not lines[0].strip():
        lines.pop(0)
    title = ""
    m = re.match(r"^[\w./-]+\.(?:s|fs):\s*(.*)$", lines[0]) if lines else None
    if m:
        t = [m.group(1)]
        i = 1
        while i < len(lines) and re.match(r"^[a-z(]", lines[i]):
            t.append(lines[i]); i += 1
        title = " ".join(t).strip()
        lines = lines[i:]
    paras, cur = [], []
    for l in lines + [""]:
        if not l.strip() or l.startswith("----"):
            if cur: paras.append(cur)
            cur = []
        else:
            cur.append(l)
    desc = ""
    bullet = re.compile(r"^\s*[*-] ")
    for para in paras:
        para = [l for l in para if not l.startswith("Run")]
        if not para:
            continue
        if len(para) > 1 and len(para[0]) < 80 and not re.search(r"[.;,]$", para[0]) \
                and bullet.match(para[1]):
            para = para[1:]           # a heading over a bullet list: its first bullet
        if bullet.match(para[0]):
            ind = len(para[0]) - len(para[0].lstrip())
            out = [bullet.sub("", para[0])]
            for l in para[1:]:
                if bullet.match(l) or len(l) - len(l.lstrip()) <= ind: break
                out.append(l)
        elif para[0][:1].isspace():
            continue                  # usage lines, examples
        else:
            out = []
            for l in para:
                if l[:1].isspace(): break  # an indented block ends the prose
                out.append(l)
        text_ = re.sub(r"\s+", " ", " ".join(out)).strip()
        if text_.endswith(":"):       # "... like this:" before a dropped block
            cut = text_.rfind(". ")
            text_ = text_[:cut + 1] if cut > 0 else ""
        if len(text_) < 25:
            continue
        desc = text_
        break
    if len(desc) > 700:
        cut = desc.rfind(". ", 0, 700)
        desc = desc[:cut + 1] if cut > 200 else desc[:700].rstrip() + "…"
    return title, desc


# ---------------------------------------------------------------- main
def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = sys.argv[1]
    shutil.rmtree(os.path.join(out, "src"), ignore_errors=True)
    seen = set()
    groups = []
    total = 0
    for gname, pats in GROUPS:
        files = []
        for pat in pats:
            for p in sorted(glob.glob(os.path.join(ROOT, pat))):
                rel = os.path.relpath(p, ROOT)
                if rel in seen or not os.path.isfile(p):
                    continue
                seen.add(rel)
                lang = "forth" if rel.endswith(".fs") else "asm"
                text = read(rel)
                title, desc = header(text, lang)
                n = text.count("\n") + (0 if text.endswith("\n") or not text else 1)
                total += n
                entry = {"path": rel, "lang": lang, "lines": n,
                         "bytes": len(text.encode("utf-8")), "title": title, "desc": desc}
                if rel in RUN:
                    entry["run"] = "?run=" + RUN[rel]
                elif rel.startswith("lang/forth/demos/") and rel.endswith(".fs"):
                    entry["run"] = "?run=forth&demo=" + os.path.basename(rel)[:-3]
                dst = os.path.join(out, "src", rel)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copyfile(p, dst)
                files.append(entry)
        if files:
            groups.append({"name": gname, "files": files})
    manifest = {
        "repo": "https://github.com/yrashk/strata",
        "branch": "main",
        "files": len(seen),
        "lines": total,
        "groups": groups,
        "syntax": {"asm": asm_keywords(), "forth": forth_keywords()},
    }
    with open(os.path.join(out, "manifest.json"), "w") as f:
        json.dump(manifest, f, separators=(",", ":"))
    print(f"web-code: {len(seen)} files, {total} lines -> {out}/")


if __name__ == "__main__":
    main()
