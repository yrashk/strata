# The file server split into blk, db and fs

An experiment on the branch `fs-split-blk-db` (not for `main` until the
numbers say so): StrataOS's file server, one program today
(`os/servers/fs.s` with the store's `store.s`, `storew.s`, `sblob.s`), split
into three servers, and what the split costs measured on the emulator.

Why: a guest StrataOS keeps its disk in a RAM disk inside its image, lost
when it stops. A persistent guest disk wants the host's store reachable on
its own: a guest's `fs` on the host's `db` confined to a namespace, or a
guest's `blk` whose blocks are a value in the host's `db`. With one server
neither layer can be reached without the other.

## The three servers

| server | owns | answers | reaches |
|---|---|---|---|
| `blk` | the block device: its ports (window from `dev`, GETDISK) and its node, or the RAM disk of a guest | runs of blocks into or out of a lent buffer; READBLK | the device |
| `db` | the store: pages, the page cache, the B+trees, namespaces, commits, snapshots, the boot manifest | the store's calls by tree handle (fs), the program store's DBGET / DBSCAN / DBBATCH | `blk` |
| `fs` | files, names, tags, the index, attributes, open files, current paths, LOADIMG | every op programs send to `fs` today, unchanged | `db` (and `blk` for READBLK) |

Programs see the same ops with the same formats on the same endpoint (c2).
DBGET, DBSCAN and DBBATCH are answered by `db`'s code; a program's request
still goes to `fs`, which hands its data to `db` and the answer back (one
round trip more; `db` alone is the only place that knows namespaces).

**The page cache lives in `db`, only.** The B+tree code works on pages in
the D-LS and needs them a transfer away, not a message away; `blk` is a
driver with no cache (a command per run of blocks, the bytes moved by the
device straight into the lent buffer). A cache in `blk` too would hold the
same pages twice and still cost `db` a message per miss. A guest's `blk`
over the host's `db` gets the host's cache for free.

## Several servers on one core

The kernel used to give a worker core one server (`w_server`): every
request arriving at the core went to it. Six cores were core 0 plus `proc`,
`dev`, `fs`, `tty`, `pipe`; two more servers do not fit. Now a core keeps a
table of up to four servers (`w_srv`, a byte each), servers share the core
like any other program, and a request names its server by an index in
header word 48: `0x53 << 56 | index` (byte 7 is 'S'; anything else means
index 0, so every client of today's servers is unchanged). CREATE's flags
carry the index (bits 12 and 13). Each server has its own count of queued
requests, its own sender of the request it holds (for PARK), and only its
own queued and parked requests go back with -1 when it ends. Clients learn
the index with the endpoint: LOOKUP answers it in data[0]; the boot servers
get theirs from the kernel.

Placement (any core count from 6): `proc` 1, `dev` 2 and `db` 2 (index 1),
`fs` 3, `tty` 4, `pipe` 5 and `blk` 5 (index 1). `db` and `blk` sit beside
the servers that run least (`dev`, `pipe`), so that `fs`, `db` and `blk`
each run on a core of its own and a call between them is not a context
switch; cores 6 and up stay free for threads.

## Interfaces

Header as for every message: 0 op, 8 handle, 16 length, 24 mode, 32 result,
40 sender pid (stamped), 48 server index (requests), 56 reply extra (db: the
commit number, and the count of aborts << 48).

### blk (index 1 on `pipe`'s core)

| op | name | in | out |
|---|---|---|---|
| 1 | BREAD | handle = first block, length = blocks (any number), mode = byte offset in the attachment; the buffer as attachment | 0 / the device's status; the buffer back |
| 2 | BWRITE | the same, from the buffer | the same |
| 3 | FLUSH | | 0: what the device holds back is on the disk |
| 4 | INFO | | data: u64 blocks, u64 1 for a RAM disk |
| 33 | READBLK | handle = block | 512; data: the block (`fs` passes READBLK on: `db`, `wdb`, `fsck`) |

BREAD, BWRITE and FLUSH are taken from `db` only (its pid); anyone may
READBLK, as before. Per command: 2 messages, no copy (the device moves the
bytes into the lent buffer: `db`'s frames, or `proc`'s arena for LOADIMG).

### db (index 1 on `dev`'s core)

A tree is named by a handle (its entry in `db`'s table of open trees). The
calls follow the store's routines one for one, so that `fs`'s code calls
`st_get`, `st_put` ... as before and those are now stubs that send a
message (`os/servers/dbcall.s`).

| op | name | in | out |
|---|---|---|---|
| 70 | TREE | handle = namespace id, mode 1 = make it, data = the tree's name | the handle, 0 none |
| 71 | GET | handle = tree, data = key | the value's length (-1 none), data = the value, mode = its flag |
| 72 | SEEK | handle = tree, mode = ST_GE/GT/LE/LT, data = key | 1 found / 0; length = the key's length, mode = the value's length \| flag << 32; data = the key (padded to 8) and the value |
| 73 | PUT | handle = tree, mode = flag, data = {u16 key length, u16 value length, u32 0, key padded, value} | 1 added / 0 replaced / -1 too long |
| 74 | DEL | handle = tree, data = key | 1 / 0 |
| 75 | VSIZE | handle = tree, data = key | a value's length of any size, -1 none |
| 76 | VREAD | handle = tree, data = {u64 extents' tree, u64 offset, u64 bytes, key} | bytes read (0 at the end); data: them |
| 77 | VWRITE | handle = tree, data = {u64 extents' tree, u64 offset, u64 bytes, u64 key length, key padded, the bytes}, mode 1 = always a stream | 0 |
| 78 | VTRUNC | handle = tree, data = {.., u64 new length, key} | 0 |
| 79 | VDEL | handle = tree, data = key | 1 / 0 |
| 80 | VLOAD | handle = tree, data = {.., u64 offset in the attachment, u64 most bytes, key}; an arena as attachment | the value's length, all of it copied in (-4 none, -1 longer); the arena back |
| 81 | COMMIT | | 0: on the disk |
| 82 | ABORT | | 0: back to the last commit; every handle is to be opened again |
| 83 | INFO | | data: page size, blocks per page, pages, free pages, commit, last commit on the disk, the namespace "fs"'s id |
| 84 | SNAP | as fs's SNAP (45): take, delete, list, restore | as SNAP |
| 85 | SNAPT | handle = a snapshot's commit, data = namespace id and names | data: a handle per tree (read only, until the next SNAPT), -1 no such snapshot |
| 86 | BOOT | handle = the data tree, data = the key made one run (or none), then the manifest's entries {name[16], key, size} | 0 |
| 64, 65, 66 | DBGET, DBSCAN, DBBATCH | as programs send them to fs | as before |

Values are any size: VREAD, VWRITE and VTRUNC reach part of a value by
offset (a value longer than a quarter page is a stream of extents; the
store had that for file contents). A file's contents are one such value,
read and written by parts; a guest's disk can be one too.

Errors: -1 a bad request (or the disk is full: the commit under way is given
up), -5 the disk cannot be read as a store, a page failed its checksum, or
the device refused. On -1 for a full disk and on -5 `db` has aborted: the
reply's abort count says so, and `fs` gives up its writer's bytes and opens
its trees again, as it did in one program.

Who may call: TREE, the V* calls, COMMIT, ABORT, SNAP, SNAPT and BOOT come
from `fs` (its pid); DBGET, DBSCAN and DBBATCH from anyone that reaches
`db`, refused for the namespace "fs" as before.

## Messages and copies per operation

Expected from the code (each db call is 2 messages, a request and its
reply; the measured counts are below):

| op from a program | today | split |
|---|---|---|
| OPEN (a path of one tag) | 2 | 2 + 2 × (dictionary, name, record lookups: 3–5) |
| READ 4 KiB | 2; the bytes: frame → D-LS → reply | 2 + 2; frame → db's D-LS → db's reply → fs's D-LS → reply (2 more copies) |
| WRITE 4 KiB | 2 | 2 + 2; one more copy each way |
| CLOSE of a written file | 2, a commit | 2 + 2 × (record, name, index puts: about 6) + the commit |
| LOADIMG / READALL | 2; the device writes the arena | 2 + 2 + 2 per run of pages; the device still writes the arena (lent fs → db → blk → device) |
| QUERY (one part of a listing) | 2 | 2 + 2 × (an index seek and a record get per file) |
| DBGET / DBBATCH | 2 | 4 |
| a cache miss in the store | a device command | + 2 messages (db → blk) |

## Measurements

`make bench-store` (tools/bench-store.sh): sessions on the emulator,
8 cores, `-T virtual`, each workload alone between two `uptime`s; numbers
are the workload's own (a session with nothing in it taken away).

Before (main at 55f0543 plus the bench, one fs):

| workload | ticks | messages | blk cmds | switches | KiB moved | instructions |
|---|---:|---:|---:|---:|---:|---:|
| boot to the shell | 9000 | 258 | 21 | 12 | 1160 | 2,531,969 |
| cat /src/cc.c (162 KB) | 81,897 | 239 | 45 | 90 | 8,370 | 9,363,404 |
| wc < /src/cc.c | 86,419 | 163 | 45 | 86 | 7,826 | 9,575,796 |
| ls /many (300 files) | 18,196 | 69 | 12 | 8 | 779 | 2,476,360 |
| ls /bin | 5,397 | 61 | 6 | 4 | 389 | 1,085,648 |
| cp /src/cc.c /x | 88,777 | 251 | 119 | 178 | 17,267 | 9,823,625 |
| 100 small files (echo >) | 282,875 | 664 | 1,510 | 0 | 0 | 31,430,851 |
| touch /many/f100 | 1,811 | 77 | 3 | 4 | 364 | 944,470 |
| dbbench 200 | 210,758 | 883 | 1,291 | 818 | 78,526 | 22,113,569 |
| — 200 DBBATCH puts | 170,757 | | | | | |
| — 200 DBGETs | 33,312 | | | | | |
| — a DBSCAN of 200 | 4,861 | | | | | |

The store test (`tools/test-store.sh`, 117 sessions, `tools/bench/store-test.sh`):
1,535,736,521 instructions, 90,492 messages, 15,245 block commands.

After: (to come)
