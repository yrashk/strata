#!/usr/bin/env python3
# stc.py: the Stratalk compiler on the host (the bootstrap compiler).
#
# Reads Stratalk source (the file syntax of lang/stratalk/README.md) and
# compiles methods to the bytecodes of the VM (lang/stratalk/vm.s). The
# compiler in the image (lang/stratalk/kernel/Compiler.st) follows this one
# step by step and must give the same bytes: `stratalk.py check` compares
# them.

# ---- bytecodes ------------------------------------------------------------------
PUSH_SELF, PUSH_NIL, PUSH_TRUE, PUSH_FALSE = 0, 1, 2, 3
DUP, POP, RET_TOP, RET_SELF, BLK_RET = 5, 6, 7, 8, 9
PUSH_INST, PUSH_TEMP, PUSH_LIT, PUSH_LITVAR = 16, 17, 18, 19
STORE_INST, STORE_TEMP, STORE_LITVAR = 20, 21, 22
POPST_INST, POPST_TEMP, POPST_LITVAR = 23, 24, 25
PUSH_INT8, PUSH_TVEC, STORE_TVEC, POPST_TVEC = 26, 27, 28, 29
PUSH_ARRAY, PUSH_CLOSURE, SEND, SUPER, SEND_SP = 30, 31, 32, 33, 34
JUMP, JUMP_T, JUMP_F, PUSH_VEC = 35, 36, 37, 38

OPNAMES = {0: 'pushSelf', 1: 'pushNil', 2: 'pushTrue', 3: 'pushFalse', 5: 'dup',
           6: 'pop', 7: 'returnTop', 8: 'returnSelf', 9: 'blockReturn',
           16: 'pushInst', 17: 'pushTemp', 18: 'pushLit', 19: 'pushLitVar',
           20: 'storeInst', 21: 'storeTemp', 22: 'storeLitVar', 23: 'popStoreInst',
           24: 'popStoreTemp', 25: 'popStoreLitVar', 26: 'pushInt8', 27: 'pushTempInVector',
           28: 'storeTempInVector', 29: 'popStoreTempInVector', 30: 'pushArray',
           31: 'pushClosure', 32: 'send', 33: 'superSend', 34: 'sendSpecial',
           35: 'jump', 36: 'jumpTrue', 37: 'jumpFalse', 38: 'pushNewVector'}


def oplen(op):
    if op < 16:
        return 1
    if op in (27, 28, 29, 31, 32, 33, 35, 36, 37):
        return 3
    return 2


# The special selectors: sendSpecial k. The VM does the SmallInteger cases,
# == and class itself, and sends the rest.
SPECIAL_SELECTORS = [('+', 1), ('-', 1), ('<', 1), ('>', 1), ('<=', 1), ('>=', 1),
                     ('=', 1), ('~=', 1), ('*', 1), ('/', 1), ('\\\\', 1), ('//', 1),
                     ('bitAnd:', 1), ('bitOr:', 1), ('bitShift:', 1), ('==', 1),
                     ('class', 0), ('at:', 1), ('at:put:', 2), ('size', 0), ('value', 0),
                     ('value:', 1), ('isNil', 0), ('notNil', 0), ('new', 0), ('new:', 1),
                     ('~~', 1)]
SPECIAL_INDEX = {s: i for i, (s, n) in enumerate(SPECIAL_SELECTORS)}


class CompileError(Exception):
    pass


# ---- literal values ---------------------------------------------------------------
class Sym:
    __slots__ = ('s',)
    def __init__(self, s): self.s = s
    def __eq__(self, o): return isinstance(o, Sym) and o.s == self.s
    def __hash__(self): return hash(('sym', self.s))
    def __repr__(self): return '#' + self.s


class Str:
    __slots__ = ('s',)
    def __init__(self, s): self.s = s
    def __eq__(self, o): return isinstance(o, Str) and o.s == self.s
    def __hash__(self): return hash(('str', self.s))
    def __repr__(self): return repr(self.s)


class Char:
    __slots__ = ('c',)
    def __init__(self, c): self.c = c
    def __eq__(self, o): return isinstance(o, Char) and o.c == self.c
    def __hash__(self): return hash(('char', self.c))


class Special:
    __slots__ = ('name',)
    def __init__(self, n): self.name = n
    def __repr__(self): return self.name


NIL, TRUE, FALSE = Special('nil'), Special('true'), Special('false')


class LitArray:
    __slots__ = ('items',)
    def __init__(self, items): self.items = items


class ByteArr:
    __slots__ = ('b',)
    def __init__(self, b): self.b = bytes(b)


class Global:            # an association of Smalltalk's globals
    __slots__ = ('name',)
    def __init__(self, n): self.name = n


class ClassRef:          # the class a method belongs to (the last literal)
    __slots__ = ('cls',)
    def __init__(self, c): self.cls = c


def lit_key(v):
    """The key under which a literal is shared within one method."""
    if isinstance(v, int) and not isinstance(v, bool):
        return ('int', v)
    if isinstance(v, Sym):
        return ('sym', v.s)
    if isinstance(v, Str):
        return ('str', v.s)
    if isinstance(v, Char):
        return ('char', v.c)
    if isinstance(v, Global):
        return ('global', v.name)
    if isinstance(v, Special):
        return ('special', v.name)
    return None          # arrays, byte arrays, blocks: never shared


# ---- the scanner ------------------------------------------------------------------
BINCHARS = '+-*/\\<>=~@%|&?,'
OPERAND_END = ('ident', 'int', 'char', 'str', 'sym', ')', ']', '}')


