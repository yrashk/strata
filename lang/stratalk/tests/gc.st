| l | l := nil. 1 to: 5000 do: [:i | l := Array with: i with: l]. | s | s := 0. [l notNil] whileTrue: [s := s + (l at: 1). l := l at: 2]. s
| a | a := Array new: 300. 1 to: 300 do: [:i | a at: i put: (Array with: i with: i printString)]. (a inject: 0 into: [:s :e | s + (e at: 1)]) + (a at: 300) last size
| big | big := Array new: 1000. 1 to: 1000 do: [:i | big at: i put: i * 2]. big inject: 0 into: [:s :e | s + e]
| big | big := Array new: 2000. 1 to: 2000 do: [:i | big at: i put: (OrderedCollection with: i)]. (big collect: [:o | o first]) inject: 0 into: [:s :e | s + e]
| d | d := Dictionary new. 1 to: 2000 do: [:i | d at: i printString put: i]. (d at: '1999') + (d at: '7')
| o | o := OrderedCollection new. 1 to: 3000 do: [:i | o add: i printString]. (o inject: 0 into: [:s :e | s + e size])
| keep | keep := (1 to: 100) collect: [:i | String new: 100 withAll: $x]. 1 to: 20000 do: [:i | Array new: 4]. keep inject: 0 into: [:s :e | s + e size]
| s | s := WriteStream on: String new. 1 to: 2000 do: [:i | s nextPutAll: i printString]. s contents size
(1 to: 10000) inject: 0 into: [:a :b | a + b]
| arr | arr := (1 to: 200) asArray. 1 to: 50 do: [:k | arr := arr collect: [:e | e + 1]]. arr last
(Smalltalk vm at: 'scavenges') > 0
| x | x := Array new: 3. x isNear
(Array new: 3000) isNear
#sym isNear
| m | m := (1 to: 400) collect: [:i | i -> i squared]. Smalltalk scavenge. (m at: 400) value
