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
"The JIT's front: turning it on and off, and compiling a hot method to native
 Strata code. It has no instances; its class-side slots hold the state:
 helpers (the Array from primHelpers: the I-LS addresses of what native code
 calls, then the VM's numbers it needs), table (the native table, a far Array
 of 8192 slots kept in the specials' slot 15: pairs of method and c0 offset),
 and compiled and failed, the counts that stats reports. The translation is
 JitCompiler's; the code units, the paging and the far links are the VM's
 (vm-jit.s)."

Object subclass: #JitCompiler slots: 'method helpers base code labels header isBlock fixups'.
"Translates one CompiledMethod or CompiledBlock to Strata code, template by
 template: each bytecode becomes a fixed run of instructions with its operands
 as constants. Native code keeps the interpreter's frames and registers (fp,
 sp, self in s4, the literals in s10) and calls the resident VM helpers with
 jalr through gp. method is the code being translated; helpers the Array from
 Jit primHelpers; base the far address of the unit's first instruction; code
 the instruction words so far; labels and fixups where each bytecode's code
 starts (fixups is nil in pass 1); header the method's header; isBlock whether
 it is a block."

Jit class >> primHelpers [
    "An Array of SmallIntegers: the I-LS addresses of the VM helpers native
     code calls (send, super send, special send, mustBeBoolean, return, ^,
     closure, array, temp vector, class, slot load, slot store), then the
     native mark and gp. A VM primitive (120); answers nil when it fails."
    <primitive: 120> ^nil ]
Jit class >> primReserve: n [
    "Reserves room for n bytes of native code in one code unit of the
     program's arena (c0) and answers {c0 offset. far address}, or nil if
     there is no room. A VM primitive (121)."
    <primitive: 121> ^nil ]
Jit class >> primInstall: bytes at: offset for: aMethod [
    "Copies bytes out to c0 at offset (as reserved by primReserve:), enters
     aMethod and the offset in the native table and sets the method header's
     bit 53, so that the method cache finds the native code. A VM primitive
     (122)."
    <primitive: 122> ^nil ]
Jit class >> primEnable: n [
    "Sets the VM's JIT state: 0 off, 1 on (hot methods are offered to Jit
     jitCompile:), 2 at work (nothing is offered while a method is being
     compiled). A VM primitive (123)."
    <primitive: 123> ^nil ]
Jit class >> reset [
    "Forgets all native code and the counts. Run at start-up: what an image
     kept of native code is gone, since c0 is new; it also clears the native
     table's specials slot."
    table := nil. compiled := 0. failed := 0. helpers := nil.
    Smalltalk specialObjects at: 16 put: nil ]
Jit class >> setUp [
    "Makes the native table (a far Array of 8192 slots, stored in the
     specials' slot 15), fetches the helpers and zeroes the counts, each only
     if it is not there yet."
    table == nil ifTrue: [
        table := Array basicNewFar: 8192.
        Smalltalk specialObjects at: 16 put: table].
    helpers == nil ifTrue: [helpers := self primHelpers].
    compiled == nil ifTrue: [compiled := 0. failed := 0] ]
Jit class >> on [
    "Turns the JIT on: from now on a method activated 200 times is compiled to
     native code. Sets up the native table and helpers first."
    self setUp. self primEnable: 1 ]
Jit class >> off [
    "Turns the JIT off: no more methods are compiled; native code already
     installed stays and is still run."
    self primEnable: 0 ]
Jit class >> stats [
    "A String with the number of methods compiled, the number that could not
     be compiled, and the number of activations of native code (Smalltalk
     vmStatsNative)."
    ^'compiled ' , compiled printString , ', not compiled ' , failed printString ,
        ', native activations ' , (Smalltalk vmStatsNative) printString ]
Jit class >> jitCompile: aMethod [
    "Compiles aMethod, sent by the VM from inside the method's new frame when
     it gets hot; answers nil. The VM offers nothing more while it works
     (primEnable: 2); an Error during the translation counts the method as not
     compiled and is not passed on."
    self primEnable: 2.
    [self compile: aMethod] on: Error do: [:e | failed := failed + 1. e return: nil].
    self primEnable: 1.
    ^nil ]