class Tok:
    __slots__ = ('kind', 'val', 'pos', 'end', 'line')
    def __init__(self, kind, val, pos, end, line):
        self.kind, self.val, self.pos, self.end, self.line = kind, val, pos, end, line
    def __repr__(self): return '%s:%r' % (self.kind, self.val)


def is_letter(c):
    return c.isalpha() or c == '_'


def scan(src):
    toks = []
    i, n, line = 0, len(src), 1
    def err(msg):
        raise CompileError('line %d: %s' % (line, msg))
    while True:
        while i < n:
            c = src[i]
            if c == '\n':
                line += 1; i += 1
            elif c in ' \t\r\f':
                i += 1
            elif c == '"':
                j = src.find('"', i + 1)
                if j < 0: err('comment without end')
                line += src.count('\n', i, j); i = j + 1
            else:
                break
        if i >= n:
            toks.append(Tok('eof', None, i, i, line)); return toks
        c, s = src[i], i
        last = toks[-1].kind if toks else None
        if is_letter(c):
            j = i
            while j < n and (is_letter(src[j]) or src[j].isdigit()): j += 1
            if j < n and src[j] == ':' and (j + 1 >= n or src[j + 1] != '='):
                toks.append(Tok('kw', src[i:j + 1], s, j + 1, line)); i = j + 1
            else:
                toks.append(Tok('ident', src[i:j], s, j, line)); i = j
        elif c.isdigit() or (c == '-' and i + 1 < n and src[i + 1].isdigit() and last not in OPERAND_END):
            neg = c == '-'
            if neg: i += 1
            j = i
            while j < n and src[j].isdigit(): j += 1
            v = int(src[i:j])
            if j < n and src[j] == 'r':
                base = v; k = j + 1
                while k < n and (src[k].isdigit() or 'A' <= src[k] <= 'Z'): k += 1
                if k == j + 1: err('digits expected after the radix')
                v = int(src[j + 1:k], base); j = k
            elif j + 1 < n and src[j] == '.' and src[j + 1].isdigit():
                err('floating point numbers are not supported')
            if neg: v = -v
            toks.append(Tok('int', v, s, j, line)); i = j
        elif c == '$':
            if i + 1 >= n: err('character expected after $')
            ch = src[i + 1]
            toks.append(Tok('char', ord(ch), s, i + 2, line)); i += 2
        elif c == "'":
            j = i + 1; out = []
            while True:
                if j >= n: err('string without end')
                if src[j] == "'":
                    if j + 1 < n and src[j + 1] == "'": out.append("'"); j += 2; continue
                    break
                if src[j] == '\n': line += 1
                out.append(src[j]); j += 1
            toks.append(Tok('str', ''.join(out), s, j + 1, line)); i = j + 1
        elif c == '#':
            if i + 1 < n and src[i + 1] == '(':
                toks.append(Tok('#(', None, s, i + 2, line)); i += 2
            elif i + 1 < n and src[i + 1] == '[':
                toks.append(Tok('#[', None, s, i + 2, line)); i += 2
            elif i + 1 < n and src[i + 1] == "'":
                t = scan_one_string(src, i + 1)
                toks.append(Tok('sym', t[0], s, t[1], line)); i = t[1]
            elif i + 1 < n and is_letter(src[i + 1]):
                j = i + 1
                while j < n and (is_letter(src[j]) or src[j].isdigit() or src[j] == ':'): j += 1
                toks.append(Tok('sym', src[i + 1:j], s, j, line)); i = j
            elif i + 1 < n and src[i + 1] in BINCHARS:
                j = i + 1
                while j < n and src[j] in BINCHARS: j += 1
                toks.append(Tok('sym', src[i + 1:j], s, j, line)); i = j
            else:
                err('bad literal after #')
        elif c == ':' and i + 1 < n and src[i + 1] == '=':
            toks.append(Tok(':=', None, s, i + 2, line)); i += 2
        elif c in '()[]{}.;^:':
            toks.append(Tok(c, None, s, i + 1, line)); i += 1
        elif c in BINCHARS:
            j = i
            while j < n and src[j] in BINCHARS:
                # a minus before digits after an operator is a negative number
                if j > i and src[j] == '-' and j + 1 < n and src[j + 1].isdigit(): break
                j += 1
            toks.append(Tok('bin', src[i:j], s, j, line)); i = j
        else:
            err('unexpected character %r' % c)


def scan_one_string(src, i):
    j = i + 1; out = []
    while True:
        if j >= len(src): raise CompileError('string without end')
        if src[j] == "'":
            if j + 1 < len(src) and src[j + 1] == "'": out.append("'"); j += 2; continue
            return ''.join(out), j + 1
        out.append(src[j]); j += 1


# ---- the syntax tree --------------------------------------------------------------
class Node:
    pass


class Lit(Node):
    def __init__(self, v): self.v = v


class Var(Node):
    def __init__(self, name, line=0): self.name, self.line = name, line


class Assign(Node):
    def __init__(self, name, value, line=0): self.name, self.value, self.line = name, value, line


class Send(Node):
    def __init__(self, rcvr, sel, args, line=0):
        self.rcvr, self.sel, self.args, self.line = rcvr, sel, args, line


class Cascade(Node):
    def __init__(self, rcvr, msgs): self.rcvr, self.msgs = rcvr, msgs


class Block(Node):
    def __init__(self, args, temps, stmts):
        self.args, self.temps, self.stmts = args, temps, stmts


class Brace(Node):
    def __init__(self, elems): self.elems = elems


class Return(Node):
    def __init__(self, expr): self.expr = expr


