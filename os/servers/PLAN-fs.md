# Plan: the database store and the file system on it

The design is `doc/strata-fs-proposal.md`. Its section 11 holds the
decisions taken.

## Proposal
- [x] Survey: `fs.s`, the kernel's disk reading, `mkdisk`, the block
      device, the protocol, every client, the limits, persistence
- [x] `doc/strata-fs-proposal.md`
- [x] Decisions (section 11 of the proposal): one server; no hierarchy;
      snapshots wanted; query terms in paths; private or public
      namespaces; assembly; a commit per change. Emulator and RTL stay
      block devices only.
- [ ] The format's specification (field offsets, the checksum, key
      encodings) written out from `tools/stdb/` once stage 1 settles it

## Stage 1: the store on the host
- [x] `tools/stdb/store.c`: pages, B+tree (search, seek, insert, split,
      delete, merge), free-space and pending trees, commit, mount,
      catalog, `st_check`
- [x] `tools/stdb/test.c`: random operations against a model; a cut at
      every block write (`make test-stdb`)
- [x] Blobs: inline values, streams of extents, sparse ranges, truncate
- [x] Namespaces (the tree `ns`); pages for the layers above
- [x] `tools/stdb/fsl.c`: what the tools need of the file system's trees
      (a file with tags and attributes, the boot manifest, check, dump).
      Queries, rename, unlink and transactions for programs are in the
      server only
- [x] `tools/stdb/mkdisk.c` (`build/mkdisk-stdb`; it replaces
      `tools/mkdisk.c` when the server reads the format)
- [x] `stdb check`, `dump`, `ls`, `get`, `info`
- [ ] A million objects on the host

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

## Stage 8: snapshots
- [ ] Births in pages and extents (in the format from stage 1)
- [ ] Dead lists; take, list, delete; `fs@NAME` and `/@NAME/` paths

## Later
- [ ] Browser persistence (IndexedDB, download)
- [ ] `fsck` in the OS
- [ ] Checksums of file data
