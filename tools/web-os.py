#!/usr/bin/env python3
"""web-os.py: the StrataOS pages' message specifications, and the manual's, from os/spec/.

Every message StrataOS answers is described field by field in os/spec/*.toml
(the format: os/spec/README.md); tools/osspec.py reads those files and checks
them against the code: the ops each server's dispatch answers, the OP_*
constants of os/lib/sys.s. This makes the pages from them:

  site/os/*.html  each spec between markers, <!-- ops:fs --> ... <!-- /ops:fs -->:
                  the server's facts, an index of its ops, and an entry per op
                  (request, reply, errors, the data's fields with their offsets)
  the manual      latex_outputs() gives doc/manual/gen/geninsns.py (which writes
                  every gen-*.tex of the manual) gen-os-ops-KEY.tex, the same
                  for the StrataOS chapter, and gen-os-fig-NAME.tex, each SVG
                  diagram of the pages as a TikZ picture (NAME is the prefix of
                  its title's id: <title id="cm-t"> is gen-os-fig-cm.tex)

  web-os.py OUTDIR    the pages, made afresh, into OUTDIR/os/ (the site's build)
  web-os.py --write   make the pages of site/os/ afresh in place
  web-os.py --check   exit 1 if a spec disagrees with the code, if site/os/*.html
                      does not show what the specs say (run --write), or if the
                      manual's chapter (doc/manual/ch-os.tex) leaves out one of
                      the specs or diagrams
"""
import html
import os
import re
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import osspec  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = os.path.join(ROOT, "site", "os")
CODE = "../code/#"

# key, title, dispatch (file, first line, last line: regular expressions),
# files whose comments document the ops
# the manual's table of each spec: label, caption
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
    "system": ("tab:os-sysops", "Messages from \\texttt{proc} to the servers, and from the kernel to \\texttt{proc}"),
}
ERRORS = {-1: "failed", -2: "interrupted", -3: "would block", -4: "no such file or program",
          -5: "no free core / not allowed", -6: "no memory", -7: "busy", -8: "timed out"}
HEADER = (("handle", "handle"), ("length", "length"), ("mode", "mode"))


def build():
    """[spec] in the order of the pages, and the problems found (os/spec/, tools/osspec.py)."""
    specs, problems = [], []
    for spec, p in osspec.load_all():
        specs.append(spec)
        problems += p
    return specs, problems


def field_rows(fields, base):
    """Rows (key, at, type, text) of a data layout; offsets while the sizes are fixed."""
    rows, at = [], base
    for fd in fields:
        if "repeat" in fd:
            rows.append(("", "", "", "%s:" % fd["repeat"] + (" " + fd["note"] if fd.get("note") else "")))
            sub = field_rows(fd["fields"], 0)
            rows += [(k, ("  " + a) if a != "" else "", t, x) for (k, a, t, x) in sub]
            at = None
            continue
        size = osspec.TYPES[fd["type"]]
        text = fd.get("name", "padding to the next multiple of 8") + (" — " + fd["note"] if fd.get("note") else "")
        rows.append(("", "+%d" % at if at is not None else "", fd["type"], text))
        at = at + size if (at is not None and size) else None
    return rows


def sections(spec, op):
    """An op as sections of rows: [(title, [(key, at, type, text)])]."""
    out = []
    for part, title in (("request", "request"), ("reply", "reply")):
        t = op.get(part, {})
        rows = []
        if part == "reply" and "result" in t:
            rows.append(("a0" if spec["server"]["calls"] == "svc" else "result", "", "", t["result"]))
        for reg, text in t.get("regs", {}).items():
            rows.append((reg, "", "", text))
        for word, key in HEADER:
            if word in t:
                rows.append((key, "", "", t[word]))
            if word == "mode":
                for v, text in t.get("modes", {}).items():
                    rows.append(("mode %s" % v, "", "", text))
        if "attachment" in t:
            rows.append(("attached", "", "", t["attachment"]))
        for reg, text in t.get("attachments", {}).items():
            rows.append((reg, "", "", text))
        if t.get("data"):
            drows = field_rows(t["data"], 0)
            drows[0] = ("data",) + drows[0][1:]
            rows += drows
        if t.get("note"):
            rows.append(("", "", "", t["note"]))
        if not rows:
            rows.append(("", "", "", "nothing" if part == "request" else "—"))
        out.append((title, rows))
    errs = [(code, "", "", text) for code, text in sorted(op.get("errors", {}).items(), key=lambda e: -int(e[0]))]
    if errs:
        out.append(("errors", errs))
    return out


