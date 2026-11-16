"exceptions.st: signal, handle, resume, retry, ensure."

| attempts r log |
r := [10 / 0] on: ZeroDivide do: [:e | Transcript showln: 'caught: ', e messageText. 0].
Transcript showln: 'result: ', r printString.

r := [(Warning signal: 'careful') ifNil: ['resumed with nil'] ifNotNil: [:v | v]]
    on: Warning do: [:e | e resume: 'resumed with a value'].
Transcript showln: r.

attempts := 0.
r := [attempts := attempts + 1. attempts < 3 ifTrue: [Error signal: 'not yet']. attempts]
    on: Error do: [:e | e retry].
Transcript showln: 'succeeded after ', r printString, ' attempts'.

log := OrderedCollection new.
[[log add: 'work'. nil foo] ensure: [log add: 'cleanup']]
    on: MessageNotUnderstood do: [:e | log add: 'handled ', e message selector].
Transcript showln: log asArray printString.
