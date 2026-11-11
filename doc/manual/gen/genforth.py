#!/usr/bin/env python3
"""Generates the website's Strata Forth section: forth/index.html.

    python3 doc/manual/gen/genforth.py OUTDIR    (also run by genweb.py, so by make web-docs)

The word reference is read from the Forth sources themselves, never copied:

  * the kernel's primitives from lang/forth/forth.s: the word table at
    `ktable` (the same table build_dict turns into the dictionary at start-up:
    xt label, inline size, flags, fold kind, name) gives every name; the
    routine at the xt label is the source, and the stack comment and
    description come from the routine's comments (`; NAME ( ... ): what`
    above the label or on it);
  * the words defined in Forth from core.fs, tools.fs, see.fs, os/os.fs and
    bare/start.fs (the files the Makefile embeds): colon definitions and the
    words that `constant`, `value`, `variable`, `2variable`, `create`,
    `defer` and `buffer:` define at top level, with their `( ... )` stack
    comments and `\\` comments. Words between `(mark)` and `(release)` are
    forgotten at start-up and left out;
  * what is loaded on demand under StrataOS from the tool table `pl_tools`
    in lang/forth/os/config.s;
  * the examples behind the "Try" buttons from lang/forth/tests/test.fs: a
    test line that passes in tests/test.out and uses the word, from its
    start (or the shortest stretch that stands alone, or with the line
    before it when it needs that), extended until it prints something.
    Words the test does not use have an example in EXAMPLES below, or show
    their machine code with `see`.

Written here, not read from the sources: the grouping (GROUPS, BY_NAME,
SECTION_GROUP), EXAMPLES, and the few one-line glosses and standard stack
effects of primitives whose comment names them without one (STD_DESC,
STD_EFFECT). The prose in front of the reference is doc/manual/web/forth.html.

The page has a playground: the real build/forth.stx in the WebAssembly
emulator (site/forth/forth.js, which runs site/play/worker.js and the play
page's strata-emu.wasm, images/ and demos/; the panel is
doc/manual/web/forth-play.html).

    python3 doc/manual/gen/genforth.py --check   runs every example on
                                                 build/strata-emu + build/forth.stx
"""
import html
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
FORTH = "lang/forth"
WEB = os.path.join(HERE, "..", "web")

esc = lambda s: html.escape(s, quote=True)  # noqa: E731


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


# ---------------------------------------------------------------- anchors
SPECIAL = {"!": "store", "@": "fetch", '"': "quote", "+": "plus", "-": "minus", "*": "star", "/": "slash",
           ".": "dot", ",": "comma", ":": "colon", ";": "semi", "<": "lt", ">": "gt", "=": "eq", "?": "q",
           "'": "tick", "[": "lb", "]": "rb", "(": "lp", ")": "rp", "{": "lc", "}": "rc", "\\": "bs",
           "#": "hash", "$": "dollar", "%": "pct", "&": "amp", "~": "tilde", "^": "caret", "|": "bar",
           "_": "us"}


def word_id(name):
    """w-dup, w-plus-store (+!), w-dot-quote (."), w-2-gt-r (2>r)."""
    parts = re.findall(r"[a-z0-9]+|.", name.lower())
    return "w-" + "-".join(p if re.match(r"[a-z0-9]", p) else SPECIAL.get(p, "x%02x" % ord(p)) for p in parts)


# ---------------------------------------------------------------- the kernel (forth.s)
FLAG_BITS = {"F_IMM": "immediate", "F_INL": "inline"}
FOLD = {"FD_ADD", "FD_SUB", "FD_AND", "FD_OR", "FD_XOR", "FD_SHL", "FD_SHR", "FD_SAR", "FD_LD", "FD_ST",
        "FD_LDB", "FD_STB"}
RE_LABEL = re.compile(r"^([A-Za-z_][\w]*):")


def comment_of(line):
    """The text after the first ';' that is not inside a string or a character."""
    q = None
    for i, c in enumerate(line):
        if q:
            if c == "\\":
                continue
            if c == q:
                q = None
        elif c in "\"'":
            # a character literal like ')' or a string
            q = c
        elif c == ";":
            return line[i + 1:].strip()
    return None


