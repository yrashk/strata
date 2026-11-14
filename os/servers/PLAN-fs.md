# Plan: the database store and the file system on it

The design is `doc/strata-fs-proposal.md`. Nothing below the first section
starts before the open questions (section 11 there) are answered.

## Proposal
- [x] Survey: `fs.s`, the kernel's disk reading, `mkdisk`, the block
      device, the protocol, every client, the limits, persistence
- [x] `doc/strata-fs-proposal.md`
- [ ] Answers to the open questions: one server or two; hierarchy and
      unique names; snapshots; query syntax; namespace rights; assembly or
      C; when to commit
- [ ] The proposal revised to the answers and turned into the format's
      specification (field offsets, the checksum, key encodings)

## Stage 1: the store on the host
- [ ] `tools/stdb/`: pages, cache, B+tree (search, insert, split, delete,
      merge), free-space and pending trees, commit, mount
- [ ] Streams: inline values, extents, sparse ranges, truncate
- [ ] Catalog and namespaces; batches and transactions
- [ ] The fs layer: `obj`, `data`, `name`, `attr`, `dict`; queries with
      cursors
- [ ] `mkdisk` on the library; the boot manifest
- [ ] `stdb check`, `dump`, `ls`, `get`, `put`, `rm`, `tag`
- [ ] Tests: random operations against a model; a cut at every block
      write; a million objects

## Stage 2: persistence
- [ ] Emulator `-w` (write back at exit and at FLUSH)
- [ ] Emulator `--disk-cut N` and `--disk-cache`
- [ ] RTL harness: `disk_write` and write-back at exit

## Stage 3: boot
- [ ] Kernel `u_disk` / `u_findfile`: meta pages, checksum, manifest
- [ ] A disk without a boot server fails in `mkdisk`; `stdb check` checks
      the manifest

## Stage 4: the server, reading
- [ ] Mount, page cache in far memory, node-at-a-time search and scan
- [ ] Stream read (into a message, into an attached arena)
- [ ] fs: OPEN, READ, CLOSE, STAT, LOADIMG, READALL, CWD, STATFS, READBLK
- [ ] fs: QUERY (40), TAGS2 (41); DIR and TAGS in their present form
- [ ] The OS boots; every test that does not write passes

## Stage 5: the server, writing
- [ ] Allocator with a reserve; pending frees; the commit loop
- [ ] Insert and split, delete and merge
- [ ] Stream write, append, atomic replace at close
- [ ] BATCH, BEGIN / COMMIT / ABORT, parking of other writers, abort at
      CLEANUP
- [ ] fs: WRITE, WRITEALL, UNLINK, RENAME, TAG, UNTAG; boot objects kept
      contiguous
- [ ] Tests: across a boot; cuts in the emulator; `dump` against the C
      library; emulator against RTL

## Stage 6: clients
- [ ] `sys.s`: `sys_list`, `sys_tags2`
- [ ] `ls`, `sh` completion, `httpd`, `tag` / `tags` / `cp -t`, `vi`
- [ ] The 128 KiB refusals removed (`cp`, `vi`, `touch`)
- [ ] Forth: `sys.fs`, `ls.fs`, `httpd.fs`, `tag.fs`, `tags.fs`, `cp.fs`,
      `vi-edit.fs`
- [ ] DIR (10) and TAGS (14) removed; expected outputs regenerated
- [ ] `doc/strataos.md`, the manual (`ch-os`, `ch-firmware`,
      `ch-appendices`), `HANDOFF.md`

## Stage 7: the store for programs
- [ ] NSOPEN, NSGRANT, TREE, GET, SCAN, SOPEN and the rest over the
      endpoint; handles through SPAWN and CLEANUP
- [ ] `db` utility; Forth words
- [ ] Attributes: SETATTR, GETATTR, `attr`; query terms in paths

## Later
- [ ] Snapshots
- [ ] Browser persistence (IndexedDB, download)
- [ ] `fsck` in the OS
- [ ] Checksums of file data
