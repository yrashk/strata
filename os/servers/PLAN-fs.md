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
- [x] Emulator `-w FILE` (the disk as it is at the end)
- [x] Emulator `--disk-cut N` and `--disk-cache SEED`
- [x] RTL harness: `disk_write` and `-w FILE`

## Stage 3: boot
- [x] Kernel `u_disk`: meta blocks, checksums, the manifest turned into the
      directory `u_findfile` and `u_loadsrv` read
- [x] A disk without a boot server fails in `mkdisk`; `stdb check` checks
      the manifest

## Stage 4: the server, reading
- [x] Mount, page cache in far memory (124 frames), three page buffers in
      the D-LS, search and seek (`os/servers/store.s`)
- [x] Blob read (into a message, into an attached arena) (`sblob.s`)
- [x] fs: OPEN, READ, CLOSE, STAT, LOADIMG, READALL, CWD, STATFS, READBLK
- [x] fs: QUERY (40), TAGS2 (41); DIR and TAGS in their present form
- [x] The OS boots

## Stage 5: the server, writing
- [x] Allocator: free and pending trees, spare extent, relief of the lists
      where no change is under way, the commit's loop (`storew.s`)
- [x] Insert and split, delete and merge
- [x] Stream write, append, truncate; replace at close in one commit
- [x] fs: WRITE, WRITEALL, UNLINK, RENAME, TAG, UNTAG
- [x] `tools/test-store.sh`: a disk the OS wrote passes `stdb check` and
      holds the right bytes; read back after a second boot; power cuts
      over a whole session, with and without a write cache losing blocks
- [x] Emulator against RTL: `compare-boot.sh` (console) passes on the store
- [ ] Boot objects written from inside the OS (now refused: the manifest is
      only written by `mkdisk`)
- [ ] After a failed write (disk full, a bad page) the commit under way is
      given up for every client: files being written by others are lost.
      Give up only the failing client's work
- [ ] A commit writes each changed page with a command of its own; pages
      that lie together could go in one
- [ ] `compare-boot.sh`: also compare the two disks' `stdb dump` (needs
      `-w` on both; the RTL harness has it)
- [x] `make test` runs `test-stdb` and `test-store`; `test-sh.out` regenerated
      (a file's tags are listed in the order it got them; a 25-byte name is
      a name). `test-http.out` expects an older `sh.s` size: not from here

## Stage 6: clients
- [x] `sys.s`: `sys_list`, `sys_tags2`
- [x] `ls` (names of any length, listings of any length)
- [x] `cp`, `cp.fs`: no size limit
- [ ] `sh` completion, `httpd`, `tag` / `tags` / `cp -t`, `vi`'s tags: still
      DIR and TAGS (24-byte names, 16-byte tag names, 126 records, tag ids
      below 64 in the facets)
- [ ] `vi`: its "128 KiB at most" for `:w`
- [ ] Forth: `sys.fs`, `ls.fs`, `httpd.fs`, `tag.fs`, `tags.fs`, `vi-edit.fs`
- [ ] DIR (10) and TAGS (14) removed
- [x] `doc/strataos.md`
- [ ] The manual (`ch-os`, `ch-firmware`, `ch-appendices`), `HANDOFF.md`

## Looking into the store from inside the OS
- [x] `os/lib/stview.s`: the disk's trees read with READBLK (the last
      commit), pages, a walk over a tree's records, lines of text
- [x] `db` (the trees; a tree's records; one page) and `wdb` (the same in a
      window: page by page, into branches and from the catalog into trees)
- [ ] `wdb` has no test of its own (it was looked at on a captured frame)

## Stage 7: the store for programs
- [ ] NSOPEN, NSGRANT, TREE, GET, SCAN, BATCH, BEGIN / COMMIT / ABORT,
      SOPEN over the endpoint; handles through SPAWN and CLEANUP. (The
      server's code fills the I-LS's 32 KiB with the whole of `sys.s` in
      it, of which it uses little: a library of what a server needs comes
      first)
- [ ] `db` utility; Forth words
- [ ] Attributes: SETATTR, GETATTR, `attr`; query terms in paths (the host
      side has attributes: `mkdisk -a`, `stdb dump`)

## Stage 8: snapshots
- [x] Births in pages and extents (in the format from stage 1)
- [x] Dead lists in the pending tree (`st_deadlim`, `pfree`, `drain_fr`);
      SNAP (45): take, delete, list; `/@NAME/` paths for the calls that
      read; `snap`; `test-store.sh` part 4; `stdb check` knows dead lists
- [ ] Pages of the free and pending trees themselves are kept on dead
      lists too when they are older than a snapshot (no snapshot shows
      them): they come back when the snapshot is deleted, not before
- [ ] `stdb`: listing snapshots and reading through one on the host
- [ ] The server's I-LS is full (40 bytes left): anything more needs the
      library trimmed to what a server uses

## Later
- [ ] Browser persistence (IndexedDB, download)
- [ ] `fsck` in the OS
- [ ] Checksums of file data
- [ ] The FPGA disk (128 KiB) is too small for the kernel's images and a
      store: `mkdisk -B ""` writes it with the kernel only (it had no
      servers before either)
