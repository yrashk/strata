#!/usr/bin/env python3
"""Generates the website's Stratalk section: stratalk/index.html.

   genstratalk.py OUTDIR

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


def method_comment(text):
    """The comment that begins a method's body, if any."""
    body = text[text.find("[") + 1:]
    m = re.match(r'\s*(?:\|[^|]*\|\s*)?(?:<[^>]*>\s*)?"(.*?)"', body, re.S)
    return " ".join(m.group(1).split()) if m else ""


def collect():
    """[(file, comment, [class...])]; a class: {name, super, kind, slots, cslots, methods: [(meta, sel, comment, source)]}"""
    files, classes = [], {}
    for fn in kernel_files():
        src = open(os.path.join(ST, "kernel", fn), encoding="utf-8").read()
        items = stc.Parser(src).items()
        here = []
        for it in items:
            if it[0] == "expr":
                e = it[1]
                if isinstance(e, stc.Send) and e.sel.endswith("ubclass:slots:") and isinstance(e.rcvr, stc.Var) \
                        and isinstance(e.args[0], stc.Lit) and isinstance(e.args[0].v, stc.Sym):
                    c = {"name": e.args[0].v.s, "super": e.rcvr.name, "kind": e.sel.split(":")[0],
                         "slots": e.args[1].v.s.split() if isinstance(e.args[1], stc.Lit) else [],
                         "cslots": [], "methods": [], "file": fn}
                    classes[c["name"]] = c
                    here.append(c)
                elif isinstance(e, stc.Send) and e.sel == "slots:" and isinstance(e.rcvr, stc.Send) \
                        and e.rcvr.sel == "class" and e.rcvr.rcvr.name in classes:
                    classes[e.rcvr.rcvr.name]["cslots"] = e.args[0].v.s.split()
            elif it[0] == "method":
                _, cname, meta, m = it
                c = classes.get(cname)
                if c is None: continue
                c["methods"].append((meta, m.sel, method_comment(m.source), m.source))
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


def class_html(c):
    rows = []
    for meta, sel, com, src in sorted(c["methods"], key=lambda m: (not m[0], m[1])):
        mid = "m-%s-%s%s" % (c["name"], "class-" if meta else "", anchor(sel))
        rows.append('<details class="meth" id="%s"><summary><code>%s%s</code><span>%s</span></summary>'
                    '<pre class="lst"><code>%s</code></pre></details>' % (
                        esc(mid), "class " if meta else "", esc(sel), esc(com), esc(src)))
    kind = {"subclass": "", "variableSubclass": " · indexed", "byteSubclass": " · bytes",
            "wordSubclass": " · words", "methodSubclass": " · compiled code"}.get(c["kind"], "")
    slots = " ".join(c["slots"]) or "none"
    cs = (" · class side: <code>%s</code>" % esc(" ".join(c["cslots"]))) if c["cslots"] else ""
    return ('<article class="word cls" id="c-%s"><h3><code>%s</code> <span class="sup">%s%s</span></h3>'
            '<p class="slots">slots: <code>%s</code>%s · %d methods</p>%s</article>' % (
                esc(c["name"]), esc(c["name"]), esc(c["super"]), kind, esc(slots), cs, len(c["methods"]),
                "\n".join(rows)))


def page_parts(files, classes, exs, intro):
    side = ['    <div class="doc-find"><input id="filter" type="search" placeholder="Filter classes…  ( / )" '
            'autocomplete="off" spellcheck="false" aria-label="Filter classes and methods" '
            'data-items="article.word" data-prefix="c-" data-noun="classes">'
            '<p id="count" class="doc-count" aria-live="polite"></p></div>',
            '    <details class="doc-ix" id="ix" open><summary>Index</summary><nav class="doc-toc" aria-label="Classes">',
            '      <div class="ix-group" id="ix-intro"><a class="ix-ch" href="#intro"><span>Stratalk</span></a>'
            '<a class="ix-ch" href="#memory"><span>Near and far objects</span></a>'
            '<a class="ix-ch" href="#jit"><span>The JIT</span></a>'
            '<a class="ix-ch" href="#os"><span>StrataOS</span></a>'
            '<a class="ix-ch" href="#examples"><span>Examples</span></a>'
            '<a class="ix-ch" href="#playground"><span>Playground</span></a></div>']
    main = [intro]
    ex = ['<section class="chap" id="examples" data-unfiltered>\n<h2><span class="num">%d programs</span>Examples</h2>\n'
          '<p>On the disk under <code>/stratalk/examples</code>: <code>stratalk /stratalk/examples/NAME.st</code>, or '
          '<b>Try</b> here.</p>' % len(exs)]
    for name, com, src in exs:
        ex.append('<h3 id="ex-%s">%s.st <button type="button" class="small try-b" data-try="%s">Try</button></h3>'
                  '<p>%s</p><pre class="lst"><code>%s</code></pre>' % (
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
                esc(c["name"]), esc(c["name"]), esc(c["name"]), esc(c["super"])))
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


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.path.insert(0, HERE)
    import genweb
    c = write(sys.argv[1], genweb.page, genweb.link_sources, genweb.browsable())
    print("web-docs: Stratalk: %(classes)d classes, %(methods)d methods, %(examples)d examples" % c)


if __name__ == "__main__":
    main()
