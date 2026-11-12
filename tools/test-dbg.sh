#!/bin/sh
# The debuggers: strata-dbg driving strata-emu's debug engine (--debug
# stdio) with scripts, on bare-metal examples and on StrataOS, and the same
# engine in the WebAssembly build (tools/wasm-dbg.js) when node and the
# build are there. Every run is deterministic (-j -T virtual), so the stops
# land on the same ticks every time; the checks look for what each stop must
# show, not for tick numbers.
#   1. hello: break at a label (print_str), source lines, the stall of a
#      core waiting in ctake, a backtrace;
#   2. pipeline: stepi on two cores; a watchpoint on core 1's D-LS buffer
#      fired by the tget that fills it; reverse-stepi back in front of that
#      tget; the provenance of the capability core 1 took from core 0
#      (split on core 0, given, taken);
#   3. clock: info tags while a timer WAIT (a tget) is in flight, and a
#      watchpoint on its destination fired by its completion; reverse-tag
#      back to its issue (in front of the tget: its tag has no transfer yet);
#   4. StrataOS: break when the process `ls` runs, info processes; a guest
#      OS (its cores in info cores and processes) and a break on the reset
#      `guest stop` makes;
#   5. the wasm engine: a breakpoint and a reverse step;
#   6. fast continues (ff, with the JIT): hello to its end, StrataOS to the
#      process ls, and the history starting again there.
#
#   tools/test-dbg.sh            (-v: show the transcripts)
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
verbose=0
if [ "${1:-}" = "-v" ]; then verbose=1; shift; fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

# run NAME SCRIPT ARGS...: strata-dbg with SCRIPT as its stdin; the transcript in $tmp/NAME.out
run() {
  name=$1 script=$2
  shift 2
  "$b/strata-dbg" "$@" < "$script" > "$tmp/$name.out" 2>&1
  [ $verbose = 1 ] && { echo "==== $name"; cat "$tmp/$name.out"; }
}
# expect NAME TEXT...: each TEXT (a fixed string) appears in the transcript, in order
expect() {
  name=$1
  shift
  rest="$tmp/$name.out"
  cp "$rest" "$tmp/rest"
  for t in "$@"; do
    n=$(grep -nF -- "$t" "$tmp/rest" | head -1 | cut -d: -f1)
    if [ -z "$n" ]; then
      echo "test-dbg: $name: expected \"$t\""
      fail=1
      return
    fi
    tail -n +"$((n + 1))" "$tmp/rest" > "$tmp/rest2"
    mv "$tmp/rest2" "$tmp/rest"
  done
}

# ---- 1. hello: a breakpoint at a label
cat > "$tmp/hello.cmd" <<'EOF'
break print_str
continue
info cores
bt
list
continue
quit
EOF
run hello "$tmp/hello.cmd" -c 4 -j -T virtual "$b/examples/hello.stx"
expect hello \
  "Breakpoint 1: pc 0x5c (print_str examples/lib/print.s:34)" \
  "stopped: breakpoint 1" "core 0: 0x5c <print_str> (print.s:34)  tput  tg15, a0, c2, zero, a1" \
  "core 1  super 0x10 <_start+16> (hello.s:35)  ctake c3, t0" "waits for a capability from node 0" \
  "#0  0x5c <print_str> (print.s:34)" "#1  0x24 <speak+16> (hello.s:40)  via ra" \
  ">   34          tput  tg15, a0, c2, zero, a1" \
  "console| Hello from Strata core "

# ---- 2. pipeline: two cores, a watchpoint hit by a transfer, reverse, provenance
cat > "$tmp/pipe.cmd" <<'EOF'
stepi 3
info cores
core 1
stepi 2
info cores
watch dls buf 8 core 1
continue
info registers
info tags
reverse-stepi
info tags
prov c4
log 6
quit
EOF
run pipe "$tmp/pipe.cmd" -c 4 -j -T virtual "$b/examples/pipeline.stx"
expect pipe \
  "stopped: step" "core 0: 0xc <_start+12> (pipeline.s:56)  li    t1, 2" \
  "* core 0  super 0xc <_start+12>" "  core 1  super 0x8 <_start+8>" \
  "current core: 1" "stopped: step" "core 1: 0x10 <_start+16> (pipeline.s:57)" \
  "  core 0  super 0x10 <_start+16>" "* core 1  super 0x10 <_start+16>" \
  "Watchpoint 1: dls [0x0, 0x8) w on core 1" \
  "stopped: watchpoint 1: dls [0x0, 0x8) w on core 1, core 1 tget wrote [0x0, 0x1000)" \
  "core 1: 0xd0 <c_loop+8> (pipeline.s:117)" \
  "tg0  idle tget  t3 0x0  ls 0x0 len 4096" \
  "stopped: reverse step" "core 1: 0xcc <c_loop+4> (pipeline.s:116)  tget  tg0, s5, c4, zero, s6" \
  "core 1: no transfer yet on any tag" \
  "give t3 0x0+0x1000 rwx  by core 1 from node 0" \
  "split t3 0x0+0x1000 rwx  by core 0" \
  "reset t3 0x0+0x4000000 rwx  by core 0" \
  "core 0  xfer   tg0 tput t3 0x0" "core 0  give   -> node 1: t3 0x0+0x1000 rwx"

