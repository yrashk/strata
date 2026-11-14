# A database store for StrataOS, and the file system on top of it

Status: the design is accepted with the decisions of section 11; the
implementation follows the stages of section 10 (as checkboxes in
`os/servers/PLAN-fs.md`, which says how far it is).

The idea in one paragraph: StrataOS gets a **generic store**, `db`: ordered
key-value trees (copy-on-write B+trees) grouped into **namespaces**, with
transactions, cursors and large values. The store owns the block device.
The **file system is one client of it**: `fs` keeps its objects and its
indexes (names, tags, attributes) as ordinary trees in its own namespace
and holds no on-disk structure of its own. Any other program can have a
namespace, and a namespace can be shared. An index is a tree like any
other, so a new kind of query is a new tree, not a new disk format.

File and line references are to branch `claude/ws-fps-game-20319b` (commit
cb68a9a), which has the 1024-entry directory.

## 1. What exists

### 1.1 The disk and the server

The layout is written by `tools/mkdisk.c` (:11-26, :137-200): block 0 is
the boot header; then a directory of N 32-byte entries `{name[24], u32
first block, u32 size}`; a tag table of 64 names of 16 bytes and one u64
tag set per entry; the kernel's three images; then the files, each one
contiguous run of blocks.

`os/servers/fs.s` (2349 lines, 8.2 KiB of code) reads the whole directory
and tag table into far memory at start (`load_meta`, :358) and writes all
of it back on every change (`save_meta`, :479: the directory, block 0 and
the tag table, three commands, 64 + 1 + 18 blocks for 1024 entries). A file
being written is held whole in one of three 128 KiB regions and written at
the first free block when its last reference closes (`save_file`, :1132).
Deleting gives the blocks back only when the file was the last one on the
disk (`give_back`, :1095). There is no block cache: every READ is a device
command (`op_read`, :1611). FLUSH is never issued.

The model on top is already not hierarchical: a file has one name, unique
on the disk, and carries tags; a path is a list of tags and a name;
`-tag` excludes; DIR answers the "facets", the other tags the matching
files carry (`doc/strataos.md` :900-956). This proposal keeps that model
and generalizes it.

### 1.2 Fixed limits

| Limit | Value | Where |
|---|---|---|
| Files | 128..1024, set when the disk is made | `fs.s:129`, `mkdisk.c:37-40` |
| Servers the kernel can find | among the first 128 entries, unchecked | `boot.s:319`, `:460` |
| File name | 24 bytes | `mkdisk.c:152`, `boot.s:478`, `ls.s:88`, `sh.s:1478`, `httpd.s:1494`, `proc.s:602` |
| Tags | 64 (a u64 set per file; facets are a u64) | `fs.s:131`, `sys.s:2240`, `httpd.s:1420` |
| Tag name | 16 bytes | `fs.s:132`, `tag.s:17`, `sh.s:1515` |
| One DIR reply | 126 files; `sh`, `httpd`, `ls.fs`, `httpd.fs` take the first 126 only | `fs.s:75`, `sh.s:1457`, `httpd.s:1356`, `ls.fs:33`, `httpd.fs:37` |
| A file being written | 128 KiB, three at a time | `fs.s:112-114`, `cp.s:98`, `vi.s:140`, `cp.fs:23`, `vi-edit.fs:172` |
| File layout | one contiguous run; size is a u32 | `fs.s:8`, `boot.s:416` |
| Free space | reused only behind the last file | `fs.s:1095` |
| Open files | 16 | `fs.s:119` |
| Path in a request; current path | 120 bytes; 64 bytes, 64 processes | `fs.s:133-135` |
| Directory entries in the D-LS | a window of 128; an entry's address dies with its window | `fs.s:130`, `:444` |
| Program image; `<` and `>` of bare-metal programs | 128 KiB; 256 KiB and 64 KiB | `proc.s:73`, `:676`, `:1220` |
| Disk | 32768 blocks (16 MiB) in the emulator's default and in the RTL | `common/stx.h:73`, `sim/main.cpp:264` |

The last two rows are not the file system's and stay.

### 1.3 Who depends on the layout or the reply formats

