#!/usr/bin/env python3
"""Generates the website's Stratalk section: stratalk/index.html.

   genstratalk.py OUTDIR                  the page, OUTDIR/stratalk/index.html
   genstratalk.py --check [FILE.st...]    every class and method has a description
   genstratalk.py --examples DIR [FILE.st...]
                                          the comments' examples as DIR/doc.st and
                                          DIR/doc.out, for lang/stratalk/tests/doc.sh

The prose is doc/manual/web/stratalk.html; the class reference (every class
of the kernel, by file, with its slots and its methods: selector, comment,
source) is read from lang/stratalk/kernel/*.st with the host compiler's own
parser (lang/stratalk/host/stc.py), the examples from
lang/stratalk/examples/*.st. The playground (stratalk-play.html,
site/stratalk/stratalk.js) runs StrataOS with the REPL in the browser.
genweb.py calls write() as part of make web-docs."""
import html
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
WEB = os.path.join(HERE, "..", "web")
ST = os.path.join(ROOT, "lang", "stratalk")
sys.path.insert(0, os.path.join(ST, "host"))
import stc  # noqa: E402

esc = html.escape


def kernel_files():
    out = []
    for line in open(os.path.join(ST, "kernel", "LOAD")):
        line = line.split("#")[0].strip()
        if line: out.append(line)
    return out


def file_comment(src):
    m = re.match(r'\s*"(.*?)"', src, re.S)
    return " ".join(m.group(1).split()) if m else ""


def comment_text(raw):
    """A comment's text, its lines' indentation taken off: (prose, [(expr, result)]).
    A line `EXPR >>> RESULT` is an example: EXPR printed by the REPL gives RESULT."""
    prose, exs = [], []
    for line in raw.split("\n"):
        line = line.strip()
        if " >>> " in line:
            e, r = line.split(" >>> ", 1)
            exs.append((e.strip(), r.strip()))
        elif line:
            prose.append(line)
    return " ".join(prose), exs


def first_sentence(text):
    m = re.match(r"(.*?[.!?])(?=\s+[A-Z`(]|$)", text, re.S)
    return m.group(1) if m else text


def class_comments(src):
    """{class name: the comment right after its definition (and its class-side slots)}."""
    out = {}
    for m in re.finditer(r"^\w+ (?:\w*[sS]ubclass): #(\w+) slots: '[^']*'\.[ \t]*\n"
                         r"(?:\1 class slots: '[^']*'\.[ \t]*\n)?[ \t]*\"(.*?)\"", src, re.M | re.S):
        out[m.group(1)] = m.group(2)
    return out


def method_comment(src, m):
    """The comment that begins a method's body, if any."""
    _, _, l1, r0 = m.span
    c = re.match(r'\s*"(.*?)"', src[l1:r0], re.S)
    return c.group(1) if c else None


def collect():
    """[(file, comment, [class...])]; a class: {name, super, kind, slots, cslots, comment,
    methods: [(meta, sel, comment, source)]}; a comment is None or (prose, examples)"""
    files, classes = [], {}
    for fn in kernel_files():
        src = open(os.path.join(ST, "kernel", fn), encoding="utf-8").read()
        items = stc.Parser(src).items()
        ccom = class_comments(src)
        here = []
        for it in items:
            if it[0] == "expr":
                e = it[1]
                if isinstance(e, stc.Send) and e.sel.endswith("ubclass:slots:") and isinstance(e.rcvr, stc.Var) \
                        and isinstance(e.args[0], stc.Lit) and isinstance(e.args[0].v, stc.Sym):
                    name = e.args[0].v.s
                    c = {"name": name, "super": e.rcvr.name, "kind": e.sel.split(":")[0],
                         "slots": e.args[1].v.s.split() if isinstance(e.args[1], stc.Lit) else [],
                         "cslots": [], "methods": [], "file": fn,
                         "comment": comment_text(ccom[name]) if name in ccom else None}
                    classes[c["name"]] = c
                    here.append(c)
                elif isinstance(e, stc.Send) and e.sel == "slots:" and isinstance(e.rcvr, stc.Send) \
                        and e.rcvr.sel == "class" and e.rcvr.rcvr.name in classes:
                    classes[e.rcvr.rcvr.name]["cslots"] = e.args[0].v.s.split()
            elif it[0] == "method":
                _, cname, meta, m = it
                c = classes.get(cname)
                if c is None: continue
                raw = method_comment(src, m)
                c["methods"].append((meta, m.sel, comment_text(raw) if raw is not None else None, m.source,
                                     fn, m.line))
                if c not in here and c["file"] != fn:
                    c.setdefault("elsewhere", set()).add(fn)
        files.append((fn, file_comment(src), here))
    return files, classes


