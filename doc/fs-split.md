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
round trip more; `db` is the only place that knows namespaces).

## Several servers on one core

The kernel used to give a worker core one server (`w_server`): every
request arriving at the core went to it. Six cores were core 0 plus `proc`,
`dev`, `fs`, `tty`, `pipe`; two more servers do not fit, and eight cores
for StrataOS would leave no room for StrataOS as a guest. Now a core keeps
a table of up to four servers (`w_srv`, a byte each), servers share a core
like any other program, and a request names its server by an index in
header word 48: `0x53 << 56 | index` (byte 7 is 'S'; anything else means
index 0, so every client of the servers there were is unchanged). CREATE's
flags carry the index (bits 12 and 13). Each server has its own count of
queued requests (the queue is one ring of 16; one taken out of turn leaves
a hole), its own sender of the request it holds (for PARK), and only its
own queued and parked requests go back with -1 when it ends. The kernel
gives `fs` and `db` the indexes of the servers they call. The room in the
worker's resident code came from gp-relative loads in place of `la` + `add`
(16 bytes are left).

Placement (any core count from 6): `proc` 1, `dev` 2 and `blk` 2 (index
1), `fs` 3 (alone), `tty` 4, `pipe` 5 and `db` 5 (index 1): `fs`, `db` and
`blk` on three cores, beside the servers that run least. `db` is on
`pipe`'s core because every program holds an endpoint for it (c4): a
program reaches `db` with header word 48 = `0x53 << 56 | 1` and no new
capability. A program holds endpoints for four cores only (c1..c4:
`proc`'s, `fs`'s, `tty`'s, `pipe`'s), and the other three will not do:
`proc` and `tty` must be alone on theirs; on `fs`'s, `db` and `fs` would be
switched at every call between them, and from 8 cores `fs` is alone there
so that `db` can trust what comes from its core (forwarding, below). The
cost: pipelines and the store share core 5, and `pipe`'s traffic and
`db`'s wait for each other there. `blk` is not with `db` for the same
reason as `db` is not with `fs`: `db` calls it at every page it reads or
writes (tried: on core 5, `cat` and the 100 files were 1.5% and 2.6%
slower). `blk` asks `dev` for the disk (GETDISK) from `dev`'s own core,
so it asks twice, one capability per answer: a core's inbox holds two
gifts from each sender, its own included, and an answer of three (two
attachments and the buffer) to one's own core waits on a dispatcher that
is the one sending it. A server of index 1..3 is
a core flag of its own (16): it does not keep a server of index 0 away (so
`proc` still puts `pipe` on core 5) and does not count when a program is
placed (or the login shell would land on core 6 and leave a guest no run
of empty cores). The boot servers are made in the order dev, blk, db, fs,
proc; one that sends to another that does not run yet gets -1 and asks
again a tick later.

