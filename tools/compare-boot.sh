#!/bin/sh
# Boots StrataOS on the C emulator and on the Verilated RTL with the same
# disk image and the same scripted console input, and compares them.
#
#   tools/compare-boot.sh build/bootrom.stx build/disk.img os/demo.txt [NAME]
#
# (NAME labels the result line; os/guest-demo.txt is the guest session: a
# second OS started, stopped by core-control resets, a hostile one, the
# reset cores reused, and the bare-metal Forth as a guest with the console.)
#
# EMU_ARGS: extra emulator flags that describe the same machine as the RTL
# build (e.g. -X 8 for an RTL built with NXMAP=8).
#
# Both machines run with the virtual timer (-T virtual: NOW = emulator rounds
# / 100, RTL cycles / 100) and no window (-g none).
#
# What is compared, and why not more:
#   * Console output, with the lines that report timing normalised. StrataOS
#     0.1 preempts time-shared processes every time slice of timer time and wakes
#     timed waits from the timer, and the two machines' clocks advance at
#     different rates per instruction (the emulator counts rounds of one step
#     per core; the RTL counts cycles, including stalls). So the moments at
#     which processes are switched differ, and with them the numbers `ps`,
#     `cores` and `uptime` print (switches, KiB moved, who is running) and
#     the per-core instruction streams. Everything the programs compute and
#     print must still be identical.
#   * Per-core instruction traces of the deterministic part: the boot ROM,
#     up to each core's jump into the kernel (first instruction at 0x4000).
#     After that, event order depends on the clock (see above), so exact
#     traces cannot match; the examples (tools/compare.sh) still compare
#     every instruction of every core.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
n=${NCORES:-8}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$2" "$tmp/d1.img"; cp "$2" "$tmp/d2.img"
# the traces are long: keep, through a pipe, each core's boot-ROM part (every
# line before its first instruction at 0x4000) and count the rest
mkfifo "$tmp/e.fifo" "$tmp/r.fifo"
split_trace() { # $1 = fifo, $2 = output prefix
  awk -v p="$2" '{ if (!done[$1]) { if ($2 == "00004000") done[$1] = 1; else print > (p "." $1) } }
                 END { print NR > (p ".count") }' "$1"
}
split_trace "$tmp/e.fifo" "$tmp/e" & pe=$!
split_trace "$tmp/r.fifo" "$tmp/r" & pr=$!
"$b/strata-emu" -j -c "$n" ${EMU_ARGS:-} -T virtual -g none -m 4000000000 -d "$tmp/d1.img" -i "$3" -t "$tmp/e.fifo" "$1" >"$tmp/e.out" 2>"$tmp/e.err"
erc=$?
"$b/strata-rtl" -T virtual -g none -m 4000000000 -d "$tmp/d2.img" -i "$3" -t "$tmp/r.fifo" "$1" >"$tmp/r.out" 2>"$tmp/r.err"
rrc=$?
wait $pe $pr
# normalise what depends on timing: ps rows keep pid, parent, core, cores and
# name; cores lines keep processes and flags (not switches, KiB, cycles, free slots); uptime keeps nothing but itself;
# sched keeps the slice, not the rates
norm() {
  sed -E -e 's/^( +[0-9]+ +[0-9]+) +(running|ready|blocked|zombie) +([0-9]+ +[0-9]+) +[0-9]+ +[0-9]+ +(.*)$/\1 \3 \4/' \
         -e 's/^(core [0-9]+): (running [0-9]+|idle), [0-9]+ runnable,(.*); [0-9]+ switches, [0-9]+ KiB moved, [0-9]+ cycles\/switch, [0-9]+ cycles\/trap, [0-9]+ slots free$/\1:\3/' \
         -e 's/^up [0-9.]+ s, .*$/up .../' \
         -e 's/^(time slice: [0-9]+ us); .*$/\1/' "$1"
}
ok=1
norm "$tmp/e.out" >"$tmp/e.norm"; norm "$tmp/r.out" >"$tmp/r.norm"
cmp -s "$tmp/e.norm" "$tmp/r.norm" || { echo "  console output differs:"; diff "$tmp/e.norm" "$tmp/r.norm" | head; ok=0; }
grep -q 'StrataOS: all cores halted' "$tmp/e.out" || { echo "  the session did not end with halt"; ok=0; }
# every core must really halt: `halt` waits for a core's pending device reads
# (a read left in flight is a deadlock on the emulator, a timeout on the RTL)
[ $erc -eq 0 ] || { echo "  the emulator ended with status $erc:"; tail -2 "$tmp/e.err" | sed 's/^/    /'; ok=0; }
[ $rrc -eq 0 ] || { echo "  the RTL ended with status $rrc:"; tail -2 "$tmp/r.err" | sed 's/^/    /'; ok=0; }
c=0
while [ $c -lt "$n" ]; do
  touch "$tmp/e.$c" "$tmp/r.$c"
  cmp -s "$tmp/e.$c" "$tmp/r.$c" || { echo "  core $c boot trace differs"; ok=0; }
  c=$((c + 1))
done
ins=$(cat "$tmp/e.count")
cyc=$(sed -n 's/^total cycles: //p' "$tmp/r.err")
if [ $ok -eq 1 ]; then printf '%-14s OK    %8s instructions  %9s RTL cycles (console compared; boot traces)\n' "${4:-boot}" "$ins" "$cyc"; exit 0; fi
printf '%-14s FAIL\n' "${4:-boot}"; exit 1
