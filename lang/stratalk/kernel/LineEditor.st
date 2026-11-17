"LineEditor.st: the REPL's line on the console: what is typed is shown as
 it is typed; backspace; the up and down arrows go through the lines typed
 before; Tab completes a name (a global after a capital letter, a selector
 otherwise), or lists the names that would fit."

Object subclass: #LineEditor slots: 'line history index prompt pending console'.
"The REPL's line editor: readLine: reads one line key by key, with the
 console in raw mode, echoing what is typed, with backspace, Ctrl-U (the
 whole line), the up and down arrows through the history and Tab to
 complete a name. The REPL (Smalltalk's loop in System.st) uses one when
 it is interactive. line is the line being typed; history the lines typed
 before (an OrderedCollection, without repeats in a row); index where the
 arrows are in it; prompt what was shown before the line; pending the keys
 read but not yet handled (a ReadStream); console whether standard input
 is the console, which must then be put in raw mode."

LineEditor class >> new [
    "Answers a line editor with an empty history."
    ^self basicNew setUp ]
LineEditor >> setUp [
    "Starts with an empty history and no pending keys, and notes whether
     standard input is the console."
    history := OrderedCollection new. pending := ReadStream on: ''.
    console := Smalltalk stdinIsConsole ]
LineEditor >> line: aString [
    "Makes aString the line typed so far: completions are for its end (the
     Workspace asks with the text before its cursor).
     (LineEditor new line: '3 fact'; candidatesFor: 'fact') asArray >>> #('factorial')"
    line := aString ]
LineEditor >> completionsOf: aString [
    "Answers {the word at the end of aString. its completions, sorted}: what
     Tab offers after aString.
     (LineEditor new completionsOf: 'Transcr') last asArray >>> #('Transcript')"
    | w |
    line := aString.
    w := self wordBefore.
    ^Array with: w with: (self candidatesFor: w) ]
LineEditor >> raw: aBoolean [
    "Puts the console in raw mode (true) or back in cooked mode (false), with
     tty's CONMODE; nothing if standard input is not the console. The console
     is raw while a line is typed; a pipe (term's) brings keys as they are."
    console ifTrue: [Smalltalk consoleMode: (aBoolean ifTrue: [1] ifFalse: [0])] ]
LineEditor >> out: aString [
    "Shows aString on the Transcript at once (flushed)."
    Transcript show: aString; flush ]
LineEditor >> nextKey [
    "Answers the next key typed (a Character), or nil at the end of input;
     reads more from standard input when the pending keys are used up."
    | keys |
    [pending atEnd] whileTrue: [
        keys := Smalltalk readKeys.
        keys == nil ifTrue: [^nil].
        pending := ReadStream on: keys].
    ^pending next ]
LineEditor >> readLine: aPrompt [
    "Shows aPrompt and answers the line typed after it, without its end, or
     nil at the end of input (Ctrl-D on an empty line). Handles backspace,
     Ctrl-U, Tab and the arrows on the way; a line that is not empty and not
     the same as the last one goes into the history."
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
    "Removes the line's last character, and from the screen (backspace,
     space, backspace); nothing if the line is empty."
    line isEmpty ifTrue: [^self].
    line := line copyFrom: 1 to: line size - 1.
    self out: (String with: Character backspace with: Character space with: Character backspace) ]
LineEditor >> replaceLine: aString [
    "Rubs the whole line out and puts aString in its place, shown."
    [line isEmpty] whileFalse: [self rubout].
    line := aString.
    self out: line ]