class MethodNode(Node):
    def __init__(self, sel, args, temps, prim, stmts, line):
        self.sel, self.args, self.temps, self.prim, self.stmts, self.line = sel, args, temps, prim, stmts, line


# ---- the parser -------------------------------------------------------------------
class Parser:
    def __init__(self, src):
        self.src = src
        self.toks = scan(src)
        self.i = 0

    def peek(self, k=0): return self.toks[min(self.i + k, len(self.toks) - 1)]
    def next(self):
        t = self.toks[self.i]; self.i += 1; return t
    def err(self, msg):
        raise CompileError('line %d: %s' % (self.peek().line, msg))
    def expect(self, kind):
        t = self.peek()
        if t.kind != kind: self.err('%s expected' % kind)
        return self.next()
    def at_bin(self, op): return self.peek().kind == 'bin' and self.peek().val == op

    # file items: class definitions, methods, statements
    def items(self):
        out = []
        while self.peek().kind != 'eof':
            if self.at_bin('|') or self.at_bin('||'):
                # variables of the file (or the session): they are globals
                out.append(('vars', self.temps()))
                continue
            if self.is_method_def():
                cls = self.next().val; meta = False
                if self.peek().kind == 'ident' and self.peek().val == 'class':
                    self.next(); meta = True
                self.next()   # >>
                m = self.method_def()
                p0, l0, l1, r0 = m.span
                m.source = self.src[p0:l0] + ' ' + self.src[l1:r0]
                out.append(('method', cls, meta, m))
            else:
                line = self.peek().line
                e = self.expression()
                if self.peek().kind == '.': self.next()
                elif self.peek().kind != 'eof': self.err('. expected')
                out.append(('expr', e, line))
        return out

    def is_method_def(self):
        t = self.peek()
        if t.kind != 'ident': return False
        k = 1
        if self.peek(1).kind == 'ident' and self.peek(1).val == 'class': k = 2
        return self.peek(k).kind == 'bin' and self.peek(k).val == '>>'

    def method_def(self):
        line = self.peek().line
        p0 = self.peek().pos
        sel, args = self.pattern()
        lb = self.peek()
        self.expect('[')
        temps, prim = [], 0
        for _ in range(2):
            if self.at_bin('|') or self.at_bin('||'): temps = self.temps()
            elif self.at_bin('<'): prim = self.pragma()
        stmts = self.statements(']')
        rb = self.expect(']')
        m = MethodNode(sel, args, temps, prim, stmts, line)
        m.span = (p0, lb.pos, lb.end, rb.pos)
        return m

    def method_source(self):
        """A method as typed: its pattern and body without brackets."""
        line = self.peek().line
        sel, args = self.pattern()
        temps, prim = [], 0
        for _ in range(2):
            if self.at_bin('|') or self.at_bin('||'): temps = self.temps()
            elif self.at_bin('<'): prim = self.pragma()
        stmts = self.statements('eof')
        return MethodNode(sel, args, temps, prim, stmts, line)

    def pattern(self):
        t = self.peek()
        if t.kind == 'ident':
            self.next(); return t.val, []
        if t.kind == 'bin':
            self.next(); return t.val, [self.expect('ident').val]
        if t.kind == 'kw':
            sel, args = '', []
            while self.peek().kind == 'kw':
                sel += self.next().val; args.append(self.expect('ident').val)
            return sel, args
        self.err('method pattern expected')

    def temps(self):
        if self.at_bin('||'): self.next(); return []
        self.next()
        out = []
        while self.peek().kind == 'ident': out.append(self.next().val)
        if not self.at_bin('|'): self.err('| expected')
        self.next()
        return out

    def pragma(self):
        self.next()
        t = self.expect('kw')
        if t.val != 'primitive:': self.err('only <primitive: N> is known')
        n = self.expect('int').val
        if not self.at_bin('>'): self.err('> expected')
        self.next()
        return n

    def statements(self, end):
        out = []
        while self.peek().kind != end:
            if self.peek().kind == '^':
                self.next(); out.append(Return(self.expression()))
            else:
                out.append(self.expression())
            if self.peek().kind == '.': self.next()
            elif self.peek().kind != end: self.err('. or %s expected' % end)
        return out

    def expression(self):
        t = self.peek()
        if t.kind == 'ident' and self.peek(1).kind == ':=':
            self.next(); self.next()
            return Assign(t.val, self.expression(), t.line)
        return self.cascade()

    def cascade(self):
        e = self.keyword_expr()
        if self.peek().kind != ';': return e
        if not isinstance(e, Send): self.err('cascade without a message')
        rcvr = e.rcvr; msgs = [(e.sel, e.args)]
        while self.peek().kind == ';':
            self.next()
            msgs.append(self.cascade_msg())
        return Cascade(rcvr, msgs)

    def cascade_msg(self):
        t = self.peek()
        if t.kind == 'ident':
            self.next(); m = (t.val, [])
            while self.peek().kind == 'ident':   # unary chain applies to the result: not allowed
                self.err('cascade part must be one message')
            return m
        if t.kind == 'bin':
            self.next(); return (t.val, [self.unary_expr()])
        if t.kind == 'kw':
            sel, args = '', []
            while self.peek().kind == 'kw':
                sel += self.next().val; args.append(self.binary_expr())
            return (sel, args)
        self.err('message expected')

    def keyword_expr(self):
        r = self.binary_expr()
        if self.peek().kind != 'kw': return r
        line = self.peek().line
        sel, args = '', []
        while self.peek().kind == 'kw':
            sel += self.next().val; args.append(self.binary_expr())
        return Send(r, sel, args, line)

    def binary_expr(self):
        r = self.unary_expr()
        while self.peek().kind == 'bin':
            t = self.next()
            r = Send(r, t.val, [self.unary_expr()], t.line)
        return r

    def unary_expr(self):
        r = self.primary()
        while self.peek().kind == 'ident' and self.peek(1).kind != ':=':
            t = self.next()
            r = Send(r, t.val, [], t.line)
        return r

    def primary(self):
        t = self.peek()
        k = t.kind
        if k == 'ident':
            self.next(); return Var(t.val, t.line)
        if k == 'int': self.next(); return Lit(t.val)
        if k == 'char': self.next(); return Lit(Char(t.val))
        if k == 'str': self.next(); return Lit(Str(t.val))
        if k == 'sym': self.next(); return Lit(Sym(t.val))
        if k == '#(': self.next(); return Lit(self.lit_array())
        if k == '#[': self.next(); return Lit(self.byte_array())
        if k == '(':
            self.next(); e = self.expression(); self.expect(')'); return e
        if k == '[': return self.block()
        if k == '{':
            self.next(); elems = []
            while self.peek().kind != '}':
                elems.append(self.expression())
                if self.peek().kind == '.': self.next()
                elif self.peek().kind != '}': self.err('. or } expected')
            self.next()
            return Brace(elems)
        self.err('expression expected')

    def block(self):
        self.expect('[')
        args = []
        while self.peek().kind == ':':
            self.next(); args.append(self.expect('ident').val)
        temps = []
        if args:
            if self.at_bin('||'):
                self.next()
                while self.peek().kind == 'ident': temps.append(self.next().val)
                if not self.at_bin('|'): self.err('| expected')
                self.next()
            elif self.at_bin('|'):
                self.next()
            else:
                self.err('| expected after the block arguments')
        if self.at_bin('|') or self.at_bin('||'): temps = self.temps()
        stmts = self.statements(']')
        self.expect(']')
        return Block(args, temps, stmts)

    def lit_array(self):
        items = []
        while True:
            t = self.peek()
            k = t.kind
            if k == ')': self.next(); return LitArray(items)
            if k == 'eof': self.err(') expected')
            self.next()
            if k == 'int': items.append(t.val)
            elif k == 'char': items.append(Char(t.val))
            elif k == 'str': items.append(Str(t.val))
            elif k == 'sym': items.append(Sym(t.val))
            elif k == 'ident':
                items.append({'nil': NIL, 'true': TRUE, 'false': FALSE}.get(t.val, None) or Sym(t.val))
            elif k == 'kw':
                s = t.val
                while self.peek().kind == 'kw' and self.peek().pos == t.end:
                    t = self.next(); s += t.val
                items.append(Sym(s))
            elif k == 'bin': items.append(Sym(t.val))
            elif k in ('(', '#('): items.append(self.lit_array())
            elif k == '#[': items.append(self.byte_array())
            else: self.err('literal expected')

    def byte_array(self):
        out = []
        while self.peek().kind == 'int':
            v = self.next().val
            if not 0 <= v <= 255: self.err('byte out of range')
            out.append(v)
        self.expect(']')
        return ByteArr(out)


