"Jit.st: the JIT. A method that gets hot (200 activations) is translated
 to Strata code, template by template: each bytecode becomes the
 instructions the interpreter would run for it, with its operands as
 constants and no dispatch. Temps, literals, pushes and stores, the
 SmallInteger cases of + - * < > <= >= = ~= bitAnd: bitOr: and == ~~ are
 done in place; sends, returns, closures, arrays and the slots of objects
 (near or far) call the VM. The code goes into a unit of 1 KiB in the
 program's arena; the kernel pages it into the I-LS when it is called
 (vm-jit.s has the VM's side).

   Jit on        compile hot methods from now on
   Jit off       stop (what is compiled stays)
   Jit stats     what it did"

Object subclass: #Jit slots: ''.
Jit class slots: 'helpers table compiled failed'.
Object subclass: #JitCompiler slots: 'method helpers base code labels header isBlock fixups'.

Jit class >> primHelpers [ <primitive: 120> ^nil ]
Jit class >> primReserve: n [ <primitive: 121> ^nil ]
Jit class >> primInstall: bytes at: offset for: aMethod [ <primitive: 122> ^nil ]
Jit class >> primEnable: n [ <primitive: 123> ^nil ]
Jit class >> reset [
    "At start: what an image kept of native code is gone (c0 is new)."
    table := nil. compiled := 0. failed := 0. helpers := nil.
    Smalltalk specialObjects at: 16 put: nil ]
Jit class >> setUp [
    table == nil ifTrue: [
        table := Array basicNewFar: 8192.
        Smalltalk specialObjects at: 16 put: table].
    helpers == nil ifTrue: [helpers := self primHelpers].
    compiled == nil ifTrue: [compiled := 0. failed := 0] ]
Jit class >> on [ self setUp. self primEnable: 1 ]
Jit class >> off [ self primEnable: 0 ]
Jit class >> stats [
    ^'compiled ' , compiled printString , ', not compiled ' , failed printString ,
        ', native activations ' , (Smalltalk vmStatsNative) printString ]
Jit class >> jitCompile: aMethod [
    "Sent by the VM when aMethod gets hot."
    self primEnable: 2.
    [self compile: aMethod] on: Error do: [:e | failed := failed + 1. e return: nil].
    self primEnable: 1.
    ^nil ]
Jit class >> compile: aMethod [
    "-> true if aMethod has native code now"
    | bytes where |
    self setUp.
    bytes := (JitCompiler new method: aMethod helpers: helpers base: 0) translate.
    bytes == nil ifTrue: [failed := failed + 1. ^false].
    where := self primReserve: bytes size.
    where == nil ifTrue: [failed := failed + 1. ^false].
    bytes := (JitCompiler new method: aMethod helpers: helpers base: (where at: 2)) translate.
    self primInstall: bytes at: (where at: 1) for: aMethod.
    compiled := compiled + 1.
    ^true ]
Jit class >> compileClass: aClass [
    aClass methodDict keysAndValuesDo: [:sel :m | self compile: m] ]
SystemDictionary >> vmStatsNative [ <primitive: 124> ^0 ]

"---- the translator --------------------------------------------------------------"

JitCompiler >> method: aMethod helpers: anArray base: anInteger [
    method := aMethod. helpers := anArray. base := anInteger ]
JitCompiler >> helper: i [ ^helpers at: i ]
JitCompiler >> translate [
    "The native code as bytes, or nil (too large for a unit)."
    | pc n op |
    header := method header.
    isBlock := ((header bitShift: -44) bitAnd: 1) = 1.
    n := method numBytes.
    "pass 1: where each bytecode's code starts (templates have fixed sizes)"
    labels := Array new: n + 1.
    code := OrderedCollection new.
    fixups := nil.
    pc := 1.
    [pc <= n] whileTrue: [
        labels at: pc put: code size.
        op := method byteAt: pc.
        self emit: op at: pc.
        pc := pc + (self lengthOf: op)].
    labels at: n + 1 put: code size.
    code size * 4 > 1024 ifTrue: [^nil].
    "pass 2: the same, with every target known"
    fixups := labels.
    code := OrderedCollection new.
    pc := 1.
    [pc <= n] whileTrue: [
        op := method byteAt: pc.
        self emit: op at: pc.
        pc := pc + (self lengthOf: op)].
    ^self bytes ]
JitCompiler >> lengthOf: op [
    op < 16 ifTrue: [^1].
    (#(27 28 29 31 32 33 35 36 37) includes: op) ifTrue: [^3].
    ^2 ]
JitCompiler >> bytes [
    | b i |
    b := ByteArray new: code size * 4.
    i := 0.
    code do: [:w | | x |
        x := w.
        1 to: 4 do: [:k | b at: i + k put: (x bitAnd: 255). x := x bitShift: -8].
        i := i + 4].
    ^b ]
JitCompiler >> here [ ^code size ]
JitCompiler >> farHere [ "the far address of the next instruction" ^base + (code size * 4) ]
JitCompiler >> target: bcPc [ "the instruction index bytecode bcPc starts at" ^fixups == nil ifTrue: [0] ifFalse: [fixups at: bcPc] ]

"---- the instructions (asm/sasm.c's encodings) ----"

JitCompiler >> w: anInteger [ code add: (anInteger bitAnd: 16rFFFFFFFF) ]
JitCompiler >> r: op d: rd s: rs1 t: rs2 f: funct [
    self w: (op bitShift: 26) + (rd bitShift: 21) + (rs1 bitShift: 16) + (rs2 bitShift: 11) + funct ]
JitCompiler >> i: op d: rd s: rs1 imm: imm [
    self w: (op bitShift: 26) + (rd bitShift: 21) + (rs1 bitShift: 16) + (imm bitAnd: 16rFFFF) ]
JitCompiler >> alu: funct d: rd s: a t: b [ self r: 0 d: rd s: a t: b f: funct ]
JitCompiler >> add: rd s: a t: b [ self alu: 0 d: rd s: a t: b ]
JitCompiler >> sub: rd s: a t: b [ self alu: 1 d: rd s: a t: b ]
JitCompiler >> and: rd s: a t: b [ self alu: 2 d: rd s: a t: b ]
JitCompiler >> or: rd s: a t: b [ self alu: 3 d: rd s: a t: b ]
JitCompiler >> xor: rd s: a t: b [ self alu: 4 d: rd s: a t: b ]
JitCompiler >> mul: rd s: a t: b [ self alu: 10 d: rd s: a t: b ]
JitCompiler >> addi: rd s: rs imm: v [ self i: 1 d: rd s: rs imm: v ]
JitCompiler >> andi: rd s: rs imm: v [ self i: 2 d: rd s: rs imm: v ]
JitCompiler >> ori: rd s: rs imm: v [ self i: 3 d: rd s: rs imm: v ]
JitCompiler >> slli: rd s: rs imm: v [ self i: 5 d: rd s: rs imm: v ]
JitCompiler >> srai: rd s: rs imm: v [ self i: 7 d: rd s: rs imm: v ]
JitCompiler >> lui: rd imm: v [ self i: 10 d: rd s: 0 imm: v ]
JitCompiler >> ld: rd off: v base: rs [ self i: 16 d: rd s: rs imm: v ]
JitCompiler >> sd: rv off: v base: rs [ self i: 24 d: rv s: rs imm: v ]
JitCompiler >> branch: op a: ra b: rb to: index [
    "op: 32 beq 33 bne 34 blt 35 bge; index: the target instruction"
    self i: op d: ra s: rb imm: index - self here ]
JitCompiler >> jumpTo: index [ self w: (40 bitShift: 26) + ((index - self here) bitAnd: 16r1FFFFF) ]
JitCompiler >> call: helperIndex [ "jalr ra, gp, H - 0x10000" self i: 41 d: 1 s: 3 imm: (self helper: helperIndex) - 16r10000 ]
JitCompiler >> goto: helperIndex [ "jalr zero, gp, H - 0x10000" self i: 41 d: 0 s: 3 imm: (self helper: helperIndex) - 16r10000 ]
JitCompiler >> li: rd far: v [ "two instructions, whatever v is (v < 2^31)" self lui: rd imm: (v bitShift: -16). self ori: rd s: rd imm: (v bitAnd: 16rFFFF) ]
"registers"
JitCompiler >> zero [ ^0 ]
JitCompiler >> sp [ ^2 ]
JitCompiler >> t0 [ ^5 ]
JitCompiler >> t1 [ ^6 ]
JitCompiler >> t2 [ ^7 ]
JitCompiler >> a0 [ ^10 ]
JitCompiler >> a1 [ ^11 ]
JitCompiler >> a2 [ ^12 ]
JitCompiler >> t3 [ ^28 ]
JitCompiler >> t4 [ ^29 ]
JitCompiler >> t5 [ ^30 ]
JitCompiler >> fp [ ^9 ]
JitCompiler >> self4 [ ^20 ]
JitCompiler >> trueReg [ ^23 ]
JitCompiler >> falseReg [ ^24 ]
JitCompiler >> lits [ ^26 ]

"---- the templates ----"

JitCompiler >> push: r [ self addi: self sp s: self sp imm: -8. self sd: r off: 0 base: self sp ]
JitCompiler >> pop [ self addi: self sp s: self sp imm: 8 ]
JitCompiler >> emit: op at: pc [
    | a b |
    a := pc + 1 <= method numBytes ifTrue: [method byteAt: pc + 1] ifFalse: [0].
    b := pc + 2 <= method numBytes ifTrue: [method byteAt: pc + 2] ifFalse: [0].
    op = 0 ifTrue: [^self push: self self4].
    op = 1 ifTrue: [^self push: self zero].
    op = 2 ifTrue: [^self push: self trueReg].
    op = 3 ifTrue: [^self push: self falseReg].
    op = 5 ifTrue: [self ld: self t0 off: 0 base: self sp. ^self push: self t0].
    op = 6 ifTrue: [^self pop].
    op = 7 ifTrue: [self ld: self a0 off: 0 base: self sp. ^self goto: (isBlock ifTrue: [6] ifFalse: [5])].
    op = 8 ifTrue: [self addi: self a0 s: self self4 imm: 0. ^self goto: 5].
    op = 9 ifTrue: [self ld: self a0 off: 0 base: self sp. ^self goto: 5].
    op = 16 ifTrue: [self addi: self a0 s: self self4 imm: 0. self addi: self a1 s: 0 imm: a. self call: 11. ^self push: self a0].
    op = 17 ifTrue: [self ld: self t0 off: 0 - (8 * a) base: self fp. ^self push: self t0].
    op = 18 ifTrue: [self ld: self t0 off: 8 * a base: self lits. ^self push: self t0].
    op = 19 ifTrue: [self ld: self a0 off: 8 * a base: self lits. self addi: self a1 s: 0 imm: 1. self call: 11. ^self push: self a0].
    (op = 20 or: [op = 23]) ifTrue: [
        self addi: self a0 s: self self4 imm: 0. self addi: self a1 s: 0 imm: a.
        self ld: self a2 off: 0 base: self sp. self call: 12.
        ^op = 23 ifTrue: [self pop] ifFalse: [self]].
    (op = 21 or: [op = 24]) ifTrue: [
        self ld: self t0 off: 0 base: self sp. self sd: self t0 off: 0 - (8 * a) base: self fp.
        ^op = 24 ifTrue: [self pop] ifFalse: [self]].
    (op = 22 or: [op = 25]) ifTrue: [
        self ld: self a0 off: 8 * a base: self lits. self addi: self a1 s: 0 imm: 1.
        self ld: self a2 off: 0 base: self sp. self call: 12.
        ^op = 25 ifTrue: [self pop] ifFalse: [self]].
    op = 26 ifTrue: [self addi: self t0 s: 0 imm: (a > 127 ifTrue: [a - 256] ifFalse: [a]) * 2 + 1. ^self push: self t0].
    op = 27 ifTrue: [self ld: self a0 off: 0 - (8 * b) base: self fp. self addi: self a1 s: 0 imm: a. self call: 11. ^self push: self a0].
    (op = 28 or: [op = 29]) ifTrue: [
        self ld: self a0 off: 0 - (8 * b) base: self fp. self addi: self a1 s: 0 imm: a.
        self ld: self a2 off: 0 base: self sp. self call: 12.
        ^op = 29 ifTrue: [self pop] ifFalse: [self]].
    op = 30 ifTrue: [self addi: self a2 s: 0 imm: a. ^self call: 8].
    op = 38 ifTrue: [self addi: self a2 s: 0 imm: a. ^self call: 9].
    op = 31 ifTrue: [self ld: self a0 off: 8 * a base: self lits. self addi: self a2 s: 0 imm: b. ^self call: 7].
    (op = 32 or: [op = 33]) ifTrue: [
        self ld: self a0 off: 8 * a base: self lits. self addi: self a1 s: 0 imm: b.
        self li: self a2 far: self farHere + 12.
        ^self goto: (op = 32 ifTrue: [1] ifFalse: [2])].
    op = 34 ifTrue: [^self special: a].
    op = 35 ifTrue: [^self jumpTo: (self target: pc + 3 + (self offset: a b: b))].
    (op = 36 or: [op = 37]) ifTrue: [^self conditional: op = 36 at: pc a: a b: b].
    ^self error: 'no template for bytecode ' , op printString ]
JitCompiler >> offset: a b: b [ | off | off := (a bitShift: 8) + b. ^off >= 32768 ifTrue: [off - 65536] ifFalse: [off] ]
JitCompiler >> conditional: onTrue at: pc a: a b: b [
    "TEST: ld t0, 0(sp); beq t0, taken, TAKE; bne t0, other, MB; pop; j NEXT;
     TAKE: pop; j TARGET; MB: a2 := TEST; the VM sends #mustBeBoolean"
    | test taken other |
    test := self here.
    taken := onTrue ifTrue: [self trueReg] ifFalse: [self falseReg].
    other := onTrue ifTrue: [self falseReg] ifFalse: [self trueReg].
    self ld: self t0 off: 0 base: self sp.
    self branch: 32 a: self t0 b: taken to: test + 5.
    self branch: 33 a: self t0 b: other to: test + 7.
    self pop.
    self jumpTo: (self target: pc + 3).
    self pop.
    self jumpTo: (self target: pc + 3 + (self offset: a b: b)).
    self li: self a2 far: base + (test * 4).
    self goto: 4 ]
JitCompiler >> special: k [
    "The SmallInteger cases in place; the rest sent."
    | start slow done |
    k = 15 ifTrue: [^self identity: true].
    k = 26 ifTrue: [^self identity: false].
    k = 16 ifTrue: [self ld: self a0 off: 0 base: self sp. self call: 10. ^self sd: self a0 off: 0 base: self sp].
    (#(0 1 2 3 4 5 6 7 8 12 13) includes: k) ifFalse: [^self sendSpecial: k].
    "a1 := b, a0 := a; both SmallIntegers? (12 instructions to the slow path at most)"
    start := self here.
    slow := start + (self fastLength: k).
    done := slow + 4.
    self ld: self a1 off: 0 base: self sp.
    self ld: self a0 off: 8 base: self sp.
    self and: self t1 s: self a0 t: self a1.
    self andi: self t1 s: self t1 imm: 1.
    self branch: 32 a: self t1 b: 0 to: slow.
    k = 0 ifTrue: [
        self add: self t2 s: self a0 t: self a1. self addi: self t2 s: self t2 imm: -1.
        self xor: self t3 s: self a0 t: self t2. self xor: self t4 s: self a1 t: self t2.
        self and: self t3 s: self t3 t: self t4. self branch: 34 a: self t3 b: 0 to: slow].
    k = 1 ifTrue: [
        self sub: self t2 s: self a0 t: self a1. self addi: self t2 s: self t2 imm: 1.
        self xor: self t3 s: self a0 t: self a1. self xor: self t4 s: self a0 t: self t2.
        self and: self t3 s: self t3 t: self t4. self branch: 34 a: self t3 b: 0 to: slow].
    k = 8 ifTrue: [
        self srai: self t3 s: self a0 imm: 1. self srai: self t4 s: self a1 imm: 1.
        self slli: self t5 s: self t3 imm: 32. self srai: self t5 s: self t5 imm: 32.
        self branch: 33 a: self t5 b: self t3 to: slow.
        self slli: self t5 s: self t4 imm: 32. self srai: self t5 s: self t5 imm: 32.
        self branch: 33 a: self t5 b: self t4 to: slow.
        self mul: self t2 s: self t3 t: self t4. self slli: self t2 s: self t2 imm: 1. self ori: self t2 s: self t2 imm: 1].
    k = 12 ifTrue: [self and: self t2 s: self a0 t: self a1].
    k = 13 ifTrue: [self or: self t2 s: self a0 t: self a1].
    (k between: 2 and: 7) ifTrue: [
        "t2 := true; the condition holds: skip; t2 := false"
        self addi: self t2 s: self trueReg imm: 0.
        k = 2 ifTrue: [self branch: 34 a: self a0 b: self a1 to: self here + 2].
        k = 3 ifTrue: [self branch: 34 a: self a1 b: self a0 to: self here + 2].
        k = 4 ifTrue: [self branch: 35 a: self a1 b: self a0 to: self here + 2].
        k = 5 ifTrue: [self branch: 35 a: self a0 b: self a1 to: self here + 2].
        k = 6 ifTrue: [self branch: 32 a: self a0 b: self a1 to: self here + 2].
        k = 7 ifTrue: [self branch: 33 a: self a0 b: self a1 to: self here + 2].
        self addi: self t2 s: self falseReg imm: 0].
    self pop.
    self sd: self t2 off: 0 base: self sp.
    self jumpTo: done.
    self here = slow ifFalse: [^self error: 'the fast path is not as long as it should be'].
    self addi: self a0 s: 0 imm: k.
    self li: self a2 far: base + (done * 4).
    self goto: 3 ]
JitCompiler >> fastLength: k [
    "instructions from the start of a special send's code to its slow path"
    k = 0 ifTrue: [^5 + 6 + 3].
    k = 1 ifTrue: [^5 + 6 + 3].
    k = 8 ifTrue: [^5 + 11 + 3].
    (k = 12 or: [k = 13]) ifTrue: [^5 + 1 + 3].
    ^5 + 3 + 3 ]
JitCompiler >> sendSpecial: k [
    self addi: self a0 s: 0 imm: k.
    self li: self a2 far: self farHere + 12.
    self goto: 3 ]
JitCompiler >> identity: same [
    "== (or ~~): pop b, a := (a == b) the Boolean"
    self ld: self t1 off: 0 base: self sp.
    self ld: self t0 off: 8 base: self sp.
    self pop.
    self addi: self t2 s: (same ifTrue: [self trueReg] ifFalse: [self falseReg]) imm: 0.
    self branch: 32 a: self t0 b: self t1 to: self here + 2.
    self addi: self t2 s: (same ifTrue: [self falseReg] ifFalse: [self trueReg]) imm: 0.
    self sd: self t2 off: 0 base: self sp ]
