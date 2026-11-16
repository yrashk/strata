[] value
[3] value
[:a :b | a * b] value: 6 value: 7
[:a :b :c :d | a + b + c + d] value: 1 value: 2 value: 3 value: 4
[:a | a] valueWithArguments: #(9)
[:a :b | a] numArgs
| c | c := 0. 1 to: 10 do: [:i | c := c + i]. c
| bs | bs := (1 to: 3) collect: [:i | [i * 10]]. bs collect: [:b | b value]
| n inc | n := 0. inc := [n := n + 1]. inc value. inc value. inc value. n
| mk a b | mk := [:start | | x | x := start. [x := x + 1]]. a := mk value: 10. b := mk value: 100. a value. a value. b value. {a value. b value}
| acc | acc := OrderedCollection new. #(1 2 3) do: [:x | #(10 20) do: [:y | acc add: x * y]]. acc
| i | i := 0. [i < 5] whileTrue: [i := i + 1]. i
| i | i := 10. [i <= 0] whileFalse: [i := i - 3]. i
| i | i := 0. [i := i + 1. i < 7] whileTrue. i
| s | s := 0. 10 to: 1 by: -3 do: [:k | s := s * 100 + k]. s
| s | s := 0. 1 to: 0 do: [:k | s := 99]. s
| s | s := 0. 5 timesRepeat: [s := s + 2]. s
(1 to: 5) inject: 1 into: [:a :b | a * b]
#(1 2 3 4 5 6) detect: [:x | x > 4]
#(1 2 3) detect: [:x | x > 4] ifNone: ['none']
(#(1 2 3 4) select: [:x | x even]) , (#(1 2 3 4) reject: [:x | x even])
#(3 4) with: #(10 20) collect: [:a :b | a * b]
#(1 2 3) allSatisfy: [:x | x > 0]
#(1 2 3) anySatisfy: [:x | x > 2]
(1 to: 10) count: [:x | x isPrime]
nil ifNil: [1] ifNotNil: [:x | x]
5 ifNil: [1] ifNotNil: [:x | x * 2]
nil ifNotNil: [:x | x]
7 ifNil: [0]
(3 > 2) & (2 > 3)
(3 > 2) | (2 > 3)
(3 > 2) and: [2 > 3]
(3 < 2) or: [2 < 3]
3 > 2 ifTrue: ['yes'] ifFalse: ['no']
3 < 2 ifTrue: ['yes']
#(1 $a 'x' #s nil true) collect: [:e | e class]
[:x | x] value: [:y | y + 1]
([:x | x] value: [:y | y + 1]) value: 41
#(5 3 9 1) inject: 0 into: [:m :e | m max: e]
#(1 2 3) reverse
| r | r := OrderedCollection new. #(1 2 3) reverseDo: [:e | r add: e]. r
| r | r := OrderedCollection new. #(a b c) doWithIndex: [:e :i | r add: i -> e]. r
#size value: 'four'
#(1 2 3) collect: #squared
| fact | fact := nil. fact := [:n | n <= 1 ifTrue: [1] ifFalse: [n * (fact value: n - 1)]]. fact value: 20
| find | find := [:coll :x | | r | r := nil. coll do: [:e | e = x ifTrue: [r := e]]. r]. find value: #(1 2 3) value: 2
