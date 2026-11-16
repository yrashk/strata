#!/usr/bin/env python3
"""Generates the website's Stralog section: prolog/index.html.

    python3 doc/manual/gen/genprolog.py OUTDIR    (also run by genweb.py, so by make web-docs)
    python3 doc/manual/gen/genprolog.py --check   every predicate of the sources is described here

Read from the sources:

  * the builtins in lang/prolog/init.s's table (bi_tab: a functor and what
    runs it) and the predicates boot.pl defines (the heads of its clauses
    that do not start with $): together, every predicate Stralog has;
  * the examples, lang/prolog/examples/*.pl: their first comment says what
    they are, their `%   ?- Query.` lines become "Try" buttons that consult
    the file (it is on the disk, under /prolog) and run the query in the
    playground, and their text is shown.

Written here: the grouping and the one-line description of each predicate
(DESC). --check fails if a predicate of the sources has none, or if one
described here is not in the sources. The prose in front of the reference
is doc/manual/web/prolog.html.

The page has a playground: StrataOS in the WebAssembly emulator, with
`stralog` typed at its first prompt (site/prolog/prolog.js, which runs
site/play/worker.js and the play page's strata-emu.wasm and disk image; the
panel is doc/manual/web/prolog-play.html).
"""
import html
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
PL = "lang/prolog"
WEB = os.path.join(HERE, "..", "web")

esc = lambda s: html.escape(s, quote=True)  # noqa: E731