def kernel_words():
    path = FORTH + "/forth.s"
    src = read(path).split("\n")
    kt = next(i for i, l in enumerate(src) if l.startswith("ktable:"))
    labels = {}
    for i, l in enumerate(src):
        m = RE_LABEL.match(l)
        if m:
            labels[m.group(1)] = i
    entries, i = [], kt + 1
    while True:
        m = re.match(r"\s*\.half\s+(\w+)", src[i])
        if not m or m.group(1) == "0":
            break
        fl = re.match(r"\s*\.byte\s+([\w|]+),\s*(\w+)", src[i + 1])
        nm = re.match(r'\s*\.asciz\s+"((?:[^"\\]|\\.)*)"', src[i + 2])
        name = nm.group(1).replace("\\\\", "\\")
        flags = [FLAG_BITS[f] for f in fl.group(1).split("|") if f in FLAG_BITS]
        entries.append({"label": m.group(1), "name": name, "flags": flags, "fold": fl.group(2) in FOLD,
                        "table_line": i + 1})
        i += 3
    xt_labels = {e["label"] for e in entries}

    def is_banner(l):
        return re.match(r"^;\s*(?:-{5,}|={5,})", l) is not None

    def routine(start, inline):
        """[start, end] (0-based, inclusive) of the routine at label line start."""
        j = start + 1
        while j < len(src):
            l = src[j]
            if inline and re.match(r"^\w+_e:", l):
                return j
            if not l.strip() or l.startswith(";") or re.match(r"^\s*\.(align|org|data|text|far)\b", l):
                break
            m = RE_LABEL.match(l)
            if m and m.group(1) in xt_labels:
                break
            j += 1
        return j - 1

    for e in entries:
        lab = labels[e["label"]]
        inline = e["label"] + "_e" in labels
        # the comment block right above the label (not a banner, not across a blank line)
        k = lab
        while k > 0 and src[k - 1].startswith(";") and not is_banner(src[k - 1]):
            k -= 1
        block = [src[j][2:] if src[j].startswith("; ") else src[j][1:] for j in range(k, lab)]
        end = routine(lab, inline)
        ranges = [(k if block else lab, end)]
        # constant/value, slit,/dotq,, ./u. share code: follow a jump to X_common
        last = src[end].split(";")[0].split()
        if len(last) == 2 and last[0] == "j" and last[1].endswith("_common") and last[1] in labels:
            s = labels[last[1]]
            ranges.append((s, routine(s, False)))
        e["file"] = path
        e["ranges"] = ranges
        e["lines"] = src
        e["kind"] = "primitive"
        e["inline_body"] = inline
        e["doc"] = kernel_doc(e["name"], block, comment_of(src[lab]) or "", inline)
        if not e["doc"][0] and not e["doc"][1]:
            # documented together with another word: `SLIT, ( addr u -- ) and DOTQ, ...`
            for j, l in enumerate(src):
                if l.startswith(";") and re.search(r"(?:^|\s)" + re.escape(e["name"].upper()) + r"\s+\(", l):
                    k = j
                    while k > 0 and src[k - 1].startswith(";") and not is_banner(src[k - 1]):
                        k -= 1
                    n = j
                    while n + 1 < len(src) and src[n + 1].startswith(";"):
                        n += 1
                    blk = [x[2:] if x.startswith("; ") else x[1:] for x in src[k:n + 1]]
                    e["doc"] = kernel_doc(e["name"], blk, "", inline)
                    break
        if not e["doc"][0] and e["name"] in STD_EFFECT:
            e["doc"] = (STD_EFFECT[e["name"]],) + e["doc"][1:]
    return entries


# The standard (Forth 2012) stack effect of the few primitives whose comment
# in forth.s names the word but not its effect.
STD_EFFECT = {"1+": "( n -- n+1 )", "1-": "( n -- n-1 )", "2*": "( n -- 2n )", "2/": "( n -- n/2 )",
              "cell+": "( addr -- addr+8 )", "unloop": "( -- ) ( R: loop -- )", "(does>)": "( -- )"}


def doc_text(block):
    """A comment block as prose: up to the first indented line (an example)."""
    out = []
    for raw in block:
        if raw.startswith("  "):
            break
        out.append(raw.strip())
    return " ".join(out)


# Inline primitives comment their first instruction on the label line
# ("DUP ( x -- x x ): room"); such a gloss is not a description.
RE_GLOSS = re.compile(r"^(?:\w+ = |room$|copy$|\.\.\.|-x )|\.\.\.$")


def kernel_doc(name, block, labcomment, inline):
    """(stack effect, description) from `NAME ( effect ): what` (or `NAME: what`)
    in the comment block above the routine or on its label line."""
    up = re.escape(name.upper())
    pat = re.compile(r"(?:^|(?<=[\s,]))" + up + r"(?:\s+and\s+\S+)?\s+(\()")
    plain = re.compile(r"(?:^|(?<=\s))" + up + r":\s+(.*)")
    for text, from_block in ((doc_text(block), True), (labcomment, False)):
        m = pat.search(text)
        if not m:
            m = plain.search(text)
            if m:
                return "", m.group(1).strip(), from_block
            continue
        a = m.start(1)
        b = text.find(")", a + 1)
        if b < 0:
            continue
        eff = text[a:b + 1]
        rest = text[b + 1:].strip()
        desc = ""
        if rest[:1] in (":", ","):
            desc = rest[1:].strip()
        elif rest.startswith("(") and rest.endswith(")"):  # "(immediate)": a flag the page shows anyway
            desc = ""
        if inline and not from_block and RE_GLOSS.search(desc):
            desc = ""
        if desc.startswith("share"):          # "CONSTANT ( .. ) and VALUE ( .. ) share this"
            desc = ""
        return eff, desc, from_block
    return "", "", False


# ---------------------------------------------------------------- the words written in Forth
DEFINERS = {"constant": "constant", "value": "value", "variable": "variable", "2variable": "variable",
            "create": "created", "defer": "deferred", "buffer:": "buffer"}
DEF_EFFECT = {"constant": "( -- x )", "value": "( -- x )", "variable": "( -- addr )", "2variable": "( -- addr )",
              "create": "( -- addr )", "buffer:": "( -- addr )"}
PARSE_STR = {'s"': '"', '."': '"', 'abort"': '"', 'c"': '"', ".(": ")"}
PARSE_ONE = {"'", "[']", "postpone", "[char]", "char", "to", "is", "see", "action-of", "[defined]"}


def tokens(text):
    """Forth tokens of a file: (kind, text, line) with kind 'w' word, 'n' the
    name a defining word defines, 'a' the argument of a parsing word, 's' a
    string, 'p' a ( comment ), '\\\\' a line comment."""
    lines = text.split("\n")
    out = []
    want_arg = False
    for ln, s in enumerate(lines):
        p = 0
        while True:
            m = re.compile(r"\S+").search(s, p)
            if not m:
                break
            t, p = m.group(0), m.end()
            tl = t.lower()
            if want_arg == "name" and t == ";":   # `create ;` inside a definition
                want_arg = False
            if want_arg:
                out.append(("n" if want_arg == "name" else "a", t, ln))
                want_arg = False
                continue
            if t == "\\":
                out.append(("\\", s[m.end():].strip(), ln))
                break
            if t == "(":
                e = s.find(")", p)
                if e < 0:
                    out.append(("p", s[m.start():].strip(), ln))
                    break
                out.append(("p", s[m.start():e + 1], ln))
                p = e + 1
                continue
            if tl in PARSE_STR:
                e = s.find(PARSE_STR[tl], p + 1)
                e = len(s) if e < 0 else e + 1
                out.append(("w", t, ln))
                out.append(("s", s[p:e], ln))
                p = e
                continue
            out.append(("w", t, ln))
            if tl == ":" or tl in DEFINERS:
                want_arg = "name"             # the word being defined: never parsed itself
            elif tl in PARSE_ONE:
                want_arg = "arg"
    return out, lines


