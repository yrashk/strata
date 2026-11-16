"OSServers.st: made by lang/stratalk/host/osgen.py from os/spec/*.toml; do not edit.
 A class per StrataOS server, a method pair per message op (OS.st has the
 machinery). The svc calls are not messages: the VM makes them itself."

OSServer subclass: #BlkServer slots: ''.
BlkServer class >> default [
    "blk: db holds an endpoint to its core (index 1, header word 48); fs too, for READBLK"
    ^self register: 2 lookup: 'dev' index: 1 ]
BlkServer class >> spec [ ^'blk.toml' ]
BlkServer >> bread [ ^self bread: Dictionary new ]
BlkServer >> bread: args [
    "BREAD (1): A run of blocks into the lent buffer. Request: handle: the first block; length: the blocks (any number); mode: the byte offset in the buffer; attachment: the buffer, lent for the call (not sent from Stratalk). Reply: result: 0, or the device's status (not 0) of the first command that failed; attachments: the buffer, back. From: db only."
    ^self op: 1 named: 'BREAD' args: args request: #() reply: #() ]
BlkServer >> bwrite [ ^self bwrite: Dictionary new ]
BlkServer >> bwrite: args [
    "BWRITE (2): A run of blocks out of the lent buffer. Request: handle: the first block; length: the blocks (any number); mode: the byte offset in the buffer; attachment: the buffer, lent for the call (not sent from Stratalk). Reply: result: 0, or the device's status (not 0) of the first command that failed; attachments: the buffer, back. From: db only."
    ^self op: 2 named: 'BWRITE' args: args request: #() reply: #() ]
BlkServer >> flush [ ^self flush: Dictionary new ]
BlkServer >> flush: args [
    "FLUSH (3): What the device holds back, to the disk. Request: nothing. Reply: result: 0, or the device's status. From: db only."
    ^self op: 3 named: 'FLUSH' args: args request: #() reply: #() ]
BlkServer >> info [ ^self info: Dictionary new ]
BlkServer >> info: args [
    "INFO (4): The disk's size. Request: nothing. Reply: length: 16; result: 2; data: blocks, 1 for a RAM disk (a guest StrataOS), else 0."
    ^self op: 4 named: 'INFO' args: args request: #() reply: #(#(#u64 'blocks') #(#u64 '1 for a RAM disk (a guest StrataOS), else 0')) ]
BlkServer >> writev [ ^self writev: Dictionary new ]
BlkServer >> writev: args [
    "WRITEV (5): Several runs of blocks out of the lent buffer, then a flush. Request: length: the runs' bytes (24 each, at most 4032); mode: bit 0: then FLUSH; data: records (per run); attachment: the buffer, lent for the call (not sent from Stratalk). Reply: result: 0, or the device's status (not 0) of the first command that failed (the rest are not done); attachments: the buffer, back. From: db only."
    ^self op: 5 named: 'WRITEV' args: args request: #(#(#repeat 'per run' #(#(#u64 'the first block') #(#u64 'blocks') #(#u64 'the byte offset in the buffer')))) reply: #() ]
BlkServer >> readblk [ ^self readblk: Dictionary new ]
BlkServer >> readblk: args [
    "READBLK (33): A raw block of the disk. Request: handle: the block. Reply: length: 512; result: 512; data: the block's 512 bytes."
    ^self op: 33 named: 'READBLK' args: args request: #() reply: #(#(#bytes 'the block''s 512 bytes')) ]

OSServer subclass: #DbServer slots: ''.
DbServer class >> default [
    "db: fs holds an endpoint to its core (index 1, header word 48); programs send DBGET and DBSCAN through their endpoint for pipe's core, and DBBATCH to fs, which forwards it"
    ^self register: 4 lookup: nil index: 1 ]
DbServer class >> spec [ ^'db.toml' ]
DbServer >> dbget [ ^self dbget: Dictionary new ]
DbServer >> dbget: args [
    "DBGET (64): A value from a program's tree. Request: length: the data's bytes (8..4032); data: namespace name length, tree name length, key length, 0, the namespace's name, the tree's name, the key. Reply: result: the value's length; data: the value."
    ^self op: 64 named: 'DBGET' args: args request: #(#(#u8 'namespace name length') #(#u8 'tree name length') #(#u16 'key length') #(#u32 '0') #(#bytes 'the namespace''s name') #(#bytes 'the tree''s name') #(#bytes 'the key')) reply: #(#(#bytes 'the value')) ]
DbServer >> dbscan [ ^self dbscan: Dictionary new ]
DbServer >> dbscan: args [
    "DBSCAN (65): Records of a program's tree, in key order. Request: length: the data's bytes (8..4032); modes: 0 ST_GE: from the key on, 1 ST_GT: after the key, 2 ST_LE: from the last key at or before it, 3 ST_LT: from the last key before it; data: namespace name length, tree name length, key length, 0, the namespace's name, the tree's name, the key. Reply: length: the data's bytes; result: the records; data: records (per record)."
    ^self op: 65 named: 'DBSCAN' args: args request: #(#(#u8 'namespace name length') #(#u8 'tree name length') #(#u16 'key length') #(#u32 '0') #(#bytes 'the namespace''s name') #(#bytes 'the tree''s name') #(#bytes 'the key')) reply: #(#(#repeat 'per record' #(#(#u16 'key length') #(#u16 'value length') #(#u32 '0') #(#bytes 'the key') #(#pad '') #(#bytes 'the value') #(#pad '')))) ]
DbServer >> dbbatch [ ^self dbbatch: Dictionary new ]
DbServer >> dbbatch: args [
    "DBBATCH (66): Puts and deletes in a program's tree, in one commit. Request: handle: the items; length: the data's bytes (8..4032); data: namespace name length, tree name length, key length, 0, the namespace's name, the tree's name, records (per item). Reply: result: 0: every item is on the disk."
    ^self op: 66 named: 'DBBATCH' args: args request: #(#(#u8 'namespace name length') #(#u8 'tree name length') #(#u16 'key length') #(#u32 '0') #(#bytes 'the namespace''s name') #(#bytes 'the tree''s name') #(#pad '') #(#repeat 'per item' #(#(#u8 '1 put, 2 delete') #(#u8 '0') #(#u16 'key length') #(#u16 'value length') #(#u16 '0') #(#bytes 'the key') #(#pad '') #(#bytes 'the value') #(#pad '')))) reply: #() ]
DbServer >> tree [ ^self tree: Dictionary new ]
DbServer >> tree: args [
    "TREE (70): A handle to a tree of a namespace. Request: handle: the namespace's id; length: the name's length (1..28); modes: 0 open it if it is there, 1 make it if it is not; data: the tree's name. Reply: result: the handle; 0: no such tree. From: fs only."
    ^self op: 70 named: 'TREE' args: args request: #(#(#bytes 'the tree''s name')) reply: #() ]
DbServer >> get [ ^self get: Dictionary new ]
DbServer >> get: args [
    "GET (71): A value by its key. Request: handle: the tree; length: the key's length; data: the key. Reply: mode: the value's flag (1: a stream's 16 bytes); result: the value's length; data: the value. From: fs only."
    ^self op: 71 named: 'GET' args: args request: #(#(#bytes 'the key')) reply: #(#(#bytes 'the value')) ]
DbServer >> seek [ ^self seek: Dictionary new ]
DbServer >> seek: args [
    "SEEK (72): The nearest record on one side of a key. Request: handle: the tree; length: the key's length; modes: 0 ST_GE, 1 ST_GT, 2 ST_LE, 3 ST_LT; data: the key. Reply: length: the found key's length; mode: the value's length | its flag << 32; result: 1 found, 0 none; data: the key, the value. From: fs only."
    ^self op: 72 named: 'SEEK' args: args request: #(#(#bytes 'the key')) reply: #(#(#bytes 'the key') #(#pad '') #(#bytes 'the value')) ]
DbServer >> put [ ^self put: Dictionary new ]
DbServer >> put: args [
    "PUT (73): A record in, or replaced. Request: handle: the tree; length: the data's bytes; mode: the value's flag (0, 1); data: key length, value length, 0, the key, the value. Reply: result: 1 added, 0 replaced. From: fs only."
    ^self op: 73 named: 'PUT' args: args request: #(#(#u16 'key length') #(#u16 'value length') #(#u32 '0') #(#bytes 'the key') #(#pad '') #(#bytes 'the value')) reply: #() ]
DbServer >> del [ ^self del: Dictionary new ]
DbServer >> del: args [
    "DEL (74): A record out. Request: handle: the tree; length: the key's length; data: the key. Reply: result: 1 deleted, 0 not there. From: fs only."
    ^self op: 74 named: 'DEL' args: args request: #(#(#bytes 'the key')) reply: #() ]
DbServer >> vsize [ ^self vsize: Dictionary new ]
DbServer >> vsize: args [
    "VSIZE (75): A value's length, whatever its size. Request: handle: the tree | the extents' tree << 16 (0: as last named) | the key's length << 32; data: the key, when it is longer than 8 bytes. Reply: mode: its flag: 0 in the tree, 1 a stream of extents; result: the value's length; data: the value as the tree holds it: a short one itself, a stream's 16 bytes. From: fs only."
    ^self op: 75 named: 'VSIZE' args: args request: #(#(#bytes 'the key, when it is longer than 8 bytes')) reply: #(#(#bytes 'the value as the tree holds it: a short one itself, a stream''s 16 bytes')) ]
DbServer >> vread [ ^self vread: Dictionary new ]
DbServer >> vread: args [
    "VREAD (76): Part of a value, by offset. Request: handle: the tree | the extents' tree << 16 (0: as last named) | the key's length << 32; length: the bytes wanted (at most 4032 are answered); mode: the offset. Reply: result: the bytes read; 0 at the end; data: them. From: fs only."
    ^self op: 76 named: 'VREAD' args: args request: #() reply: #(#(#bytes 'them')) ]
DbServer >> vwrite [ ^self vwrite: Dictionary new ]
DbServer >> vwrite: args [
    "VWRITE (77): Part of a value written, by offset. Request: handle: the tree | the extents' tree << 16 (0: as last named) | the key's length << 32; length: the data's bytes; mode: the offset | 1 << 63: a stream even when short; data: the key, when it is longer than 8 bytes, padded, the bytes. Reply: result: 0. From: fs only."
    ^self op: 77 named: 'VWRITE' args: args request: #(#(#bytes 'the key, when it is longer than 8 bytes, padded') #(#bytes 'the bytes')) reply: #() ]
DbServer >> vtrunc [ ^self vtrunc: Dictionary new ]
DbServer >> vtrunc: args [
    "VTRUNC (78): A value cut or grown to a length. Request: handle: the tree | the extents' tree << 16 (0: as last named) | the key's length << 32; mode: the new length. Reply: result: 0. From: fs only."
    ^self op: 78 named: 'VTRUNC' args: args request: #() reply: #() ]
DbServer >> vdel [ ^self vdel: Dictionary new ]
DbServer >> vdel: args [
    "VDEL (79): A value out, its extents freed. Request: handle: the tree | the extents' tree << 16 (0: as last named) | the key's length << 32. Reply: result: 1 deleted, 0 not there. From: fs only."
    ^self op: 79 named: 'VDEL' args: args request: #() reply: #() ]
DbServer >> vload [ ^self vload: Dictionary new ]
DbServer >> vload: args [
    "VLOAD (80): A whole value into a lent arena. Request: handle: the tree | the extents' tree << 16 (0: as last named) | the key's length << 32; length: the most bytes; mode: the offset in the arena; attachment: the arena (LOADIMG, READALL: a program's), lent for the call: db lends it on to blk, and blk to the device (not sent from Stratalk). Reply: result: the value's length, all of it copied in; attachments: the arena, back. From: fs only."
    ^self op: 80 named: 'VLOAD' args: args request: #() reply: #() ]
DbServer >> commit [ ^self commit: Dictionary new ]
DbServer >> commit: args [
    "COMMIT (81): Everything changed, on the disk. Request: nothing. Reply: result: 0: on the disk (a FLUSH, the meta block, a FLUSH). From: fs only."
    ^self op: 81 named: 'COMMIT' args: args request: #() reply: #() ]
DbServer >> abort [ ^self abort: Dictionary new ]
DbServer >> abort: args [
    "ABORT (82): Back to the last commit. Request: nothing. Reply: result: 0: what was not committed is given up; every handle is to be opened again. From: fs only."
    ^self op: 82 named: 'ABORT' args: args request: #() reply: #() ]
DbServer >> info [ ^self info: Dictionary new ]
DbServer >> info: args [
    "INFO (83): The store's sizes. Request: nothing. Reply: length: 64; result: 8; data: the page size, blocks per page, pages, free pages, the commit under way, the last commit on the disk, the newest snapshot's commit (0: none), the disk's blocks. From: fs only."
    ^self op: 83 named: 'INFO' args: args request: #() reply: #(#(#u64 'the page size') #(#u64 'blocks per page') #(#u64 'pages') #(#u64 'free pages') #(#u64 'the commit under way') #(#u64 'the last commit on the disk') #(#u64 'the newest snapshot''s commit (0: none)') #(#u64 'the disk''s blocks')) ]
DbServer >> snap [ ^self snap: Dictionary new ]
DbServer >> snap: args [
    "SNAP (84): Snapshots: take, delete, list, restore. Request: length: the data's bytes; modes: 0 take one: data = its name (1..32 bytes); what is under way is committed first, 1 delete it: data = the name, 2 list them, 3 restore it: data = {u64 the name's length, name[32], u64 trees, the live trees' handles, the namespace's extents' tree last}: they take the snapshot's roots; not committed (fs writes the boot manifest and commits). Reply: result: 0; list: the snapshots; data: records (per snapshot (mode 2)). From: fs only."
    ^self op: 84 named: 'SNAP' args: args request: #() reply: #(#(#repeat 'per snapshot (mode 2)' #(#(#u64 'its commit') #(#bytes 'its name, 32 bytes, zero padded')))) ]
DbServer >> snapt [ ^self snapt: Dictionary new ]
DbServer >> snapt: args [
    "SNAPT (85): Handles to a snapshot's trees. Request: handle: the snapshot's commit; length: the data's bytes; data: trees (8 at most), a live tree's handle, per tree: the one of that namespace and name. Reply: result: the trees; data: per tree: a handle to it as the snapshot has it (empty when it had none), good until the next SNAPT. From: fs only."
    ^self op: 85 named: 'SNAPT' args: args request: #(#(#u64 'trees (8 at most)') #(#u64 'a live tree''s handle, per tree: the one of that namespace and name')) reply: #(#(#u64 'per tree: a handle to it as the snapshot has it (empty when it had none), good until the next SNAPT')) ]
DbServer >> boot [ ^self boot: Dictionary new ]
DbServer >> boot: args [
    "BOOT (86): The boot manifest anew. Request: handle: the data tree | the extents' tree << 16; length: the data's bytes; data: the key (8 bytes) of a value to make one run of pages first; 0: none, entries (64 at most), records (per entry). Reply: result: 0: the manifest is written anew, at a new page, in the commit under way. From: fs only."
    ^self op: 86 named: 'BOOT' args: args request: #(#(#u64 'the key (8 bytes) of a value to make one run of pages first; 0: none') #(#u64 'entries (64 at most)') #(#repeat 'per entry' #(#(#bytes 'the name, 16 bytes') #(#u64 'the value''s key in the data tree') #(#u64 'the size')))) reply: #() ]
DbServer >> scan [ ^self scan: Dictionary new ]
DbServer >> scan: args [
    "SCAN (87): Records in key order, as many as fit. Request: handle: the tree; length: the key's length; modes: 0 ST_GE: from the key on, 1 ST_GT: after it; data: the key. Reply: length: the data's bytes; mode: 1 when the last is the tree's last; result: the records; data: records (per record). From: fs only."
    ^self op: 87 named: 'SCAN' args: args request: #(#(#bytes 'the key')) reply: #(#(#repeat 'per record' #(#(#u16 'key length') #(#u16 'value length') #(#u32 'flag') #(#bytes 'the key') #(#pad '') #(#bytes 'the value') #(#pad '')))) ]
DbServer >> flush [ ^self flush: Dictionary new ]
DbServer >> flush: args [
    "FLUSH (88): Nothing but the batch that comes with it. Request: nothing. Reply: result: 0. From: fs only."
    ^self op: 88 named: 'FLUSH' args: args request: #() reply: #() ]

OSServer subclass: #DevServer slots: ''.
DevServer class >> default [
    "dev: LOOKUP 'dev'"
    ^self register: 2 lookup: 'dev' index: 0 ]
DevServer class >> spec [ ^'dev.toml' ]
DevServer >> getptr [ ^self getptr: Dictionary new ]
DevServer >> getptr: args [
    "GETPTR (21): A window on the pointer's ports. Request: nothing. Reply: result: 0; attachments: a device capability for the pointer's ports (0x4100..0x410F)."
    ^self op: 21 named: 'GETPTR' args: args request: #() reply: #() ]
DevServer >> getsnd [ ^self getsnd: Dictionary new ]
DevServer >> getsnd: args [
    "GETSND (22): A window on the sound device's ports. Request: nothing. Reply: result: 0; attachments: a device capability for the sound device's ports (0x4300..0x4317)."
    ^self op: 22 named: 'GETSND' args: args request: #() reply: #() ]
DevServer >> devs [ ^self devs: Dictionary new ]
DevServer >> devs: args [
    "DEVS (23): The platform table's entries. Request: nothing. Reply: result: the number of entries (32 bytes each); data: records (per entry)."
    ^self op: 23 named: 'DEVS' args: args request: #() reply: #(#(#repeat 'per entry' #(#(#u16 'type') #(#u16 'index') #(#u16 'space') #(#u16 'node') #(#u64 'info') #(#u64 'base') #(#u64 'size')))) ]
DevServer >> opHalt [ ^self opHalt: Dictionary new ]
DevServer >> opHalt: args [
    "HALT (24): Stop the machine. Request: nothing. Reply: result: none: the machine stops."
    ^self op: 24 named: 'HALT' args: args request: #() reply: #() ]
DevServer >> grantFb [ ^self grantFb: Dictionary new ]
DevServer >> grantFb: args [
    "GRANT_FB (26): The framebuffer memory and the controller's ports. Request: nothing. Reply: result: 0; attachments: the framebuffer memory (the whole 16 MiB window at 0x3000000 in T3), a device capability for the framebuffer controller's ports (0x4000..0x400F). From: the process registered as 'ws'."
    ^self op: 26 named: 'GRANT_FB' args: args request: #() reply: #() ]
DevServer >> getdisk [ ^self getdisk: Dictionary new ]
DevServer >> getdisk: args [
    "GETDISK (30): The block device's ports and an endpoint to its node. Request: mode: 0 both, 1 the window alone, 2 the endpoint alone (in c6). Reply: result: 0; attachments: a device capability for the block device's ports (its platform entry's base and size: 0x2000..0x22FF); in a guest StrataOS the RAM disk, memory (the kernel's GDISK), a send-only endpoint to the block device's node (its entry's node), for its buffers; none in a guest. From: blk (dev does not check: any program that asks gets them)."
    ^self op: 30 named: 'GETDISK' args: args request: #() reply: #() ]
DevServer >> getcon [ ^self getcon: Dictionary new ]
DevServer >> getcon: args [
    "GETCON (31): The console's ports. Request: nothing. Reply: result: 0; attachments: a device capability for the console's ports (0x0000..0x00FF); in a guest StrataOS an endpoint to the host's tty (the kernel's GCON). From: tty (dev does not check: any program that asks gets them)."
    ^self op: 31 named: 'GETCON' args: args request: #() reply: #() ]
DevServer >> rings [ ^self rings: Dictionary new ]
DevServer >> rings: args [
    "RINGS (46): The console rings in T2. Request: nothing. Reply: result: 0; attachments: the console rings: an atomic segment in T2 (the kernel's RINGS). From: tty, at its start (the kernel gives them once: a later caller gets −1)."
    ^self op: 46 named: 'RINGS' args: args request: #() reply: #() ]
DevServer >> getnet [ ^self getnet: Dictionary new ]
DevServer >> getnet: args [
    "GETNET (59): The network interface's ports. Request: nothing. Reply: result: 0; attachments: a device capability for the network interface's ports (0x4200..0x421F). From: the process registered as 'net'."
    ^self op: 59 named: 'GETNET' args: args request: #() reply: #() ]
DevServer >> time [ ^self time: Dictionary new ]
DevServer >> time: args [
    "TIME (67): The wall clock: the timer's EPOCH and ZONE. Request: nothing. Reply: result: 1: one 32-byte record; data: EPOCH, ZONE, 0, 0."
    ^self op: 67 named: 'TIME' args: args request: #() reply: #(#(#u64 'EPOCH') #(#s64 'ZONE') #(#u64 '0') #(#u64 '0')) ]

OSServer subclass: #FsServer slots: ''.
FsServer class >> default [
    "fs: c2 of every process"
    ^self register: 2 lookup: nil index: 0 ]
FsServer class >> spec [ ^'fs.toml' ]
FsServer >> read [ ^self read: Dictionary new ]
FsServer >> read: args [
    "READ (1): Read from an open file. Request: handle: the id from OPEN (mode 0); length: the most bytes wanted (at most 4032 are answered). Reply: result: the bytes read; 0 at the end of the file; data: the bytes read."
    ^self op: 1 named: 'READ' args: args request: #() reply: #(#(#bytes 'the bytes read')) ]
FsServer >> write [ ^self write: Dictionary new ]
FsServer >> write: args [
    "WRITE (2): Write to a file open for writing or appending. Request: handle: the id from OPEN (mode 1 or 2); length: the bytes (at most 4032 are taken); data: the bytes to write. Reply: result: the bytes taken: the length, or 4032 when it was more; 0 for none."
    ^self op: 2 named: 'WRITE' args: args request: #(#(#bytes 'the bytes to write')) reply: #() ]
FsServer >> open [ ^self open: Dictionary new ]
FsServer >> open: args [
    "OPEN (3): Open a file by its path. Request: length: the path's length; modes: 0 read, 1 write: the file's contents are replaced at the close, 2 append; data: the path. Reply: result: the id (1..16): the caller holds a reference to it."
    ^self op: 3 named: 'OPEN' args: args request: #(#(#bytes 'the path')) reply: #() ]
FsServer >> close [ ^self close: Dictionary new ]
FsServer >> close: args [
    "CLOSE (4): Drop a reference to an open file. Request: handle: the id. Reply: result: 0, also for an id the caller does not hold."
    ^self op: 4 named: 'CLOSE' args: args request: #() reply: #() ]
FsServer >> unlink [ ^self unlink: Dictionary new ]
FsServer >> unlink: args [
    "UNLINK (11): Delete a file. Request: length: the path's length; data: the path. Reply: result: 0."
    ^self op: 11 named: 'UNLINK' args: args request: #(#(#bytes 'the path')) reply: #() ]
FsServer >> tag [ ^self tag: Dictionary new ]
FsServer >> tag: args [
    "TAG (12): Give a file tags: it moves to the directory of its tags and these. Request: length: the data's bytes; data: the file's path, 0, records (per tag name). Reply: result: 0 (also when nothing changes)."
    ^self op: 12 named: 'TAG' args: args request: #(#(#bytes 'the file''s path') #(#u8 '0') #(#repeat 'per tag name' #(#(#bytes 'the tag''s name') #(#u8 '0')))) reply: #() ]
FsServer >> untag [ ^self untag: Dictionary new ]
FsServer >> untag: args [
    "UNTAG (13): Take tags from a file: it moves to the directory without them. Request: length: the data's bytes; data: the file's path, 0, records (per tag name). Reply: result: 0."
    ^self op: 13 named: 'UNTAG' args: args request: #(#(#bytes 'the file''s path') #(#u8 '0') #(#repeat 'per tag name' #(#(#bytes 'the tag''s name') #(#u8 '0')))) reply: #() ]
FsServer >> rename [ ^self rename: Dictionary new ]
FsServer >> rename: args [
    "RENAME (15): Move a file to a new path's directory and name. Request: length: the data's bytes; data: the file's path, 0, the new path. Reply: result: 0."
    ^self op: 15 named: 'RENAME' args: args request: #(#(#bytes 'the file''s path') #(#u8 '0') #(#bytes 'the new path')) reply: #() ]
FsServer >> cwd [ ^self cwd: Dictionary new ]
FsServer >> cwd: args [
    "CWD (20): Get or set the caller's current tag path. Request: length: mode 1: the path's length (0: `/`); modes: 0 get, 1 set: data = a path, 2 from `proc` only, when it spawns: data = u64 the parent's pid, u64 the child's pid; the child starts in the parent's path (at `/` when the table is full); data: mode 1: the new path; mode 2: the two pids. Reply: result: modes 0 and 1: the path's length (1 at the root); mode 2: 0; data: the current path."
    ^self op: 20 named: 'CWD' args: args request: #(#(#bytes 'mode 1: the new path; mode 2: the two pids')) reply: #(#(#bytes 'the current path')) ]
FsServer >> stat [ ^self stat: Dictionary new ]
FsServer >> stat: args [
    "STAT (27): A file's size. Request: length: the path's length; data: the path. Reply: result: the size in bytes."
    ^self op: 27 named: 'STAT' args: args request: #(#(#bytes 'the path')) reply: #() ]
FsServer >> loadimg [ ^self loadimg: Dictionary new ]
FsServer >> loadimg: args [
    "LOADIMG (28): Copy a file's contents into an attached arena. Request: handle: the most bytes the arena takes from the offset; length: the path's length; mode: bits 0..31: the offset in the arena; bits 32..63: the pid of the process that starts the program (0: the caller); data: the path; attachment: the arena, lent for the call (not sent from Stratalk). Reply: length: found in `/bin` or `/sys`: that path's length; else the request's, unchanged; result: the file's size; all of it is copied in; data: found in `/bin` or `/sys`: the path it was found by; else the request's path, left in place; attachments: the arena, given back. From: any program; `proc` when it spawns."
    ^self op: 28 named: 'LOADIMG' args: args request: #(#(#bytes 'the path')) reply: #(#(#bytes 'found in `/bin` or `/sys`: the path it was found by; else the request''s path, left in place')) ]
FsServer >> statfs [ ^self statfs: Dictionary new ]
FsServer >> statfs: args [
    "STATFS (32): The disk's blocks and files. Request: nothing. Reply: result: 3; data: total blocks, used blocks, files."
    ^self op: 32 named: 'STATFS' args: args request: #() reply: #(#(#u64 'total blocks') #(#u64 'used blocks') #(#u64 'files')) ]
FsServer >> readblk [ ^self readblk: Dictionary new ]
FsServer >> readblk: args [
    "READBLK (33): A raw block of the disk. Request: handle: the block's number. Reply: result: 512; data: the block."
    ^self op: 33 named: 'READBLK' args: args request: #() reply: #(#(#bytes 'the block')) ]
FsServer >> readall [ ^self readall: Dictionary new ]
FsServer >> readall: args [
    "READALL (34): An open file, whole, into an attached arena. Request: handle: the id from OPEN (mode 0); length: the most bytes the arena takes from the offset; mode: the offset in the arena; attachment: the arena, lent for the call (not sent from Stratalk). Reply: result: the file's size; all of it is copied in; attachments: the arena, given back."
    ^self op: 34 named: 'READALL' args: args request: #() reply: #() ]
FsServer >> writeall [ ^self writeall: Dictionary new ]
FsServer >> writeall: args [
    "WRITEALL (35): Bytes of an attached arena written to a file open for writing. Request: handle: the id from OPEN (mode 1 or 2); length: the bytes; mode: the offset in the arena; attachment: the arena, lent for the call (not sent from Stratalk). Reply: result: the bytes written (the length); attachments: the arena, given back."
    ^self op: 35 named: 'WRITEALL' args: args request: #() reply: #() ]
FsServer >> query [ ^self query: Dictionary new ]
FsServer >> query: args [
    "QUERY (40): List the files of a directory, part by part. Request: handle: the cursor: 0 at first, then the one the last reply gave; length: the path's length (0: the current path); mode: bit 0: only the count and the facets, no records; bit 1: with no tag in the path, every file wherever it is (not only the root's); data: the path. Reply: handle: the cursor to ask with again (the last file answered); 0: that was all; length: the data's bytes; mode: the facets: bit t for a tag id t below 64 that a file answered carries, less the path's own tags; every bit at the root (no tag, no term, no mode bit 1); 0 for one file; result: the records in this reply; with mode bit 0, the files of the directory itself (not deeper ones), all of them; 1 when the path names one file; data: n, records (n times), records (per file (none with mode bit 0, unless the path names one file))."
    ^self op: 40 named: 'QUERY' args: args request: #(#(#bytes 'the path')) reply: #(#(#u64 'n') #(#repeat 'n times' #(#(#u32 'a tag id'))) #(#pad '') #(#repeat 'per file (none with mode bit 0, unless the path names one file)' #(#(#u16 'record bytes') #(#u16 'name length') #(#u32 'tags') #(#u64 'size') #(#bytes 'the name') #(#pad '') #(#bytes 'the file''s tag ids') #(#pad '')))) ]
FsServer >> tags2 [ ^self tags2: Dictionary new ]
FsServer >> tags2: args [
    "TAGS2 (41): List every tag, or a file's tags, part by part. Request: handle: the cursor: 0 at first, then the one the last reply gave; length: the path's length (0: every tag); data: the path. Reply: handle: the cursor to ask with again (every tag: the last id answered; a file: the index of its next tag in its record); 0: that was all; length: the data's bytes; result: the records in this reply; data: records (per tag)."
    ^self op: 41 named: 'TAGS2' args: args request: #(#(#bytes 'the path')) reply: #(#(#repeat 'per tag' #(#(#u16 'record bytes') #(#u16 'name length') #(#u32 'the tag''s id') #(#u64 'files carrying it') #(#bytes 'the name') #(#pad '')))) ]
FsServer >> setattr [ ^self setattr: Dictionary new ]
FsServer >> setattr: args [
    "SETATTR (42): Set or take away one of a file's attributes. Request: length: the data's bytes; data: the file's path, 0, the attribute's name, 0, the value. Reply: result: 0."
    ^self op: 42 named: 'SETATTR' args: args request: #(#(#bytes 'the file''s path') #(#u8 '0') #(#bytes 'the attribute''s name') #(#u8 '0') #(#bytes 'the value')) reply: #() ]
FsServer >> getattr [ ^self getattr: Dictionary new ]
FsServer >> getattr: args [
    "GETATTR (43): A file's attributes. Request: length: the path's length; data: the path. Reply: length: the data's bytes; result: the records; data: records (per attribute)."
    ^self op: 43 named: 'GETATTR' args: args request: #(#(#bytes 'the path')) reply: #(#(#repeat 'per attribute' #(#(#u16 'record bytes') #(#u16 'name length') #(#u8 'type') #(#u8 'value length') #(#u16 '0') #(#bytes 'the name') #(#pad '') #(#bytes 'the value') #(#pad '')))) ]
FsServer >> snap [ ^self snap: Dictionary new ]
FsServer >> snap: args [
    "SNAP (45): Take, delete, list or restore snapshots. Request: length: the name's length (1..32; none for mode 2); modes: 0 take one, 1 delete one, 2 list them, 3 restore one; data: the snapshot's name. Reply: result: modes 0, 1, 3: 0; mode 2: the records (100 at most); data: records (mode 2: per snapshot, oldest first)."
    ^self op: 45 named: 'SNAP' args: args request: #(#(#bytes 'the snapshot''s name')) reply: #(#(#repeat 'mode 2: per snapshot, oldest first' #(#(#u64 'its commit') #(#bytes 'its name')))) ]
FsServer >> find [ ^self find: Dictionary new ]
FsServer >> find: args [
    "FIND (46): Files across the whole file system by name, part by part. Request: handle: the cursor: 0 at first, then the one the last reply gave; length: the text's length (1..255); mode: only bit 0 counts; modes: 0 the names that begin with the text, 1 the names that hold it; data: the text. Reply: handle: the cursor to ask with again (mode 0: directories passed << 32 | names of the next answered; mode 1: the last object read); 0: that was all; length: the data's bytes; result: the records in this reply; data: 0, records (per file)."
    ^self op: 46 named: 'FIND' args: args request: #(#(#bytes 'the text')) reply: #(#(#u64 '0') #(#repeat 'per file' #(#(#u16 'record bytes') #(#u16 'name length') #(#u32 'tags') #(#u64 'size') #(#bytes 'the name') #(#pad '') #(#bytes 'the file''s tag ids') #(#pad '')))) ]
FsServer >> dbget [ ^self dbget: Dictionary new ]
FsServer >> dbget: args [
    "DBGET (64): A value from a program's tree. Request: length: the data's bytes (8..4032); data: namespace name length, tree name length, key length, 0, the namespace's name, the tree's name, the key. Reply: result: the value's length; data: the value."
    ^self op: 64 named: 'DBGET' args: args request: #(#(#u8 'namespace name length') #(#u8 'tree name length') #(#u16 'key length') #(#u32 '0') #(#bytes 'the namespace''s name') #(#bytes 'the tree''s name') #(#bytes 'the key')) reply: #(#(#bytes 'the value')) ]
FsServer >> dbscan [ ^self dbscan: Dictionary new ]
FsServer >> dbscan: args [
    "DBSCAN (65): Records of a program's tree, in key order. Request: length: the data's bytes (8..4032); modes: 0 ST_GE: from the key on, 1 ST_GT: after the key, 2 ST_LE: from the last key at or before it, 3 ST_LT: from the last key before it; data: namespace name length, tree name length, key length, 0, the namespace's name, the tree's name, the key. Reply: length: the data's bytes; result: the records; data: records (per record)."
    ^self op: 65 named: 'DBSCAN' args: args request: #(#(#u8 'namespace name length') #(#u8 'tree name length') #(#u16 'key length') #(#u32 '0') #(#bytes 'the namespace''s name') #(#bytes 'the tree''s name') #(#bytes 'the key')) reply: #(#(#repeat 'per record' #(#(#u16 'key length') #(#u16 'value length') #(#u32 '0') #(#bytes 'the key') #(#pad '') #(#bytes 'the value') #(#pad '')))) ]
FsServer >> dbbatch [ ^self dbbatch: Dictionary new ]
FsServer >> dbbatch: args [
    "DBBATCH (66): Puts and deletes in a program's tree, in one commit. Request: handle: the items; length: the data's bytes (8..4032); data: namespace name length, tree name length, key length, 0, the namespace's name, the tree's name, records (per item). Reply: result: 0: every item is on the disk."
    ^self op: 66 named: 'DBBATCH' args: args request: #(#(#u8 'namespace name length') #(#u8 'tree name length') #(#u16 'key length') #(#u32 '0') #(#bytes 'the namespace''s name') #(#bytes 'the tree''s name') #(#pad '') #(#repeat 'per item' #(#(#u8 '1 put, 2 delete') #(#u8 '0') #(#u16 'key length') #(#u16 'value length') #(#u16 '0') #(#bytes 'the key') #(#pad '') #(#bytes 'the value') #(#pad '')))) reply: #() ]

OSServer subclass: #KernelServer slots: ''.
KernelServer class >> default [
    "the system core: an endpoint only proc holds (and dev, for HALT and FBLEND)"
    ^self error: 'a program has no endpoint to kernel' ]
KernelServer class >> spec [ ^'kernel.toml' ]
KernelServer >> create [ ^self create: Dictionary new ]
KernelServer >> create: args [
    "CREATE (1): Start a process in an arena that holds its image. Request: data: pid, threads, flags, pin core, c1's core, c2's core, c3's core, c4's core, 0, a0, a1, a2; attachment: the arena, whole, as MEMORY gave it (not sent from Stratalk). Reply: result: 0: the process starts; data: first core; attachments: for a server: a send-only endpoint to its core; on failure: the arena, given back."
    ^self op: 1 named: 'CREATE' args: args request: #(#(#u64 'pid') #(#u64 'threads') #(#u64 'flags') #(#s64 'pin core') #(#u8 'c1''s core') #(#u8 'c2''s core') #(#u8 'c3''s core') #(#u8 'c4''s core') #(#u32 '0') #(#u64 'a0') #(#u64 'a1') #(#u64 'a2')) reply: #(#(#u64 'first core')) ]
KernelServer >> destroy [ ^self destroy: Dictionary new ]
KernelServer >> destroy: args [
    "DESTROY (2): Stop every thread of a process. Request: handle: the pid. Reply: result: 0."
    ^self op: 2 named: 'DESTROY' args: args request: #() reply: #() ]
KernelServer >> memory [ ^self memory: Dictionary new ]
KernelServer >> memory: args [
    "MEMORY (3): A fresh, zeroed arena. Request: handle: with mode 1: the pid whose extra arena it is (not checked); length: the size wanted in bytes: rounded up to whole 256 KiB granules, 1 MiB at least (0: 1 MiB); modes: 0 an arena for the sender, to make a process of (CREATE) or a guest (GSTART), 1 an extra arena of the process the handle names. Reply: result: 0; data: base, size; attachments: the arena."
    ^self op: 3 named: 'MEMORY' args: args request: #() reply: #(#(#u64 'base') #(#u64 'size')) ]
KernelServer >> stats [ ^self stats: Dictionary new ]
KernelServer >> stats: args [
    "STATS (4): Counts of the machine, every core and every process. Request: nothing. Reply: result: the number of processes; data: cores, free memory, total memory, kernel units loaded, switches, KiB moved, processes, 0, records (per core, core 0 first), records (per process)."
    ^self op: 4 named: 'STATS' args: args request: #() reply: #(#(#u64 'cores') #(#u64 'free memory') #(#u64 'total memory') #(#u64 'kernel units loaded') #(#u64 'switches') #(#u64 'KiB moved') #(#u64 'processes') #(#u64 '0') #(#repeat 'per core, core 0 first' #(#(#u8 'pid running') #(#u8 'runnable') #(#u8 'processes') #(#u8 'flags') #(#u32 'cycles per switch') #(#u64 'switches') #(#u64 'KiB moved') #(#u32 'free save-table slots') #(#u32 'cycles per trap'))) #(#repeat 'per process' #(#(#u8 'pid') #(#u8 'core') #(#u8 'state') #(#u8 'flags') #(#u32 '0') #(#u64 'threads') #(#u64 'switches') #(#u64 'bytes moved')))) ]
KernelServer >> tune [ ^self tune: Dictionary new ]
KernelServer >> tune: args [
    "TUNE (5): Set the preemption time slice. Request: length: the time slice in ticks (1 µs): 100..100000. Reply: result: 0: the slice from the next tick on. From: proc only."
    ^self op: 5 named: 'TUNE' args: args request: #() reply: #() ]
KernelServer >> free [ ^self free: Dictionary new ]
KernelServer >> free: args [
    "FREE (6): Give an arena back to the pool. Request: attachment: the arena, whole: one MEMORY gave out and was not used, one that came with EXITED, or an extra arena (mode 1) (not sent from Stratalk). Reply: result: 0."
    ^self op: 6 named: 'FREE' args: args request: #() reply: #() ]
KernelServer >> opHalt [ ^self opHalt: Dictionary new ]
KernelServer >> opHalt: args [
    "HALT (8): Stop every core. Request: nothing. Reply: result: none: the machine halts."
    ^self op: 8 named: 'HALT' args: args request: #() reply: #() ]
KernelServer >> notify [ ^self notify: Dictionary new ]
KernelServer >> notify: args [
    "NOTIFY (9): Send notification bits to a process. Request: handle: the pid; length: the bits. Reply: result: 0."
    ^self op: 9 named: 'NOTIFY' args: args request: #() reply: #() ]
KernelServer >> fblend [ ^self fblend: Dictionary new ]
KernelServer >> fblend: args [
    "FBLEND (10): Lend the framebuffer memory to a process. Request: handle: the pid of the new holder. Reply: result: 0; attachments: the framebuffer memory. From: dev only."
    ^self op: 10 named: 'FBLEND' args: args request: #() reply: #() ]
KernelServer >> gstart [ ^self gstart: Dictionary new ]
KernelServer >> gstart: args [
    "GSTART (11): Start a guest: whole worker cores running another system. Request: data: cores, pin core, allowed servers, flags, console core, image offset; attachment: the arena, as MEMORY gave it, with the guest image at its top (not sent from Stratalk). Reply: result: 0: the guest runs; data: first core, guest id; attachments: on −5, or on −1 for an arena MEMORY did not give: the arena, given back. From: proc only."
    ^self op: 11 named: 'GSTART' args: args request: #(#(#u64 'cores') #(#s64 'pin core') #(#u64 'allowed servers') #(#u64 'flags') #(#u64 'console core') #(#u64 'image offset')) reply: #(#(#u64 'first core') #(#u64 'guest id')) ]
KernelServer >> gstop [ ^self gstop: Dictionary new ]
KernelServer >> gstop: args [
    "GSTOP (12): End a guest and take its cores back. Request: handle: the guest id; mode: bit 0: kill rather than stop. Ignored: the reset does both. Reply: result: 0. From: proc only."
    ^self op: 12 named: 'GSTOP' args: args request: #() reply: #() ]
KernelServer >> ginfo [ ^self ginfo: Dictionary new ]
KernelServer >> ginfo: args [
    "GINFO (13): The guests that run. Request: nothing. Reply: result: the number of guests; data: count, records (per guest)."
    ^self op: 13 named: 'GINFO' args: args request: #() reply: #(#(#u64 'count') #(#repeat 'per guest' #(#(#u64 'id') #(#u8 'first core') #(#u8 'cores') #(#u16 '0') #(#u32 '0') #(#u64 'arena bytes') #(#u64 'state')))) ]
KernelServer >> rings [ ^self rings: Dictionary new ]
KernelServer >> rings: args [
    "RINGS (14): The console rings in T2, for tty. Request: nothing. Reply: result: 0; attachments: an atomic segment: a 64-byte header (its first word: rings handed out so far), then the 64 rings. From: dev only, once."
    ^self op: 14 named: 'RINGS' args: args request: #() reply: #() ]
KernelServer >> gdisk [ ^self gdisk: Dictionary new ]
KernelServer >> gdisk: args [
    "GDISK (15): A guest StrataOS's RAM disk, for fs. Request: nothing. Reply: result: 0; attachments: the RAM disk: writable memory, its length the disk's. From: dev only, in a guest StrataOS, once."
    ^self op: 15 named: 'GDISK' args: args request: #() reply: #() ]
KernelServer >> gcon [ ^self gcon: Dictionary new ]
KernelServer >> gcon: args [
    "GCON (16): An endpoint to the host's tty, for a guest StrataOS's tty. Request: nothing. Reply: result: 0; attachments: an endpoint to the host's tty (read, write, copyable). From: dev only, in a guest StrataOS."
    ^self op: 16 named: 'GCON' args: args request: #() reply: #() ]

OSServer subclass: #NetServer slots: ''.
NetServer class >> default [
    "net: LOOKUP 'net'"
    ^self register: 2 lookup: 'net' index: 0 ]
NetServer class >> spec [ ^'net.toml' ]
NetServer >> read [ ^self read: Dictionary new ]
NetServer >> read: args [
    "READ (1): Read from a TCP connection. Request: handle: the socket id; length: the most bytes wanted; mode: bit 0: do not block. Reply: result: the bytes read; 0 once the peer has closed (or the connection has ended) and everything was read; data: the bytes read."
    ^self op: 1 named: 'READ' args: args request: #() reply: #(#(#bytes 'the bytes read')) ]
NetServer >> write [ ^self write: Dictionary new ]
NetServer >> write: args [
    "WRITE (2): Write to a TCP connection. Request: handle: the socket id; length: the bytes; mode: bit 0: do not block; data: the bytes to send. Reply: result: the bytes taken (at least 1; 0 for a length of 0)."
    ^self op: 2 named: 'WRITE' args: args request: #(#(#bytes 'the bytes to send')) reply: #() ]
NetServer >> close [ ^self close: Dictionary new ]
NetServer >> close: args [
    "CLOSE (4): Close a socket, or stop sending on it. Request: handle: the socket id; mode: bit 0: only stop sending (shutdown). Reply: result: 0."
    ^self op: 4 named: 'CLOSE' args: args request: #() reply: #() ]
NetServer >> stat [ ^self stat: Dictionary new ]
NetServer >> stat: args [
    "STAT (50): The interface, its counters and the sockets in use. Request: nothing. Reply: result: the sockets in use (the records that follow); data: address, STATUS, packets in, packets out, packets dropped, socket slots, first resolver, second resolver, records (per socket in use)."
    ^self op: 50 named: 'STAT' args: args request: #() reply: #(#(#u64 'address') #(#u64 'STATUS') #(#u64 'packets in') #(#u64 'packets out') #(#u64 'packets dropped') #(#u64 'socket slots') #(#u64 'first resolver') #(#u64 'second resolver') #(#repeat 'per socket in use' #(#(#u8 'id') #(#u8 'state') #(#u8 'protocol') #(#u8 'flags') #(#u16 'local port') #(#u16 'remote port') #(#u32 'remote address') #(#u32 'owner pid') #(#u32 'bytes received, not yet read') #(#u32 'bytes sent, not yet acknowledged') #(#u32 'the peer''s window') #(#u32 'retransmissions')))) ]
NetServer >> setip [ ^self setip: Dictionary new ]
NetServer >> setip: args [
    "SETIP (51): Set the interface's address. Request: handle: the new address. Reply: result: 0."
    ^self op: 51 named: 'SETIP' args: args request: #() reply: #() ]
NetServer >> ping [ ^self ping: Dictionary new ]
NetServer >> ping: args [
    "PING (52): Send an ICMP echo request and wait for the reply. Request: handle: the address; length: the payload's bytes (at most 1400); mode: the timeout in clock ticks (microseconds; 0: one second). Reply: result: the round trip in ticks."
    ^self op: 52 named: 'PING' args: args request: #() reply: #() ]
NetServer >> connect [ ^self connect: Dictionary new ]
NetServer >> connect: args [
    "CONNECT (53): Open a TCP connection. Request: handle: the address; length: the port (1..65535). Reply: result: the socket id, once established."
    ^self op: 53 named: 'CONNECT' args: args request: #() reply: #() ]
NetServer >> listen [ ^self listen: Dictionary new ]
NetServer >> listen: args [
    "LISTEN (54): Listen for TCP connections on a port. Request: handle: the port (1..65535). Reply: result: the listening socket's id."
    ^self op: 54 named: 'LISTEN' args: args request: #() reply: #() ]
NetServer >> accept [ ^self accept: Dictionary new ]
NetServer >> accept: args [
    "ACCEPT (55): Take the next established connection of a listener. Request: handle: the listening socket's id; mode: bit 0: do not block. Reply: result: the connection's socket id."
    ^self op: 55 named: 'ACCEPT' args: args request: #() reply: #() ]
NetServer >> udp [ ^self udp: Dictionary new ]
NetServer >> udp: args [
    "UDP (56): Make a UDP socket bound to a port. Request: handle: the port (0: any free one, from 49152 up). Reply: result: the socket id."
    ^self op: 56 named: 'UDP' args: args request: #() reply: #() ]
NetServer >> sendto [ ^self sendto: Dictionary new ]
NetServer >> sendto: args [
    "SENDTO (57): Send a datagram from a UDP socket. Request: handle: the socket id; length: 16 + the payload's bytes (the payload at most 1472); data: address, port, payload. Reply: result: the payload's bytes."
    ^self op: 57 named: 'SENDTO' args: args request: #(#(#u64 'address') #(#u64 'port') #(#bytes 'payload')) reply: #() ]
NetServer >> recvfrom [ ^self recvfrom: Dictionary new ]
NetServer >> recvfrom: args [
    "RECVFROM (58): Receive a datagram on a UDP socket. Request: handle: the socket id; length: the most payload bytes wanted; mode: bit 0: do not block. Reply: result: the payload's bytes given; data: the sender's address, the sender's port, payload."
    ^self op: 58 named: 'RECVFROM' args: args request: #() reply: #(#(#u64 'the sender''s address') #(#u64 'the sender''s port') #(#bytes 'payload')) ]
NetServer >> resolve [ ^self resolve: Dictionary new ]
NetServer >> resolve: args [
    "RESOLVE (60): A host name's IPv4 addresses (DNS). Request: length: the name's bytes (1..127); data: the name. Reply: result: the first address; data: count, address 1, address 2, address 3, address 4, the canonical name."
    ^self op: 60 named: 'RESOLVE' args: args request: #(#(#bytes 'the name')) reply: #(#(#u64 'count') #(#u64 'address 1') #(#u64 'address 2') #(#u64 'address 3') #(#u64 'address 4') #(#text 'the canonical name')) ]
NetServer >> setdns [ ^self setdns: Dictionary new ]
NetServer >> setdns: args [
    "SETDNS (61): Set the resolvers. Request: handle: the first resolver's address; length: the second's (0: none). Reply: result: 0."
    ^self op: 61 named: 'SETDNS' args: args request: #() reply: #() ]

OSServer subclass: #PipeServer slots: ''.
PipeServer class >> default [
    "pipe: c4 of every process"
    ^self register: 4 lookup: nil index: 0 ]
PipeServer class >> spec [ ^'pipe.toml' ]
PipeServer >> read [ ^self read: Dictionary new ]
PipeServer >> read: args [
    "READ (1): Read from the read end of a pipe. Request: handle: the read end's id; length: the most bytes wanted; mode: bit 0: do not block. Reply: result: the bytes read: at most the length, 4032 and what the ring holds; 0 at the end (no writer is left); data: the bytes read."
    ^self op: 1 named: 'READ' args: args request: #() reply: #(#(#bytes 'the bytes read')) ]
PipeServer >> write [ ^self write: Dictionary new ]
PipeServer >> write: args [
    "WRITE (2): Write to the write end of a pipe. Request: handle: the write end's id; length: the bytes; mode: bit 0: do not block; data: the bytes to write. Reply: result: the bytes taken: at most the length, 4032 and the room in the ring; at least 1 unless the length is 0."
    ^self op: 2 named: 'WRITE' args: args request: #(#(#bytes 'the bytes to write')) reply: #() ]
PipeServer >> close [ ^self close: Dictionary new ]
PipeServer >> close: args [
    "CLOSE (4): Close one end of a pipe. Request: handle: the end's id. Reply: result: 0, always."
    ^self op: 4 named: 'CLOSE' args: args request: #() reply: #() ]
PipeServer >> pipe [ ^self pipe: Dictionary new ]
PipeServer >> pipe: args [
    "PIPE (8): Make a pipe. Request: nothing. Reply: result: read id | write id << 8: the ids of the two ends, both the caller's."
    ^self op: 8 named: 'PIPE' args: args request: #() reply: #() ]

OSServer subclass: #ProcServer slots: ''.
ProcServer class >> default [
    "proc: c1 of every process"
    ^self register: 1 lookup: nil index: 0 ]
ProcServer class >> spec [ ^'proc.toml' ]
ProcServer >> spawn [ ^self spawn: Dictionary new ]
ProcServer >> spawn: args [
    "SPAWN (5): Start a program. Request: length: the command's bytes (at most 440 are used); mode: bit 0: the child gets no endpoints at all (c1..c4 empty: not even proc's), a sandbox; bit 1: pin the first thread to core `(mode >> 8) & 255` (not core 0); bits 16..23: the arena's size in MiB (0: 1 MiB); data: thread count, descriptor of the child's handle 0, descriptor of the child's handle 1, descriptor of the child's handle 2, the command. Reply: result: the child's pid (4..239)."
    ^self op: 5 named: 'SPAWN' args: args request: #(#(#u64 'thread count') #(#u64 'descriptor of the child''s handle 0') #(#u64 'descriptor of the child''s handle 1') #(#u64 'descriptor of the child''s handle 2') #(#bytes 'the command')) reply: #() ]
ProcServer >> wait [ ^self wait: Dictionary new ]
ProcServer >> wait: args [
    "WAIT (6): Wait for a child to end. Request: handle: the child's pid; 0: any child; mode: bit 0: do not block. Reply: result: the child's exit status; data: the child's pid."
    ^self op: 6 named: 'WAIT' args: args request: #() reply: #(#(#u64 'the child''s pid')) ]
ProcServer >> kill [ ^self kill: Dictionary new ]
ProcServer >> kill: args [
    "KILL (7): Stop a process. Request: handle: the pid. Reply: result: 0: stopped, or it had already ended."
    ^self op: 7 named: 'KILL' args: args request: #() reply: #() ]
ProcServer >> ps [ ^self ps: Dictionary new ]
ProcServer >> ps: args [
    "PS (9): The processes. Request: nothing. Reply: result: the number of records (32 bytes each); data: records (per process)."
    ^self op: 9 named: 'PS' args: args request: #() reply: #(#(#repeat 'per process' #(#(#u8 'pid') #(#u8 'state') #(#u8 'core') #(#u8 'parent') #(#u8 'flags') #(#u8 'threads') #(#u16 '0') #(#u32 'switches') #(#u32 'KiB moved') #(#u64 'name') #(#u64 '0')))) ]
ProcServer >> info [ ^self info: Dictionary new ]
ProcServer >> info: args [
    "INFO (16): A summary of the system. Request: nothing. Reply: result: 0; data: cores, free heap, total heap, processes, kernel unit loads, context switches, KiB moved, 0."
    ^self op: 16 named: 'INFO' args: args request: #() reply: #(#(#u64 'cores') #(#u64 'free heap') #(#u64 'total heap') #(#u64 'processes') #(#u64 'kernel unit loads') #(#u64 'context switches') #(#u64 'KiB moved') #(#u64 '0')) ]
ProcServer >> signal [ ^self signal: Dictionary new ]
ProcServer >> signal: args [
    "SIGNAL (17): Interrupt a process (Ctrl-C). Request: handle: the pid. Reply: result: 0: interrupted, killed, or it had already ended."
    ^self op: 17 named: 'SIGNAL' args: args request: #() reply: #() ]
ProcServer >> catch [ ^self catch: Dictionary new ]
ProcServer >> catch: args [
    "CATCH (22): Catch interrupts, or be killed by them. Request: handle: not 0: catch them (SIGNAL interrupts the caller); 0: SIGNAL kills it (the default). Reply: result: 0."
    ^self op: 22 named: 'CATCH' args: args request: #() reply: #() ]
ProcServer >> lookup [ ^self lookup: Dictionary new ]
ProcServer >> lookup: args [
    "LOOKUP (25): An endpoint to a server, by name. Request: length: the name's bytes (1..8); data: the name. Reply: result: 0; attachments: a send-only endpoint to the server's core, minted with the reply."
    ^self op: 25 named: 'LOOKUP' args: args request: #(#(#bytes 'the name')) reply: #() ]
ProcServer >> opRegister [ ^self opRegister: Dictionary new ]
ProcServer >> opRegister: args [
    "REGISTER (29): Give a name to the caller's core. Request: length: the name's bytes (1..8); mode: bit 0: net only: it is ready for CANCEL and CLEANUP; data: the name. Reply: result: 0."
    ^self op: 29 named: 'REGISTER' args: args request: #(#(#bytes 'the name')) reply: #() ]
ProcServer >> sched [ ^self sched: Dictionary new ]
ProcServer >> sched: args [
    "SCHED (30): The time slice and the switch rates; set the slice. Request: handle: 0: read; not 0: set; length: set: the new time slice in ticks (100..100000; 1 tick = 1 microsecond). Reply: result: 0; data: time slice, switches per second, KiB moved per second."
    ^self op: 30 named: 'SCHED' args: args request: #() reply: #(#(#u64 'time slice') #(#u64 'switches per second') #(#u64 'KiB moved per second')) ]
ProcServer >> cores [ ^self cores: Dictionary new ]
ProcServer >> cores: args [
    "CORES (31): What every core is doing. Request: nothing. Reply: result: the number of cores (one 32-byte record each); data: records (per core)."
    ^self op: 31 named: 'CORES' args: args request: #() reply: #(#(#repeat 'per core' #(#(#u8 'core') #(#u8 'pid running') #(#u8 'runnable') #(#u8 'processes') #(#u8 'flags') #(#u8 'free save-table slots') #(#u16 '0') #(#u32 'switches') #(#u32 'KiB moved') #(#u32 'cycles per switch') #(#u32 'cycles per trap') #(#u64 '0')))) ]
ProcServer >> whois [ ^self whois: Dictionary new ]
ProcServer >> whois: args [
    "WHOIS (39): The pid registered under a name. Request: length: the name's bytes (1..8); data: the name. Reply: result: the pid; 0 for a server started at boot (proc, dev, fs, tty, pipe)."
    ^self op: 39 named: 'WHOIS' args: args request: #(#(#bytes 'the name')) reply: #() ]
ProcServer >> guest [ ^self guest: Dictionary new ]
ProcServer >> guest: args [
    "GUEST (40): Start a guest OS on whole cores. Request: data: cores, arena MiB, the guest image's path. Reply: result: 0; data: guest id, first core."
    ^self op: 40 named: 'GUEST' args: args request: #(#(#u64 'cores') #(#u64 'arena MiB') #(#text 'the guest image''s path')) reply: #(#(#u64 'guest id') #(#u64 'first core')) ]
ProcServer >> gueststop [ ^self gueststop: Dictionary new ]
ProcServer >> gueststop: args [
    "GUESTSTOP (41): Stop a guest. Request: handle: the guest id. Reply: result: 0."
    ^self op: 41 named: 'GUESTSTOP' args: args request: #() reply: #() ]
ProcServer >> guests [ ^self guests: Dictionary new ]
ProcServer >> guests: args [
    "GUESTS (42): The guests. Request: nothing. Reply: result: the number of guests (32 bytes each); data: records (per guest)."
    ^self op: 42 named: 'GUESTS' args: args request: #() reply: #(#(#repeat 'per guest' #(#(#u64 'guest id') #(#u64 'first core | cores << 8') #(#u64 'arena bytes') #(#u64 'state')))) ]
ProcServer >> more [ ^self more: Dictionary new ]
ProcServer >> more: args [
    "MORE (43): An extra arena for the caller. Request: handle: the bytes wanted (rounded up to whole 256 KiB granules, 1 MiB at least; 0: 1 MiB). Reply: result: 0; data: the arena's size in bytes; attachments: the extra arena, zeroed."
    ^self op: 43 named: 'MORE' args: args request: #() reply: #(#(#u64 'the arena''s size in bytes')) ]
ProcServer >> less [ ^self less: Dictionary new ]
ProcServer >> less: args [
    "LESS (44): Give an extra arena back. Request: attachment: the extra arena, whole, as MORE gave it (not sent from Stratalk). Reply: result: 0."
    ^self op: 44 named: 'LESS' args: args request: #() reply: #() ]

OSServer subclass: #SystemServer slots: ''.
SystemServer class >> default [
    "from proc and the kernel: sent by proc to the servers (36–38), by the kernel to proc (7)"
    ^self error: 'a program has no endpoint to system' ]
SystemServer class >> spec [ ^'system.toml' ]
SystemServer >> exited [ ^self exited: Dictionary new ]
SystemServer >> exited: args [
    "EXITED (7): A process has ended. Request: handle: the pid; length: the exit status: bits 0–31 the code, bit 62 killed, bit 63 faulted (the cause in bits 0–7); attachment: the process's arena, when CREATE asked to have it back (an old bare-metal program's output) (not sent from Stratalk). Reply: result: 0. From: the kernel, to proc."
    ^self op: 7 named: 'EXITED' args: args request: #() reply: #() ]
SystemServer >> dups [ ^self dups: Dictionary new ]
SystemServer >> dups: args [
    "DUPS (36): A process now holds these handles too. Request: length: 64, whatever the count (not read); data: owner pid, count, records (per handle). Reply: result: 0. From: proc, to fs, tty and pipe, while it spawns."
    ^self op: 36 named: 'DUPS' args: args request: #(#(#u64 'owner pid') #(#u64 'count') #(#repeat 'per handle' #(#(#u64 'the server''s id for it')))) reply: #() ]
SystemServer >> cleanup [ ^self cleanup: Dictionary new ]
SystemServer >> cleanup: args [
    "CLEANUP (37): A process ended: drop everything it held. Request: handle: the pid. Reply: result: 0. From: proc, to fs, tty, pipe and net."
    ^self op: 37 named: 'CLEANUP' args: args request: #() reply: #() ]
SystemServer >> cancel [ ^self cancel: Dictionary new ]
SystemServer >> cancel: args [
    "CANCEL (38): A process was interrupted: answer its waiting requests. Request: handle: the pid. Reply: result: 0. From: proc, to tty, pipe and net."
    ^self op: 38 named: 'CANCEL' args: args request: #() reply: #() ]

OSServer subclass: #TtyServer slots: ''.
TtyServer class >> default [
    "tty: c3 of every process"
    ^self register: 3 lookup: nil index: 0 ]
TtyServer class >> spec [ ^'tty.toml' ]
TtyServer >> read [ ^self read: Dictionary new ]
TtyServer >> read: args [
    "READ (1): Read from the console. Request: handle: 0 (not checked); length: the most bytes wanted (at most 4032 are given; with mode bit 1 and a pointer, 32); mode: bit 0: do not block; bit 1: the pointer's events too. Reply: mode: the pointer events after offset 32 (0..8); 0 without mode bit 1 or without a pointer (an error leaves the request's mode); result: the key bytes read; 0 at the end of input (with mode bit 1, 0 may also come with pointer events); data: the bytes read, records (per pointer event, from offset 32 (the mode word says how many))."
    ^self op: 1 named: 'READ' args: args request: #() reply: #(#(#bytes 'the bytes read') #(#repeat 'per pointer event, from offset 32 (the mode word says how many)' #(#(#u16 'x') #(#u16 'y') #(#u8 'buttons') #(#u8 'wheel y') #(#u8 'wheel x') #(#u8 'kind')))) ]
TtyServer >> write [ ^self write: Dictionary new ]
TtyServer >> write: args [
    "WRITE (2): Write to the console. Request: handle: 1 or 2 (not checked); length: the bytes; modes: 0 write, 2 write, and send the sender's console ring back (its c6 is free); data: the bytes to write. Reply: result: the bytes written: the length, at most 4032; attachments: with mode 2, a copy of the sender's console ring (not for guests, nor if it has none)."
    ^self op: 2 named: 'WRITE' args: args request: #(#(#bytes 'the bytes to write')) reply: #() ]
TtyServer >> close [ ^self close: Dictionary new ]
TtyServer >> close: args [
    "CLOSE (4): Close the console (it stays open). Request: handle: the handle (not checked). Reply: result: 0."
    ^self op: 4 named: 'CLOSE' args: args request: #() reply: #() ]
TtyServer >> setfg [ ^self setfg: Dictionary new ]
TtyServer >> setfg: args [
    "SETFG (18): Make a process the foreground: Ctrl-C interrupts it. Request: handle: the pid (not checked). Reply: result: 0."
    ^self op: 18 named: 'SETFG' args: args request: #() reply: #() ]
TtyServer >> conmode [ ^self conmode: Dictionary new ]
TtyServer >> conmode: args [
    "CONMODE (19): Cooked or raw input. Request: handle: bit 0: 0 cooked, 1 raw. Reply: result: 0."
    ^self op: 19 named: 'CONMODE' args: args request: #() reply: #() ]
TtyServer >> attach [ ^self attach: Dictionary new ]
TtyServer >> attach: args [
    "ATTACH (20): Give the console's input to a guest until it comes back. Request: handle: the guest id (240..255). Reply: result: how it came back: 0 Ctrl-] was typed, 1 the guest closed the console, 2 the guest was stopped. From: a StrataOS process (the `guest` command)."
    ^self op: 20 named: 'ATTACH' args: args request: #() reply: #() ]

OSServer subclass: #WsServer slots: ''.
WsServer class >> default [
    "ws: LOOKUP 'ws'"
    ^self register: 2 lookup: 'ws' index: 0 ]
WsServer class >> spec [ ^'ws.toml' ]
WsServer >> create [ ^self create: Dictionary new ]
WsServer >> create: args [
    "CREATE (40): Open a window. Request: mode: bit 0: interrupt me (SIGNAL) when events wait and I am not in EVENT; data: width, height, title. Reply: result: the window id (1..4); data: width, height."
    ^self op: 40 named: 'CREATE' args: args request: #(#(#u64 'width') #(#u64 'height') #(#bytes 'title')) reply: #(#(#u64 'width') #(#u64 'height')) ]
WsServer >> damage [ ^self damage: Dictionary new ]
WsServer >> damage: args [
    "DAMAGE (41): Copy a band of pixels into the window, or redraw part of it. Request: handle: the window id; data: x, y, w, h, stride; attachment: the band (memory), lent for the call and given back with the reply (not sent from Stratalk). Reply: result: 0; attachments: the band, given back."
    ^self op: 41 named: 'DAMAGE' args: args request: #(#(#u64 'x') #(#u64 'y') #(#u64 'w') #(#u64 'h') #(#u64 'stride')) reply: #() ]
WsServer >> text [ ^self text: Dictionary new ]
WsServer >> text: args [
    "TEXT (42): Draw text into the window. Request: handle: the window id; length: 32 + the string's bytes; data: x, y, fg, bg, the string. Reply: result: 0."
    ^self op: 42 named: 'TEXT' args: args request: #(#(#u64 'x') #(#u64 'y') #(#u64 'fg') #(#u64 'bg') #(#bytes 'the string')) reply: #() ]
WsServer >> fill [ ^self fill: Dictionary new ]
WsServer >> fill: args [
    "FILL (43): Fill a rectangle of the window with a colour. Request: handle: the window id; data: x, y, w, h, colour. Reply: result: 0."
    ^self op: 43 named: 'FILL' args: args request: #(#(#u64 'x') #(#u64 'y') #(#u64 'w') #(#u64 'h') #(#u64 'colour')) reply: #() ]
WsServer >> event [ ^self event: Dictionary new ]
WsServer >> event: args [
    "EVENT (44): Wait for the window's next event. Request: handle: the window id; length: the timeout in clock ticks (microseconds; 0: none); mode: bit 0: do not block. Reply: result: 0; data: kind, value, width, height."
    ^self op: 44 named: 'EVENT' args: args request: #() reply: #(#(#u64 'kind') #(#u64 'value') #(#u64 'width') #(#u64 'height')) ]
WsServer >> destroy [ ^self destroy: Dictionary new ]
WsServer >> destroy: args [
    "DESTROY (45): Close a window. Request: handle: the window id. Reply: result: 0."
    ^self op: 45 named: 'DESTROY' args: args request: #() reply: #() ]
WsServer >> title [ ^self title: Dictionary new ]
WsServer >> title: args [
    "TITLE (46): Change a window's title. Request: handle: the window id; data: title. Reply: result: 0."
    ^self op: 46 named: 'TITLE' args: args request: #(#(#bytes 'title')) reply: #() ]

OSServer class >> svcCalls [ "The svc calls (not messages): the VM makes them" ^#('WAIT_REPLY' 'RECEIVE' 'REPLY' 'YIELD' 'EXIT' 'NOTIFY_WAIT' 'SET_MIRROR' 'PARK' 'UNPARK' 'CLOCK' 'SET_SCRATCH' 'SEND' 'UNITS' 'PAGE') ]
OSServer class >> opCount [ ^129 ]