def handler_link(spec, op):
    """The source line of an op's handler (from the dispatch), for the source browser."""
    d = spec["server"].get("dispatch")
    if not d:
        return None
    consts = osspec.constants(["os/lib/sys.s", "os/lib/srv.s", d["file"]] + spec["server"].get("sources", []))
    ops = osspec.dispatch(d["file"], d["first"], d["last"], consts)
    lab = ops.get(op["num"], (None, 0))[0]
    where = osspec.label_line([d["file"]] + spec["server"].get("sources", []), lab) if lab else None
    return where or (d["file"], ops.get(op["num"], (None, 1))[1])


def inline(text):
    """Text -> HTML: escaped, `code`, the arrow."""
    t = html.escape(text).replace("-&gt;", "&rarr;")
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", t)


def facts_html(spec):
    s = spec["server"]
    out = ['<div class="facts2">']
    for k, title in (("core", "core"), ("holds", "holds"), ("reached", "reached by")):
        if s.get(k):
            out.append("<div><b>%s</b>%s</div>" % (title, inline(s[k])))
    if s.get("sources"):
        out.append("<div><b>source</b>%s</div>" % ", ".join(
            '<a class="srcpath" href="%s%s">%s</a>' % (CODE, p, p) for p in s["sources"]))
    out.append("</div>")
    return "\n".join(out)


def spec_html(spec, system=()):
    key = spec["server"]["key"]
    out = []
    if key not in ("svc", "kernel", "system"):
        out.append(facts_html(spec))
    if spec["server"].get("note"):
        out.append('<p class="srvnote">%s</p>' % inline(spec["server"]["note"]))
    out.append('<div class="opindex">')
    for op in spec["op"]:
        out.append('<a href="#%s-%d"><span class="n">%d</span><code>%s</code><span>%s</span></a>'
                   % (key, op["num"], op["num"], op["name"], inline(op["summary"])))
    out.append("</div>")
    for op in spec["op"]:
        link = handler_link(spec, op)
        name = ('<a class="opname" href="%s%s:%d"><code>%s</code></a>' % (CODE, link[0], link[1], op["name"])
                if link else "<code>%s</code>" % op["name"])
        out.append('<article class="op" id="%s-%d">' % (key, op["num"]))
        out.append('<h4><span class="n">%d</span>%s<span class="sum">%s</span>%s</h4>'
                   % (op["num"], name, inline(op["summary"]),
                      '<span class="from">%s</span>' % inline(op["from"]) if op.get("from") else ""))
        if op.get("note"):
            out.append("<p>%s</p>" % inline(op["note"]))
        out.append('<div class="optable"><table>')
        for title, rows in sections(spec, op):
            out.append('<tbody class="%s"><tr class="sec"><th colspan="4">%s</th></tr>' % (title, title))
            for k, at, typ, text in rows:
                kcell = ('<abbr title="%s">%s</abbr>' % (ERRORS.get(int(k), ""), k.replace("-", "−"))
                         if title == "errors" else inline(k))
                out.append('<tr><td class="k">%s</td><td class="at">%s</td><td class="ty">%s</td><td>%s</td></tr>'
                           % (kcell, html.escape(at), html.escape(typ), inline(text)))
            out.append("</tbody>")
        out.append("</table></div></article>")
    if system:
        out.append('<p class="sysops">Its dispatch also answers %s (<a href="#system">below</a>).</p>'
                   % ", ".join("%d %s" % (n, {36: "DUPS", 37: "CLEANUP", 38: "CANCEL"}[n]) for n in system))
    return "\n".join(out)


# ---------------------------------------------------------------- the manual (LaTeX)
UNI = {"·": r"\textperiodcentered{}", "–": r"\textendash{}", "—": r"\textemdash{}", "→": r"$\rightarrow$", "←": r"$\leftarrow$",
       "↔": r"$\leftrightarrow$", "…": r"\ldots{}", "−": "$-$", "×": r"$\times$", "≤": r"$\le$", "≥": r"$\ge$", "µ": r"$\mu$", "×": r"$\times$"}
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
    t = re.sub(r"`([^`]+)`", r"\1" if mono else r"\\texttt{\1}", t)     # `code`
    if mono:
        t = t.replace('"', r"\textquotedbl{}")
    else:
        t = re.sub(r'(^|[\s(\[])"', r"\1``", t).replace('"', "''")     # "ws": opening and closing quotes
    return t


