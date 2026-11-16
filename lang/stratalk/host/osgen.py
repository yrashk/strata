#!/usr/bin/env python3
# osgen.py: Stratalk classes for every StrataOS server, from os/spec/*.toml.
#
#   osgen.py OUT.st          write the classes (kernel/OSServers.st)
#   osgen.py --check OUT.st  the file must be what the specs give, and every
#                            message op of every spec must have its methods
#
# Each server with message calls gets a class, <Key>Server (ProcServer,
# FsServer, DbServer, ...): `XServer default` reaches it (its register, or a
# lookup, and the server index of header word 48), and for each op two
# methods: `name` and `name: aDictionary`, the op's name in lower camel case
# (DBGET: dbget, GRANT_FB: grantFb). The Dictionary's keys are the spec's
# names of the request's header words ('handle', 'length', 'mode') and data
# fields; what is not given is zero (or empty). The answer is an OSReply:
# its result, handle, length and mode words, its data, and `fields`, the data
# decoded by the spec (records in 'records').
import os
import re
import sys
import tomllib

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..')
SPEC = os.path.join(ROOT, 'os', 'spec')

# how a program reaches each server: (register, a name to look up or None,
# the server index of header word 48)
REACH = {
    'proc': (1, None, 0), 'fs': (2, None, 0), 'tty': (3, None, 0), 'pipe': (4, None, 0),
    'db': (4, None, 1),
    'dev': (2, 'dev', 0), 'blk': (2, 'dev', 1),
    'net': (2, 'net', 0), 'ws': (2, 'ws', 0),
    'kernel': (0, None, 0), 'system': (0, None, 0),
}
RESERVED = {'class', 'size', 'value', 'name', 'print', 'hash', 'copy', 'error', 'halt', 'yourself',
            'new', 'initialize', 'default', 'server', 'register', 'index', 'request'}


def selector(opname):
    parts = opname.lower().split('_')
    s = parts[0] + ''.join(p.capitalize() for p in parts[1:])
    if s in RESERVED: s = 'op' + s.capitalize()
    return s


def st_string(s):
    return "'" + s.replace("'", "''") + "'"


def comment(s):
    return s.replace('"', "'")


def field_list(fields):
    """Fields as a literal array: #( #(type 'name') ... #(#repeat 'over' #(...)) )."""
    out = []
    for f in fields or []:
        if 'repeat' in f:
            out.append('#(#repeat %s %s)' % (st_string(f['repeat']), field_list(f['fields'])))
        else:
            out.append('#(#%s %s)' % (f['type'], st_string(f.get('name', ''))))
    return '#(' + ' '.join(out) + ')'


def describe(part):
    if not part: return 'nothing'
    bits = []
    for k in ('handle', 'length', 'mode', 'result'):
        if k in part: bits.append('%s: %s' % (k, part[k]))
    if 'modes' in part:
        bits.append('modes: ' + ', '.join('%s %s' % kv for kv in part['modes'].items()))
    if 'data' in part:
        names = []
        for f in part['data']:
            if 'repeat' in f: names.append('records (%s)' % f['repeat'])
            elif f.get('type') != 'pad': names.append(f.get('name', ''))
        bits.append('data: ' + ', '.join(names))
    if 'attachment' in part: bits.append('attachment: ' + part['attachment'] + ' (not sent from Stratalk)')
    if 'attachments' in part: bits.append('attachments: ' + ', '.join(part['attachments'].values()))
    return '; '.join(bits)


def generate():
    specs = []
    for fn in sorted(os.listdir(SPEC)):
        if fn.endswith('.toml'):
            d = tomllib.load(open(os.path.join(SPEC, fn), 'rb'))
            specs.append((fn, d))
    out = ['"OSServers.st: made by lang/stratalk/host/osgen.py from os/spec/*.toml; do not edit.',
           ' A class per StrataOS server, a method pair per message op (OS.st has the',
           ' machinery). The svc calls are not messages: the VM makes them itself."', '']
    ops_total = 0
    svc = []
    for fn, d in specs:
        sv = d.get('server', {})
        key = sv.get('key', fn[:-5])
        if sv.get('calls') == 'svc':
            svc.extend(op['name'] for op in d.get('op', []))
            continue
        if not d.get('op'): continue
        cls = key.capitalize() + 'Server'
        reg, look, idx = REACH.get(key, (2, key, 0))
        out.append('OSServer subclass: #%s slots: \'\'.' % cls)
        how = sv.get('reached', '')
        if look:
            body = '^self register: %d lookup: %s index: %d' % (reg, st_string(look), idx)
        elif reg:
            body = '^self register: %d lookup: nil index: %d' % (reg, idx)
        else:
            body = '^self error: %s' % st_string('a program has no endpoint to ' + key)
        out.append('%s class >> default [\n    "%s: %s"\n    %s ]' % (cls, comment(sv.get('title', key)), comment(how), body))
        out.append('%s class >> spec [ ^%s ]' % (cls, st_string(fn)))
        for op in d['op']:
            ops_total += 1
            sel = selector(op['name'])
            req, rep = op.get('request', {}), op.get('reply', {})
            doc = '%s (%d): %s. Request: %s. Reply: %s.' % (op['name'], op['num'], op.get('summary', ''),
                                                           describe(req), describe(rep))
            if op.get('from'): doc += ' From: %s.' % op['from']
            out.append('%s >> %s [ ^self %s: Dictionary new ]' % (cls, sel, sel))
            out.append('%s >> %s: args [\n    "%s"\n    ^self op: %d named: %s args: args request: %s reply: %s ]' % (
                cls, sel, comment(doc), op['num'], st_string(op['name']),
                field_list(req.get('data')), field_list(rep.get('data'))))
        out.append('')
    out.append('OSServer class >> svcCalls [ "The svc calls (not messages): the VM makes them" ^#(%s) ]'
               % ' '.join(st_string(n) for n in svc))
    out.append('OSServer class >> opCount [ ^%d ]' % ops_total)
    return '\n'.join(out) + '\n', ops_total


def main(argv):
    check = '--check' in argv
    path = [a for a in argv[1:] if not a.startswith('--')][0]
    text, n = generate()
    if check:
        have = open(path).read() if os.path.exists(path) else ''
        if have != text:
            print('osgen: %s is not what os/spec gives: run lang/stratalk/host/osgen.py %s' % (path, path))
            return 1
        print('osgen: %d ops, every one with its methods' % n)
        return 0
    open(path, 'w').write(text)
    print('osgen: %s: %d ops' % (path, n))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
