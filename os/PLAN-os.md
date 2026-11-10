# StrataOS 0.1 — step 4 working plan (agent notes; delete when integrated)

Spec: doc/strataos-0.2.md section 2. Design summary: the header of os/kernel.s.
Files: os/kernel.s (resident), os/kunits/{boot,ops,events}.s (kernel code units),
os/servers/{proc,dev,fs,tty,pipe}.s, os/lib/{sys,srv}.s, os/progs/*.s, os/files/,
os/demo.txt, firmware/{bootrom,fw}.s, tools/mkdisk.c, tools/compare-boot.sh,
tools/test-break.sh, tools/test-preempt.sh, tools/test-as.sh (StrataOS part), Makefile OS rules.

## Decisions taken (deviations / interpretations of the spec)
- Kernel ops: 1 CREATE, 2 DESTROY, 3 MEMORY, 4 STATS (spec) + 5 NOTIFY (proc → kernel:
  interrupt a sleeper / NOTIFY_WAIT), 6 FREE (give an arena back), 8 HALT (from dev).
  Kernel → proc: 7 EXITED (handle = pid, length = status; arena attached if CREATE had F_KEEP).
- CREATE takes endpoint *core numbers* for c1..c4 (the dispatcher mints the endpoints)
  and the pid (proc allocates pids). A server's CREATE reply carries an endpoint to it.
- The kernel itself loads proc, dev, fs from the disk at boot (fs must exist before
  anything can be loaded); proc starts tty, pipe, then `sh -l`. Cores: proc 1, dev 2, fs 3.
- svc 12 SEND (a1 endpoint register, a5 attachment register, then as WAIT_REPLY).
- svc: 1 WAIT_REPLY (a1 doorbell core, a2 timeout, a3 awaited base: 0 own buffer /
  -1 nothing = sleep, a4 destination register), 2 RECEIVE (a1 tag mask), 3 REPLY
  (a2 bit2 send c4, bit0 send c7, bit1 mint EP for core a3 — privileged), 4 YIELD,
  5 EXIT, 6 NOTIFY_WAIT, 7 SET_MIRROR, 8 PARK, 9 UNPARK, 10 CLOCK.
- Demux: job pieces (by base, from core 0) → a local process's buffer (reply; from the
  own core it alternates request/reply: PR_OUTL) → awaited base → a sender inside a
  local multi-thread process's window = sibling gift (queued, owner = slot) → a 4 KiB
  T3 capability = request → anything else = attachment (rides with the next message
  from the same sender, lands in c6 then c7). Arena-containment is not used: the
  sender's window decides (windows never include server cores).
- User attachments: svc 12 SEND (sys_msga): attachment + message sent by the dispatcher
  in one step. (`csend cX, cE` then `csend c5, cE` is reliable only from processes alone
  on their core: proc, F_SOLO, still does that.)
- Max 3 threads per worker core (save-table budget). Placement: servers on empty cores;
  ordinary 1-thread processes prefer cores with a server (score = processes + 1 if no
  server); N threads on N contiguous non-server cores with the least-loaded busiest core.
- No exclusive cores (user decision): bare programs and `-n N` = N threads, window
  corebase/corecount; user ctake/cpoll/tany(bit16) trap priv and are emulated
  (block = S_GIFT / S_TANY; the instruction is retried on wake; core 0's tick stops a
  core with such a waiter while another thread runs: CA_GIFTW).
- c8..c15 of a thread survive only while it is not switched out (spec: processes own
  c0..c7); the dispatcher stashes c8, c9 (T_P8/T_P9) on traps and returns them.
- Old protocol (bare `as < in > out`): proc READALLs the input into arena 0x80000 (a0 =
  length, a1 = 1); at exit the arena comes back with EXITED (F_KEEP) and proc WRITEALLs
  arena[0xC0000, +code) (≤ 64 KiB) to the output file; the status becomes 0.
- Arena layout (N threads): [0,P) program, P = 0xD0000 - (N-1)*48K; thread k≥1 save
  areas below 0xD0000; image [0xD0000,0xF0000) (128 KiB max); thread 0 save 0xF0000;
  buffer 0xFF000; start-up block 0x7F000. Arenas are scrubbed (zeroed) at MEMORY.
- A bare-metal thread's saved D-LS is all of 0..0x9FFF (as keeps tables there); a
  StrataOS program's is its data section.
- Core 0's resident code is at I-LS 0x7000+ (overlay.s writes 0x7000..0x707F on workers).
- clock.s / gfx.s are left off the disk (they need the device root).
- dev's GRANT_FB: only to the pid registered as "ws" (proc WHOIS); the kernel lends the
  framebuffer from its own revocation domain (FBLEND) and revokes it when the holder ends.
- Interrupts: SIGNAL to a catching process: proc answers its held WAIT with -2 or
  remembers it for the next WAIT, sends CANCEL(pid) to tty and pipe (held reads → -2),
  and NOTIFY to the kernel (wakes sleeps / NOTIFY_WAIT). Non-catching → DESTROY.
- tty reads console input only while a reader waits (no early echo of type-ahead);
  Ctrl-C is echoed by tty; the shell does not print another "^C".
- sh: `kill %J` added; `-c N` pins to core N (SPAWN mode bit1 | core << 8).
- test-as.sh: the expanded kernel source (282 KB) is over the 256 KiB OS-mode input:
  skipped in os mode (bare mode still compares it).

## Status
- [x] mkdisk (128-entry dir, far image), boot ROM (c12 far, c13 heap, c14 FB), fw names
- [x] fs: tags instead of directories. The 128-entry directory is unchanged (the kernel
  reads it at boot); a tag table follows it (header offset 52: 64 names of 16 bytes,
  then a u64 tag set per entry). Names in requests are paths (`/tag/tag/name`); DIR
  takes a tag path (intersection); TAG 12, UNTAG 13, TAGS 14; `mkdisk -t`; `ls [-t]
  [PATH]`, `tag`/`untag` (one image), `tags`. A rewrite keeps the file's entry and tags.
- [x] kernel resident + units: boot, CREATE/DESTROY/MEMORY/STATS/NOTIFY/FREE/HALT,
      exits, ticks, self-paging (k_trap; never evicts the missing slot itself)
- [x] dispatcher: run queue, switches (data extent + stack, code from image/mirror),
      demux, doorbells, svc 1..10, timeouts, kills, notifications, threads + emulation
- [x] servers proc/dev/fs/tty/pipe; sys.s, srv.s; sh + utilities (sub-agent, then fixed)
- [x] all examples run as programs (-n 2 mandel/parsum/pipeline/race, others 1 thread)
- [x] demo.txt runs end to end on the emulator (8 and 12 cores) and the RTL
- [x] tools: compare-boot.sh (console normalised + boot-ROM traces), test-break.sh,
      test-preempt.sh (new, in `make test`), test-as.sh StrataOS part
- [x] full `make test` green after the thread rework, JIT fixes and sched (SET_SCRATCH added after: emulator demo, preempt, boot-jit, test-as re-run green)
- [ ] README (not owned) still describes the old shell-in-kernel OS — report to coordinator

## Time slice (spec 2.1/2.4 update)
- Default 2 ms (SLICE0), kernel op 5 TUNE (length = slice ticks, 100..100000, proc
  only; NOTIFY moved to kernel op 9), proc op 30 SCHED (handle 0 read: slice,
  switches/s, KiB/s since the last read; handle 1 set: length = slice → TUNE), proc
  CORES moved to op 31, sys_sched wrapper, `sched` program (`sched`, `sched 500us`,
  `sched 5ms`, `sched 2000`); rc can run it. A core with one runnable process is never
  stopped by the slice; the gift-poll stop (a thread waiting in an emulated ctake on a
  busy core) happens at most every 10 ms, independent of the slice.
- compare-boot normalises the `sched` rates line (timing).

## SET_SCRATCH (requested for ws; spec 2.2 to be updated by the coordinator)
- svc 11 SET_SCRATCH (a1 = D-LS start, a2 = length; 0 clears): one range per thread,
  rounded inward to whole words, left out of the saved/restored data extent (contents
  undefined after a switch-in). sys.s: sys_scratch(start, len).

## Fixed bugs worth remembering
- `cat wc.s` faulted (bounds): sys_put added a zero terminator after a full 4032-byte
  message, so a 4040-byte transfer ran past the 4 KiB buffer. Fixed in sys.s; demo.txt
  has `cat wc.s | wc` (a 70 KB file) as a regression line.

- JIT interleavings (strata-emu default -T real, up to 8192 steps per core turn):
  (1) w_ring reused c8 while wpl_bounce held the capability to give back in c8:
  w_ring now works through c9 (the KST helpers restore c9 on use), and w_place
  calls w_jobs (no capability use) instead of w_cmds (which may run w_exit → crs8).
  (2) a request whose owner was killed while a server worked on it made the
  server fault (its tput hit a dead capability) and die: srv.s `srv_guard`
  installs a user trap handler that drops the request and returns to the loop.
  tools/test-boot-jit.sh (in `make test`) runs the demo 3× with -J -T real.

## Known limitations / open
- c8..c15 lost on a switch; non-memory sibling gifts with overlapping windows go to
  the first matching process; queue (11 entries/core) overflow drops capabilities.
- Requests beyond 8 queued per server core are bounced with -1.
- POLL is not implemented (spec says it is not an operation); ws/term are later work.

## Requests for the shell agent (os/progs/sh.s is theirs now)
- Keep: CATCH 1 at start; SETFG(job) while a foreground job runs, SETFG(own pid) after;
  on WAIT -2 SIGNAL the job; a login shell (-l) runs `rc`, and at end of console input
  calls sys_halt (otherwise proc would restart it forever on a closed input).
- The tty echoes "^C" itself: the shell need not print it for a killed job.
- `kill %J` (kills every stage of job J) and `-c N` (pin, SPAWN mode bit1 | N << 8)
  are used by os/demo.txt and tools/test-preempt.sh; `run` prefix and `-n N` too.
- tools/test-as.sh greps for the prompt `strata$ ` and `$ cat hello` in the session.
- Raw mode: CONMODE 1 makes tty READ return whatever bytes are there (no echo); input is
  read from the console only while a READ is waiting.

## Requests from the shell agent
- Please add `BUILD=$(BUILD) NCORES=$(NCORES) ./tools/test-sh.sh $(BUILD)/bootrom.stx
  $(BUILD)/disk.img` to `make test` (next to test-break.sh). It runs in ~5 s (emulator
  only, -j -T virtual) and compares with tools/test-sh.out (`tools/test-sh.sh -u ...`
  regenerates it). It only depends on the examples, `upper`, `wc`, `seq`, `grep`, `cat`,
  `rm`, `spin` and `sh`; it creates its own files.
- os/demo.txt, compare-boot.sh, test-break.sh, test-preempt.sh and the StrataOS part of
  test-as.sh pass unchanged with the new shell. Visible differences in the demo: the
  help text, and job reports show the command without its `&` ("[1] done  spin 12 a > sa").
- The motd's `spin 20 a & spin 20 b &` now works as written (`&` may appear anywhere in
  a list). The help text lists `sched` among the programs.
- The shell switches the console to raw (CONMODE 1) only while it reads a line, and
  back to cooked before running anything; a shell killed while reading leaves the tty
  raw (proc could reset CONMODE 0 when it restarts `sh -l`, if you want that).


## Requests from the ws agent — all done (takeover agent)
(ws = the window server, os/ws/ws.s; clients os/progs/{term,wmandel,wclock}.s.)
- [x] **R1: `ws` is its core's server.** proc SPAWN: a program whose name is exactly `ws`
  is created with KF_SERVER: the kernel places it on the lowest EMPTY core (-5 "no free
  core" if there is none: with 8 cores, 6 and 7 are the candidates) and its RECEIVE gets
  the requests sent to that core. It stays an ordinary child (WAIT, `kill`, Ctrl-C work;
  `ps` shows "ws (server)"). When it ends (exit, kill, fault) the kernel clears the
  core's server slot, its registry name goes (LOOKUP "ws" -> -4), and `ws` can be run
  again. Other processes then time-share ws's core like any server core (3 threads per
  core in all, ws included).
  REGISTER is now checked (spec 2.4): -5 unless the caller was started as a server (boot
  servers, `ws`); -7 if another live process holds the name.
  Requests still QUEUED or PARKED at a server when it ends now go back to their senders
  with result -1 (they used to be dropped, leaving the clients waiting for ever): a
  client blocked in a ws call sees -1 when ws quits or is killed. (A request the server
  holds in c6 at that moment is not answered: reply before exiting.)
- [x] **R2: GRANT_FB again after ws ends.** No RETURN_FB op (dev op 27 does not exist: ws
  may drop that call; an unknown op answers -1). The API is unchanged: dev op 26, the
  memory arrives in c6 and the controller ports 0x4000..0x400F in c7 (sys.s:
  sys_grantfb()). What changed: dev asks proc who is registered as "ws" (proc op 39
  WHOIS) and answers -5 to anyone else; the kernel keeps the framebuffer in a revocation
  domain of its own and lends it (kernel op 10 FBLEND, dev only) to that pid; when the
  holder ends, however it ends, the kernel revokes it, so every capability cut from it
  dies and the next `ws` gets a fresh one. -7 while a live process holds it.
- [x] **R3: svc 12 SEND = send with attachment.** a1 = endpoint register (1..7), a5 =
  attachment register (0..7, -1 none), a2..a4 as WAIT_REPLY. The dispatcher sends the
  attachment and then c5 through the endpoint, rings the doorbell and waits like
  WAIT_REPLY; -1 (nothing sent) if a register is empty or not a send endpoint.
  sys.s: **sys_msga(ep reg, op, handle, length, mode, attachment reg)** -> result, the
  same as sys_msg plus the attachment (the server gets it in c7; what it sends back
  arrives in the caller's c6). Use it instead of `csend cX, cWs` + sys_msg/ws_call
  (os/lib/wsclient.s should switch; the old two-csend way still works but keeps the hole:
  my test saw wrong and lost attachments with it, none in 900 calls with SEND).
  Two bugs found on the way, both fixed, both hit a client on the SAME core as ws:
  (1) sys_lookup left a copy of the endpoint in c6 when asked to put it elsewhere;
  (2) a capability arriving for a process that is switched out was dropped if its
  register held anything (now, as for a running process, only a live linear capability
  blocks it). Before these, a reply's attachment (the band coming back) was lost
  whenever client and server shared a core.
- [x] (FYI) SET_SCRATCH (svc 11) is used by ws for its strip buffers and scene: thanks.
- Notes for ws: (a) a linear capability left in c6 when a call is made makes the reply's
  attachment unreceivable (dropped): keep c6 free. (b) `halt` waits for pending device
  reads: if ws (through tty) is waiting for a console key when a shell in a term runs
  `halt`, the machine stops completely only at the next key (or end of input). (c) the
  dispatcher sends up to 2 capabilities per SEND and up to 4 per REPLY into inboxes that
  hold 2 per sender: it waits for the receiver to drain (the receiver is rung first).

## Halt (ISA rule F3: `halt` drains pending device reads) — done
- tty arms the break read again only after a real Ctrl-C (it reads 3), not after a
  release (0); it tracks whether the read is in flight (brkarm) for its RECEIVE mask.
- Kernel HALT (u_halt): sets G_HALT, wakes every worker; each dispatcher counts itself
  in (KST G_HALTED) in w_halt before its `halt`; core 0 waits (bounded) for all of them,
  so that no process can start another read, then writes the console release port
  (0x18: completes every break read) and timer DEADLINE 0 (its own WAIT), and halts.
- Console input cannot be cancelled: tty only has an input read in flight while a
  reader waits; if one does at `halt` (a background reader, ws), that core halts at
  the next key / end of input. Known limitation (needs an ISA way to cancel).
- compare-boot.sh and test-boot-jit.sh now also require exit status 0 (emulator and RTL).

## Takeover notes (what was half-done)
- GRANT_FB (WHOIS, FBLEND, revocation at exit, sys_grantfb) was complete in the
  sources and tested by the previous agent in build-fb/; only the notes were missing.
- tools/test-sh.sh is in `make test` (after test-break.sh).
- proc resets the console to cooked (CONMODE 0) when it restarts the login shell.
- Shell wrap-up: see os/progs/PLAN-sh.md (nothing open).
- Needs at least 6 cores (core 0 + proc, dev, fs, tty, pipe; the shell shares a server
  core): with fewer the boot stops with "cannot start proc/dev/fs" (not new).

## Test status after the takeover (emulator unless noted)
- demo.txt: exit 0 with -c 8 / -c 12, JIT (default) and -j, -T virtual; 6 cores too.
- test-break (emulator + RTL), test-preempt, test-boot-jit, test-sh, test-as: OK.
- compare-boot (emulator vs RTL, with the new exit-status checks): OK.
- R1-R3: a scratch `ws` (REGISTER, GRANT_FB, echo of an attached arena, PARK) and client:
  900 SEND calls from 3 clients (2 on ws's core) without a wrong attachment; -1 for a
  parked call when ws quits; ws run again after quit and after kill gets the framebuffer
  again; clients killed in mid-call do no harm. (Scratch programs deleted.)
