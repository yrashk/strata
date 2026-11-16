# The store's disk format

This is the format of a StrataOS disk as `tools/stdb/` writes and checks
it and `os/servers/fs.s` reads and writes it. The design and its reasons
are in `strata-fs-proposal.md`; the code is the reference
(`tools/stdb/store.c`, `tools/stdb/fsl.c`), and `build/stdb check IMAGE`
checks a disk against everything said here.

Numbers are little-endian unless said to be big-endian; keys that must
sort as numbers are big-endian. The device has blocks of 512 bytes. The
store works in *pages* of 1024, 2048 or 4096 bytes (4096 unless `mkdisk
-p` says otherwise); page *n* starts at byte *n* × page size. Every field
lies at a multiple of its size, and every cell at a multiple of 8, because
the machine's loads and stores must be aligned.

## The disk

| Pages | Contents |
|---|---|
| 0 | the boot header, in the first block (`firmware/bootrom.s`). Offset 56: `STDB`; offset 60: u32 page size |
| 1, 2 | the two meta pages; only the first block of each is used |
| 3 … *first* − 1 | what `mkdisk` put there: the kernel's code, data and far images |
| *first* … | tree pages and stream data |

## The meta block

Commit *c* is described by the meta block in page 1 + (*c* & 1), so a
commit never writes over the block of the commit before it. At mount the
block with a good checksum and the larger commit number is the disk's
state; the other is the state before.

| Offset | Field |
|---|---|
| 0 | checksum of this block (512 bytes), seeded with the page's number |
| 8 | `STDBMETA` |
| 16 | commit number |
| 24 | pages on the disk |
| 32 | *first*: the first page the store manages |
| 40, 48 | the catalog: root page, height |
| 56, 64 | the free tree: root, height |
| 72, 80 | the pending tree: root, height |
| 88 | the boot manifest's page (0: none) |
| 96 | the next namespace id |
| 104 | free pages (those in the free tree and the spare extent) |
| 112 | page size |
| 120, 128 | the spare extent: start, pages (free pages that are in no tree) |
| 136 | the next stream id |

A tree with height 0 is empty and has no root page.

## The checksum

Of a page, or of a meta block's 512 bytes: over its 8-byte words except
the first, which holds the result.

    h = seed * 0x9E3779B97F4A7C15 + 0xCBF29CE484222325
    for each word w after the first:  h = (h ^ w) * 0x100000001B3
    checksum = h ^ (h >> 32)

All in 64 bits. The seed is the page's number, so a page written to the
wrong place does not pass. Stream data pages have no checksum.

## A tree page

| Offset | Field |
|---|---|
| 0 | checksum of the page |
| 8 | the page's own number |
| 16 | the commit that wrote it (its *birth*) |
| 24 | u8 kind: 1 branch, 2 leaf (3: the boot manifest, not a tree page) |
| 25 | u8 level: 0 for a leaf |
| 26 | u16 cells |
| 28 | u16 where the cells start |
| 32 … | a u16 offset per cell, in key order |

The cells fill the page from its end downwards; each starts at a multiple
of 8 and is padded with zeros to a multiple of 8.

- A **leaf cell**: 0 u16 key length; 2 u16 value length, with bit 15 a
  flag (the value is a stream, below); 8 the key; the value at the next
  multiple of 8 after the key.
- A **branch cell**: 0 u16 key length; 8 u64 child page; 16 the key.
  Child *i* holds the keys from key *i* up to key *i* + 1. The key of cell
  0 is not looked at: its child holds everything below key 1.

Keys compare as unsigned bytes, a shorter key before a longer one it is
the start of. A key has 1 to page size / 8 − 32 bytes (480 with 4 KiB
pages). A cell has at most ((page size − 32) / 4 − 2) rounded down to a
multiple of 8 bytes (1008), so an inline value beside a key of *k* bytes
has at most that less 8 less *k* rounded up to 8.

Pages are never changed in place once a commit holds them: a change
copies the page to a free one (with the new commit as its birth) and the
path to the root with it. A page born in the commit being made is changed
where it is.

## The store's own trees

**The catalog**: u32 namespace id (big-endian), then the tree's name →
u64 root, u64 height. Every tree but the three in the meta block is found
here.

**Namespace 0** holds the store's own named trees:

- `ns`: a namespace's name → u64 id, u64 flags (bit 0: public: any
  program may name it).
