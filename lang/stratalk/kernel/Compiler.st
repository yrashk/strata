"Compiler.st: the compiler in the image. It follows lang/stratalk/host/stc.py
 step by step and gives the same bytes (stratalk.py check compares them):
 a scanner, a parser to a tree, pass 1 (what blocks capture), pass 2 (code)."

Object subclass: #StToken slots: 'kind value start stop line'.
Object subclass: #StScanner slots: 'source pos line tokens'.
Object subclass: #StParser slots: 'tokens index source'.
Object subclass: #StNode slots: 'line'.
StNode subclass: #StLiteral slots: 'value'.
StNode subclass: #StVariable slots: 'name'.
StNode subclass: #StAssign slots: 'name value'.
StNode subclass: #StSend slots: 'receiver selector arguments'.
StNode subclass: #StCascade slots: 'receiver messages'.
StNode subclass: #StBlock slots: 'arguments temps statements'.
StNode subclass: #StBrace slots: 'elements'.
StNode subclass: #StReturn slots: 'expr'.
StNode subclass: #StMethod slots: 'selector arguments temps primitive statements'.
Object subclass: #StVar slots: 'name kind scope captured assigned remote vidx origin'.
Object subclass: #StScope slots: 'parent isBlock args locals remotes copied vector lits code'.
Object subclass: #StLex slots: 'parent real names'.
Object subclass: #StLabel slots: 'pos'.
Object subclass: #Compiler slots: 'ivars methodClass analysis scopes'.

"---- tokens and the scanner ----------------------------------------------------"

