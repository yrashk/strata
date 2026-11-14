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
- [x] The format's specification (field offsets, the checksum, key
      encodings): `doc/strata-store-format.md`

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
- [x] Two programs writing at once wrote garbage (the commit of the other
      writer's bytes built its meta block over the bytes waiting in the
      request buffer): `tx_take` commits before the bytes are fetched;
      `test-store.sh` part 12. (The RTL comparison did not see it: both
      sides printed the same garbage)
- [x] A failed write (disk full) gives up one writer's work only: a
      commit holds the uncommitted bytes of one open file (`tx_w`; another
      writer's bytes, or any other change, commit them first), so giving a
      commit up loses that file's bytes since its last commit and nothing
      else; a lost write's blob is freed at its close; `test-store.sh`
      part 10. Two programs writing at once commit at every switch
      between them (slower than one commit a MiB). A page that fails its
      checksum while someone reads still loses the one writer in flight
- [x] A commit writes changed pages that lie together, in frames that lie
      together, with one command (`c_write`; 4 KiB pages): 171 write
      commands became 102 in a session of small files and a large one.
      Pages together on the disk but apart in the cache still go one by one
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
      (part by part): file names whole, any number of files; the facets
      from QUERY mode 1 (`sys_count`)
- [x] `tag` / `tags` / `cp -t`, `vi`'s tags, the shell's and `httpd`'s tag
      names: TAGS2 (`retag`, the shell and `httpd` take one message's
      worth of tags, `vi` what its buffer holds)
- [ ] Facets of tags with ids of 64 and up: the reply's tag set has 64
      bits (`ls` works them out from the files' tag ids; the shell's
      completion, `httpd` and `ls.fs` do not)
- [x] `vi`, `vi-edit.fs`: no "128 KiB at most" for `:w`
- [x] Forth: `sys.fs` (`tags-of`, `rec-next`, `rec-name`, `rec-id`),
      `ls.fs`, `httpd.fs` (the first part of a listing), `tag.fs`,
      `tags.fs`, `cp.fs`, `vi-edit.fs`
- [x] DIR (10) and TAGS (14) removed from the server; `sys_dir`,
      `sys_query`, `sys_tags` from `sys.s`
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
- [x] `tools/test-wdb.sh` (in `make test`): the list, a tree's root page,
      back, quit, by the frames they leave

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
- [x] Forth words for the store's calls: `lang/forth/progs/db.fs`
      (`kv-open`, `kv-get`, `kv-put`, `kv-del`, `kv-scan`; `forth db.fs
      get|put|del|scan`)
- [x] Attributes: SETATTR (42), GETATTR (43), `attr` (`fsattr.s`); terms
      in paths: `NAME=VALUE`, `<`, `>` over attributes, `size`,
      `modified`; `PREFIX*` last in a listing; `test-store.sh` part 7
- [x] A path without tags with a term `NAME=VALUE` (an attribute, `size`,
      `modified`) is answered from the index: the entries of one value are
      in object order, which is the order a listing's cursor needs
- [ ] `<`, `>` and `PREFIX*` alone still read every record: their index
      entries are in value order (name order), and a listing's cursor is
      an object id

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

## Stage 9: the server's code in units
- [x] Seldom used handlers are code units in the image's `.far` section,
      paged into the I-LS by the dispatcher when entered (`fsunits.s`:
      the rules of a unit; `fs_trap` hands a miss over with `svc` PAGE):
      the store's calls for programs, snapshots, boot objects, QUERY /
      TAGS2, TAG / UNTAG / RENAME / CWD, attributes. Units of 2 KiB; the
      resident code is 25 KiB of the 32, the code cache has three slots
- [x] `tools/check-fsunits.py` (in `make test`): no jump leaves its unit
- [x] A boot on the RTL with the paged server compared with the emulator's

## Stage 10: names per directory
A file's directory is the set of its tags (`/src/demo` is `/demo/src`; no
tag: the root), and a name is unique within a directory: `/src/x`,
`/src/demo/x` and a root `x` are three files. `ls /src` shows the files
of `/src` and its subdirectories (`demo/`); `ls /` the root's files and
every directory. (A first version, where a file was in each directory it
was tagged with, could not tell `/src/x` from `/src/demo/x`.)
- [x] Subdirectories (required): `ls /src` ends with `demo/`, `cd
      /src/demo` and `/src/demo/NAME` work, a directory and its
      subdirectory can each have a file of one name; tested by name
      (`test-sh.sh`, `test-store.sh` part 11)
