#!/usr/bin/env python3
# stratalk.py: Stratalk on the host.
#
#   stratalk.py build -o IMAGE LOADFILE      compile the kernel, run its
#                                            initialisations, write the image
#   stratalk.py run IMAGE [ARGS...]          run an image here (the reference
#                                            interpreter): the REPL, -e EXPR, FILE
#   stratalk.py dis IMAGE CLASS SELECTOR     the bytecodes of a method
#   stratalk.py check IMAGE LOADFILE         the image's compiler against this one
#
# The image is the far heap as the VM (lang/stratalk/vm.s) loads it: the
# object format is in lang/stratalk/README.md. This interpreter follows
# the VM's rules (the same bytecodes, primitives and frames) without its
# memory hierarchy: every object is far, nothing is collected.
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stc
from stc import (Sym, Str, Char, LitArray, ByteArr, Global, ClassRef, Code, NIL, TRUE, FALSE,
                 SPECIAL_SELECTORS, CompileError)

# ---- the object format ------------------------------------------------------------
F_FIXED, F_INDEX, F_BYTES, F_METHOD, F_WORDS, F_FREE = 0, 1, 2, 3, 4, 15
FMT_SHIFT, PAD_SHIFT, IMM_BIT, MARK_BIT, FWD_BIT = 16, 20, 1 << 23, 1 << 24, 1 << 25
HASH_SHIFT, HASH_MASK, SIZE_SHIFT = 27, 0x1FFFF, 44
HEAP_BASE = 64                       # [0, 64): the image header
MAGIC = 0x314B4C5441525453           # "STRATLK1"

FIXED_CLASSES = ['SmallInteger', 'Character', 'UndefinedObject', 'True', 'False', 'Array',
                 'String', 'Symbol', 'CompiledMethod', 'CompiledBlock', 'BlockClosure',
                 'Message', 'ByteArray', 'Association', 'MethodDictionary',
                 'LargePositiveInteger', 'LargeNegativeInteger', 'Float']
CI = {n: i + 1 for i, n in enumerate(FIXED_CLASSES)}
FIRST_FREE_CI = 32
CLASS_TABLE_SIZE = 4096

# the specials array (heap header word 2)
SP_TRUE, SP_FALSE, SP_CLASSES, SP_SPSELS, SP_DNU, SP_MUSTBOOL, SP_CANNOTRET, SP_UNWIND, \
    SP_START_RCVR, SP_START_SEL, SP_SMALLTALK, SP_SYMBOLS, SP_OVERFLOW = range(13)
NSPECIALS = 16

# Behavior's slots, then Class's or Metaclass's (the VM reads the first four)
B_SUPER, B_MDICT, B_FORMAT, B_INDEX, C_NAME, C_IVARS = range(6)

SMALL_MIN, SMALL_MAX = -(1 << 62), (1 << 62) - 1


def strhash(b):
    h = 2166136261
    for c in b:
        h = ((h ^ c) * 16777619) & 0xFFFFFFFF
    return h & 0x3FFFFFFF


class StError(Exception):
    pass


class Heap:
    def __init__(self, size=64 << 20):
        self.mem = bytearray(size)
        self.used = HEAP_BASE
        self.hashc = 0

    def grow(self, need):
        while self.used + need > len(self.mem):
            self.mem.extend(bytearray(len(self.mem)))

    def word(self, a):
        return int.from_bytes(self.mem[a:a + 8], 'little')

    def setword(self, a, v):
        self.mem[a:a + 8] = (v & 0xFFFFFFFFFFFFFFFF).to_bytes(8, 'little')

    def next_hash(self):
        self.hashc = (self.hashc + 0x9E37) & HASH_MASK
        return self.hashc

    def alloc(self, ci, fmt, nslots, pad=0, h=None):
        if nslots >= 1 << 20: raise StError('object too large')
        size = 8 + 8 * nslots
        self.grow(size)
        oop = self.used
        self.used += size
        if h is None: h = self.next_hash()
        self.setword(oop, ci | fmt << FMT_SHIFT | pad << PAD_SHIFT | h << HASH_SHIFT | nslots << SIZE_SHIFT)
        return oop

    def hdr(self, oop): return self.word(oop)
    def slot(self, oop, i): return self.word(oop + 8 + 8 * i)
    def setslot(self, oop, i, v): self.setword(oop + 8 + 8 * i, v)
    def nslots(self, oop): return self.word(oop) >> SIZE_SHIFT
    def fmt(self, oop): return (self.word(oop) >> FMT_SHIFT) & 15
    def ci(self, oop): return self.word(oop) & 0xFFFF
    def pad(self, oop): return (self.word(oop) >> PAD_SHIFT) & 7

    def nbytes(self, oop):
        return self.nslots(oop) * 8 - self.pad(oop)

    def bytes_of(self, oop):
        n = self.nbytes(oop)
        return bytes(self.mem[oop + 8:oop + 8 + n])

    def alloc_bytes(self, ci, b, fmt=F_BYTES):
        n = len(b)
        ns = (n + 7) // 8
        oop = self.alloc(ci, fmt, ns, ns * 8 - n)
        self.mem[oop + 8:oop + 8 + n] = b
        return oop


def si(v):                      # SmallInteger oop of v
    return ((v << 1) | 1) & 0xFFFFFFFFFFFFFFFF


def is_si(o): return o & 1


def si_val(o):
    v = o >> 1
    return v - (1 << 63) if v >= 1 << 62 else v


def ch(c): return (c << 3) | 4


# ---- the image builder ------------------------------------------------------------------
class ClassDef:
    def __init__(self, name, sup, kind, slots, line):
        self.name, self.sup, self.kind, self.slots, self.line = name, sup, kind, slots, line
        self.cslots = []
        self.methods = []          # (meta, MethodNode, source text)
        self.oop = self.meta = None
        self.ci = self.mci = None


KIND_FMT = {'subclass:slots:': None, 'variableSubclass:slots:': F_INDEX,
            'byteSubclass:slots:': F_BYTES, 'wordSubclass:slots:': F_WORDS,
            'methodSubclass:slots:': F_METHOD}


