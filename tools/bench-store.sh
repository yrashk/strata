#!/bin/sh
# bench-store.sh: what the file system and the store cost, measured on the
# emulator (make bench-store; doc/fs-split.md has the numbers it gave).
#
#   tools/bench-store.sh EMU BUILD DISK
#
# EMU is an emulator that prints "msgstats: ... total N blk M" at exit when
# STRATA_MSGSTATS is set (the messages each core sent: 4 KiB buffers put into
# an inbox, requests and replies both; blk: commands to the block device).
# make bench-store builds one from emu/emu.c with -DSTRATA_MSGSTATS.
# DISK is the bench disk: the standard one, 300 files in /many, dbbench in
# /bin and /bench/small (100 lines "echo N > /sm/fN").
#
# Every workload is one session of its own on 8 cores, -T virtual (one
# instruction per core per round, the time is rounds / 100): boot, uptime,
# the workload under the shell's time, uptime, halt. A session with nothing
# between the two uptimes is taken away from each, so the numbers are the
# workload's own: its time (the shell's time, in ticks of 100 rounds), the
# messages, the context switches and the KiB they moved (uptime), and the
# instructions all cores ran. The boot line is the session with nothing in
# it: the time is what the first uptime says, the rest are its totals.
set -e
EMU=$1
BUILD=${2:-build}
DISK=$3
T=$BUILD/bench-store
mkdir -p $T

run() { # name, workload lines
    name=$1; shift
    cp "$DISK" $T/d.img
    { echo uptime; for l in "$@"; do echo "$l"; done; echo uptime; echo halt; } > $T/$name.in
    STRATA_MSGSTATS=1 $EMU -c 8 -j -T virtual -g none -m 40000000000 -d $T/d.img -i $T/$name.in \
        $BUILD/bootrom.stx > $T/$name.out 2>&1 || { echo "bench-store: $name: the emulator failed"; tail $T/$name.out; exit 1; }
}

run idle
run cat 'time cat /src/cc.c'
run wc 'time wc < /src/cc.c'
run lsmany 'time ls /many'
run lsbin 'time ls /bin'
run cp 'time cp /src/cc.c /x'
run small 'time source /bench/small'
run dbbench 'time dbbench 200'
run stat 'time touch /many/f100'

python3 - $T <<'PY'
import sys, re
T = sys.argv[1]
def parse(name):
    t = open('%s/%s.out' % (T, name), errors='replace').read()
    ups = re.findall(r'up ([\d.]+) s, \d+ processes, (\d+) context switches \((\d+) KiB moved\)', t)
    m = re.search(r'msgstats:.* total (\d+) blk (\d+)', t)
    ins = sum(int(x) for x in re.findall(r'instret=(\d+)', t))
    tm = re.findall(r'time: ([\d.]+) s', t)
    db = re.findall(r'^(put|get|scan) \d+: (\d+) ticks', t, re.M)
    return dict(up=ups, msgs=int(m.group(1)), blk=int(m.group(2)), ins=ins,
                time=float(tm[-1]) if tm else 0.0, db=db, text=t)
idle = parse('idle')
up0 = idle['up'][0]
print('%-24s %12s %9s %7s %9s %9s %14s' % ('workload', 'ticks', 'messages', 'blk', 'switches', 'KiB moved', 'instructions'))
print('%-24s %12d %9d %7d %9s %9s %14d' % ('boot to the shell', float(up0[0]) * 1e6, idle['msgs'], idle['blk'],
      up0[1], up0[2], idle['ins']))
isw = int(idle['up'][1][1]) - int(idle['up'][0][1]); ikb = int(idle['up'][1][2]) - int(idle['up'][0][2])
names = [('cat', 'cat /src/cc.c (162 KB)'), ('wc', 'wc < /src/cc.c'), ('lsmany', 'ls /many (300 files)'),
         ('lsbin', 'ls /bin'), ('cp', 'cp /src/cc.c /x'), ('small', '100 small files (echo >)'),
         ('stat', 'touch /many/f100'), ('dbbench', 'dbbench 200')]
for n, label in names:
    r = parse(n)
    sw = int(r['up'][1][1]) - int(r['up'][0][1]) - isw
    kb = int(r['up'][1][2]) - int(r['up'][0][2]) - ikb
    print('%-24s %12d %9d %7d %9d %9d %14d' % (label, r['time'] * 1e6, r['msgs'] - idle['msgs'], r['blk'] - idle['blk'],
          sw, kb, r['ins'] - idle['ins']))
    for what, ticks in r['db']:
        print('    %-20s %12s' % ('%s x200' % what, ticks))
PY