LineEditor >> escape [
    "Handles what follows an escape key: ESC [ A, the up arrow, shows the
     line typed before the one shown; ESC [ B, the down arrow, the one after
     (an empty line past the last). Other sequences are dropped whole,
     their numbers and their last character too (ESC [ 3 ~, ESC [ 1 ; 5 C).
     Keys are read as they come, so a sequence cut between two reads is
     whole here."
    | c |
    (c := self nextKey) = $[ ifFalse: [^self].
    [(c := self nextKey) notNil and: [c isDigit or: [c = $;]]] whileTrue.
    c = $A ifTrue: [
        index > 1 ifTrue: [index := index - 1. self replaceLine: (history at: index)]].
    c = $B ifTrue: [
        index < history size
            ifTrue: [index := index + 1. self replaceLine: (history at: index)]
            ifFalse: [index := history size + 1. self replaceLine: '']] ]
LineEditor >> wordBefore [
    "Answers the name being typed at the end of the line: the letters,
     digits, _ and : before the cursor."
    | i |
    i := line size.
    [i > 0 and: [(line at: i) isAlphaNumeric or: [(line at: i) = $_ or: [(line at: i) = $:]]]] whileTrue: [i := i - 1].
    ^line copyFrom: i + 1 to: line size ]
LineEditor >> receiverBefore: aWord [
    "Answers an object of the class the selector aWord being typed is sent
     to, when the line shows it plainly (nothing is run): '' after a string,
     #sym after a symbol, the integer after a number, $a after a
     character, the global after a
     global's name, #nil (for nil) or true after those words. nil if unknown."
    | head i tok |
    head := (line copyFrom: 1 to: line size - aWord size) trimSeparators.
    head isEmpty ifTrue: [^nil].
    (head last = $') ifTrue: [^'' ].
    (head size >= 2 and: [(head at: head size - 1) = $$]) ifTrue: [^$a].
    i := head size.
    [i > 0 and: [(head at: i) isAlphaNumeric or: [(head at: i) = $_ or: [(head at: i) = $#]]]] whileTrue: [i := i - 1].
    (i > 0 and: [(head at: i) = $-]) ifTrue: [i := i - 1].
    tok := head copyFrom: i + 1 to: head size.
    tok isEmpty ifTrue: [^nil].
    tok first = $# ifTrue: [^#sym].
    (tok first isDigit or: [tok first = $-]) ifTrue: [^tok asInteger].
    tok first isUppercase ifTrue: [^Smalltalk at: tok asSymbol ifAbsent: [nil]].
    tok = 'nil' ifTrue: [^#nil].
    (tok = 'true' or: [tok = 'false']) ifTrue: [^true].
    ^nil ]
LineEditor >> add: aSelector to: aSet after: aWord [
    "Adds to aSet the completion of aWord that aSelector gives, if aSelector
     begins with aWord: for a keyword selector only up to its next keyword.
     | s | s := Set new. LineEditor new add: #at:put: to: s after: 'at'. s asArray >>> #('at:')"
    | k |
    (aSelector size >= aWord size and: [aSelector beginsWith: aWord]) ifFalse: [^self].
    k := aSelector indexOf: $: startingAt: aWord size + 1.
    aSet add: (k = 0 ifTrue: [aSelector asString] ifFalse: [aSelector copyFrom: 1 to: k]) ]
LineEditor >> candidatesFor: aWord [
    "Answers the sorted names that complete aWord at the end of the line:
     globals for a capitalized word (or an empty one where a name starts),
     otherwise the selectors of the receiver's class and its superclasses
     when receiverBefore: knows it, or every lowercase selector there is."
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
    "Tab: extends the word at the end of the line by what all its candidates
     share; if that adds nothing, lists the candidates in columns under the
     line and shows the prompt and line again."
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
    "Answers the longest common beginning of the strings a and b.
     LineEditor new common: 'abcd' with: 'abxy' >>> 'ab'"
    | n |
    n := 0.
    [n < a size and: [n < b size and: [(a at: n + 1) = (b at: n + 1)]]] whileTrue: [n := n + 1].
    ^a copyFrom: 1 to: n ]

SystemDictionary >> consoleMode: n [
    "Sets the console's mode: 0 cooked (tty edits and echoes the line), 1 raw
     (keys as they are typed, no echo). A VM primitive (113): tty's CONMODE."
    <primitive: 113> ]
SystemDictionary >> readKeys [
    "Answers what standard input has now: keys, in raw mode; an empty String
     if the read was interrupted, nil at the end of input. A VM primitive
     (114): a READ on handle 0."
    <primitive: 114> ]
SystemDictionary >> stdinIsConsole [
    "Answers whether standard input (handle 0) is the console, tty's
     endpoint, rather than a pipe or a file. A VM primitive (115)."
    <primitive: 115> ]