class Builder:
    def __init__(self):
        self.h = Heap()
        self.classes = {}          # name -> ClassDef
        self.order = []
        self.symbols = {}          # name -> oop
        self.globals = {}          # name -> association oop
        self.doits = []            # (file, line, node)
        self.files = []            # the kernel's source files, in order
        self.ci_next = FIRST_FREE_CI

    # -- reading the sources
    def load(self, loadfile):
        base = os.path.dirname(loadfile)
        for line in open(loadfile):
            line = line.split('#')[0].strip()
            if line: self.read(os.path.join(base, line))

    def read(self, path):
        if 'kernel' in os.path.dirname(os.path.abspath(path)).split(os.sep)[-1:]:
            self.files.append(path)
        src = open(path, encoding='utf-8').read()
        try:
            items = stc.Parser(src).items()
        except CompileError as e:
            raise CompileError('%s: %s' % (path, e))
        for it in items:
            if it[0] == 'vars':
                continue
            if it[0] == 'method':
                _, cname, meta, m = it
                if cname not in self.classes:
                    raise CompileError('%s:%d: no class %s' % (path, m.line, cname))
                self.classes[cname].methods.append((meta, m, path))
            else:
                _, e, line = it
                if not self.class_def(e, path, line):
                    self.doits.append((path, line, e))

    def class_def(self, e, path, line):
        if isinstance(e, stc.Send) and e.sel in KIND_FMT and isinstance(e.rcvr, stc.Var):
            sup = e.rcvr.name
            name, slots = e.args
            if not (isinstance(name, stc.Lit) and isinstance(name.v, Sym) and isinstance(slots, stc.Lit)
                    and isinstance(slots.v, Str)):
                return False
            if sup != 'nil' and sup not in self.classes:
                raise CompileError('%s:%d: no class %s' % (path, line, sup))
            cd = ClassDef(name.v.s, None if sup == 'nil' else sup, e.sel, slots.v.s.split(), line)
            if cd.name in self.classes: raise CompileError('%s:%d: %s defined twice' % (path, line, cd.name))
            self.classes[cd.name] = cd
            self.order.append(cd)
            return True
        # Name class slots: 'a b'.
        if isinstance(e, stc.Send) and e.sel == 'slots:' and isinstance(e.rcvr, stc.Send) \
                and e.rcvr.sel == 'class' and isinstance(e.rcvr.rcvr, stc.Var):
            cd = self.classes[e.rcvr.rcvr.name]
            cd.cslots = e.args[0].v.s.split()
            return True
        return False

    # -- layout
    def all_ivars(self, cd):
        out = []
        c = cd
        chain = []
        while c: chain.append(c); c = self.classes.get(c.sup) if c.sup else None
        for c in reversed(chain): out += c.slots
        return out

    def all_cslots(self, cd):
        chain = []
        c = cd
        while c: chain.append(c); c = self.classes.get(c.sup) if c.sup else None
        out = []
        for c in reversed(chain): out += c.cslots
        return out

    def fmt_of(self, cd):
        f = KIND_FMT[cd.kind]
        if f is not None: return f
        c = self.classes.get(cd.sup) if cd.sup else None
        while c:
            f2 = KIND_FMT[c.kind]
            if f2 is not None: return f2
            c = self.classes.get(c.sup) if c.sup else None
        return F_FIXED

    def symbol(self, s):
        if s in self.symbols: return self.symbols[s]
        b = s.encode('utf-8')
        oop = self.h.alloc_bytes(CI['Symbol'], b)
        # a symbol's identity hash is its text's: method dictionaries spread well
        w = self.h.hdr(oop)
        w = (w & ~(HASH_MASK << HASH_SHIFT)) | ((strhash(b) & HASH_MASK) << HASH_SHIFT)
        self.h.setword(oop, w | IMM_BIT)
        self.symbols[s] = oop
        return oop

    def global_assoc(self, name):
        if name in self.globals: return self.globals[name]
        a = self.h.alloc(CI['Association'], F_FIXED, 2)
        self.h.setslot(a, 0, self.symbol(name))
        self.globals[name] = a
        return a

    def string(self, s, imm=True):
        oop = self.h.alloc_bytes(CI['String'], s.encode('utf-8'))
        if imm: self.h.setword(oop, self.h.hdr(oop) | IMM_BIT)
        return oop

    def array(self, items, imm=False):
        a = self.h.alloc(CI['Array'], F_INDEX, len(items))
        for i, v in enumerate(items): self.h.setslot(a, i, v)
        if imm: self.h.setword(a, self.h.hdr(a) | IMM_BIT)
        return a

    def literal(self, v, cd_oop):
        if v is NIL: return 0
        if v is TRUE: return self.true
        if v is FALSE: return self.false
        if isinstance(v, int):
            if SMALL_MIN <= v <= SMALL_MAX: return si(v)
            m = abs(v); b = bytearray()
            while m: b.append(m & 255); m >>= 8
            o = self.h.alloc_bytes(self.classes['LargeNegativeInteger' if v < 0 else 'LargePositiveInteger'].ci, bytes(b))
            return o
        if isinstance(v, Sym): return self.symbol(v.s)
        if isinstance(v, Str): return self.string(v.s)
        if isinstance(v, Char): return ch(v.c)
        if isinstance(v, LitArray): return self.array([self.literal(x, cd_oop) for x in v.items], True)
        if isinstance(v, ByteArr):
            o = self.h.alloc_bytes(CI['ByteArray'], v.b); self.h.setword(o, self.h.hdr(o) | IMM_BIT); return o
        if isinstance(v, Global): return self.global_assoc(v.name)
        if isinstance(v, ClassRef): return cd_oop
        if isinstance(v, Code): return self.method(v, cd_oop)
        raise CompileError('literal %r' % v)

    def method(self, code, cls_oop):
        return make_method(self.h, code, lambda v: self.literal(v, cls_oop))

    def build(self):
        h = self.h
        # class indices
        used = set()
        for cd in self.order:
            if cd.name in CI: cd.ci = CI[cd.name]
            else: cd.ci = self.ci_next; self.ci_next += 1
        for cd in self.order:
            cd.mci = self.ci_next; self.ci_next += 1
        for n in ('Behavior', 'Class', 'Metaclass', 'Object', 'True', 'False', 'Stratalk', 'Message'):
            if n not in self.classes: raise CompileError('the kernel has no class %s' % n)
        self.true = h.alloc(CI['True'], F_FIXED, 0)
        self.false = h.alloc(CI['False'], F_FIXED, 0)
        cls_size = len(self.all_ivars(self.classes['Class']))
        meta_size = len(self.all_ivars(self.classes['Metaclass']))
        expect = ['superclass', 'methodDict', 'format', 'classIndex']
        if self.all_ivars(self.classes['Behavior'])[:4] != expect:
            raise CompileError('Behavior must begin with the slots %s' % ' '.join(expect))
        for cd in self.order:
            nc = cls_size + len(self.all_cslots(cd))
            cd.meta = h.alloc(self.classes['Metaclass'].ci, F_FIXED, meta_size)
            cd.oop = h.alloc(cd.mci, F_FIXED, nc)
        for cd in self.order:
            sup = self.classes[cd.sup] if cd.sup else None
            h.setslot(cd.oop, B_SUPER, sup.oop if sup else 0)
            h.setslot(cd.meta, B_SUPER, sup.meta if sup else self.classes['Class'].oop)
            iv = self.all_ivars(cd)
            h.setslot(cd.oop, B_FORMAT, si(len(iv) | self.fmt_of(cd) << 16))
            h.setslot(cd.oop, B_INDEX, si(cd.ci))
            h.setslot(cd.oop, C_NAME, self.symbol(cd.name))
            h.setslot(cd.oop, C_IVARS, self.array([self.string(x) for x in cd.slots]))
            nc = cls_size + len(self.all_cslots(cd))
            h.setslot(cd.meta, B_FORMAT, si(nc))
            h.setslot(cd.meta, B_INDEX, si(cd.mci))
            h.setslot(cd.meta, C_NAME, cd.oop)          # Metaclass: thisClass
            h.setslot(cd.meta, C_IVARS, self.array([self.string(x) for x in cd.cslots]))
            h.setword(self.global_assoc(cd.name) + 16, cd.oop)
        # methods
        for cd in self.order:
            per = {False: {}, True: {}}
            for meta, m, path in cd.methods:
                ivars = (self.all_ivars(self.classes['Class']) + self.all_cslots(cd)) if meta else self.all_ivars(cd)
                try:
                    code = stc.Compiler(ivars, cd.name).compile(m)
                except CompileError as e:
                    raise CompileError('%s: %s%s>>%s: %s' % (path, cd.name, ' class' if meta else '', m.sel, e))
                per[meta][m.sel] = self.method(code, cd.meta if meta else cd.oop)
            for meta in (False, True):
                h.setslot(cd.meta if meta else cd.oop, B_MDICT, self.method_dict(per[meta]))
        # the class table
        table = [0] * CLASS_TABLE_SIZE
        for cd in self.order:
            table[cd.ci] = cd.oop; table[cd.mci] = cd.meta
        classes = self.array(table)
        spsels = self.array([self.symbol(s) for s, n in SPECIAL_SELECTORS])
        specials = [0] * NSPECIALS
        specials[SP_TRUE], specials[SP_FALSE], specials[SP_CLASSES] = self.true, self.false, classes
        specials[SP_SPSELS] = spsels
        specials[SP_DNU] = self.symbol('doesNotUnderstand:')
        specials[SP_MUSTBOOL] = self.symbol('mustBeBoolean')
        specials[SP_CANNOTRET] = self.symbol('cannotReturn:')
        specials[SP_UNWIND] = self.symbol('unwindAndReturn:to:')
        specials[SP_START_RCVR] = self.classes['Stratalk'].oop
        specials[SP_START_SEL] = self.symbol('start')
        specials[SP_OVERFLOW] = self.symbol('stackOverflow')
        self.specials = self.array(specials)
        # the globals and the symbols: made last, every name is known by now
        for n in ('Smalltalk', 'Transcript', 'Processor'): self.global_assoc(n)
        # the kernel's files, for the browser (on the disk under /stratalk)
        h.setword(self.global_assoc('SourceFiles') + 16,
                  self.array([self.string(os.path.basename(p)) for p in self.files], True))
        self.finish_tables()

    def finish_tables(self):
        h = self.h
        sd = self.classes['SystemDictionary']
        assocs = list(self.globals.values())
        size = 1
        while size < 2 * len(assocs) + 64: size *= 2
        arr = [0] * size
        for a in assocs:
            k = h.slot(a, 0)
            i = ((h.hdr(k) >> HASH_SHIFT) & HASH_MASK) & (size - 1)
            while arr[i]: i = (i + 1) & (size - 1)
            arr[i] = a
        smalltalk = h.alloc(sd.ci, F_FIXED, len(self.all_ivars(sd)))
        h.setslot(smalltalk, 0, si(len(assocs)))
        h.setslot(smalltalk, 1, self.array(arr))
        h.setword(self.global_assoc('Smalltalk') + 16, smalltalk)
        syms = list(self.symbols.values())
        size = 1
        while size < 2 * len(syms) + 1024: size *= 2
        arr = [0] * size
        for s in syms:
            i = strhash(h.bytes_of(s)) & (size - 1)
            while arr[i]: i = (i + 1) & (size - 1)
            arr[i] = s
        symtab = self.array(arr)
        sp = self.specials
        h.setslot(sp, SP_SMALLTALK, smalltalk)
        h.setslot(sp, SP_SYMBOLS, symtab)
        h.setword(0, MAGIC)
        h.setword(8, h.used)
        h.setword(16, sp)

    def method_dict(self, methods):
        h = self.h
        size = 4
        while size < 2 * len(methods): size *= 2
        keys, vals = [0] * size, [0] * size
        for sel, m in methods.items():
            s = self.symbol(sel)
            i = ((h.hdr(s) >> HASH_SHIFT) & HASH_MASK) & (size - 1)
            while keys[i]: i = (i + 1) & (size - 1)
            keys[i], vals[i] = s, m
        md = h.alloc(CI['MethodDictionary'], F_FIXED, 3)
        h.setslot(md, 0, si(len(methods)))
        h.setslot(md, 1, self.array(keys))
        h.setslot(md, 2, self.array(vals))
        return md


