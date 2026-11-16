#!/usr/bin/env python3
"""Generates the website's Stralog section: stralog/index.html.

    python3 doc/manual/gen/genstralog.py OUTDIR    (also run by genweb.py, so by make web-docs)
    python3 doc/manual/gen/genstralog.py --check   every predicate of the sources is described here

Read from the sources:

  * the builtins in lang/stralog/init.s's table (bi_tab: a functor and what
    runs it) and the predicates boot.pl defines (the heads of its clauses
    that do not start with $): together, every predicate Stralog has;
  * the examples, lang/stralog/examples/*.pl: their first comment says what
    they are, their `%   ?- Query.` lines become "Try" buttons that consult
    the file (it is on the disk, under /stralog) and run the query in the
    playground, and their text is shown.

The reference is doc/manual/web/stralog-ref.txt: the groups, and an entry
for each predicate (its templates, what it does, its errors, where it
differs from ISO and SWI-Prolog, examples); its first comment says how it
is written. --check fails if a predicate of the sources has no entry, if an
entry is for a predicate that is not in the sources, or if an entry has no
template or no example. The prose in front of the reference is
doc/manual/web/stralog.html; its {{optable}} is the operator table, from
lang/stralog/mkatoms.py.

    python3 doc/manual/gen/genstralog.py --session DIR

writes the reference's examples as a session (DIR/ref.txt) and what Stralog
must print for it (DIR/ref.out), which lang/stralog/tests/ref.sh runs (the
test stralog-ref).

The page has a playground: StrataOS in the WebAssembly emulator, with
`stralog` typed at its first prompt (site/stralog/stralog.js, which runs
site/play/worker.js and the play page's strata-emu.wasm and disk image; the
panel is doc/manual/web/stralog-play.html).
"""
import html
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
PL = "lang/stralog"
WEB = os.path.join(HERE, "..", "web")

esc = lambda s: html.escape(s, quote=True)  # noqa: E731

REF = "doc/manual/web/stralog-ref.txt"


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


def mkatoms_names():
    """label -> name, from lang/stralog/mkatoms.py's table"""
    src = read(PL + "/mkatoms.py")
    return {m.group(1): m.group(2).encode().decode("unicode_escape")
            for m in re.finditer(r"\('(\w+)', '((?:[^'\\]|\\.)*)'", src)}


def source_preds():
    """every predicate of the sources: the builtin table and boot.pl's heads"""
    names = mkatoms_names()
    out = set()
    for m in re.finditer(r"\.dword \(\(at_(\w+) >> 3\) << 16\) \| \((\d+) << 3\)", read(PL + "/init.s")):
        name = names.get(m.group(1), m.group(1))
        if not name.startswith("$"):
            out.add("%s/%s" % (name, m.group(2)))
    text = re.sub(r"%[^\n]*", "", read(PL + "/boot.pl"))
    for clause in re.split(r"\.\s*\n", text):
        clause = clause.strip()
        if not clause or clause.startswith(":-"):
            continue
        head = re.split(r":-|-->", clause)[0].strip()
        if head.startswith("["):                            # [F|Fs] :- consult(...)
            out.add("./2")
            continue
        m = re.match(r"'?([a-z][A-Za-z0-9_]*|[^\s(']+)'?\s*(\((.*)\))?$", head, re.S)
        if not m:
            m2 = re.match(r"_\s*(\^|>>)\s*\w", head)        # _ ^ G
            if m2:
                out.add("%s/2" % m2.group(1))
            continue
        name = m.group(1)
        if name.startswith("$"):
            continue
        args = m.group(3)
        out.add("%s/%d" % (name, 0 if args is None else arity(args)))
    return out


def arity(args):
    depth, n = 0, 1
    quote = None
    for c in args:
        if quote:
            if c == quote:
                quote = None
            continue
        if c in "'\"":
            quote = c
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "," and depth == 0:
            n += 1
    return n