def forth_words(path, origin):
    text = read(path)
    toks, lines = tokens(text)
    words = []
    i, released = 0, False
    banner = re.compile(r"^\\\s*(?:-{3,}|={3,})")

    def line_comment(ln):
        return next((x[1] for x in toks if x[0] == "\\" and x[2] == ln), "")

    def block_above(ln, name):
        """The \\ lines right above a definition: its description, unless they
        are a section's introduction (right under a banner) about something else."""
        out, k = [], ln - 1
        while k >= 0 and lines[k].startswith("\\") and not banner.match(lines[k]):
            out.insert(0, lines[k][1:].strip())
            k -= 1
        if not out or (k >= 0 and banner.match(lines[k]) and not out[0].startswith(name + " ")):
            return ""
        return " ".join(out)

    while i < len(toks):
        kind, t, ln = toks[i]
        tl = t.lower()
        if kind == "w" and tl == "(mark)":
            released = True
        elif kind == "w" and tl == "(release)":
            released = False
        if kind == "w" and tl in (":", ":noname"):
            named = tl == ":" and i + 1 < len(toks) and toks[i + 1][0] == "n"
            name = toks[i + 1][1] if named else None
            j = i + (2 if named else 1)
            eff = ""
            if named and j < len(toks) and toks[j][0] == "p" and toks[j][2] == ln:
                eff = toks[j][1]
            while j < len(toks) and not (toks[j][0] == "w" and toks[j][1] == ";"):
                j += 1
            end = toks[j][2]
            flags = []
            if j + 1 < len(toks) and toks[j + 1][0] == "w" and toks[j + 1][1].lower() == "immediate" \
                    and toks[j + 1][2] == end:
                flags.append("immediate")
            if named and not released:
                desc = line_comment(ln) or line_comment(end) or block_above(ln, name.lower())
                words.append({"name": name.lower(), "kind": "colon", "flags": flags, "file": path,
                              "ranges": [(ln, end)], "lines": lines, "doc": (eff, desc, False),
                              "origin": origin})
            i = j + 1
            continue
        if kind == "w" and tl in DEFINERS and i + 1 < len(toks) and toks[i + 1][0] == "n" and not released:
            name = toks[i + 1][1]
            words.append({"name": name.lower(), "kind": DEFINERS[tl], "flags": [], "file": path,
                          "ranges": [(ln, ln)], "lines": lines,
                          "doc": (DEF_EFFECT.get(tl, ""), line_comment(ln), False), "origin": origin})
            i += 2
            continue
        i += 1
    return words


def tool_entry_points():
    """The words StrataOS loads on demand: lang/forth/os/config.s, pl_tools."""
    s = read(FORTH + "/os/config.s")
    m = re.search(r"^pl_tools:(.*?)\.byte 0\s", s, re.S | re.M)
    return set(re.findall(r'\.asciz "([^"]+)"', m.group(1)))


# ---------------------------------------------------------------- groups
# The sections of the reference, in the order of the README's word list. A
# word goes to the group its name is listed in, else to the group of its
# core.fs section (the "\ ---- title" banners), else to its file's group.
GROUPS = [
    ("stack", "Stack", "The data stack (top cached in <code>s1</code>) and the return stack (the machine stack)."),
    ("arith", "Arithmetic and logic", "64-bit cells; <code>/</code> and <code>mod</code> truncate, like the "
     "hardware. Most of these are inlined, and a literal before <code>+ - and or xor lshift rshift arshift</code> "
     "folds into one instruction."),
    ("memory", "Memory", "The D-LS: cells, bytes and the dictionary's data space. Code space is separate (Harvard)."),
    ("control", "Control flow", "Control structures compile a few instructions each, assembled by core.fs with "
     "the kernel's code-generation words. <code>do</code> loops keep their index and limit in "
     "<code>s2</code>/<code>s3</code>."),
    ("define", "Defining words", "Colon definitions compile to native code; <code>;</code> installs it in the I-LS "
     "with a <code>tput</code> and a <code>tgetx</code> (under StrataOS, with one thread: a <code>tput</code> to "
     "its code unit, which StrataOS pages in). Variables and constants compile as literals."),
    ("strings", "Strings and number formatting", "String literals live in data space; number formatting works on "
     "single cells."),
    ("io", "Input and output", "The console, through the platform layer (the console device on bare metal, the "
     "tty server under StrataOS)."),
    ("interp", "The interpreter and the dictionary", "Parsing, finding, evaluating; headers and their fields."),
    ("compiler", "Compiler and assembler", "The code-generation words core.fs builds the language with, and the "
     "small assembler it uses."),
    ("caps", "Capabilities, transfers and far memory", "Every one of these is a one-liner over "
     "<code>xexec</code>: the instruction is assembled at run time, because it names its capability register and "
     "tag in immediate fields. <code>far@</code> and <code>far!</code> go through a software cache built on "
     "<code>ltag</code>/<code>linst</code>."),
    ("cores", "Multicore", "Other cores are workers: they receive the image by being lent capability "
     "<code>c0</code>, and jobs through the board."),
    ("time", "Time and cost", "The timer and the counters."),
    ("net", "Networking", "StrataOS only: TCP and UDP through the <code>net</code> server (net.fs, udp.fs, loaded "
     "on demand or with <code>require net</code> / <code>require udp</code>); a socket is a handle. "
     "<code>httpd.fs</code> is a web server written with them."),
    ("paging", "Code paging", "StrataOS, one thread: every word compiled after the kernel (core.fs on) is in a "
     "code unit of 2 KiB in far memory, called by <code>xcall</code>; StrataOS pages the units into the I-LS "
     "(the code cache) when they are called, and puts them back after a context switch. A program may be "
     "much bigger than the I-LS, with no annotations; a definition must fit in a unit."),
    ("progs", "The ports of os/progs", "StrataOS: sys.fs, the library of the Forth ports of StrataOS's "
     "programs (<code>forth seq.fs 20</code>, <code>forth ls.fs -t /src</code>, ...; lang/forth/progs/): "
     "the command line, standard input by lines, standard error and the exit code, messages to the file server "
     "and to proc. The ports are kept in one disk file, progs.pk (its head is progs.fs), which "
     "<code>included</code> reads when it is given a name that is no file."),
    ("files", "Files and the system", "Files are StrataOS's; <code>bye</code> halts every core (bare metal) or "
     "ends the process."),
    ("tools", "Tools", "<code>see</code>, the disassembler, <code>words</code>, <code>dump</code> and the "
     "inspection words: built in on bare metal, loaded on demand under StrataOS."),
]