def make_method(h, code, lit):
    """A CompiledMethod or CompiledBlock object for code, its literals made by lit."""
    lits = [lit(v) for v in code.lits]
    nb = len(code.bytes)
    nwords = 1 + len(lits) + (nb + 7) // 8
    pad = (8 - nb % 8) % 8
    ci = CI['CompiledBlock'] if code.is_block else CI['CompiledMethod']
    m = h.alloc(ci, F_METHOD, nwords, pad)
    h.setslot(m, 0, si(code.header()))
    for i, v in enumerate(lits): h.setslot(m, 1 + i, v)
    base = m + 8 + 8 * (1 + len(lits))
    h.mem[base:base + nb] = code.bytes
    return m


# ---- the reference interpreter ----------------------------------------------------------
HDR_NARGS = lambda x: x & 255
HDR_NTEMPS = lambda x: (x >> 8) & 255
HDR_NLITS = lambda x: (x >> 16) & 255
HDR_PRIM = lambda x: (x >> 24) & 0xFFF
HDR_NCOPIED = lambda x: (x >> 36) & 255
HDR_ISBLOCK = lambda x: (x >> 44) & 1

FL_BLOCK, FL_ENSURE, FL_HANDLER, FL_DONE, FL_DISABLED = 1, 2, 4, 8, 16


class Frame:
    __slots__ = ('method', 'bc', 'base', 'lits', 'ip', 'temps', 'stack', 'self_', 'rcvr',
                 'sender', 'serial', 'flags', 'hdr', 'depth')


class Quit(Exception):
    def __init__(self, code): self.code = code


