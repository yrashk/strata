#!/usr/bin/env python3
"""Prints the values of chosen signals in an sby counterexample trace.

  formal/vcdpeek.py TRACE.vcd NAME [NAME ...]

A NAME matches every signal whose hierarchical name ends with it (so `ir`
matches strata_core.ir, and `caps<3>` one element of an array). One line
per time step at which any of them changes.
"""
import sys

def main():
    path, wanted = sys.argv[1], sys.argv[2:]
    ids, scope, order = {}, [], []
    values, time, rows = {}, 0, []
    with open(path) as f:
        header = True
        for line in f:
            t = line.split()
            if not t:
                continue
            if header:
                if t[0] == '$scope':
                    scope.append(t[2])
                elif t[0] == '$upscope':
                    scope.pop()
                elif t[0] == '$var':
                    name = '.'.join(scope + [t[4]])
                    for w in wanted:
                        if name == w or name.endswith('.' + w):
                            ids.setdefault(t[3], name)
                            if name not in order:
                                order.append(name)
                elif t[0] == '$enddefinitions':
                    header = False
                continue
            if t[0][0] == '#':
                rows.append((time, dict(values)))
                time = int(t[0][1:])
            elif t[0][0] == 'b' and len(t) == 2 and t[1] in ids:
                values[ids[t[1]]] = t[0][1:]
            elif t[0][0] in '01xz' and t[0][1:] in ids:
                values[ids[t[0][1:]]] = t[0][0]
    rows.append((time, dict(values)))
    last = None
    for time, v in rows:
        if v and v != last:
            print(f'#{time}', ' '.join(
                f'{n.split(".")[-1]}={int(v[n], 2):x}' if n in v and set(v[n]) <= set('01') else f'{n.split(".")[-1]}=?'
                for n in order))
            last = v

main()
