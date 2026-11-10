"""tex2html: the manual's LaTeX, as far as the website needs it, in HTML.

Used by gen/genweb.py. It understands the subset the manual is written in:
the house macros of strata-manual.sty (\\insn, \\reg, \\cause, \\perm, ...),
inline math, tabular/tabularx, itemize/enumerate/description, the pseudo
and asm listings, and the encoding diagrams. It also numbers the manual
the way LaTeX does (book class: chapters, sections, tables, figures,
appendices; instruction entries are sections), so a cross-reference on
the web reads "Section 3.4" exactly as in the PDF and links either to the
web page that has the target or to the PDF's named destination.
"""
import html
import os
import re

MANUAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")

VERBATIM = ("asm", "pseudo", "syntax", "shell", "lstlisting", "verbatim")


def esc(s):
    return html.escape(s, quote=True)


def strip_comments(s):
    """Drops % comments (keeps \\%) outside verbatim environments."""
    out, verb = [], None
    for line in s.split("\n"):
        if verb:
            out.append(line)
            if re.search(r"\\end\{%s\}" % verb, line):
                verb = None
            continue
        m = re.search(r"\\begin\{(%s)\}" % "|".join(VERBATIM), line)
        if m and not re.search(r"\\end\{%s\}" % m.group(1), line):
            verb = m.group(1)
        out.append(re.sub(r"(?<!\\)%.*", "", line) if not m else line)
    return "\n".join(out)


def group(s, i):
    """s[i] == '{': returns (content, index after the closing brace)."""
    assert s[i] == "{", s[i:i + 40]
    depth, j = 0, i
    while j < len(s):
        c = s[j]
        if c == "\\":
            j += 2
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return s[i + 1:j], j + 1
        j += 1
    raise ValueError("unbalanced braces: " + s[i:i + 60])


def opt(s, i):
    """Skips an optional [..] argument at i (after spaces); returns (content or None, index)."""
    j = i
    while j < len(s) and s[j] in " \t":
        j += 1
    if j < len(s) and s[j] == "[":
        depth, k = 0, j
        while k < len(s):
            if s[k] == "[":
                depth += 1
            elif s[k] == "]":
                depth -= 1
                if depth == 0:
                    return s[j + 1:k], k + 1
            elif s[k] == "{":
                _, k = group(s, k)
                continue
            k += 1
    return None, i


def args(s, i, n):
    """Reads n mandatory {..} arguments starting at i (spaces allowed between)."""
    out = []
    for _ in range(n):
        while i < len(s) and s[i] in " \t\n":
            i += 1
        if i < len(s) and s[i] == "{":
            a, i = group(s, i)
        else:                       # a single token argument
            a, i = s[i], i + 1
        out.append(a)
    return out, i


def split_top(s, sep):
    """Splits s at top-level (brace depth 0) occurrences of the string sep."""
    parts, depth, cur, i = [], 0, 0, 0
    while i < len(s):
        c = s[i]
        if c == "\\" and not s.startswith(sep, i):
            i += 2
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
        elif depth == 0 and s.startswith(sep, i):
            parts.append(s[cur:i])
            i += len(sep)
            cur = i
            continue
        i += 1
    parts.append(s[cur:])
    return parts