BY_NAME = {
    "stack": "dup drop swap over rot -rot nip tuck 2dup 2drop 2swap 2over ?dup >r r> r@ rdrop 2>r 2r> 2r@ "
             "depth sp@ rp@ pick roll",
    "arith": "+ - * / mod /mod u/ umod um*hi negate abs min max and or xor invert lshift rshift arshift 1+ 1- "
             "2* 2/ = <> < > u< u> 0= 0< 0> 0<> within */ */mod u/mod true false",
    "memory": "@ ! c@ c! w@ w! l@ l! +! here allot , c, align aligned cells cell+ chars char+ cell -cell fill "
              "move erase blank cmove cmove> 2@ 2! ? unused dict-limit buffer: variable 2variable",
    "control": "i j unloop exit recurse execute catch throw abort abort\" (abort\") [if] [else] [then] "
               "[defined]",
    "define": ": ; :noname create constant value does> (does>) immediate postpone literal ' ['] [ ] "
              "compile-name compile, defer defer! defer@ is action-of to { [: ;] state",
    "io": "emit type key accept . u. flush cr space spaces bl .s ? .r u.r h.",
    "interp": "interpret evaluate evaluate-far source parse-name parse find-name number? xt>name >in base "
              "decimal hex source-id source-id-var \\ ( char [char] latest name>string name>xt name>size "
              "name>flags name>link immediate? >body",
    "compiler": "insn, slit, dotq, mark if, ahead, resolve prologue, epilogue, code@ code! install chere "
                "(local) local? jit-trace kvar (lit?)",
    "paging": "unit-stats xtliteral",
    "caps": "far@ far! farc@ farc! fflush finval xexec heap-cap tmp-cap far-size far-read far-write "
            "fcache-reset",
    "cores": "cores core# spawn await publish (reclaim) ?threads workers run-on par give take",
    "time": "ticks ms cycles instret timeit csr@",
    "files": "bye included (tool) (mark) (release) include require",
}
SECTION_GROUP = {
    "kernel variables and constants": "interp",
    "control structures": "control",
    "a small assembler": "compiler",
    "counted loops": "control",
    "more stack and arithmetic words": "arith",
    "case": "control",
    "strings": "strings",
    "number formatting": "strings",
    "conditional compilation": "control",
    "locals and quotations": "define",
    "the dictionary": "interp",
    "memory tiers, capabilities, transfers": "caps",
    "the jit, made visible": "compiler",
    "cores": "cores",
}
FILE_GROUP = {FORTH + "/tools.fs": "tools", FORTH + "/see.fs": "tools", FORTH + "/os/os.fs": "files",
              FORTH + "/net.fs": "net", FORTH + "/udp.fs": "net",
              FORTH + "/sys.fs": "progs", FORTH + "/bare/start.fs": "io"}


def section_of(w):
    """The core.fs section ("\\ ---- title ----") a word is defined in."""
    ln = w["ranges"][0][0]
    for k in range(ln, -1, -1):
        m = re.match(r"^\\ -{3,} (.*?) -{3,}", w["lines"][k])
        if m:
            return re.sub(r"[:(].*", "", m.group(1)).strip().lower()
    return ""


def assign_group(w, by_name):
    if w["file"] in FILE_GROUP and w["file"] != FORTH + "/bare/start.fs":
        return FILE_GROUP[w["file"]]
    if w["name"] in by_name:
        return by_name[w["name"]]
    if w["file"].endswith("core.fs"):
        sec = section_of(w)
        if sec in SECTION_GROUP:
            return SECTION_GROUP[sec]
    return FILE_GROUP.get(w["file"], "interp")


