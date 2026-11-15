#!/usr/bin/env python3
"""osspec.py: the StrataOS message specifications (os/spec/*.toml), read and checked.

  osspec.py [FILE...]   check the files (all of os/spec/ when none is named):
                        their form, and that each agrees with the code (the
                        ops its server's dispatch answers, the OP_* constants
                        of os/lib/sys.s). Exit 1 on any problem.
  osspec.py --table OUT the debugger's table of the messages (strata-emu
                        --os DIR reads DIR/msgops.txt): every op's name, the
                        fields of its data, its errors (format: table()).

os/spec/README.md describes the format. tools/web-os.py makes the site's and
the manual's pages from what load() returns.
"""
import os
import re
import sys
import tomllib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPEC = os.path.join(ROOT, "os", "spec")
ORDER = ["svc", "kernel", "proc", "dev", "fs", "tty", "pipe", "net", "ws", "system"]
SYSTEM_OPS = (36, 37, 38)               # proc -> every server: described in system.toml
TYPES = {"u8": 1, "u16": 2, "u32": 4, "u64": 8, "s64": 8, "bytes": None, "text": None, "pad": None}
SERVER_KEYS = {"key", "title", "role", "reached", "core", "holds", "sources", "dispatch", "calls", "note"}
OP_KEYS = {"num", "name", "summary", "from", "note", "request", "reply", "errors"}
REQ_KEYS = {"handle", "length", "mode", "modes", "attachment", "data", "regs", "note"}
REP_KEYS = {"result", "handle", "length", "mode", "modes", "data", "attachments", "regs", "note"}
FIELD_KEYS = {"type", "name", "note"}


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
    """The op numbers a dispatch answers: {number: (handler label, line)}. Pairs of
    `li tN, VALUE` and `beq tX, tN, LABEL` between the lines matching first and
    last. A range check (addi t2, t1, -OP_A; li t3, OP_B - OP_A; bgtu) followed
    by single tests answers the untested rest of the range too (ws's TITLE)."""
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
                ops[value(m.group(2), consts)] = (b.group(2), n + 2)
        m = re.match(r"^\s*addi\s+t\d\s*,\s*t\d\s*,\s*-([A-Z_][A-Z0-9_]*)", l)
        if m:
            lo = consts[m.group(1)]
            w = re.match(r"^\s*li\s+t\d\s*,\s*([A-Z_][A-Z0-9_]*\s*-\s*[A-Z_][A-Z0-9_]*)", lines[n + 1])
            rng = (lo, lo + value(w.group(1), consts))
        n += 1
    if rng:
        for op in range(rng[0], rng[1] + 1):
            ops.setdefault(op, (None, n + 1))
    return ops


def label_line(sources, label):
    """(file, line) of a label in the sources, or None."""
    for p in sources:
        for n, l in enumerate(read(p)):
            if re.match(r"^%s:" % re.escape(label), l):
                return p, n + 1
    return None


def sysops():
    """The OP_* constants of sys.s with the servers their comment names: (name, num, server, line)."""
    out = []
    for n, l in enumerate(read("os/lib/sys.s")):
        m = re.match(r"^(OP_[A-Z0-9_]+)\s*=\s*(\d+)\s*;\s*([a-z, ]+):", l)
        if m:
            for s in m.group(3).split(","):
                out.append((m.group(1), int(m.group(2)), s.strip(), n + 1))
    return out


def files():
    return sorted((f for f in os.listdir(SPEC) if f.endswith(".toml")),
                  key=lambda f: ORDER.index(f[:-5]) if f[:-5] in ORDER else 99)


def load(name):
    with open(os.path.join(SPEC, name), "rb") as f:
        return tomllib.load(f)


def check_fields(fields, where, problems):
    for fd in fields:
        if "repeat" in fd:
            if set(fd) - {"repeat", "fields", "note"} or "fields" not in fd:
                problems.append("%s: a repeat group has repeat, fields and note only" % where)
            check_fields(fd.get("fields", []), where + " (" + fd["repeat"] + ")", problems)
            continue
        if set(fd) - FIELD_KEYS:
            problems.append("%s: field keys %s" % (where, sorted(set(fd) - FIELD_KEYS)))
        if fd.get("type") not in TYPES:
            problems.append("%s: field %r has type %r (one of %s)" % (where, fd.get("name"), fd.get("type"), ", ".join(TYPES)))
        if "name" not in fd and fd.get("type") != "pad":
            problems.append("%s: a field without a name" % where)


def check_form(spec, name):
    """Problems with the file's form."""
    problems = []
    srv = spec.get("server", {})
    for k in sorted(set(srv) - SERVER_KEYS):
        problems.append("%s: [server] has an unknown key %s" % (name, k))
    for k in ("key", "title", "role", "calls"):
        if k not in srv:
            problems.append("%s: [server] lacks %s" % (name, k))
    if srv.get("key") != name[:-5]:
        problems.append("%s: [server] key must be %r" % (name, name[:-5]))
    seen = set()
    for op in spec.get("op", []):
        where = "%s: op %s %s" % (name, op.get("num"), op.get("name"))
        for k in sorted(set(op) - OP_KEYS):
            problems.append("%s: unknown key %s" % (where, k))
        for k in ("num", "name", "summary", "request", "reply"):
            if k not in op:
                problems.append("%s: lacks %s" % (where, k))
        if op.get("num") in seen:
            problems.append("%s: the number is used twice" % where)
        seen.add(op.get("num"))
        s = op.get("summary", "")
        if s.endswith(".") or "\n" in s:
            problems.append("%s: a summary is one line without a full stop" % where)
        for part, keys in (("request", REQ_KEYS), ("reply", REP_KEYS)):
            t = op.get(part, {})
            for k in sorted(set(t) - keys):
                problems.append("%s: [op.%s] has an unknown key %s" % (where, part, k))
            check_fields(t.get("data", []), "%s %s data" % (where, part), problems)
            if srv.get("calls") == "svc" and set(t) & {"handle", "length", "mode", "data"}:
                problems.append("%s: an svc call has registers (regs), not header words" % where)
        for code in op.get("errors", {}):
            if not re.fullmatch(r"-[1-9]\d*", code):
                problems.append("%s: error %r is not a negative number" % (where, code))
    return problems


