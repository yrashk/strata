Object subclass: #FakeWindow slots: 'events drawn'. #ok
FakeWindow compile: 'events: c [ events := OrderedCollection new. drawn := OrderedCollection new. c do: [:k | self add: k] ]'. #ok
FakeWindow compile: 'add: k [ k isString ifFalse: [^events add: k]. 1 to: k size by: 8 do: [:i | events add: (WindowEvent bytes: (k copyFrom: i to: (i + 7 min: k size)))] ]'. #ok
WindowEvent class compile: 'bytes: s [ ^self new setKind: 1 value: ((1 to: s size) inject: 0 into: [:v :i | v + ((s at: i) value bitShift: 8 * (i - 1))]) width: s size height: 0 ]'. #ok
FakeWindow compile: 'columns [ ^80 ]'. FakeWindow compile: 'rows [ ^24 ]'. FakeWindow compile: 'clear: c [ ^self ]'. FakeWindow compile: 'drawn [ ^drawn ]'. #ok
FakeWindow compile: 'text: s column: c row: r color: f background: b [ drawn add: (Array with: s with: c with: r with: f) ]'. #ok
FakeWindow compile: 'nextEvent [ events isEmpty ifTrue: [^WindowEvent new setKind: 3 value: 0 width: 0 height: 0]. ^events removeFirst ]'. #ok
FakeWindow compile: 'pollEvent [ ^nil ]'. FakeWindow compile: 'nextEventWait: t [ ^events isEmpty ifTrue: [nil] ifFalse: [events removeFirst] ]'. #ok
Smalltalk at: #E put: (String with: (Character value: 27)). Smalltalk at: #CQ put: (String with: (Character value: 17)). #ok
Smalltalk at: #Keys put: E , '[B' , E , '[C' , E , '[C' , E , '[3~' , E , '[F' , 'x' , E , '[H' , E , '[1;5D' , 'y' , E , '[A' , CQ. Keys size
Smalltalk at: #Run put: [:evs | | w ws | w := FakeWindow new. w events: evs. ws := Workspace new. ws openIn: w. ws textPane text]. #ok
(Run value: (Array with: Keys)) lines
| one | one := Run value: (Array with: Keys). (1 to: Keys size - 1) select: [:k | (Run value: (Array with: (Keys copyFrom: 1 to: k) with: (Keys copyFrom: k + 1 to: Keys size))) ~= one]
| one | one := Run value: (Array with: Keys). (1 to: Keys size - 1) inject: 0 into: [:n :k | n + ((Run value: ((1 to: Keys size) collect: [:i | String with: (Keys at: i)])) = one ifTrue: [0] ifFalse: [1])]
Run value: (Array with: (String with: (Character value: 27)) with: (String with: (Character value: 17)))
(Run value: (Array with: (String with: (Character value: 27) with: (Character value: 27)) , '[A' with: (String with: (Character value: 17)))) lines size
| r | r := OrderedCollection new. StHighlight runsOf: '^x := #(1 2) at: 2' open: nil into: r. r collect: [:e | (e at: 1) -> (e at: 2)]
| r | r := OrderedCollection new. StHighlight runsOf: '| a b | a := self foo: $c. "note' open: nil into: r
| r | r := OrderedCollection new. (StHighlight runsOf: 'still a comment" Object new' open: $" into: r) -> (r collect: [:e | (e at: 1) -> (e at: 2)])
| r | r := OrderedCollection new. StHighlight runsOf: '[:each | each printString] value: 16rFF + 3.5e2' open: nil into: r. r collect: [:e | (e at: 1) -> (e at: 2)]
| r | r := OrderedCollection new. StHighlight runsOf: 'Point >> x: ax [ ^''it''''s'' , #+ ]' open: nil into: r. r collect: [:e | (e at: 1) -> (e at: 2)]
((Run value: (Array with: (String with: (Character value: 27)) , '[F -> 4' , (String with: (Character value: 16)))) lines first: 2) asArray
((Run value: (Array with: (String with: (Character value: 16) with: (Character value: 16)))) lines first: 3) asArray
((Run value: (Array with: 'x' with: (WindowEvent new setKind: 2 value: 0 width: 640 height: 384) with: 'y')) lines first: 1) asArray
((Run value: (Array with: E , '[F + 10 facto' , (String with: Character tab))) lines first: 1) asArray
((Run value: (Array with: E , '[B' , E , '[B' , E , '[B' , E , '[F. Transcr' , (String with: Character tab))) lines last: 1) asArray
((Run value: (Array with: E , '[F. 3 printS' , (String with: Character tab) , E , '[B' , E , '[F x prin' , (String with: Character tab))) lines first: 2) asArray
| w ws | w := FakeWindow new. w events: (Array with: E , '[B' , E , '[C' , E , '[C' , E , '[C' , E , '[C' , E , '[C'). ws := Workspace new. ws openIn: w. ws textPane wordAtCursor
