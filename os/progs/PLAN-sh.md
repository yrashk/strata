# Step 5: the advanced shell (os/progs/sh.s) — working plan

Spec: doc/strataos-0.2.md 2.4-2.7. Owner of os/progs/sh.s, tools/test-sh.sh, tools/test-sh.out.

## Design
- Raw console only inside read_line (CONMODE 1 when stdin is the tty and the shell is
  interactive); everything else (jobs, builtins) runs cooked.
- History: 32 slots x 256 bytes in the arena at 0x10000 (tget/tput, tag 1); lengths in D-LS.
- Scripts (`sh FILE`, `source`, rc): whole file copied into the arena at
  0x20000 + (depth - 1) * 64 KiB; one 8-aligned 520-byte window per line per depth, so
  `source` nests (depth <= 3). A script stops after an interrupted command.
- Lines: split into commands at ; && || & (outside quotes and after \), # comments;
  each command is tokenized ($?, $$, $NAME, '...', "...", \x) and parsed into up to 4
  stages. && / || test $? of the last command run.
- Builtins in a pipeline or in the background run as `sh -c 'w' 'w'...` (the parser keeps
  a re-quoted copy of each stage's words in qtxt).
- Completion: command position = only run/time/-n N/-c N before the word in its command;
  candidates = builtins + files whose first 4 bytes are "STX2"; else all files.
- Image: code 0x8000..0xCB08 (of 0x10000), data 0..0x80F0 (of 0xA000).

## Checklist
- [x] line editor (raw mode, keys, redraw)
- [x] history + `history`
- [x] Tab completion (commands = builtins + STX2 files; files; LCP; second Tab lists)
- [x] syntax: quotes, $?, $$, $NAME, set/unset, \x, ; && || & #, pipes, redirections
- [x] jobs: jobs, fg, wait %n, kill, reports
- [x] builtins: help echo set unset history jobs fg wait kill sleep time clear source exit halt run true false
- [x] options -l -i -c FILE; plain stdin (no prompt) otherwise
- [x] demo / test-break / test-preempt / test-as (StrataOS part) / boot-jit still pass
- [x] compare-boot (emulator vs RTL): OK (takeover agent; it now also requires exit status 0)
- [x] tools/test-sh.sh is in `make test`
- [x] tools/test-sh.sh (+ identical output under -J -T real)

## Known limitations
- Redraws use relative cursor moves: a line longer than the terminal width redraws wrongly.
- Completion assumes an 80-column terminal; no completion inside quotes or of $NAME.
- No `cd` (directories are tags, see os/servers/fs.s: there is no current one), no
  globbing, no 2> redirection. Tab completes a file name behind a tag path (`cat /doc/mo`).

## Wrap-up (takeover agent)
- Checked against spec 2.7 in scripted interactive runs: editing keys, history, Tab,
  Ctrl-C abandons a line, Ctrl-D exits, status in the prompt, `sh -i` on a pipe, `-c`,
  scripts, jobs/fg/wait/kill: all present. Gaps are only the limitations above.
- proc puts the console back in cooked mode when it restarts a dead login shell.
