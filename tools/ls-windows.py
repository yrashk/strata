#!/usr/bin/env python3
"""ls-windows.py: what context switches would move if user-mode windows let
threads share a core's Local Stores (doc/ls-windows.md, option B of
doc/ls-switch.md), simulated from the log of an emulator built with
-DSTRATA_LSSTATS and run with STRATA_LSLOG=FILE (tools/ls-stats.sh).

    tools/ls-windows.py LOG...

The log has the dispatcher's transfers on the worker cores in order:
"G|P|X core far ls len dirty" (tget, tput, tgetx; dirty = the D-LS
segments written since the occupant was loaded). From it:
  a switch-in      G of [0, 0xA000) (from another process; far = the
                   thread's save area, its key), or G at 0 from the
                   occupant's own save area (it comes back);
  a thread's size  data: the end of its saved extent; stack: the deepest
                   byte saved or written; code: the highest I-LS byte
                   loaded for it above 0x8000 (code, mirror, units). The
                   sizes are the largest seen over the session (an oracle:
                   the real dispatcher would grow a window on a fault).
Each core keeps the threads that fit resident. A switch to a resident
thread moves nothing; to one that is not, the least recently run are
evicted until its windows fit (an evicted thread's state is saved: its
extent and live stack, or with a dirty mask only the segments written),
and its windows are loaded whole (fresh space may hold another's bytes).
The free space is the program part of each store: D-LS [0, 0xA000) and
[0xE000, 0x10000), I-LS [0x8000, 0x10000), in 1 KiB units.
"""
import sys, collections

K = 1024

def parse(path):
    for l in open(path):
        p = l.split()
        if len(p) == 6:
            yield p[0], int(p[1]), int(p[2], 16), int(p[3], 16), int(p[4], 16), int(p[5], 16)

def sizes(events):
    """per thread key: data extent end, stack low, code end (bytes)"""
    data, stk, code = collections.Counter(), {}, collections.Counter()
    occ, lastkey = {}, {}
    for op, c, far, ls, ln, d in events:
        if op == 'G' and ls == 0 and ln == 0xA000:
            occ[c] = far
        elif op == 'P' and ls < 0xA000:
            if ls == 0: lastkey[c] = far
            k = lastkey.get(c)
            if k is None: continue
            data[k] = max(data[k], ls + ln)
            for s in range(56, 64):
                if d >> s & 1: stk[k] = min(stk.get(k, 0x10000), s * K); break
        elif op == 'P' and ls >= 0xE000:
            k = lastkey.get(c)
            if k is not None: stk[k] = min(stk.get(k, 0x10000), ls)
        elif op == 'X' and ls >= 0x8000 and c in occ:
            code[occ[c]] = max(code[occ[c]], ls + ln - 0x8000)
    return data, stk, code

def up(n, g=K): return (n + g - 1) // g * g
def pow2(n):
    p = K
    while p < n: p *= 2
    return p

class Pool:
    def __init__(self, ranges): self.free = set(u for a, b in ranges for u in range(a // K, b // K))
    def take(self, n, align=1):
        n //= K
        if n == 0: return []
        fr = sorted(self.free)
        for i, u in enumerate(fr):
            if u % align: continue
            run = list(range(u, u + n))
            if all(x in self.free for x in run):
                self.free -= set(run); return run
        return None
    def give(self, run): self.free |= set(run)

def simulate(events, data, stk, code, stackfix=None, p2=False, dirty=False):
    cores = {}
    moved = sw = 0
    lastsave = {}          # key -> bytes today's save moved last time (extent + live stack)
    wmask = collections.Counter()  # key -> segments written since its last load (OR of the P masks)
    occ, lastkey = {}, {}
    for op, c, far, ls, ln, d in events:
        st = cores.setdefault(c, {'d': Pool([(0, 0xA000), (0xE000, 0x10000)]), 'i': Pool([(0x8000, 0x10000)]),
                                  'res': collections.OrderedDict()})
        if op == 'P' and ls < 0xA000:
            if ls == 0: lastkey[c] = far; lastsave[far] = 0
            k = lastkey.get(c)
            if k is not None: lastsave[k] = lastsave.get(k, 0) + ln; wmask[k] |= d
            continue
        if op == 'P' and ls >= 0xE000:
            k = lastkey.get(c)
            if k is not None: lastsave[k] = lastsave.get(k, 0) + ln
            continue
        if op != 'G' or ls != 0: continue
        if ln == 0xA000: key = far
        elif far == occ.get(c): key = far
        else: continue
        occ[c] = key
        sw += 1
        res = st['res']
        if key in res: res.move_to_end(key); continue
        dw = up(data[key]) if not p2 else pow2(data[key])
        sk = 0x10000 - (stk.get(key, 0x10000) // K * K)
        sw_ = stackfix if stackfix else max(sk, K)
        if p2: sw_ = pow2(sw_)
        cw = up(code[key]) if not p2 else pow2(code[key])
        al = (lambda n: max(1, n // K)) if p2 else (lambda n: 1)
        while True:
            got = [st['d'].take(dw, al(dw)), st['d'].take(sw_, al(sw_)), st['i'].take(cw, al(cw))]
            if all(g is not None for g in got): break
            for g, pool in zip(got, (st['d'], st['d'], st['i'])):
                if g: pool.give(g)
            if not res: got = None; break
            v, runs = res.popitem(last=False)          # evict the least recently run
            st['d'].give(runs[0]); st['d'].give(runs[1]); st['i'].give(runs[2])
            moved += bin(wmask[v]).count('1') * K if dirty else lastsave.get(v, 0)
            wmask[v] = 0
        if got is None:                                # does not fit even alone: a plain switch
            moved += 0xA000 + 0x2000 + code[key]
            continue
        res[key] = got
        wmask[key] = 0
        moved += dw + sw_ + cw
    return sw, moved

def main():
    rows = []
    for path in sys.argv[1:]:
        ev = list(parse(path))
        data, stk, code = sizes(ev)
        today = sum(ln for op, c, far, ls, ln, d in ev if not (op == 'X' and ls < 0x8000))
        nsw = sum(1 for op, c, far, ls, ln, d in ev if op == 'G' and ls == 0 and ln == 0xA000)
        r = [path.split('/')[-1].rsplit('.', 1)[0], nsw, today / K]
        for kw in ({}, {'dirty': True}, {'stackfix': 0x2000}, {'p2': True}):
            n, m = simulate(ev, data, stk, code, **kw)
            r.append(m / K)
        rows.append(r)
    print('%-8s %8s | %9s | %9s %9s %9s %9s   (KiB moved)' % ('session', 'switches', 'today', 'B', 'B+mask', 'B 8K stk', 'B pow2'))
    for r in rows:
        print('%-8s %8d | %9.0f | %9.0f %9.0f %9.0f %9.0f' % tuple(r))

if __name__ == '__main__':
    main()