# ---- variables and scopes --------------------------------------------------------------
class CVar:
    def __init__(self, name, kind, scope):
        self.name, self.kind, self.scope = name, kind, scope
        self.captured = self.assigned = self.remote = False
        self.vidx = -1           # index in the scope's temp vector (remote)
        self.origin = None       # the outer variable a copied one holds


class CScope:
    """A real scope: a method or a block that is not inlined."""
    def __init__(self, parent, is_block):
        self.parent, self.is_block = parent, is_block
        self.args, self.locals, self.remotes, self.copied = [], [], [], []
        self.vector = None
        self.lits, self.litmap, self.code = [], {}, []
        self.nlabels = 0

    def declare_local(self, name):
        v = CVar(name, 'temp', self); self.locals.append(v); return v

    def capture(self, v):
        """The copy of outer variable v in this scope."""
        for c in self.copied:
            if c.origin is v: return c
        c = CVar(v.name, 'copied', self); c.origin = v
        self.copied.append(c)
        return c

    def lit(self, v):
        k = lit_key(v)
        if k is not None and k in self.litmap: return self.litmap[k]
        self.lits.append(v)
        if k is not None: self.litmap[k] = len(self.lits) - 1
        if len(self.lits) > 255: raise CompileError('too many literals')
        return len(self.lits) - 1

    def label(self):
        self.nlabels += 1; return ('label', self.nlabels)


class Lex:
    """A lexical scope: a real scope or an inlined block within one."""
    def __init__(self, parent, real):
        self.parent, self.real, self.names = parent, real, {}

    def lookup(self, name):
        s = self
        while s:
            if name in s.names: return s.names[name]
            s = s.parent
        return None


INLINE_0 = ('ifTrue:', 'ifFalse:', 'and:', 'or:')


def is_block(n, nargs):
    return isinstance(n, Block) and len(n.args) == nargs