def examples():
    out = []
    d = os.path.join(ST, "examples")
    for fn in sorted(os.listdir(d)):
        if fn.endswith(".st"):
            src = open(os.path.join(d, fn), encoding="utf-8").read()
            out.append((fn[:-3], file_comment(src), src))
    return out


def anchor(s):
    return re.sub(r"[^A-Za-z0-9_-]", "_", s)


def prose(text):
    """A description as HTML: `code` in backquotes becomes <code>."""
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", esc(text))


def examples_html(exs):
    if not exs: return ""
    return '<div class="st-ex">%s</div>' % "".join(
        '<code class="e">%s</code><span class="to" aria-label="answers">→</span><code class="r">%s</code>' % (
            esc(e), esc(r)) for e, r in exs)


def class_html(c):
    rows, keys = [], []
    for meta, sel, com, src, _, _ in sorted(c["methods"], key=lambda m: (not m[0], m[1])):
        mid = "m-%s-%s%s" % (c["name"], "class-" if meta else "", anchor(sel))
        text, exs = com or ("", [])
        first = first_sentence(text)
        rest = text[len(first):].strip()
        k = ("class " if meta else "") + sel + " " + text
        keys.append(sel + " " + first)
        rows.append('<details class="meth" id="%s" data-k="%s"><summary><code>%s%s</code><span>%s</span></summary>'
                    '<div class="meth-b">%s%s<pre class="lst"><code class="language-stratalk">%s</code></pre></div>'
                    '</details>' % (
                        esc(mid), esc(k.lower()), "class " if meta else "", esc(sel), prose(first),
                        '<p class="meth-d">%s</p>' % prose(rest) if rest else "", examples_html(exs), esc(src)))
    kind = {"subclass": "", "variableSubclass": " · indexed", "byteSubclass": " · bytes",
            "wordSubclass": " · words", "methodSubclass": " · compiled code"}.get(c["kind"], "")
    slots = " ".join(c["slots"]) or "none"
    cs = (" · class side: <code>%s</code>" % esc(" ".join(c["cslots"]))) if c["cslots"] else ""
    text, exs = c["comment"] or ("", [])
    sup = c["super"]
    sup_html = ('<a href="#c-%s">%s</a>' % (esc(sup), esc(sup))) if sup != "nil" else "nil"
    k = " ".join([c["name"], sup, text] + keys).lower()
    return ('<article class="word cls" id="c-%s" data-name="%s" data-k="%s"><header class="word-h"><h3>'
            '<a href="#c-%s"><code>%s</code></a></h3><span class="sup">%s%s</span></header>'
            '<p class="word-d">%s</p>%s'
            '<p class="slots">slots: <code>%s</code>%s · %d methods</p>%s</article>' % (
                esc(c["name"]), esc(c["name"].lower()), esc(k), esc(c["name"]), esc(c["name"]), sup_html, kind,
                prose(text), examples_html(exs), esc(slots), cs, len(c["methods"]), "\n".join(rows)))


def hierarchy(classes):
    """{superclass name: [subclass names, by name]}; Object's superclass is nil."""
    kids = {}
    for c in classes.values():
        kids.setdefault(c["super"], []).append(c["name"])
    for v in kids.values(): v.sort()
    return kids


def tree_html(classes):
    """The class hierarchy from Object, as nested lists: a class with subclasses is a
    <details> (open for the first two levels), each name a link to its entry."""
    kids = hierarchy(classes)

    def node(name, depth):
        c = classes[name]
        a = '<a href="#c-%s" data-c="%s" title="%s">%s</a>' % (
            esc(name), esc(name.lower()), esc(first_sentence(c["comment"][0]) if c["comment"] else ""), esc(name))
        sub = kids.get(name, [])
        if not sub: return "<li>%s</li>" % a
        return '<li><details%s><summary>%s<em>%d</em></summary><ul>%s</ul></details></li>' % (
            " open" if depth < 2 else "", a, count(name), "".join(node(k, depth + 1) for k in sub))

    def count(name):
        return sum(1 + count(k) for k in kids.get(name, []))

    return ('<div class="ct" id="ct" hidden role="dialog" aria-label="The class hierarchy">'
            '<div class="ct-bar"><span class="ct-t">Classes</span>'
            '<input id="ct-q" type="search" placeholder="Find a class" autocomplete="off" spellcheck="false" '
            'aria-label="Find a class in the hierarchy">'
            '<button type="button" class="small" data-z="-1" aria-label="Smaller">−</button>'
            '<button type="button" class="small" data-z="1" aria-label="Larger">+</button>'
            '<button type="button" class="small" data-ct="all" aria-label="Open every branch">all</button>'
            '<button type="button" class="small" id="ct-x" aria-label="Close">×</button></div>'
            '<div class="ct-body"><ul class="ct-tree">%s</ul></div></div>' % "".join(
                node(r, 0) for r in kids.get("nil", [])))


