#!/usr/bin/env python3
"""web-os.py: the message tables of the StrataOS pages (site/os/), from the sources.

Every server answers its messages in one dispatch: pairs of

        li    t2, 23                    ; DEVS
        beq   t1, t2, op_devs           ; ...

and documents them in its header comment, one entry per op:

;  23 DEVS     -> entries; data: the platform table's 32-byte entries

The op numbers come from the dispatch (what the server answers); each one's
name and text from the comments (the server's header, the headers of the
files it includes, or a section heading "; ---- NAME: text"). The svc calls
are the dispatcher's dispatch in os/kernel.s and the entries "a0 = N NAME"
of its header; the system core's operations are os/kunits/ops.s. The OP_*
constants of os/lib/sys.s that name a server ("; fs: open a file") must be
ops that server answers.

The pages carry the generated tables between markers:

    <!-- ops:fs -->  ...  <!-- /ops:fs -->

  web-os.py OUTDIR    the pages with fresh tables into OUTDIR/os/ (the site's build)
  web-os.py --write   refresh the tables of site/os/*.html in place
  web-os.py --check   exit 1 if site/os/*.html does not show exactly what the
                      sources answer (an op missing from a page, one that no
                      server answers, an op without a description, an OP_*
                      constant its server does not answer), or if the manual's
                      chapter (doc/manual/ch-os.tex) leaves out one of the
                      tables or diagrams

The manual's StrataOS chapter takes the same tables and the same drawings:
latex_outputs() gives doc/manual/gen/geninsns.py (which writes every gen-*.tex
of the manual) gen-os-ops-KEY.tex, a longtable per table, and
gen-os-fig-NAME.tex, each SVG diagram of the pages as a TikZ picture (NAME is
the prefix of its title's id: <title id="cm-t"> is gen-os-fig-cm.tex).
"""
import html
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = os.path.join(ROOT, "site", "os")
CODE = "../code/#"

# key, title, dispatch (file, first line, last line: regular expressions),
# files whose comments document the ops
TABLES = [
    ("svc", "svc calls", ("os/kernel.s", r"^wt_svc:", r"^\s*li\s+a0,\s*-1\s*;\s*unknown"),
     ["os/kernel.s"]),
    ("kernel", "the system core", ("os/kunits/ops.s", r"ld\s+t0,\s*k_hdr-GPBASE", r"^\s*li\s+a0,\s*-1\s*;\s*unknown"),
     ["os/kunits/ops.s"]),
    ("proc", "proc", ("os/servers/proc.s", r"^lp_proc:", r"^\s*li\s+a0,\s*-1\s*;\s*unknown"),
     ["os/servers/proc.s"]),
    ("dev", "dev", ("os/servers/dev.s", r";\s*dispatch", r"^\s*li\s+a0,\s*-1\s*;\s*unknown"),
     ["os/servers/dev.s"]),
    ("fs", "fs", ("os/servers/fs.s", r";\s*dispatch", r"^bad:"),
     ["os/servers/fs.s", "os/servers/fsattr.s", "os/servers/fsops.s", "os/servers/fsunits.s"]),
    ("tty", "tty", ("os/servers/tty.s", r"^request:", r"^\s*li\s+a0,\s*-1\s*;\s*unknown"),
     ["os/servers/tty.s"]),
    ("pipe", "pipe", ("os/servers/pipe.s", r";\s*dispatch", r"^\s*li\s+a0,\s*-1\s*;\s*unknown"),
     ["os/servers/pipe.s"]),
    ("net", "net", ("os/servers/net.s", r";\s*dispatch", r"^bad:"),
     ["os/servers/net.s"]),
    ("ws", "ws", ("os/ws/ws.s", r"^rq_serve:", r";\s*----\s*TITLE"),
     ["os/ws/ws.s"]),
]
# the manual's table of each: label, caption
LATEX = {
    "svc": ("tab:os-svc", "StrataOS supervisor calls (\\reg{a0})"),
    "kernel": ("tab:os-kops", "Operations of the system core"),
    "proc": ("tab:os-proc", "Operations of \\texttt{proc} (endpoint \\reg{c1})"),
    "dev": ("tab:os-dev", "Operations of \\texttt{dev} (through LOOKUP)"),
    "fs": ("tab:os-fs", "Operations of \\texttt{fs} (endpoint \\reg{c2})"),
    "tty": ("tab:os-tty", "Operations of \\texttt{tty} (endpoint \\reg{c3})"),
    "pipe": ("tab:os-pipe", "Operations of \\texttt{pipe} (endpoint \\reg{c4})"),
    "net": ("tab:os-net", "Operations of \\texttt{net} (through LOOKUP)"),
    "ws": ("tab:os-ws", "Operations of the window server"),
}
SYSTEM_OPS = (36, 37, 38)               # proc -> every server: os/lib/srv.s
ERRORS = {-1: "failed", -2: "interrupted", -3: "would block", -4: "no such file or program",
          -5: "no free core / not allowed", -6: "no memory", -7: "busy", -8: "timed out"}


