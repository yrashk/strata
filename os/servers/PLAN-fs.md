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
- [x] A million files on the host (`tools/stdb/many.c`, in `make
      test-stdb`): made in 4 s, checked whole; trees 3 and 4 levels high

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
- [x] Boot objects written from inside the OS: at the close, one run of
      pages and the manifest anew (`boot_fix` in `fsops.s`), in the same
      commit; rename and delete stay refused; `test-store.sh` part 8
- [ ] After a failed write (disk full, a bad page) the commit under way is
      given up for every client: files being written by others are lost.
      Give up only the failing client's work
- [ ] A commit writes each changed page with a command of its own; pages
      that lie together could go in one
- [x] `compare-boot.sh` checks the disks the emulator and the RTL leave
      and compares their `stdb dump`
- [x] `make test` runs `test-stdb` and `test-store`; `test-sh.out` regenerated
      (a file's tags are listed in the order it got them; a 25-byte name is
      a name). `test-http.out` expects an older `sh.s` size: not from here

## Stage 6: clients
- [x] `sys.s`: `sys_list`, `sys_tags2`
- [x] `ls` (names of any length, listings of any length)
- [x] `cp`, `cp.fs`: no size limit
- [x] `sh` completion (asks for `PATH/PREFIX*`) and `httpd`'s listings
      (part by part): file names whole, any number of files. Both still
      ask DIR once for the facets, and TAGS for tag names
- [ ] `tag` / `tags` / `cp -t`, `vi`'s tags, the facets everywhere: still
      TAGS and DIR's tag set (16-byte tag names, 64 tags of a file, tag
      ids below 64 in the facets)
- [x] `vi`, `vi-edit.fs`: no "128 KiB at most" for `:w`
- [ ] Forth: `sys.fs`, `ls.fs`, `httpd.fs`, `tag.fs`, `tags.fs`, `vi-edit.fs`
- [ ] DIR (10) and TAGS (14) removed
- [x] `doc/strataos.md`
- [x] The manual: the disk layout (`ch-firmware`), the file system's
      structure and limits (`ch-os`, `ch-appendices`); its table of fs
      operations (QUERY to DBBATCH added; the PDF is not rebuilt);
      `HANDOFF.md`

## Looking into the store from inside the OS
- [x] `os/lib/stview.s`: the disk's trees read with READBLK (the last
      commit), pages, a walk over a tree's records, lines of text
- [x] `db` (the trees; a tree's records; one page) and `wdb` (the same in a
      window: the list of trees, then a tree page by page, into branches)
- [ ] `wdb` has no test of its own (it was looked at on a captured frame)

## Stage 7: the store for programs
- [x] DBGET (64), DBSCAN (65), DBBATCH (66): trees of keys and values in
      namespaces made by the first write; a batch is one commit;
      namespaces made so are public, `fs` is private and refused
- [x] `db put / get / del`; `test-store.sh` part 6
- [x] `db scan NS/TREE` (DBSCAN, part by part), tested with 300 records
- [ ] Values longer than a quarter page (streams) through these calls
- [ ] Private namespaces for programs: handles, grants (NSGRANT), through
      SPAWN and CLEANUP
- [ ] Transactions over several requests (BEGIN / COMMIT / ABORT, other
      writers parked); conditions in a batch (REQUIRE-ABSENT ...)
- [x] Wrappers: `os/lib/kv.s` (`kv_open`, `kv_get`, `kv_put`, `kv_del`,
      `kv_scan`; a library of its own, so that programs that keep nothing
      in the store do not grow); `db` is built on it
- [ ] Forth words for the store's calls
- [x] Attributes: SETATTR (42), GETATTR (43), `attr` (`fsattr.s`); terms
      in paths: `NAME=VALUE`, `<`, `>` over attributes, `size`,
      `modified`; `PREFIX*` last in a listing; `test-store.sh` part 7
- [ ] Terms are checked against each record of what the tags give; walking
      the index for a term (a range of values, a prefix of names) is not
      done, so a term alone still reads every record

## Stage 8: snapshots
- [x] Births in pages and extents (in the format from stage 1)
- [x] Dead lists in the pending tree (`st_deadlim`, `pfree`, `drain_fr`);
      SNAP (45): take, delete, list; `/@NAME/` paths for the calls that
      read; `snap`; `test-store.sh` part 4; `stdb check` knows dead lists
- [x] Restore (`snap -r`, SNAP mode 3): the six trees take the snapshot's
      roots; `drop_tree` frees what only the state given up used; the
      snapshot's own pages leave the dead lists (a dead-list entry says
      whose namespace's pages it holds). `test-store.sh` part 5
- [x] `stdb snaps IMAGE`; `stdb -s SNAP dump|ls|get|info IMAGE` reads the
      disk as a snapshot has it (`test-store.sh` part 5)
- [x] The server no longer carries `sys.s` (it used one message and three
      buffers of it): about 5 KiB of its I-LS are free

## Later
- [ ] Browser persistence (IndexedDB, download)
- [ ] `fsck` in the OS
- [ ] Checksums of file data
- [ ] The FPGA disk (128 KiB) is too small for the kernel's images and a
      store: `mkdisk -B ""` writes it with the kernel only (it had no
      servers before either)