def examples():
    out = []
    d = os.path.join(ROOT, PL, "examples")
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".pl"):
            continue
        text = read(PL + "/examples/" + fn)
        lines = text.split("\n")
        head = []
        for l in lines:
            if not l.startswith("%"):
                break
            head.append(l[1:].strip())
        first = head[0] if head else fn
        _, _, first = first.partition(":")                  # "name.pl: what it is ..."
        title = re.split(r"[.:;]", first.strip(), 1)[0]
        what = " ".join([first.strip()] + [h for h in head[1:] if h and not h.startswith("?-")])
        tries = []
        for h in head:
            m = re.match(r"\?-\s*(.*?\.)\s*(.*)$", h)
            if m:
                tries.append((m.group(1), m.group(2)))
        out.append({"file": fn, "name": fn[:-3], "title": title.strip(), "what": what, "tries": tries, "text": text})
    return out


def web_file(name):
    with open(os.path.join(WEB, name), encoding="utf-8") as f:
        return re.sub(r"\A\s*<!--.*?-->\s*", "", f.read(), flags=re.S)


def pred_id(pi):
    return "p-" + re.sub(r"[^A-Za-z0-9]", lambda m: "_%02x" % ord(m.group(0)), pi)


# ---------------------------------------------------------------- the reference
# doc/manual/web/stralog-ref.txt: the entries, in groups. Its first comment
# says how it is written.

def parse_ref(text):
    """[{id, title, blurb: [lines], entries: [{pis, tmpl, text, errors, differs, examples}]}]"""
    groups, g, e = [], None, None
    lines = [l for l in re.sub(r"\A\s*<!--.*?-->\s*", "", text, flags=re.S).split("\n")]
    i = 0
    while i < len(lines):
        l = lines[i]
        if l.startswith("# "):
            gid, _, title = l[2:].partition("|")
            g = {"id": gid.strip(), "title": title.strip(), "blurb": [], "entries": []}
            groups.append(g)
            e = None
        elif l.startswith("## "):
            e = {"pis": l[3:].split(), "tmpl": [], "text": [], "errors": [], "differs": [], "examples": []}
            g["entries"].append(e)
        elif e is None:
            if l.strip():
                g["blurb"].append(l)
        elif l.startswith(": "):
            e["tmpl"].append(l[2:])
        elif l.startswith("error: "):
            f, _, w = l[7:].partition(" — ")
            e["errors"].append((f.strip(), w.strip()))
        elif l.startswith("differs: "):
            e["differs"].append(l[9:])
        elif l.startswith("?- ") or l.startswith("strata$ "):
            block = []
            while i < len(lines) and lines[i].strip():
                block.append(lines[i])
                i += 1
            e["examples"].append(block)
            continue
        elif l.strip():
            e["text"].append(l)
        i += 1
    return groups


def reference():
    return parse_ref(read(REF))


def cat_v(s):
    """what cat -v makes of the text (run.sh's transcript goes through it)"""
    out = []
    for b in s.encode():
        if b >= 128:
            out.append("M-")
            b -= 128
        out.append("^?" if b == 127 else ("^" + chr(b + 64)) if b < 32 and b != 10 and b != 9 else chr(b))
    return "".join(out)


def session(groups):
    """(the lines typed, the transcript expected) for every example that runs:
    a query; `| text`, a line typed for the program; an answer ending in ` ;`,
    after which ; was typed; `.` alone, Enter after an answer that may have
    had others (the answer line ends in a space)."""
    inp, out = [], []
    for g in groups:
        for e in g["entries"]:
            for b in e["examples"]:
                if b[0].startswith("strata$"):                  # a shell transcript: shown, not run
                    continue
                for l in b:
                    if l.startswith("?- "):
                        inp.append(l[3:])
                        out.append(l)
                    elif l.startswith("| "):
                        inp.append(l[2:])
                        out.append(l[2:])
                    elif l == ".":
                        inp.append("")
                        out[-1] += " "
                        out.append(l)
                    else:
                        if l.endswith(" ;"):
                            inp.append(";")
                        out.append(l)
    return inp, out


