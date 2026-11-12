#!/bin/sh
# Guests: a second OS on whole cores beside StrataOS (doc/strataos.md, "Guests").
# Boots StrataOS, runs a benign guest (gdemo) and a hostile one (ghostile) on 2
# cores each, and checks:
#   * the benign guest's console I/O reaches the terminal (its banner), it shows
#     in `cores` as a guest, and `guest stop` returns its cores to StrataOS;
#   * the hostile guest's out-of-grant attacks are all refused ("isolation
#     holds"), and the block-device attack leaves fs healthy;
#   * after `guest stop` (a core-control reset of each guest core) the cores
#     come back clean: StrataOS runs a program on each of them;
#   * StrataOS keeps running throughout (a program on the other cores), and is
#     still healthy after each guest is stopped (ps, and a file read from fs);
#   * the bare-metal Forth as a guest (`guest forth`, lang/forth/guest/): the
#     console is attached to it, so typed lines go to Forth and the shell waits;
#     it computes, runs a word on its worker core (SPAWN / AWAIT) and the
#     multicore demo (lang/forth/demos/multicore.fs: slices of its far heap
#     change hands between its own cores); Ctrl-] gives the console back to the
#     shell (which sees the guest's cores), `guest attach` returns to Forth,
#     BYE closes the console, and `guest stop` returns the cores, which then
#     run StrataOS programs.
# Needs at least 8 cores (StrataOS wants 6 for itself; the guest gets 2 more).
#
#   tools/test-guest.sh build/bootrom.stx build/disk.img
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
n=${NCORES:-8}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0

run() { # $1 = script, $2 = out
  cp "$2script" "$tmp/in.txt" 2>/dev/null || printf '%s' "$1" >"$tmp/in.txt"
  "$b/strata-emu" -c "$n" -T virtual -g none -m 2000000000 -d "$3" -i "$tmp/in.txt" "$4" >"$5" 2>/dev/null
}

# ---- benign guest: console, visibility, stop/reclaim ------------------------
cp "$2" "$tmp/d1.img"
printf 'guest -d gdemo 2 8\ncores\nguest stop 240\ncores\ncat motd\nhalt\n' >"$tmp/in1.txt"
"$b/strata-emu" -c "$n" -T virtual -g none -m 2000000000 -d "$tmp/d1.img" -i "$tmp/in1.txt" "$1" >"$tmp/o1" 2>/dev/null
ban=$(grep -c 'second OS is live on its own cores' "$tmp/o1")
gflag=$(grep -c ', guest;' "$tmp/o1")          # a core shown as a guest's while it runs
stopped=$(grep -c '^guest stopped' "$tmp/o1")
reclaimed=$(awk '/guest stopped/{s=1} s&&/^core 6: idle.*guest/{bad=1} END{print bad+0}' "$tmp/o1")
motd=$(grep -c 'StrataOS' "$tmp/o1")           # fs still serves files after the guest
if [ "$ban" -ge 1 ] && [ "$gflag" -ge 1 ] && [ "$stopped" -ge 1 ] && [ "$reclaimed" = 0 ] && [ "$motd" -ge 1 ]; then
  printf '%-14s OK    benign guest: console reached the terminal, shown as a guest, stopped and cores reclaimed\n' guest
else
  printf '%-14s FAIL  benign guest (banner=%s flag=%s stopped=%s reclaimed-bad=%s fs=%s)\n' guest "$ban" "$gflag" "$stopped" "$reclaimed" "$motd"
  grep -iE 'guest|core 6|fault' "$tmp/o1" | head -8 | sed 's/^/    /'
  rc=1
fi

# ---- hostile guest: every out-of-grant attack refused, StrataOS unharmed -----
cp "$2" "$tmp/d2.img"
printf 'guest -d ghostile 2 8\nps\nguest stop 240\nps\n-c 6 hello\n-c 7 hello\ncat motd\nhalt\n' >"$tmp/in2.txt"
"$b/strata-emu" -c "$n" -T virtual -g none -m 2000000000 -d "$tmp/d2.img" -i "$tmp/in2.txt" "$1" >"$tmp/o2" 2>/dev/null
holds=$(grep -c 'isolation holds' "$tmp/o2")
failed=$(grep -c 'ISOLATION FAILED' "$tmp/o2")
alive=$(grep -c 'proc (server)' "$tmp/o2")     # proc still answers ps while the hostile guest runs
fs_ok=$(grep -c 'StrataOS' "$tmp/o2")          # fs intact: the block-device attack was bounced
clean=$(grep -c '^Hello from Strata' "$tmp/o2")  # the reset cores run StrataOS programs again
if [ "$holds" -ge 1 ] && [ "$failed" = 0 ] && [ "$alive" -ge 1 ] && [ "$fs_ok" -ge 1 ] && [ "$clean" -ge 2 ]; then
  printf '%-14s OK    hostile guest: all 4 out-of-grant attacks refused, nothing of StrataOS left on its cores, fs healthy, its cores reset clean and reused\n' guest-isol
