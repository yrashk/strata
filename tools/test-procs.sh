#!/bin/sh
# Many processes at once: the process limit is memory now, not the 15
# revocation domains of old (14 processes at most, one domain per arena).
# Boots StrataOS on the emulator with 15 cores and, twice in a row:
#   * starts 4 background shells, each running a script that starts 6
#     sleeping shells (`sh -c "sleep 30" &`), kills them after 3 s and waits;
#   * shows the peak in `ps` and `free` while they all live (34 processes:
#     the 5 servers, the login shell, 4 + 24 shells and ps itself);
#   * waits until they are gone and checks that every arena came back
#     (`free` as before, only the servers and the login shell in `ps`).
# Every arena is revoked by address when its process ends, then reused by
# the next round. Also: `-m 8 free` runs with an 8 MiB arena.
# The emulator runs the interpreter with the virtual timer (deterministic).
#
#   tools/test-procs.sh build/bootrom.stx build/disk.img     (-v: show the output)
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
verbose=0
if [ "${1:-}" = "-v" ]; then verbose=1; shift; fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
{
  for i in 1 2 3 4 5 6; do printf "echo 'sh -c \"sleep 30\" &' >> w\n"; done
  printf "echo 'sleep 3' >> w\n"
  for i in 1 2 3 4 5 6; do printf "echo 'kill %%%s' >> w\n" "$i"; done
  printf "echo 'wait' >> w\n"
  printf 'free\n-m 8 free\n'
  for r in 1 2; do
    printf 'sh w &\nsh w &\nsh w &\nsh w &\nsleep 2\nps\nfree\nwait\nps\nfree\n'
  done
  printf 'halt\n'
} >"$tmp/in.txt"
cp "$2" "$tmp/d.img"
"$b/strata-emu" -c 15 -j -T virtual -g none -m 6000000000 -d "$tmp/d.img" -i "$tmp/in.txt" "$1" >"$tmp/out" 2>&1
[ "$verbose" = 1 ] && cat "$tmp/out"
# the rows of each `ps` (a line starting with a pid after a PID header), and each `free`
awk '/^  PID  PPID/ { if (n) print n; n = 0; inps = 1; next }
     inps && /^ +[0-9]+ +[0-9]+ / { n++; next }
     { if (inps && n) { print n; n = 0 } inps = 0 }' "$tmp/out" >"$tmp/ps"
grep '^free: ' "$tmp/out" | awk '{ print $2 }' >"$tmp/free"
p1=$(sed -n 1p "$tmp/ps"); p2=$(sed -n 2p "$tmp/ps"); p3=$(sed -n 3p "$tmp/ps"); p4=$(sed -n 4p "$tmp/ps")
f0=$(sed -n 1p "$tmp/free"); fm=$(sed -n 2p "$tmp/free"); fp1=$(sed -n 3p "$tmp/free")
f1=$(sed -n 4p "$tmp/free"); fp2=$(sed -n 5p "$tmp/free"); f2=$(sed -n 6p "$tmp/free")
bad=$(grep -c -E 'fault|no free core|no memory|cannot|syntax error' "$tmp/out")
halted=$(grep -c 'StrataOS: all cores halted' "$tmp/out")
ok=1
[ -n "$p1" ] && [ "$p1" -ge 30 ] || ok=0            # the peak: far more than 14
[ "${p3:-x}" = "$p1" ] || ok=0                       # the same in the second round
[ "${p2:-x}" = 7 ] && [ "${p4:-x}" = 7 ] || ok=0     # then the servers, sh and ps only
[ -n "$f0" ] && [ "${f1:-x}" = "$f0" ] && [ "${f2:-x}" = "$f0" ] || ok=0 # every arena back
[ -n "$fm" ] && [ "$fm" = $((f0 - 7 * 1024)) ] || ok=0 # -m 8: 7 MiB more than free's own 1 MiB
[ "${fp1:-x}" = "${fp2:-y}" ] && [ "$fp1" -lt "$f0" ] || ok=0
[ "$bad" = 0 ] && [ "$halted" = 1 ] || ok=0
if [ "$ok" = 1 ]; then
  printf '%-14s OK    %s processes at once, twice; free %s KiB at the peak, %s KiB before and after; -m 8\n' \
    procs "$p1" "$fp1" "$f0"
  exit 0
fi
printf '%-14s FAIL  (ps rows: %s %s %s %s; free: %s %s %s %s %s %s; errors: %s; halted: %s)\n' procs \
  "$p1" "$p2" "$p3" "$p4" "$f0" "$fm" "$fp1" "$f1" "$fp2" "$f2" "$bad" "$halted"
sed 's/^/    /' "$tmp/out" | tail -40
exit 1