# ---- 3. clock: a tget in flight (the timer's WAIT), its completion, back to its issue
cat > "$tmp/clock.cmd" <<'EOF'
watch tag tg1 issue core 0
continue
info tags
info pending
delete
watch dls wbuf 8 core 0
continue
info tags
reverse-tag tg1
info tags
quit
EOF
run clock "$tmp/clock.cmd" -c 2 -j -T virtual "$b/examples/clock.stx"
expect clock \
  "Watchpoint 1: tg1 issue on core 0" \
  "stopped: watchpoint 1: tg1 issue on core 0, core 0 tg1 issued (pending)" \
  "tg1  BUSY tget  dev 0x3018" \
  "core 0 tg1: timer WAIT (port 0x3018) into D-LS 0x210+8, issued round 390, waits for the timer deadline" \
  "Watchpoint 2: dls" "stopped: watchpoint 2: dls [0x210, 0x218) w on core 0, core 0 device read wrote [0x210, 0x218)" \
  "tg1  idle tget  dev 0x3018" "completed round" \
  "stopped: reverse: tg1 issued" "core 0: 0x310 <arm+52> (clock.s:288)  tget  tg1, t2, c5, t3, t4" \
  "tg0  idle tget  dev 0x3000"

# ---- 4. StrataOS: break when `ls` runs; the processes
if [ -f "$b/disk.img" ] && [ -f "$b/kernel.map" ]; then
  cp "$b/disk.img" "$tmp/disk.img"
  cat > "$tmp/os.cmd" <<'EOF'
break process ls
input ls\n
continue
info processes
info cores
quit
EOF
  run os "$tmp/os.cmd" -c 8 -j -T virtual -g none -d "$tmp/disk.img" --os "$b" "$b/bootrom.stx"
  expect os \
    "Breakpoint 1: process ls runs (at its entry)" \
    "console| strata\$ " \
    "stopped: breakpoint 1: process ls runs (at its entry)" "<_start> (ls.s:" \
    "pid parent state  core n  running  name" "  proc" "  sh" "  ls" \
    "pid 8 ls"
  # a guest OS: its cores while it runs, then `guest stop`'s core-control resets
  cp "$b/disk.img" "$tmp/disk.img"
  cat > "$tmp/guest.cmd" <<'EOF'
break process cores
input guest gdemo 2 8\ncores\nguest stop 240\n
continue
info processes
info cores
delete 1
break reset
continue
info cores
quit
EOF
  run guest "$tmp/guest.cmd" -c 8 -j -T virtual -g none -d "$tmp/disk.img" --os "$b" "$b/bootrom.stx"
  expect guest \
    "console| guest: a second OS is live on its own cores, beside StrataOS." \
    "stopped: breakpoint 1: process cores runs" \
    "guest 240 on cores 6,7 (a second OS)" \
    "  guest 240  " "  guest 240  " \
    "stopped: breakpoint 2: a core is reset, core 6 reset by core 0" \
    "* core 6  super 0x0 <_start> (bootrom.s:" \
    "core 7  super"
else
  echo "test-dbg: no StrataOS build (make os): skipping part 4"
fi

# ---- 5. the WebAssembly build's engine
if command -v node >/dev/null 2>&1 && [ -f "$b/web/strata-emu.js" ]; then
  printf '%s\n' '{"cmd":"break","loc":"print_str"}' '{"cmd":"continue"}' '{"cmd":"reverse-stepi","core":0}' \
    > "$tmp/wasm.req"
  node "$here/tools/wasm-dbg.js" "$b/web/strata-emu.js" -c 4 -j -T virtual "$b/examples/hello.stx" \
    < "$tmp/wasm.req" > "$tmp/wasm.out" 2>&1
  [ $verbose = 1 ] && { echo "==== wasm"; cat "$tmp/wasm.out"; }
  expect wasm '"reason":"breakpoint 1: pc 0x5c (print_str examples/lib/print.s:34)"' \
    '"reason":"reverse step","core":0'
else
  echo "test-dbg: no node or no WebAssembly build (make wasm): skipping part 5"
fi

# ---- 6. fast continues: unrecorded (the JIT), the history starts again where they stop
printf 'ff\ninfo history\nquit\n' > "$tmp/ff.cmd"
run ff "$tmp/ff.cmd" -c 4 -J -T virtual "$b/examples/hello.stx"
expect ff "console| Hello from Strata core 3 of 4" \
  "the machine has stopped: halted (tick 100," "time travel: ticks 100..100, 1 snapshot(s)"
if [ -f "$b/disk.img" ] && [ -f "$b/kernel.map" ]; then
  cp "$b/disk.img" "$tmp/disk.img"
  printf 'break process ls\ninput ls\\n\nff\ninfo history\nstepi 20\nreverse-stepi 5\ninfo history\nquit\n' > "$tmp/osff.cmd"
  run osff "$tmp/osff.cmd" -c 8 -J -T virtual -g none -d "$tmp/disk.img" --os "$b" "$b/bootrom.stx"
  expect osff "stopped: breakpoint 1: process ls runs (at its entry)" "<_start> (ls.s:" \
    "recording starts again at the next round's start" "stopped: step" "stopped: reverse step" \
    "time travel: ticks "
fi

if [ $fail = 0 ]; then echo "test-dbg: ok"; else exit 1; fi