# ---------------------------------------------------------------- examples for the playground
# Words the test does not use (or uses only after earlier lines), with an
# example that runs on bare metal.
EXAMPLES = {
    "see": ": sq ( n -- n*n ) dup * ;  see sq",
    "words": "words",
    ".jit": ".jit",
    ".caps": ".caps",
    ".cap": "heap-cap .cap",
    "jit-trace": "true jit-trace  : cube dup dup * * ;  false jit-trace  3 cube .",
    "disasm": "' dup 8 disasm",
    "code@": "' dup code@ dis",
    "dump": "s\" Strata Forth\" drop 16 dump",
    "ticks": "ticks 10 ms ticks swap - .",
    "ms": "ticks 100 ms ticks swap - .",
    "timeit": ": busy 10000 0 do loop ;  ' busy timeit",
    "cycles": "cycles .",
    "instret": "instret .",
    "par": ": hi ( core -- ) . ;  ' hi par",
    "workers": "workers .",
    "core#": "core# .  ' core# 3 run-on .",
    "emit": "42 emit 10 emit",
    "cr": "1 . cr 2 .",
    "u.": "-1 u.",
    "depth": "1 2 3 depth .",
    "here": "here .",
    "chere": "chere h.",
    "latest": "latest name>string type",
    "unused": "unused .",
    "pick": "10 20 30 2 pick .",
    "roll": "1 2 3 4 3 roll .s",
    "2dup": "1 2 2dup .s",
    "2swap": "1 2 3 4 2swap .s",
    "2over": "1 2 3 4 2over .s",
    "?dup": "0 ?dup .s  5 ?dup .s",
    "within": "5 1 10 within .",
    "*/": "100 3 7 */ .",
    "/mod": "17 5 /mod . .",
    "um*hi": "-1 -1 um*hi h.",
    "fill": "here 8 char * fill here 8 type",
    "move": "s\" hello\" here swap move here 5 type",
    "evaluate": "s\" 6 7 * .\" evaluate",
    "base": "base @ .",
    "far-size": "far-size h.",
    "tmp-cap": "tmp-cap .",
    "farc@": "65 100 farc!  100 farc@ emit",
    "farc!": "65 100 farc!  100 farc@ emit",
    ":noname": ":noname 6 7 * ;  execute .",
    "spaces": "1 . 8 spaces 2 .",
    "h.": "255 h.",
    "defer": ": sq dup * ;  defer action  ' sq is action  9 action .",
    "is": ": sq dup * ;  defer action  ' sq is action  9 action .",
    "does>":": counter create , does> dup @ 1+ dup rot ! ;  0 counter next-id  next-id . next-id .",
    "literal": ": answer [ 6 7 * ] literal ;  answer .",
    "[": ": answer [ 6 7 * ] literal ;  answer .",
    "]": ": answer [ 6 7 * ] literal ;  answer .",
    "postpone": ": my-if postpone if ; immediate  : t 0= my-if 1 . then ;  0 t",
    "immediate": ": now 42 . ; immediate  : t now ;",
    "compile,": ": t [ ' dup compile, ] * ;  7 t .",
    "c,": "create abc 65 c, 66 c, 67 c,  abc 3 type",
    "source": "source type",
    "parse-name": ": next-word parse-name type ;  next-word hello",
    "parse": ": upto-dot [char] . parse type ;  upto-dot hello there.",
    "find-name": "s\" dup\" find-name name>xt h.",
    "number?": "s\" $ff\" number? . .",
    "xt>name": "' dup xt>name name>string type",
    "\\": "1 . \\ the rest of the line is ignored",
    "(": "1 ( a comment ) 2 + .",
    "flush": "1 . flush",
    "publish": "publish",
    "include": None,
    "require": None,
    "included": None,
    "(tool)": None,
    "bye": None,
    "key": None,
    "accept": None,
}

# What a word does, for the primitives whose comment in forth.s names them
# with a stack effect only (the page's own one-line glosses).
STD_DESC = {
    ":": "start a colon definition: native code, installed by `;`",
    ":noname": "start a definition without a name; `;` leaves its xt",
    "create": "a word that pushes the address of its data field",
    "constant": "a word that pushes x (compiled as a literal)",
    "value": "a word that pushes x, changed with `to` (compiled as a load)",
    "postpone": "compile the compilation behaviour of the next word",
    "'": "the execution token of the next word",
    "literal": "compile x as a literal",
    "immediate": "make the newest word run at compile time",
    "recurse": "call the definition being compiled",
    "catch": "run xt; 0, or the code it threw (the stack restored)",
    "throw": "unwind to the innermost catch with n (0 does nothing)",
    "execute": "run the word with this xt",
    "key": "the next character from the console",
    "accept": "read a line of at most n characters to addr",
    "emit": "print a character",
    "type": "print a string",
    "u.": "print unsigned, in BASE, then a space",
    "allot": "reserve n bytes of data space",
    ",": "append a cell to data space",
    "c,": "append a byte to data space",
    "align": "align HERE to a cell",
    "here": "the next free byte of data space",
    "latest": "the newest word's header",
    "source": "the input buffer",
    "parse-name": "the next space-delimited word of the input",
    "parse": "the input up to the delimiter c",
    "find-name": "the header of a word, or 0",
    "number?": "convert a number (BASE, $ # % prefixes, 'c')",
    "xt>name": "the header of the word with this xt, or 0",
    "depth": "the number of items on the data stack",
    "pick": "copy the u-th item to the top",
    "farc@": "cached far byte fetch",
    "farc!": "cached far byte store",
    "local?": "the index of a local in the current definition, or 0",
    "(mark)": "remember the dictionary: data space, code space, the newest word and the hash buckets (one level)",
    "(release)": "forget everything defined since (mark)",
    "do": "start a counted loop: index and limit in s2/s3",
    "(does>)": "make the newest word run the code after DOES>",
    "slit,": "compile a string literal that pushes addr u at run time",
    "2>r": "move two cells to the return stack",
    "2r>": "move two cells back from the return stack",
    "2r@": "copy two cells from the return stack",
    ">r": "move a cell to the return stack",
    "r>": "move a cell back from the return stack",
    "r@": "copy the top of the return stack",
    "rdrop": "drop the top of the return stack",
}
STD_DESC_OVER = {"(mark)", "(release)"}   # the source's own words there are only "one level only."

TEST = FORTH + "/tests/test.fs"
RE_NUM = re.compile(r"^-?(?:\$-?[0-9a-f]+|#-?\d+|%-?[01]+|\d+|'.')$", re.I)


