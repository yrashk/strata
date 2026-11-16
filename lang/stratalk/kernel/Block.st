"Block.st: closures and compiled code."

Object subclass: #BlockClosure slots: 'block receiver homeFrame homeSerial'.
Object methodSubclass: #CompiledCode slots: ''.
CompiledCode subclass: #CompiledMethod slots: ''.
CompiledCode subclass: #CompiledBlock slots: ''.

"---- BlockClosure: the VM activates the block on value; the copied values
 follow the four slots -----------------------------------------------------------"

BlockClosure >> isBlock [ ^true ]
BlockClosure >> numArgs [ ^block numArgs ]
BlockClosure >> receiver [ ^receiver ]
BlockClosure >> compiledBlock [ ^block ]
BlockClosure >> value [ <primitive: 70> ^self numArgsError: 0 ]
BlockClosure >> value: a [ <primitive: 70> ^self numArgsError: 1 ]
BlockClosure >> value: a value: b [ <primitive: 70> ^self numArgsError: 2 ]
BlockClosure >> value: a value: b value: c [ <primitive: 70> ^self numArgsError: 3 ]
BlockClosure >> value: a value: b value: c value: d [ <primitive: 70> ^self numArgsError: 4 ]
BlockClosure >> valueWithArguments: anArray [ <primitive: 71> ^self numArgsError: anArray size ]
BlockClosure >> numArgsError: n [
    ^self error: 'this block takes ', self numArgs printString, ' arguments, not ', n printString ]
BlockClosure >> cull: a [ ^self numArgs = 0 ifTrue: [self value] ifFalse: [self value: a] ]
BlockClosure >> cull: a cull: b [
    self numArgs = 0 ifTrue: [^self value].
    self numArgs = 1 ifTrue: [^self value: a].
    ^self value: a value: b ]
BlockClosure >> whileTrue: aBlock [ [self value] whileTrue: [aBlock value]. ^nil ]
BlockClosure >> whileFalse: aBlock [ [self value] whileFalse: [aBlock value]. ^nil ]
BlockClosure >> whileTrue [ [self value] whileTrue. ^nil ]
BlockClosure >> whileFalse [ [self value] whileFalse. ^nil ]
BlockClosure >> repeat [ [self value] repeat ]
BlockClosure >> ensure: aBlock [
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
    <primitive: 198>
    | result f |
    result := self value.
    f := Frame current.
    Frame flags: ((Frame flags: f) bitOr: 8) of: f.
    ^result ]
BlockClosure >> on: exceptionClass do: handlerBlock [
    "The VM marks this frame (primitive 199): signal looks for it."
    <primitive: 199>
    ^self value ]
BlockClosure >> on: exceptionClass do: handlerBlock on: class2 do: handler2 [
    ^[self on: exceptionClass do: handlerBlock] on: class2 do: handler2 ]
BlockClosure >> unwindAndReturn: anObject to: aFrame [
    "A ^ in this block leaves through ensure: blocks: run them, then return."
    Frame unwindTo: aFrame from: (Frame sender: Frame current).
    Frame return: anObject to: aFrame ]
BlockClosure >> cannotReturn: anObject [
    ^BlockCannotReturn new signal: 'the method this block would return from has returned already' ]
BlockClosure >> printOn: aStream [ aStream nextPutAll: 'a BlockClosure' ]
BlockClosure >> timeToRun [ | t | t := Smalltalk milliseconds. self value. ^Smalltalk milliseconds - t ]

"---- compiled code: a header (a SmallInteger), the literals, the bytecodes ------"

CompiledCode >> header [ <primitive: 75> ]
CompiledCode >> numArgs [ ^self header bitAnd: 255 ]
CompiledCode >> numTemps [ ^(self header bitShift: -8) bitAnd: 255 ]
CompiledCode >> numLiterals [ ^(self header bitShift: -16) bitAnd: 255 ]
CompiledCode >> primitive [ ^(self header bitShift: -24) bitAnd: 4095 ]
CompiledCode >> numCopied [ ^(self header bitShift: -36) bitAnd: 255 ]
CompiledCode >> literalAt: i [ <primitive: 76> ^self indexError: i ]
CompiledCode >> literalAt: i put: v [ <primitive: 80> ^self indexError: i ]
CompiledCode >> byteAt: i [ <primitive: 77> ^self indexError: i ]
CompiledCode >> byteAt: i put: b [ <primitive: 81> ^self indexError: i ]
CompiledCode >> numBytes [ <primitive: 78> ]
CompiledCode >> literals [ | a | a := Array new: self numLiterals. 1 to: a size do: [:i | a at: i put: (self literalAt: i)]. ^a ]
CompiledCode >> bytecodes [ | a | a := ByteArray new: self numBytes. 1 to: a size do: [:i | a at: i put: (self byteAt: i)]. ^a ]
CompiledCode >> methodClass [ ^self literalAt: self numLiterals ]
CompiledCode class >> header: h numBytes: n [ "Made in far memory" <primitive: 79> ]
CompiledMethod >> selector [ ^self literalAt: self numLiterals - 1 ]
CompiledMethod >> printOn: aStream [ aStream print: self methodClass; nextPutAll: '>>'; nextPutAll: self selector ]
CompiledBlock >> selector [ ^'[] in' ]
CompiledBlock >> printOn: aStream [ aStream nextPutAll: 'a CompiledBlock' ]