# (group id, title, blurb, [(Name/Arity, description), ...])
DESC = [
    ("control", "Control", "Conjunction, disjunction, if-then-else and cut are run by the solve loop itself "
     "(lang/prolog/solve.s); a cut inside call/N, \\+ or the condition of an if-then-else is local to it.", [
        ("true/0", "Succeeds."), ("fail/0", "Fails."), ("false/0", "Fails."),
        (",/2", "Conjunction: the first goal, then the second."),
        (";/2", "Disjunction; with -> or *-> inside, if-then-else."),
        ("|/2", "The same as ;."),
        ("->/2", "If-then: the condition once, then the goal."),
        ("*->/2", "Soft cut: every solution of the condition, then the goal."),
        ("!/0", "Cut: the choices made since the clause was called are dropped."),
        ("\\+/1", "Negation as failure: succeeds if the goal has no solution."),
        ("not/1", "The same as \\+."),
        ("call/1", "Calls a goal; cut inside it is local."),
        ("call/2", "Calls a goal with one more argument (call/3 to call/8: more)."),
        ("call/3", "call/2 with two more arguments."), ("call/4", "call/2 with three more arguments."),
        ("call/5", "call/2 with four more arguments."), ("call/6", "call/2 with five more arguments."),
        ("call/7", "call/2 with six more arguments."), ("call/8", "call/2 with seven more arguments."),
        ("once/1", "The first solution of a goal."),
        ("ignore/1", "Calls a goal once, and succeeds even if it fails."),
        ("forall/2", "Succeeds if the second goal holds for every solution of the first."),
        ("if/3", "if(C, T, E): (C *-> T ; E)."),
        ("repeat/0", "Succeeds again on every backtrack."),
        ("catch/3", "catch(Goal, Catcher, Recovery): Goal; if it throws a ball that unifies with Catcher, Recovery."),
        ("throw/1", "Throws a copy of a ball to the nearest catch/3 whose catcher unifies with it."),
        ("halt/0", "Ends Stralog."), ("halt/1", "Ends Stralog with an exit status."),
        (">>/2", "A lambda with no arguments: [X1, ...]>>Goal, its variables copied for each call."),
        (">>/3", "[X]>>Goal called with one argument, as maplist/3 and the like do (>>/4 to >>/7: more)."),
        (">>/4", "A lambda called with two arguments."), (">>/5", "A lambda called with three arguments."),
        (">>/6", "A lambda called with four arguments."), (">>/7", "A lambda called with five arguments."),
        ("^/2", "V^Goal: Goal (in bagof/3 and setof/3, V is not a free variable)."),
    ]),
    ("terms", "Terms", "Unification, comparison in the standard order (variables, numbers, atoms, compounds), "
     "and taking terms apart.", [
        ("=/2", "Unifies two terms."), ("\\=/2", "Succeeds if two terms do not unify (and binds nothing)."),
        ("==/2", "Identical terms."), ("\\==/2", "Terms that are not identical."),
        ("@</2", "Before, in the standard order of terms."), ("@>/2", "After, in the standard order."),
        ("@=</2", "Before or identical."), ("@>=/2", "After or identical."),
        ("compare/3", "compare(Order, X, Y): Order is <, = or >."),
        ("var/1", "An unbound variable."), ("nonvar/1", "Not an unbound variable."),
        ("atom/1", "An atom."), ("number/1", "A number (an integer: there are no floats)."),
        ("integer/1", "An integer."), ("atomic/1", "An atom or a number."),
        ("compound/1", "A compound term."), ("callable/1", "An atom or a compound."),
        ("is_list/1", "A proper list."), ("ground/1", "A term without variables."),
        ("functor/3", "functor(T, Name, Arity): a term's name and arity, or a term made of them."),
        ("arg/3", "arg(N, T, A): the Nth argument of a compound."),
        ("=../2", "T =.. [Name|Args]: a term and the list of its name and arguments."),
        ("copy_term/2", "A copy of a term with fresh variables."),
        ("term_variables/2", "The variables of a term, in the order they first occur."),
        ("numbervars/3", "Binds a term's variables to '$VAR'(N), which print as A, B, ..."),
        ("term_to_atom/2", "Reads a term from an atom's text."),
    ]),
    ("arith", "Arithmetic", "Integers of 61 bits; a result outside them raises evaluation_error(int_overflow). "
     "The functions: + - * // / mod rem div min max abs sign gcd ** ^ >> << /\\ \\/ xor \\ msb; / divides "
     "and truncates, as there are no floats.", [
        ("is/2", "X is Expression: evaluates it."),
        ("=:=/2", "Equal values."), ("=\\=/2", "Different values."), ("</2", "Less."), (">/2", "Greater."),
        ("=</2", "Less or equal."), (">=/2", "Greater or equal."),
        ("between/3", "between(L, H, X): X from L to H, one at a time."),
        ("succ/2", "succ(X, Y): Y is X + 1, either way round, for natural numbers."),
        ("plus/3", "plus(X, Y, Z): Z is X + Y, given any two."),
    ]),
    ("atoms", "Atoms and text", "Text is a list of codes or of one-character atoms; double-quoted text is a "
     "list of codes.", [
        ("atom_codes/2", "An atom and the list of its codes."),
        ("atom_chars/2", "An atom and the list of its one-character atoms."),
        ("char_code/2", "A one-character atom and its code."),
        ("atom_length/2", "The length of an atom's name."),
        ("number_codes/2", "A number and its text, as codes (0x, 0o, 0b and 0'c too)."),
        ("number_chars/2", "A number and its text, as characters."),
        ("atom_number/2", "An atom whose text is a number, and the number."),
        ("atom_concat/3", "Two atoms and the atom of the two together; with the third given, every split."),
        ("sub_atom/5", "sub_atom(A, Before, Length, After, Sub): the parts of an atom."),
        ("upcase_atom/2", "An atom in capitals."),
    ]),
    ("db", "The database", "Clauses added and removed while the program runs. A call sees the clauses there were "
     "when it was made (the logical update view).", [
        ("assert/1", "Adds a clause at the end."), ("assertz/1", "Adds a clause at the end."),
        ("asserta/1", "Adds a clause at the beginning."),
        ("retract/1", "Removes a clause that unifies; on backtracking, the next one."),
        ("retractall/1", "Removes every clause whose head unifies."),
        ("abolish/1", "abolish(Name/Arity): removes all of a predicate's clauses."),
        ("clause/2", "clause(Head, Body): the clauses of a predicate."),
        ("dynamic/1", "Declares predicates dynamic: Name/Arity, or several in a list or with commas."),
        ("discontiguous/1", "Accepted and ignored."),
        ("current_predicate/1", "current_predicate(Name/Arity): the predicates with clauses."),
        ("consult/1", "Reads a file's clauses (File, File.pl, then the same in /prolog); consult(user) reads "
         "them from the input until Ctrl-D."),
        ("./2", "[File, ...]: consult/1."),
    ]),
    ("all", "All solutions", "", [
        ("findall/3", "findall(T, Goal, L): T for every solution of Goal."),
        ("findall/4", "The same, with a tail for the list."),
        ("bagof/3", "Like findall/3, but grouped by the free variables of the goal (V^Goal: not V); "
         "fails if there is no solution."),
        ("setof/3", "bagof/3, sorted, without duplicates."),
        ("aggregate_all/3", "aggregate_all(count | sum(E) | bag(E) | set(E), Goal, Result)."),
    ]),
    ("lists", "Lists and sorting", "Written in Prolog in lang/prolog/boot.pl.", [
        ("append/3", "Two lists and the two together."), ("member/2", "An element of a list."),
        ("memberchk/2", "member/2, once."), ("length/2", "The length of a list, or lists of a length."),
        ("reverse/2", "A list reversed."), ("nth0/3", "The element at an index from 0."),
        ("nth1/3", "The element at an index from 1."), ("last/2", "The last element."),
        ("select/3", "An element and the list without it."), ("selectchk/3", "select/3, once."),
        ("permutation/2", "The permutations of a list."),
        ("delete/3", "A list without the elements that unify with one."),
        ("exclude/3", "The elements for which a goal fails."), ("include/3", "The elements for which it succeeds."),
        ("maplist/2", "A goal holds for every element."),
        ("maplist/3", "A goal for every pair of elements of two lists."),
        ("maplist/4", "A goal for every three elements of three lists."),
        ("foldl/4", "foldl(G, List, A0, A): G called with each element and an accumulator."),
        ("sum_list/2", "The sum of a list of numbers."), ("max_list/2", "The largest."),
        ("min_list/2", "The smallest."), ("numlist/3", "numlist(L, H, List): the integers from L to H."),
        ("msort/2", "Sorts in the standard order, keeping duplicates."),
        ("sort/2", "Sorts in the standard order, without duplicates."),
        ("keysort/2", "Sorts Key-Value pairs by key, keeping the order of equal keys."),
        ("predsort/3", "Sorts with a comparison predicate."),
    ]),
    ("io", "Input and output", "Streams: user_input, user_output, and files opened with open/3. "
     "read/1 and the top level read from user_input through a line editor.", [
        ("write/1", "Writes a term."), ("print/1", "Writes a term as writeq/1 does."),
        ("writeq/1", "Writes a term so that it can be read back."),
        ("write_canonical/1", "writeq/1 without operators."),
        ("write/2", "write/1 to a stream (print/2, writeq/2, write_canonical/2: the same)."),
        ("print/2", "print/1 to a stream."), ("writeq/2", "writeq/1 to a stream."),
        ("write_canonical/2", "write_canonical/1 to a stream."),
        ("write_term/2", "Writes with options: quoted(true), ignore_ops(true), numbervars(true), priority(P)."),
        ("write_term/3", "write_term/2 to a stream."), ("writeln/1", "Writes a term and a newline."),
        ("nl/0", "A newline."), ("nl/1", "A newline to a stream."), ("tab/1", "Spaces."),
        ("put_char/1", "Writes a character."), ("put_char/2", "To a stream."),
        ("get_char/1", "Reads a character (end_of_file at the end)."), ("get_char/2", "From a stream."),
        ("peek_char/1", "The next character, left there."), ("peek_char/2", "From a stream."),
        ("read/1", "Reads a term."), ("read/2", "From a stream."),
        ("read_term/2", "Reads a term with options: variable_names(Vs)."), ("read_term/3", "From a stream."),
        ("format/1", "format/2 with no arguments."),
        ("format/2", "Formatted output: ~w ~a ~d ~q ~p ~s ~n ~~."),
        ("open/3", "open(File, read | write | append, Stream)."), ("open/4", "The same, with options (ignored)."),
        ("close/1", "Closes a stream."), ("set_input/1", "The current input stream."),
        ("set_output/1", "The current output stream."), ("current_input/1", "The current input stream."),
        ("current_output/1", "The current output stream."), ("flush_output/0", "Sends the buffered output."),
        ("flush_output/1", "The same, for a stream."),
    ]),
    ("system", "Operators and the system", "", [
        ("op/3", "op(Priority, Type, Names): defines operators (priority 0 removes them)."),
        ("current_op/3", "The operators."),
        ("statistics/0", "What the engine has moved between the Local Store and far memory: each window's "
         "spills, slides and bytes, the far cache's misses and write-backs, the collections."),
        ("statistics/2", "statistics(runtime, [Ms, _]), statistics(inferences, Calls)."),
        ("phrase/2", "phrase(Rule, List): a DCG rule covers the list."),
        ("phrase/3", "phrase(Rule, List, Rest): the same, leaving Rest."),
    ]),
]


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


