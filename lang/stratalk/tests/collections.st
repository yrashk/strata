| o | o := OrderedCollection new. 1 to: 20 do: [:i | o add: i]. {o size. o first. o last}
| o | o := OrderedCollection new. 1 to: 20 do: [:i | o addFirst: i]. {o size. o first. o last}
| o | o := OrderedCollection withAll: #(1 2 3 4 5). o removeFirst. o removeLast. o
| o | o := OrderedCollection withAll: #(1 2 3 4 5). o remove: 3. o
| o | o := OrderedCollection withAll: #(1 2 3). o insert: 9 before: 2. o
[OrderedCollection new removeFirst] on: Error do: [:e | 'empty']
[OrderedCollection new remove: 5] on: NotFound do: [:e | 'not found']
| d | d := Dictionary new. 1 to: 500 do: [:i | d at: i put: i * i]. {d size. d at: 499. d at: 1}
| d | d := Dictionary new. 1 to: 100 do: [:i | d at: i put: i]. 1 to: 100 by: 2 do: [:i | d removeKey: i]. {d size. (d keys asSortedCollection: [:a :b | a <= b]) first: 3. d includesKey: 51. d includesKey: 52}
| d | d := Dictionary new. d at: 'one' put: 1. d at: 'one' copy put: 11. {d size. d at: 'one'}
| d | d := IdentityDictionary new. d at: #a put: 1; at: #b put: 2. (d keys asSortedCollection: [:x :y | x <= y]) asArray
| d | d := Dictionary new. d at: #k ifAbsent: [0]
| d | d := Dictionary new. (d at: #k ifAbsentPut: [5]) + (d at: #k)
| s | s := Set new. #(1 2 2 3 3 3) do: [:e | s add: e]. s size
| s | s := Set withAll: (1 to: 50). 1 to: 50 by: 3 do: [:i | s remove: i]. {s size. s includes: 4. s includes: 5}
#(1 2 3) asOrderedCollection asArray
(1 to: 5) asArray
(1 to: 10 by: 3) asArray
(10 to: 1 by: -4) asArray
(1 to: 0) asArray
(1 to: 5) reversed
#(5 3 8 1 9 2) asSortedCollection asArray
#(5 3 8 1 9 2) sorted: [:a :b | a > b]
| a | a := (1 to: 300) asArray reversed. a sort. {a first. a last. (a at: 150)}
#('pear' 'apple' 'fig') sorted
#(3 1 2) , #(4)
#(1 2 3) indexOf: 3
#(1 2 3) includes: 4
(Array new: 3)
Array with: 1 with: 2 with: 3
(Array new: 2 withAll: 7)
#(1 2 3 4 5) copyFrom: 2 to: 4
#(1 2 3) copyWith: 4
#(1 2 3) = #(1 2 3)
#(1 2 3) = #(1 2 4)
#(1 2 3) sum
#(4 9 2) max
| a | a := Array new: 5. a replaceFrom: 2 to: 4 with: #(7 8 9) startingAt: 1. a
| a | a := (1 to: 6) asArray. a replaceFrom: 2 to: 5 with: a startingAt: 1. a
| ws | ws := WriteStream on: String new. ws nextPutAll: 'abc'; nextPut: $d; print: 42. ws contents
| rs | rs := ReadStream on: #(1 2 3). {rs next. rs next. rs atEnd. rs next. rs atEnd}
('one two  three' substrings: ' ') asArray
'hello world' asUppercase
'Hello' reversed
'hello' indexOf: $l
'hello world' includesSubstring: 'o w'
'hello' , ' ' , 'there'
'abc' < 'abd'
'abc' = 'abc' copy
'abc' hash = 'abc' copy hash
'a-b-c' copyReplaceAll: '-' with: '--'
'{1} + {2}' format: #(3 4)
'  trim me  ' trimSeparators
'hello' first
'hello' asSymbol
#with:with: numArgs
#+ numArgs
'hello' size
'x' , 3 printString
3 printString , 'x'
(1 -> 2) key
'abc' asByteArray
#[1 2 255] size
(3 @ 4) + (1 @ 1)
(3 @ 4) = (3 @ 4)
(OrderedCollection withAll: #(1 2)) copyWith: 3
(OrderedCollection withAll: #(1 2)) with: #(10 20) collect: [:a :b | a + b]
'abc' occurrencesOfString: ''
'abc' copyReplaceAll: '' with: 'x'
0 lcm: 0
| w | w := WriteStream on: String new. w nextPutAll: 'abc'; position: 0; setToEnd. w position
(ReadStream on: #(1 2 3)) next: 2
#(1 $a -2 'x' #y) isLiteral
(Set withAll: #(1 2)) = (Set withAll: #(2 1))
(Dictionary new at: 1 put: 2; yourself) = (Dictionary new at: 1 put: 3; yourself)
| a | a := Array with: 'x'. a deepCopy first == a first
| t n | t := Smalltalk symbolTable size. 1 to: t do: [:i | ('zz', i printString) asSymbol]. Smalltalk symbolTable size > t
#zz17 == ('zz', '17') asSymbol
(Message new selector: #at:put: arguments: #(1 2)) printString
