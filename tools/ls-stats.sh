#!/bin/sh
# ls-stats.sh: what StrataOS's context switches move through the far bus,
# and what they would move with dirty-segment tracking (doc/ls-switch.md).
#
#   tools/ls-stats.sh EMU BUILD DISK
#
# EMU is an emulator built with -DSTRATA_LSSTATS (make ls-stats builds
# build/strata-emu-ls), which prints "lsstats:" lines at exit. Each workload
# is a session of its own on 8 cores, -T virtual: boot, the workload, halt.
# The boot line is the session with nothing in it; the workloads' rows have
# it taken away, so they are the workload's own.
set -e
EMU=$1
BUILD=${2:-build}
DISK=$3
T=$BUILD/ls-stats
mkdir -p $T

run() { # name, workload lines
    name=$1; shift
    cp "$DISK" $T/d.img
    { for l in "$@"; do echo "$l"; done; echo halt; } > $T/$name.in
    STRATA_LSSTATS=1 $EMU -c 8 -T virtual -g none -m 40000000000 -d $T/d.img -i $T/$name.in \
        $BUILD/bootrom.stx > $T/$name.out 2>&1 || { echo "ls-stats: $name: the emulator failed"; tail $T/$name.out; exit 1; }
}

run boot
run spin2 '-c 6 spin 30 a & -c 6 spin 30 b' 'wait'
run pipe1 'time -c 6 cat /src/cc.c | -c 6 wc'
run pipe3 'time -c 6 cat /src/cc.c | -c 6 upper | -c 6 wc'
run cat 'time cat /src/cc.c'
run cp 'time cp /src/cc.c /x'

python3 - $T <<'PY'
import sys
T = sys.argv[1]
def parse(name):
    for l in open('%s/%s.out' % (T, name), errors='replace'):
        if l.startswith('lsstats: all'):
            v = l.replace('|', ' ').split()[2:]
            return [int(x) for x in v]
    raise SystemExit('ls-stats: %s: no lsstats line' % name)
b = parse('boot')
print('%-28s %8s | %7s %7s %6s %7s | %8s %8s %7s | %7s | %5s | %7s %6s' % ('workload', 'switches', 'save', 'restore', 'code',
      'KiB/sw', 'save 1K', 'rest 1K', 'KiB/sw', '4K', 'fit', 'lazy/sw', 'traps'))
for n, label in [('boot', 'boot to the shell'), ('spin2', 'two spins on core 6'), ('pipe1', 'cat | wc on core 6'),
                 ('pipe3', 'cat | upper | wc on core 6'), ('cat', 'cat /src/cc.c'), ('cp', 'cp /src/cc.c /x')]:
    r = parse(n)
    if n != 'boot': r = [x - y for x, y in zip(r, b)]
    sw, same, save, rest, code, ms, mr, ms4, mr4, fit, fitd, lazy, traps = r
    sw = max(sw, 1)
    print('%-28s %8d | %7d %7d %6d %7.1f | %8d %8d %7.1f | %7.1f | %5d | %7.1f %6.1f' % (label, r[0], save, rest, code,
          (save + rest + code) / sw, ms, mr, (ms + mr + code) / sw, (ms4 + mr4 + code) / sw, fit, (ms + lazy + code) / sw,
          traps / sw))
PY