StToken class >> kind: k value: v start: s stop: e line: l [ ^self new setKind: k value: v start: s stop: e line: l ]
StToken >> setKind: k value: v start: s stop: e line: l [ kind := k. value := v. start := s. stop := e. line := l ]
StToken >> kind [ ^kind ]
StToken >> value [ ^value ]
StToken >> start [ ^start ]
StToken >> stop [ ^stop ]
StToken >> line [ ^line ]
StToken >> is: k [ ^kind == k ]
StToken >> isBin: op [ ^kind == #bin and: [value = op] ]

StScanner class >> scan: aString [ ^self new setSource: aString; scan ]
StScanner >> setSource: aString [ source := aString. pos := 1. line := 1. tokens := OrderedCollection new ]
StScanner >> error: aString [ ^(CompileError new) line: line; signal: 'line ', line printString, ': ', aString ]
StScanner >> peekAt: i [ i > source size ifTrue: [^nil]. ^source at: i ]
StScanner >> isLetter: c [ ^c notNil and: [c isLetter or: [c = $_]] ]
StScanner >> isDigit: c [ ^c notNil and: [c isDigit] ]
StScanner >> isBinChar: c [ ^c notNil and: ['+-*/\<>=~@%|&?,' includes: c] ]
StScanner >> add: k value: v from: s to: e [ tokens add: (StToken kind: k value: v start: s stop: e line: line) ]
StScanner >> lastKind [ tokens isEmpty ifTrue: [^nil]. ^tokens last kind ]
StScanner >> operandEnded [ ^#(#ident #int #char #str #sym #')' #']' #'}') includes: self lastKind ]
StScanner >> skipBlanks [
    | c j |
    [pos <= source size] whileTrue: [
        c := source at: pos.
        c value = 10
            ifTrue: [line := line + 1. pos := pos + 1]
            ifFalse: [
                (c value = 32 or: [c value = 9 or: [c value = 13 or: [c value = 12]]])
                    ifTrue: [pos := pos + 1]
                    ifFalse: [
                        c = $" ifFalse: [^self].
                        j := source indexOf: $" startingAt: pos + 1.
                        j = 0 ifTrue: [^self error: 'comment without end'].
                        pos + 1 to: j - 1 do: [:k | (source at: k) value = 10 ifTrue: [line := line + 1]].
                        pos := j + 1]]] ]
StScanner >> scan [
    | c s |
    [self skipBlanks.
     pos > source size] whileFalse: [
        c := source at: pos.
        s := pos.
        (self isLetter: c)
            ifTrue: [self scanWord]
            ifFalse: [
                ((self isDigit: c) or: [c = $- and: [(self isDigit: (self peekAt: pos + 1)) and: [self operandEnded not]]])
                    ifTrue: [self scanNumber]
                    ifFalse: [self scanOther: c]]].
    self add: #eof value: nil from: pos to: pos.
    ^tokens ]
StScanner >> scanWord [
    | s j |
    s := pos. j := pos.
    [j <= source size and: [(self isLetter: (source at: j)) or: [(source at: j) isDigit]]] whileTrue: [j := j + 1].
    ((self peekAt: j) = $: and: [(self peekAt: j + 1) ~= $=])
        ifTrue: [self add: #kw value: (source copyFrom: s to: j) from: s to: j + 1. pos := j + 1]
        ifFalse: [self add: #ident value: (source copyFrom: s to: j - 1) from: s to: j. pos := j] ]
StScanner >> scanNumber [
    | s neg i j v base k |
    s := pos.
    neg := (source at: pos) = $-.
    i := neg ifTrue: [pos + 1] ifFalse: [pos].
    j := i.
    [j <= source size and: [(source at: j) isDigit]] whileTrue: [j := j + 1].
    v := (source copyFrom: i to: j - 1) asInteger.
    (self peekAt: j) = $r
        ifTrue: [
            base := v. k := j + 1.
            [k <= source size and: [(source at: k) isDigit or: [(source at: k) isUppercase]]] whileTrue: [k := k + 1].
            k = (j + 1) ifTrue: [^self error: 'digits expected after the radix'].
            v := 0.
            j + 1 to: k - 1 do: [:m | v := v * base + (source at: m) digitValue].
            j := k]
        ifFalse: [
            ((self peekAt: j) = $. and: [self isDigit: (self peekAt: j + 1)])
                ifTrue: [^self error: 'floating point numbers are not supported']].
    neg ifTrue: [v := 0 - v].
    self add: #int value: v from: s to: j.
    pos := j ]
StScanner >> scanString: from [
    "The string whose opening quote is at from; answers {text. index after it}."
    | j out |
    j := from + 1.
    out := WriteStream on: (String new: 16).
    [j > source size ifTrue: [^self error: 'string without end'].
     (source at: j) = $' and: [(self peekAt: j + 1) ~= $']] whileFalse: [
        (source at: j) = $'
            ifTrue: [out nextPut: $'. j := j + 2]
            ifFalse: [(source at: j) value = 10 ifTrue: [line := line + 1]. out nextPut: (source at: j). j := j + 1]].
    ^Array with: out contents with: j + 1 ]
StScanner >> scanOther: c [
    | s j r n |
    s := pos.
    c = $$ ifTrue: [
        pos + 1 > source size ifTrue: [^self error: 'character expected after $'].
        self add: #char value: (source at: pos + 1) value from: s to: pos + 2.
        pos := pos + 2. ^self].
    c = $' ifTrue: [
        r := self scanString: pos.
        self add: #str value: (r at: 1) from: s to: (r at: 2).
        pos := r at: 2. ^self].
    c = $# ifTrue: [^self scanHash].
    (c = $: and: [(self peekAt: pos + 1) = $=]) ifTrue: [
        self add: #':=' value: nil from: s to: pos + 2. pos := pos + 2. ^self].
    ('()[]{}.;^:' includes: c) ifTrue: [
        self add: (String with: c) asSymbol value: nil from: s to: pos + 1. pos := pos + 1. ^self].
    (self isBinChar: c) ifTrue: [
        j := pos.
        [n := self peekAt: j.
         (self isBinChar: n) and: [(j > pos and: [n = $- and: [self isDigit: (self peekAt: j + 1)]]) not]]
            whileTrue: [j := j + 1].
        self add: #bin value: (source copyFrom: pos to: j - 1) from: s to: j.
        pos := j. ^self].
    ^self error: 'unexpected character ', c printString ]
StScanner >> scanHash [
    | s n j r |
    s := pos.
    n := self peekAt: pos + 1.
    n = $( ifTrue: [self add: #'#(' value: nil from: s to: pos + 2. pos := pos + 2. ^self].
    n = $[ ifTrue: [self add: #'#[' value: nil from: s to: pos + 2. pos := pos + 2. ^self].
    n = $' ifTrue: [
        r := self scanString: pos + 1.
        self add: #sym value: (r at: 1) from: s to: (r at: 2).
        pos := r at: 2. ^self].
    (self isLetter: n) ifTrue: [
        j := pos + 1.
        [j <= source size and: [(self isLetter: (source at: j)) or: [(source at: j) isDigit or: [(source at: j) = $:]]]]
            whileTrue: [j := j + 1].
        self add: #sym value: (source copyFrom: pos + 1 to: j - 1) from: s to: j.
        pos := j. ^self].
    (self isBinChar: n) ifTrue: [
        j := pos + 1.
        [j <= source size and: [self isBinChar: (source at: j)]] whileTrue: [j := j + 1].
        self add: #sym value: (source copyFrom: pos + 1 to: j - 1) from: s to: j.
        pos := j. ^self].
    ^self error: 'bad literal after #' ]

"---- the syntax tree ------------------------------------------------------------"

StNode >> line [ ^line ]
StNode >> line: n [ line := n ]
StNode >> isReturn [ ^false ]
StNode >> isBlock [ ^false ]
StNode >> isSend [ ^false ]
StNode >> isVariable [ ^false ]
StNode >> isLiteral [ ^false ]
StNode >> isAssign [ ^false ]
StLiteral class >> value: v [ ^self new setValue: v ]
StLiteral >> setValue: v [ value := v ]
StLiteral >> value [ ^value ]
StLiteral >> isLiteral [ ^true ]
StVariable class >> name: n line: l [ ^self new setName: n; line: l; yourself ]
StVariable >> setName: n [ name := n ]
StVariable >> name [ ^name ]
StVariable >> isVariable [ ^true ]
StVariable >> isSuper [ ^name = 'super' ]
StAssign class >> name: n value: v line: l [ ^self new setName: n value: v; line: l; yourself ]
StAssign >> setName: n value: v [ name := n. value := v ]
StAssign >> name [ ^name ]
StAssign >> value [ ^value ]
StAssign >> isAssign [ ^true ]
StSend class >> receiver: r selector: s arguments: a line: l [ ^self new setReceiver: r selector: s arguments: a; line: l; yourself ]
StSend >> setReceiver: r selector: s arguments: a [ receiver := r. selector := s. arguments := a ]
StSend >> receiver [ ^receiver ]
StSend >> selector [ ^selector ]
StSend >> arguments [ ^arguments ]
StSend >> isSend [ ^true ]
StSend >> isSuperSend [ ^receiver isVariable and: [receiver isSuper] ]
StCascade class >> receiver: r messages: m [ ^self new setReceiver: r messages: m ]
StCascade >> setReceiver: r messages: m [ receiver := r. messages := m ]
StCascade >> receiver [ ^receiver ]
StCascade >> messages [ ^messages ]
StBlock class >> arguments: a temps: t statements: s [ ^self new setArguments: a temps: t statements: s ]
StBlock >> setArguments: a temps: t statements: s [ arguments := a. temps := t. statements := s ]
StBlock >> arguments [ ^arguments ]
StBlock >> temps [ ^temps ]
StBlock >> statements [ ^statements ]
StBlock >> isBlock [ ^true ]
StBlock >> isBlock: n [ ^arguments size = n ]
StBrace class >> elements: e [ ^self new setElements: e ]
StBrace >> setElements: e [ elements := e ]
StBrace >> elements [ ^elements ]
StReturn class >> expr: e [ ^self new setExpr: e ]
StReturn >> setExpr: e [ expr := e ]
StReturn >> expr [ ^expr ]
StReturn >> isReturn [ ^true ]
StMethod class >> selector: s arguments: a temps: t primitive: p statements: st line: l [
    ^self new setSelector: s arguments: a temps: t primitive: p statements: st; line: l; yourself ]
StMethod >> setSelector: s arguments: a temps: t primitive: p statements: st [
    selector := s. arguments := a. temps := t. primitive := p. statements := st ]
StMethod >> selector [ ^selector ]
StMethod >> arguments [ ^arguments ]
StMethod >> temps [ ^temps ]
StMethod >> primitive [ ^primitive ]
StMethod >> statements [ ^statements ]

"---- the parser -------------------------------------------------------------------"

StParser class >> on: aString [ ^self new setTokens: (StScanner scan: aString) source: aString ]
StParser >> setTokens: t source: aString [ tokens := t. index := 1. source := aString ]
StParser >> setTokens: t [ tokens := t. index := 1 ]
StParser >> peek [ ^tokens at: (index min: tokens size) ]
StParser >> peek: k [ ^tokens at: (index + k min: tokens size) ]
StParser >> next [ | t | t := tokens at: index. index := index + 1. ^t ]
StParser >> error: aString [ ^(CompileError new) line: self peek line; signal: 'line ', self peek line printString, ': ', aString ]
StParser >> expect: k [ (self peek is: k) ifFalse: [^self error: k, ' expected']. ^self next ]
StParser >> atBin: op [ ^self peek isBin: op ]
StParser >> items [
    "The items of a file: {#method. class name. meta. StMethod. source} or {#expr. node. line} or {#vars. names}"
    | out cls meta t line e |
    out := OrderedCollection new.
    [self peek is: #eof] whileFalse: [
        ((self atBin: '|') or: [self atBin: '||'])
            ifTrue: [out add: (Array with: #vars with: self temps)]
            ifFalse: [
                self isMethodDef
                    ifTrue: [
                        | from |
                        cls := self next value. meta := false.
                        ((self peek is: #ident) and: [self peek value = 'class']) ifTrue: [self next. meta := true].
                        self next.
                        from := self peek start.
                        t := self methodDef.
                        out add: (Array with: #method with: cls with: meta with: t
                            with: (source copyFrom: from to: (tokens at: index - 1) stop - 1))]
                    ifFalse: [
                        line := self peek line.
                        e := self expression.
                        (self peek is: #'.')
                            ifTrue: [self next]
                            ifFalse: [(self peek is: #eof) ifFalse: [^self error: '. expected']].
                        out add: (Array with: #expr with: e with: line)]]].
    ^out ]
StParser >> isMethodDef [
    | k |
    (self peek is: #ident) ifFalse: [^false].
    k := 1.
    (((self peek: 1) is: #ident) and: [(self peek: 1) value = 'class']) ifTrue: [k := 2].
    ^(self peek: k) isBin: '>>' ]
StParser >> methodDef [
    | line sp temps prim stmts |
    line := self peek line.
    sp := self pattern.
    self expect: #'['.
    temps := #(). prim := 0.
    2 timesRepeat: [
        ((self atBin: '|') or: [self atBin: '||'])
            ifTrue: [temps := self temps]
            ifFalse: [(self atBin: '<') ifTrue: [prim := self pragma]]].
    stmts := self statements: #']'.
    self expect: #']'.
    ^StMethod selector: (sp at: 1) arguments: (sp at: 2) temps: temps primitive: prim statements: stmts line: line ]
StParser >> methodSource [
    | line sp temps prim stmts |
    line := self peek line.
    sp := self pattern.
    temps := #(). prim := 0.
    2 timesRepeat: [
        ((self atBin: '|') or: [self atBin: '||'])
            ifTrue: [temps := self temps]
            ifFalse: [(self atBin: '<') ifTrue: [prim := self pragma]]].
    stmts := self statements: #eof.
    ^StMethod selector: (sp at: 1) arguments: (sp at: 2) temps: temps primitive: prim statements: stmts line: line ]
StParser >> methodEither [
    "A pattern and a body, the body in brackets (as in a file) or not."
    | start node |
    start := index.
    self pattern.
    (self peek is: #'[') ifTrue: [
        "the brackets around the whole body, or a body that begins with a block?"
        index := start.
        node := [self methodDef] on: CompileError do: [:e | e return: nil].
        (node notNil and: [self peek is: #eof]) ifTrue: [^node]].
    index := start.
    ^self methodSource ]
StParser >> doIt [
    "Statements, with temporaries first: what the REPL compiles."
    | temps stmts |
    temps := #().
    ((self atBin: '|') or: [self atBin: '||']) ifTrue: [temps := self temps].
    stmts := self statements: #eof.
    ^StMethod selector: 'DoIt' arguments: #() temps: temps primitive: 0 statements: stmts line: 1 ]
StParser >> pattern [
    | t sel args |
    t := self peek.
    (t is: #ident) ifTrue: [self next. ^Array with: t value with: #()].
    (t is: #bin) ifTrue: [self next. ^Array with: t value with: (Array with: (self expect: #ident) value)].
    (t is: #kw) ifTrue: [
        sel := ''. args := OrderedCollection new.
        [self peek is: #kw] whileTrue: [sel := sel, self next value. args add: (self expect: #ident) value].
        ^Array with: sel with: args asArray].
    ^self error: 'method pattern expected' ]
StParser >> temps [
    | out |
    (self atBin: '||') ifTrue: [self next. ^#()].
    self next.
    out := OrderedCollection new.
    [self peek is: #ident] whileTrue: [out add: self next value].
    (self atBin: '|') ifFalse: [^self error: '| expected'].
    self next.
    ^out asArray ]
StParser >> pragma [
    | t n |
    self next.
    t := self expect: #kw.
    t value = 'primitive:' ifFalse: [^self error: 'only <primitive: N> is known'].
    n := (self expect: #int) value.
    (self atBin: '>') ifFalse: [^self error: '> expected'].
    self next.
    ^n ]
StParser >> statements: end [
    | out |
    out := OrderedCollection new.
    [self peek is: end] whileFalse: [
        (self peek is: #'^')
            ifTrue: [self next. out add: (StReturn expr: self expression)]
            ifFalse: [out add: self expression].
        (self peek is: #'.')
            ifTrue: [self next]
            ifFalse: [(self peek is: end) ifFalse: [^self error: '. or ', end, ' expected']]].
    ^out asArray ]
StParser >> expression [
    | t |
    t := self peek.
    ((t is: #ident) and: [(self peek: 1) is: #':=']) ifTrue: [
        self next. self next.
        ^StAssign name: t value value: self expression line: t line].
    ^self cascade ]
StParser >> cascade [
    | e msgs |
    e := self keywordExpr.
    (self peek is: #';') ifFalse: [^e].
    e isSend ifFalse: [^self error: 'cascade without a message'].
    msgs := OrderedCollection new.
    msgs add: (Array with: e selector with: e arguments).
    [self peek is: #';'] whileTrue: [self next. msgs add: self cascadeMessage].
    ^StCascade receiver: e receiver messages: msgs asArray ]
StParser >> cascadeMessage [
    | t sel args |
    t := self peek.
    (t is: #ident) ifTrue: [
        self next.
        (self peek is: #ident) ifTrue: [^self error: 'cascade part must be one message'].
        ^Array with: t value with: #()].
    (t is: #bin) ifTrue: [self next. ^Array with: t value with: (Array with: self unaryExpr)].
    (t is: #kw) ifTrue: [
        sel := ''. args := OrderedCollection new.
        [self peek is: #kw] whileTrue: [sel := sel, self next value. args add: self binaryExpr].
        ^Array with: sel with: args asArray].
    ^self error: 'message expected' ]
StParser >> keywordExpr [
    | r line sel args |
    r := self binaryExpr.
    (self peek is: #kw) ifFalse: [^r].
    line := self peek line.
    sel := ''. args := OrderedCollection new.
    [self peek is: #kw] whileTrue: [sel := sel, self next value. args add: self binaryExpr].
    ^StSend receiver: r selector: sel arguments: args asArray line: line ]
StParser >> binaryExpr [
    | r t |
    r := self unaryExpr.
    [self peek is: #bin] whileTrue: [
        t := self next.
        r := StSend receiver: r selector: t value arguments: (Array with: self unaryExpr) line: t line].
    ^r ]
StParser >> unaryExpr [
    | r t |
    r := self primary.
    [(self peek is: #ident) and: [((self peek: 1) is: #':=') not]] whileTrue: [
        t := self next.
        r := StSend receiver: r selector: t value arguments: #() line: t line].
    ^r ]
StParser >> primary [
    | t k e elems |
    t := self peek.
    k := t kind.
    k == #ident ifTrue: [self next. ^StVariable name: t value line: t line].
    k == #int ifTrue: [self next. ^StLiteral value: t value].
    k == #char ifTrue: [self next. ^StLiteral value: (Character value: t value)].
    k == #str ifTrue: [self next. ^StLiteral value: t value].
    k == #sym ifTrue: [self next. ^StLiteral value: t value asSymbol].
    k == #'#(' ifTrue: [self next. ^StLiteral value: self literalArray].
    k == #'#[' ifTrue: [self next. ^StLiteral value: self byteArray].
    k == #'(' ifTrue: [self next. e := self expression. self expect: #')'. ^e].
    k == #'[' ifTrue: [^self block].
    k == #'{' ifTrue: [
        self next.
        elems := OrderedCollection new.
        [self peek is: #'}'] whileFalse: [
            elems add: self expression.
            (self peek is: #'.')
                ifTrue: [self next]
                ifFalse: [(self peek is: #'}') ifFalse: [^self error: '. or } expected']]].
        self next.
        ^StBrace elements: elems asArray].
    ^self error: 'expression expected' ]
StParser >> block [
    | args temps stmts |
    self expect: #'['.
    args := OrderedCollection new.
    [self peek is: #':'] whileTrue: [self next. args add: (self expect: #ident) value].
    temps := #().
    args isEmpty ifFalse: [
        (self atBin: '||')
            ifTrue: [
                self next.
                temps := OrderedCollection new.
                [self peek is: #ident] whileTrue: [temps add: self next value].
                (self atBin: '|') ifFalse: [^self error: '| expected'].
                self next.
                temps := temps asArray]
            ifFalse: [
                (self atBin: '|')
                    ifTrue: [self next]
                    ifFalse: [^self error: '| expected after the block arguments']]].
    ((self atBin: '|') or: [self atBin: '||']) ifTrue: [temps := self temps].
    stmts := self statements: #']'.
    self expect: #']'.
    ^StBlock arguments: args asArray temps: temps statements: stmts ]
StParser >> literalArray [
    | items t k s |
    items := OrderedCollection new.
    [t := self peek.
     k := t kind.
     k == #')'] whileFalse: [
        k == #eof ifTrue: [^self error: ') expected'].
        self next.
        k == #int ifTrue: [items add: t value] ifFalse: [
        k == #char ifTrue: [items add: (Character value: t value)] ifFalse: [
        k == #str ifTrue: [items add: t value] ifFalse: [
        k == #sym ifTrue: [items add: t value asSymbol] ifFalse: [
        k == #ident ifTrue: [
            t value = 'nil' ifTrue: [items add: nil] ifFalse: [
            t value = 'true' ifTrue: [items add: true] ifFalse: [
            t value = 'false' ifTrue: [items add: false] ifFalse: [items add: t value asSymbol]]]] ifFalse: [
        k == #kw ifTrue: [
            s := t value.
            [(self peek is: #kw) and: [self peek start = t stop]] whileTrue: [t := self next. s := s, t value].
            items add: s asSymbol] ifFalse: [
        k == #bin ifTrue: [items add: t value asSymbol] ifFalse: [
        (k == #'(' or: [k == #'#(']) ifTrue: [items add: self literalArray] ifFalse: [
        k == #'#[' ifTrue: [items add: self byteArray] ifFalse: [
        ^self error: 'literal expected']]]]]]]]]].
    self next.
    ^items asArray beImmutable ]
StParser >> byteArray [
    | out v |
    out := OrderedCollection new.
    [self peek is: #int] whileTrue: [
        v := self next value.
        (v between: 0 and: 255) ifFalse: [^self error: 'byte out of range'].
        out add: v].
    self expect: #']'.
    ^(ByteArray withAll: out) beImmutable ]

"---- variables and scopes ---------------------------------------------------------"

StVar class >> name: n kind: k scope: s [ ^self new setName: n kind: k scope: s ]
StVar >> setName: n kind: k scope: s [
    name := n. kind := k. scope := s. captured := false. assigned := false. remote := false. vidx := -1 ]
StVar >> name [ ^name ]
StVar >> kind [ ^kind ]
StVar >> scope [ ^scope ]
StVar >> captured [ ^captured ]
StVar >> assigned [ ^assigned ]
StVar >> remote [ ^remote ]
StVar >> vidx [ ^vidx ]
StVar >> origin [ ^origin ]
StVar >> origin: v [ origin := v ]
StVar >> beCaptured [ captured := true ]
StVar >> beAssigned [ assigned := true ]
StVar >> beRemote: i [ remote := true. vidx := i ]

StScope class >> parent: p isBlock: b [ ^self new setParent: p isBlock: b ]
StScope >> setParent: p isBlock: b [
    parent := p. isBlock := b.
    args := OrderedCollection new. locals := OrderedCollection new. remotes := OrderedCollection new.
    copied := OrderedCollection new. lits := OrderedCollection new. code := OrderedCollection new ]
StScope >> args [ ^args ]
StScope >> locals [ ^locals ]
StScope >> locals: c [ locals := c ]
StScope >> remotes [ ^remotes ]
StScope >> copied [ ^copied ]
StScope >> vector [ ^vector ]
StScope >> vector: v [ vector := v ]
StScope >> lits [ ^lits ]
StScope >> code [ ^code ]
StScope >> isBlock [ ^isBlock ]
StScope >> declareLocal: aName [ | v | v := StVar name: aName kind: #temp scope: self. locals add: v. ^v ]
StScope >> capture: v [
    | c |
    copied do: [:x | x origin == v ifTrue: [^x]].
    c := StVar name: v name kind: #copied scope: self.
    c origin: v.
    copied add: c.
    ^c ]
StScope >> lit: v [
    "The index (0-based) of literal v; equal numbers, strings, symbols, characters and globals are shared."
    | shared |
    shared := v isInteger or: [v isString or: [v isCharacter or: [v class == Association]]].
    shared ifTrue: [
        lits doWithIndex: [:x :i | (x class == v class and: [v class == Association ifTrue: [x == v] ifFalse: [x = v]])
            ifTrue: [^i - 1]]].
    lits add: v.
    lits size > 256 ifTrue: [^CompileError new signal: 'too many literals'].
    ^lits size - 1 ]

StLex class >> parent: p real: r [ ^self new setParent: p real: r ]
StLex >> setParent: p real: r [ parent := p. real := r. names := Dictionary new ]
StLex >> real [ ^real ]
StLex >> names [ ^names ]
StLex >> lookup: aName [
    | s |
    s := self.
    [s == nil] whileFalse: [(s names includesKey: aName) ifTrue: [^s names at: aName]. s := s parent].
    ^nil ]
StLex >> parent [ ^parent ]
StLex >> declare: aName as: v [ names at: aName put: v ]

StLabel >> pos [ ^pos ]
StLabel >> pos: n [ pos := n ]

"---- the compiler -------------------------------------------------------------"

Compiler class >> evaluate: aString [ ^self evaluate: aString for: nil ]
Compiler class >> evaluate: aString for: anObject [
    | m |
    m := self new compileDoIt: aString for: anObject class.
    ^anObject executeMethod: m ]
Object >> executeMethod: aMethod [ <primitive: 112> ^self error: 'not a method without arguments' ]
Compiler >> compileDoIt: aString for: aClass [
    | node stmts |
    node := (StParser on: aString) doIt.
    stmts := node statements.
    (stmts notEmpty and: [stmts last isReturn not]) ifTrue: [
        stmts := stmts copy.
        stmts at: stmts size put: (StReturn expr: stmts last)].
    node setSelector: 'DoIt' arguments: #() temps: node temps primitive: 0 statements: stmts.
    ^self compileMethod: node in: aClass ]
Compiler >> compile: aString in: aClass [
    "Compile a method (its pattern and body, the body in brackets or not) and install it."
    | m |
    m := self compileSource: aString in: aClass.
    aClass addSelector: m selector asSymbol withMethod: m.
    MethodSource note: aString class: aClass selector: m selector.
    ^m ]
Compiler >> compileSource: aString in: aClass [
    ^self compileMethod: (StParser on: aString) methodEither in: aClass ]
Compiler >> compileMethod: aNode in: aClass [
    ivars := aClass allInstVarNames asArray.
    methodClass := aClass.
    ^self compile: aNode ]
Compiler >> error: aString [ ^CompileError new signal: aString ]
Compiler >> compile: m [
    | scope lex |
    m arguments size > 15 ifTrue: [^self error: 'too many arguments'].
    analysis := IdentityDictionary new.
    scope := StScope parent: nil isBlock: false.
    lex := StLex parent: nil real: scope.
    m arguments do: [:a | | v |
        (lex names includesKey: a) ifTrue: [^self error: a, ': argument declared twice'].
        v := StVar name: a kind: #arg scope: scope.
        scope args add: v.
        lex declare: a as: v].
    m temps do: [:t |
        (lex names includesKey: t) ifTrue: [^self error: t, ': declared twice'].
        lex declare: t as: (scope declareLocal: t)].
    scopes := OrderedCollection with: scope.
    self anStatements: m statements in: lex.
    self settle.
    self begin: scope.
    m statements do: [:st |
        st isReturn
            ifTrue: [
                (st expr isVariable and: [st expr name = 'self'])
                    ifTrue: [self emit: scope op: 8]
                    ifFalse: [self genValue: st expr in: lex. self emit: scope op: 7]]
            ifFalse: [self genEffect: st in: lex]].
    (m statements isEmpty or: [m statements last isReturn not]) ifTrue: [self emit: scope op: 8].
    scope lits add: m selector asSymbol.
    scope lits add: methodClass.
    ^self assemble: scope nargs: m arguments size primitive: m primitive isBlock: false ]

"pass 1"
Compiler >> anStatements: stmts in: lex [ stmts do: [:s | self an: s in: lex] ]
Compiler >> an: n in: lex [
    | v inl inlNodes |
    n isLiteral ifTrue: [^self].
    n isVariable ifTrue: [
        v := lex lookup: n name.
        (v notNil and: [v scope ~~ lex real]) ifTrue: [v beCaptured].
        ^self].
    n isAssign ifTrue: [
        (#('self' 'super' 'nil' 'true' 'false' 'thisContext') includes: n name)
            ifTrue: [^self error: 'line ', n line printString, ': cannot assign to ', n name].
        v := lex lookup: n name.
        v notNil ifTrue: [
            v kind == #arg ifTrue: [^self error: 'line ', n line printString, ': cannot assign to the argument ', n name].
            v beAssigned.
            v scope ~~ lex real ifTrue: [v beCaptured]].
        ^self an: n value in: lex].
    n isReturn ifTrue: [^self an: n expr in: lex].
    (n isKindOf: StBrace) ifTrue: [n elements do: [:e | self an: e in: lex]. ^self].
    (n isKindOf: StCascade) ifTrue: [
        self an: n receiver in: lex.
        n messages do: [:m | (m at: 2) do: [:a | self an: a in: lex]].
        ^self].
    n isBlock ifTrue: [^self anBlock: n in: lex].
    n isSend ifTrue: [
        inl := self inlinedArgs: n.
        inl == nil ifTrue: [
            self an: n receiver in: lex.
            n arguments do: [:a | self an: a in: lex].
            ^self].
        inlNodes := inl collect: [:p | p at: 1].
        (n selector = 'to:do:' or: [n selector = 'to:by:do:']) ifTrue: [
            self an: n receiver in: lex.
            self an: (n arguments at: 1) in: lex.
            n selector = 'to:by:do:' ifTrue: [self an: (n arguments at: 2) in: lex].
            analysis at: n put: (lex real declareLocal: nil).
            self anInlined: n arguments last in: lex loopVar: true.
            ^self].
        (inlNodes includesIdentity: n receiver)
            ifTrue: [self anInlined: n receiver in: lex loopVar: false]
            ifFalse: [self an: n receiver in: lex].
        n arguments do: [:a |
            (inlNodes includesIdentity: a)
                ifTrue: [self anInlined: a in: lex loopVar: true]
                ifFalse: [self an: a in: lex]].
        ^self].
    ^self error: 'unknown node' ]
Compiler >> anInlined: b in: lex loopVar: assignedArgs [
    | inner v |
    inner := StLex parent: lex real: lex real.
    b arguments do: [:a |
        v := lex real declareLocal: a.
        inner declare: a as: v.
        assignedArgs ifTrue: [v beAssigned]].
    b temps do: [:t | inner declare: t as: (lex real declareLocal: t)].
    analysis at: b put: inner.
    self anStatements: b statements in: inner ]
Compiler >> anBlock: b in: lex [
    | sc inner v |
    sc := StScope parent: lex real isBlock: true.
    scopes add: sc.
    inner := StLex parent: lex real: sc.
    b arguments size > 15 ifTrue: [^self error: 'too many block arguments'].
    b arguments do: [:a |
        v := StVar name: a kind: #arg scope: sc.
        sc args add: v.
        inner declare: a as: v].
    b temps do: [:t | inner declare: t as: (sc declareLocal: t)].
    analysis at: b put: inner.
    self anStatements: b statements in: inner ]
Compiler >> settle [
    | keep |
    scopes do: [:sc |
        keep := OrderedCollection new.
        sc locals do: [:v |
            (v captured and: [v assigned])
                ifTrue: [v beRemote: sc remotes size. sc remotes add: v]
                ifFalse: [keep add: v]].
        sc locals: keep.
        sc remotes isEmpty ifFalse: [sc vector: (StVar name: '<vector>' kind: #temp scope: sc)]] ]
Compiler >> inlinedArgs: n [
    "Which parts of send n are blocks compiled in line: {{node. nargs}...}, or nil."
    | s a r |
    s := n selector. a := n arguments. r := n receiver.
    n isSuperSend ifTrue: [^nil].
    (#('ifTrue:' 'ifFalse:' 'and:' 'or:') includes: s) ifTrue: [
        ^(self isBlock: a first args: 0) ifTrue: [Array with: (Array with: a first with: 0)] ifFalse: [nil]].
    (s = 'ifTrue:ifFalse:' or: [s = 'ifFalse:ifTrue:']) ifTrue: [
        ^((self isBlock: (a at: 1) args: 0) and: [self isBlock: (a at: 2) args: 0])
            ifTrue: [Array with: (Array with: (a at: 1) with: 0) with: (Array with: (a at: 2) with: 0)] ifFalse: [nil]].
    (s = 'whileTrue:' or: [s = 'whileFalse:']) ifTrue: [
        ^((self isBlock: r args: 0) and: [self isBlock: (a at: 1) args: 0])
            ifTrue: [Array with: (Array with: r with: 0) with: (Array with: (a at: 1) with: 0)] ifFalse: [nil]].
    (#('whileTrue' 'whileFalse' 'repeat') includes: s) ifTrue: [
        ^(self isBlock: r args: 0) ifTrue: [Array with: (Array with: r with: 0)] ifFalse: [nil]].
    s = 'to:do:' ifTrue: [
        ^(self isBlock: (a at: 2) args: 1) ifTrue: [Array with: (Array with: (a at: 2) with: 1)] ifFalse: [nil]].
    s = 'to:by:do:' ifTrue: [
        ^(((a at: 2) isLiteral and: [(a at: 2) value isInteger and: [(a at: 2) value ~= 0]])
            and: [self isBlock: (a at: 3) args: 1])
                ifTrue: [Array with: (Array with: (a at: 3) with: 1)] ifFalse: [nil]].
    s = 'ifNil:' ifTrue: [
        ^(self isBlock: (a at: 1) args: 0) ifTrue: [Array with: (Array with: (a at: 1) with: 0)] ifFalse: [nil]].
    s = 'ifNotNil:' ifTrue: [
        ^((a at: 1) isBlock and: [(a at: 1) arguments size <= 1])
            ifTrue: [Array with: (Array with: (a at: 1) with: (a at: 1) arguments size)] ifFalse: [nil]].
    s = 'ifNil:ifNotNil:' ifTrue: [
        ^((self isBlock: (a at: 1) args: 0) and: [(a at: 2) isBlock and: [(a at: 2) arguments size <= 1]])
            ifTrue: [Array with: (Array with: (a at: 1) with: 0) with: (Array with: (a at: 2) with: (a at: 2) arguments size)]
            ifFalse: [nil]].
    s = 'ifNotNil:ifNil:' ifTrue: [
        ^(((a at: 1) isBlock and: [(a at: 1) arguments size <= 1]) and: [self isBlock: (a at: 2) args: 0])
            ifTrue: [Array with: (Array with: (a at: 1) with: (a at: 1) arguments size) with: (Array with: (a at: 2) with: 0)]
            ifFalse: [nil]].
    ^nil ]
Compiler >> isBlock: n args: k [ ^n isBlock and: [n arguments size = k] ]

"pass 2"
Compiler >> begin: scope [
    scope vector == nil ifFalse: [
        self emit: scope op: 38 with: scope remotes size.
        self emit: scope op: 24 with: scope vector] ]
Compiler >> emit: scope op: op [ scope code add: (Array with: op) ]
Compiler >> emit: scope op: op with: a [ scope code add: (Array with: op with: a) ]
Compiler >> emit: scope op: op with: a with: b [ scope code add: (Array with: op with: a with: b) ]
Compiler >> emit: scope label: l [ scope code add: l ]
Compiler >> genEffect: n in: lex [
    n isAssign
        ifTrue: [self genValue: n value in: lex. self genStore: n name in: lex pop: true]
        ifFalse: [self genValue: n in: lex. self emit: lex real op: 6] ]
Compiler >> genValue: n in: lex [
    | sc sup last |
    sc := lex real.
    n isLiteral ifTrue: [^self genLiteral: n value in: sc].
    n isVariable ifTrue: [^self genLoadName: n name line: n line in: lex].
    n isAssign ifTrue: [self genValue: n value in: lex. ^self genStore: n name in: lex pop: false].
    (n isKindOf: StBrace) ifTrue: [
        n elements size > 255 ifTrue: [^self error: 'brace array too long'].
        n elements do: [:e | self genValue: e in: lex].
        ^self emit: sc op: 30 with: n elements size].
    (n isKindOf: StCascade) ifTrue: [
        self genValue: n receiver in: lex.
        n messages doWithIndex: [:m :i |
            last := i = n messages size.
            last ifFalse: [self emit: sc op: 5].
            (m at: 2) do: [:a | self genValue: a in: lex].
            self genSend: (m at: 1) nargs: (m at: 2) size in: sc super: false.
            last ifFalse: [self emit: sc op: 6]].
        ^self].
    n isBlock ifTrue: [^self genBlock: n in: lex].
    n isSend ifTrue: [
        (self inlinedArgs: n) == nil ifFalse: [^self genInline: n in: lex].
        sup := n isSuperSend.
        sup ifTrue: [self emit: sc op: 0] ifFalse: [self genValue: n receiver in: lex].
        n arguments do: [:a | self genValue: a in: lex].
        ^self genSend: n selector nargs: n arguments size in: sc super: sup].
    n isReturn ifTrue: [^self error: '^ inside an expression'].
    ^self error: 'unknown node' ]
Compiler >> genLiteral: v in: sc [
    v == nil ifTrue: [^self emit: sc op: 1].
    v == true ifTrue: [^self emit: sc op: 2].
    v == false ifTrue: [^self emit: sc op: 3].
    (v isInteger and: [v between: -128 and: 127]) ifTrue: [^self emit: sc op: 26 with: (v bitAnd: 255)].
    self emit: sc op: 18 with: (sc lit: (self literal: v)) ]
Compiler >> literal: v [
    "Literal strings, arrays and byte arrays cannot be changed."
    (v isString and: [v isSymbol not]) ifTrue: [^v copy beImmutable].
    ^v ]
Compiler >> specialIndexOf: sel nargs: n [
    | i |
    i := #(#+ #- #< #> #<= #>= #= #~= #* #/ #\\ #// #bitAnd: #bitOr: #bitShift: #== #class #at: #at:put:
           #size #value #value: #isNil #notNil #new #new: #~~) indexOf: sel asSymbol.
    i = 0 ifTrue: [^nil].
    sel asSymbol numArgs = n ifFalse: [^nil].
    ^i - 1 ]
Compiler >> genSend: sel nargs: n in: sc super: sup [
    | k |
    sup ifTrue: [^self emit: sc op: 33 with: (sc lit: sel asSymbol) with: n].
    k := self specialIndexOf: sel nargs: n.
    k == nil ifFalse: [^self emit: sc op: 34 with: k].
    self emit: sc op: 32 with: (sc lit: sel asSymbol) with: n ]
Compiler >> genLoadName: name line: line in: lex [
    | sc v |
    sc := lex real.
    (name = 'self' or: [name = 'super']) ifTrue: [^self emit: sc op: 0].
    name = 'nil' ifTrue: [^self emit: sc op: 1].
    name = 'true' ifTrue: [^self emit: sc op: 2].
    name = 'false' ifTrue: [^self emit: sc op: 3].
    name = 'thisContext' ifTrue: [^self error: 'line ', line printString, ': thisContext is not supported'].
    v := lex lookup: name.
    v == nil ifFalse: [^self genLoadVar: v in: sc].
    (ivars includes: name) ifTrue: [^self emit: sc op: 16 with: (ivars indexOf: name) - 1].
    self emit: sc op: 19 with: (sc lit: (self globalNamed: name)) ]
Compiler >> globalNamed: name [
    | sym |
    sym := name asSymbol.
    ^Smalltalk associationAt: sym ifAbsent: [
        Smalltalk at: sym put: nil.
        Smalltalk associationAt: sym ifAbsent: [nil]] ]
Compiler >> genLoadVar: v in: sc [
    v scope == sc ifTrue: [
        ^v remote
            ifTrue: [self emit: sc op: 27 with: v vidx with: sc vector]
            ifFalse: [self emit: sc op: 17 with: v]].
    v remote ifTrue: [^self emit: sc op: 27 with: v vidx with: (sc capture: v scope vector)].
    self emit: sc op: 17 with: (sc capture: v) ]
Compiler >> genStore: name in: lex pop: pop [
    | sc v |
    sc := lex real.
    v := lex lookup: name.
    v == nil ifFalse: [^self genStoreVar: v in: sc pop: pop].
    (ivars includes: name) ifTrue: [^self emit: sc op: (pop ifTrue: [23] ifFalse: [20]) with: (ivars indexOf: name) - 1].
    self emit: sc op: (pop ifTrue: [25] ifFalse: [22]) with: (sc lit: (self globalNamed: name)) ]
Compiler >> genStoreVar: v in: sc pop: pop [
    v scope == sc ifTrue: [
        ^v remote
            ifTrue: [self emit: sc op: (pop ifTrue: [29] ifFalse: [28]) with: v vidx with: sc vector]
            ifFalse: [self emit: sc op: (pop ifTrue: [24] ifFalse: [21]) with: v]].
    v remote ifTrue: [^self emit: sc op: (pop ifTrue: [29] ifFalse: [28]) with: v vidx with: (sc capture: v scope vector)].
    ^self error: 'internal: a store into a copied variable' ]
Compiler >> genBlock: b in: lex [
    | inner sc code outer |
    inner := analysis at: b.
    sc := inner real.
    self begin: sc.
    b statements isEmpty ifTrue: [self emit: sc op: 1. self emit: sc op: 9].
    b statements doWithIndex: [:st :i |
        st isReturn
            ifTrue: [self genValue: st expr in: inner. self emit: sc op: 7]
            ifFalse: [
                i = b statements size
                    ifTrue: [self genValue: st in: inner. self emit: sc op: 9]
                    ifFalse: [self genEffect: st in: inner]]].
    sc lits add: methodClass.
    code := self assemble: sc nargs: b arguments size primitive: 0 isBlock: true.
    outer := lex real.
    sc copied do: [:c | self genLoadVar: c origin in: outer].
    self emit: outer op: 31 with: (outer lit: code) with: sc copied size ]
Compiler >> genInlinedValue: b in: lex [
    | inner sc |
    inner := analysis at: b.
    sc := lex real.
    b statements isEmpty ifTrue: [^self emit: sc op: 1].
    b statements doWithIndex: [:st :i |
        st isReturn
            ifTrue: [self genValue: st expr in: inner. self emit: sc op: 7]
            ifFalse: [
                i = b statements size
                    ifTrue: [self genValue: st in: inner]
                    ifFalse: [self genEffect: st in: inner]]] ]
Compiler >> genInlinedEffect: b in: lex [
    | inner sc |
    inner := analysis at: b.
    sc := lex real.
    b statements do: [:st |
        st isReturn
            ifTrue: [self genValue: st expr in: inner. self emit: sc op: 7]
            ifFalse: [self genEffect: st in: inner]] ]
Compiler >> inlinedArg: b [ ^(analysis at: b) names at: b arguments first ]
Compiler >> genInline: n in: lex [
    | sc s a l1 l2 lim blk i step nilb valb |
    sc := lex real.
    s := n selector. a := n arguments.
    l1 := StLabel new. l2 := StLabel new.
    (s = 'ifTrue:' or: [s = 'ifFalse:']) ifTrue: [
        self genValue: n receiver in: lex.
        self emit: sc op: (s = 'ifTrue:' ifTrue: [37] ifFalse: [36]) with: l1.
        self genInlinedValue: a first in: lex.
        self emit: sc op: 35 with: l2. self emit: sc label: l1. self emit: sc op: 1. self emit: sc label: l2.
        ^self].
    (s = 'ifTrue:ifFalse:' or: [s = 'ifFalse:ifTrue:']) ifTrue: [
        self genValue: n receiver in: lex.
        self emit: sc op: (s = 'ifTrue:ifFalse:' ifTrue: [37] ifFalse: [36]) with: l1.
        self genInlinedValue: (a at: 1) in: lex.
        self emit: sc op: 35 with: l2. self emit: sc label: l1.
        self genInlinedValue: (a at: 2) in: lex. self emit: sc label: l2.
        ^self].
    (s = 'and:' or: [s = 'or:']) ifTrue: [
        self genValue: n receiver in: lex.
        self emit: sc op: (s = 'and:' ifTrue: [37] ifFalse: [36]) with: l1.
        self genInlinedValue: a first in: lex.
        self emit: sc op: 35 with: l2. self emit: sc label: l1.
        self emit: sc op: (s = 'and:' ifTrue: [3] ifFalse: [2]). self emit: sc label: l2.
        ^self].
    (s = 'whileTrue:' or: [s = 'whileFalse:']) ifTrue: [
        self emit: sc label: l1.
        self genInlinedValue: n receiver in: lex.
        self emit: sc op: (s = 'whileTrue:' ifTrue: [37] ifFalse: [36]) with: l2.
        self genInlinedEffect: a first in: lex.
        self emit: sc op: 35 with: l1. self emit: sc label: l2. self emit: sc op: 1.
        ^self].
    (s = 'whileTrue' or: [s = 'whileFalse']) ifTrue: [
        self emit: sc label: l1.
        self genInlinedValue: n receiver in: lex.
        self emit: sc op: (s = 'whileTrue' ifTrue: [36] ifFalse: [37]) with: l1.
        self emit: sc op: 1.
        ^self].
    s = 'repeat' ifTrue: [
        self emit: sc label: l1.
        self genInlinedEffect: n receiver in: lex.
        self emit: sc op: 35 with: l1. self emit: sc op: 1.
        ^self].
    (s = 'to:do:' or: [s = 'to:by:do:']) ifTrue: [
        lim := analysis at: n.
        blk := a last.
        i := self inlinedArg: blk.
        step := s = 'to:by:do:' ifTrue: [(a at: 2) value] ifFalse: [1].
        self genValue: n receiver in: lex. self genStoreVar: i in: sc pop: true.
        self genValue: (a at: 1) in: lex. self genStoreVar: lim in: sc pop: true.
        self emit: sc label: l1.
        self genLoadVar: i in: sc. self genLoadVar: lim in: sc.
        self emit: sc op: 34 with: (step > 0 ifTrue: [4] ifFalse: [5]).
        self emit: sc op: 37 with: l2.
        self genInlinedEffect: blk in: lex.
        self genLoadVar: i in: sc. self genLiteral: step in: sc.
        self emit: sc op: 34 with: 0.
        self genStoreVar: i in: sc pop: true.
        self emit: sc op: 35 with: l1. self emit: sc label: l2. self emit: sc op: 1.
        ^self].
    s = 'ifNil:' ifTrue: [
        self genValue: n receiver in: lex.
        self emit: sc op: 5. self emit: sc op: 1. self emit: sc op: 34 with: 15.
        self emit: sc op: 37 with: l1. self emit: sc op: 6.
        self genInlinedValue: a first in: lex. self emit: sc label: l1.
        ^self].
    s = 'ifNotNil:' ifTrue: [
        self genValue: n receiver in: lex.
        self emit: sc op: 5. self emit: sc op: 1. self emit: sc op: 34 with: 15.
        self emit: sc op: 36 with: l1.
        self genNonNilArg: a first in: sc.
        self genInlinedValue: a first in: lex.
        self emit: sc label: l1.
        ^self].
    (s = 'ifNil:ifNotNil:' or: [s = 'ifNotNil:ifNil:']) ifTrue: [
        s = 'ifNil:ifNotNil:'
            ifTrue: [nilb := a at: 1. valb := a at: 2]
            ifFalse: [nilb := a at: 2. valb := a at: 1].
        self genValue: n receiver in: lex.
        self emit: sc op: 5. self emit: sc op: 1. self emit: sc op: 34 with: 15.
        s = 'ifNil:ifNotNil:'
            ifTrue: [
                self emit: sc op: 37 with: l1. self emit: sc op: 6.
                self genInlinedValue: nilb in: lex.
                self emit: sc op: 35 with: l2. self emit: sc label: l1.
                self genNonNilArg: valb in: sc. self genInlinedValue: valb in: lex.
                self emit: sc label: l2]
            ifFalse: [
                self emit: sc op: 36 with: l1.
                self genNonNilArg: valb in: sc. self genInlinedValue: valb in: lex.
                self emit: sc op: 35 with: l2. self emit: sc label: l1. self emit: sc op: 6.
                self genInlinedValue: nilb in: lex.
                self emit: sc label: l2].
        ^self].
    ^self error: 'internal: inline ', s ]
Compiler >> genNonNilArg: b in: sc [
    b arguments isEmpty
        ifTrue: [self emit: sc op: 6]
        ifFalse: [self genStoreVar: (self inlinedArg: b) in: sc pop: true] ]

"assembly"
Compiler >> opLength: op [
    op < 16 ifTrue: [^1].
    (#(27 28 29 31 32 33 35 36 37) includes: op) ifTrue: [^3].
    ^2 ]
Compiler >> stackEffect: ins [
    | op |
    op := ins at: 1.
    (#(0 1 2 3 5 16 17 18 19 26 27 38) includes: op) ifTrue: [^1].
    (#(6 7 9 23 24 25 29 36 37) includes: op) ifTrue: [^-1].
    op = 30 ifTrue: [^1 - (ins at: 2)].
    op = 31 ifTrue: [^1 - (ins at: 3)].
    (op = 32 or: [op = 33]) ifTrue: [^0 - (ins at: 3)].
    op = 34 ifTrue: [^0 - (#(1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 0 1 2 0 0 1 0 0 0 1 1) at: (ins at: 2) + 1)].
    ^0 ]
Compiler >> assemble: sc nargs: nargs primitive: prim isBlock: isBlock [
    | temps index pos bytes depth maxd op x off ntemps header m nlits |
    temps := OrderedCollection new.
    temps addAll: sc args; addAll: sc copied; addAll: sc locals.
    sc vector == nil ifFalse: [temps add: sc vector].
    temps size > 255 ifTrue: [^self error: 'too many temporaries'].
    index := IdentityDictionary new.
    temps doWithIndex: [:v :i | index at: v put: i - 1].
    pos := 0.
    sc code do: [:ins |
        (ins isKindOf: StLabel)
            ifTrue: [ins pos: pos]
            ifFalse: [pos := pos + (self opLength: (ins at: 1))]].
    bytes := WriteStream on: (ByteArray new: pos).
    depth := 0. maxd := 0.
    sc code do: [:ins |
        (ins isKindOf: StLabel) ifFalse: [
            op := ins at: 1.
            bytes nextPut: op.
            (op = 35 or: [op = 36 or: [op = 37]])
                ifTrue: [
                    off := (ins at: 2) pos - (bytes position + 2).
                    (off between: -32768 and: 32767) ifFalse: [^self error: 'method too long'].
                    off < 0 ifTrue: [off := off + 65536].
                    bytes nextPut: (off bitShift: -8); nextPut: (off bitAnd: 255)]
                ifFalse: [
                    2 to: ins size do: [:k |
                        x := ins at: k.
                        (x isKindOf: StVar) ifTrue: [x := index at: x].
                        bytes nextPut: (x bitAnd: 255)]].
            depth := depth + (self stackEffect: ins).
            maxd := maxd max: depth]].
    maxd > 255 ifTrue: [^self error: 'expression too deep'].
    ntemps := temps size - nargs.
    nlits := sc lits size.
    header := nargs + (ntemps bitShift: 8) + (nlits bitShift: 16) + (prim bitShift: 24)
        + (sc copied size bitShift: 36) + ((isBlock ifTrue: [1] ifFalse: [0]) bitShift: 44) + (maxd bitShift: 45).
    bytes := bytes contents.
    m := (isBlock ifTrue: [CompiledBlock] ifFalse: [CompiledMethod]) header: header numBytes: bytes size.
    sc lits doWithIndex: [:l :i | m literalAt: i put: l].
    1 to: bytes size do: [:i | m byteAt: i put: (bytes at: i)].
    ^m ]