def write_session(d):
    """the test stralog-ref's session (ref.txt) and what it must print (ref.out)"""
    inp, out = session(reference())
    with open(os.path.join(d, "ref.txt"), "w") as f:
        f.write("stralog\n" + "\n".join(inp) + "\nhalt.\nhalt\n")
    with open(os.path.join(d, "ref.out"), "w") as f:
        f.write(cat_v("strata$ stralog\nStralog 0.1\n" + "\n".join(out) +
                      "\n?- halt.\nstrata$ halt\nStrataOS: all cores halted\n"))


def optable():
    """the operators Stralog starts with (lang/stralog/mkatoms.py), as a table"""
    src = read(PL + "/mkatoms.py")
    by = {}
    for m in re.finditer(r"\('\w+', '((?:[^'\\]|\\.)*)', \[([^\]]*)\]\)", src):
        name = m.group(1).encode().decode("unicode_escape")
        for p, t in re.findall(r"\((\d+), '(\w+)'\)", m.group(2)):
            by.setdefault((int(p), t), []).append(name)
    rows = "".join('<tr><td>%d</td><td><code>%s</code></td><td>%s</td></tr>' % (
        p, t, " ".join("<code>%s</code>" % esc(n) for n in ns)) for (p, t), ns in
        sorted(by.items(), key=lambda kv: (-kv[0][0], kv[0][1])))
    return ('<table class="optab"><tr><th>priority</th><th>type</th><th>operators</th></tr>%s</table>' % rows)


def ref_ids(groups):
    return {pi: pred_id(pi) for g in groups for e in g["entries"] for pi in e["pis"]}


def inline(s, ids):
    """text with `code` (a link when it is a predicate indicator), and links to
    the Terms and syntax chapter"""
    out, last = [], 0
    for m in re.finditer(r"`([^`]+)`", s):
        out.append(esc(s[last:m.start()]))
        c = m.group(1)
        out.append('<a href="#%s"><code>%s</code></a>' % (ids[c], esc(c)) if c in ids else "<code>%s</code>" % esc(c))
        last = m.end()
    out.append(esc(s[last:]))
    return "".join(out).replace("Terms and syntax", '<a href="#syntax">Terms and syntax</a>')


def gloss(e):
    """an entry's first sentence: its line in the index"""
    t = re.sub(r"`([^`]*)`", r"\1", " ".join(e["text"]))
    m = re.match(r"(.+?\.)(\s|$)", t)
    return m.group(1) if m else t


def example_html(b):
    if b[0].startswith("strata$"):
        return '<pre class="lst"><code class="language-prolog" data-session>%s</code></pre>' % esc("\n".join(b))
    parts, ans = [], []

    def flush():
        if ans:
            parts.append('<pre class="ans">%s</pre>' % "\n".join(ans))
            ans.clear()
    for l in b:
        if l.startswith("?- "):
            flush()
            q = l[3:]
            parts.append('<div class="try"><button type="button" class="try-b" data-try="%s" title="Ask this in '
                         'the playground">Try</button><code class="language-prolog">?- %s</code></div>' % (
                             esc(q), esc(q)))
        elif l.startswith("| "):
            ans.append('<span class="typed">%s</span>' % esc(l[2:]))
        else:
            ans.append(esc(l))
    flush()
    return '<div class="ex-s">%s</div>' % "".join(parts)


def entry_html(e, ids):
    aid = pred_id(e["pis"][0])
    title = " ".join('<code%s>%s</code>' % ("" if k == 0 else ' id="%s"' % pred_id(pi), esc(pi))
                     for k, pi in enumerate(e["pis"]))
    h = ['<article class="word" id="%s" data-name="%s" data-k="%s">' % (
        aid, esc(e["pis"][0]), esc(" ".join(e["pis"] + e["tmpl"] + [gloss(e)]).lower())),
        '<header class="word-h"><h3><a href="#%s">%s</a></h3></header>' % (aid, title)]
    h.append('<div class="tmpl">%s</div>' % "".join('<code class="stack">%s</code>' % esc(t) for t in e["tmpl"]))
    h += ['<p class="word-d">%s</p>' % inline(p, ids) for p in e["text"]]
    if e["errors"]:
        h.append('<div class="errs"><h4>Errors</h4><dl>%s</dl></div>' % "".join(
            '<dt><code>%s</code></dt><dd>%s</dd>' % (esc(f), inline(w, ids)) for f, w in e["errors"]))
    for d in e["differs"]:
        h.append('<p class="differs"><b>Differs.</b> %s</p>' % inline(d, ids))
    h.append('<div class="exs">%s</div>' % "".join(example_html(b) for b in e["examples"]))
    h.append("</article>")
    return "\n".join(h)