def latex_spec(spec, system=()):
    """A spec for the manual: a summary table (the label the chapter refers to), then an
    entry per op with its request, reply and errors, row by row."""
    key = spec["server"]["key"]
    label, caption = LATEX[key]
    t = "%% generated by tools/web-os.py from os/spec/%s.toml: do not edit\n" % key
    if spec["server"].get("note"):
        t += tex(spec["server"]["note"]) + "\n\n"
    t += "\\begin{small}\n\\begin{longtable}{@{}r>{\\ttfamily}l>{\\raggedright\\arraybackslash}p{0.7\\linewidth}@{}}\n"
    t += "\\caption{%s}\\label{%s}\\\\\n\\toprule\n" % (caption, label)
    hdr = "\\textbf{%s} & \\textrm{\\bfseries Name} & \\textbf{What it does}\\\\\\midrule\n" % (
        "\\reg{a0}" if spec["server"]["calls"] == "svc" else "Op")
    t += hdr + "\\endfirsthead\n\\toprule\n" + hdr + "\\endhead\n\\bottomrule\n\\endfoot\n"
    for op in spec["op"]:
        t += "%d & %s & %s\\\\\n" % (op["num"], tex(op["name"], True), tex(op["summary"]))
    t += "\\end{longtable}\n"
    if system:
        t += "\\vspace{-1.5ex}\\noindent{\\footnotesize Its dispatch also answers %s (Table~\\ref{tab:os-sysops}).}\n" % (
            ", ".join("%d %s" % (n, {36: "DUPS", 37: "CLEANUP", 38: "CANCEL"}[n]) for n in system))
    t += "\\end{small}\n\n"
    for op in spec["op"]:
        t += "\\osop{%d}{%s}{%s}{%s}\n" % (op["num"], tex(op["name"], True), tex(op["summary"]),
                                           tex(op["from"]) if op.get("from") else "")
        if op.get("note"):
            t += "{\\small %s}\\par\n" % tex(op["note"])
        t += "\\begin{osfields}\n"
        for title, rows in sections(spec, op):
            t += "\\osfsec{%s}\n" % title
            for k, at, typ, text in rows:
                kk = ("$%s$" % k.replace("-", "-")) if title == "errors" else tex(k, True)
                t += "%s & %s & %s & %s\\\\\n" % (kk, tex(at.strip(), True), tex(typ, True), tex(text))
        t += "\\end{osfields}\n\n"
    return t


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
    """{file name: LaTeX} for the manual: the specs and the diagrams."""
    specs, problems = build()
    if problems:
        raise SystemExit("web-os: " + "\n".join(problems))
    files = {}
    for spec in specs:
        files["gen-os-ops-%s.tex" % spec["server"]["key"]] = latex_spec(spec, osspec.system_ops_of(spec))
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


def render(page, specs, labels=None, problems=None):
    by = {sp["server"]["key"]: sp for sp in specs}
    page = MARK.sub(lambda m: m.group(1) + "\n" + spec_html(by[m.group(2)], osspec.system_ops_of(by[m.group(2)]))
                    + "\n" + m.group(4), page)
    if labels is not None:
        page = PDFREF.sub(lambda m: pdfref(m, labels, problems), page)
    return page


def pages():
    return sorted(f for f in os.listdir(SITE) if f.endswith(".html"))


def main(argv):
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    specs, problems = build()
    labels = manual_labels()
    shown = set()
    rendered = {}
    for f in pages():
        with open(os.path.join(SITE, f)) as fh:
            old = fh.read()
        shown |= {m.group(2) for m in MARK.finditer(old)}
        rendered[f] = (old, render(old, specs, labels, problems))
    for key in (sp["server"]["key"] for sp in specs):
        if key not in shown:
            problems.append("no page of site/os/ shows the table %s (<!-- ops:%s --> ... <!-- /ops:%s -->)" % (key, key, key))
    for p in problems:
        print("web-os: " + p, file=sys.stderr)
    if argv[1] == "--check":
        # the manual's chapter takes every table and every diagram
        try:
            gen = latex_outputs()
        except (ValueError, KeyError, SystemExit) as e:
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
            n = sum(len(sp["op"]) for sp in specs)
            print("web-os: %d ops of %d specs, as the code answers them, on the pages and in the manual" % (n, len(specs)))
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