# ---------------------------------------------------------------- numbering
def roman(n):
    out = ""
    for v, r in ((10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")):
        while n >= v:
            out, n = out + r, n - v
    return out


class Labels:
    """Every \\label of the manual with its number, kind, title and PDF
    destination, found by walking main.tex the way LaTeX would."""

    def __init__(self, generated):
        self.generated = generated      # {gen-*.tex name: text} from geninsns.outputs()
        self.lab = {}                   # label -> dict(num, kind, title, dest, chapter)
        self.part = 0
        self.chap = 0
        self.appendix = False
        self.main = True
        self.sec = self.sub = 0
        self.tab = self.fig = 0
        self.cur = None                 # what a \label refers to now
        self.secdest = "chapter.1"      # PDF destination of the enclosing section
        self.sections = []              # every numbered heading, labelled or not
        self.chapter_label = None
        root = read(os.path.join(MANUAL, "main.tex"))
        self.walk(root, "main.tex")

    def chapnum(self):
        return chr(ord("A") + self.chap - 1) if self.appendix else str(self.chap)

    def source(self, name):
        if name in self.generated:
            return self.generated[name]
        return read(os.path.join(MANUAL, name))

    def walk(self, s, fname):
        s = strip_comments(s)
        tok = re.compile(r"\\(frontmatter|mainmatter|appendix|part|chapter|section|subsection|subsubsection"
                         r"|input|caption|label|begin|end)\b(\*?)")
        i = 0
        while True:
            m = tok.search(s, i)
            if not m:
                return
            cmd, star, i = m.group(1), m.group(2), m.end()
            if cmd == "frontmatter":
                self.main = False
            elif cmd == "mainmatter":
                self.main = True
            elif cmd == "appendix":
                self.appendix, self.chap = True, 0
            elif cmd == "input":
                (name,), i = args(s, i, 1)
                name = name if name.endswith(".tex") else name + ".tex"
                self.walk(self.source(name), name)
            elif cmd == "begin":
                (env,), i = args(s, i, 1)
                if env in VERBATIM:
                    e = s.find("\\end{%s}" % env, i)
                    i = e + len("\\end{%s}" % env)
                elif env == "instruction":
                    (mn, title, key), i = args(s, i, 3)
                    self.sec += 1
                    self.sub = 0
                    num = "%s.%d" % (self.chapnum(), self.sec)
                    self.cur = dict(num=num, kind="section", title=mn, dest="section." + num,
                                    chapter=self.chapter_label, file=fname)
                    self.lab["insn:" + key] = dict(self.cur)
                    self.secdest = self.cur["dest"]
                elif env in ("table", "figure", "longtable"):
                    self.float_env = env
            elif cmd == "end":
                (env,), i = args(s, i, 1)
            elif cmd == "caption":
                _, i = opt(s, i)
                (cap,), i = args(s, i, 1)
                kind = "figure" if getattr(self, "float_env", "table") == "figure" else "table"
                if kind == "figure":
                    self.fig += 1
                    n = self.fig
                else:
                    self.tab += 1
                    n = self.tab
                num = "%s.%d" % (self.chapnum(), n)
                # hyperref names float anchors by a running caption counter; link to the
                # enclosing section instead, which has a stable name
                self.cur = dict(num=num, kind=kind, title=cap, dest=self.secdest,
                                chapter=self.chapter_label, file=fname)
            elif cmd == "label":
                (lab,), i = args(s, i, 1)
                if self.cur is not None:
                    self.lab[lab] = dict(self.cur)
                    if self.cur["kind"] == "chapter" and self.chapter_label is None:
                        self.chapter_label = lab
                        self.lab[lab]["chapter"] = lab
            else:                       # sectioning
                _, i = opt(s, i)
                (title,), i = args(s, i, 1)
                if star:
                    continue
                if cmd == "part":
                    self.part += 1
                    num = roman(self.part)
                    self.cur = dict(num=num, kind="part", title=title, dest="part.%d" % self.part,
                                    chapter=None, file=fname)
                elif cmd == "chapter":
                    if not self.main:
                        self.cur = None
                        continue
                    self.chap += 1
                    self.sec = self.sub = self.tab = self.fig = 0
                    num = self.chapnum()
                    dest = ("appendix." if self.appendix else "chapter.") + num
                    self.cur = dict(num=num, kind="chapter", appendix=self.appendix, title=title,
                                    dest=dest, chapter=None, file=fname)
                    self.chapter_label = None
                elif cmd == "section":
                    self.sec += 1
                    self.sub = 0
                    num = "%s.%d" % (self.chapnum(), self.sec)
                    self.cur = dict(num=num, kind="section", title=title, dest="section." + num,
                                    chapter=self.chapter_label, file=fname)
                elif cmd == "subsection":
                    self.sub += 1
                    num = "%s.%d.%d" % (self.chapnum(), self.sec, self.sub)
                    self.cur = dict(num=num, kind="section", title=title, dest="subsection." + num,
                                    chapter=self.chapter_label, file=fname)
                # \subsubsection is unnumbered (secnumdepth 2): labels keep the subsection
                if self.cur is not None:
                    self.secdest = self.cur["dest"]
                    self.sections.append(self.cur)

    def get(self, lab):
        if lab not in self.lab:
            raise KeyError("unknown label " + lab)
        return self.lab[lab]


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


# ---------------------------------------------------------------- inline
REL = "≠≥≤≪≫≈∈∉→←×÷±∪∩·"
MATH_SYM = {
    "neq": "≠", "ne": "≠", "geq": "≥", "ge": "≥", "leq": "≤", "le": "≤", "div": "÷", "bmod": " mod ",
    "pm": "±", "times": "×", "to": "→", "cup": "∪", "cap": "∩", "ldots": "…", "cdots": "⋯", "cdot": "·",
    "ll": "≪", "gg": "≫", "mid": " | ", "approx": "≈", "mu": "μ", "log": "log", "infty": "∞",
    "quad": "\u2003", ",": "\u2009", ";": " ", "!": "", " ": " ", "lbrace": "{", "rbrace": "}",
    "{": "{", "}": "}", "_": "_", "%": "%", "&": "&amp;", "#": "#", "rightarrow": "→", "leftarrow": "←",
    "in": "∈", "notin": "∉", "lfloor": "⌊", "rfloor": "⌋", "alpha": "α", "beta": "β",
}
TEXT_SYM = {
    "ldots": "…", "dots": "…", "textbackslash": "\\", "textasciitilde": "~", "textasciicircum": "^",
    "%": "%", "&": "&amp;", "#": "#", "_": "_", "$": "$", "{": "{", "}": "}", " ": " ", ",": "\u2009",
    "\\": "<br>", "IS": "Strata", "S": "§", "qquad": "\u2003\u2003", "quad": "\u2003", "slash": "/",
    "textendash": "–", "textemdash": "—", "LaTeX": "LaTeX", "TeX": "TeX", "-": "", "/": "",
    "textregistered": "®", "copyright": "©", "textbar": "|", "textless": "&lt;", "textgreater": "&gt;",
}
# commands that take one argument and wrap it
WRAP = {
    "insn": ('<code class="insn">', "</code>"), "reg": ('<code class="reg">', "</code>"),
    "csr": ('<code class="csr">', "</code>"), "cause": ('<span class="cause">', "</span>"),
    "perm": ('<span class="perm">', "</span>"), "field": ('<i class="field">', "</i>"),
    "term": ('<b class="term">', "</b>"), "texttt": ("<code>", "</code>"), "textit": ("<i>", "</i>"),
    "emph": ("<em>", "</em>"), "textbf": ("<b>", "</b>"), "textsf": ('<span class="sf">', "</span>"),
    "textrm": ('<span class="rm">', "</span>"), "textsc": ('<span class="sc">', "</span>"),
    "mbox": ("", ""), "makebox": ("", ""), "text": ("", ""), "underline": ("<u>", "</u>"),
    "textsuperscript": ("<sup>", "</sup>"), "makecell": ("", ""), "nolinkurl": ("<code>", "</code>"),
}
# switches: the rest of the group gets a style
SWITCH = {"bfseries": ("<b>", "</b>"), "ttfamily": ("<code>", "</code>"), "itshape": ("<i>", "</i>"),
          "sffamily": ('<span class="sf">', "</span>"), "rmfamily": ("", ""), "scshape": ("", ""),
          "small": ("", ""), "footnotesize": ("", ""), "scriptsize": ("", ""), "normalsize": ("", ""),
          "large": ("", ""), "Large": ("", ""), "huge": ("", ""), "centering": ("", ""),
          "raggedright": ("", ""), "arraybackslash": ("", ""), "strut": ("", ""), "noindent": ("", ""),
          "nobreak": ("", ""), "par": ("", ""), "hfill": ("", ""), "qedbox": ("", ""), "smallskip": ("", ""),
          "medskip": ("", ""), "bigskip": ("", ""), "xspace": ("", ""), "protect": ("", "")}
DROP1 = {"label", "vspace", "hspace", "index", "color", "pageref", "needspace", "Needspace", "phantom"}
REF_WORDS = r"(Section|Sections|Table|Tables|Chapter|Chapters|Appendix|Figure|Part|Theorem)"


class Ctx:
    """How to resolve references: labels, and where each label is shown on the web."""

    def __init__(self, labels, here, anchors, pdf, insn_href):
        self.labels = labels
        self.here = here            # this page's name ("isa" or "arch")
        self.anchors = anchors      # {label: (page, id)} for targets present on the web
        self.pdf = pdf              # URL of the PDF, relative to this page
        self.insn_href = insn_href  # key -> URL of an instruction entry

    def href(self, lab):
        if lab.startswith("insn:"):
            return self.insn_href(lab[5:])
        if lab in self.anchors:
            page, ident = self.anchors[lab]
            return ("#" if page == self.here else "../%s/#" % page) + ident
        return "%s#nameddest=%s" % (self.pdf, self.labels.get(lab)["dest"])

    def ref(self, lab, word=""):
        info = self.labels.get(lab)
        num = info["num"]
        if word == "Chapter" and info.get("appendix"):
            word = "Appendix"
        text = (word + "\u00a0" if word and word != "§" else word) + num
        cls = ' class="pdf"' if "nameddest" in self.href(lab) else ""
        return '<a href="%s"%s>%s</a>' % (esc(self.href(lab)), cls, text)


def tex_to_html(s, ctx, math=False):
    """Inline LaTeX to HTML."""
    s = re.sub(REF_WORDS + r"~\\ref\{([^}]*)\}", lambda m: "\\xref{%s}{%s}" % (m.group(1), m.group(2)), s)
    s = re.sub(r"\\S\s*\\ref\{([^}]*)\}", lambda m: "\\xref{§}{%s}" % m.group(1), s)
    return _conv(s, ctx, math)


def _conv(s, ctx, math):
    out = []
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == "\\":
            m = re.match(r"\\([A-Za-z]+)\*?|\\(.)", s[i:])
            name = m.group(1) or m.group(2)
            i += m.end()
            ate = False
            if m.group(1):              # a control word eats the spaces after it
                while i < n and s[i] in " \t\n":
                    i += 1
                    ate = True
            if name == "xref":
                (word, lab), i = args(s, i, 2)
                out.append(ctx.ref(lab, word))
            elif name == "ref":
                (lab,), i = args(s, i, 1)
                out.append(ctx.ref(lab))
            elif name == "insref":
                (k,), i = args(s, i, 1)
                out.append('<a href="%s"><code class="insn">%s</code></a>' % (esc(ctx.insn_href(k)), esc(k)))
            elif name == "hyperref":
                lab, i = opt(s, i)
                (body,), i = args(s, i, 1)
                out.append('<a href="%s">%s</a>' % (esc(ctx.href(lab)), _conv(body, ctx, math)))
            elif name == "href":
                (url, body), i = args(s, i, 2)
                out.append('<a href="%s">%s</a>' % (esc(url), _conv(body, ctx, math)))
            elif name == "url":
                (url,), i = args(s, i, 1)
                out.append('<a href="%s"><code>%s</code></a>' % (esc(url), esc(url)))
            elif name == "hex":
                (h,), i = args(s, i, 1)
                out.append("<code>0x%s</code>" % esc(h))
            elif name in ("planned", "estimate"):
                out.append('<span class="tag">[%s]</span>' % name)
            elif name == "mathcal":
                (a,), i = args(s, i, 1)
                out.append({"S": "𝒮"}.get(a, a))
            elif name == "multicolumn":
                (_, _, body), i = args(s, i, 3)
                out.append(_conv(body, ctx, math))
            elif name in ("colorbox", "textcolor"):
                (_, body), i = args(s, i, 2)
                out.append(_conv(body, ctx, math))
            elif name in WRAP:
                if name == "makebox":
                    _, i = opt(s, i)
                (a,), i = args(s, i, 1)
                o, e = WRAP[name]
                out.append(o + _conv(a, ctx, math and name not in ("text", "texttt", "textit", "mbox")) + e)
            elif name in DROP1:
                (_,), i = args(s, i, 1)
            elif name in SWITCH:
                o, e = SWITCH[name]
                rest = _conv(s[i:], ctx, math)
                out.append(o + rest + e)
                i = n
            elif math and name in MATH_SYM:
                v = MATH_SYM[name]
                out.append(" %s " % v if v in REL else v)
            elif name == "IS":          # \xspace: keeps the space it ate
                out.append("Strata" + (" " if ate else ""))
            elif name in TEXT_SYM:
                out.append(TEXT_SYM[name])
            elif name in MATH_SYM:
                out.append(MATH_SYM[name])
            elif name in ("item",):
                out.append("")
            else:
                raise ValueError("tex2html: unknown command \\%s in: %s" % (name, s[:120]))
        elif c == "{":
            body, i = group(s, i)
            out.append(_conv(body, ctx, math))
        elif c == "$" and not math:
            j = i + 1
            while j < n and not (s[j] == "$" and s[j - 1] != "\\"):
                j += 1
            m_html = re.sub(r" {2,}", " ", _conv(s[i + 1:j], ctx, True)).strip()
            out.append('<span class="m">%s</span>' % m_html)
            i = j + 1
        elif math and c in "^_":
            i += 1
            if s[i] == "{":
                body, i = group(s, i)
            else:
                body, i = s[i], i + 1
            tag = "sup" if c == "^" else "sub"
            out.append("<%s>%s</%s>" % (tag, _conv(body, ctx, True), tag))
        elif math and c.isalpha():
            j = i
            while j < n and s[j].isalpha():
                j += 1
            w = s[i:j]
            out.append("<i>%s</i>" % w if len(w) == 1 else w)
            i = j
        elif math and c == "-":
            out.append("\u2212")
            i += 1
        elif math and c in " \t\n":
            i += 1
            if out and not out[-1].endswith(" "):
                out.append(" ")
        elif c == "~":
            out.append("\u00a0")
            i += 1
        elif s.startswith("---", i):
            out.append("—")
            i += 3
        elif s.startswith("--", i):
            out.append("–")
            i += 2
        elif s.startswith("``", i):
            out.append("“")
            i += 2
        elif s.startswith("''", i):
            out.append("”")
            i += 2
        elif c == "\n":
            out.append(" ")
            i += 1
        else:
            j = i
            while j < n and s[j] not in "\\{}$~-`'\n^_" and not (math and (s[j].isalpha() or s[j] in " \t")):
                j += 1
            if j == i:
                j = i + 1
            out.append(esc(s[i:j]))
            i = j
    return "".join(out)


# ---------------------------------------------------------------- blocks
ENV_RE = re.compile(r"\\begin\{([A-Za-z*]+)\}")


def env_body(s, i, env):
    """s[i:] starts just after \\begin{env}; returns (body, index after \\end{env})."""
    if env in VERBATIM:
        e = s.index("\\end{%s}" % env, i)
        return s[i:e], e + len("\\end{%s}" % env)
    depth, j = 1, i
    pat = re.compile(r"\\(begin|end)\{%s\}" % re.escape(env))
    while True:
        m = pat.search(s, j)
        if not m:
            raise ValueError("unterminated " + env)
        depth += 1 if m.group(1) == "begin" else -1
        if depth == 0:
            return s[i:m.start()], m.end()
        j = m.end()


def items(body):
    """Splits a list body at top-level \\item; returns [(label or None, text)]."""
    out, depth, i, starts = [], 0, 0, []
    pat = re.compile(r"\\(begin|end)\{[^}]*\}|\\item\b")
    for m in pat.finditer(body):
        t = m.group(0)
        if t.startswith("\\begin"):
            depth += 1
        elif t.startswith("\\end"):
            depth -= 1
        elif depth == 0:
            starts.append(m.start())
    for k, st in enumerate(starts):
        en = starts[k + 1] if k + 1 < len(starts) else len(body)
        chunk = body[st + len("\\item"):en]
        lab, j = opt(chunk, 0)
        out.append((lab, chunk[j:].strip()))
    return out


def blocks(s, ctx):
    """A run of LaTeX body text (paragraphs, lists, listings, tables) to HTML."""
    s = strip_comments(s).strip()
    out, i, para = [], 0, []

    def flush():
        text = "".join(para).strip()
        para.clear()
        for p in re.split(r"\n\s*\n", text):
            if p.strip():
                out.append("<p>%s</p>" % tex_to_html(p.strip(), ctx))

    while i < len(s):
        m = ENV_RE.search(s, i)
        if not m:
            para.append(s[i:])
            break
        para.append(s[i:m.start()])
        env = m.group(1)
        j = m.end()
        lopt = None
        if env in ("description", "itemize", "enumerate"):
            lopt, j = opt(s, j)
        elif env in ("rule*", "note"):
            pass
        body, i = env_body(s, j, env)
        flush()
        out.append(block_env(env, body, ctx, lopt))
    flush()
    return "\n".join(x for x in out if x)


def block_env(env, body, ctx, lopt=None):
    if env == "itemize":
        return "<ul>%s</ul>" % "".join("<li>%s</li>" % inner(t, ctx) for (_, t) in items(body))
    if env == "enumerate":
        cls = ' class="alph"' if lopt and "alph" in lopt else ""
        return "<ol%s>%s</ol>" % (cls, "".join("<li>%s</li>" % inner(t, ctx) for (_, t) in items(body)))
    if env == "description":
        return '<dl class="desc">%s</dl>' % "".join(
            "<dt>%s</dt><dd>%s</dd>" % (tex_to_html(l or "", ctx), inner(t, ctx)) for (l, t) in items(body))
    if env == "rule*":
        (title,), k = args(body, 0, 1)
        return rule_html(title, body[k:], ctx)
    if env == "note":
        title, k = opt(body, 0)
        return '<aside class="note"><b>%s.</b> %s</aside>' % (tex_to_html(title or "Note", ctx), inner(body[k:], ctx))
    if env == "pseudo":
        return pseudo_html(body)
    if env == "asm":
        return '<pre class="lst"><code class="language-strata-asm">%s</code></pre>' % esc(dedent(body))
    if env == "shell":
        return '<pre class="lst"><code>%s</code></pre>' % esc(dedent(body))
    if env == "center":
        return blocks(body, ctx)
    if env in ("tabular", "tabularx"):
        return tabular_html(env, body, ctx)
    if env == "encoding":
        return encoding_html(parse_encoding(body))
    raise ValueError("tex2html: unsupported environment " + env)


def inner(t, ctx):
    """List-item or box text: one paragraph inline, several as blocks."""
    h = blocks(t, ctx)
    if h.count("<p>") == 1 and h.startswith("<p>") and h.endswith("</p>"):
        return h[3:-4]
    return h


def rule_html(title, body, ctx):
    return ('<div class="rule"><p class="rule-t">%s</p>%s</div>' % (tex_to_html(title, ctx), blocks(body, ctx)))


def dedent(text):
    lines = text.strip("\n").split("\n")
    return "\n".join(l.rstrip() for l in lines)


# ---------------------------------------------------------------- pseudocode
def pseudo_keywords():
    """The keyword lists of the pseudo listing language, from strata-manual.sty."""
    sty = read(os.path.join(MANUAL, "strata-manual.sty"))
    m = re.search(r"\\lstdefinelanguage\{pseudo\}\{(.*?)\n\}", sty, re.S)
    body = m.group(1)
    k1 = re.search(r"morekeywords=\{([^}]*)\}", body).group(1)
    k2 = re.search(r"morekeywords=\[2\]\{([^}]*)\}", body).group(1)
    norm = lambda t: {w.strip() for w in t.replace("\n", " ").split(",") if w.strip()}
    return norm(k1), norm(k2)


_PK = None


def pseudo_html(text):
    global _PK
    if _PK is None:
        _PK = pseudo_keywords()
    k1, k2 = _PK
    out = []
    for line in dedent(text).split("\n"):
        code, com = line, ""
        if "//" in line:
            p = line.index("//")
            code, com = line[:p], line[p:]
        o = re.sub(r"[A-Za-z_][A-Za-z0-9_]*|[^A-Za-z_]+",
                   lambda m: ('<b class="k1">%s</b>' % esc(m.group(0)) if m.group(0) in k1 else
                              '<span class="k2">%s</span>' % esc(m.group(0)) if m.group(0) in k2 else
                              esc(m.group(0))), code)
        if com:
            o += '<span class="c">%s</span>' % esc(com)
        out.append(o)
    return '<pre class="pseudo">%s</pre>' % "\n".join(out)


# ---------------------------------------------------------------- tables
def colspec(spec):
    """A tabular column specification to a list of per-column classes."""
    cols, pre, i = [], "", 0
    spec = spec.replace(" ", "")
    while i < len(spec):
        c = spec[i]
        if c == "@" or c == "!":
            _, i = group(spec, i + 1)
            continue
        if c == ">":
            p, i = group(spec, i + 1)
            pre += p
            continue
        if c == "<":
            _, i = group(spec, i + 1)
            continue
        if c == "*":
            (cnt, rep), i = args(spec, i + 1, 2)
            spec = spec[:i] + rep * int(cnt) + spec[i:]
            continue
        if c in "lcrXp":
            cls = []
            if "ttfamily" in pre:
                cls.append("tt")
            if "sffamily" in pre:
                cls.append("sf")
            if c == "c" or "centering" in pre:
                cls.append("ctr")
            if c == "r":
                cls.append("rgt")
            cols.append(" ".join(cls))
            pre = ""
            i += 1
            if c == "p":
                _, i = group(spec, i)
            continue
        i += 1
    return cols


def tabular_html(env, body, ctx, caption=None, ident=None, number=None):
    i = 0
    if env == "tabularx":
        (_,), i = args(body, i, 1)
    (spec,), i = args(body, i, 1)
    cols = colspec(spec)
    rows = split_top(body[i:], "\\\\")
    head, rows_out, in_head = [], [], True
    has_mid = "\\midrule" in body
    for r in rows:
        r = re.sub(r"^\s*\[[^\]]*\]", "", r)            # \\[2pt]
        mid = "\\midrule" in r or "\\hline" in r
        if mid and re.match(r"\s*\\(midrule|hline)", r):   # the rule ends the header before this row
            in_head = False
            mid = False
        r = re.sub(r"\\(toprule|midrule|bottomrule|hline|endfirsthead|endhead|endfoot|endlastfoot)\b", "", r)
        if not r.strip():
            if mid:
                in_head = False
            continue
        cells = split_top(r, "&")
        tds = []
        k = 0
        for c in cells:
            c = c.strip()
            span = 1
            mm = re.match(r"\\multicolumn\{(\d+)\}", c)
            if mm:
                span = int(mm.group(1))
            cls = cols[k] if k < len(cols) else ""
            tag = "th" if (in_head and has_mid) else "td"
            attrs = (' class="%s"' % cls if cls else "") + (' colspan="%d"' % span if span > 1 else "")
            tds.append("<%s%s>%s</%s>" % (tag, attrs, tex_to_html(c, ctx), tag))
            k += span
        (head if in_head and has_mid else rows_out).append("<tr>%s</tr>" % "".join(tds))
        if mid:
            in_head = False
    cap = ""
    if caption is not None:
        cap = "<caption>%s%s</caption>" % (
            ('<span class="tn">Table %s</span> ' % number) if number else "", tex_to_html(caption, ctx))
    return ('<div class="tbl"%s><table>%s%s<tbody>%s</tbody></table></div>' % (
        ' id="%s"' % ident if ident else "", cap,
        "<thead>%s</thead>" % "".join(head) if head else "", "".join(rows_out)))


# ---------------------------------------------------------------- encodings
def parse_encoding(body):
    """A \\begin{encoding} body (\\bitheader + \\fx/\\fv/\\fz boxes) to (hi, lo, label, kind) fields."""
    fields, hi = [], 31
    for m in re.finditer(r"\\f([xvz])\{(\d+)\}\{([^{}]*)\}", body):
        w = int(m.group(2))
        fields.append((hi, hi - w + 1, m.group(3), {"x": "f"}.get(m.group(1), m.group(1))))
        hi -= w
    assert hi == -1, body
    return fields


def encoding_html(lay):
    """An instruction word diagram: 32 equal columns, bit numbers above each field."""
    cells = []
    for (hi, lo, lab, kind) in lay:
        w = hi - lo + 1
        cls = {"f": "fx", "v": "fv", "z": "fz"}[kind]
        nums = ('<span class="bh">%d</span>' % hi if w == 1 else
                '<span class="bh"><span>%d</span><span>%d</span></span>' % (hi, lo))
        cells.append('<div class="bf %s" style="grid-column:span %d">%s<span class="bl">%s</span></div>'
                     % (cls, w, nums, esc(lab)))
    return '<div class="enc-w"><div class="enc" role="img" aria-label="%s">%s</div></div>' % (
        esc(" | ".join("%s %s" % (("%d:%d" % (h, l)) if h != l else str(h), lab) for (h, l, lab, _) in lay)),
        "".join(cells))


# ---------------------------------------------------------------- finding things in the sources
def chapter_source(name):
    return strip_comments(read(os.path.join(MANUAL, name)))


def find_float(labels, lab):
    """The table or figure environment carrying \\label{lab}: (env, body, caption)."""
    info = labels.get(lab)
    s = chapter_source(info["file"])
    p = s.index("\\label{%s}" % lab)
    b = max(s.rfind("\\begin{table}", 0, p), s.rfind("\\begin{figure}", 0, p))
    env = "figure" if s.startswith("\\begin{figure}", b) else "table"
    body, _ = env_body(s, b + len("\\begin{%s}" % env), env)
    return env, body, info


def table_by_label(labels, lab, ctx):
    env, body, info = find_float(labels, lab)
    m = re.search(r"\\begin\{(tabularx|tabular)\}", body)
    tb, _ = env_body(body, m.end(), m.group(1))
    ident = lab.replace(":", "-")
    return tabular_html(m.group(1), tb, ctx, caption=info["title"], ident=ident, number=info["num"])


def tabular_by_header(fname, header, ctx):
    """The first tabular in a chapter file whose first header cell is `header`
    (`header#n`: the n-th such tabular)."""
    header, _, nth = header.partition("#")
    nth = int(nth or 1)
    s = chapter_source(fname)
    for m in re.finditer(r"\\begin\{(tabularx|tabular)\}", s):
        tb, _ = env_body(s, m.end(), m.group(1))
        k = 0
        if m.group(1) == "tabularx":
            (_,), k = args(tb, 0, 1)
        (_,), k = args(tb, k, 1)
        first = re.sub(r"\\toprule|\\textbf|\\textrm|\\bfseries|[{}\s]", "", split_top(tb[k:], "&")[0])
        if first == header.replace(" ", ""):
            nth -= 1
            if nth == 0:
                return tabular_html(m.group(1), tb, ctx)
    raise KeyError("%s: no tabular headed %r" % (fname, header))


def rule_by_title(fname, title, ctx):
    s = chapter_source(fname)
    for m in re.finditer(r"\\begin\{rule\*\}", s):
        body, _ = env_body(s, m.end(), "rule*")
        (t,), k = args(body, 0, 1)
        if t == title:
            return rule_html(t, body[k:], ctx)
    raise KeyError("%s: no rule %r" % (fname, title))


def listing(fname, env, needle):
    """The first asm/pseudo listing in a chapter file that contains `needle`."""
    s = chapter_source(fname)
    for m in re.finditer(r"\\begin\{%s\}" % env, s):
        body, _ = env_body(s, m.end(), env)
        if needle in body:
            return body
    raise KeyError("%s: no %s listing containing %r" % (fname, env, needle))


def description_items(fname, first, ctx):
    """The description list of a chapter whose first item label contains `first`, as HTML."""
    s = chapter_source(fname)
    for m in re.finditer(r"\\begin\{description\}", s):
        _, j = opt(s, m.end())
        body, _ = env_body(s, j, "description")
        its = items(body)
        if its and first in (its[0][0] or ""):
            return block_env("description", body, ctx)
    raise KeyError("%s: no description starting %r" % (fname, first))


def encodings(fname, ctx):
    """The format diagrams of ch-encoding: [(name, used by, HTML)]."""
    s = chapter_source(fname)
    out = []
    for m in re.finditer(r"\\fmtrow\{([^}]*)\}\{([^}]*)\}\s*\\begin\{encoding\}", s):
        body, _ = env_body(s, m.end(), "encoding")
        out.append((m.group(1), m.group(2), encoding_html(parse_encoding(body))))
    return out


def tikz_fields(lab, labels):
    """The capability-format figure: its row of \\node boxes as (name, width text)."""
    env, body, info = find_float(labels, lab)
    out = []
    for m in re.finditer(r"\\node\[f[^\]]*\][^{]*\{(.*?)\};", body):
        name, _, sub = m.group(1).partition("\\\\")
        out.append((name.strip(), sub.replace("\\scriptsize", "").strip()))
    return out, info
