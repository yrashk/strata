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
# cores, so every process shares a core with a server), with the default
# 256-slot capability save table, twice in a row:
#   * 4 shells running a script of 8 sleeping shells: the peak in `ps` is 43
#     processes (proc and tty are alone on their cores, the three others
#     hold 13 or 14 threads each; with a 64-slot table at most 11, and 3
#     before the save table was a pool); while they live, a pipeline (`seq 30
#     | grep 2 | wc`) runs among them;
#   * `cores` before, at the peak and after each round: after a round every
#     core's free save-table slots are back where they were before it;
#   * then `spin`, stopped by Ctrl-C (-b), and another pipeline.
# Part 3, 6 cores with a 64-slot save table (-S 64: 11 threads per core),
# twice: the rounds of part 1 (35 processes, the most that fit), the slots
# back after each round, and at the peak one more process than fits:
# `sh -c "sleep 1" &` takes the last place, the next one is refused ("no
# free core", CREATE's -5) and the machine goes on.
# The emulator runs the interpreter with the virtual timer (deterministic).
# The three machines run at the same time; their outputs are checked in order.
#
#   tools/test-procs.sh build/bootrom.stx build/disk.img     (-v: show the output)
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
verbose=0
if [ "${1:-}" = "-v" ]; then verbose=1; shift; fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
script() { # the script w: N (default 6) sleeping shells, killed after S (3) s
  n=${1:-6}; i=1
  while [ $i -le $n ]; do printf "echo 'sh -c \"sleep 30\" &' >> w\n"; i=$((i + 1)); done
  printf "echo 'sleep %s' >> w\n" "${2:-3}"
  i=1
  while [ $i -le $n ]; do printf "echo 'kill %%%s' >> w\n" "$i"; i=$((i + 1)); done
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
"$b/strata-emu" -c 15 -j -T virtual -g none -m 6000000000 -d "$tmp/d.img" -i "$tmp/in.txt" "$1" >"$tmp/out" 2>&1 &
image=$1 disk=$2
# ---- parts 2 and 3: 6 cores ----
# six NAME TABLE SLEEPERS SECONDS EXTRA BREAK: start the rounds
six() {
  name=$1 ctab=$2
  {
    script "$3" "$4"
    printf 'cores\n'
    for r in 1 2; do
      printf 'sh w &\nsh w &\nsh w &\nsh w &\nsleep 2\nps\ncores\n%bseq 30 | grep 2 | wc\nwait\nps\ncores\n' "$5"
    done
    printf 'spin\nseq 3 | wc\nhalt\n'
  } >"$tmp/in.$name"
  cp "$disk" "$tmp/d.$name"
  "$b/strata-emu" -c 6 -S "$ctab" -j -T virtual -g none -m 5000000000 -b "$6" \
    -d "$tmp/d.$name" -i "$tmp/in.$name" "$image" >"$tmp/out.$name" 2>&1 &
}
six procs-6 256 8 3 '' "${PROCS_BREAK:-3000000000}"
six procs-6s 64 6 5 'sh -c "sleep 1" &\nsh -c "sleep 1"\nsleep 4\n' "${PROCS_BREAK64:-3000000000}"
wait
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

# read NAME: what a run of six printed
read6() {
  name=$1
  [ "$verbose" = 1 ] && cat "$tmp/out.$name"
  psrows "$tmp/out.$name" >"$tmp/ps.$name"
  # each `cores`: the free slots of cores 1..5, on one line
  awk '/^core 1:/ { l = "" } /^core [1-9][0-9]*:/ { sub(/ slots free$/, ""); n = split($0, w, " "); l = l " " w[n] }
       /^core 5:/ { print l }' "$tmp/out.$name" >"$tmp/slots.$name"
  q1=$(sed -n 1p "$tmp/ps.$name"); q2=$(sed -n 2p "$tmp/ps.$name"); q3=$(sed -n 3p "$tmp/ps.$name")
  q4=$(sed -n 4p "$tmp/ps.$name")
  s0=$(sed -n 1p "$tmp/slots.$name"); sp1=$(sed -n 2p "$tmp/slots.$name"); s1=$(sed -n 3p "$tmp/slots.$name")
  sp2=$(sed -n 4p "$tmp/slots.$name"); s2=$(sed -n 5p "$tmp/slots.$name")
  pipes=$(grep -c '^12 12 35$' "$tmp/out.$name")
  nofree=$(grep -c 'no free core' "$tmp/out.$name")
  bad=$(grep -c -E 'fault|no memory|cannot|syntax error' "$tmp/out.$name")
  halted=$(grep -c 'StrataOS: all cores halted' "$tmp/out.$name")
}
check6() { # NAME PEAK REFUSED: the verdict on a run of six
  ok=1
  [ "${q1:-x}" = "$2" ] && [ "${q3:-x}" = "$q1" ] || ok=0 # the peak, twice
  [ "${q2:-x}" = 7 ] && [ "${q4:-x}" = 7 ] || ok=0     # then the servers, sh and ps only
  [ -n "$s0" ] && [ "${s1:-x}" = "$s0" ] && [ "${s2:-x}" = "$s0" ] || ok=0 # every slot back
  [ -n "$sp1" ] && [ "$sp1" != "$s0" ] || ok=0         # (and they were in use at the peak)
  [ "$pipes" = 2 ] || ok=0                             # the pipeline, at both peaks
  [ "$nofree" = "$3" ] || ok=0                         # the processes that did not fit
  grep -q '\^C$' "$tmp/out.$1" && grep -q '^3 3 6$' "$tmp/out.$1" || ok=0 # Ctrl-C, then the shell goes on
  [ "$bad" = 0 ] && [ "$halted" = 1 ] || ok=0
  if [ "$ok" = 0 ]; then
    printf '%-14s FAIL  (ps rows: %s %s %s %s; slots: [%s] [%s] [%s] [%s] [%s]; pipelines: %s; refused: %s; errors: %s; halted: %s)\n' \
      "$1" "$q1" "$q2" "$q3" "$q4" "$s0" "$sp1" "$s1" "$sp2" "$s2" "$pipes" "$nofree" "$bad" "$halted"
    sed 's/^/    /' "$tmp/out.$1" | tail -60
    exit 1
  fi
}
read6 procs-6
check6 procs-6 43 0
printf '%-14s OK    6 cores, 256 save-table slots: %s processes at once, twice, a pipeline among them;\n' procs-6 "$q1"
printf '%-14s       free slots of cores 1-5:%s, at the peak%s; Ctrl-C\n' "" "$s0" "$sp1"
read6 procs-6s
check6 procs-6s 35 2
printf '%-14s OK    6 cores, 64 save-table slots: %s processes, twice; one more refused (no free core);\n' procs-6s "$q1"
printf '%-14s       free slots of cores 1-5:%s, at the peak%s; Ctrl-C\n' "" "$s0" "$sp1"
exit 0
