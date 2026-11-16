# StrataOS message specifications

One file per server (and one for the `svc` calls, one for the system
core's endpoint) describes every message it answers, field by field. The
site's server catalogue (`site/os/`) and the manual's StrataOS chapter are
generated from these files by `tools/web-os.py`; `tools/osspec.py` reads and
checks them. The test `web-os` fails when a file disagrees with the code:

- the ops a file lists must be exactly the ops the server's dispatch answers
  (`[server] dispatch`), except the three `proc` sends to every server
  (36 DUPS, 37 CLEANUP, 38 CANCEL), which are described once, in
  `system.toml`;
- an `OP_*` constant of `os/lib/sys.s` whose comment names a server
  (`; fs: open a file`) must be an op of that server's file, with the same
  number;
- every op has a summary, and what it takes and gives is described.

`python3 tools/osspec.py` checks every file; `python3 tools/osspec.py
os/spec/fs.toml` one. When you add or change an op in a server, change its
file here in the same commit, then `python3 tools/web-os.py --write` (the
site's pages carry the generated text).

## The format (TOML)

A server's `start`, `pid` and `place` are checked against the code that makes
it (`os/kunits/boot.s` u_servers for the kernel's, `os/servers/proc.s` main for
proc's), and every source that RECEIVEs requests must be named by a spec's
`sources`. Everything said of all the servers at once is made from these
fields: the core line of each server's facts, the lists of servers on the
pages (`<!-- servers:list -->` and the others), the server cores of the cores
diagram, the manual's table of the servers; the boot diagram and the list in
`doc/strataos.md` must name every server (`tools/web-os.py --check`).

```toml
[server]
key = "fs"                          # the file's name; the anchor on the site
title = "fs"                        # how it is named
role = "files, tags, names and program images"   # a few words
does = "the file server: files, ..."  # a sentence: the manual's table of the servers
reached = "c2 of every process"     # how a program gets an endpoint to it
start = "kernel"                    # a server: "kernel" or "proc" (made at boot), "demand"
pid = 3                             # made at boot: its pid, and where it runs
place = { core = 3, index = 0, alone = "from 8 cores" }   # alone: "yes", "no", "from 8 cores"
core_note = "..."                   # optional, after the place in words
# core = "the lowest empty core"    # where a server started on demand runs (in words)
holds = "a window on the block device's ports (c1), ..."   # capabilities it holds
sources = ["os/servers/fs.s", "os/servers/fsops.s"]        # where the ops are
dispatch = { file = "os/servers/fs.s", first = ";\\s*dispatch", last = "^bad:" }
calls = "message"                   # "message" (header words) or "svc" (registers)

[[op]]
num = 65
name = "DBSCAN"
summary = "Records of a program's tree, in key order"     # one line, no full stop
from = "any program"                # optional: who may send it (e.g. "proc only")
note = "As many records as fit; ask again with the last key and mode 1."

[op.request]                        # what the caller sends
handle = "..."                      # a header word that is used; leave out what is not
length = "..."
mode = "..."                        # a sentence, or with `modes` the values:
modes = { "0" = "ST_GE: from the key on", "1" = "ST_GT: after it" }
attachment = "the arena, lent for the call"     # a capability sent with it
data = [                            # the data from offset 64, in order
  { type = "u8", name = "namespace length", note = "1..32" },
  { type = "u8", name = "tree length", note = "1..28" },
  { type = "u16", name = "key length" },
  { type = "u32", name = "0" },
  { type = "bytes", name = "namespace, tree name, key", note = "no key: from the start" },
]
regs = { a1 = "...", a2 = "..." }   # svc calls: the registers instead of the header

[op.reply]                          # what comes back
result = "the number of records"    # the meaning of a result >= 0 (svc: a0)
handle = "..."                      # header words the reply uses (a cursor, facets)
length = "the data's bytes"
mode = "..."
data = [
  { repeat = "per record", fields = [
    { type = "u16", name = "key length" },
    { type = "u16", name = "value length" },
    { type = "u32", name = "0" },
    { type = "bytes", name = "key", note = "padded to 8 bytes" },
    { type = "bytes", name = "value", note = "padded to 8 bytes" },
  ] },
]
attachments = { c6 = "an endpoint to the server" }   # capabilities that arrive
regs = { a1 = "..." }               # svc calls

[op.errors]                         # each negative result this op gives, and why
"-4" = "no such namespace, tree or key"
"-1" = "a bad request, or a private namespace"
```

Field types: `u8`, `u16`, `u32`, `u64`, `s64` (fixed sizes: the generator
gives their offsets), `bytes` (a run of bytes whose length another field or
the header gives), `text` (zero-terminated text), `pad` (padding to the next
multiple of 8). A `repeat` entry is a group of fields that repeats (`repeat`
says over what). Text may use `backquotes` for code. Results that every
server shares (−1 failed, −2 interrupted, −3 would block, −4 no such file or
program, −5 no free core / not allowed, −6 no memory, −7 busy, −8 timed out)
are listed under `[op.errors]` with what they mean for that op.
