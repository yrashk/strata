Object subclass: #FakeWindow slots: 'events drawn'. #ok
FakeWindow compile: 'events: c [ events := OrderedCollection new. drawn := OrderedCollection new. c do: [:k | self add: k] ]'. #ok
FakeWindow compile: 'add: k [ k isString ifFalse: [^events add: k]. 1 to: k size by: 8 do: [:i | events add: (WindowEvent bytes: (k copyFrom: i to: (i + 7 min: k size)))] ]'. #ok
WindowEvent class compile: 'bytes: s [ ^self new setKind: 1 value: ((1 to: s size) inject: 0 into: [:v :i | v + ((s at: i) value bitShift: 8 * (i - 1))]) width: s size height: 0 ]'. #ok
FakeWindow compile: 'columns [ ^80 ]'. FakeWindow compile: 'rows [ ^24 ]'. FakeWindow compile: 'clear: c [ ^self ]'. FakeWindow compile: 'drawn [ ^drawn ]'. #ok
FakeWindow compile: 'text: s column: c row: r color: f background: b [ drawn add: (Array with: s with: c with: r with: f) ]'. #ok
FakeWindow compile: 'nextEvent [ events isEmpty ifTrue: [^WindowEvent new setKind: 3 value: 0 width: 0 height: 0]. ^events removeFirst ]'. #ok
FakeWindow compile: 'pollEvent [ ^nil ]'. FakeWindow compile: 'nextEventWait: t [ ^events isEmpty ifTrue: [nil] ifFalse: [events removeFirst] ]'. #ok
Smalltalk at: #E put: (String with: (Character value: 27)). Smalltalk at: #CQ put: (String with: (Character value: 17)). #ok
Smalltalk at: #Br put: [:name | | w b | w := FakeWindow new. w events: #(). b := ClassBrowser new on: name; openIn: w. Array with: b classList selected with: b selectorList selected with: b classList items size]. #ok
Br value: 'Interval'
Br value: 'Interval>>last'
| r | r := Br value: 'isArray'. Array with: (r at: 3) with: (r at: 2)
| r | r := Br value: 'inject:'. r at: 2
(Br value: 'Nonsense') at: 3