- **The firmware** (`firmware/bootrom.s:126-180`) reads block 0: the magic
  and offsets 8..28, 44, 48 (the kernel's images). It ignores 36..56.
- **The kernel** (`os/kunits/boot.s:302-333`, `:458-492`) reads header
  offset 36, eight directory blocks, and finds `proc`, `dev` and `fs` by
  name in 32-byte entries; it loads each as one contiguous run (:416-436).
- **`mkdisk`** and seven Makefile rules that call it (Makefile :403-536).
- **`os/lib/sys.s`**: `sys_query` and `sys_fskip` (:1007, :157: the skip
  count), `sys_tags` (:1019: 64 records), `sys_facets` (:2240: a u64).
- **Programs that parse DIR or TAGS records**: `ls.s` (:24-192), `sh.s`
  (completion, :1365-1523), `httpd.s` (:1356-1532), `tag.s`, `tags.s`,
  `cp.s` (:136), `vi.s` (:4672); in Forth `ls.fs`, `httpd.fs`, `tag.fs`,
  `tags.fs`, `vi-edit.fs` (:156, the first 31 tags only). Programs that
  only open, read, write, stat, rename or unlink (`cat`, `rm`, `mv`,
  `touch`, `wdoom`, `guest`, `net`, Forth's `include`) do not change.
- **`hexdump N`** (READBLK) and the tests that read raw blocks:
  `tools/test-files.sh:71-80` checks directory and tag-table bytes at
  fixed blocks.
- **Tests with listings in their expected output**: `tools/test-sh.out`
  (:228-242, files in directory-slot order), `tools/test-http.out`
  (listing lengths), `tools/test-fs-progs.sh`, `os/demo.txt`.
- **`progs.pk`** (`tools/forth-pack.py`, `lang/forth/os/os.fs:21-28`)
  exists only because the directory had 128 entries.
- **Documents**: `doc/strataos.md` :869-956, `doc/manual/ch-os.tex`
  (:237, :664-700, :758-810), `ch-firmware.tex` (:140-190),
  `ch-appendices.tex:226`.

### 1.4 What the machine imposes

- **Local Stores.** A program has 32 KiB of I-LS and 40 KiB of D-LS plus
  an 8 KiB stack (`doc/strataos.md` :672-675). `fs` today uses 15.2 KiB of
  code (6.3 of it `sys.s`) and 37.1 KiB of data (13.1 of it `sys.s`), so
  3.8 KiB of data is free. Everything large must live in the arena (far
  memory, 832 KiB) and be worked on a piece at a time. Code beyond the
  I-LS can be paged as 2 KiB code units, as Forth does.
- **The block device** (`common/platform.h` :92-203, `ch-platform.tex`
  :425-541): 512-byte blocks, at most 256 per command, READ, WRITE and
  FLUSH, no discard. The device moves data straight between the disk and
  far memory that the server lends it; completion is the buffer coming
  back, which costs the server a trap and a wait.
- **Cost.** The emulator's transfers are instantaneous. On the RTL a
  512-byte block costs about 1,500 cycles on the bus (64 words, each a
  far-memory burst), and a command costs a trap and a wake-up on top
  (10,000 to 20,000 cycles, `doc/strataos.md` :656-662). A `tget` of
  4 KiB from the arena costs about 530 cycles. So the count of commands
  matters more than the bytes: large pages and a cache in far memory pay.
- **The server is assembly**, and the kernel must load the first servers
  with the firmware's block routines before any server runs.
- **One server per core.** The system needs six cores today; on the
  default eight, `net` and `ws` take the rest (`doc/strataos.md` :423-466).
- **No wall clock.** The timer counts microseconds since power-on; the
  emulator and the RTL disagree about it.
- **Nothing persists.** The emulator copies the image into memory and never
  writes it back (`emu/emu.c:259-313`); the RTL keeps the disk in an array
  and its `disk_write` hook is an empty stub (`sim/main.cpp:98`); the
  browser builds keep it in the module's memory; the FPGA disk is 128 KiB
  of block RAM. Persistence across a boot has never been exercised.

## 2. The model

### 2.1 Two layers

```
programs ── fs calls (paths, files, tags, queries) ──┐
programs ── db calls (namespaces, trees, keys) ──────┤
                                                     ▼
   fs layer: objects and indexes as trees in namespace "fs"
                                                     ▼
   db: namespaces → trees → keys and values; transactions; cursors
                                                     ▼
   pages: copy-on-write B+tree nodes, extents, free-space tree, cache
                                                     ▼
   block device
```

The same split as FoundationDB's layers over an ordered key-value store
([layer concept](https://apple.github.io/foundationdb/layer-concept.html)),
and as SQLite, where tables and indexes are both B-trees in one file
([file format](https://www.sqlite.org/fileformat2.html)).

### 2.2 The store

- A **tree** maps keys to values. Keys are byte strings compared as
  unsigned bytes, at most an eighth of a page (480 bytes with 4 KiB
  pages). A value is either short bytes kept in the leaf, or a **stream**:
  bytes addressed by offset, of any length, sparse, read and written by
  range. A value starts inline and becomes a stream when it outgrows a
  quarter of a page.
- A **namespace** is a set of named trees. It is the unit of ownership and
  of sharing. Namespaces and their trees are created and dropped at run
  time; nothing is counted in advance.
- A **transaction** covers any number of trees in any number of
  namespaces the caller holds, and commits or does not. One write
  transaction is open at a time; readers see the last commit.
- A **cursor** is a key: "the records after K". The server keeps nothing
  between calls, so a listing has no length limit and no state to leak.

### 2.3 The file system as trees

`fs` keeps these trees in namespace `fs`:

| Tree | Key | Value |
|---|---|---|
| `obj` | object id (u64, big-endian, never reused) | the record: kind, size, created and modified (commit numbers), name, tag ids, attributes |
| `data` | object id | the contents (inline when small, else a stream) |
| `name` | name | object id |
| `attr` | attribute id, value, object id | empty |
| `dict` | `t` tag name, `a` attribute name, and the reverse by id | id, count of objects, flags |

- An **object** is contents plus a record. Its identity is the id, so
  renaming touches `name` and the record, never the contents, and an open
  file survives a rename.
- A **name** is one indexed attribute among others. It is at most 255
  bytes, any bytes but `/` and zero.
- A **tag** is the multi-valued attribute `tag`; its index entries are
  (tag attribute, tag id, object id). Tags are created by use and dropped
  with their last file, as now; their number is unbounded, their names up
  to 255 bytes.
- **Size and times** are in the record. Times are commit numbers: ordered,
  and the same on every machine, which a clock is not here. Indexing size
  and modification is optional per disk (two more entries in `attr` per
  write); the proposal is to index them.
- **Any other attribute** is a name and a value (an unsigned integer or a
  string) set by a program: `type=text`, `author=...`, `width=320`.
  Attributes are indexed unless created as unindexed. Integer values are
  stored big-endian and strings with a terminator, so byte order in the
  tree is value order and a range of values is a range of keys. This is
  BeFS's attributes and indexes
  ([Giampaolo, *Practical File System Design*](http://www.nobius.org/practical-file-system-design.pdf),
  chapters 4 and 5) with the difference that the indexes are not a special
  structure: they are trees of the same store. WinFS aimed at the same
  from the other side, a database with files in it
  ([overview](https://en.wikipedia.org/wiki/WinFS)).

**Directories do not exist.** A path is a query: the components before
the last are conditions, and the last is a name (or, in a listing, one
more condition). `/src/demo/hello.s` is "tag src and tag demo and name
hello.s". The current tag path stays as it is, a prefix of conditions kept
per process. Hierarchy can be had by convention where wanted (a tag per
level), but nothing nests on the disk. Whether to add real hierarchy is
open question 2.

### 2.4 Queries

A query is a conjunction of terms; every term is answered by a range of
one tree:

| Term | Written (proposal) | Answered by |
|---|---|---|
| name is N | last component | `name`: one lookup |
| name starts with P | `P*` | `name`: the range [P, P+1) |
| names from A to B | `A..B` | `name`: a range |
| has tag T | `T` | `attr`: the range (tag, id of T) |
| has not tag T | `-T` | a lookup per candidate |
| attribute = v, < v, > v, a range | `size>4096`, `type=text` | `attr`: a range |
| everything | `/` | `obj` in id order, or `name` in name order |

Evaluation: if the query bounds the name, walk `name` and check the other
terms against each candidate's record. Otherwise walk the `attr` ranges
together, each seeking to the largest id the others have reached (all are
in id order, so a combination of tags costs about as much as its rarest
tag), then check exclusions. Results come in name order in the first case
and in id order (creation order) in the second; a program that wants
another order sorts, as `ls` would. The reply holds as many records as fit
in a message and a cursor; the caller passes the cursor back for more.

Tab completion is a prefix query with the current path's tags as the other
terms. Facets (the other tags of the matching files) are computed from the
records of a query as it is read; for `/` they are the whole `dict`. Tag
counts are kept in `dict`, so `tags` does not scan.

## 3. On-disk structures

### 3.1 Candidates

| Candidate | For | Against here |
|---|---|---|
| **Copy-on-write B+tree**, two root blocks written in turn (LMDB) | A commit is atomic with no log and no recovery: mount reads two blocks. Ordered, so prefix, range and cursor come free. One structure for everything, including free space. Snapshots later for nothing. | Every change rewrites a path to the root (2 to 4 pages); freed pages must wait for the commit; fragmentation over time. |
| Log-structured merge tree | Sequential writes; good for bursts of small updates. | Reads look in several runs; compaction needs free space and background work in a single-threaded assembly server; range scans merge runs. Writes are not this machine's bottleneck. |
| A log with indexes rebuilt in memory at mount | Smallest code; this is close to what `fs` does now. | Memory and mount time grow with the number of objects: a million names do not fit in 832 KiB. It is the present limit in another form. |
| Update-in-place B-tree with a journal (ext, BeFS) | Stable page addresses; less rewriting. | Two write paths, and replay at mount: the code that runs only after a crash is the code that is wrong. |
| Extent tree with a free-space index (XFS, btrfs) | Needed anyway for large contents. | It is a part, not an alternative: it is two more trees of the chosen kind. |
| Metadata pairs and a skip list (littlefs) | Built for kilobytes of RAM and for wear. | No ordered index; directory scans are linear. Its lesson is kept: bounded RAM, and copy-on-write instead of a journal ([DESIGN.md](https://github.com/littlefs-project/littlefs/blob/master/DESIGN.md)). |

**Chosen: copy-on-write B+trees throughout**, in the manner of LMDB
([documentation](http://www.lmdb.tech/doc/)) for the commit and of btrfs
for "everything is an item in a tree"
([on-disk format](https://btrfs.readthedocs.io/en/latest/dev/On-disk-format.html);
Rodeh, [B-trees, shadowing, and clones](https://dl.acm.org/doi/10.1145/1326542.1326544)).
The deciding reasons: no recovery code; a root is one page number, which is
all the kernel needs at boot; and the server already serves one request at
a time, which is exactly the single-writer rule this design wants.

### 3.2 Pages and the fixed part

- **Page size** is a field of the disk, 1, 2 or 4 KiB; 4 KiB by default
  (one device command of 8 blocks; one `tget` to bring a page into the
  D-LS). The 128 KiB FPGA disk would use 1 KiB.
- **Page 0** holds the boot header in its first 512 bytes, as now (the
  firmware does not change), with two new fields: the format ("STDB1") and
  the page size. Nothing in it changes after `mkdisk`; everything that
  changes is reached from a meta page.
- **Pages 1 and 2 are the two meta pages.** Only the first 512 bytes of
  each are used, so that a meta write is one block. A meta page holds: the
  commit number, the root of the catalog, the root of the free-space
  tree, the root of the pending-free tree, the boot manifest's page, the
  disk's size in pages, the next object-independent counters (next
  namespace id), and a checksum. A commit writes the meta page it did not
  write last time. Mount takes the one with a good checksum and the higher
  commit number.
- **The catalog** is a tree: (namespace id, tree name) → the tree's root
  page, height and entry count; and namespace name → id and flags. A tree
  is created by inserting a catalog entry.
- The kernel's images stay where `mkdisk` puts them, as extents that the
  free-space tree does not contain.

### 3.3 Nodes

Every page starts with a 32-byte header: checksum (u64), the page's own
number, the commit that wrote it, kind (branch, leaf, stream data is
headerless), level, cell count, and the offset where free space ends. Then
a slot array of u16 cell offsets growing up, and cells growing down from
the end, as in SQLite and LMDB. Cells are sorted through the slot array,
so an insert moves 2-byte slots, not cells.

- Leaf cell: key length (u16), value length and kind (u16), key, value.
  Value kinds: inline bytes; a stream descriptor (length u64, and either
  one extent or the stream's first key in the extent tree).
- Branch cell: key length (u16), child page (u64), separator key. A
  separator is the shortest string that separates the two children, not a
  whole key, so long names do not thin the upper levels.
- A cell is at most a quarter of the page, so a node always splits into
  nodes of at least two cells. Keys longer than an eighth of a page are
  refused (480 bytes at 4 KiB: a 255-byte name, and an attribute index key
  of a 4-byte id, a 255-byte string and an 8-byte object id, both fit).
- Nodes split when full and merge with a neighbour when under a quarter
  full. An append-only load (`mkdisk`, ascending object ids) splits at the
  end, leaving full nodes behind.

### 3.4 Contents, extents and free space

- **Small contents** (up to a quarter page, about 1,000 bytes) live in the
  `data` leaf: `rc`, `motd`, short scripts and notes need no extent.
- **A stream** is a list of extents (start page, page count). One extent is
  recorded in the descriptor itself. More than one go to the namespace's
  extent tree: (stream id, offset in pages) → (start page, pages). A
  missing range reads as zeros: sparse files cost nothing. Length is a
  u64. A stream is read with one device command per extent per 128 KiB,
  straight into the caller's arena when the caller attached one (as
  LOADIMG and READALL do now).
- **Writing** goes to the disk as it arrives, into newly allocated pages;
  there is no 128 KiB region and no limit of three writers. Appending
  asks the allocator for the pages after the stream's last extent, and
  for a growing run otherwise (double the last request, up to 256 pages),
  so a file written in 4 KiB pieces ends as a few extents. The unused end
  of the last run is given back at close. Overwriting the middle of a
  stream writes new pages and replaces that range's extent (the extent is
  split in the tree); the old pages are freed at commit.
- **Free space is a tree**: an extent's end page → its page count (by
  end, because allocation takes pages from an extent's front: the key
  stays while the count shrinks), coalesced with its neighbours. Allocation is first fit from a hint (the end of
  the stream being extended, else the last allocation), so it reuses any
  hole, not just the one at the end.
- **Pending frees.** A page freed by a transaction is not reusable until
  that transaction is on the disk, or a crash would leave the old tree
  pointing at overwritten pages. Freed extents go to a second tree keyed
  by (commit number, start), with the commit that wrote the pages, and the
  next transaction takes the committed ones for reuse. (With snapshots
  this same tree says which pages a snapshot still needs, section 4.1.)
- **The allocator does not recurse.** Changing the free tree needs pages
  and frees pages. At the start of a transaction the allocator takes a
  reserve of free extents into memory and serves the transaction from it;
  frees accumulate in a list in far memory; at commit both are written
  into the trees in a loop that ends when a pass frees no page (one or
  two passes in the tests; LMDB saves its free list the same way). The
  last extent of the reserve is not put back into the tree, since that
  insert could need more pages than the extent has: the meta page holds
  it as the *spare extent*. A new disk has no free tree at all, only a
  spare extent.

### 3.5 Growth and sizes

Nothing is counted in advance: objects, tags, attributes, namespaces and
trees are entries in trees; the disk's size is a field of the meta page,
so a larger image is adopted by raising it. Page numbers are u64 in the
format; the code may assume 32 bits (16 TiB) at first.

Estimates with 4 KiB pages, names of 12 bytes on average, two tags per
file, nodes 70% full (cells: `obj` 96 bytes, `name` 26, tag 18, extent
34; 30, 110, 155 and 83 per leaf):

| Objects | `obj` | `name` | tags | extents | All metadata | Height (`obj` / `name`) |
|---|---|---|---|---|---|---|
| 100 | 5 pages | 1 | 3 | 1 | 14 pages, 56 KiB (with catalog, free tree, metas) | 2 / 1 |
| 10,000 | 338 | 92 | 131 | 122 | about 690 pages, 2.7 MiB | 3 / 2 |
| 1,000,000 | 33,650 | 9,170 | 13,000 | 12,140 | about 68,000 pages, 266 MiB | 4 / 3 |

About 270 bytes of metadata per object, against 40 today; a small disk
pays about 50 KiB of fixed cost. (Built since: `tools/stdb/many.c` makes a
million files with two tags and an attribute each and checks the whole
store, in about ten seconds on the host; the trees are 3 and 4 levels high
with 4 KiB pages, as estimated. With aligned cells the per-object cost is
somewhat above the estimate.) The million-object case needs a device
larger than today's 16 MiB (`STX_DISK_BLOCKS`); the emulator already
accepts a larger image, the RTL harness does not.

## 4. Consistency

- **A commit** is: write every new page (to free pages, so nothing live is
  overwritten); FLUSH; write the other meta page; FLUSH. Before the second
  write the disk holds the old state; after it, the new. There is no
  moment in between, no log to replay and nothing to repair at mount.
- **What survives a power cut or a halt**: everything committed.
  A transaction in progress vanishes; its pages are still in the free
  tree of the last commit.
- **When commits happen.** Each change made outside a transaction (an fs
  call such as UNLINK, TAG, RENAME; the close of a written file) is its
  own commit, and its reply means it is on the disk. Writes to an open
  file are committed at close, at SYNC, and whenever the file has grown
  by a set amount (1 MiB) so that a long write does not hold an unbounded
  set of dirty pages.
- **Replacing a file is atomic.** Opening for writing with truncation
  creates a new stream; the close switches the object to it and frees the
  old one in one commit. A crash leaves the old contents or the new, never
  a mixture; today a crash during `save_file` can leave a directory that
  points at half-written blocks. Appending extends in place and commits
  at close.
- **Transactions for programs.** Yes: BEGIN, any number of operations on
  trees of namespaces the caller holds (and fs calls, which join it),
  COMMIT or ABORT. Most uses need only BATCH: one message carrying
  several puts, deletes and conditions ("this key must be absent"),
  applied atomically; `fs` itself is written with batches. While a
  transaction is open, other writers wait (their requests are parked);
  readers are served from the last commit, which costs nothing because
  the writer's pages have new numbers. A transaction whose owner dies is
  aborted by CLEANUP; one idle for longer than a limit is aborted too.
- **Checksums.** Every tree page and both meta pages carry a 64-bit
  checksum over the page, seeded with the page's number (a page written
  to the wrong place fails it). It is verified when a page enters the
  cache. Stream data is not checksummed in the first version (it would
  need a checksum per extent in the tree; ZFS and btrfs do this and it
  can be added in the extent's value later).
- **A checker.** `stdb check IMAGE` on the host: both meta pages; every
  tree from its root (checksums, key order, levels, fill, separators);
  every page reached exactly once or free or pending, none twice, none
  lost; the kernel's extents; then the fs layer's invariants (each `name`
  entry has its object and the object has that name; each `attr` entry
  has its attribute in the record and the reverse; `dict` counts; every
  stream's extents inside the disk); and the boot manifest (section 6).
  A smaller `fsck` program in the OS can follow.

### 4.1 Snapshots

A snapshot is the whole store as of one commit, under a name: every
namespace, every tree, every file. Taking one records that commit's
catalog root in a tree of snapshots; it copies nothing. It is read-only
and is opened like a namespace (`NSOPEN` of `fs@NAME`); for files, a
first path component `@NAME` reads the file system as it was (`ls
/@monday/src`, `cat /@monday/notes`), so `cp /@monday/notes notes` brings
an old version back.

What a snapshot costs is the pages it keeps from being reused. Every tree
page and every extent records the commit that wrote it (its birth). When
the live store stops using a page:

- born after the newest snapshot: no snapshot can see it; it is freed as
  described in 3.4;
- born before: the newest snapshot still needs it. It goes to that
  snapshot's dead list (entries in the pending tree under the snapshot's
  commit number, with the birth kept).

Deleting a snapshot walks the dead list of the snapshot after it (or of
the live store): entries born after the snapshot before it become free,
the rest move to that earlier snapshot's list. This is the scheme of ZFS's dead lists
([OpenZFS documentation](https://openzfs.github.io/openzfs-docs/)); it
needs no reference counts and no walk of the trees.

## 5. Working within the Local Stores

- **A page cache in far memory**: 128 frames of 4 KiB (512 KiB of the
  server's arena; today that space is the I/O buffer and the write
  regions). The table (page number, frame, dirty, pinned, clock bit) is
  16 bytes per frame, 2 KiB in the D-LS, searched by a small hash. The
  device reads and writes frames directly (it is far memory the server
  lends, as now).
- **Node at a time.** The D-LS has three page buffers (12 KiB). To search,
  the server brings one node into a buffer with one `tget`, does a binary
  search over its slots, and goes down. A split needs the node, its new
  sibling and the parent: three buffers. Changed buffers go back to their
  frames with `tput`. Nothing else is ever resident: the trees can be any
  size.
- **Dirty pages** stay pinned in the cache until the commit. A commit
  writes them with as few commands as their page numbers allow; the
  allocator hands a transaction consecutive pages, so it is usually one
  command. If dirty pages would fill the cache, they are written early
  (they are in free pages; only the meta write makes them visible).
- **Budget.** D-LS: 12 KiB buffers, 2 KiB cache table, 5 KiB current
  paths, 3 KiB open streams and handles, 4 KiB request staging, 1 KiB
  srv.s, and `sys.s` without its three stdio buffers (5 KiB): 32 of 40
  KiB. I-LS: an estimated 28 KiB of store and fs code (section 10)
  against 32 KiB with the library; the code that runs rarely (mount,
  namespace administration, the checker's hooks) goes into code units if
  it does not fit.

Device commands per operation, with 10,000 objects and the branch pages
cached (they are about ten pages; the leaves are 690, more than the
cache):

| Operation | Reads | Writes | Today |
|---|---|---|---|
| Look up a name (open, stat) | 0 to 2 (a `name` leaf, an `obj` leaf) | 0 | 0 (directory in memory) |
| Read a small file | +0 or 1 (`data` leaf, usually the one just read) | 0 | 1 per READ |
| Read a large file | +1 (extents) and 1 per extent per 128 KiB | 0 | 1 per READ of 4 KiB |
| One step of a listing, names only | 1 per about 110 names | 0 | 0, but 126 at most |
| One step of a listing with sizes | the above, +1 per about 30 objects when in id order | 0 | 0 |
| Create and write a file | 0 to 4 leaves | 1 per data extent; then the commit: 1 write of 8 to 14 pages, FLUSH, 1 meta block, FLUSH | 1 data write, 3 metadata writes (83 blocks), no FLUSH |
| Delete, rename, tag | 0 to 3 leaves | the commit: 4 commands | 3 metadata writes |
| Mount | 2 meta blocks, the catalog root | 0 | the whole directory and tag table |

On the RTL a commit is about 4 commands and 100 KiB moved at most:
roughly 250,000 cycles, the cost of two dozen context switches (an
estimate from the bus timings, not a measurement). With a million objects
a cold lookup reads up to 7 pages; the top two levels of each tree then
stay in the cache, and the third level (about 400 pages for all trees)
and the leaves turn over in it.

## 6. Booting

The kernel must load `proc`, `dev` and `fs` before a server runs, with the
firmware's block reads and about 2 KiB of code per unit. It will not walk
trees. Instead:

- **A boot manifest**: one page, pointed to by the meta page, holding
  entries {name[16], first page, length in bytes} for every object with
  the attribute `boot`, and a checksum. It is written copy-on-write in
  the same commit as any change to those objects, so it is never stale.
- **Boot objects are kept in one extent.** The store allocates a boot
  object's contents contiguously or fails the write. Replacing `fs` from
  inside the OS (`cp newfs fs`) therefore updates the manifest atomically
  with the file.
- **The kernel's part** (replacing `u_disk` and `u_findfile`): read page
  0's header for the page size; read the two meta blocks, check each
  checksum, take the newer; read the manifest page, check it; find three
  names in it; load each run as now. About 150 instructions, most of them
  the checksum. A bad meta pair or a missing server halts with a message
  naming it, as now.
- **Checked.** `mkdisk` writes the manifest and fails if a named boot
  object is missing; `stdb check` verifies that each entry matches its
  object's single extent; the store refuses a commit that would break it.
  The "first 128 files" rule and its silent failure are gone.
- The kernel's own images stay in the boot header (the firmware's
  contract). Listing them as objects too, so that a kernel can be
  installed from inside the OS, is possible later and not proposed now.

## 7. The protocol

### 7.1 One server or two

The store and the fs layer are **two modules of one server process**,
which stays on the core `fs` has now and registers both names, `fs` and
`db`. Reasons: every core hosts one server and the default machine has
none to spare; a file call would otherwise cost two to seven more
messages; and the fs layer needs to act when a written file closes (size,
modification, indexes), which is a plain call inside one process. The
layering is kept by construction: the fs module calls the same entry
points the db messages call, on namespace `fs`, and touches no page. If
cores stop being scarce the two can be separated without changing a
client. This is open question 1.

### 7.2 Store calls (new, op numbers from 64)

| Op | Call | Data → reply |
|---|---|---|
| 64 | NSOPEN | name, mode (read, write, create) → a namespace handle |
| 65 | NSGRANT | handle, pid, rights (read / write / grant) → 0; the other process now holds it |
| 66 | NSDROP, NSSTAT, NSLIST | administration |
| 67 | TREE | namespace, tree name, create? → a tree number |
| 68 | GET | tree, key → value (or a stream's length) |
| 69 | SCAN | tree, from key (after / at / before), end key, flags (keys only, backwards) → records {key length, value length, key, value} to the message's size; the last key is the cursor |
| 70 | BATCH | a list of PUT, DELETE, DELETE-RANGE, ADD (a counter), REQUIRE-ABSENT / PRESENT / EQUAL → 0, or the number of the condition that failed; atomic |
| 71-73 | BEGIN, COMMIT, ABORT | a transaction across calls |
| 74 | SOPEN | tree, key, mode → a stream as an ordinary handle: READ, WRITE, CLOSE (1, 2, 4) work on it |
| 75 | SREAD, SWRITE, STRUNC | a stream by offset, to or from an attached arena |
| 76 | SYNC | commit what is pending → the commit number |

A namespace handle is held like a file handle: counted per process by the
server, passed to children by SPAWN, dropped by CLEANUP. Sharing a
namespace is NSGRANT, or opening it by name when its flags allow
(question 5). The namespace `fs` is created by `mkdisk` and is the fs
module's alone; a program that wants to read file metadata directly can
be granted it read-only.

### 7.3 File calls

| Today | Becomes |
|---|---|
| 3 OPEN, 1 READ, 2 WRITE, 4 CLOSE | The same. No 128 KiB limit; writes go to the disk as they come; replace is atomic at close. Names up to 255 bytes. |
| 27 STAT | The same reply (size); 44 STATX gives the whole record. |
| 11 UNLINK, 15 RENAME | The same; each is one commit. |
| 12 TAG, 13 UNTAG | The same; any number of tags; names up to 255 bytes. -6 no longer happens. |
| 20 CWD | The same; the path may be longer and may hold attribute terms. |
| 28 LOADIMG, 34 READALL, 35 WRITEALL | The same (the stream is read by extents into the arena). |
| 32 STATFS | The same three numbers (blocks are 512 bytes as before), from counters. |
| 33 READBLK | The same: a raw block, for `hexdump N`. |
| 10 DIR | Kept for the transition in its present form (32-byte records, skip count, a u64 of facets): names longer than 24 bytes are cut, tags with ids above 63 are missing from the facets. Removed when the clients have moved to 40. |
| 14 TAGS | Kept likewise (16-byte names, the first 126). Replaced by 41 with a cursor. |
| — | **40 QUERY**: data = a path (a query), then a cursor (empty at first); mode = what to return (names; + size and times; + tag names; + named attributes) → records of variable length {record length, object id, size, modified, name length, name, ...}, the facets of these records as tag names, and the cursor for the next call (empty: done). |
| — | **41 TAGS2**: every tag, or a file's, as {count, name length, name}, with a cursor. |
| — | **42 SETATTR / 43 GETATTR**: path, attribute name, value; all of a file's attributes. |

### 7.4 What changes for each client

- `os/lib/sys.s`: `sys_list` (open a query, next record, hiding the
  cursor and the messages), `sys_tags2`, `sys_setattr`, `sys_getattr`;
  `sys_query`, `sys_fskip`, `sys_facets` go with DIR.
- `ls`: reads with `sys_list`; prints names of any length; sorts by name
  when the result came in id order (in the arena; beyond what fits it
  prints in the order given).
- `sh`: completion becomes a prefix query (fewer candidates, no 126 cap,
  and `is_prog` checks only names that match); the 32-byte name buffers
  grow.
- `httpd` and `httpd.fs`: listings are read to the end with the cursor
  and sent as they come; the loops over 64 tag bits become loops over the
  facet names.
- `tag`, `tags`, `cp -t`, `vi` (the file's tags for highlighting): TAGS2.
- `cp`, `vi`, `touch`, `cp.fs`, `vi-edit.fs`: the "128 KiB at most"
  refusals go.
- Forth `sys.fs` and the ports: the same as their assembly originals.
  `progs.pk` is no longer needed; whether to unpack it is a separate
  choice.
- `proc`: nothing but longer names (its 24-byte program name field).
- `tools/test-files.sh` reads raw directory blocks: rewritten against
  `stdb dump`. The expected outputs with listings in slot order
  (`test-sh.out`, `test-http.out`) are regenerated once; `ls` output is
  sorted from then on, so later changes to the disk's contents do not
  reorder it.
- New: `db` (a shell utility to list namespaces and trees, get, put,
  scan), `attr`, and query terms in paths for every program at once,
  since paths are resolved in the server.

## 8. Tools

- **`tools/stdb/`**: the store in C (pages, trees, allocator, commit,
  streams, namespaces) and the fs layer over it, as a library. It is the
  reference for the assembly: same format, same algorithms, same
  allocation decisions, so the two can be compared image for image.
- **`mkdisk`** keeps its command line (`-t tags`, `-b blocks`) and writes
  the new format through the library; new options: `-p` page size, `-B`
  to mark boot objects (default: `proc`, `dev`, `fs`), `-a name=value`.
  `-n` goes: nothing is preset.
- **`stdb`**: `check`, `dump` (a canonical text of every namespace, tree,
  key and value, independent of page placement and commit numbers),
  `ls QUERY`, `get`, `put`, `rm`, `tag` on an image; so files can be
  taken out of a disk the OS wrote.
- **Persistence.** Emulator: `-d FILE` stays read-only; `-w` writes the
  image back, at exit and at each FLUSH. RTL harness: fill in the
  `disk_write` hook and write the image at exit under the same option.
  Browser: keep changed blocks in IndexedDB and offer the image for
  download (a later stage).
- **Crash injection** in the emulator: `--disk-cut N` stops the machine
  at the Nth write command, optionally in the middle of it (the first k
  blocks written), and with `--disk-cache` drops a seeded subset of the
  writes since the last FLUSH, as a drive with a volatile cache would.
  The image is then given to `stdb check`.

## 9. Tests

- **Host, store**: random operations against an in-memory map, with
  `check` after every commit; every key and value size around the page
  fractions; trees to four levels; full disk; the allocator's commit
  loop.
- **Host, crashes**: a workload of N commits is cut at every single block
  write; every resulting image must pass `check` and `dump` equal to the
  state after commit k or k+1 for the k at which it was cut.
- **Many files**: 10,000 files on a 64 MiB image in the emulator (create,
  list by tag, by prefix, delete every other one, create again and check
  that space was reused); 1,000,000 objects on the host only.
- **Emulator against the C library**: the same scripted session through
  the OS and through the library must give equal `dump`s, and equal
  images when commits are taken at the same points.
- **Emulator against RTL**: `compare-boot.sh` gains a comparison of the
  two disks' `dump`s after the session (times are commit numbers, so
  they agree).
- **Across a boot**: a session writes, halts; a second boot of the
  written image reads it back. With `--disk-cut` in the middle of the
  first session, the second boot must come up and show the last
  committed state.
- **Boot manifest**: replace `fs` from inside the OS, reboot; a disk
  without a server fails in `mkdisk`.
- The present suites (`test-sh`, `test-http`, `test-fs-progs`,
  `test-vi`, `test-files`, `test-wdoom`) with regenerated listings.

## 10. Stages

Sizes are lines of new code, rough.

| Stage | What | Size | Result |
|---|---|---|---|
| 1 | The store and fs layer in C; `mkdisk` on it; `stdb check / dump / ls / get`; host tests with crash cutting | 2,500 C, 800 tests | A format that is checked before any assembly exists |
| 2 | Emulator `-w` and crash options; RTL harness write-back | 250 C | Persistence can be tested at all |
| 3 | Boot: the manifest in `mkdisk`, the kernel's `u_disk` / `u_findfile` | 200 asm | The kernel boots from the new image |
| 4 | The store in assembly, reading: mount, cache, search, scan, stream read; fs reading (OPEN, READ, STAT, LOADIMG, READALL, QUERY, DIR and TAGS as they are, CWD, STATFS) | 2,500 asm | The OS boots and runs everything that does not write |
| 5 | Writing: allocator, insert and split, delete and merge, commit, stream write, batches and transactions; fs writing | 2,500 asm | Feature parity without the limits; crash tests in the emulator; the comparison with the C library |
| 6 | Clients: `sys_list`, `ls`, `sh`, `httpd`, tag tools, the refusals, the Forth ports; DIR and old TAGS removed; documents | 800 asm, 300 Forth | The 126 and 24-byte limits gone from programs too |
| 7 | The store for programs: namespace calls, grants, `db`, Forth words; attributes, `attr`, query terms in paths | 900 asm | The database facility in use beyond `fs` |
| 8 | Snapshots (section 4.1): SNAP calls, `snap` utility, reading a snapshot through a path | 500 asm, 300 C | The disk as it was, by name |
| 9 | Later: browser persistence, `fsck` in the OS, data checksums | — | — |

Stages 1 to 3 change no server. From stage 4 the old `fs.s` is replaced;
the old format is not read (disks are always built by `mkdisk`), so there
is no migration.

**Left out of the first version**: versions of single files (a snapshot
is of the whole store); permissions
finer than a namespace handle; more than one writer at a time; checksums
of file data; defragmentation and compaction (free space coalesces, files
do not move); wall-clock times; full-text or substring search; discard;
hard links (an object has one name; tags do what links did).

## 11. Decisions

1. **One server.** The store and the fs layer are two modules of one
   process that answers both `fs` and `db` (7.1).
2. **A directory is a set of tags; names per directory.** Tags are the
   only grouping. The set of a file's tags is its directory (`/src/demo`
   is `/demo/src`), a file with no tag is in the root, and a name is
   unique within a directory: the name index's key is the tag ids in
   order and the name, one entry a file. So `/src/x` and `/src/demo/x`
   are two files. A directory's subdirectories are the other tags of the
   files in deeper directories. RENAME, TAG and UNTAG each move a file to
   another directory in one step. A program is looked for where its
   starter is, then in `/bin` and `/sys`.
3. **Snapshots are wanted** (section 4.1, stage 8). The format carries
   what they need from the first stage, so adding them changes no disk.
4. **Query terms are path components** (`ls '/src/size>4096'`), quoted in
   the shell where they hold `>` or `*`.
5. **A namespace is private or public**, chosen when it is created:
   private to its creator and whoever it grants, or open to anyone by
   name. `fs` is private to the fs module.
6. **The server is assembly.** The C in `tools/stdb/` is the host's side
   of the format (`mkdisk`, the checker) and the reference the assembly is
   compared with.
7. **Every metadata change and every close is a commit.**

**Where the code lives.** The emulator, the RTL and the browser build
know nothing of the store: they model a block device, as now. What they
gain is the device's own behaviour: keeping what was written (`-w`) and
losing power (`--disk-cut`). The store and the file system are in `os/`.
The host knows the format only in `tools/` (`mkdisk` must write a disk,
and a checker must read one), as `mkdisk` knows the present one.
