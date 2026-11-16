Object subclass: #Acc slots: 'n'
Acc compile: 'add: x n := (n ifNil: [0]) + x'
Acc compile: 'n ^n'
(Acc new add: 3; add: 4; yourself) n
Acc subclass: #Acc2 slots: 'm'
Acc2 compile: 'add: x m := x. ^super add: x * 10'
| a | a := Acc2 new. a add: 5. a n
Acc2 superclass
Acc2 new class class
Acc2 new isKindOf: Acc
Acc2 new respondsTo: #n
Acc2 new respondsTo: #zork
Integer compile: 'down self = 0 ifTrue: [^0]. ^(self - 1) down + 1'
50 down
200 down
1000 down
[100000000 down] on: StackOverflow do: [:e | 'overflow']
5000 down
Object compile: 'twice: aBlock ^{aBlock value. aBlock value}'
| k | k := 0. nil twice: [k := k + 1]
Object compile: 'findFirst: coll ^coll do: [:e | e > 2 ifTrue: [^e]]'
nil findFirst: #(1 2 3 4)
Object compile: 'escaper ^[:x | ^x]'
[nil escaper value: 5] on: BlockCannotReturn do: [:e | 'cannot return']
[Compiler evaluate: '1 +'] on: CompileError do: [:e | 'compile error']
[Compiler evaluate: 'x := '] on: CompileError do: [:e | 'compile error 2']
Compiler evaluate: '#(1 #(2 3) $a ''s'' #sym foo:bar: + nil true)'
Compiler evaluate: '{1+1. 2*3. #[1 2]}'
Compiler evaluate: '16rFF + 2r1010 + -5'
Compiler evaluate: '| a b | a := 3. b := [:x | x + a]. b value: 4'
Compiler evaluate: '3 + 4; * 10'
Compiler evaluate: '(OrderedCollection new) add: 1; add: 2; yourself'
(Acc >> #add:) numArgs
(Acc >> #n) selector
(Acc >> #n) methodClass
Acc2 instSize
Acc2 allInstVarNames asArray
Object subclass: #Acc slots: 'n'
[Compiler evaluate: '2r9'] on: Error do: [:e | e messageText]
[Compiler evaluate: '37r1'] on: Error do: [:e | e messageText]
Compiler evaluate: '16rFF + 2r101'
[Compiler evaluate: ((1 to: 300) inject: '' into: [:s :i | s , '''x' , i printString , ''' size + ']) , '0'] on: Error do: [:e | e messageText]
Compiler evaluate: ((1 to: 200) inject: '' into: [:s :i | s , '''x' , i printString , ''' size + ']) , '0'
Jit stats beginsWith: 'compiled '
