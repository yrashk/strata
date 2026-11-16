[1/0] on: ZeroDivide do: [:e | e class]
[1/0. 5] on: ZeroDivide do: [:e | e return: 7]
[(1/0) + 1] on: ZeroDivide do: [:e | e resume: 41]
[Warning signal: 'w'. 'after'] on: Warning do: [:e | e resume: nil]
([Warning signal: 'w'] on: Warning do: [:e | e resume: 'resumed'])
[nil foo] on: MessageNotUnderstood do: [:e | e message selector]
[nil foo: 1 bar: 2] on: MessageNotUnderstood do: [:e | e message arguments]
[3 zork] on: MessageNotUnderstood do: [:e | e receiver]
[nil foo] on: Error do: [:e | e messageText]
[#(1 2) at: 5] on: SubscriptOutOfBounds do: [:e | 'out']
[#(1 2) at: 5] on: Error do: [:e | e class]
[Dictionary new at: #missing] on: KeyNotFound do: [:e | 'no key']
[Error signal: 'boom'] on: Error do: [:e | e messageText]
[Error new signal: 'x'] on: ZeroDivide do: [:e | 'wrong'] on: Error do: [:e | 'right']
[[1/0] on: MessageNotUnderstood do: [:e | 'inner']] on: ZeroDivide do: [:e | 'outer']
[[1/0] on: ZeroDivide do: [:e | e pass]] on: ZeroDivide do: [:e | 'passed']
[[1/0] on: ZeroDivide do: [:e | e signal]] on: ZeroDivide do: [:e | 'resignalled']
[[Warning signal: 'a'] on: Warning do: [:e | e pass]] on: Warning do: [:e | e resume: 'outer resumed']
[1/0] on: ZeroDivide, MessageNotUnderstood do: [:e | 'set']
[nil foo] on: ZeroDivide, MessageNotUnderstood do: [:e | 'set2']
| log | log := OrderedCollection new. [log add: 1] ensure: [log add: 2]. log
| log | log := OrderedCollection new. [[log add: 1. 1/0. log add: 9] ensure: [log add: 2]] on: ZeroDivide do: [:e | log add: 3]. log
| log | log := OrderedCollection new. [[log add: 1. Error signal: 'e'] ifCurtailed: [log add: 2]] on: Error do: [:e | log add: 3]. log
| log | log := OrderedCollection new. [log add: 1] ifCurtailed: [log add: 2]. log
| log r | log := OrderedCollection new. r := [[log add: 1. 10] ensure: [log add: 2]] value. {r. log}
| n r | n := 0. r := [n := n + 1. n < 3 ifTrue: [Error signal: 'again']. n] on: Error do: [:e | e retry]. r
| log | log := OrderedCollection new. [[[1/0] ensure: [log add: #a]] ensure: [log add: #b]] on: ZeroDivide do: [:e | log add: #h]. log
[[1/0] ensure: [nil]] on: ZeroDivide do: [:e | e return: 'unwound']
[[:x | x] value] on: Error do: [:e | 'wrong arity']
[Error signal: 'outer'] on: Error do: [:e | [Error signal: 'inner'] on: Error do: [:e2 | e messageText , '/' , e2 messageText]]
[ZeroDivide new signal: 'z'] on: Error do: [:e | e isResumable]
[Error new signal] on: Error do: [:e | e messageText]
[(Array new: 3) at: 4 put: 1] on: Error do: [:e | 'store out']
[#(1 2) at: 1 put: 3] on: Error do: [:e | 'literal']
['abc' at: 1 put: $z] on: Error do: [:e | 'literal string']
| s | s := 'abc' copy. s at: 1 put: $z. s
[true ifTrue: 3] on: Error do: [:e | 'ok']
[3 ifTrue: [4]] on: NonBooleanReceiver do: [:e | 'not boolean']
[3 ifTrue: [4] ifFalse: [5]] on: NonBooleanReceiver do: [:e | e resume: false]
[3 perform: #+ withArguments: #()] on: Error do: [:e | e messageText]
[3 perform: #negated with: 5] on: Error do: [:e | e messageText]
3 perform: #between:and: with: 1 with: 5
[[Warning signal. 1] on: Warning do: [:e | e outer + 10]] on: Warning do: [:e | e resume: 5]
| n | n := 0. [n := n + 1. 1/0] on: ZeroDivide do: [:e | n < 3 ifTrue: [e retryUsing: [n := n + 1. 1/0]] ifFalse: [n]]
[Smalltalk vm at: 'nonsense'] on: NotFound do: [:e | e messageText]