def good_test_lines():
    """test.fs lines whose output in test.out has no error."""
    fs = read(TEST).split("\n")
    out = read(FORTH + "/tests/test.out").split("\n")
    good = []
    j = 0
    for ln, s in enumerate(fs):
        if not s.strip() or s.startswith("\\") or s.startswith("23 kvar"):
            continue
        while j < len(out) and not out[j].startswith(s):
            j += 1
        if j >= len(out):
            break
        bad = "***" in out[j] or (j + 1 < len(out) and out[j + 1].startswith("***"))
        if not bad:
            good.append((ln, s))
        j += 1
    return good


def standalone(text, known):
    """Does this Forth text use only numbers, known words and words it defines itself?"""
    toks, _ = tokens(text)
    defined = set()
    prev = None
    for kind, t, _ in toks:
        tl = t.lower()
        if kind in ("s", "p", "\\"):
            prev = None
            continue
        if kind == "n":
            defined.add(tl)
        elif kind == "a":
            if prev not in ("[char]", "char") and tl not in known and tl not in defined:
                return False
        elif tl == "bye":
            return False
        elif not (RE_NUM.match(t) or tl in known or tl in defined):
            return False
        prev = tl
    return True


OUTPUT = {".", "u.", "h.", ".s", "?", "type", "emit", ".r", "u.r", ".fcache", ".cap", ".caps", ".jit", "dis",
          "words", "dump", "see"}


def prints(text, tail=None):
    """Does this text, run, show something: an output word, or a call of a word
    it defines, outside a definition (in its part `tail`, if given)?"""
    depth, defined, prev = 0, set(), None
    for kind, t, _ in tokens(text)[0]:
        if kind == "n" and prev == ":":        # colon definitions (not variables) do something
            defined.add(t.lower())
        prev = t
    for kind, t, _ in tokens(text if tail is None else tail)[0]:
        tl = t.lower()
        if kind == "w" and tl in (":", "[:"):
            depth += 1
        elif kind == "w" and tl in (";", ";]"):
            depth = max(0, depth - 1)
        elif kind == "w" and depth == 0 and (tl in OUTPUT or tl in defined):
            return True
    return False


def test_examples(known):
    """name -> an example from a passing test line that uses it: the shortest
    stretch of the line (statements are separated by two spaces) that needs
    nothing from earlier lines, extended until it prints something; with the
    line before it if that is what defines what it uses."""
    best = {}
    good = good_test_lines()
    prev_line, next_line = {}, {}
    for (a, sa), (b, sb) in zip(good, good[1:]):
        if b == a + 1:
            prev_line[b], next_line[a] = sa, sb
    for ln, line in good:
        segs = re.split(r"\s{2,}", line.strip())
        pl = prev_line.get(ln)
        # A test line is one step of a session: what comes first in it sets up
        # what follows, and a line that needs the line before it (what that
        # defines) needs its state too.
        after_prev = not standalone(line, known) and pl and standalone(pl + "\n" + line, known)
        for k, seg in enumerate(segs):
            toks, _ = tokens(seg)
            used = {t.lower() for (kind, t, _) in toks if kind in ("w", "a")}
            cand, segs_ = None, segs
            if after_prev:
                cand, segs_ = (0, k), [pl + "\n" + segs[0]] + segs[1:]
            else:
                # the line from its start, else the shortest stretch ending here
                for j in [0] + list(range(k, 0, -1)):
                    if standalone("  ".join(segs[j:k + 1]), known):
                        cand = (j, k)
                        break
            if cand is None:
                continue
            j, e = cand
            # on to the next statements until something shows what this one did
            while not prints("  ".join(segs_[j:e + 1]), "  ".join(segs_[k:e + 1])) and e + 1 < len(segs_) \
                    and standalone("  ".join(segs_[j:e + 2]), known):
                e += 1
            text, tail = "  ".join(segs_[j:e + 1]), "  ".join(segs_[k:e + 1])
            nl = next_line.get(ln)
            if not prints(text, tail) and e + 1 == len(segs_) and nl and prints(text + "\n" + nl, tail + "\n" + nl) \
                    and standalone(text + "\n" + nl, known):
                text, tail = text + "\n" + nl, tail + "\n" + nl   # a definition, used on the next line
            score = (0 if prints(text, tail) else 1, len(text))
            for w in used:
                if w in known and (w not in best or score < best[w][0]):
                    best[w] = (score, text)
    return {w: t for (w, (s, t)) in best.items()}


# ---------------------------------------------------------------- the page
def avail_of(w, tools):
    f = w["file"]
    if f.endswith("/os/os.fs"):
        return "os", "StrataOS only"
    if f.endswith("/net.fs") or f.endswith("/udp.fs"): # (sockets exist only under StrataOS)
        base = os.path.basename(f)[:-3]
        return "os", "StrataOS only: loaded on demand, or <code>require %s</code>" % base
    if f.endswith("/sys.fs"):                         # (a disk file: StrataOS's)
        return "os", "StrataOS: in a port, or after <code>include /sys.fs</code>"
    if f.endswith("/bare/start.fs"):
        return "bare", "bare metal only"
    if f.endswith("/tools.fs") or f.endswith("/see.fs") or f.endswith("/net.fs") or f.endswith("/udp.fs"):
        base = os.path.basename(f)[:-3]
        if w["name"] in tools:
            return "demand", "StrataOS: loaded on demand"
        return "require", "StrataOS: after <code>require %s</code>" % base
    return "all", ""


def kind_text(w):
    if w["kind"] == "primitive":
        t = "kernel primitive"
        if "inline" in w["flags"]:
            t += " · inlined"
        if w.get("fold"):
            t += " · folds a literal"
        return t
    return {"colon": "colon definition", "constant": "constant", "value": "value", "variable": "variable",
            "created": "created", "deferred": "deferred", "buffer": "buffer"}[w["kind"]]


