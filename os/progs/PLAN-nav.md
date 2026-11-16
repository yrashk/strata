# nav: a file navigator

`nav` (`os/progs/nav.s`) is a two-panel file navigator in the line of the
Norton and Midnight Commanders, for the tag file system, with a search that
finds files across the whole disk as one types.

## Form

A full-screen text program, like `vi`: it draws with ANSI escapes and reads
keys from its standard input. So one program runs on the console (`make
boot`), in a `term` window under `ws`, and in the browser (the play page's
terminal is xterm.js), with no drawing code of its own. The mouse comes the
way terminals give it: nav asks for SGR mouse reports (ESC [ ? 1000 h,
ESC [ ? 1006 h) and reads ESC [ < b ; x ; y M / m. xterm.js answers that by
itself; `term` learns to (a click in its window becomes such a report when
the program has asked). A `ws` client with its own drawing would have no
console or browser terminal version, and two front ends would be two
programs.

## Decisions

- Memory grows on demand: `proc` has two new calls, MORE (an extra arena
  for the caller, which the kernel records as that process's and frees
  with it) and LESS (one given back). nav keeps its growing data in one
  such arena (c6) as areas side by side, and replaces it with a bigger one
  when an area fills (the old one is moved to c7 while the copy is made;
  c7, the clock, is restored afterwards).
- The command line (Ctrl-X) alternates with the search, as in the
  Midnight Commander: typing goes to one or the other.
- The panels hold their entries in that growing memory, each as long as
  its name and its directories, with an index per panel ({sort key, offset})
  sorted there too by a merge sort (directories first, then names).
- A directory is a tag path. A panel lists the files of its path (QUERY,
  part by part) and then its subdirectories (the facets); `..` first except
  at `/`. The root lists the snapshots too, as `@NAME/`, read-only
  directories (`/@NAME/...` paths).
- A directory is the set of its files' tags (the file system's rework on
  `main`): a file is in exactly one directory. A directory panel shows its
  own files and, as subdirectories, the other tags of its deeper ones'
  files (QUERY's nameless records). A search's panel shows each file's
  directory in a third column. The two ways of putting a file into the
  other panel's directory are separate keys: F5 copies (a new file), F2
  tags it with that directory's tags too (one RENAME: the same file, now
  in the directory of both). F8 offers, besides deleting, taking the
  directory's last tag away (UNTAG: up a level).
- F4 runs the system's `vi` on the file (`nav -e EDITOR` names another
  command) and redraws when it ends.
- Search: any printable key starts it. A plain text asks the file server
  for the names that begin with it (FIND mode 0, new: one seek per
  directory in the names' tree) and shows those at once, then for the
  names that hold it anywhere (FIND mode 1, part by part, the keyboard
  checked between parts so a new key restarts at once), and the
  directories whose names hold it (from the tag list read at start). A
  text with `/`, `=`, `<` or `>` is a path with terms (`lang=asm`,
  `size>9000`, `/src/ls*`): QUERY over every file. Ranked: exact name,
  then names and directories that begin with the text, then the rest;
  shorter names first within a rank.
- The file server's FIND (call 46) is a new code unit (`fsunits.s`, uf);
  nothing else in the server changed but its dispatch.

## Plan

- [x] FIND in the file server
- [x] One panel drawn from a directory; keys up/down/pgup/pgdn/home/end
- [x] Two panels, Tab, Enter into a directory, Backspace / `..` up
- [x] Function-key bar; F3 view (text, hex), F4 vi, F5 copy, F2 also file
      here, F6 move/rename, F7 new directory (a tag on the marked files),
      F8 delete with confirmation, F10 quit; Insert / Ctrl-T marks
- [x] Search with typeahead; timing on a 10,000-file disk
- [x] Ctrl-Q quick view in the other panel (also F9)
- [x] Snapshots as read-only directories
- [x] Mouse: SGR reports, in `term` too
- [x] Function keys from the emulator's window (F1..F10, Insert)
- [x] Tests (`tools/test-nav.sh`: `nav` fast, `nav-ws` mid), README, site,
      `help`, `doc/strataos.md`, Makefile, play page preset (`?run=nav`)
- [x] No fixed limits: entries of any length in an extra arena from `proc`
      (new calls MORE / LESS, the kernel's MEMORY mode 1) that grows on
      demand; the order sorted in far memory; the viewer reads the part of a
      file it shows (any size); tag names and ids without a table size
- [x] A command line that alternates with the search (Ctrl-X): `sh -c` in
      the panel's directory; Ctrl-F inserts the cursor's path
- [ ] Not done: sorting by size or time
- [ ] Not tried: the play page in a browser (the preset types `nav /src
      /bin`; xterm.js sends F-keys and SGR mouse reports itself)

## Measurements

The disk: the standard files and 10,000 generated ones (names like
`kernel_queue59.s`) in 40 directories `p00`..`p39`, a seventh of them in
`arch` too, and `/deep/inner/lib/proj/needle.s`: 10,140 files.
`nav -s TEXT` runs a search to its end; machine time (`-T virtual`, the
interpreter, 8 cores):

| text | found | first results | all |
|---|---|---|---|
| `needle` | 1 | 13.5 ms | 225.5 ms |
| `kernel` | 693 (357 begin with it) | 14.9 ms | 288.7 ms |
| `k` | 698 | 14.4 ms | 296.1 ms |
| `eta` | 691 | 23.0 ms | 241.5 ms |
| `zzz` | 0 | 222.9 ms (none) | 222.9 ms |
| `_` (every generated file) | 10,002 | 17.6 ms | 351.3 ms |

(After `main`'s rework of names: a directory is a tag set, about 80 of them
on this disk, each a seek or two. Before it, with an entry per tag: 4 to
14 ms to the first results.)

The first results are what FIND mode 0 gives (names that begin with the
text: a seek or two per directory, then the records of the files found). "All"
adds FIND mode 1, which reads every record (about 21 us each): there is no
index of parts of names. It comes in parts of 384 records (about 8 ms), and
a key typed meanwhile stops it, so typing is not held up. Before FIND, the
only way was QUERY over every file with `PREFIX*`: 190 ms for `needle*`.
Under the JIT, in the host's time (the screenshot): `kernel`, 0.9 ms to the
first results and 47 ms to all.

The `_` search fills the heap past its first MiB (pools, index, the sort's
half grow); after nav ends, `free` shows the memory back.

Sizes: code 25.6 KiB of the 32 KiB I-LS; data 37.2 KiB of the 40 KiB a
program has in the D-LS (the buffers that are indexed by label end below
0x8000; the ones above it are reached by address only). The file server's
new unit uf is 1,132 of its 2,048 bytes.
