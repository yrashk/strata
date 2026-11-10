#!/bin/sh
# Preemption: two `spin` processes pinned to the same worker core (-c 6) both
# make progress, because the system core's time-slice tick stops that core and its
# dispatcher switches between them; `ps` shows the switches and the Local
# Store bytes they moved. Runs on the emulator with the virtual timer.
#
#   tools/test-preempt.sh build/bootrom.stx build/disk.img
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
n=${NCORES:-8}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf -- '-c 6 spin 30 a &\n-c 6 spin 30 b &\nps\nwait\nhalt\n' >"$tmp/in.txt"
cp "$2" "$tmp/d.img"
"$b/strata-emu" -c "$n" -T virtual -g none -m 400000000 -d "$tmp/d.img" -i "$tmp/in.txt" "$1" >"$tmp/out" 2>/dev/null
# both spins on core 6 with at least one switch each (ps: pid ppid state core cpus switches KiB name)
sw=$(awk '$4 == 6 && $8 == "spin" && $6 >= 1 { n++ } END { print n + 0 }' "$tmp/out")
# the characters they printed: interleaved, so neither ran to the end first
seq=$(grep -oE '[ab]{3,}' "$tmp/out" | tr -d '\n')
na=$(printf '%s' "$seq" | tr -cd a | wc -c | tr -d ' ')
nb=$(printf '%s' "$seq" | tr -cd b | wc -c | tr -d ' ')
mixed=$(printf '%s' "$seq" | grep -c 'ab.*ba\|ba.*ab')
if [ "$sw" = 2 ] && [ "$na" -ge 20 ] && [ "$nb" -ge 20 ] && [ "$mixed" = 1 ]; then
  printf '%-14s OK    two spins on core 6 interleaved; ps shows their switches\n' preempt; exit 0
fi
printf '%-14s FAIL  (spins switched: %s, a: %s, b: %s, interleaved: %s)\n' preempt "$sw" "$na" "$nb" "$mixed"
sed 's/^/    /' "$tmp/out" | tail -20; exit 1