def read(path):
    with open(os.path.join(ROOT, path)) as f:
        return f.read().split("\n")


def constants(paths):
    """NAME = value (decimal or hex) in these files."""
    out = {}
    for p in paths:
        for line in read(p):
            m = re.match(r"^([A-Z_][A-Z0-9_]*)\s*=\s*(0x[0-9A-Fa-f]+|\d+)\b", line)
            if m:
                out[m.group(1)] = int(m.group(2), 0)
    return out


def value(tok, consts):
    tok = tok.strip()
    m = re.fullmatch(r"([A-Z_][A-Z0-9_]*)\s*-\s*([A-Z_][A-Z0-9_]*)", tok)
    if m:
        return consts[m.group(1)] - consts[m.group(2)]
    if re.fullmatch(r"0x[0-9A-Fa-f]+|\d+", tok):
        return int(tok, 0)
    return consts[tok]


def dispatch(path, first, last, consts):
    """The op numbers the region answers: {number: (handler label, line)}. A
    range check (addi t2, t1, -OP_A; li t3, OP_B - OP_A; bgtu) followed by
    single tests answers the untested rest of the range too (ws's TITLE)."""
    lines = read(path)
    i = next(n for n, l in enumerate(lines) if re.search(first, l))
    ops, rng = {}, None
    n = i
    while n < len(lines):
        l = lines[n]
        if n > i and re.search(last, l):
            break
        m = re.match(r"^\s*li\s+(t\d)\s*,\s*([^;]+?)\s*(;.*)?$", l)
        if m and n + 1 < len(lines):
            b = re.match(r"^\s*beq\s+(\w+)\s*,\s*" + m.group(1) + r"\s*,\s*(\w+)", lines[n + 1])
            if b:
                ops[value(m.group(2), consts)] = (b.group(2), n + 1)
        m = re.match(r"^\s*addi\s+t\d\s*,\s*t\d\s*,\s*-([A-Z_][A-Z0-9_]*)", l)
        if m:
            lo = consts[m.group(1)]
            w = re.match(r"^\s*li\s+t\d\s*,\s*([A-Z_][A-Z0-9_]*\s*-\s*[A-Z_][A-Z0-9_]*)", lines[n + 1])
            rng = (lo, lo + value(w.group(1), consts))
        n += 1
    if rng:
        for op in range(rng[0], rng[1] + 1):
            ops.setdefault(op, ("(the range)", n + 1))
    return ops


ENTRY = re.compile(r"^;(\s+)(?:a0 = )?(\d+)((?:/\d+)*)\s+([A-Z][A-Z0-9_]+)\b(.*)$")
NEXT = re.compile(r"^\s*/\s*(\d+)\s+([A-Z][A-Z0-9_]+)\b(.*)$")
SPLIT = re.compile(r"\s{3,}(?=(?:a0 = )?\d+\s+[A-Z][A-Z0-9_]+\b)")


