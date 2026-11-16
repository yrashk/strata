"LineEditor.st: the REPL's line on the console: what is typed is shown as
 it is typed; backspace; the up and down arrows go through the lines typed
 before; Tab completes a name (a global after a capital letter, a selector
 otherwise), or lists the names that would fit."

Object subclass: #LineEditor slots: 'line history index prompt pending console'.

LineEditor class >> new [ ^self basicNew setUp ]
LineEditor >> setUp [
    history := OrderedCollection new. pending := ReadStream on: ''.
    console := Smalltalk stdinIsConsole ]
LineEditor >> raw: aBoolean [
    "The console is raw while a line is typed; a pipe (term's) brings keys as they are."
    console ifTrue: [Smalltalk consoleMode: (aBoolean ifTrue: [1] ifFalse: [0])] ]
LineEditor >> out: aString [ Transcript show: aString; flush ]
LineEditor >> nextKey [
    "The next key, or nil at the end of input."
    | keys |
    [pending atEnd] whileTrue: [
        keys := Smalltalk readKeys.
        keys == nil ifTrue: [^nil].
        pending := ReadStream on: keys].
    ^pending next ]
LineEditor >> readLine: aPrompt [
    "A line, or nil at the end of input (Ctrl-D on an empty line)."
    | c v |
    prompt := aPrompt. line := ''. index := history size + 1.
    self raw: true.
    self out: prompt.
    [c := self nextKey.
     c == nil ifTrue: [self raw: false. ^nil].
     v := c value.
     v = 13 or: [v = 10]] whileFalse: [
        (v = 4 and: [line isEmpty]) ifTrue: [self out: (String with: Character cr). self raw: false. ^nil].
        (v = 8 or: [v = 127]) ifTrue: [self rubout].
        v = 9 ifTrue: [self complete].
        v = 21 ifTrue: [self replaceLine: ''].
        v = 27 ifTrue: [self escape].
        (v >= 32 and: [v ~= 127]) ifTrue: [line := line, (String with: c). self out: (String with: c)]].
    self out: (String with: Character cr).
    self raw: false.
    (line notEmpty and: [history isEmpty or: [history last ~= line]]) ifTrue: [history add: line].
    ^line ]
LineEditor >> rubout [
    line isEmpty ifTrue: [^self].
    line := line copyFrom: 1 to: line size - 1.
    self out: (String with: Character backspace with: Character space with: Character backspace) ]
LineEditor >> replaceLine: aString [
    [line isEmpty] whileFalse: [self rubout].
    line := aString.
    self out: line ]
