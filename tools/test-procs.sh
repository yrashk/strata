#!/bin/sh
# Many processes at once, on many cores and on few. The process limit is
# memory and the cores' capability save tables, not the 15 revocation domains
# of old (14 processes at most, one domain per arena) nor the 3 threads per
# core the save table's fixed split allowed.
#
# Part 1, 15 cores, twice in a row:
#   * starts 4 background shells, each running a script that starts 6
#     sleeping shells (`sh -c "sleep 30" &`), kills them after 3 s and waits;
#   * shows the peak in `ps` and `free` while they all live (34 processes:
#     the 5 servers, the login shell, 4 + 24 shells and ps itself);
#   * waits until they are gone and checks that every arena came back
#     (`free` as before, only the servers and the login shell in `ps`).
#   Every arena is revoked by address when its process ends, then reused by
#   the next round. Also: `-m 8 free` runs with an 8 MiB arena.
# Part 2, 6 cores (the fewest StrataOS runs on: core 0 and the 5 server
# cores, so every process shares a core with a server), the same rounds:
#   * the peak in `ps`: 35 processes, as on 15 cores (proc and tty are alone
#     on their cores, the three others hold 11 threads each); while they
#     live, a pipeline (`seq 30 | grep 2 | wc`) runs among them;
#   * `cores` before, at the peak and after each round: after a round every
#     core's free save-table slots are back where they were before it;
#   * then `spin`, stopped by Ctrl-C (-b), and another pipeline.
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
script() { # the script w: 6 sleeping shells, killed after 3 s
  for i in 1 2 3 4 5 6; do printf "echo 'sh -c \"sleep 30\" &' >> w\n"; done
  printf "echo 'sleep 3' >> w\n"
  for i in 1 2 3 4 5 6; do printf "echo 'kill %%%s' >> w\n" "$i"; done
  printf "echo 'wait' >> w\n"
}
{
  script
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
psrows() {
  awk '/^  PID  PPID/ { if (n) print n; n = 0; inps = 1; next }
       inps && /^ +[0-9]+ +[0-9]+ / { n++; next }
       { if (inps && n) { print n; n = 0 } inps = 0 }' "$1"
}
psrows "$tmp/out" >"$tmp/ps"
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
else
  printf '%-14s FAIL  (ps rows: %s %s %s %s; free: %s %s %s %s %s %s; errors: %s; halted: %s)\n' procs \
    "$p1" "$p2" "$p3" "$p4" "$f0" "$fm" "$fp1" "$f1" "$fp2" "$f2" "$bad" "$halted"
  sed 's/^/    /' "$tmp/out" | tail -40
  exit 1
fi

# ---- part 2: 6 cores ----
{
  script
  printf 'cores\n'
  for r in 1 2; do
    printf 'sh w &\nsh w &\nsh w &\nsh w &\nsleep 2\nps\ncores\nseq 30 | grep 2 | wc\nwait\nps\ncores\n'
  done
  printf 'spin\nseq 3 | wc\nhalt\n'
} >"$tmp/in2.txt"
cp "$2" "$tmp/d2.img"
"$b/strata-emu" -c 6 -j -T virtual -g none -m 5000000000 -b "${PROCS_BREAK:-3000000000}" \
  -d "$tmp/d2.img" -i "$tmp/in2.txt" "$1" >"$tmp/out2" 2>&1
[ "$verbose" = 1 ] && cat "$tmp/out2"
psrows "$tmp/out2" >"$tmp/ps2"
# each `cores`: the free slots of cores 1..5, on one line
awk '/^core 1:/ { l = "" } /^core [1-9][0-9]*:/ { sub(/ slots free$/, ""); n = split($0, w, " "); l = l " " w[n] }
     /^core 5:/ { print l }' "$tmp/out2" >"$tmp/slots"
q1=$(sed -n 1p "$tmp/ps2"); q2=$(sed -n 2p "$tmp/ps2"); q3=$(sed -n 3p "$tmp/ps2"); q4=$(sed -n 4p "$tmp/ps2")
s0=$(sed -n 1p "$tmp/slots"); sp1=$(sed -n 2p "$tmp/slots"); s1=$(sed -n 3p "$tmp/slots")
sp2=$(sed -n 4p "$tmp/slots"); s2=$(sed -n 5p "$tmp/slots")
pipes=$(grep -c '^12 12 35$' "$tmp/out2")
bad=$(grep -c -E 'fault|no free core|no memory|cannot|syntax error' "$tmp/out2")
halted=$(grep -c 'StrataOS: all cores halted' "$tmp/out2")
ok=1
[ -n "$q1" ] && [ "$q1" -ge 30 ] && [ "${q3:-x}" = "$q1" ] || ok=0 # the peak, twice
[ "${q2:-x}" = 7 ] && [ "${q4:-x}" = 7 ] || ok=0     # then the servers, sh and ps only
[ -n "$s0" ] && [ "${s1:-x}" = "$s0" ] && [ "${s2:-x}" = "$s0" ] || ok=0 # every slot back
[ -n "$sp1" ] && [ "$sp1" != "$s0" ] || ok=0         # (and they were in use at the peak)
[ "$pipes" = 2 ] || ok=0                             # the pipeline, at both peaks
grep -q '\^C$' "$tmp/out2" && grep -q '^3 3 6$' "$tmp/out2" || ok=0           # Ctrl-C, then the shell goes on
[ "$bad" = 0 ] && [ "$halted" = 1 ] || ok=0
if [ "$ok" = 1 ]; then
  printf '%-14s OK    6 cores: %s processes at once, twice, a pipeline among them; free slots of cores 1-5:%s, at the peak%s; Ctrl-C\n' \
    procs-6 "$q1" "$s0" "$sp1"
  exit 0
fi
printf '%-14s FAIL  (ps rows: %s %s %s %s; slots: [%s] [%s] [%s] [%s] [%s]; pipelines: %s; errors: %s; halted: %s)\n' procs-6 \
  "$q1" "$q2" "$q3" "$q4" "$s0" "$sp1" "$s1" "$sp2" "$s2" "$pipes" "$bad" "$halted"
sed 's/^/    /' "$tmp/out2" | tail -60
exit 1