else
  printf '%-14s FAIL  hostile guest (holds=%s failed=%s proc=%s fs=%s clean=%s)\n' guest-isol "$holds" "$failed" "$alive" "$fs_ok" "$clean"
  grep -iE 'hostile|isolation|fault|deadlock' "$tmp/o2" | head -8 | sed 's/^/    /'
  rc=1
fi

# ---- the bare-metal Forth as a guest ----------------------------------------
cp "$2" "$tmp/d3.img"
{
  printf 'guest forth 2 16\n2 3 + .\n'
  printf ": sq ( n -- n*n ) dup * ;  7 1 ' sq 1 spawn  1 await .\n"
  cat "$here/lang/forth/demos/multicore.fs"
  printf '50 ms cores .\n\035cores\nguest attach 240\n3 4 * .\nbye\n'
  printf 'guest stop 240\ncores\n-c 6 hello\n-c 7 hello\ncat motd\nhalt\n'
} >"$tmp/in3.txt"
"$b/strata-emu" -c "$n" -T virtual -g none -m 4000000000 -d "$tmp/d3.img" -i "$tmp/in3.txt" "$1" >"$tmp/o3" 2>/dev/null
ban=$(grep -c '^Strata Forth 0.1 (native code, 2 cores, a StrataOS guest' "$tmp/o3")
five=$(grep -c '^5  ok' "$tmp/o3")                 # 2 3 + . (the shell would say "no such program")
sq=$(grep -c '^49  ok' "$tmp/o3")                  # on the worker core
sum=$(grep -c '^sum = 8386560 expected 8386560' "$tmp/o3")  # multicore.fs, one worker
ncore=$(grep -c '^2  ok' "$tmp/o3")                # cores . after 50 ms
det=$(grep -c '^guest 240 detached' "$tmp/o3")
gcores=$(grep -c '^core [67]: .*guest;' "$tmp/o3") # the shell's `cores` while it runs
back=$(grep -c '^12  ok' "$tmp/o3")                # after guest attach
closed=$(grep -c '^guest 240 closed the console' "$tmp/o3")
stopped=$(grep -c '^guest stopped' "$tmp/o3")
freed=$(awk '/^guest stopped/{s=1} s&&/^core [67]: idle, 0 runnable, 0 processes;/{n++} END{print n+0}' "$tmp/o3")
clean=$(grep -c '^Hello from Strata' "$tmp/o3")
motd=$(grep -c 'StrataOS' "$tmp/o3")
if [ "$ban" = 1 ] && [ "$five" = 1 ] && [ "$sq" = 1 ] && [ "$sum" = 1 ] && [ "$ncore" = 1 ] && [ "$det" = 1 ] && \
   [ "$gcores" = 2 ] && [ "$back" = 1 ] && [ "$closed" = 1 ] && [ "$stopped" = 1 ] && [ "$freed" = 2 ] && \
   [ "$clean" -ge 2 ] && [ "$motd" -ge 1 ]; then
  printf '%-14s OK    Forth as a guest: the console attached, a word on its worker, multicore.fs, Ctrl-], attach, bye, stop, cores back\n' guest-forth
else
  printf '%-14s FAIL  Forth guest (banner=%s 5=%s spawn=%s sum=%s cores=%s detached=%s guestcores=%s attach=%s closed=%s stopped=%s freed=%s clean=%s fs=%s)\n' \
    guest-forth "$ban" "$five" "$sq" "$sum" "$ncore" "$det" "$gcores" "$back" "$closed" "$stopped" "$freed" "$clean" "$motd"
  grep -iE "guest|sum =|fault|\*\*\*" "$tmp/o3" | head -20 | sed 's/^/    /'
  rc=1
fi

exit $rc