class VM:
    def __init__(self, heap, args=(), out=None):
        self.h = heap
        self.args = list(args)
        self.out = out or sys.stdout.buffer
        sp = heap.word(16)
        self.specials = sp
        g = lambda i: heap.slot(sp, i)
        self.true, self.false = g(SP_TRUE), g(SP_FALSE)
        self.classes = g(SP_CLASSES)
        self.spsels = [heap.slot(g(SP_SPSELS), i) for i in range(len(SPECIAL_SELECTORS))]
        self.serial = 0
        self.mcache = {}
        self.lcache = {}
        self.sends = 0
        self.bytecodes = 0
        self.stdin = sys.stdin.buffer

    # -- objects
    def class_index(self, o):
        if o & 1: return 1
        if o & 7 == 4: return 2
        if o == 0: return 3
        return self.h.word(o) & 0xFFFF

    def class_of(self, o):
        return self.h.slot(self.classes, self.class_index(o))

    def bool(self, b): return self.true if b else self.false

    def new_array(self, items):
        h = self.h
        a = h.alloc(CI['Array'], F_INDEX, len(items))
        for i, v in enumerate(items): h.setslot(a, i, v)
        return a

    def new_string(self, b, ci=None):
        return self.h.alloc_bytes(ci or CI['String'], b)

    def instantiate(self, cls, n):
        h = self.h
        f = si_val(h.slot(cls, B_FORMAT))
        fixed, fmt = f & 0xFFFF, f >> 16
        ci = si_val(h.slot(cls, B_INDEX))
        if fmt == F_FIXED:
            if n: return None
            return h.alloc(ci, F_FIXED, fixed)
        if fmt == F_INDEX: return h.alloc(ci, F_INDEX, fixed + n)
        if fmt == F_BYTES:
            ns = (n + 7) // 8
            return h.alloc(ci, F_BYTES, ns, ns * 8 - n)
        if fmt == F_WORDS: return h.alloc(ci, F_WORDS, n)
        return None

    def code_info(self, m):
        info = self.mcache.get(m)
        if info is None:
            h = self.h
            hdr = si_val(h.slot(m, 0))
            nl = HDR_NLITS(hdr)
            lits = [h.slot(m, 1 + i) for i in range(nl)]
            start = m + 8 + 8 * (1 + nl)
            bc = bytes(h.mem[start:m + 8 + h.nbytes(m)])
            info = (hdr, lits, bc)
            self.mcache[m] = info
        return info

    def lookup(self, ci, sel):
        key = (ci, sel)
        m = self.lcache.get(key)
        if m is not None: return m
        h = self.h
        cls = h.slot(self.classes, ci)
        while cls:
            md = h.slot(cls, B_MDICT)
            if md and h.slot(md, 1):
                keys, vals = h.slot(md, 1), h.slot(md, 2)
                size = h.nslots(keys)
                i = ((h.hdr(sel) >> HASH_SHIFT) & HASH_MASK) & (size - 1)
                while True:
                    k = h.slot(keys, i)
                    if k == sel:
                        m = h.slot(vals, i)
                        self.lcache[key] = m
                        return m
                    if k == 0: break
                    i = (i + 1) & (size - 1)
            cls = h.slot(cls, B_SUPER)
        return 0

    def lookup_from(self, cls, sel):
        return self.lookup(si_val(self.h.slot(cls, B_INDEX)), sel)

    # -- running
    def start(self):
        h = self.h
        rcvr = h.slot(self.specials, SP_START_RCVR)
        sel = h.slot(self.specials, SP_START_SEL)
        return self.run_send(rcvr, sel, [])

    def run_send(self, rcvr, sel, args):
        m = self.lookup(self.class_index(rcvr), sel)
        if not m: raise StError('the start method is missing')
        bottom = Frame()
        bottom.stack = []; bottom.sender = None; bottom.serial = 0; bottom.flags = 0
        bottom.method = 0; bottom.temps = []; bottom.self_ = 0; bottom.rcvr = 0
        bottom.bc = bytes([0x7F]); bottom.ip = 0; bottom.lits = []; bottom.hdr = 0
        self.bottom = bottom
        bottom.stack.append(rcvr); bottom.stack.extend(args)
        self.frame = bottom
        try:
            self.send(sel, len(args), None)
            self.interpret()
        except Quit as q:
            return q.code
        return 0

    def activate(self, m, nargs, closure=None):
        f0 = self.frame
        st = f0.stack
        hdr, lits, bc = self.code_info(m)
        if HDR_NARGS(hdr) != nargs: raise StError('wrong argument count')
        f = Frame()
        f.method = m; f.hdr = hdr; f.lits = lits; f.bc = bc; f.ip = 0
        args = st[len(st) - nargs:] if nargs else []
        rcvr = st[len(st) - nargs - 1]
        del st[len(st) - nargs - 1:]
        f.rcvr = rcvr
        ntemps = HDR_NTEMPS(hdr)
        if closure is not None:
            ncop = HDR_NCOPIED(hdr)
            copied = [self.h.slot(closure, 4 + i) for i in range(ncop)]
            f.temps = args + copied + [0] * (ntemps - ncop)
            f.self_ = self.h.slot(closure, 1)
            f.flags = FL_BLOCK
        else:
            f.temps = args + [0] * ntemps
            f.self_ = rcvr
            f.flags = 0
            p = HDR_PRIM(hdr)
            if p == 198: f.flags |= FL_ENSURE
            elif p == 199: f.flags |= FL_HANDLER
        f.stack = []
        f.sender = f0
        f.depth = getattr(f0, 'depth', 0) + 1
        self.serial += 1
        f.serial = self.serial
        self.frame = f
        if not self.serial & 255: self.depth_check()

    def depth_check(self):
        """Deeper than the VM's paged stack goes: Stratalk stackOverflow."""
        n = self.frame.depth
        if n < 10000: self.in_ovf = False
        if n > 20000 and not getattr(self, 'in_ovf', False):
            self.in_ovf = True
            st = self.frame.stack
            st.append(self.h.slot(self.specials, SP_START_RCVR))
            self.send(self.h.slot(self.specials, SP_OVERFLOW), 0, None)

    def send(self, sel, nargs, start_cls):
        self.sends += 1
        st = self.frame.stack
        rcvr = st[-1 - nargs]
        if start_cls is None:
            m = self.lookup(self.class_index(rcvr), sel)
        else:
            m = self.lookup_from(start_cls, sel) if start_cls else 0
        if not m:
            args = st[len(st) - nargs:] if nargs else []
            del st[len(st) - nargs:]
            msg = self.h.alloc(CI['Message'], F_FIXED, 2)
            self.h.setslot(msg, 0, sel)
            self.h.setslot(msg, 1, self.new_array(args))
            st.append(msg)
            dnu = self.h.slot(self.specials, SP_DNU)
            m = self.lookup(self.class_index(rcvr), dnu)
            if not m: raise StError('doesNotUnderstand: is missing')
            nargs = 1
        self.call(m, nargs)

    def call(self, m, nargs):
        hdr = self.code_info(m)[0]
        p = HDR_PRIM(hdr)
        if p and p < 198:
            r = self.primitive(p, nargs)
            if r is not None:
                st = self.frame.stack
                del st[len(st) - nargs - 1:]
                st.append(r)
                return
            if self.prim_done:
                self.prim_done = False
                return
        self.activate(m, nargs)

    def ret(self, value, frame):
        """frame returns value to its sender."""
        s = frame.sender
        if s is None: raise Quit(0)
        s.stack.append(value)
        self.frame = s
        if s is self.bottom: raise Quit(0)

    def find_frame(self, serial):
        f = self.frame
        while f is not None and f is not self.bottom:
            if f.serial == serial: return f
            f = f.sender
        return None

    def nonlocal_return(self, value):
        f = self.frame
        closure = f.rcvr
        home_serial = si_val(self.h.slot(closure, 3))
        home = self.find_frame(home_serial)
        if home is None or home.flags & FL_BLOCK:
            st = f.stack
            st.append(closure); st.append(value)
            self.send(self.h.slot(self.specials, SP_CANNOTRET), 1, None)
            return
        g = f
        while g is not home:
            if g.flags & (FL_ENSURE | FL_DONE) == FL_ENSURE:
                st = f.stack
                st.append(closure); st.append(value); st.append(si(home_serial))
                self.send(self.h.slot(self.specials, SP_UNWIND), 2, None)
                return
            g = g.sender
        self.ret(value, home)

    def interpret(self):
        h = self.h
        while True:
            f = self.frame
            bc = f.bc
            ip = f.ip
            op = bc[ip]
            self.bytecodes += 1
            st = f.stack
            if op < 16:
                f.ip = ip + 1
                if op == 0: st.append(f.self_)
                elif op == 1: st.append(0)
                elif op == 2: st.append(self.true)
                elif op == 3: st.append(self.false)
                elif op == 5: st.append(st[-1])
                elif op == 6: st.pop()
                elif op == 7:
                    v = st.pop()
                    if f.flags & FL_BLOCK: self.nonlocal_return(v)
                    else: self.ret(v, f)
                elif op == 8: self.ret(f.self_, f)
                elif op == 9: self.ret(st.pop(), f)
                elif op == 0x7F: raise Quit(0)
                else: raise StError('bad bytecode %d' % op)
                continue
            a = bc[ip + 1]
            if op < 27 or op == 30 or op == 34 or op == 38:
                f.ip = ip + 2
                if op == 16: st.append(h.slot(f.self_, a))
                elif op == 17: st.append(f.temps[a])
                elif op == 18: st.append(f.lits[a])
                elif op == 19: st.append(h.slot(f.lits[a], 1))
                elif op == 20: self.store_inst(f.self_, a, st[-1])
                elif op == 21: f.temps[a] = st[-1]
                elif op == 22: h.setslot(f.lits[a], 1, st[-1])
                elif op == 23: self.store_inst(f.self_, a, st.pop())
                elif op == 24: f.temps[a] = st.pop()
                elif op == 25: h.setslot(f.lits[a], 1, st.pop())
                elif op == 26: st.append(si(a - 256 if a > 127 else a))
                elif op == 30:
                    items = st[len(st) - a:] if a else []
                    del st[len(st) - a:]
                    st.append(self.new_array(items))
                elif op == 34: self.send_special(a, f)
                elif op == 38: st.append(h.alloc(CI['Array'], F_INDEX, a))
                continue
            b = bc[ip + 2]
            f.ip = ip + 3
            if op == 27: st.append(h.slot(f.temps[b], a))
            elif op == 28: h.setslot(f.temps[b], a, st[-1])
            elif op == 29: h.setslot(f.temps[b], a, st.pop())
            elif op == 31:
                blk = f.lits[a]
                c = h.alloc(CI['BlockClosure'], F_FIXED, 4 + b)
                for i in range(b): h.setslot(c, 4 + b - 1 - i, st.pop())
                home = f
                if f.flags & FL_BLOCK:
                    hs = si_val(h.slot(f.rcvr, 3))
                else:
                    hs = f.serial
                h.setslot(c, 0, blk); h.setslot(c, 1, f.self_)
                h.setslot(c, 2, si(hs)); h.setslot(c, 3, si(hs))
                st.append(c)
            elif op == 32: self.send(f.lits[a], b, None)
            elif op == 33:
                mc = f.lits[-1]
                self.send(f.lits[a], b, h.slot(mc, B_SUPER))
            elif op in (35, 36, 37):
                off = (a << 8) | b
                if off >= 32768: off -= 65536
                if op == 35: f.ip += off
                else:
                    v = st.pop()
                    if v == self.true:
                        if op == 36: f.ip += off
                    elif v == self.false:
                        if op == 37: f.ip += off
                    else:
                        st.append(v)
                        f.ip = ip
                        self.send(h.slot(self.specials, SP_MUSTBOOL), 0, None)
            else:
                raise StError('bad bytecode %d' % op)

    def store_inst(self, o, i, v):
        if self.h.hdr(o) & IMM_BIT: raise StError('store into an immutable object')
        self.h.setslot(o, i, v)

    def send_special(self, k, f):
        st = f.stack
        if k <= 14:
            b, a = st[-1], st[-2]
            if a & b & 1:
                x, y = si_val(a), si_val(b)
                r = None
                if k == 0: r = x + y
                elif k == 1: r = x - y
                elif k == 2: r = self.bool(x < y)
                elif k == 3: r = self.bool(x > y)
                elif k == 4: r = self.bool(x <= y)
                elif k == 5: r = self.bool(x >= y)
                elif k == 6: r = self.bool(x == y)
                elif k == 7: r = self.bool(x != y)
                elif k == 8: r = x * y
                elif k == 9: r = x // y if y and x % y == 0 else None
                elif k == 10: r = x % y if y else None
                elif k == 11: r = x // y if y else None
                elif k == 12: r = x & y
                elif k == 13: r = x | y
                elif k == 14:
                    if y >= 0: r = x << y if y < 64 else None
                    else: r = x >> min(-y, 63)
                if r is not None:
                    if isinstance(r, int) and k in (0, 1, 8, 9, 10, 11, 12, 13, 14):
                        if SMALL_MIN <= r <= SMALL_MAX: r = si(r)
                        else: r = None
                    if r is not None:
                        st.pop(); st[-1] = r; return
        elif k == 15:
            b = st.pop(); st[-1] = self.bool(st[-1] == b); return
        elif k == 16:
            st[-1] = self.class_of(st[-1]); return
        elif k == 26:
            b = st.pop(); st[-1] = self.bool(st[-1] != b); return
        s, n = SPECIAL_SELECTORS[k]
        self.send(self.spsels[k], n, None)

    # -- primitives: return the result, or None when the primitive fails
    prim_done = False

    def primitive(self, p, nargs):
        st = self.frame.stack
        rcvr = st[-1 - nargs]
        args = st[len(st) - nargs:] if nargs else []
        h = self.h
        try:
            if p <= 18:
                if nargs != 1: return None
                a, b = rcvr, args[0]
                if not (a & b & 1): return None
                x, y = si_val(a), si_val(b)
                if p == 1: r = x + y
                elif p == 2: r = x - y
                elif p == 3: return self.bool(x < y)
                elif p == 4: return self.bool(x > y)
                elif p == 5: return self.bool(x <= y)
                elif p == 6: return self.bool(x >= y)
                elif p == 7: return self.bool(x == y)
                elif p == 8: return self.bool(x != y)
                elif p == 9: r = x * y
                elif p == 10:
                    if y == 0 or x % y: return None
                    r = x // y
                elif p == 11:
                    if y == 0: return None
                    r = x % y
                elif p == 12:
                    if y == 0: return None
                    r = x // y
                elif p == 13:
                    if y == 0: return None
                    r = abs(x) // abs(y) * (1 if (x < 0) == (y < 0) else -1)
                elif p == 14:
                    if y == 0: return None
                    r = x - (abs(x) // abs(y) * (1 if (x < 0) == (y < 0) else -1)) * y
                elif p == 15: r = x & y
                elif p == 16: r = x | y
                elif p == 17: r = x ^ y
                elif p == 18:
                    if y >= 0:
                        if y >= 64: return None
                        r = x << y
                    else: r = x >> min(-y, 63)
                if SMALL_MIN <= r <= SMALL_MAX: return si(r)
                return None
            if p == 19:
                if not rcvr & 1: return None
                return self.new_string(str(si_val(rcvr)).encode())
            if p == 30:
                if rcvr & 7 != 4: return None
                return si(rcvr >> 3)
            if p in (31, 32):
                v = args[0] if p == 31 else rcvr
                if not v & 1 or si_val(v) < 0: return None
                return ch(si_val(v))
            if p == 40: return self.bool(rcvr == args[0])
            if p == 41: return self.class_of(rcvr)
            if p == 42:
                if rcvr & 1: return rcvr
                if rcvr & 7 == 4: return si(rcvr >> 3)
                if rcvr == 0: return si(0)
                return si((h.hdr(rcvr) >> HASH_SHIFT) & HASH_MASK)
            if p == 43:
                if rcvr & 7 or rcvr == 0: return si(0)
                return si(self.indexable_size(rcvr))
            if p in (44, 45, 60, 61, 49, 50):
                return self.prim_at(p, rcvr, args)
            if p == 46:
                return self.instantiate(rcvr, 0)
            if p == 47 or p == 54:
                if not args[0] & 1 or si_val(args[0]) < 0: return None
                return self.instantiate(rcvr, si_val(args[0]))
            if p == 62: return self.instantiate(rcvr, 0)
            if p == 48:
                if rcvr & 7 or rcvr == 0: return rcvr
                n = h.nslots(rcvr)
                hdr = h.hdr(rcvr)
                o = h.alloc(hdr & 0xFFFF, (hdr >> FMT_SHIFT) & 15, n, (hdr >> PAD_SHIFT) & 7)
                h.mem[o + 8:o + 8 + 8 * n] = h.mem[rcvr + 8:rcvr + 8 + 8 * n]
                return o
            if p == 51:
                sel = args[0]
                st.pop(len(st) - nargs)            # take the selector out
                self.send(sel, nargs - 1, None)
                self.prim_done = True
                return None
            if p == 52:
                sel, arr = args
                if arr & 7 or arr == 0 or h.ci(arr) != CI['Array']: return None
                items = [h.slot(arr, i) for i in range(h.nslots(arr))]
                del st[len(st) - 2:]
                st.extend(items)
                self.send(sel, len(items), None)
                self.prim_done = True
                return None
            if p == 53: return self.false
            if p == 55:
                if rcvr & 7 or rcvr == 0: return self.true
                return self.bool(h.hdr(rcvr) & IMM_BIT)
            if p == 56:
                if not (rcvr & 7 or rcvr == 0): h.setword(rcvr, h.hdr(rcvr) | IMM_BIT)
                return rcvr
            if p == 111: return self.specials
            if p == 113: return rcvr
            if p == 114:
                self.out.flush()
                b = os.read(0, 512)
                return self.new_string(b) if b else 0
            if p == 115: return self.false
            if p == 112:
                m = args[0]
                if m & 7 or m == 0 or h.ci(m) != CI['CompiledMethod']: return None
                if HDR_NARGS(self.code_info(m)[0]) != 0: return None
                st.pop()
                self.activate(m, 0)
                self.prim_done = True
                return None
            if p == 57: return self.prim_replace(rcvr, args)
            if p == 58:
                b = args[0]
                if b & 7 or b == 0 or h.fmt(b) != F_BYTES: return self.false
                return self.bool(h.bytes_of(rcvr) == h.bytes_of(b))
            if p == 59: return si(strhash(h.bytes_of(rcvr)))
            if p == 63:
                b = args[0]
                if b & 7 or b == 0 or h.fmt(b) != F_BYTES: return None
                x, y = h.bytes_of(rcvr), h.bytes_of(b)
                return si(-1 if x < y else (1 if x > y else 0))
            if p == 70:
                return self.prim_value(rcvr, nargs)
            if p == 71:
                arr = args[0]
                if arr & 7 or arr == 0 or h.ci(arr) != CI['Array']: return None
                items = [h.slot(arr, i) for i in range(h.nslots(arr))]
                hdr = self.code_info(h.slot(rcvr, 0))[0]
                if HDR_NARGS(hdr) != len(items): return None
                st.pop(); st.extend(items)
                self.prim_value(rcvr, len(items))
                return None
            if p == 75: return h.slot(rcvr, 0)
            if p == 76:
                i = si_val(args[0])
                hdr = si_val(h.slot(rcvr, 0))
                if not 1 <= i <= HDR_NLITS(hdr): return None
                return h.slot(rcvr, i)
            if p == 77 or p == 81:
                i = si_val(args[0])
                hdr = si_val(h.slot(rcvr, 0))
                start = rcvr + 8 + 8 * (1 + HDR_NLITS(hdr))
                n = rcvr + 8 + h.nbytes(rcvr) - start
                if not 1 <= i <= n: return None
                if p == 77: return si(h.mem[start + i - 1])
                v = si_val(args[1])
                if not 0 <= v <= 255: return None
                h.mem[start + i - 1] = v
                self.mcache.pop(rcvr, None)
                return args[1]
            if p == 78:
                hdr = si_val(h.slot(rcvr, 0))
                return si(h.nbytes(rcvr) - 8 * (1 + HDR_NLITS(hdr)))
            if p == 79:
                hdr, nb = si_val(args[0]), si_val(args[1])
                nl = HDR_NLITS(hdr)
                ci = si_val(h.slot(rcvr, B_INDEX))
                nw = 1 + nl + (nb + 7) // 8
                m = h.alloc(ci, F_METHOD, nw, (8 - nb % 8) % 8)
                h.setslot(m, 0, args[0])
                return m
            if p == 80:
                i = si_val(args[0])
                hdr = si_val(h.slot(rcvr, 0))
                if not 1 <= i <= HDR_NLITS(hdr): return None
                h.setslot(rcvr, i, args[1])
                self.mcache.pop(rcvr, None)
                return args[1]
            if 90 <= p <= 99: return self.prim_frame(p, args)
            if p == 100 or p == 110:
                b = args[0]
                if b & 7 or b == 0 or h.fmt(b) != F_BYTES: return None
                self.out.flush()
                (sys.stderr.buffer if p == 110 else self.out).write(h.bytes_of(b))
                if p == 110: sys.stderr.buffer.flush()
                return rcvr
            if p == 101:
                self.out.flush()
                line = self.stdin.readline()
                if not line: return 0
                return self.new_string(line.rstrip(b'\n'))
            if p == 102:
                self.out.flush()
                raise Quit(si_val(args[0]))
            if p == 103:
                return self.new_array([self.new_string(a.encode()) for a in self.args])
            if p == 104:
                self.lcache.clear(); self.mcache.clear(); return rcvr
            if p == 105:
                return self.new_array([si(self.sends), si(self.bytecodes), si(h.used)] + [si(0)] * 13)
            if p in (106, 107): return rcvr
            if p == 108:
                b = h.bytes_of(args[0]).decode()
                h.setword(8, h.used)
                with open(b, 'wb') as fp: fp.write(h.mem[:h.used])
                return rcvr
            if p == 109: return si(int(time.monotonic() * 1000))
            if p == 116: return self.prim_ossend(args)
            if p == 119: return self.new_array([si(self.reply_words[0]), si(self.reply_words[1]), si(self.reply_words[2])])
            return None
        except (IndexError, TypeError) as e:
            return None

    def indexable_size(self, o):
        h = self.h
        f = h.fmt(o)
        if f == F_INDEX:
            cls = self.class_of(o)
            return h.nslots(o) - (si_val(h.slot(cls, B_FORMAT)) & 0xFFFF)
        if f == F_BYTES: return h.nbytes(o)
        if f == F_WORDS: return h.nslots(o)
        if f == F_METHOD: return 0
        return 0

    def prim_at(self, p, rcvr, args):
        h = self.h
        if rcvr & 7 or rcvr == 0: return None
        if not args[0] & 1: return None
        i = si_val(args[0])
        f = h.fmt(rcvr)
        hdr = h.hdr(rcvr)
        if p in (49, 50):
            n = si_val(h.slot(self.class_of(rcvr), B_FORMAT)) & 0xFFFF
            if f in (F_FIXED, F_INDEX) and 1 <= i <= h.nslots(rcvr):
                if p == 49: return h.slot(rcvr, i - 1)
                if hdr & IMM_BIT: return None
                h.setslot(rcvr, i - 1, args[1]); return args[1]
            return None
        put = p in (45, 61)
        if put and hdr & IMM_BIT: return None
        if f == F_INDEX:
            fixed = si_val(h.slot(self.class_of(rcvr), B_FORMAT)) & 0xFFFF
            if not 1 <= i <= h.nslots(rcvr) - fixed: return None
            if put: h.setslot(rcvr, fixed + i - 1, args[1]); return args[1]
            return h.slot(rcvr, fixed + i - 1)
        if f == F_BYTES:
            if not 1 <= i <= h.nbytes(rcvr): return None
            a = rcvr + 8 + i - 1
            if p in (60, 61):
                if put:
                    v = args[1]
                    if v & 7 != 4 or v >> 3 > 255: return None
                    h.mem[a] = v >> 3; return v
                return ch(h.mem[a])
            if put:
                v = args[1]
                if not v & 1 or not 0 <= si_val(v) <= 255: return None
                h.mem[a] = si_val(v); return v
            return si(h.mem[a])
        if f == F_WORDS:
            if not 1 <= i <= h.nslots(rcvr): return None
            if put:
                v = args[1]
                if not v & 1: return None
                h.setslot(rcvr, i - 1, si_val(v)); return v
            v = h.slot(rcvr, i - 1)
            if v >= 1 << 63: v -= 1 << 64
            if not SMALL_MIN <= v <= SMALL_MAX: return None
            return si(v)
        return None

    def prim_replace(self, rcvr, args):
        h = self.h
        start, stop, src, sstart = args
        if not (start & stop & sstart & 1): return None
        start, stop, sstart = si_val(start), si_val(stop), si_val(sstart)
        if rcvr & 7 or src & 7 or rcvr == 0 or src == 0: return None
        f, g = h.fmt(rcvr), h.fmt(src)
        if f != g or h.hdr(rcvr) & IMM_BIT: return None
        n = stop - start + 1
        if n <= 0: return rcvr
        if f == F_BYTES:
            if start < 1 or stop > h.nbytes(rcvr) or sstart < 1 or sstart + n - 1 > h.nbytes(src): return None
            d, s = rcvr + 8 + start - 1, src + 8 + sstart - 1
            h.mem[d:d + n] = bytes(h.mem[s:s + n])
            return rcvr
        if f in (F_INDEX, F_WORDS):
            fd = si_val(h.slot(self.class_of(rcvr), B_FORMAT)) & 0xFFFF if f == F_INDEX else 0
            fs = si_val(h.slot(self.class_of(src), B_FORMAT)) & 0xFFFF if g == F_INDEX else 0
            if start < 1 or stop > h.nslots(rcvr) - fd or sstart < 1 or sstart + n - 1 > h.nslots(src) - fs:
                return None
            d, s = rcvr + 8 + 8 * (fd + start - 1), src + 8 + 8 * (fs + sstart - 1)
            h.mem[d:d + 8 * n] = bytes(h.mem[s:s + 8 * n])
            return rcvr
        return None

    def prim_value(self, closure, nargs):
        h = self.h
        if closure & 7 or closure == 0 or h.ci(closure) != CI['BlockClosure']: return None
        blk = h.slot(closure, 0)
        hdr = self.code_info(blk)[0]
        if HDR_NARGS(hdr) != nargs: return None
        self.activate(blk, nargs, closure)
        self.prim_done = True
        return None

    def prim_frame(self, p, args):
        h = self.h
        def fr(o):
            f = self.find_frame(si_val(o))
            if f is None: raise IndexError
            return f
        if p == 90: return si(self.frame.serial)
        if p == 91:
            s = fr(args[0]).sender
            return si(0 if s is None or s is self.bottom else s.serial)
        if p == 92: return fr(args[0]).method
        if p == 93: return fr(args[0]).self_
        if p == 94:
            f = fr(args[1]); i = si_val(args[0])
            if not 1 <= i <= len(f.temps): return None
            return f.temps[i - 1]
        if p == 95: return si(fr(args[0]).flags)
        if p == 96:
            f = fr(args[1]); f.flags = si_val(args[0]); return args[0]
        if p == 97:
            v, f = args[0], fr(args[1])
            self.ret(v, f)
            self.prim_done = True
            return None
        if p == 98:
            f = fr(args[0])
            hdr = f.hdr
            nargs = HDR_NARGS(hdr)
            f.ip = 0
            f.stack = []
            if f.flags & FL_BLOCK:
                ncop = HDR_NCOPIED(hdr)
                f.temps = f.temps[:nargs + ncop] + [0] * (HDR_NTEMPS(hdr) - ncop)
            else:
                f.temps = f.temps[:nargs] + [0] * HDR_NTEMPS(hdr)
            f.flags &= ~(FL_DONE | FL_DISABLED)
            self.frame = f
            self.prim_done = True
            return None
        if p == 99:
            c = args[0]
            s = si_val(h.slot(c, 3))
            f = self.find_frame(s)
            return si(s if f is not None and not f.flags & FL_BLOCK else 0)
        return None

    reply_words = (0, 0, 0)

    def prim_ossend(self, args):
        """Smalltalk osSend: on the host: fs's file messages (register 2) on
        host files; anything else answers -4 (no such server)."""
        h = self.h
        reg, op, handle, length, mode, server, data, reply = args
        reg, op, handle, mode = si_val(reg), si_val(op), si_val(handle), si_val(mode)
        bdata = h.bytes_of(data) if data else b''
        n = si_val(length) if length & 1 else len(bdata)
        if not hasattr(self, 'files'): self.files = {}
        out = b''
        self.reply_words = (0, 0, 0)
        if reg != 2: return si(-4)
        if op == 3:
            name = bdata.decode()
            try: fp = open(name, ['rb', 'wb', 'ab'][mode])
            except OSError: return si(-4)
            k = 1
            while k in self.files: k += 1
            self.files[k] = fp
            r = k
        elif op == 1:
            fp = self.files.get(handle)
            if fp is None: return si(-1)
            out = fp.read(min(n, 1024)); r = len(out)
        elif op == 2:
            fp = self.files.get(handle)
            if fp is None: return si(-1)
            fp.write(bdata); r = len(bdata)
        elif op == 4:
            fp = self.files.pop(handle, None)
            if fp: fp.close()
            r = 0
        elif op == 27:
            try: r = os.path.getsize(bdata.decode())
            except OSError: r = -4
        elif op == 11:
            try: os.unlink(bdata.decode()); r = 0
            except OSError: r = -4
        else:
            return si(-1)
        if reply and out:
            h.mem[reply + 8:reply + 8 + len(out)] = out
        self.reply_words = (handle, len(out), mode)
        return si(r)

    def prim_file(self, p, rcvr, args):
        h = self.h
        if not hasattr(self, 'files'): self.files = {}
        if p == 120:
            name = h.bytes_of(args[0]).decode(); mode = si_val(args[1])
            try:
                fp = open(name, ['rb', 'wb', 'ab'][mode])
            except OSError:
                return si(-4)
            k = 3
            while k in self.files: k += 1
            self.files[k] = fp
            return si(k)
        if p == 121:
            fp = self.files.get(si_val(args[0]))
            if fp is None: return si(-1)
            buf = args[1]
            n = min(si_val(args[2]), h.nbytes(buf))
            d = fp.read(n)
            h.mem[buf + 8:buf + 8 + len(d)] = d
            return si(len(d))
        if p == 122:
            k = si_val(args[0])
            buf = args[1]; n = si_val(args[2])
            if k in (1, 2):
                (self.out if k == 1 else sys.stderr.buffer).write(h.bytes_of(buf)[:n]); return si(n)
            fp = self.files.get(k)
            if fp is None: return si(-1)
            fp.write(h.bytes_of(buf)[:n])
            return si(n)
        if p == 123:
            fp = self.files.pop(si_val(args[0]), None)
            if fp: fp.close()
            return si(0)
        if p == 124:
            try: return si(os.path.getsize(h.bytes_of(args[0]).decode()))
            except OSError: return si(-4)
        if p == 125:
            try: os.unlink(h.bytes_of(args[0]).decode()); return si(0)
            except OSError: return si(-4)
        return None


# ---- the command line --------------------------------------------------------------------
def load_image(path):
    data = open(path, 'rb').read()
    h = Heap(max(64 << 20, len(data) * 2))
    h.mem[:len(data)] = data
    if h.word(0) != MAGIC: raise StError('%s: not an image' % path)
    h.used = h.word(8)
    return h


def run_doits(b, h):
    """The file's statements, in order, in the image being built."""
    for path, line, node in b.doits:
        m = stc.MethodNode('DoIt', [], [], 0, [stc.Return(node)], line)
        try:
            code = stc.Compiler([], 'UndefinedObject').compile(m)
        except CompileError as e:
            raise CompileError('%s:%d: %s' % (path, line, e))
        mo = b.method(code, b.classes['UndefinedObject'].oop)
        vm = VM(h)
        bottom_run(vm, mo)


def bottom_run(vm, method):
    f = Frame()
    f.stack = [0]; f.sender = None; f.serial = 0; f.flags = 0; f.method = 0
    f.temps = []; f.self_ = 0; f.rcvr = 0; f.bc = bytes([0x7F]); f.ip = 0; f.lits = []; f.hdr = 0
    vm.bottom = f
    vm.frame = f
    try:
        vm.call(method, 0)
        vm.interpret()
    except Quit:
        pass


def send_value(vm, rcvr, sel, args):
    """rcvr sel args, run to the end in vm; its result."""
    f = Frame()
    f.stack = [rcvr] + list(args); f.sender = None; f.serial = 0; f.flags = 0; f.method = 0
    f.temps = []; f.self_ = 0; f.rcvr = 0; f.bc = bytes([0x7F]); f.ip = 0; f.lits = []; f.hdr = 0
    vm.bottom = f
    vm.frame = f
    try:
        vm.send(sel, len(args), None)
        vm.interpret()
    except Quit:
        pass
    return f.stack[-1]


def same_literal(h, v, o, cls_oop, where):
    if v is NIL: return o == 0
    if v is TRUE or v is FALSE: return o != 0 and o & 7 == 0 and h.ci(o) == (CI['True'] if v is TRUE else CI['False'])
    if isinstance(v, int):
        if SMALL_MIN <= v <= SMALL_MAX: return o == si(v)
        m = abs(v); b = bytearray()
        while m: b.append(m & 255); m >>= 8
        return o & 7 == 0 and o and h.bytes_of(o) == bytes(b)
    if isinstance(v, Char): return o == ch(v.c)
    if isinstance(v, Sym): return o & 7 == 0 and o and h.ci(o) == CI['Symbol'] and h.bytes_of(o) == v.s.encode()
    if isinstance(v, Str): return o & 7 == 0 and o and h.ci(o) == CI['String'] and h.bytes_of(o) == v.s.encode()
    if isinstance(v, ByteArr): return o & 7 == 0 and o and h.ci(o) == CI['ByteArray'] and h.bytes_of(o) == v.b
    if isinstance(v, LitArray):
        if o & 7 or not o or h.ci(o) != CI['Array'] or h.nslots(o) != len(v.items): return False
        return all(same_literal(h, x, h.slot(o, i), cls_oop, where) for i, x in enumerate(v.items))
    if isinstance(v, Global):
        return o & 7 == 0 and o and h.ci(o) == CI['Association'] and h.bytes_of(h.slot(o, 0)) == v.name.encode()
    if isinstance(v, ClassRef): return o == cls_oop
    if isinstance(v, Code): return same_code(h, v, o, cls_oop, where)
    return False


def same_code(h, code, m, cls_oop, where):
    if m & 7 or not m or h.fmt(m) != F_METHOD:
        print('%s: no method came back' % where); return False
    hdr = si_val(h.slot(m, 0))
    nl = HDR_NLITS(hdr)
    start = m + 8 + 8 * (1 + nl)
    bc = bytes(h.mem[start:m + 8 + h.nbytes(m)])
    ok = True
    if hdr != code.header():
        print('%s: header %x, the host has %x' % (where, hdr, code.header())); ok = False
    if bc != code.bytes:
        print('%s: bytecodes differ\n  image: %s\n  host:  %s' % (where, bc.hex(), code.bytes.hex())); ok = False
    if ok:
        for i, v in enumerate(code.lits):
            if not same_literal(h, v, h.slot(m, 1 + i), cls_oop, where):
                print('%s: literal %d differs (%r)' % (where, i + 1, v)); ok = False
    return ok


def check(image, files):
    """Compile every method of files with the image's compiler and with this
    one; the two must give the same methods."""
    h = load_image(image)
    vm = VM(h)
    b = Builder()
    for f in files:
        if f.endswith('.st'): b.read(f)
        else: b.load(f)
    smalltalk = h.slot(vm.specials, SP_SMALLTALK)
    def global_value(name):
        arr = h.slot(smalltalk, 1)
        n = h.nslots(arr)
        for i in range(n):
            a = h.slot(arr, i)
            if a and h.bytes_of(h.slot(a, 0)) == name.encode(): return h.slot(a, 1)
        return 0
    compiler_cls = global_value('Compiler')
    sel = None
    for k, v in list(vm.__dict__.items()): pass
    syms = {}
    def symbol(name):
        tab = h.slot(vm.specials, SP_SYMBOLS)
        for i in range(h.nslots(tab)):
            o = h.slot(tab, i)
            if o and h.bytes_of(o) == name.encode(): return o
        raise StError('no symbol %s' % name)
    sel = symbol('compileSource:in:')
    bad = n = 0
    for cd in b.order:
        cls = global_value(cd.name)
        for meta, m, path in cd.methods:
            target = h.word(cls) & 0xFFFF and h.slot(vm.classes, h.word(cls) & 0xFFFF) if meta else cls
            ivars = (b.all_ivars(b.classes['Class']) + b.all_cslots(cd)) if meta else b.all_ivars(cd)
            code = stc.Compiler(ivars, cd.name).compile(m)
            comp = vm.instantiate(compiler_cls, 0)
            src = vm.new_string(m.source.encode('utf-8'))
            where = '%s%s>>%s' % (cd.name, ' class' if meta else '', m.sel)
            try:
                o = send_value(vm, comp, sel, [src, target])
            except StError as e:
                print('%s: %s' % (where, e)); bad += 1; continue
            n += 1
            if not same_code(h, code, o, target, where): bad += 1
    print('%d methods compiled by both, %d differ' % (n, bad))
    return 1 if bad else 0


def main(argv):
    if len(argv) < 2:
        print(__doc__ or 'usage: stratalk.py build|run|dis ...'); return 2
    cmd = argv[1]
    if cmd == 'build':
        i = argv.index('-o')
        out = argv[i + 1]
        b = Builder()
        try:
            for f in argv[2:i] + argv[i + 2:]:
                if f.endswith('.st'): b.read(f)
                else: b.load(f)
            b.build()
        except CompileError as e:
            print('stratalk: %s' % e, file=sys.stderr); return 1
        h = b.h
        try:
            run_doits(b, h)
        except (CompileError, StError) as e:
            print('stratalk: %s' % e, file=sys.stderr); return 1
        h.setword(8, h.used)
        with open(out, 'wb') as fp: fp.write(h.mem[:h.used])
        return 0
    if cmd == 'run':
        h = load_image(argv[2])
        vm = VM(h, argv[3:])
        if os.environ.get('STRATALK_WATCH'):
            import signal
            def dump(*a):
                f = vm.frame
                while f is not None and f is not vm.bottom:
                    m = f.method
                    nl = HDR_NLITS(si_val(h.slot(m, 0)))
                    sel = h.slot(m, nl - 1) if not f.flags & FL_BLOCK else 0
                    cls = h.slot(m, nl)
                    try: name = h.bytes_of(sel).decode() if sel else '[]'
                    except Exception: name = '?'
                    print('  %s ip %d' % (name, f.ip), file=sys.stderr)
                    f = f.sender
                os._exit(9)
            signal.signal(signal.SIGALRM, dump)
            signal.alarm(int(os.environ['STRATALK_WATCH']))
        try:
            code = vm.start()
        except StError as e:
            vm.out.flush()
            print('stratalk: %s' % e, file=sys.stderr); return 3
        vm.out.flush()
        return code
    if cmd == 'check':
        return check(argv[2], argv[3:])
    if cmd == 'dis':
        h = load_image(argv[2])
        vm = VM(h)
        cname, sel = argv[3], argv[4]
        meta = cname.endswith(' class')
        for ci in range(CLASS_TABLE_SIZE):
            c = h.slot(vm.classes, ci)
            if not c or h.ci(c) == CI['Metaclass'] if 'Metaclass' in CI else False: continue
        print('(not implemented)')
        return 0
    print('unknown command %s' % cmd); return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
