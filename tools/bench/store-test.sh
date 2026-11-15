#!/bin/sh
# store-test.sh: tools/test-store.sh run on the counting emulator
# (build/strata-emu-stats, make bench-store), every session's totals summed:
# instructions of all cores, messages, commands to the block device
#   tools/bench/store-test.sh [BUILD]
B=${1:-build}
T=$(mktemp -d)
LOG=$T/log
sed -e 's|"\$b/strata-emu"|STRATA_MSGSTATS=1 "$b/strata-emu-stats"|' \
    -e 's|2>"\$tmp/err.txt"$|2>"$tmp/err.txt"; rc=$?; cat "$tmp/err.txt" >> '"$LOG"'; return $rc|' \
    -e 's|^here=.*|here='"$PWD"'|' tools/test-store.sh > $T/ts.sh
start=$(date +%s)
sh $T/ts.sh $B/bootrom.stx $B/disk.img > $T/out 2>&1; rc=$?
end=$(date +%s)
tail -1 $T/out
python3 - $LOG $rc $((end - start)) <<'PY'
import sys, re
t = open(sys.argv[1], errors='replace').read()
ins = sum(int(x) for x in re.findall(r'instret=(\d+)', t))
m = re.findall(r'msgstats:.* total (\d+) blk (\d+)', t)
print('store test: exit %s, %d sessions, %d instructions, %d messages, %d block commands, %s s' % (
    sys.argv[2], len(m), ins, sum(int(a) for a, b in m), sum(int(b) for a, b in m), sys.argv[3]))
PY
rm -rf $T