def blurb_html(lines, ids):
    out = []
    for l in lines:
        if l.startswith("<"):
            out.append(l)
        elif l.startswith("differs: "):
            out.append('<p class="differs"><b>Differs.</b> %s</p>' % inline(l[9:], ids))
        else:
            out.append("<p>%s</p>" % inline(l, ids))
    return "\n".join(out)


def page_main(intro, exs, groups):
    side, main = [], []
    ids = ref_ids(groups)
    side.append('    <div class="doc-find"><input id="filter" type="search" placeholder="Filter predicates…  ( / )" '
                'autocomplete="off" spellcheck="false" aria-label="Filter predicates by name or description" '
                'data-items="article.word" data-prefix="p-" data-noun="predicates"><p id="count" class="doc-count" '
                'aria-live="polite"></p></div>')
    side.append('    <details class="doc-ix" id="ix" open><summary>Index</summary><nav class="doc-toc" aria-label="Predicates">')
    side.append('      <div class="ix-group" id="ix-intro"><a class="ix-ch" href="#intro"><span>Stralog</span></a>'
                '<a class="ix-ch" href="#syntax"><span>Terms and syntax</span></a>'
                '<a class="ix-ch" href="#reading"><span>Reading the entries</span></a>'
                '<a class="ix-ch" href="#examples"><span>Examples</span><em>%d</em></a>'
                '<a class="ix-ch" href="#playground"><span>Playground</span></a></div>' % len(exs))
    # the examples
    ex_html = ['<section class="chap" id="examples" data-ch="examples">\n<h2><span class="num">%d programs</span>'
               'Examples</h2>\n<p>They are on the disk under <code>/stralog</code>. <b>Try</b> consults one in the '
               'playground and asks the query; <b>Edit</b> puts its text into the playground\'s editor, from where '
               '<b>Consult</b> reads it again as you changed it.</p>' % len(exs)]
    for e in exs:
        tries = "".join(
            '<div class="try"><button type="button" class="try-b" data-try="[%s].\n%s" title="Consult it in the '
            'playground and ask this">Try</button><code>?- %s</code>%s</div>' % (
                esc(e["name"]), esc(q), esc(q), ' <span class="try-n">%s</span>' % esc(n) if n else "")
            for (q, n) in e["tries"])
        ex_html.append(
            '<article class="word ex" id="ex-%s" data-k="%s">\n<header class="word-h"><h3><a href="#ex-%s"><code>%s'
            '</code></a></h3><span class="ex-title">%s</span>'
            '<button type="button" class="small ex-edit" data-edit="%s">Edit</button></header>\n'
            '<p class="word-d">%s</p>\n%s\n<details class="wsrc"><summary><span class="ws-what">source</span>'
            '<em>%d lines</em></summary><pre class="lst"><code class="language-prolog">%s</code></pre></details>\n'
            '</article>' % (e["name"], esc((e["file"] + " " + e["title"] + " " + e["what"]).lower()), e["name"],
                            esc(e["file"]), esc(e["title"]), esc(e["name"]), esc(e["what"]), tries,
                            e["text"].count("\n"), esc(e["text"])))
    ex_html.append("</section>")
    main.append("\n".join(ex_html))
    side.append('      <div class="ix-group" data-ch="examples">' + "".join(
        '<a class="ix" href="#ex-%s" data-for="ex-%s"><code>%s</code><span>%s</span></a>' % (
            e["name"], e["name"], esc(e["file"]), esc(e["title"])) for e in exs) + "</div>")
    # the reference
    for g in groups:
        n = sum(len(e["pis"]) for e in g["entries"])
        side.append('      <div class="ix-group" data-ch="%s"><a class="ix-ch" href="#g-%s"><span>%s</span><em>%d</em></a>'
                    % (g["id"], g["id"], g["title"], n))
        for e in g["entries"]:
            for pi in e["pis"]:
                side.append('        <a class="ix" href="#%s" data-for="%s"><code>%s</code><span>%s</span></a>' % (
                    pred_id(pi), pred_id(e["pis"][0]), esc(pi), esc(gloss(e))))
        side.append("      </div>")
        main.append('<section class="chap" id="g-%s" data-ch="%s">\n<h2><span class="num">%d predicates</span>%s</h2>\n'
                    '%s\n<div class="preds">%s</div>\n</section>' % (
                        g["id"], g["id"], n, esc(g["title"]), blurb_html(g["blurb"], ids),
                        "\n".join(entry_html(e, ids) for e in g["entries"])))
    side.append("    </nav></details>")
    side.append('    <p class="doc-keys"><kbd>/</kbd> filter · <kbd>Enter</kbd> first match · <kbd>Esc</kbd> clear</p>')
    return "\n".join(side), intro + "\n" + "\n".join(main)