def docs(paths):
    """{number: (name, text, priority, file, line)} from the files' comments; priority 2 an
    entry of its own, 1 one of a group ("42 SETATTR / 43 GETATTR  ..."), 0 a
    section heading ("; ---- GUEST: ...")."""
    out = {}

    def put(num, name, text, prio, where):
        if num not in out or out[num][2] < prio:
            out[num] = (name, " ".join(text.split()), prio) + where

    for p in paths:
        block = [(n + 1, l) for n, l in enumerate(read(p)) if l.startswith(";")]
        k = 0
        while k < len(block):
            ln, l = block[k]
            m = ENTRY.match(l)
            if not m:
                k += 1
                continue
            indent = len(m.group(1))
            # the entry's text: the rest of its line and the lines indented deeper
            text = [m.group(5)]
            k += 1
            while k < len(block):
                c = block[k][1]
                body = c[1:]
                if block[k][0] != block[k - 1][0] + 1 or not body.strip() or ENTRY.match(c) or len(body) - len(body.lstrip()) <= indent:
                    break
                text.append(body.strip())
                k += 1
            # several entries on one line, far apart ("45 DESTROY ...    46 TITLE ...")
            first = (m.group(2) + m.group(3)) + " " + m.group(4) + " ".join(text)
            pieces = SPLIT.split(first)
            for piece in pieces:
                e = re.match(r"(?:a0 = )?(\d+)((?:/\d+)*)\s+([A-Z][A-Z0-9_]+)\b(.*)$", piece)
                nums = [int(e.group(1))] + [int(x) for x in e.group(2).split("/")[1:]]
                rest = e.group(4)
                names = [e.group(3)]
                if len(nums) > 1:       # "36/37/38    DUPS / CLEANUP / CANCEL ..."
                    g = re.match(r"((?:\s*/\s*[A-Z][A-Z0-9_]+)+)(.*)$", rest)
                    names += re.findall(r"[A-Z][A-Z0-9_]+", g.group(1))
                    rest = g.group(2)
                while True:             # "42 SETATTR / 43 GETATTR ..."
                    g = NEXT.match(rest)
                    if not g:
                        break
                    nums.append(int(g.group(1)))
                    names.append(g.group(2))
                    rest = g.group(3)
                grouped = len(nums) > 1
                for num, name in zip(nums, names):
                    put(num, name, rest, 1 if grouped else 2, (p, ln))
    for p in paths:
        for n, l in enumerate(read(p)):
            m = re.match(r"^;\s*----\s+([A-Z][A-Z0-9_]+):\s*(.*?)\s*-*\s*$", l)
            if m:
                out.setdefault(("heading", m.group(1)), (m.group(1), m.group(2), 0, p, n + 1))
    return out


def sysops():
    """The OP_* constants of sys.s with the servers their comment names."""
    out = []
    for n, l in enumerate(read("os/lib/sys.s")):
        m = re.match(r"^(OP_[A-Z0-9_]+)\s*=\s*(\d+)\s*;\s*([a-z, ]+):", l)
        if m:
            for s in m.group(3).split(","):
                out.append((m.group(1), int(m.group(2)), s.strip(), n + 1))
    return out


def build():
    """{key: [(num, name, text, file, line, handler)]} and the problems found."""
    consts = constants(["os/lib/sys.s", "os/lib/srv.s"])
    problems = []
    tables = {}
    for key, title, (dfile, first, last), dpaths in TABLES:
        c = dict(consts)
        c.update(constants([dfile] + dpaths))
        ops = dispatch(dfile, first, last, c)
        d = docs(dpaths)
        heads = {v[0]: v for k, v in d.items() if isinstance(k, tuple)}
        rows = []
        for num in sorted(ops):
            if num in SYSTEM_OPS and key not in ("svc", "kernel"):
                continue
            if num in d:
                name, text, _, f, ln = d[num]
            else:
                # a section heading of the handler's name ("op_guest" -> "GUEST")
                h = ops[num][0].upper().replace("OP_", "")
                if h in heads:
                    name, text, _, f, ln = heads[h]
                else:
                    problems.append("%s: op %d (%s, %s:%d) has no description in %s"
                                    % (key, num, ops[num][0], dfile, ops[num][1], ", ".join(dpaths)))
                    name, text, f, ln = ops[num][0].upper(), "", dfile, ops[num][1]
            rows.append((num, name, text, f, ln, ops[num][0]))
        for num in sorted(k for k in d if not isinstance(k, tuple)):
            if num not in ops and not (key == "kernel" and num == 7):     # 7 EXITED: sent by the kernel
                problems.append("%s: %s:%d describes op %d %s, which the dispatch (%s) does not answer"
                                % (key, d[num][3], d[num][4], num, d[num][0], dfile))
        tables[key] = (rows, sorted(o for o in ops if o in SYSTEM_OPS))
    answered = {k: {r[0] for r in rows} | set(sy) for k, (rows, sy) in tables.items()}
    for name, num, server, ln in sysops():
        if server in answered and num not in answered[server]:
            problems.append("os/lib/sys.s:%d: %s = %d is a %s op, but %s does not answer %d"
                            % (ln, name, num, server, server, num))
    return tables, problems