def inlined_args(send):
    """Which parts of a send are inlined blocks: a list of (node, nargs);
    None if the send is not inlined."""
    s, a, r = send.sel, send.args, send.rcvr
    if isinstance(r, Var) and r.name == 'super': return None
    if s in INLINE_0:
        return [(a[0], 0)] if is_block(a[0], 0) else None
    if s in ('ifTrue:ifFalse:', 'ifFalse:ifTrue:'):
        return [(a[0], 0), (a[1], 0)] if is_block(a[0], 0) and is_block(a[1], 0) else None
    if s in ('whileTrue:', 'whileFalse:'):
        return [(r, 0), (a[0], 0)] if is_block(r, 0) and is_block(a[0], 0) else None
    if s in ('whileTrue', 'whileFalse', 'repeat'):
        return [(r, 0)] if is_block(r, 0) else None
    if s == 'to:do:':
        return [(a[1], 1)] if is_block(a[1], 1) else None
    if s == 'to:by:do:':
        st = a[1]
        if isinstance(st, Lit) and isinstance(st.v, int) and not isinstance(st.v, bool) and st.v != 0 \
                and is_block(a[2], 1):
            return [(a[2], 1)]
        return None
    if s == 'ifNil:':
        return [(a[0], 0)] if is_block(a[0], 0) else None
    if s == 'ifNotNil:':
        return [(a[0], len(a[0].args))] if isinstance(a[0], Block) and len(a[0].args) <= 1 else None
    if s == 'ifNil:ifNotNil:':
        if is_block(a[0], 0) and isinstance(a[1], Block) and len(a[1].args) <= 1:
            return [(a[0], 0), (a[1], len(a[1].args))]
        return None
    if s == 'ifNotNil:ifNil:':
        if isinstance(a[0], Block) and len(a[0].args) <= 1 and is_block(a[1], 0):
            return [(a[0], len(a[0].args)), (a[1], 0)]
        return None
    return None


RESERVED = ('self', 'super', 'nil', 'true', 'false', 'thisContext')


class Code:
    """A compiled method or block, ready to be put into the image."""
    def __init__(self, nargs, ntemps, ncopied, prim, is_block, maxdepth, lits, code, sel=None):
        self.nargs, self.ntemps, self.ncopied, self.prim = nargs, ntemps, ncopied, prim
        self.is_block, self.maxdepth, self.lits, self.bytes, self.sel = is_block, maxdepth, lits, code, sel

    def header(self):
        return (self.nargs | self.ntemps << 8 | len(self.lits) << 16 | self.prim << 24 |
                self.ncopied << 36 | (1 if self.is_block else 0) << 44 | self.maxdepth << 45)