def src_block(w, rng):
    a, b = rng
    text = "\n".join(w["lines"][a:b + 1])
    href = "../code/#%s:%d%s" % (w["file"], a + 1, "-%d" % (b + 1) if b > a else "")
    loc = "%s:%d%s" % (w["file"].split("lang/forth/", 1)[1], a + 1, "–%d" % (b + 1) if b > a else "")
    return text, href, loc, b - a + 1


def prose(s):
    """A comment as HTML: escaped, `code` in backticks."""
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", esc(s))


def word_html(w, ex):
    wid = word_id(w["name"])
    eff, desc, _ = w["doc"]
    meta = ['<span class="wk">%s</span>' % kind_text(w)]
    if "immediate" in w["flags"]:
        meta.append('<span class="wf">immediate</span>')
    if w["avail"][1]:
        meta.append('<span class="wa wa-%s">%s</span>' % (w["avail"][0], w["avail"][1]))
    srcs = []
    for src in w["sources"]:
        for n, rng in enumerate(src["ranges"]):
            text, href, loc, nlines = src_block(src, rng)
            lang = "strata-asm" if src["file"].endswith(".s") else "forth"
            what = ("redefined in " + os.path.basename(src["file"])) if src is not w["sources"][0] else (
                "continues in shared code" if n else "source")
            srcs.append('<details class="wsrc"%s><summary><span class="ws-what">%s</span>'
                        '<a class="srcref" href="%s" title="These lines in the source browser">%s</a>'
                        '<em>%d line%s</em></summary><pre class="lst"><code class="language-%s">%s</code></pre>'
                        '</details>' % (" open" if nlines <= 12 else "", what, href, esc(loc), nlines,
                                        "" if nlines == 1 else "s", lang, esc(text)))
    try_html = ""
    if ex:
        try_html = ('<div class="try"><button type="button" class="try-b" data-try="%s" '
                    'title="Put this in the playground editor and run it">Try</button>'
                    '<code class="language-forth">%s</code></div>\n' % (esc(ex), esc(ex)))
    hay = " ".join([w["name"], eff, desc, kind_text(w), os.path.basename(w["file"]),
                    re.sub(r"<[^>]+>", "", w["avail"][1]), " ".join(w["flags"])]).lower()
    return ('<article class="word" id="%s" data-name="%s" data-k="%s">\n'
            '<header class="word-h"><h3><a href="#%s"><code>%s</code></a></h3>%s</header>\n'
            '%s<p class="word-meta">%s</p>\n%s%s\n</article>' % (
                wid, esc(w["name"]), esc(hay), wid, esc(w["name"]),
                '<code class="stack">%s</code>' % esc(eff) if eff else "",
                '<p class="word-d">%s</p>\n' % prose(desc) if desc else "",
                "".join(meta), try_html, "\n".join(srcs)))


def collect():
    kernel = kernel_words()
    files = [(FORTH + "/core.fs", "core"), (FORTH + "/tools.fs", "tools"), (FORTH + "/see.fs", "see"),
             (FORTH + "/os/os.fs", "os"), (FORTH + "/bare/start.fs", "bare"),
             (FORTH + "/net.fs", "net"), (FORTH + "/udp.fs", "udp"),
             (FORTH + "/sys.fs", "sys")]
    words, by = [], {}
    for w in kernel:
        w["sources"] = [w]
        words.append(w)
        by[w["name"]] = w
    for path, origin in files:
        for w in forth_words(path, origin):
            if w["name"] in by:
                old = by[w["name"]]
                old["sources"].append(w)        # a redefinition: `:` and `:noname` in core.fs
                continue
            w["sources"] = [w]
            words.append(w)
            by[w["name"]] = w
    tools = tool_entry_points()
    by_name = {}
    for g, names in BY_NAME.items():
        for n in names.split():
            by_name[n] = g
    titles = {g: t for (g, t, _) in GROUPS}
    for w in words:
        n = w["name"]
        if w["kind"] == "primitive" and n in STD_DESC and (not w["doc"][1] or n in STD_DESC_OVER):
            w["doc"] = (w["doc"][0], STD_DESC[n], False)
        w["group"] = assign_group(w, by_name)
        w["group_title"] = titles[w["group"]]
        w["avail"] = avail_of(w, tools)
    ids = {}
    for w in words:
        i = word_id(w["name"])
        assert i not in ids, "two words with the anchor %s: %r %r" % (i, ids[i], w["name"])
        ids[i] = w["name"]
    return words, tools


def examples(words):
    known = {w["name"] for w in words}
    ex = test_examples(known)
    out = {}
    for w in words:
        n = w["name"]
        if w["avail"][0] == "os":
            out[n] = None
        elif n in EXAMPLES:
            out[n] = EXAMPLES[n]
        elif n in ex:
            out[n] = ex[n]
        elif w["kind"] in ("constant", "value", "variable", "created", "buffer"):
            out[n] = "%s ." % n if w["kind"] in ("constant", "value") else "%s h." % n
        elif w["kind"] == "colon" or (w["kind"] == "primitive" and w["inline_body"]):
            out[n] = "see " + n       # its machine code: the inlined body, or the compiled definition
        else:
            out[n] = None
    return out


