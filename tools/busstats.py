#!/usr/bin/env python3
"""busstats.py: sums the far-bus counts of `strata-emu --bus-stats FILE` for a StrataOS session.

    tools/busstats.py [--map build/kernel.map] [--cores 1=proc,2=dev,3=fs,...] FILE

Prints the transactions, bytes and bus cycles per space (T2, T3, devices,
the block device's DMA) and per use, the use decided from who issued the
transfer and where it went:
  kst        far atomics (the kernel shared table)
  switch     the dispatcher's save and restore of a thread (w_out, w_in, ...)
  scrub      core 0 writing zeros over an arena it hands out
  code       tgetx: code paged into an I-LS (kernel units, programs' units)
  kernel     the rest of the kernel's transfers (supervisor mode)
  fb         user transfers into the framebuffer window [48, 64) MiB of T3
  msg        user transfers through a 4 KiB capability (a message buffer)
  fscache    the rest of the file server's transfers (its core: --cores)
  disk       the block device's DMA
  device     user transfers to device space
  user       the rest of the user-mode transfers
Bus cycles are the RTL's: a burst costs the target's latency (T3 20, T2 4)
and a cycle per 8-byte beat; an atomic the latency and 3 more.
"""
import sys
from collections import defaultdict

SPACE = {2: 'T2', 3: 'T3', 4: 'dev'}
OPS = ['get', 'put', 'getx', 'amo', 'blkrd', 'blkwr']
FB_LO, FB_HI = 48 << 20, 64 << 20


def load_map(path):
    syms = []
    for line in open(path):
        p = line.split()
        if len(p) == 4 and p[0] == 'sym' and p[1] == 'text':
            syms.append((int(p[2], 16), p[3]))
    syms.sort()
    return syms


def sym_of(syms, pc):
    lo, hi, best = 0, len(syms) - 1, '?'
    while lo <= hi:
        m = (lo + hi) // 2
        if syms[m][0] <= pc:
            best, lo = syms[m][1], m + 1
        else:
            hi = m - 1
    return best


SWITCH = ('w_out', 'w_in', 'wi_', 'wo_', 'dd_', 'dls_')


def main():
    args = sys.argv[1:]
    mapf, cores = 'build/kernel.map', {}
    while args and args[0].startswith('--'):
        if args[0] == '--map':
            mapf = args[1]
        elif args[0] == '--cores':
            cores = {int(k): v for k, v in (x.split('=') for x in args[1].split(','))}
        args = args[2:]
    syms = load_map(mapf)
    use = defaultdict(lambda: [0, 0, 0])
    space = defaultdict(lambda: [0, 0, 0])
    ksym = defaultdict(lambda: [0, 0, 0])
    sizes = defaultdict(lambda: [0, 0, 0])
    t2pages = []
    for line in open(args[0]):
        if line.startswith('# t2-page'):
            t2pages.append(line.split()[2:])
            continue
        if line.startswith('#'):
            if 't2-lines' in line:
                print(line.strip()[2:])
            continue
        core, user, pc, ra, op, sp, far, caplen, n, b, cyc = line.split()
        core, user, op, sp, n, b, cyc = int(core), int(user), int(op), int(sp), int(n), int(b), int(cyc)
        pc, far, caplen = int(pc, 16), int(far, 16), int(caplen, 16)
        sname = SPACE.get(sp, str(sp))
        if OPS[op] == 'amo':
            u = 'kst'
        elif OPS[op].startswith('blk'):
            u, sname = 'disk', sname + '(dma)'
        elif OPS[op] == 'getx':
            u = 'code'
        elif not user:
            s = sym_of(syms, pc) if core else 'core0'
            u = 'switch' if s.startswith(SWITCH) else 'scrub' if not core and OPS[op] == 'put' and caplen >= 1 << 20 \
                else 'kernel'
            ksym[(core and 'w' or 'k0', s, sname, OPS[op])][0] += n
            ksym[(core and 'w' or 'k0', s, sname, OPS[op])][1] += b
            ksym[(core and 'w' or 'k0', s, sname, OPS[op])][2] += cyc
        elif sp == 3 and FB_LO <= far < FB_HI:
            u = 'fb'
        elif sp == 4:
            u = 'device'
        elif caplen == 4096:
            u = 'msg'
        elif cores.get(core) == 'fs':
            u = 'fscache'
        else:
            u = 'user'
        for t in (use[(u, sname)], space[sname]):
            t[0] += n
            t[1] += b
            t[2] += cyc
        if sp in (2, 3) and OPS[op] != 'amo':
            k = 'small (<=64 B)' if b <= 64 * n else 'medium (<=4 KiB)' if b <= 4096 * n else 'large'
            sizes[(k, sname)][0] += n
            sizes[(k, sname)][1] += b
            sizes[(k, sname)][2] += cyc
    tot = sum(v[2] for v in space.values())
    print('%-14s %10s %12s %12s %6s' % ('space', 'n', 'bytes', 'bus cycles', '%'))
    for k, v in sorted(space.items(), key=lambda x: -x[1][2]):
        print('%-14s %10d %12d %12d %5.1f%%' % (k, v[0], v[1], v[2], 100 * v[2] / tot))
    print()
    print('%-10s %-10s %10s %12s %12s %6s %10s' % ('use', 'space', 'n', 'bytes', 'bus cycles', '%', 'lat share'))
    for (u, s), v in sorted(use.items(), key=lambda x: -x[1][2]):
        lat = (4 if s.startswith('T2') else 20 if s.startswith('T3') else 0) * v[0]
        print('%-10s %-10s %10d %12d %12d %5.1f%% %9.1f%%' % (u, s, v[0], v[1], v[2], 100 * v[2] / tot,
                                                              100 * lat / v[2] if v[2] else 0))
    print()
    print('memory transfers by size (bytes per transaction)')
    for (k, s), v in sorted(sizes.items()):
        print('  %-18s %-4s %10d %12d %12d' % (k, s, v[0], v[1], v[2]))
    print()
    print('kernel transfers by symbol (top 25 by bus cycles)')
    for (w, s, sp, op), v in sorted(ksym.items(), key=lambda x: -x[1][2])[:25]:
        print('  %-3s %-18s %-4s %-5s %8d %12d %12d' % (w, s, sp, op, v[0], v[1], v[2]))
    if t2pages:
        print()
        print('T2 4 KiB pages touched (64-byte lines of 64):', ' '.join('%s:%s' % (a, b) for a, b in t2pages))


main()