class Compiler:
    """Compiles one method of a class whose instance variables are ivars."""

    def __init__(self, ivars, cls=None):
        self.ivars, self.cls = ivars, cls
        self.analysis = {}        # id(node) -> what pass 1 decided

    def compile(self, m):
        if len(m.args) > 15: raise CompileError('too many arguments')
        scope = CScope(None, False)
        lex = Lex(None, scope)
        for a in m.args:
            if a in lex.names: raise CompileError('%s: argument declared twice' % a)
            v = CVar(a, 'arg', scope); scope.args.append(v); lex.names[a] = v
        for t in m.temps:
            if t in lex.names: raise CompileError('%s: declared twice' % t)
            lex.names[t] = scope.declare_local(t)
        self.scopes = [scope]
        self.an_stmts(m.stmts, lex)
        self.settle()
        # pass 2, over the same lexical scopes
        lex2 = lex
        self.begin(scope)
        for i, st in enumerate(m.stmts):
            if isinstance(st, Return):
                if isinstance(st.expr, Var) and st.expr.name == 'self':
                    self.emit(scope, RET_SELF)
                else:
                    self.gen_value(st.expr, lex2); self.emit(scope, RET_TOP)
            else:
                self.gen_effect(st, lex2)
        if not m.stmts or not isinstance(m.stmts[-1], Return):
            self.emit(scope, RET_SELF)
        scope.lits.append(Sym(m.sel))
        scope.lits.append(ClassRef(self.cls))
        return self.assemble(scope, len(m.args), m.prim, False, m.sel)

    # ---- pass 1: which variables a block captures, and which are assigned ------
    def an_stmts(self, stmts, lex):
        for s in stmts: self.an(s, lex)

    def an(self, n, lex):
        if isinstance(n, Lit): return
        if isinstance(n, Var):
            v = lex.lookup(n.name)
            if v is not None and v.scope is not lex.real: v.captured = True
            return
        if isinstance(n, Assign):
            if n.name in RESERVED: raise CompileError('line %d: cannot assign to %s' % (n.line, n.name))
            v = lex.lookup(n.name)
            if v is not None:
                if v.kind == 'arg': raise CompileError('line %d: cannot assign to the argument %s' % (n.line, n.name))
                v.assigned = True
                if v.scope is not lex.real: v.captured = True
            self.an(n.value, lex); return
        if isinstance(n, Return): self.an(n.expr, lex); return
        if isinstance(n, Brace):
            for e in n.elems: self.an(e, lex)
            return
        if isinstance(n, Cascade):
            self.an(n.rcvr, lex)
            for sel, args in n.msgs:
                for a in args: self.an(a, lex)
            return
        if isinstance(n, Block):
            self.an_block(n, lex); return
        if isinstance(n, Send):
            inl = inlined_args(n)
            if inl is None:
                self.an(n.rcvr, lex)
                for a in n.args: self.an(a, lex)
                return
            inl_nodes = [b for b, k in inl]
            if n.sel in ('to:do:', 'to:by:do:'):
                self.an(n.rcvr, lex); self.an(n.args[0], lex)
                if n.sel == 'to:by:do:': self.an(n.args[1], lex)
                lim = lex.real.declare_local(None)
                self.analysis[id(n)] = lim
                self.an_inlined(n.args[-1], lex, loopvar=True)
                return
            if n.rcvr in inl_nodes: self.an_inlined(n.rcvr, lex)
            else: self.an(n.rcvr, lex)
            for a in n.args:
                if a in inl_nodes: self.an_inlined(a, lex, assigned_arg=True)
                else: self.an(a, lex)
            return
        raise CompileError('unknown node')

    def an_inlined(self, b, lex, loopvar=False, assigned_arg=False):
        inner = Lex(lex, lex.real)
        for a in b.args:
            v = lex.real.declare_local(a); inner.names[a] = v
            if loopvar or assigned_arg: v.assigned = True
        for t in b.temps:
            inner.names[t] = lex.real.declare_local(t)
        self.analysis[id(b)] = inner
        self.an_stmts(b.stmts, inner)

    def an_block(self, b, lex):
        sc = CScope(lex.real, True)
        self.scopes.append(sc)
        inner = Lex(lex, sc)
        if len(b.args) > 15: raise CompileError('too many block arguments')
        for a in b.args:
            v = CVar(a, 'arg', sc); sc.args.append(v); inner.names[a] = v
        for t in b.temps:
            inner.names[t] = sc.declare_local(t)
        self.analysis[id(b)] = inner
        self.an_stmts(b.stmts, inner)

    def settle(self):
        for sc in self.scopes:
            keep = []
            for v in sc.locals:
                if v.captured and v.assigned:
                    v.remote = True; v.vidx = len(sc.remotes); sc.remotes.append(v)
                else:
                    keep.append(v)
            sc.locals = keep
            if sc.remotes:
                sc.vector = CVar('<vector>', 'temp', sc)

    # ---- pass 2: code ------------------------------------------------------------
    def begin(self, scope):
        if scope.vector is not None:
            scope.code.append((PUSH_VEC, len(scope.remotes)))
            scope.code.append((POPST_TEMP, scope.vector))

    def emit(self, scope, op, *a):
        scope.code.append((op,) + a)

    def gen_effect(self, n, lex):
        if isinstance(n, Assign):
            self.gen_value(n.value, lex)
            self.gen_store(n, lex, True)
        else:
            self.gen_value(n, lex)
            self.emit(lex.real, POP)

    def gen_value(self, n, lex):
        sc = lex.real
        if isinstance(n, Lit):
            self.gen_lit(n.v, sc); return
        if isinstance(n, Var):
            self.gen_load_name(n.name, n.line, lex); return
        if isinstance(n, Assign):
            self.gen_value(n.value, lex); self.gen_store(n, lex, False); return
        if isinstance(n, Brace):
            if len(n.elems) > 255: raise CompileError('brace array too long')
            for e in n.elems: self.gen_value(e, lex)
            self.emit(sc, PUSH_ARRAY, len(n.elems)); return
        if isinstance(n, Cascade):
            self.gen_value(n.rcvr, lex)
            for i, (sel, args) in enumerate(n.msgs):
                last = i == len(n.msgs) - 1
                if not last: self.emit(sc, DUP)
                for a in args: self.gen_value(a, lex)
                self.gen_send(sel, len(args), sc, False)
                if not last: self.emit(sc, POP)
            return
        if isinstance(n, Block):
            self.gen_block(n, lex); return
        if isinstance(n, Send):
            if inlined_args(n) is not None:
                self.gen_inline(n, lex); return
            sup = isinstance(n.rcvr, Var) and n.rcvr.name == 'super'
            if sup: self.emit(sc, PUSH_SELF)
            else: self.gen_value(n.rcvr, lex)
            for a in n.args: self.gen_value(a, lex)
            self.gen_send(n.sel, len(n.args), sc, sup)
            return
        if isinstance(n, Return):
            raise CompileError('^ inside an expression')
        raise CompileError('unknown node')

    def gen_lit(self, v, sc):
        if v is NIL: self.emit(sc, PUSH_NIL)
        elif v is TRUE: self.emit(sc, PUSH_TRUE)
        elif v is FALSE: self.emit(sc, PUSH_FALSE)
        elif isinstance(v, int) and -128 <= v <= 127: self.emit(sc, PUSH_INT8, v & 255)
        else:
            self.emit(sc, PUSH_LIT, sc.lit(v))

    def gen_send(self, sel, nargs, sc, sup):
        if sup:
            self.emit(sc, SUPER, sc.lit(Sym(sel)), nargs); return
        k = SPECIAL_INDEX.get(sel)
        if k is not None and SPECIAL_SELECTORS[k][1] == nargs:
            self.emit(sc, SEND_SP, k); return
        self.emit(sc, SEND, sc.lit(Sym(sel)), nargs)

    def gen_load_name(self, name, line, lex):
        sc = lex.real
        if name == 'self' or name == 'super': self.emit(sc, PUSH_SELF); return
        if name == 'nil': self.emit(sc, PUSH_NIL); return
        if name == 'true': self.emit(sc, PUSH_TRUE); return
        if name == 'false': self.emit(sc, PUSH_FALSE); return
        if name == 'thisContext': raise CompileError('line %d: thisContext is not supported' % line)
        v = lex.lookup(name)
        if v is not None: self.gen_load_var(v, sc); return
        if name in self.ivars: self.emit(sc, PUSH_INST, self.ivars.index(name)); return
        self.emit(sc, PUSH_LITVAR, sc.lit(Global(name)))

    def gen_load_var(self, v, sc):
        if v.scope is sc:
            if v.remote: self.emit(sc, PUSH_TVEC, v.vidx, sc.vector)
            else: self.emit(sc, PUSH_TEMP, v)
        elif v.remote:
            self.emit(sc, PUSH_TVEC, v.vidx, sc.capture(v.scope.vector))
        else:
            self.emit(sc, PUSH_TEMP, sc.capture(v))

    def gen_store(self, n, lex, pop):
        self.gen_store_name(n.name, n.line, lex, pop)

    def gen_store_name(self, name, line, lex, pop):
        sc = lex.real
        v = lex.lookup(name)
        if v is not None: self.gen_store_var(v, sc, pop); return
        if name in self.ivars:
            self.emit(sc, POPST_INST if pop else STORE_INST, self.ivars.index(name)); return
        self.emit(sc, POPST_LITVAR if pop else STORE_LITVAR, sc.lit(Global(name)))

    def gen_store_var(self, v, sc, pop):
        if v.scope is sc:
            if v.remote: self.emit(sc, POPST_TVEC if pop else STORE_TVEC, v.vidx, sc.vector)
            else: self.emit(sc, POPST_TEMP if pop else STORE_TEMP, v)
        elif v.remote:
            self.emit(sc, POPST_TVEC if pop else STORE_TVEC, v.vidx, sc.capture(v.scope.vector))
        else:
            raise CompileError('internal: store into a copied variable %s' % v.name)

    def gen_block(self, b, lex):
        inner = self.analysis[id(b)]
        sc = inner.real
        self.begin(sc)
        if not b.stmts:
            self.emit(sc, PUSH_NIL); self.emit(sc, BLK_RET)
        for i, st in enumerate(b.stmts):
            last = i == len(b.stmts) - 1
            if isinstance(st, Return):
                self.gen_value(st.expr, inner); self.emit(sc, RET_TOP)
            elif last:
                self.gen_value(st, inner); self.emit(sc, BLK_RET)
            else:
                self.gen_effect(st, inner)
        sc.lits.append(ClassRef(self.cls))
        code = self.assemble(sc, len(b.args), 0, True, None)
        outer = lex.real
        for c in sc.copied:
            self.gen_load_var(c.origin, outer)
        self.emit(outer, PUSH_CLOSURE, outer.lit(code), len(sc.copied))

    def gen_inlined_value(self, b, lex):
        inner = self.analysis[id(b)]
        sc = lex.real
        if not b.stmts: self.emit(sc, PUSH_NIL); return
        for i, st in enumerate(b.stmts):
            last = i == len(b.stmts) - 1
            if isinstance(st, Return):
                self.gen_value(st.expr, inner); self.gen_return(sc)
            elif last:
                self.gen_value(st, inner)
            else:
                self.gen_effect(st, inner)

    def gen_inlined_effect(self, b, lex):
        inner = self.analysis[id(b)]
        sc = lex.real
        for st in b.stmts:
            if isinstance(st, Return):
                self.gen_value(st.expr, inner); self.gen_return(sc)
            else:
                self.gen_effect(st, inner)

    def gen_return(self, sc):
        self.emit(sc, RET_TOP)

    def inlined_arg(self, b):
        inner = self.analysis[id(b)]
        return inner.names[b.args[0]]

    def gen_inline(self, n, lex):
        sc = lex.real
        s, a = n.sel, n.args
        L1, L2 = sc.label(), sc.label()
        if s in ('ifTrue:', 'ifFalse:'):
            self.gen_value(n.rcvr, lex)
            self.emit(sc, JUMP_F if s == 'ifTrue:' else JUMP_T, L1)
            self.gen_inlined_value(a[0], lex)
            self.emit(sc, JUMP, L2); self.emit(sc, L1); self.emit(sc, PUSH_NIL); self.emit(sc, L2)
        elif s in ('ifTrue:ifFalse:', 'ifFalse:ifTrue:'):
            self.gen_value(n.rcvr, lex)
            self.emit(sc, JUMP_F if s == 'ifTrue:ifFalse:' else JUMP_T, L1)
            self.gen_inlined_value(a[0], lex)
            self.emit(sc, JUMP, L2); self.emit(sc, L1)
            self.gen_inlined_value(a[1], lex); self.emit(sc, L2)
        elif s in ('and:', 'or:'):
            self.gen_value(n.rcvr, lex)
            self.emit(sc, JUMP_F if s == 'and:' else JUMP_T, L1)
            self.gen_inlined_value(a[0], lex)
            self.emit(sc, JUMP, L2); self.emit(sc, L1)
            self.emit(sc, PUSH_FALSE if s == 'and:' else PUSH_TRUE); self.emit(sc, L2)
        elif s in ('whileTrue:', 'whileFalse:'):
            self.emit(sc, L1)
            self.gen_inlined_value(n.rcvr, lex)
            self.emit(sc, JUMP_F if s == 'whileTrue:' else JUMP_T, L2)
            self.gen_inlined_effect(a[0], lex)
            self.emit(sc, JUMP, L1); self.emit(sc, L2); self.emit(sc, PUSH_NIL)
        elif s in ('whileTrue', 'whileFalse'):
            self.emit(sc, L1)
            self.gen_inlined_value(n.rcvr, lex)
            self.emit(sc, JUMP_T if s == 'whileTrue' else JUMP_F, L1)
            self.emit(sc, PUSH_NIL)
        elif s == 'repeat':
            self.emit(sc, L1)
            self.gen_inlined_effect(n.rcvr, lex)
            self.emit(sc, JUMP, L1); self.emit(sc, PUSH_NIL)
        elif s in ('to:do:', 'to:by:do:'):
            lim = self.analysis[id(n)]
            blk = a[-1]
            i = self.inlined_arg(blk)
            step = a[1].v if s == 'to:by:do:' else 1
            self.gen_value(n.rcvr, lex); self.gen_store_var(i, sc, True)
            self.gen_value(a[0], lex); self.gen_store_var(lim, sc, True)
            self.emit(sc, L1)
            self.gen_load_var(i, sc); self.gen_load_var(lim, sc)
            self.emit(sc, SEND_SP, SPECIAL_INDEX['<='] if step > 0 else SPECIAL_INDEX['>='])
            self.emit(sc, JUMP_F, L2)
            self.gen_inlined_effect(blk, lex)
            self.gen_load_var(i, sc); self.gen_lit(step, sc)
            self.emit(sc, SEND_SP, SPECIAL_INDEX['+'])
            self.gen_store_var(i, sc, True)
            self.emit(sc, JUMP, L1); self.emit(sc, L2); self.emit(sc, PUSH_NIL)
        elif s == 'ifNil:':
            self.gen_value(n.rcvr, lex)
            self.emit(sc, DUP); self.emit(sc, PUSH_NIL); self.emit(sc, SEND_SP, SPECIAL_INDEX['=='])
            self.emit(sc, JUMP_F, L1); self.emit(sc, POP)
            self.gen_inlined_value(a[0], lex); self.emit(sc, L1)
        elif s == 'ifNotNil:':
            self.gen_value(n.rcvr, lex)
            self.emit(sc, DUP); self.emit(sc, PUSH_NIL); self.emit(sc, SEND_SP, SPECIAL_INDEX['=='])
            self.emit(sc, JUMP_T, L1)
            self.gen_nonnil_arg(a[0], sc)
            self.gen_inlined_value(a[0], lex)
            self.emit(sc, L1)
        elif s in ('ifNil:ifNotNil:', 'ifNotNil:ifNil:'):
            nilb, valb = (a[0], a[1]) if s == 'ifNil:ifNotNil:' else (a[1], a[0])
            self.gen_value(n.rcvr, lex)
            self.emit(sc, DUP); self.emit(sc, PUSH_NIL); self.emit(sc, SEND_SP, SPECIAL_INDEX['=='])
            if s == 'ifNil:ifNotNil:':
                self.emit(sc, JUMP_F, L1); self.emit(sc, POP)
                self.gen_inlined_value(nilb, lex)
                self.emit(sc, JUMP, L2); self.emit(sc, L1)
                self.gen_nonnil_arg(valb, sc); self.gen_inlined_value(valb, lex)
                self.emit(sc, L2)
            else:
                self.emit(sc, JUMP_T, L1)
                self.gen_nonnil_arg(valb, sc); self.gen_inlined_value(valb, lex)
                self.emit(sc, JUMP, L2); self.emit(sc, L1); self.emit(sc, POP)
                self.gen_inlined_value(nilb, lex)
                self.emit(sc, L2)
        else:
            raise CompileError('internal: inline %s' % s)

    def gen_nonnil_arg(self, b, sc):
        if b.args: self.gen_store_var(self.inlined_arg(b), sc, True)
        else: self.emit(sc, POP)

    # ---- assembly --------------------------------------------------------------------
    def assemble(self, sc, nargs, prim, is_block, sel):
        temps = sc.args + sc.copied + sc.locals + ([sc.vector] if sc.vector else [])
        index = {id(v): i for i, v in enumerate(temps)}
        if len(temps) > 255: raise CompileError('too many temporaries')
        # sizes and label addresses
        pos, labels = 0, {}
        for ins in sc.code:
            if isinstance(ins[0], tuple): labels[ins[0]] = pos; continue
            pos += oplen(ins[0])
        out = bytearray()
        depth = maxd = 0
        for ins in sc.code:
            if isinstance(ins[0], tuple): continue
            op = ins[0]
            args = []
            for x in ins[1:]:
                if isinstance(x, CVar): args.append(index[id(x)])
                else: args.append(x)
            out.append(op)
            if op in (JUMP, JUMP_T, JUMP_F):
                off = labels[args[0]] - (len(out) + 2)
                if not -32768 <= off < 32768: raise CompileError('method too long')
                out += bytes([(off >> 8) & 255, off & 255])
            else:
                for x in args: out.append(x & 255)
            depth += stack_effect(op, args)
            maxd = max(maxd, depth)
        if maxd > 255: raise CompileError('expression too deep')
        ntemps = len(temps) - nargs
        lits = sc.lits
        return Code(nargs, ntemps, len(sc.copied), prim, is_block, maxd, lits, bytes(out), sel)