LineEditor >> escape [
    "ESC [ A and ESC [ B: the arrows up and down."
    | c |
    (c := self nextKey) = $[ ifFalse: [^self].
    c := self nextKey.
    c = $A ifTrue: [
        index > 1 ifTrue: [index := index - 1. self replaceLine: (history at: index)]].
    c = $B ifTrue: [
        index < history size
            ifTrue: [index := index + 1. self replaceLine: (history at: index)]
            ifFalse: [index := history size + 1. self replaceLine: '']] ]
LineEditor >> wordBefore [
    | i |
    i := line size.
    [i > 0 and: [(line at: i) isAlphaNumeric or: [(line at: i) = $_ or: [(line at: i) = $:]]]] whileTrue: [i := i - 1].
    ^line copyFrom: i + 1 to: line size ]
LineEditor >> receiverBefore: aWord [
    "What the selector being typed is sent to, when the line shows it plainly:
     a literal, a global's name, the result of nothing else (nothing is run).
     nil if unknown."
    | head i tok |
    head := (line copyFrom: 1 to: line size - aWord size) trimSeparators.
    head isEmpty ifTrue: [^nil].
    (head last = $') ifTrue: [^'' ].
    i := head size.
    [i > 0 and: [(head at: i) isAlphaNumeric or: [(head at: i) = $_ or: [(head at: i) = $#]]]] whileTrue: [i := i - 1].
    (i > 0 and: [(head at: i) = $-]) ifTrue: [i := i - 1].
    tok := head copyFrom: i + 1 to: head size.
    tok isEmpty ifTrue: [^nil].
    tok first = $# ifTrue: [^#sym].
    (tok first isDigit or: [tok first = $-]) ifTrue: [^tok asInteger].
    (tok first = $$) ifTrue: [^$a].
    tok first isUppercase ifTrue: [^Smalltalk at: tok asSymbol ifAbsent: [nil]].
    tok = 'nil' ifTrue: [^#nil].
    (tok = 'true' or: [tok = 'false']) ifTrue: [^true].
    ^nil ]
LineEditor >> add: aSelector to: aSet after: aWord [
    "A keyword selector: only its next keyword."
    | k |
    (aSelector size >= aWord size and: [aSelector beginsWith: aWord]) ifFalse: [^self].
    k := aSelector indexOf: $: startingAt: aWord size + 1.
    aSet add: (k = 0 ifTrue: [aSelector asString] ifFalse: [aSelector copyFrom: 1 to: k]) ]
LineEditor >> candidatesFor: aWord [
    | out rcvr cls head |
    out := Set new.
    head := (line copyFrom: 1 to: line size - aWord size) trimSeparators.
    "a name: at the start, or after a statement or an operator"
    (aWord notEmpty and: [aWord first isUppercase]) | (aWord isEmpty and: [head isEmpty or: ['.(:[^=' includes: head last]]) ifTrue: [
        Smalltalk keysDo: [:k | (k beginsWith: aWord) ifTrue: [out add: k asString]].
        ^out asSortedCollection: [:a :b | a <= b]].
    "a selector: the receiver's, if it can be told"
    rcvr := self receiverBefore: aWord.
    rcvr == #nil ifTrue: [rcvr := nil. cls := UndefinedObject] ifFalse: [cls := rcvr == nil ifTrue: [nil] ifFalse: [rcvr class]].
    cls == nil
        ifTrue: [
            aWord isEmpty ifTrue: [cls := Object] ifFalse: [
                Smalltalk symbolTable do: [:s |
                    (s notNil and: [s size > 0 and: [(s at: 1) isLowercase]]) ifTrue: [self add: s to: out after: aWord]].
                ^out asSortedCollection: [:a :b | a <= b]]].
    [cls == nil] whileFalse: [
        cls methodDict keysDo: [:s | self add: s to: out after: aWord].
        cls := cls superclass].
    ^out asSortedCollection: [:a :b | a <= b] ]
LineEditor >> complete [
    | word cands prefix width col |
    word := self wordBefore.
    cands := self candidatesFor: word.
    cands isEmpty ifTrue: [^self].
    prefix := cands first.
    cands do: [:c | prefix := self common: prefix with: c].
    prefix size > word size ifTrue: [
        | more | more := prefix copyFrom: word size + 1 to: prefix size.
        line := line, more.
        self out: more.
        ^self].
    (cands size = 1 and: [word notEmpty]) ifTrue: [^self].
    "all of them, in columns"
    width := (cands inject: 0 into: [:m :c | m max: c size]) + 2.
    col := 0.
    self out: (String with: Character cr).
    cands do: [:c |
        col + width > 78 ifTrue: [self out: (String with: Character cr). col := 0].
        self out: c; out: (String new: width - c size withAll: $ ).
        col := col + width].
    self out: (String with: Character cr), prompt, line ]
LineEditor >> common: a with: b [
    | n |
    n := 0.
    [n < a size and: [n < b size and: [(a at: n + 1) = (b at: n + 1)]]] whileTrue: [n := n + 1].
    ^a copyFrom: 1 to: n ]

SystemDictionary >> consoleMode: n [ <primitive: 113> ]
SystemDictionary >> readKeys [ "What standard input has: keys, in raw mode; nil at its end" <primitive: 114> ]
SystemDictionary >> stdinIsConsole [ <primitive: 115> ]