def fmt(text):
    """A description: HTML-escaped, with "->" as an arrow and `code` kept."""
    t = html.escape(text)
    t = t.replace("-&gt;", "&rarr;")
    return t


def split(text):
    """Request and reply: the text before and after its first "->"."""
    if "->" in text:
        a, b = text.split("->", 1)
        return a.strip(" ;:,"), b.strip()
    return text.strip(), ""


def errors(reply):
    codes = sorted({int(x) for x in re.findall(r"(?<![\w.])-([1-8])\b", reply)})
    return " ".join('<abbr title="%s">%d</abbr>' % (ERRORS[-c], -c) for c in codes)


def table(key, rows, system):
    out = ['<div class="optable"><table>',
           '<thead><tr><th class="n">op</th><th>name</th><th>request</th><th>reply</th><th>errors</th></tr></thead>',
           "<tbody>"]
    for num, name, text, f, ln, handler in rows:
        req, rep = split(text)
        if text.count("->") > 1:        # several modes, each with its reply: kept whole
            cells = '<td colspan="2">%s</td>' % fmt(text)
        else:
            cells = "<td>%s</td><td>%s</td>" % (fmt(req), fmt(rep))
        out.append('<tr id="%s-%d"><td class="n">%d</td><td><a class="opname" href="%s%s:%d"><code>%s</code></a></td>'
                   '%s<td class="err">%s</td></tr>'
                   % (key, num, num, CODE, f, ln, name, cells, errors(rep)))
    out.append("</tbody></table></div>")
    if system:
        out.append('<p class="sysops">Also answered: %s from <code>proc</code> (<a href="#system">below</a>).</p>'
                   % ", ".join("%d %s" % (n, {36: "DUPS", 37: "CLEANUP", 38: "CANCEL"}[n]) for n in system))
    return "\n".join(out)


# ---------------------------------------------------------------- the manual (LaTeX)
UNI = {"·": r"\textperiodcentered{}", "–": r"\textendash{}", "—": r"\textemdash{}", "→": r"$\rightarrow$", "←": r"$\leftarrow$",
       "↔": r"$\leftrightarrow$", "…": r"\ldots{}", "−": "$-$", "×": r"$\times$", "≤": r"$\le$", "≥": r"$\ge$"}
for _n, _c in enumerate("①②③④⑤⑥⑦⑧⑨"):
    UNI[_c] = r"\textcircled{\scriptsize %d}" % (_n + 1)


def tex(text, mono=False):
    """Plain text -> LaTeX: specials escaped, the arrow and the dashes typeset (in a
    typewriter font, quotes stay straight)."""
    out = []
    for ch in text:
        if ch in "\\":
            out.append(r"\textbackslash{}")
        elif ch in "&%$#_{}":
            out.append("\\" + ch)
        elif ch == "~":
            out.append(r"\textasciitilde{}")
        elif ch == "^":
            out.append(r"\textasciicircum{}")
        elif ch in "<>|":
            out.append({"<": r"\textless{}", ">": r"\textgreater{}", "|": r"\textbar{}"}[ch])
        elif ch in UNI:
            out.append(UNI[ch])
        elif ord(ch) > 127:
            raise ValueError("web-os: no LaTeX for %r in %r" % (ch, text))
        else:
            out.append(ch)
    t = "".join(out)
    t = t.replace(r"-\textgreater{}", r"$\rightarrow$")
    t = re.sub(r"(?<![\w.])-(\d)", r"$-$\1", t)
    if mono:
        t = t.replace('"', r"\textquotedbl{}")
    else:
        t = re.sub(r'(^|[\s(\[])"', r"\1``", t).replace('"', "''")     # "ws": opening and closing quotes
    return t