def mkatoms_names():
    """label -> name, from lang/prolog/mkatoms.py's table"""
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


def page_main(intro, exs):
    side, main = [], []
    side.append('    <div class="doc-find"><input id="filter" type="search" placeholder="Filter predicates…  ( / )" '
                'autocomplete="off" spellcheck="false" aria-label="Filter predicates by name or description" '
                'data-items="article.word" data-prefix="p-" data-noun="predicates"><p id="count" class="doc-count" '
                'aria-live="polite"></p></div>')
    side.append('    <details class="doc-ix" id="ix" open><summary>Index</summary><nav class="doc-toc" aria-label="Predicates">')
    side.append('      <div class="ix-group" id="ix-intro"><a class="ix-ch" href="#intro"><span>Stralog</span></a>'
                '<a class="ix-ch" href="#examples"><span>Examples</span><em>%d</em></a>'
                '<a class="ix-ch" href="#playground"><span>Playground</span></a></div>' % len(exs))
    # the examples
    ex_html = ['<section class="chap" id="examples" data-ch="examples">\n<h2><span class="num">%d programs</span>'
               'Examples</h2>\n<p>They are on the disk under <code>/prolog</code>. <b>Try</b> consults one in the '
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
    for (g, title, blurb, preds) in DESC:
        side.append('      <div class="ix-group" data-ch="%s"><a class="ix-ch" href="#g-%s"><span>%s</span><em>%d</em></a>'
                    % (g, g, title, len(preds)))
        for pi, d in preds:
            side.append('        <a class="ix" href="#%s" data-for="%s"><code>%s</code><span>%s</span></a>' % (
                pred_id(pi), pred_id(pi), esc(pi), esc(d)))
        side.append("      </div>")
        arts = "\n".join('<article class="word" id="%s" data-name="%s" data-k="%s"><header class="word-h"><h3>'
                         '<a href="#%s"><code>%s</code></a></h3></header><p class="word-d">%s</p></article>' % (
                             pred_id(pi), esc(pi), esc((pi + " " + d).lower()), pred_id(pi), esc(pi), esc(d))
                         for pi, d in preds)
        main.append('<section class="chap" id="g-%s" data-ch="%s">\n<h2><span class="num">%d predicates</span>%s</h2>\n'
                    '%s\n<div class="preds">%s</div>\n</section>' % (g, g, len(preds), title,
                                                                     "<p>%s</p>" % esc(blurb) if blurb else "", arts))
    side.append("    </nav></details>")
    side.append('    <p class="doc-keys"><kbd>/</kbd> filter · <kbd>Enter</kbd> first match · <kbd>Esc</kbd> clear</p>')
    return "\n".join(side), intro + "\n" + "\n".join(main)


def check():
    described = {pi for (_, _, _, preds) in DESC for (pi, _) in preds}
    have = source_preds()
    bad = 0
    for pi in sorted(have - described):
        print("genprolog: %s is in the sources but not described" % pi)
        bad += 1
    for pi in sorted(described - have):
        print("genprolog: %s is described but not in the sources" % pi)
        bad += 1
    print("genprolog: %d predicates described, %d in the sources" % (len(described), len(have)))
    return bad


def write(out, page, link_sources=None, files=None):
    """prolog/index.html under out; page is genweb.page."""
    exs = examples()
    n = sum(len(p) for (_, _, _, p) in DESC)
    intro = web_file("prolog.html").replace("{{preds}}", str(n)).replace("{{examples}}", str(len(exs)))
    side, main = page_main(intro, exs)
    head = ('<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/xterm@5.3.0/css/xterm.css">\n'
            '<link rel="stylesheet" href="prolog.css?v=__BUILD__">')
    tail = (web_file("prolog-play.html") +
            '<script src="https://cdn.jsdelivr.net/npm/xterm@5.3.0/lib/xterm.js"></script>\n'
            '<script src="https://cdn.jsdelivr.net/npm/xterm-addon-fit@0.8.0/lib/xterm-addon-fit.js"></script>\n'
            '<script src="../play/jit.js?v=__BUILD__"></script>\n'
            '<script src="prolog.js?v=__BUILD__"></script>')
    text = page("prolog", "Stralog", "Stralog: a Prolog for Strata in Strata assembly, whose terms live in far "
                "memory behind Local Store windows; its predicates, examples, and a playground running it in "
                "StrataOS in the browser.", side, main, head=head, tail=tail)
    if link_sources and files is not None:
        text = link_sources(text, files)
    os.makedirs(os.path.join(out, "prolog"), exist_ok=True)
    with open(os.path.join(out, "prolog", "index.html"), "w") as f:
        f.write(text)
    return n, len(exs)


def main():
    if sys.argv[1:] == ["--check"]:
        sys.exit(1 if check() else 0)
    sys.path.insert(0, HERE)
    import genweb  # noqa: E402
    out = sys.argv[1]
    n, k = write(out, genweb.page)
    print("genprolog: %d predicates, %d examples -> %s/prolog/" % (n, k, out))


if __name__ == "__main__":
    main()