- [x] The name index: tree `dnam`, key = the tag ids in ascending order
      (u32 big-endian each), a zero word, the name -> file; one entry a
      file. A disk with the old `name` tree is refused. A file with no tag
      also has an index entry under tag 0 (the root's listing)
- [x] Host: `tools/stdb/fsl.c`, `mkdisk`, `stdb ls / get` by path,
      `many.c`
- [x] `fs`: exact lookup (`find`, `nk_p`, `nk_r`), `fs_place` /
      `fs_unplace`; create, delete
- [x] `fs`: TAG and UNTAG take several tags in one request and move the
      file once (a first name `/` empties the set: `retag`); refused where
      the name is taken. RENAME moves and replaces. All three are one
      routine in the unit `ut` (`reloc`)
- [x] `fs`: a listing answers the directory's files; the files of deeper
      directories go as records without a name (bit 31 of the count of
      tags), for the subdirectories; the root: every directory (the tag
      set with every bit set); QUERY mode bit 1: every file (`ls -A`);
      `PREFIX*` at the root is the root's files
- [x] Programs: fs LOADIMG reads the path from the starter's directory
      (`proc` passes its pid), then `/bin`, then `/sys`, and answers the
      path it found the program by; `proc` makes that the command's first
      word (a paged C program finds `NAME.u` by it)
- [x] The disk: every program in `/bin`, sources in `/src` and
      `/src/demo`, Forth files in `/forth`
- [x] The shell (completion from the current directory and `/bin`, the
      directories at the root, `/etc/rc`), `net` (`/etc/resolv`), `httpd`
      (`/www/index.html`, rows without deeper files), `ls` (`-A`, `-t`
      from the ids), `cp -t`, `tag` / `untag` / `retag` (one request),
      `mv`; the Forth system (`/forth`), `ls.fs`, `tag.fs`, `cp.fs`,
      `httpd.fs` (subdirectories listed)
- [x] `wdoom`, `kira`, the C compiler: no change needed (the C ladder's
      session works in `/test`: the C session's commit)
- [x] Tests converted: `test-sh`, `test-store` (parts 11, 12),
      `test-files`, `test-fs-progs`, `test-http`, `test-vi`, `test-vifs`,
      `test-net`, `test-guest`, the demo scripts
- [x] `doc/strataos.md`, the proposal's decision, the format, the manual
      (`ch-os`), `HANDOFF.md`, the shell's help, `motd`
- [ ] A path names at most 16 tags (`NQT`), and a directory's key must fit
      a tree key (about 110 tags with a short name)
- [ ] Subdirectories of tags with ids of 64 and up show in `ls` only (the
      shell's completion, `httpd`, `ls.fs`, `httpd.fs` use the reply's
      64-bit tag set)

## Later
- [ ] Browser persistence (IndexedDB, download)
- [x] `fsck` in the OS (`os/progs/fsck.s`): the meta block, every tree
      page (checksum, number, level, key order), the boot manifest, every
      page's one use, the count of free pages; not the file system's
      records (`stdb check` on the host does those); `test-store.sh` part 9
- [ ] Checksums of file data
- [ ] The FPGA disk (128 KiB) is too small for the kernel's images and a
      store: `mkdisk -B ""` writes it with the kernel only (it had no
      servers before either)