- `snap`: u64 commit (big-endian) → u64 catalog root, u64 height, then the
  snapshot's name. A snapshot is the catalog as it was at that commit.

**The free tree**: u64 *end* page of a free extent (big-endian; the page
after its last) → u64 pages. By its end, because pages are taken from an
extent's front and the key then stays. A record of 0 pages means nothing.

**The pending tree**: u64 commit, u64 start page (both big-endian) → u64
pages in the low 32 bits and the namespace the pages were of in bits 32
to 62, then u64 birth. These are pages freed by that commit: free once
that commit is on the disk. A key whose commit has its top bit set is the
*dead list* of the snapshot of that commit: pages the store no longer
uses but that snapshot (or an older one) still shows. They are not free
until the snapshot is deleted.

The allocator's last free extent may be in no tree: it is the spare
extent in the meta block.

## Values and streams

A value is inline bytes in its cell, or, with the flag set, a **stream**:
u64 length in bytes, u64 stream id. A stream's pages are found in the
tree `.ext` of the same namespace: u64 stream id, u64 offset in pages
(both big-endian) → u64 first page, u64 pages, u64 birth. A range with no
extent reads as zeros. Stream pages hold data only, with no header.

## The file system: namespace `fs`

| Tree | Key → value |
|---|---|
| `obj` | object id (u64 big-endian) → the file's record |
| `data` | object id → the contents (inline or a stream; none when the file is empty) |
| `dnam` | the file's tag ids in ascending order (u32 big-endian each), four zero bytes, the name → u64 object id |
| `attr` | the index: u32 attribute id (big-endian), value, object id (big-endian) → nothing |
| `dict` | counters and the names of tags and attributes |

**A record** (at most a quarter page): 0 u8 kind (1: a file); 1 u8 flags
(bit 0: a boot object); 2 u16 tags; 4 u16 attributes; 6 u16 name length;
8 u64 size; 16 u64 created; 24 u64 modified (commit numbers); from 32 a
u32 tag id per tag, padded to a multiple of 8; then per attribute u32 id,
u8 type (0 integer, 1 string), u8 length, u16 0 and the value padded to a
multiple of 8 (an integer is 8 bytes); then the name (at most 255 bytes).

**The names.** A file's directory is the set of its tags, and a name is
unique within a directory: `dnam` has one entry a file, under its tag ids
in ascending order, four zero bytes (no tag has id 0) and its name. A file
with no tag is in the root: four zero bytes and the name.

**The index** has an entry for every tag a file carries (for a file with
no tag: one under tag id 0, the root's listing) and every attribute it
has. Attribute ids: 1 a tag (value: the u32 tag id,
big-endian); 2 size and 3 modified (u64, big-endian); 4 boot (no value);
16 and up, the attributes made by name: an integer as u64 big-endian, a
string followed by a zero byte.

**The dictionary**:

- `!` → u64 next object id, u64 objects, u32 next tag id, u32 next
  attribute id.
- `t` + a tag's name → u32 id, u32 0, u64 files carrying it.
- `T` + the id (u32 big-endian) → the name.
- `a` + an attribute's name → u32 id, u32 type.
- `A` + the id (u32 big-endian) → the name.
- `w`, seven zero bytes, an id (big-endian): the key in `data` of
  contents that are being written and belong to no file yet. The server makes the entry when a
  long write commits part of the way and removes it at the close; at
  mount it frees what such entries name.

## The boot manifest

The kernel loads the first servers before any server runs, and reads no
tree for it. The meta block points at one page: a header as a tree
page's, with kind 3; `STBOOTMF` at 32; a u32 count at 40; from 64, entries
of {name[16], u64 first page, u64 bytes}. They are the files with the boot
flag, and each one's contents are a stream in one extent from its offset
0. `mkdisk` writes the manifest (`-B` names the boot objects); the file
server writes it anew when a boot object is written or a snapshot is
restored.

## A commit

1. Every changed tree page and every new stream page is written to pages
   that were free in the last commit.
2. The device is flushed.
3. The meta block for the new commit number is written to page 1 + (*c*
   & 1), and the device is flushed.

Until step 3 is whole, the disk is the last commit: nothing that commit
uses has been written over. Pages a commit frees go to the pending tree
under its number and are taken into use only by a later commit.