def check_code(spec, name):
    """Problems where the file and the code disagree."""
    problems = []
    srv = spec["server"]
    d = srv.get("dispatch")
    nums = {op["num"] for op in spec.get("op", [])}
    if d:
        consts = constants(["os/lib/sys.s", "os/lib/srv.s", d["file"]] + srv.get("sources", []))
        answered = dispatch(d["file"], d["first"], d["last"], consts)
        mine = {n for n in answered if n not in SYSTEM_OPS or srv["key"] in ("svc", "kernel")}
        for n in sorted(mine - nums):
            problems.append("%s: %s answers op %d (%s, %s:%d), which the file does not describe"
                            % (name, d["file"], n, answered[n][0], d["file"], answered[n][1]))
        for n in sorted(nums - mine):
            problems.append("%s: describes op %d, which %s does not answer" % (name, n, d["file"]))
    for cname, num, server, ln in sysops():
        if server == srv["key"] and num not in nums:
            problems.append("os/lib/sys.s:%d: %s = %d is a %s op, but %s does not describe it"
                            % (ln, cname, num, server, name))
    return problems


def system_ops_of(spec):
    """The proc-to-server ops a server's dispatch answers."""
    d = spec["server"].get("dispatch")
    if not d or spec["server"]["key"] in ("svc", "kernel"):
        return []
    consts = constants(["os/lib/sys.s", "os/lib/srv.s", d["file"]] + spec["server"].get("sources", []))
    return sorted(n for n in dispatch(d["file"], d["first"], d["last"], consts) if n in SYSTEM_OPS)


def load_all():
    """[(spec, problems)] for every file, in the order of ORDER."""
    out = []
    for name in files():
        try:
            spec = load(name)
        except tomllib.TOMLDecodeError as e:
            out.append(({"server": {"key": name[:-5]}, "op": []}, ["%s: %s" % (name, e)]))
            continue
        p = check_form(spec, name)
        if not p:
            p = check_code(spec, name)
        spec["op"] = sorted(spec.get("op", []), key=lambda o: o.get("num", 0))
        out.append((spec, p))
    return out


def extent(part, reply):
    """How far a message's data reaches: "len" (the header's length), "res" (a
    reply's result counts the bytes) or "fix" (the fixed fields' sizes)."""
    if "length" in part and part.get("data"):
        return "len"
    if reply and part.get("data") and re.search(r"\bbytes\b", part.get("result", "")) and \
            "repeat" not in part["data"][0] and part["data"][0].get("type") in ("bytes", "text"):
        return "res"
    return "fix"


def table(out):
    """strata-msgops 1, then one line per item (fields separated by one space,
    the last one is the rest of the line):
      op SERVER NUM NAME REQ REP    REQ, REP: the data's extent (extent())
      fq SERVER NUM TYPE NAME       a field of the request's data, in order
      fr SERVER NUM TYPE NAME       ... of the reply's (TYPE rep: a repeated group)
      e SERVER NUM CODE TEXT        what a negative result means (SERVER * NUM 0:
                                    any message, the names of os/lib/sys.s)
    SERVER is the file's key: kernel (the system core's endpoint), proc, dev,
    fs, tty, pipe, net, ws, system (what proc sends every server, and the
    kernel proc)."""
    lines = ["strata-msgops 1"]
    flat = lambda s: " ".join(str(s).split())
    for spec, problems in load_all():
        key = spec["server"]["key"]
        if spec["server"].get("calls") != "message":
            continue
        for op in spec["op"]:
            req, rep = op.get("request", {}), op.get("reply", {})
            lines.append("op %s %d %s %s %s" % (key, op["num"], op["name"], extent(req, False), extent(rep, True)))
            for tag, part in (("fq", req), ("fr", rep)):
                for fd in part.get("data", []):
                    if "repeat" in fd:
                        lines.append("%s %s %d rep %s" % (tag, key, op["num"], flat(fd["repeat"])))
                    else:
                        lines.append("%s %s %d %s %s" % (tag, key, op["num"], fd["type"], flat(fd.get("name", "-"))))
            for code, text in sorted(op.get("errors", {}).items(), key=lambda kv: -int(kv[0])):
                lines.append("e %s %d %d %s" % (key, op["num"], int(code), flat(text)))
    for l in read("os/lib/sys.s"):
        m = re.match(r'^(E_[A-Z0-9_]+)\s*=\s*(-\d+)\s*;\s*"([^"]*)"', l)
        if m:
            lines.append("e * 0 %s %s %s" % (m.group(2), m.group(1), m.group(3)))
    with open(out, "w") as f:
        f.write("\n".join(lines) + "\n")
    return 0


def main(argv):
    if len(argv) == 3 and argv[1] == "--table":
        return table(argv[2])
    names = [os.path.basename(a) for a in argv[1:]] or files()
    bad = 0
    for name in names:
        try:
            spec = load(name)
        except tomllib.TOMLDecodeError as e:
            print("osspec: %s: %s" % (name, e))
            bad += 1
            continue
        problems = check_form(spec, name) or check_code(spec, name)
        for p in problems:
            print("osspec: " + p)
        bad += len(problems)
        if not problems:
            print("osspec: %s: %d ops, as the code answers them" % (name, len(spec.get("op", []))))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
