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

- The panels hold their entries in far memory (the arena: 1024 entries of
  256 bytes per panel); the D-LS keeps an index per panel, sorted
  (directories first, then names), and the rows of the screen.
- A directory is a tag path. A panel lists the files of its path (QUERY,
  part by part) and then its subdirectories (the facets); `..` first except
  at `/`. The root lists the snapshots too, as `@NAME/`, read-only
  directories (`/@NAME/...` paths).
- A file is in every directory it is tagged with. The third column says
  where else it is ("also in" with the other tags), and the two ways of
  putting a file into the other panel's directory are separate keys:
  F5 copies (a new file, its own contents), F2 files it there too (TAG: the
  same file, now in both). F8 asks, for a file in several directories,
  whether to delete it everywhere or only take it out of this one (UNTAG).
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
- [ ] One panel drawn from a directory; keys up/down/pgup/pgdn/home/end
- [ ] Two panels, Tab, Enter into a directory, Backspace / `..` up
- [ ] Function-key bar; F3 view (text, hex), F4 vi, F5 copy, F2 also file
      here, F6 move/rename, F7 new directory (a tag on the marked files),
      F8 delete with confirmation, F10 quit; Insert / Ctrl-T marks
- [ ] Search with typeahead; timing on a 10,000-file disk
- [ ] Ctrl-Q quick view in the other panel
- [ ] Snapshots as read-only directories
- [ ] Mouse: SGR reports, in `term` too
- [ ] Function keys from the emulator's window (F1..F10)
- [ ] Tests (`tools/test-nav.sh`), README, site, `help`, `doc/strataos.md`,
      Makefile, play page preset

## Measurements

(filled in as they are made)