def stack_effect(op, a):
    if op in (PUSH_SELF, PUSH_NIL, PUSH_TRUE, PUSH_FALSE, DUP, PUSH_INST, PUSH_TEMP, PUSH_LIT,
              PUSH_LITVAR, PUSH_INT8, PUSH_TVEC, PUSH_VEC):
        return 1
    if op in (POP, RET_TOP, BLK_RET, POPST_INST, POPST_TEMP, POPST_LITVAR, POPST_TVEC, JUMP_T, JUMP_F):
        return -1
    if op == PUSH_ARRAY: return 1 - a[0]
    if op == PUSH_CLOSURE: return 1 - a[1]
    if op in (SEND, SUPER): return -a[1]
    if op == SEND_SP: return -SPECIAL_SELECTORS[a[0]][1]
    return 0


def disassemble(code, lits=None):
    out, i = [], 0
    b = code
    while i < len(b):
        op = b[i]; n = oplen(op)
        a = list(b[i + 1:i + n])
        if op in (JUMP, JUMP_T, JUMP_F):
            off = (a[0] << 8 | a[1]); off -= 65536 if off >= 32768 else 0
            a = ['-> %d' % (i + 3 + off)]
        if op == PUSH_INT8: a = [a[0] - 256 if a[0] > 127 else a[0]]
        if op == SEND_SP: a = [SPECIAL_SELECTORS[a[0]][0]]
        out.append('%4d %s %s' % (i, OPNAMES.get(op, '?%d' % op), ' '.join(map(str, a))))
        i += n
    return '\n'.join(out)