Jit class >> compile: aMethod [
    "Translates aMethod to native code and installs it; answers true if
     aMethod has native code now, false if not (its code is over a 1 KiB unit,
     or there is no room). Translates twice: once to learn the size, then at
     the far address primReserve: gave, so that far links and helper returns
     are right."
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
    "Compiles every method in aClass's method dictionary to native code, hot
     or not (not its metaclass's)."
    aClass methodDict keysAndValuesDo: [:sel :m | self compile: m] ]
SystemDictionary >> vmStatsNative [
    "The number of activations of native code since start-up. A VM primitive
     (124); 0 if it fails."
    <primitive: 124> ^0 ]

"---- the translator --------------------------------------------------------------"

JitCompiler >> method: aMethod helpers: anArray base: anInteger [
    "Sets the method to translate, the helpers Array from Jit primHelpers, and
     the far address the code will start at (0 for a trial run that only
     measures)."
    method := aMethod. helpers := anArray. base := anInteger ]
JitCompiler >> helper: i [
    "The I-LS address of VM helper i (1-based, as Jit primHelpers lists them)."
    ^helpers at: i ]
JitCompiler >> translate [
    "Answers the native code for the method as a ByteArray, or nil if it is
     over 1 KiB (a code unit). Two passes over the bytecodes: the first
     records where each bytecode's code starts (the templates have fixed
     sizes), the second emits the code again with every jump target known.
     Signals an Error for a bytecode without a template."
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
    "The length in bytes of bytecode op with its operands: 1 below 16, 3 for
     the two-operand ones (27 28 29 31 32 33 35 36 37), 2 for the rest. The
     same as Compiler opLength:.
     (JitCompiler new lengthOf: 35) >>> 3"
    op < 16 ifTrue: [^1].
    (#(27 28 29 31 32 33 35 36 37) includes: op) ifTrue: [^3].
    ^2 ]
JitCompiler >> bytes [
    "The instruction words emitted so far as a ByteArray, each word
     little-endian."
    | b i |
    b := ByteArray new: code size * 4.
    i := 0.
    code do: [:w | | x |
        x := w.
        1 to: 4 do: [:k | b at: i + k put: (x bitAnd: 255). x := x bitShift: -8].
        i := i + 4].
    ^b ]
JitCompiler >> here [
    "The index (0-based) of the next instruction to be emitted."
    ^code size ]
JitCompiler >> farHere [
    "The far address of the next instruction: base plus 4 bytes for each
     instruction so far."
    ^base + (code size * 4) ]
JitCompiler >> target: bcPc [
    "The instruction index at which bytecode bcPc's code starts; 0 in pass 1,
     when the targets are not known yet."
    ^fixups == nil ifTrue: [0] ifFalse: [fixups at: bcPc] ]

"---- the instructions (asm/sasm.c's encodings) ----"

JitCompiler >> w: anInteger [
    "Emits one 32-bit instruction word (anInteger cut to 32 bits)."
    code add: (anInteger bitAnd: 16rFFFFFFFF) ]
JitCompiler >> r: op d: rd s: rs1 t: rs2 f: funct [
    "Emits an R-type instruction: opcode op, destination rd, sources rs1 and
     rs2, function funct (asm/sasm.c's encoding)."
    self w: (op bitShift: 26) + (rd bitShift: 21) + (rs1 bitShift: 16) + (rs2 bitShift: 11) + funct ]
JitCompiler >> i: op d: rd s: rs1 imm: imm [
    "Emits an I-type instruction: opcode op, registers rd and rs1, and a
     16-bit immediate (imm cut to 16 bits)."
    self w: (op bitShift: 26) + (rd bitShift: 21) + (rs1 bitShift: 16) + (imm bitAnd: 16rFFFF) ]
JitCompiler >> alu: funct d: rd s: a t: b [
    "Emits an ALU instruction (opcode 0) with function funct: rd := a funct b."
    self r: 0 d: rd s: a t: b f: funct ]
JitCompiler >> add: rd s: a t: b [
    "Emits `add rd, a, b`."
    self alu: 0 d: rd s: a t: b ]
JitCompiler >> sub: rd s: a t: b [
    "Emits `sub rd, a, b`."
    self alu: 1 d: rd s: a t: b ]
JitCompiler >> and: rd s: a t: b [
    "Emits `and rd, a, b`."
    self alu: 2 d: rd s: a t: b ]
JitCompiler >> or: rd s: a t: b [
    "Emits `or rd, a, b`."
    self alu: 3 d: rd s: a t: b ]
JitCompiler >> xor: rd s: a t: b [
    "Emits `xor rd, a, b`."
    self alu: 4 d: rd s: a t: b ]
JitCompiler >> mul: rd s: a t: b [
    "Emits `mul rd, a, b`."
    self alu: 10 d: rd s: a t: b ]
JitCompiler >> addi: rd s: rs imm: v [
    "Emits `addi rd, rs, v` (also the register move, with v 0)."
    self i: 1 d: rd s: rs imm: v ]
JitCompiler >> andi: rd s: rs imm: v [
    "Emits `andi rd, rs, v`."
    self i: 2 d: rd s: rs imm: v ]
JitCompiler >> ori: rd s: rs imm: v [
    "Emits `ori rd, rs, v`."
    self i: 3 d: rd s: rs imm: v ]
JitCompiler >> slli: rd s: rs imm: v [
    "Emits `slli rd, rs, v`."
    self i: 5 d: rd s: rs imm: v ]
JitCompiler >> srai: rd s: rs imm: v [
    "Emits `srai rd, rs, v`."
    self i: 7 d: rd s: rs imm: v ]
JitCompiler >> lui: rd imm: v [
    "Emits `lui rd, v`: the upper 16 bits of a constant."
    self i: 10 d: rd s: 0 imm: v ]
JitCompiler >> ld: rd off: v base: rs [
    "Emits `ld rd, v(rs)`: a 64-bit load."
    self i: 16 d: rd s: rs imm: v ]
JitCompiler >> sd: rv off: v base: rs [
    "Emits `sd rv, v(rs)`: a 64-bit store."
    self i: 24 d: rv s: rs imm: v ]
JitCompiler >> branch: op a: ra b: rb to: index [
    "Emits a conditional branch from ra and rb to instruction index (relative
     to here). op is 32 beq, 33 bne, 34 blt or 35 bge."
    self i: op d: ra s: rb imm: index - self here ]
JitCompiler >> jumpTo: index [
    "Emits `j` to instruction index (a 21-bit offset relative to here)."
    self w: (40 bitShift: 26) + ((index - self here) bitAnd: 16r1FFFFF) ]
JitCompiler >> call: helperIndex [
    "Emits a call of VM helper helperIndex: `jalr ra, gp, H - 0x10000`."
    self i: 41 d: 1 s: 3 imm: (self helper: helperIndex) - 16r10000 ]
JitCompiler >> goto: helperIndex [
    "Emits a jump to VM helper helperIndex that does not come back: `jalr
     zero, gp, H - 0x10000`."
    self i: 41 d: 0 s: 3 imm: (self helper: helperIndex) - 16r10000 ]
JitCompiler >> li: rd far: v [
    "Emits a load of constant v into rd as lui and ori: always two
     instructions, whatever v is (v below 2^31), so that templates keep fixed
     sizes."
    self lui: rd imm: (v bitShift: -16). self ori: rd s: rd imm: (v bitAnd: 16rFFFF) ]
"registers"
JitCompiler >> zero [
    "The register number of zero (0)."
    ^0 ]
JitCompiler >> sp [
    "The register number of sp (2), the operand stack pointer."
    ^2 ]
JitCompiler >> t0 [
    "The register number of t0 (5), a scratch register."
    ^5 ]
JitCompiler >> t1 [
    "The register number of t1 (6), a scratch register."
    ^6 ]
JitCompiler >> t2 [
    "The register number of t2 (7), a scratch register."
    ^7 ]
JitCompiler >> a0 [
    "The register number of a0 (10), the first argument to a VM helper and its
     answer."
    ^10 ]
JitCompiler >> a1 [
    "The register number of a1 (11), the second argument to a VM helper."
    ^11 ]
JitCompiler >> a2 [
    "The register number of a2 (12), the third argument to a VM helper (often
     the far address to come back to)."
    ^12 ]
JitCompiler >> t3 [
    "The register number of t3 (28), a scratch register."
    ^28 ]
JitCompiler >> t4 [
    "The register number of t4 (29), a scratch register."
    ^29 ]
JitCompiler >> t5 [
    "The register number of t5 (30), a scratch register."
    ^30 ]
JitCompiler >> fp [
    "The register number of the frame pointer s1 (9); temps are at negative
     offsets from it."
    ^9 ]
JitCompiler >> self4 [
    "The register number of s4 (20), which holds the receiver."
    ^20 ]
JitCompiler >> trueReg [
    "The register number of s7 (23), which holds true."
    ^23 ]
JitCompiler >> falseReg [
    "The register number of s8 (24), which holds false."
    ^24 ]
JitCompiler >> lits [
    "The register number of s10 (26), which holds the address of the method's
     literals."
    ^26 ]

"---- the templates ----"

JitCompiler >> push: r [
    "Emits a push of register r on the operand stack: sp down by 8, then `sd
     r, 0(sp)`."
    self addi: self sp s: self sp imm: -8. self sd: r off: 0 base: self sp ]
JitCompiler >> pop [
    "Emits a pop of the operand stack's top: sp up by 8."
    self addi: self sp s: self sp imm: 8 ]
JitCompiler >> emit: op at: pc [
    "Emits the template for bytecode op at pc, its operands taken from the
     next two bytes. Pushes, temps, literals and stores are done in place;
     instance variables and literal variables call the VM's slot load and
     store helpers (11, 12); returns, closures, arrays, temp vectors and sends
     go to the VM helpers, a send passing the far address to come back to (a
     far link). Signals an Error for a bytecode without a template."
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
JitCompiler >> offset: a b: b [
    "The signed 16-bit jump offset whose high byte is a and low byte is b.
     (JitCompiler new offset: 255 b: 254) >>> -2"
    | off | off := (a bitShift: 8) + b. ^off >= 32768 ifTrue: [off - 65536] ifFalse: [off] ]
JitCompiler >> conditional: onTrue at: pc a: a b: b [
    "Emits jumpTrue (onTrue true) or jumpFalse at pc, operand bytes a and b:
     tests the top against the true and false registers, pops it and jumps to
     the target or falls through to the next bytecode. Any other object goes
     to the VM's mustBeBoolean helper (4) with the test's far address in a2."
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
    "Emits sendSpecial k. == and ~~ and class are done in place; for + - < >
     <= >= = ~= * bitAnd: bitOr: the SmallInteger case is done in place (with
     an overflow check for + - and *), and anything else goes to the slow
     path, the VM's special send helper (3) with the far address to come back
     to. The other special selectors are always sent (sendSpecial:). Signals
     an Error if the fast path's length does not match fastLength:."
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
    "The number of instructions from the start of special send k's code to its
     slow path: the SmallInteger test (5), k's own fast code, and the store
     and jump (3)."
    k = 0 ifTrue: [^5 + 6 + 3].
    k = 1 ifTrue: [^5 + 6 + 3].
    k = 8 ifTrue: [^5 + 11 + 3].
    (k = 12 or: [k = 13]) ifTrue: [^5 + 1 + 3].
    ^5 + 3 + 3 ]
JitCompiler >> sendSpecial: k [
    "Emits a send of special selector k through the VM's special send helper
     (3), passing the far address of the instruction after it to come back to."
    self addi: self a0 s: 0 imm: k.
    self li: self a2 far: self farHere + 12.
    self goto: 3 ]
JitCompiler >> identity: same [
    "Emits == (same true) or ~~ in place: pops the argument and replaces the
     receiver with the Boolean."
    self ld: self t1 off: 0 base: self sp.
    self ld: self t0 off: 8 base: self sp.
    self pop.
    self addi: self t2 s: (same ifTrue: [self trueReg] ifFalse: [self falseReg]) imm: 0.
    self branch: 32 a: self t0 b: self t1 to: self here + 2.
    self addi: self t2 s: (same ifTrue: [self falseReg] ifFalse: [self trueReg]) imm: 0.
    self sd: self t2 off: 0 base: self sp ]