def check():
    groups = reference()
    entries = [e for g in groups for e in g["entries"]]
    described = [pi for e in entries for pi in e["pis"]]
    have = source_preds()
    bad = 0
    for pi in sorted(have - set(described)):
        print("genstralog: %s is in the sources but has no entry" % pi)
        bad += 1
    for pi in sorted(set(described) - have):
        print("genstralog: %s has an entry but is not in the sources" % pi)
        bad += 1
    for pi in sorted({pi for pi in described if described.count(pi) > 1}):
        print("genstralog: %s has more than one entry" % pi)
        bad += 1
    for e in entries:
        for what, k in (("template", "tmpl"), ("description", "text"), ("example", "examples")):
            if not e[k]:
                print("genstralog: the entry for %s has no %s" % (" ".join(e["pis"]), what))
                bad += 1
    print("genstralog: %d predicates in %d entries, %d in the sources" % (len(described), len(entries), len(have)))
    return bad


def write(out, page, link_sources=None, files=None):
    """stralog/index.html under out; page is genweb.page."""
    exs = examples()
    groups = reference()
    n = sum(len(e["pis"]) for g in groups for e in g["entries"])
    intro = web_file("stralog.html").replace("{{preds}}", str(n)).replace("{{examples}}", str(len(exs)))
    intro = intro.replace("{{optable}}", optable())
    side, main = page_main(intro, exs, groups)
    head = ('<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/xterm@5.3.0/css/xterm.css">\n'
            '<link rel="stylesheet" href="stralog.css?v=__BUILD__">')
    tail = (web_file("stralog-play.html") +
            '<script src="https://cdn.jsdelivr.net/npm/xterm@5.3.0/lib/xterm.js"></script>\n'
            '<script src="https://cdn.jsdelivr.net/npm/xterm-addon-fit@0.8.0/lib/xterm-addon-fit.js"></script>\n'
            '<script src="../play/jit.js?v=__BUILD__"></script>\n'
            '<script src="stralog.js?v=__BUILD__"></script>')
    text = page("stralog", "Stralog", "Stralog: a Prolog for Strata in Strata assembly, whose terms live in far "
                "memory behind Local Store windows; its predicates, examples, and a playground running it in "
                "StrataOS in the browser.", side, main, head=head, tail=tail)
    if link_sources and files is not None:
        text = link_sources(text, files)
    os.makedirs(os.path.join(out, "stralog"), exist_ok=True)
    with open(os.path.join(out, "stralog", "index.html"), "w") as f:
        f.write(text)
    return n, len(exs)


def main():
    if sys.argv[1:] == ["--check"]:
        sys.exit(1 if check() else 0)
    if sys.argv[1:2] == ["--session"]:
        write_session(sys.argv[2])
        return
    sys.path.insert(0, HERE)
    import genweb  # noqa: E402
    out = sys.argv[1]
    n, k = write(out, genweb.page)
    print("genstralog: %d predicates, %d examples -> %s/stralog/" % (n, k, out))


if __name__ == "__main__":
    main()
