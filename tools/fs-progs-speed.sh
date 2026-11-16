#!/bin/sh
# The cost of the Forth ports of os/progs against the assembly programs: the
# instructions the whole machine runs (every core's instret at the end, summed)
# for one command, less those of a session that runs `true` instead. The output
# goes to a file in both, so the console costs nothing. The table in
# lang/forth/README.md ("The ports of os/progs") comes from here.
#
#   tools/fs-progs-speed.sh build/bootrom.stx build/disk.img
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
n=${NCORES:-8}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cost() {  # the instructions of a session running $1
  printf '%s > o\n\004' "$1" >"$tmp/in.txt"
  cp "$2" "$tmp/d.img"
  "$b/strata-emu" -c "$n" -j -T virtual -g none -m 20000000000 -d "$tmp/d.img" -i "$tmp/in.txt" "$3" 2>&1 |
    sed -n 's/^core [0-9]*: halt .*instret=\([0-9]*\).*/\1/p' | awk '{ s += $1 } END { print s }'
}
base=$(cost true "$2" "$1")
printf '| %-24s | %12s | %12s | %6s |\n' command '.s (K instr)' '.fs (K instr)' ratio
for c in "seq 1000" "cat /src/as.s" "upper < /src/demo/hello.s" "wc < /src/sh.s" "grep ecall < /src/sh.s" \
         "hexdump 0" "ls" "ls -t /src" "tags" "cp /src/units.s u2" "df" "devs" "ps" "cores" "uptime" \
         "free" "sched" "spin 3" "units"; do
  s=$(cost "$c" "$2" "$1")
  f=$(cost "forth $(echo "$c" | sed 's/^\([a-z]*\)/\1.fs/')" "$2" "$1")
  printf '| %-24s | %12d | %12d | %6s |\n' "$c" $(( (s - base) / 1000 )) $(( (f - base) / 1000 )) \
    "$(awk -v s=$((s - base)) -v f=$((f - base)) 'BEGIN { printf "%.1f", f / s }')"
done