def latex_table(key, rows, system):
    label, caption = LATEX[key]
    t = "%% generated by tools/web-os.py from the sources: do not edit\n"
    t += "\\begin{small}\n\\begin{longtable}{@{}r>{\\ttfamily}l>{\\raggedright\\arraybackslash}p{0.75\\linewidth}@{}}\n"
    t += "\\caption{%s}\\label{%s}\\\\\n\\toprule\n" % (caption, label)
    hdr = "\\textbf{%s} & \\textrm{\\bfseries Name} & \\textbf{Request %s reply}\\\\\\midrule\n" % (
        "\\reg{a0}" if key == "svc" else "Op", "$\\rightarrow$")
    t += hdr + "\\endfirsthead\n\\toprule\n" + hdr + "\\endhead\n\\bottomrule\n\\endfoot\n"
    for num, name, text, f, ln, handler in rows:
        t += "%d & %s & %s\\\\\n" % (num, tex(name), tex(text) if text else "")
    t += "\\end{longtable}\n"
    if system:
        t += "\\vspace{-1.5ex}\\noindent{\\footnotesize Also answered: %s from \\texttt{proc}.}\n" % ", ".join(
            "%d %s" % (n, {36: "DUPS", 37: "CLEANUP", 38: "CANCEL"}[n]) for n in system)
    return t + "\\end{small}\n"


# the site's colours, for paper: class -> TikZ style
TIKZ_STYLES = r"""
  box/.style={draw=accent!70,fill=white,line width=0.9pt},
  box sys/.style={draw=osamber,fill=osamber!7,line width=0.9pt},
  box amb/.style={draw=osamber,fill=osamber!7,line width=0.9pt},
  box srv/.style={draw=oscyan,fill=oscyan!6,line width=0.9pt},
  box hot/.style={draw=oscyan,fill=oscyan!6,line width=1.4pt},
  box dim/.style={draw=black!40,fill=black!3,dashed,line width=0.8pt},
  fillc/.style={draw=oscyan,fill=oscyan!12,line width=0.6pt},
  filla/.style={draw=osamber,fill=osamber!14,line width=0.6pt},
  filld/.style={draw=black!30,fill=black!5,line width=0.6pt},
  act/.style={draw=oscyan,fill=oscyan!14,line width=0.6pt},
  acta/.style={draw=osamber,fill=osamber!16,line width=0.6pt},
  ln/.style={draw=accent!70,line width=1pt},
  lnc/.style={draw=oscyan,line width=1.2pt},
  lna/.style={draw=osamber,line width=1.2pt},
  lnd/.style={draw=black!40,line width=0.8pt,dash pattern=on 3pt off 4pt},
  life/.style={draw=black!35,line width=0.9pt,dash pattern=on 5pt off 4pt},
  tx/.style={anchor=base west,inner sep=0,outer sep=0,text=black,font=\fontsize{13}{15}\selectfont},
  t/.style={tx,font=\fontsize{14}{16}\selectfont\bfseries},
  s/.style={tx,text=black!60,font=\fontsize{12}{14}\selectfont},
  m/.style={tx,text=black!60,font=\fontsize{11.5}{13}\selectfont\ttfamily},
  mc/.style={tx,text=oscyan,font=\fontsize{11.5}{13}\selectfont\ttfamily},
  ma/.style={tx,text=osamber,font=\fontsize{11.5}{13}\selectfont\ttfamily},
  h/.style={tx,text=osamber,font=\fontsize{11}{13}\selectfont\ttfamily}"""
ARROW = {"arrc": "oscyan", "arra": "osamber", "arre": "accent!70"}


def svg_attrs(tag):
    return dict(re.findall(r'([\w-]+)="([^"]*)"', tag))


