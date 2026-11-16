"Block.st: closures and compiled code."

Object subclass: #BlockClosure slots: 'block receiver homeFrame homeSerial'.
"A block as a value: [:x | x + 1]. block is its CompiledBlock, receiver
 the self of the method that made it, homeFrame and homeSerial name that
 method's frame, where a ^ in the block returns to. The values the block
 copies from its home (the variables it reads) follow the four slots. The
 VM runs it on value and its kin (primitive 70).
 [:x | x + 1] value: 2 >>> 3"

Object methodSubclass: #CompiledCode slots: ''.
"Compiled code (format 3): a header (a SmallInteger), the literals, then
 the bytecodes. The header holds the number of arguments (bits 0-7), of
 temps (8-15), of literals (16-23), the primitive number (24-35) and the
 number of copied values of a block (36-43). Made in far memory; the
 compiler and the JIT read and write it with the primitives 75 to 81.
 (Object >> #isKindOf:) numArgs >>> 1"

CompiledCode subclass: #CompiledMethod slots: ''.
"A method: CompiledCode whose last two literals are its selector and the
 class it is defined in. The values of a MethodDictionary.
 (Object >> #yourself) printString >>> 'Object>>yourself'"

CompiledCode subclass: #CompiledBlock slots: ''.
"The code of a block, a literal of the method it is in; each BlockClosure
 made from it pairs it with a receiver and the copied values.
 [:a :b | a] compiledBlock numArgs >>> 2"

"---- BlockClosure: the VM activates the block on value; the copied values
 follow the four slots -----------------------------------------------------------"

BlockClosure >> isBlock [
    "Answers true: the receiver is a block.
     [] isBlock >>> true"
    ^true ]
BlockClosure >> numArgs [
    "The number of arguments the block takes.
     [:a :b | a] numArgs >>> 2"
    ^block numArgs ]
BlockClosure >> receiver [
    "The self of the method that made the block; nil for a block typed at
     the REPL.
     [] receiver >>> nil"
    ^receiver ]
BlockClosure >> compiledBlock [
    "The CompiledBlock the block runs.
     [:a | a] compiledBlock numArgs >>> 1"
    ^block ]
BlockClosure >> value [
    "Runs the block with no arguments and answers its last expression's
     value. A VM primitive (70); signals an Error if the block takes
     arguments.
     [3 + 4] value >>> 7"
    <primitive: 70> ^self numArgsError: 0 ]
BlockClosure >> value: a [
    "Runs the block with the argument a and answers its value. A VM
     primitive (70); signals an Error if the block does not take one
     argument.
     [:a | a * 2] value: 3 >>> 6"
    <primitive: 70> ^self numArgsError: 1 ]
BlockClosure >> value: a value: b [
    "Runs the block with the arguments a and b and answers its value. A VM
     primitive (70); signals an Error if the block does not take two.
     [:a :b | a - b] value: 7 value: 2 >>> 5"
    <primitive: 70> ^self numArgsError: 2 ]
BlockClosure >> value: a value: b value: c [
    "Runs the block with three arguments and answers its value. A VM
     primitive (70); signals an Error if the block does not take three.
     [:a :b :c | a + b + c] value: 1 value: 2 value: 3 >>> 6"
    <primitive: 70> ^self numArgsError: 3 ]
BlockClosure >> value: a value: b value: c value: d [
    "Runs the block with four arguments and answers its value. A VM
     primitive (70); signals an Error if the block does not take four.
     [:a :b :c :d | a + b + c + d] value: 1 value: 2 value: 3 value: 4 >>> 10"
    <primitive: 70> ^self numArgsError: 4 ]
BlockClosure >> valueWithArguments: anArray [
    "Runs the block with the elements of anArray (an Array, at most 15) as
     its arguments and answers its value. A VM primitive (71); signals an
     Error if their number is not the block's.
     [:a :b | a + b] valueWithArguments: #(3 4) >>> 7"
    <primitive: 71> ^self numArgsError: anArray size ]
BlockClosure >> numArgsError: n [
    "Signals an Error saying that the block was given n arguments, not the
     number it takes.
     [[:a | a] value] on: Error do: [:e | e messageText] >>> 'this block takes 1 arguments, not 0'"
    ^self error: 'this block takes ', self numArgs printString, ' arguments, not ', n printString ]
BlockClosure >> cull: a [
    "Runs the block with a if it takes an argument, with none if it takes
     none, and answers its value.
     [7] cull: 3 >>> 7"
    ^self numArgs = 0 ifTrue: [self value] ifFalse: [self value: a] ]
BlockClosure >> cull: a cull: b [
    "Runs the block with as many of a and b as it takes (none, a, or both)
     and answers its value.
     [:a | a] cull: 3 cull: 4 >>> 3"
    self numArgs = 0 ifTrue: [^self value].
    self numArgs = 1 ifTrue: [^self value: a].
    ^self value: a value: b ]
BlockClosure >> whileTrue: aBlock [
    "Runs aBlock as long as the receiver's value is true, testing first, and
     answers nil. Compiled in line when both are literal blocks.
     | i | i := 0. [i < 5] whileTrue: [i := i + 1]. i >>> 5"
    [self value] whileTrue: [aBlock value]. ^nil ]
BlockClosure >> whileFalse: aBlock [
    "Runs aBlock as long as the receiver's value is false, testing first,
     and answers nil. Compiled in line when both are literal blocks.
     | i | i := 0. [i >= 5] whileFalse: [i := i + 1]. i >>> 5"
    [self value] whileFalse: [aBlock value]. ^nil ]
BlockClosure >> whileTrue [
    "Runs the receiver again as long as its value is true, and answers nil.
     | i | i := 0. [i := i + 1. i < 3] whileTrue. i >>> 3"
    [self value] whileTrue. ^nil ]
BlockClosure >> whileFalse [
    "Runs the receiver again as long as its value is false, and answers nil.
     | i | i := 0. [i := i + 1. i >= 3] whileFalse. i >>> 3"
    [self value] whileFalse. ^nil ]
BlockClosure >> repeat [
    "Runs the receiver over and over; it ends only by a ^, an exception or
     the end of the program.
     | i | i := 0. [[i := i + 1. i = 4 ifTrue: [Error signal]] repeat] on: Error do: [:e | i] >>> 4"
    [self value] repeat ]
BlockClosure >> ensure: aBlock [
    "Answers the receiver's value, and runs aBlock after it once, whether the
     receiver ends normally or is left by a ^ or an exception's unwinding.
     The VM marks this frame (primitive 198) for Frame class >>
     unwindTo:from:. A handler runs before the unwinding, so aBlock has not
     run yet while it does.
     | n | n := 0. [[1/0] ensure: [n := 1]] on: ZeroDivide do: [:e | 0]. n >>> 1"
    "The VM marks this frame (primitive 198): an unwind runs aBlock."
    <primitive: 198>
    | result f |
    result := self value.
    f := Frame current.
    ((Frame flags: f) bitAnd: 8) = 0 ifTrue: [
        Frame flags: ((Frame flags: f) bitOr: 8) of: f.
        aBlock value].
    ^result ]
BlockClosure >> ifCurtailed: aBlock [
    "Answers the receiver's value; runs aBlock only if the receiver does not
     end normally (a ^ or an exception unwinds through it). The VM marks this
     frame (primitive 198), as for ensure:.
     | n | n := 0. [[1/0] ifCurtailed: [n := 1]] on: ZeroDivide do: [:e | 0]. n >>> 1"
    <primitive: 198>
    | result f |
    result := self value.
    f := Frame current.
    Frame flags: ((Frame flags: f) bitOr: 8) of: f.
    ^result ]
BlockClosure >> on: exceptionClass do: handlerBlock [
    "Answers the receiver's value; if an exception that exceptionClass
     handles (a class or an ExceptionSet) is signalled meanwhile, answers
     handlerBlock's value instead, given the exception if it takes an
     argument. The VM marks this frame (primitive 199), which signal looks
     for. The handler can also resume:, retry, return:, pass the exception.
     [1/0] on: ZeroDivide do: [:e | e messageText] >>> 'division by zero'"
    "The VM marks this frame (primitive 199): signal looks for it."
    <primitive: 199>
    ^self value ]
BlockClosure >> on: exceptionClass do: handlerBlock on: class2 do: handler2 [
    "Answers the receiver's value with two handlers: handlerBlock for
     exceptionClass, handler2 for class2; the first is looked at first.
     [nil foo] on: ZeroDivide do: [:e | 1] on: MessageNotUnderstood do: [:e | 2] >>> 2"
    ^[self on: exceptionClass do: handlerBlock] on: class2 do: handler2 ]
BlockClosure >> unwindAndReturn: anObject to: aFrame [
    "Returns anObject from aFrame after running the unwind blocks of the
     frames above it. The VM sends this for a ^ in a block when frames with
     unwind blocks lie between the block and its home method."
    "A ^ in this block leaves through ensure: blocks: run them, then return."
    Frame unwindTo: aFrame from: (Frame sender: Frame current).
    Frame return: anObject to: aFrame ]
BlockClosure >> cannotReturn: anObject [
    "Signals BlockCannotReturn. The VM sends this for a ^ in a block whose
     home method has returned already.
     | b | b := Compiler evaluate: '[:x | ^x]'. [b value: 3] on: BlockCannotReturn do: [:e | e class] >>> BlockCannotReturn"
    ^BlockCannotReturn new signal: 'the method this block would return from has returned already' ]
BlockClosure >> printOn: aStream [
    "Writes 'a BlockClosure' on aStream.
     [] printString >>> 'a BlockClosure'"
    aStream nextPutAll: 'a BlockClosure' ]
BlockClosure >> timeToRun [
    "Runs the block and answers how long it took, in milliseconds (Smalltalk
     milliseconds)."
    | t | t := Smalltalk milliseconds. self value. ^Smalltalk milliseconds - t ]

"---- compiled code: a header (a SmallInteger), the literals, the bytecodes ------"

CompiledCode >> header [
    "The header word, a SmallInteger with the counts and the primitive
     number. A VM primitive (75).
     (Object >> #yourself) header >>> 131072"
    <primitive: 75> ]
CompiledCode >> numArgs [
    "The number of arguments.
     (Object >> #isKindOf:) numArgs >>> 1"
    ^self header bitAnd: 255 ]
CompiledCode >> numTemps [
    "The number of temps besides the arguments.
     (Object >> #isKindOf:) numTemps >>> 1"
    ^(self header bitShift: -8) bitAnd: 255 ]
CompiledCode >> numLiterals [
    "The number of literals, the selector and the class of a method included.
     (Object >> #yourself) numLiterals >>> 2"
    ^(self header bitShift: -16) bitAnd: 255 ]
CompiledCode >> primitive [
    "The number of the VM primitive the code tries first, 0 for none.
     (Object >> #class) primitive >>> 41"
    ^(self header bitShift: -24) bitAnd: 4095 ]
CompiledCode >> numCopied [
    "The number of values a block copies from its home when it is made; 0
     for a method.
     | x | x := 3. [:a | a + x] compiledBlock numCopied >>> 1"
    ^(self header bitShift: -36) bitAnd: 255 ]
CompiledCode >> literalAt: i [
    "Answers literal i (1-based). A VM primitive (76); on failure,
     indexError:.
     (Object >> #yourself) literalAt: 1 >>> #yourself"
    <primitive: 76> ^self indexError: i ]
CompiledCode >> literalAt: i put: v [
    "Stores v as literal i (1-based) and answers it; the VM forgets the
     method's cached copy. A VM primitive (80); on failure, indexError:."
    <primitive: 80> ^self indexError: i ]
CompiledCode >> byteAt: i [
    "Answers bytecode i (1-based), a SmallInteger. A VM primitive (77); on
     failure, indexError:.
     (Object >> #yourself) byteAt: 1 >>> 8"
    <primitive: 77> ^self indexError: i ]
CompiledCode >> byteAt: i put: b [
    "Stores the byte b (0 to 255) as bytecode i (1-based) and answers it;
     the VM forgets the method's cached copy. A VM primitive (81); on
     failure, indexError:."
    <primitive: 81> ^self indexError: i ]
CompiledCode >> numBytes [
    "The number of bytecodes. A VM primitive (78).
     (Object >> #yourself) numBytes >>> 1"
    <primitive: 78> ]
CompiledCode >> literals [
    "Answers the literals, as an Array.
     (Object >> #yourself) literals >>> #(#yourself Object)"
    | a | a := Array new: self numLiterals. 1 to: a size do: [:i | a at: i put: (self literalAt: i)]. ^a ]
CompiledCode >> bytecodes [
    "Answers the bytecodes, as a ByteArray.
     (Object >> #yourself) bytecodes >>> #[8]"
    | a | a := ByteArray new: self numBytes. 1 to: a size do: [:i | a at: i put: (self byteAt: i)]. ^a ]
CompiledCode >> methodClass [
    "The class the method is defined in: its last literal.
     (Object >> #yourself) methodClass >>> Object"
    ^self literalAt: self numLiterals ]
CompiledCode class >> header: h numBytes: n [
    "Answers new compiled code of this class with the header h, room for as
     many literals as h says and for n bytecodes, made in far memory: what
     the Compiler fills in. A VM primitive (79)."
    "Made in far memory" <primitive: 79> ]
CompiledMethod >> selector [
    "The method's selector: its literal before the last.
     (Object >> #yourself) selector >>> #yourself"
    ^self literalAt: self numLiterals - 1 ]
CompiledMethod >> printOn: aStream [
    "Writes the class and the selector on aStream, as Class>>selector.
     (Object >> #yourself) printString >>> 'Object>>yourself'"
    aStream print: self methodClass; nextPutAll: '>>'; nextPutAll: self selector ]
CompiledBlock >> selector [
    "Answers '[] in': a block has no selector of its own (for backtraces).
     [] compiledBlock selector >>> '[] in'"
    ^'[] in' ]
CompiledBlock >> printOn: aStream [
    "Writes 'a CompiledBlock' on aStream.
     [] compiledBlock printString >>> 'a CompiledBlock'"
    aStream nextPutAll: 'a CompiledBlock' ]