def tree_check(classes):
    """Every class is in the hierarchy once, under a class that exists: the names missing."""
    kids, seen = hierarchy(classes), []
    def walk(n):
        seen.append(n)
        for k in kids.get(n, []): walk(k)
    for r in kids.get("nil", []): walk(r)
    return sorted(set(classes) - set(seen)) + sorted(n for n in set(seen) if seen.count(n) > 1)


def page_parts(files, classes, exs, intro):
    side = ['    <div class="doc-find"><input id="filter" type="search" placeholder="Filter classes…  ( / )" '
            'autocomplete="off" spellcheck="false" aria-label="Filter classes and methods" '
            'data-items="article.word" data-prefix="c-" data-noun="classes">'
            '<p id="count" class="doc-count" aria-live="polite"></p>'
            '<button type="button" class="small ct-open" id="ct-open" aria-controls="ct">Class hierarchy</button></div>',
            '    <details class="doc-ix" id="ix" open><summary>Index</summary><nav class="doc-toc" aria-label="Classes">',
            '      <div class="ix-group" id="ix-intro"><a class="ix-ch" href="#intro"><span>Stratalk</span></a>'
            '<a class="ix-ch" href="#objects"><span>Objects</span></a>'
            '<a class="ix-ch" href="#memory"><span>Near and far objects</span></a>'
            '<a class="ix-ch" href="#jit"><span>The JIT</span></a>'
            '<a class="ix-ch" href="#os"><span>StrataOS</span></a>'
            '<a class="ix-ch" href="#examples"><span>Examples</span></a>'
            '<a class="ix-ch" href="#playground"><span>Playground</span></a></div>']
    main = [intro, tree_html(classes)]
    ex = ['<section class="chap" id="examples" data-unfiltered>\n<h2><span class="num">%d programs</span>Examples</h2>\n'
          '<p>On the disk under <code>/stratalk/examples</code>: <code>stratalk /stratalk/examples/NAME.st</code>, or '
          '<b>Try</b> here.</p>' % len(exs)]
    for name, com, src in exs:
        ex.append('<h3 id="ex-%s">%s.st <button type="button" class="small try-b" data-try="%s">Try</button></h3>'
                  '<p>%s</p><pre class="lst"><code class="language-stratalk">%s</code></pre>' % (
                      esc(name), esc(name), esc(src.strip()), esc(com), esc(src.strip())))
    ex.append("</section>")
    main.append("\n".join(ex))
    for fn, com, here in files:
        if not here: continue
        g = anchor(fn[:-3])
        side.append('      <div class="ix-group" data-ch="%s"><a class="ix-ch" href="#f-%s"><span>%s</span><em>%d</em></a>'
                    % (g, g, esc(fn), len(here)))
        for c in here:
            side.append('        <a class="ix" href="#c-%s" data-for="c-%s"><code>%s</code><span>%s</span></a>' % (
                esc(c["name"]), esc(c["name"]), esc(c["name"]),
                esc(first_sentence(c["comment"][0]) if c["comment"] else c["super"])))
        side.append("      </div>")
        main.append('<section class="chap" id="f-%s" data-ch="%s">\n<h2><span class="num">%d classes</span>%s</h2>\n'
                    '<p>%s <a class="srcpath" href="../code/#lang/stratalk/kernel/%s"><code>%s</code></a></p>\n%s\n</section>' % (
                        g, g, len(here), esc(fn), esc(com), esc(fn), esc(fn), "\n".join(class_html(c) for c in here)))
    side.append("    </nav></details>")
    side.append('    <p class="doc-keys"><kbd>/</kbd> filter · <kbd>Enter</kbd> first match · <kbd>Esc</kbd> clear</p>')
    return "\n".join(side), "\n".join(main)