def svg_path(d):
    """An SVG path (M L H V C z, absolute) as TikZ path text."""
    toks = re.findall(r"[MLHVCz]|-?\d+(?:\.\d+)?", d)
    out, x, y, k, start = [], 0.0, 0.0, 0, None
    num = lambda: float(toks[k])
    pt = lambda a, b: "(%g,%g)" % (a, b)
    cmd = None
    while k < len(toks):
        if re.match(r"[MLHVCz]", toks[k]):
            cmd = toks[k]
            k += 1
            if cmd == "z":
                out.append("-- cycle")
                continue
        if cmd == "M":
            x, y = float(toks[k]), float(toks[k + 1]); k += 2
            out.append(pt(x, y)); start = (x, y); cmd = "L"
        elif cmd == "L":
            x, y = float(toks[k]), float(toks[k + 1]); k += 2
            out.append("-- " + pt(x, y))
        elif cmd == "H":
            x = float(toks[k]); k += 1
            out.append("-- " + pt(x, y))
        elif cmd == "V":
            y = float(toks[k]); k += 1
            out.append("-- " + pt(x, y))
        elif cmd == "C":
            a = [float(t) for t in toks[k:k + 6]]; k += 6
            x, y = a[4], a[5]
            out.append(".. controls %s and %s .. %s" % (pt(a[0], a[1]), pt(a[2], a[3]), pt(x, y)))
    # several subpaths (M ... M ...): TikZ starts a new one at a bare coordinate
    return " ".join(out)


def svg_tikz(svg):
    """One of the pages' SVG diagrams as a tikzpicture, its width the line's."""
    vb = [float(v) for v in re.search(r'viewBox="([^"]+)"', svg).group(1).split()]
    markers = {}
    for m in re.finditer(r'<marker id="([^"]+)".*?class="(arr\w)"', svg, re.S):
        markers[m.group(1)] = ARROW[m.group(2)]
    body = re.sub(r"<title.*?</title>|<defs>.*?</defs>", "", svg, flags=re.S)
    # on paper the fills are opaque: lifelines, then boxes, then the other lines, then the text
    layers = {"under": [], "box": [], "line": [], "text": []}
    for m in re.finditer(r"<(rect|path|polygon)\b([^>]*)/>|<(text)\b([^>]*)>(.*?)</text>", body, re.S):
        kind, a = m.group(1) or m.group(3), svg_attrs(m.group(2) or m.group(4))
        cls = a.get("class", "tx" if kind == "text" else "box")
        if kind == "rect":
            x, y, w, h = (float(a[k]) for k in ("x", "y", "width", "height"))
            layers["box"].append("\\path[%s] (%g,%g) rectangle (%g,%g);" % (cls, x, y, x + w, y + h))
        elif kind == "polygon":
            pts = [p.split(",") for p in a["points"].split()]
            layers["box"].append("\\path[%s] %s -- cycle;" % (cls, " -- ".join("(%s,%s)" % tuple(p) for p in pts)))
        elif kind == "path":
            arrow = ""
            if "marker-end" in a:
                mid = re.search(r"#([^)]+)", a["marker-end"]).group(1)
                arrow = ",-{Stealth[length=7pt,width=6pt,%s]}" % ("fill=" + markers[mid])
            layers["under" if cls in ("life", "lnd") else "line"].append("\\path[%s%s] %s;" % (cls, arrow, svg_path(a["d"])))
        else:
            text = html.unescape(re.sub(r"<[^>]+>", "", m.group(5)))
            layers["text"].append("\\node[%s] at (%s,%s) {%s};" % (cls, a["x"], a["y"], tex(text, cls in ("m", "mc", "ma", "h"))))
    out = ["\\resizebox{\\linewidth}{!}{%", "\\begin{tikzpicture}[x=1pt,y=-1pt," + TIKZ_STYLES + "]",
           "\\useasboundingbox (%g,%g) rectangle (%g,%g);" % (vb[0], vb[1], vb[0] + vb[2], vb[1] + vb[3])]
    for k in ("under", "box", "line", "text"):
        out += layers[k]
    out += ["\\end{tikzpicture}}", ""]
    return "\n".join(out)


def latex_outputs():
    """{file name: LaTeX} for the manual: the op tables and the diagrams."""
    tables, problems = build()
    if problems:
        raise SystemExit("web-os: " + "\n".join(problems))
    files = {}
    for key, (rows, system) in tables.items():
        files["gen-os-ops-%s.tex" % key] = latex_table(key, rows, system)
    for f in pages():
        with open(os.path.join(SITE, f)) as fh:
            for svg in re.findall(r"<svg.*?</svg>", fh.read(), re.S):
                name = re.search(r'aria-labelledby="(\w+)-t"', svg).group(1)
                files["gen-os-fig-%s.tex" % name] = "%% generated by tools/web-os.py from site/os/%s: do not edit\n" % f \
                    + svg_tikz(svg)
    return files