`db` is made a busy server (CREATE flag bit 14, core flag 32): a busy
server's core counts three more when a program is placed, so a program
shares a core with the server it waits on only when every other core is
as full. From 8 cores on `fs` is solo (no program is ever placed on core 3):
forwarding needs it (below). On 6 or 7 cores that would leave programs two
cores (`test-procs`' 6-core peak fell from 45 processes), so there `fs` is
a busy server, shares its core and relays. A core with no server counts two more, so that on 8 cores
the two empty ones stay free for a guest (`guest -d gdemo 2 8`): programs
go beside `dev` and `blk` on core 2 first, which costs `cat` about 2%
against putting them on an empty core. Before, the login shell sat on core 2 beside `db` and
every request it made while `db` worked swapped the two.

## Interfaces

The full field-by-field description is `os/spec/blk.toml` and
`os/spec/db.toml` (the site's server pages and the manual's chapter are
made from them). In short:

**blk** (pid 4): BREAD and BWRITE (a run of blocks into or out of the
buffer lent with the request; any length, in device commands of 256
blocks), WRITEV (several runs out of the lent buffer, then a flush: a
commit's writes in one message), FLUSH, INFO, READBLK. The device moves the
bytes straight into the lent buffer: `db`'s page frames, or a program's
arena on its way from `proc` through `fs` and `db` (LOADIMG, READALL), so
no server copies them. BREAD, BWRITE, WRITEV and FLUSH are taken from
`db`'s pid only.

**db** (pid 5): the store's routines as calls, by tree handle (TREE, GET,
SEEK, PUT, DEL, SCAN), values of any length by part (VSIZE, VREAD at an
offset, VWRITE at an offset, VTRUNC, VDEL, VLOAD into a lent arena),
COMMIT, ABORT, INFO, SNAP (take, delete, list, restore), SNAPT (handles to
a snapshot's trees), BOOT (the boot manifest from entries `fs` lists),
FLUSH, and the program store's DBGET, DBSCAN, DBBATCH. Every reply carries
the commit under way and a count of aborts (word 56): when `db` gives a
commit up (the disk full, a bad page), the client sees the count change.
A request from `fs` may carry a batch of puts and deletes after its data
(word 48's bits 16..31: its bytes), applied first. Partial values were the
point of the user's suggestion: a file's contents are one value read and
written by parts, and a guest's disk can be one too.

**fs** (pid 3): the same ops for programs as before. `os/servers/dbcall.s`
has the store's routines under their old names, each a message to `db`,
so the file system's code is what it was. Two things keep the messages
down: a **read-ahead** (a SEEK walk, or a third GET of growing keys,
fetches up to 4 KiB of following records with one SCAN; two trees are
kept; anything that may change the store drops them), and **writes later**
(`st_put` and `st_del`, whose answers the file system never looked at,
are queued and go with the next call). `fs` hands DBGET, DBSCAN and
DBBATCH on to `db` and READBLK to `blk`.

**The page cache is in `db`, only.** The B+tree code works on pages in the
D-LS; a page must be a transfer away, not a message away. `blk` keeps no
cache: one in `blk` too would hold the same pages twice and still cost a
message per miss, and a guest's `blk` over the host's `db` gets the host's
cache anyway. What `db` cannot hold back is its writes when a frame must be
reused: those go to `blk` at once; a commit's writes wait and go with its
flush.

## Messages and copies per operation (as built)

Each call to another server is 2 messages (the request, the reply); a
round trip between two idle servers on different cores costs about 6,500
rounds of the machine (the dispatchers on both sides, the server loops),
and some 6,000 to 8,000 instructions in all.

| op from a program | one `fs` | split |
|---|---|---|
| OPEN of `/doc/motd` | 2 | 2 + 6 (tag, name, record) |
| READ 4 KiB | 2; frame → D-LS → reply | 2 + 2; frame → db's D-LS → db's reply → fs's D-LS → reply: 2 more copies of the bytes |
| WRITE 4 KiB | 2 | 2 + 2 (or 4: the batch first when it does not fit); one more copy |
| creating a small file (OPEN, WRITE, CLOSE) | 6, a commit | 6 + about 22 (`fs` ↔ `db`), + 4 (`db` ↔ `blk`: the commit's WRITEVs); with the value cache and the value items, 6 + 4 (a GET of the new name, the COMMIT) + 4 |
| LOADIMG | 2; the device writes the arena | 2 + 8 (lookups, VLOAD) + 2 per run of pages read; the device still writes the arena |
| a listing of 300 files | 4 (two parts) | 4 + about 34 (SCANs of the index and of the records, 4 KiB each) |
| DBGET | 2 | 4 relayed by `fs`; 3 forwarded; 2 sent to `db` directly (`kv_get`) |
| a cache miss in the store | a device command | + 2 messages (`db` → `blk`) |

## Measurements

`make bench-store` (`tools/bench-store.sh`): sessions on the emulator,
8 cores, `-T virtual`, each workload alone between two `uptime`s; the
numbers are the workload's own (a session with nothing in it taken away):
its time in ticks (100 rounds each), the messages (4 KiB buffers put into
an inbox: requests and replies), the commands to the block device, the
context switches and the KiB they moved, the instructions of all cores.

Before (main at 55f0543 plus the bench, one fs):

| workload | ticks | messages | blk cmds | switches | KiB moved | instructions |
|---|---:|---:|---:|---:|---:|---:|
| boot to the shell | 9000 | 258 | 21 | 12 | 15,000 | 1.67 |
| cat /src/cc.c (162 KB) | 81,897 | 239 | 45 | 90 | 8,370 | 9,363,404 |
| wc < /src/cc.c | 86,419 | 163 | 45 | 86 | 94,386 | 1.09 |
| ls /many (300 files) | 18,196 | 69 | 12 | 8 | 27,718 | 1.52 |
| ls /bin | 5,397 | 61 | 6 | 4 | 10,763 | 1.99 |
| cp /src/cc.c /x | 88,777 | 251 | 119 | 178 | 101,515 | 1.14 |
| 100 small files (echo >) | 282,875 | 664 | 1,510 | 0 | 340,326 | 1.20 |
| touch /many/f100 | 1,811 | 77 | 3 | 4 | 3,630 | 2.00 |
| dbbench 200 | 210,758 | 883 | 1,291 | 818 | 271,705 | 1.29 |
| — 200 DBBATCH puts | 170,757 | | | | | |
| — 200 DBGETs | 33,312 | | | | | |
| — a DBSCAN of 200 | 4,861 | | | | | |

The store test (`tools/test-store.sh`, 117 sessions, `tools/bench/store-test.sh`):
1,535,736,521 instructions, 90,492 messages, 15,245 block commands.

After, the split with one message per store call ("naive", commit
5251024), and as it is on the branch (read-ahead, writes later, WRITEV):

| workload | ticks before | naive | split | split / before | messages before → split | instructions before → split |
|---|---:|---:|---:|---:|---:|---:|
| boot to the shell | 9,000 | 16,000 | 16,000 | 1.78 | 15,000 | 1.67 |
| cat /src/cc.c (162 KB) | 81,897 | 88,311 | 90,623 | 1.11 | 239 → 427 | 9.36 M → 11.08 M |
| wc < /src/cc.c | 86,419 | 92,699 | 94,782 | 1.10 | 94,386 | 1.09 |
| ls /many (300 files) | 18,196 | 79,757 | 28,882 | 1.59 | 27,718 | 1.52 |
| ls /bin | 5,397 | 19,575 | 10,646 | 1.97 | 10,763 | 1.99 |
| cp /src/cc.c /x | 88,777 | 106,702 | 104,193 | 1.17 | 101,515 | 1.14 |
| 100 small files (echo >) | 282,875 | 717,471 | 420,071 | 1.49 | 340,326 | 1.20 |
| touch /many/f100 | 1,811 | 2,961 | 3,077 | 1.70 | 3,630 | 2.00 |
| dbbench 200 | 210,758 | 353,480 | 284,789 | 1.35 | 271,705 | 1.29 |
| — 200 DBBATCH puts | 170,757 | 306,831 | 226,449 | 1.33 | | |
| — 200 DBGETs | 33,312 | 38,723 | 49,982 | 1.50 | | |
| — a DBSCAN of 200 | 4,861 | 5,115 | 5,512 | 1.13 | | |

Block commands are the same (they are the store's): 1,503 for the 100
files, 44 for `cat`, 22 at boot. Context switches and the KiB they move
grew where a program shares a core with a server it waits on: the login
shell sits on core 2, beside `dev` and `db`, so every request it makes
while `db` works swaps the two (100 small files: 606 switches moving 65 MB,
none before; `cat`: 98 and 8.4 MB, about as before). On a machine with a
core to spare the shell could sit alone.

The store test (`tools/test-store.sh`, all its sessions on the counting
emulator, `tools/bench/store-test.sh`): 1.54 G instructions, 90,492
messages, 15,245 block commands before; 1.78 G (+16%), 164,988 messages
(+82%), 15,088 block commands after (116 sessions counted against 117: one
session fewer leaves its counts).

Where the time goes: not in copies (a READ's bytes cross two more
transfers, `cat` is 11% slower) but in round trips. A store call that was
a function call is now some 6,500 rounds; a listing or a file's creation
makes dozens. The first version (a message per call) was 2.5 to 4.4 times
slower on those; the read-ahead and the queued writes took most of that
back, and the rest is the calls that must wait for an answer (lookups by
path, the record read before a change).

## Getting the time back

The round trips that remain are the calls `fs` waits on. Three changes,
measured one after the other (ticks, `make bench-store`):

- **Placement** (above): programs are kept off the cores of `fs` and `db`.
- **A value cache in `fs`** (`dbcall.s`, `kv_find`/`kv_set`): 24 entries
  of a key up to 56 bytes and a value up to 248, from the answers of GETs
  `fs` actually sent (a hit of the read-ahead is not cached: filling the
  cache from listings cost more than it saved). `fs` is `db`'s only writer
  of its trees, so its own puts and deletes go through the cache and it is
  never stale; a value call (VWRITE, VDEL, ...) drops the tree's entries,
  ABORT, SNAP and a failed call drop all of them.
- **Value items** (`os/spec/db.toml`): the items that ride after a call's
  data were puts and deletes; now also VDEL, a VWRITE of at most 512 bytes
  and the move of a file's contents to its new key (what a write's CLOSE
  does: VDEL, VSIZE, PUT, DEL as one item). Creating a file was a GET, a
  VWRITE, a VDEL, a VSIZE and the COMMIT: five round trips; now a GET and
  the COMMIT. The cost: a short write that fills the disk is not refused at
  that WRITE but at the next call on the file (CLOSE at the latest), which
  gives the file up as before (`tools/test-store.sh` part 10).

| workload | before | as committed | + placement | + value cache | + value items (placement kept guest-safe) | / before |
|---|---:|---:|---:|---:|---:|---:|
| boot to the shell | 9,000 | 16,000 | 16,000 | 15,000 | 15,000 | 1.67 |
| cat /src/cc.c | 81,897 | 90,623 | 88,084 | 87,892 | 89,503 | 1.09 |
| wc < /src/cc.c | 86,419 | 94,782 | 92,652 | 92,532 | 94,386 | 1.09 |
| ls /many (300 files) | 18,196 | 28,882 | 28,519 | 27,640 | 27,718 | 1.52 |
| ls /bin | 5,397 | 10,646 | 10,431 | 10,722 | 10,763 | 1.99 |
| cp /src/cc.c /x | 88,777 | 104,193 | 99,674 | 100,002 | 101,515 | 1.14 |
| 100 small files (echo >) | 282,875 | 420,071 | 402,977 | 365,211 | 340,326 | 1.20 |
| touch /many/f100 | 1,811 | 3,077 | 2,861 | 3,580 | 3,630 | 2.00 |
| dbbench 200 | 210,758 | 284,789 | 259,772 | 259,575 | 271,705 | 1.29 |

The last column is the branch as it is: placement as described above (the
earlier columns put programs on the empty cores, which broke `guest`). The
100 files went from 3,090 messages to 1,606 (664 with one `fs`) and
from 606 context switches to 204. What is left is mostly the program store
reached through `fs` (DBGET, DBBATCH: two hops where there was one), the
lookups of a listing and of a path, and boot.

## Forwarding, and the program store reached directly

A server may pass a request it holds on to another server instead of
answering it. No new kernel call: REPLY's token is a core, and a REPLY
with another server's core gives the buffer there, where the dispatcher
takes it for a request like any other (a 4 KiB buffer that is not one of
its own processes'), queues it for the server header word 48 names and
stamps its sender from the buffer's arena: the program, not the server
that forwarded it, so the forwarding server lends no authority of its own.
The forwarding server does not wait for it.

Who answers, and to which core, is the two servers' agreement. `fs`
forwards a program's DBGET, DBSCAN and DBBATCH (`fsops.s`, `op_dbget`):
header word 48 names `db`, word 56 is the program's core (from `fs`'s
RECEIVE token). `db` (`db.s`, `loop`) takes word 56 only from a request
that arrives from `fs`'s core and is not `fs`'s own; `fs` is alone on its
core, so nothing but `fs` sends from there. On fewer than 8 cores the
kernel does not make `fs` solo, tells it not to forward (its start-up word,
bit 16) and gives `db` no core to trust (0xff): `fs` relays. `db` then answers the
program's core, and clears word 48 in every answer to a program (a
program's next message goes out with the header it got back). A relayed
call was 4 messages and two copies of the data through `fs`'s Local
Store, with `fs` waiting; forwarded it is 3 messages, no copy, and `fs`
takes its next request at once.

DBBATCH is taken only forwarded (or relayed by `fs`). A batch commits, and `db` cannot see
where `fs` is inside one of its own requests; forwarded, the batch is
queued after `fs`'s last call for the request before and ahead of the
first for the next one. `fs` commits a writer's bytes and sends its queued
writes first; `db` commits whatever is still uncommitted, keeps a copy of
its table of open trees (in its I/O buffer's scratch) and runs the batch
as a commit of its own. If the disk has no room for it, `db` gives that
commit up without counting an abort (fs had nothing in it) and puts the
table of open trees back, so `fs`'s handles stay good and `fs` is not
told: before, `fs` saw the -1 of its own relayed call.

DBGET and DBSCAN do not change anything, so a program sends them to `db`
directly (`os/lib/kv.s`: through c4, `pipe`'s core, word 48 = `0x53 << 56
| 1`): 2 messages, as with one `fs`. Programs that call `fs` (the Forth
words, `db.fs`) are forwarded.

What it does not cover: a forwarded request that finds `db`'s queue full
is refused back to `fs`'s core, which has no server of index 1 and refuses
it back to `db`'s core, until there is room (the dispatchers pass it to
and fro; no server runs for it). If `db` ended, that would not stop; `db`
does not end while the system runs. A REPLY of the kernel's own could give
the answer to the program's core without the agreement and without the
solo core, but the workers' resident code has 16 bytes left.

| workload | before (one fs) | value items | + direct reads, forwarding | / before |
|---|---:|---:|---:|---:|
| boot to the shell | 9,000 | 15,000 | 15,000 | 1.67 |
| cat /src/cc.c | 81,897 | 89,503 | 89,461 | 1.09 |
| ls /many (300 files) | 18,196 | 27,718 | 27,723 | 1.52 |
| 100 small files (echo >) | 282,875 | 340,326 | 342,463 | 1.21 |
| dbbench 200 | 210,758 | 271,705 | 245,901 | 1.17 |
| — 200 DBBATCH puts (forwarded) | 170,757 | 225,094 | 214,459 | 1.26 |
| — 200 DBGETs (direct) | 33,312 | 38,870 | 24,272 | 0.73 |
| — a DBSCAN of 200 (direct) | 4,861 | 5,113 | 4,530 | 0.93 |

dbbench sends 1,903 messages (2,515 relayed, 883 with one `fs`). Reads
of the program store are now faster than with one `fs`: a DBGET no longer
waits behind the file system's requests. Boot sends 353 messages (523).

The next steps of the plan: SCAN answered into a region the caller lends,
and the same for READ of a file's contents: `fs` sends `db` the program's
buffer with the value's handle and offset, and `db` fills it and answers
the program (a new call of `fs`'s, since VREAD is taken from `fs` only).

## Recommendation

**Do not land the split on `main` as the file system's structure; land
the kernel part.**

- Several servers on a core is cheap, general (servers share cores like
  programs, the user's point) and needed by anything that adds a server:
  it can go to `main` on its own (with the debugger's change; placement's
  flag 16).
- The split costs 10–17% on bulk reads and copies, 1.5–2× on what makes
  many small store calls (listings, creating files, boot, the program
  store), for every program, all the time, to gain one thing: a store a
  guest can reach without the file system.
- That one thing can be had without splitting the host's file system: a
  guest's disk is a value (or a namespace) in the host's store, and the
  host's `fs` can answer a guest's block calls on it, as it answers DBGET
  today — or `db` can be split out only where it is used across a
  boundary. The partial-value calls (VREAD, VWRITE at an offset) are what a
  guest's `blk` needs, and they work in one server as well as in two.
- A bug the split exposed belongs on `main` either way: a program wrote
  its console ring through `c10` (`os/lib/chan.s`), which does not survive
  a context switch, so one preempted between copying the ring there and
  writing it faulted (`test-procs` lost its login shell once `db` shared
  the shell's core). `chan_put` now uses `c6`, where the ring is: on
  `main` since 0be9790, with the debugger taking a server's symbols from
  `sys/NAME.map` first.
- If the guest work does build on `db` directly, two things are missing
  first: transactions for a second writer (today `fs` is `db`'s only
  writer; a guest's batch in the middle of an `fs` request would commit
  `fs`'s half-done change), and a program store reached without `fs` (the
  extra hop is the DBGET's 1.5×).