def page_main(words, ex, intro):
    side, main = [], []
    side.append('    <div class="doc-find"><input id="filter" type="search" placeholder="Filter words…  ( / )" '
                'autocomplete="off" spellcheck="false" aria-label="Filter words by name, stack effect or description" '
                'data-items="article.word" data-prefix="w-" data-noun="words">'
                '<p id="count" class="doc-count" aria-live="polite"></p></div>')
    side.append('    <details class="doc-ix" id="ix" open><summary>Index</summary><nav class="doc-toc" aria-label="Words">')
    side.append('      <div class="ix-group" id="ix-intro"><a class="ix-ch" href="#intro"><span>Strata Forth</span></a>'
                '<a class="ix-ch" href="#playground"><span>Playground</span></a></div>')
    for (g, title, blurb) in GROUPS:
        lst = [w for w in words if w["group"] == g]     # in source order: the kernel's table, then the files
        if not lst:
            continue
        side.append('      <div class="ix-group" data-ch="%s"><a class="ix-ch" href="#g-%s"><span>%s</span><em>%d</em></a>'
                    % (g, g, title, len(lst)))
        for w in lst:
            wid = word_id(w["name"])
            side.append('        <a class="ix" href="#%s" data-for="%s"><code>%s</code><span>%s</span></a>' % (
                wid, wid, esc(w["name"]), esc(w["doc"][0])))
        side.append("      </div>")
        rows = "".join('<tr data-for="%s"><td><a href="#%s"><code>%s</code></a></td><td><code class="stack">%s</code>'
                       '</td><td>%s</td></tr>' % (word_id(w["name"]), word_id(w["name"]), esc(w["name"]),
                                                  esc(w["doc"][0]), prose(w["doc"][1]))
                       for w in lst)
        main.append('<section class="chap" id="g-%s" data-ch="%s">\n<h2><span class="num">%d words</span>%s</h2>\n'
                    '<p>%s</p>\n<div class="tbl summary"><table><thead><tr><th>Word</th><th>Stack</th><th>What it does'
                    '</th></tr></thead><tbody>%s</tbody></table></div>\n%s\n</section>' % (
                        g, g, len(lst), title, blurb, rows,
                        "\n".join(word_html(w, ex.get(w["name"])) for w in lst)))
    side.append("    </nav></details>")
    side.append('    <p class="doc-keys"><kbd>/</kbd> filter · <kbd>Enter</kbd> first match · <kbd>Esc</kbd> clear</p>')
    return "\n".join(side), intro + "\n" + "\n".join(main)


def web_file(name):
    """doc/manual/web/NAME without its leading comment."""
    with open(os.path.join(WEB, name), encoding="utf-8") as f:
        return re.sub(r"\A\s*<!--.*?-->\s*", "", f.read(), flags=re.S)


def intro_html(words, tools):
    n_k = sum(1 for w in words if w["kind"] == "primitive")
    counts = {"words": len(words), "kernel": n_k, "forth": len(words) - n_k, "tools": len(tools),
              "inline": sum(1 for w in words if "inline" in w["flags"])}
    return re.sub(r"\{\{(\w+)\}\}", lambda m: str(counts[m.group(1)]), web_file("forth.html"))


def write(out, page, link_sources=None, files=None):
    """forth/index.html under out; page is genweb.page."""
    words, tools = collect()
    ex = examples(words)
    side, main = page_main(words, ex, intro_html(words, tools))
    head = ('<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/xterm@5.3.0/css/xterm.css">\n'
            '<link rel="stylesheet" href="forth.css?v=__BUILD__">')
    tail = (web_file("forth-play.html") +
            '<script src="https://cdn.jsdelivr.net/npm/xterm@5.3.0/lib/xterm.js"></script>\n'
            '<script src="https://cdn.jsdelivr.net/npm/xterm-addon-fit@0.8.0/lib/xterm-addon-fit.js"></script>\n'
            '<script src="forth.js?v=__BUILD__"></script>')
    text = page("forth", "Strata Forth", "Strata Forth: every word of the native-code Forth for Strata, with its "
                "stack effect, description and source, and a playground running the real Forth in the browser.",
                side, main, head=head, tail=tail)
    if link_sources and files is not None:
        text = link_sources(text, files)
    os.makedirs(os.path.join(out, "forth"), exist_ok=True)
    with open(os.path.join(out, "forth", "index.html"), "w") as f:
        f.write(text)
    n_try = sum(1 for v in ex.values() if v)
    return len(words), sum(1 for w in words if w["kind"] == "primitive"), n_try


def check():
    """Runs every example on bare metal, as the playground does (8 cores, a
    640x400 screen), and reports those that end in an error."""
    import subprocess
    import tempfile
    words, _ = collect()
    ex = {n: e for (n, e) in examples(words).items() if e}
    emu, img = os.path.join(ROOT, "build", "strata-emu"), os.path.join(ROOT, "build", "forth.stx")
    bad = 0
    with tempfile.TemporaryDirectory() as tmp:
        f = os.path.join(tmp, "try.fs")
        for n, e in ex.items():
            with open(f, "w") as fh:
                fh.write(e + "\n")
            try:
                out = subprocess.run([emu, "-c", "8", "-g", "none", "-r", "640x400", "-m", "200000000", "-i", f, img],
                                     capture_output=True, text=True, timeout=60).stdout
            except subprocess.TimeoutExpired:
                out = "\n*** timeout"
            body = out.split("\n", 1)[-1]        # after the banner
            if re.search(r"^\*\*\* |\n\*\*\* ", body) or not re.search(r"\bok\b", body):
                bad += 1
                print("%s: %s\n  %s" % (n, e, body.strip().replace("\n", "\n  ")))
    print("genforth: %d examples, %d failed" % (len(ex), bad))
    return bad == 0


def main():
    if sys.argv[1:] == ["--check"]:
        sys.exit(0 if check() else 1)
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.path.insert(0, HERE)
    import genweb
    n, k, t = write(sys.argv[1], genweb.page, genweb.link_sources, genweb.browsable())
    print("web-docs: %d Forth words (%d kernel primitives, %d in Forth; %d with an example) -> %s/forth/" % (
        n, k, n - k, t, sys.argv[1]))


if __name__ == "__main__":
    main()