MARK = re.compile(r"(<!-- ops:([a-z]+) -->)(.*?)(<!-- /ops:\2 -->)", re.S)
PDFREF = re.compile(r'<a class="pdf" data-pdf="([^"]+)"[^>]*>.*?</a>', re.S)
PDF = "../Strata-Architecture-Reference-Manual.pdf"


def manual_labels():
    """The manual's labels with their numbers and PDF destinations (doc/manual/gen)."""
    sys.path.insert(0, os.path.join(ROOT, "doc", "manual", "gen"))
    import geninsns
    import tex2html
    return tex2html.Labels(geninsns.outputs())


def pdfref(m, labels, problems):
    lab = labels.get(m.group(1))
    if not lab:
        problems.append("no label %s in the manual" % m.group(1))
        return m.group(0)
    word = {"chapter": "Chapter", "section": "Section"}.get(lab["kind"], lab["kind"].capitalize())
    return '<a class="pdf" data-pdf="%s" href="%s#nameddest=%s">%s %s, %s</a>' % (
        m.group(1), PDF, lab["dest"], word, lab["num"], html.escape(lab["title"]))


def render(page, tables, labels=None, problems=None):
    page = MARK.sub(lambda m: m.group(1) + "\n" + table(m.group(2), *tables[m.group(2)]) + "\n" + m.group(4), page)
    if labels is not None:
        page = PDFREF.sub(lambda m: pdfref(m, labels, problems), page)
    return page


def pages():
    return sorted(f for f in os.listdir(SITE) if f.endswith(".html"))


def main(argv):
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    tables, problems = build()
    labels = manual_labels()
    shown = set()
    rendered = {}
    for f in pages():
        with open(os.path.join(SITE, f)) as fh:
            old = fh.read()
        shown |= {m.group(2) for m in MARK.finditer(old)}
        rendered[f] = (old, render(old, tables, labels, problems))
    for key in tables:
        if key not in shown:
            problems.append("no page of site/os/ shows the table %s (<!-- ops:%s --> ... <!-- /ops:%s -->)" % (key, key, key))
    for p in problems:
        print("web-os: " + p, file=sys.stderr)
    if argv[1] == "--check":
        # the manual's chapter takes every table and every diagram
        try:
            gen = latex_outputs()
        except (ValueError, SystemExit) as e:
            gen = {}
            problems.append("the manual's tables and diagrams cannot be made: %s" % e)
        with open(os.path.join(ROOT, "doc", "manual", "ch-os.tex")) as fh:
            chapter = fh.read()
        for name in sorted(gen):
            if "\\input{%s}" % name[:-4] not in chapter:
                problems.append("doc/manual/ch-os.tex does not \\input{%s}" % name[:-4])
                print("web-os: " + problems[-1], file=sys.stderr)
        stale = [f for f, (old, new) in rendered.items() if new != old]
        for f in stale:
            print("web-os: site/os/%s does not show what the sources answer (tools/web-os.py --write)" % f,
                  file=sys.stderr)
        if not problems and not stale:
            n = sum(len(r) for r, _ in tables.values())
            print("web-os: %d ops in %d tables, as the sources answer them" % (n, len(tables)))
        return 1 if problems or stale else 0
    if argv[1] == "--write":
        for f, (old, new) in rendered.items():
            if new != old:
                with open(os.path.join(SITE, f), "w") as fh:
                    fh.write(new)
                print("web-os: site/os/%s" % f)
        return 1 if problems else 0
    out = os.path.join(argv[1], "os")
    os.makedirs(out, exist_ok=True)
    for f in os.listdir(SITE):
        src = os.path.join(SITE, f)
        if f in rendered:
            with open(os.path.join(out, f), "w") as fh:
                fh.write(rendered[f][1])
        elif os.path.isfile(src):
            shutil.copy(src, os.path.join(out, f))
    for p in problems:      # the site is built anyway; the test (--check) fails on them
        print("::warning::web-os: " + p)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
