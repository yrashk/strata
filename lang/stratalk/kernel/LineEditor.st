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
        v >= 32 ifTrue: [line := line, (String with: c). self out: (String with: c)]].
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
LineEditor >> candidatesFor: aWord [
    | out |
    out := Set new.
    aWord first isUppercase
        ifTrue: [Smalltalk keysDo: [:k | (k beginsWith: aWord) ifTrue: [out add: k asString]]]
        ifFalse: [
            Smalltalk symbolTable do: [:s |
                (s notNil and: [s size > 0 and: [(s at: 1) isLowercase and: [s beginsWith: aWord]]]) ifTrue: [
                    "a keyword selector: its next keyword"
                    | k | k := s indexOf: $: startingAt: aWord size + 1.
                    out add: (k = 0 ifTrue: [s asString] ifFalse: [s copyFrom: 1 to: k])]]].
    ^out asSortedCollection: [:a :b | a <= b] ]
LineEditor >> complete [
    | word cands prefix |
    word := self wordBefore.
    word isEmpty ifTrue: [^self].
    cands := self candidatesFor: word.
    cands isEmpty ifTrue: [^self].
    prefix := cands first.
    cands do: [:c | prefix := self common: prefix with: c].
    prefix size > word size ifTrue: [
        | more | more := prefix copyFrom: word size + 1 to: prefix size.
        line := line, more.
        self out: more.
        ^self].
    cands size = 1 ifTrue: [^self].
    self out: (String with: Character cr).
    (cands first: (cands size min: 60)) do: [:c | self out: c] separatedBy: [self out: '  '].
    cands size > 60 ifTrue: [self out: '  ...'].
    self out: (String with: Character cr), prompt, line ]
LineEditor >> common: a with: b [
    | n |
    n := 0.
    [n < a size and: [n < b size and: [(a at: n + 1) = (b at: n + 1)]]] whileTrue: [n := n + 1].
    ^a copyFrom: 1 to: n ]

SystemDictionary >> consoleMode: n [ <primitive: 113> ]
SystemDictionary >> readKeys [ "What standard input has: keys, in raw mode; nil at its end" <primitive: 114> ]
SystemDictionary >> stdinIsConsole [ <primitive: 115> ]
