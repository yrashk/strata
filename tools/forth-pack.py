#!/usr/bin/env python3
"""forth-pack.py -o OUT HEAD FILE... [OTHER=NAME...]: the pack of the Forth ports of os/progs.

The disk's directory has room for 128 files (DIR answers 126), and nearly
all of them are taken, so lang/forth/sys.fs and lang/forth/progs/*.fs go on
the disk as one file, progs.pk: HEAD (lang/forth/progs.fs, Forth that Forth's
INCLUDED interprets, which explains the rest) with an index put in at its
line "\\ {{INDEX}}" (a line "OFFSET LENGTH port NAME" per file, the numbers
seven digits wide) and the pack's size at "{{SIZE}}"; then the files, each
at an 8-aligned offset (newlines between them). OTHER=NAME adds an index
line for the file NAME under another name (tag.fs is also untag.fs and
retag.fs).
"""
import os
import sys


def main(argv):
    if len(argv) < 4 or argv[0] != "-o":
        sys.exit("usage: forth-pack.py -o OUT HEAD FILE... [OTHER=NAME...]")
    out, head = argv[1], open(argv[2]).read()
    files = [a for a in argv[3:] if "=" not in a]
    others = [a.split("=", 1) for a in argv[3:] if "=" in a]
    if head.count("\\ {{INDEX}}\n") != 1 or head.count("{{SIZE}}") != 1:
        sys.exit("forth-pack.py: HEAD needs one \\ {{INDEX}} line and one {{SIZE}}")
    datas = []
    for f in files:
        name = os.path.basename(f)
        if len(name) > 31 or " " in name:
            sys.exit("forth-pack.py: bad name: " + name)
        with open(f, "rb") as fh:
            datas.append((name, fh.read()))
    names = [n for n, _ in datas] + [o for o, _ in others]
    # the head's length does not depend on the numbers in it (fixed width)
    hlen = len(head.encode()) - len("\\ {{INDEX}}\n") + sum(22 + len(n) for n in names) - len("{{SIZE}}") + 7
    pos = (hlen + 7) & ~7
    lines, body, at = [], bytearray(), {}
    for name, data in datas:
        lines.append("%07d %07d port %s\n" % (pos, len(data), name))
        at[name] = (pos, len(data))
        body += data
        pos += len(data)
        pad = -pos & 7
        body += b"\n" * pad
        pos += pad
    for other, name in others:
        if name not in at:
            sys.exit("forth-pack.py: no file %s for %s" % (name, other))
        lines.append("%07d %07d port %s\n" % (at[name] + (other,)))
    text = head.replace("\\ {{INDEX}}\n", "".join(lines)).replace("{{SIZE}}", "%07d" % pos).encode()
    assert len(text) == hlen
    text += b"\n" * (-len(text) & 7)
    with open(out, "wb") as fh:
        fh.write(text + bytes(body))


if __name__ == "__main__":
    main(sys.argv[1:])