def web_file(name):
    with open(os.path.join(WEB, name), encoding="utf-8") as f:
        return re.sub(r"\A\s*<!--.*?-->\s*", "", f.read(), flags=re.S)


def write(out, page, link_sources=None, files_for_links=None):
    files, classes = collect()
    exs = examples()
    n_methods = sum(len(c["methods"]) for c in classes.values())
    ops = len(re.findall(r"^\w+Server >> \w+: args \[", open(os.path.join(ST, "kernel", "OSServers.st")).read(), re.M))
    counts = {"classes": len(classes), "methods": n_methods, "examples": len(exs), "ops": ops}
    intro = re.sub(r"\{\{(\w+)\}\}", lambda m: str(counts[m.group(1)]), web_file("stratalk.html"))
    side, main = page_parts(files, classes, exs, intro)
    head = ('<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/xterm@5.3.0/css/xterm.css">\n'
            '<link rel="stylesheet" href="stratalk.css?v=__BUILD__">')
    tail = (web_file("stratalk-play.html") +
            '<script>window.STRATALK_EXAMPLES = %s;</script>\n' % ("[" + ", ".join('"%s"' % n for n, _, _ in exs) + "]") +
            '<script src="https://cdn.jsdelivr.net/npm/xterm@5.3.0/lib/xterm.js"></script>\n'
            '<script src="https://cdn.jsdelivr.net/npm/xterm-addon-fit@0.8.0/lib/xterm-addon-fit.js"></script>\n'
            '<script src="../play/jit.js?v=__BUILD__"></script>\n'
            '<script src="stratalk.js?v=__BUILD__"></script>')
    text = page("stratalk", "Stratalk", "Stratalk: a Smalltalk for Strata whose object memory follows the machine: "
                "near and far objects, a JIT, every StrataOS server as classes, and a playground in the browser.",
                side, main, head=head, tail=tail)
    if link_sources and files_for_links is not None:
        text = link_sources(text, files_for_links)
    os.makedirs(os.path.join(out, "stratalk"), exist_ok=True)
    with open(os.path.join(out, "stratalk", "index.html"), "w") as f:
        f.write(text)
    return counts


def check(only=None):
    """Every class has a class comment and every method a description (in the files
    named, or all). Answers the number of what is missing."""
    files, classes = collect()
    bad = n = 0
    for fn, _, here in files:
        if only and fn not in only: continue
        for c in here:
            n += 1
            if not c["comment"] or not c["comment"][0]:
                print("genstratalk: %s: class %s has no class comment" % (fn, c["name"]))
                bad += 1
    for c in classes.values():
        for meta, sel, com, _, fn, line in c["methods"]:
            if only and fn not in only: continue
            n += 1
            if not com or not com[0]:
                print("genstratalk: %s:%d: %s%s >> %s has no description" % (
                    fn, line, c["name"], " class" if meta else "", sel))
                bad += 1
    for name in tree_check(classes):
        print("genstratalk: class %s is not in the class hierarchy once" % name)
        bad += 1
    print("genstratalk: %d classes and methods, %d without a description" % (n, bad))
    return bad


def write_examples(d, only=None):
    """The examples of the comments (EXPR >>> RESULT) as a test vector of
    lang/stratalk/tests/run.sh: d/doc.st and d/doc.out."""
    files, classes = collect()
    exs = []
    for c in classes.values():
        for com in [c["comment"]] + [m[2] for m in c["methods"] if not only or m[4] in only]:
            if com: exs.extend(com[1])
    with open(os.path.join(d, "doc.st"), "w") as f:
        f.write("".join(e + "\n" for e, _ in exs))
    with open(os.path.join(d, "doc.out"), "w") as f:
        f.write("".join(r + "\n" for _, r in exs))
    return len(exs)


def main():
    if sys.argv[1:2] == ["--check"]:
        sys.exit(1 if check(sys.argv[2:]) else 0)
    if sys.argv[1:2] == ["--examples"]:
        print("genstratalk: %d examples" % write_examples(sys.argv[2], sys.argv[3:]))
        return
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.path.insert(0, HERE)
    import genweb
    c = write(sys.argv[1], genweb.page, genweb.link_sources, genweb.browsable())
    print("web-docs: Stratalk: %(classes)d classes, %(methods)d methods, %(examples)d examples" % c)


if __name__ == "__main__":
    main()
