"Compiler.st: the compiler in the image. It follows lang/stratalk/host/stc.py
 step by step and gives the same bytes (stratalk.py check compares them):
 a scanner, a parser to a tree, pass 1 (what blocks capture), pass 2 (code)."

Object subclass: #StToken slots: 'kind value start stop line'.
"One token from StScanner: kind is a Symbol (#ident #kw #bin #int #char #str
 #sym #eof, or the punctuation itself: #'(' #'[' #':=' #'#(' ...); value its
 text or number (a character's code for #char); start and stop where it lies
 in the source (stop is one past its end); line the line it is on.
 (StScanner scan: 'x := 3') first kind >>> #ident"

Object subclass: #StScanner slots: 'source pos line tokens'.
"The compiler's scanning phase: turns source text into StTokens. source is the
 text, pos the index of the next character, line the current line (for
 errors), tokens the OrderedCollection made so far. Comments and blanks are
 skipped; a minus sign right before digits is part of the number unless an
 operand ends just before it. There are no floating point literals.
 (StScanner scan: 'x := 3') size >>> 4"

Object subclass: #StParser slots: 'tokens index source'.
"The compiler's parsing phase: a recursive descent parser from StScanner's
 tokens to a tree of StNodes, as stc.py's Parser. tokens are the tokens, index
 the next one, source the text (kept for the methods' source in items). Errors
 are CompileErrors that name the line."

Object subclass: #StNode slots: 'line'.
"The abstract node of the syntax tree that StParser builds. line is the source
 line it starts on (set for variables, assignments, sends and methods). The
 is... tests answer false here; each subclass answers true to its own."

StNode subclass: #StLiteral slots: 'value'.
"A literal in the tree: a number, character, string, symbol, literal array or
 byte array, held in value."

StNode subclass: #StVariable slots: 'name'.
"A name used as a value: a temp, an argument, an instance variable, a global,
 or one of self super nil true false thisContext. name is the String."

StNode subclass: #StAssign slots: 'name value'.
"An assignment in the tree: name := value. name is the assigned variable's
 name (a String), value the node of the expression."

StNode subclass: #StSend slots: 'receiver selector arguments'.
"A message send in the tree: receiver (a node), selector (a String) and
 arguments (an Array of nodes). A send to super is one whose receiver is the
 variable super."

StNode subclass: #StCascade slots: 'receiver messages'.
"A cascade in the tree: receiver (a node, evaluated once) and messages, an
 Array of {selector. arguments} pairs sent to it in turn."

StNode subclass: #StBlock slots: 'arguments temps statements'.
"A block in the tree: arguments and temps (Arrays of names) and statements (an
 Array of nodes). Depending on the send it is an argument of, it becomes a
 closure (pushClosure) or is compiled in line."

StNode subclass: #StBrace slots: 'elements'.
"A brace array in the tree, {a. b. c}: elements is the Array of nodes,
 compiled to pushArray."

StNode subclass: #StReturn slots: 'expr'.
"A ^ statement in the tree; expr is the node of the returned expression."

StNode subclass: #StMethod slots: 'selector arguments temps primitive statements'.
"The root of a method's tree (or of a doIt's): selector (a String), arguments
 and temps (Arrays of names), primitive (its number, 0 for none) and
 statements."

Object subclass: #StVar slots: 'name kind scope captured assigned remote vidx origin'.
"A variable in the compiler's scope analysis: name; kind (#arg, #temp or
 #copied); scope, the StScope that owns its slot; captured (used from an inner
 block) and assigned; remote, true when it lives in its scope's temp vector at
 index vidx (captured and assigned); and origin, for a #copied variable, the
 outer StVar it copies."

Object subclass: #StScope slots: 'parent isBlock args locals remotes copied vector lits code'.
"One compiled unit, a method or a real block, in the compiler: parent is the
 enclosing scope, isBlock which it is; args, locals, remotes (variables kept
 in the temp vector) and copied (variables copied into the closure) are
 StVars; vector is the StVar that holds the temp vector, or nil; lits the
 literals and code the instructions emitted for it, as Arrays of the opcode
 and its operands, with StLabels between them."

Object subclass: #StLex slots: 'parent real names'.
"A lexical level for name lookup in the compiler: a method, a real block or a
 block compiled in line. names maps names to StVars; parent is the enclosing
 level; real is the StScope whose slots the names live in (an in-line block's
 real is its enclosing scope)."

Object subclass: #StLabel slots: 'pos'.
"A jump target in a scope's code during code generation; pos is its byte
 offset, set when the code is assembled."

Object subclass: #Compiler slots: 'ivars methodClass analysis scopes'.
"The compiler in the image, which the REPL, file-in and Behavior compile: use.
 It follows lang/stratalk/host/stc.py step by step and gives the same bytes:
 scanning (StScanner), parsing (StParser), pass 1, the scope analysis (which
 variables blocks capture, which go in a temp vector, an:in:), and pass 2,
 code generation (gen...) and assembly into a CompiledMethod or CompiledBlock.
 ivars are the instance variable names of methodClass, the class compiled for;
 analysis maps nodes to what pass 1 found (block nodes to their StLex, to:do:
 sends to their limit variable); scopes are the StScopes in order.
 Compiler evaluate: '3 + 4' >>> 7"

"---- tokens and the scanner ----------------------------------------------------"

StToken class >> kind: k value: v start: s stop: e line: l [
    "A new token of kind k with value v, from index s to e (one past its end)
     on line l."
    ^self new setKind: k value: v start: s stop: e line: l ]
StToken >> setKind: k value: v start: s stop: e line: l [
    "Sets all the token's slots."
    kind := k. value := v. start := s. stop := e. line := l ]
StToken >> kind [
    "The token's kind, a Symbol: #ident #kw #bin #int #char #str #sym #eof or
     a punctuation Symbol."
    ^kind ]
StToken >> value [
    "The token's value: its text, a number for #int, a character code for
     #char, nil for punctuation."
    ^value ]
StToken >> start [
    "The index in the source of the token's first character."
    ^start ]
StToken >> stop [
    "The index in the source one past the token's last character."
    ^stop ]
StToken >> line [
    "The source line the token is on."
    ^line ]
StToken >> is: k [
    "Whether the token is of kind k."
    ^kind == k ]
StToken >> isBin: op [
    "Whether the token is the binary operator op (a String)."
    ^kind == #bin and: [value = op] ]

StScanner class >> scan: aString [
    "Scans aString and answers its tokens, an OrderedCollection of StTokens
     ending with an #eof token. Signals a CompileError on bad input."
    ^self new setSource: aString; scan ]
StScanner >> setSource: aString [
    "Starts scanning aString from its first character, on line 1."
    source := aString. pos := 1. line := 1. tokens := OrderedCollection new ]
StScanner >> error: aString [
    "Signals a CompileError for the current line, its text prefixed with the
     line number."
    ^(CompileError new) line: line; signal: 'line ', line printString, ': ', aString ]
StScanner >> peekAt: i [
    "The character at index i, or nil past the end."
    i > source size ifTrue: [^nil]. ^source at: i ]
StScanner >> isLetter: c [
    "Whether c can start or continue a name: a letter or the underscore (false
     for nil)."
    ^c notNil and: [c isLetter or: [c = $_]] ]
StScanner >> isDigit: c [
    "Whether c is a decimal digit (false for nil)."
    ^c notNil and: [c isDigit] ]
StScanner >> isBinChar: c [
    "Whether c can be part of a binary operator: one of + - * / backslash < >
     = ~ @ % pipe & ? and comma (false for nil)."
    ^c notNil and: ['+-*/\<>=~@%|&?,' includes: c] ]
StScanner >> add: k value: v from: s to: e [
    "Appends a token of kind k with value v, from index s to e, on the current
     line."
    tokens add: (StToken kind: k value: v start: s stop: e line: line) ]
StScanner >> lastKind [
    "The kind of the last token scanned, or nil if there is none."
    tokens isEmpty ifTrue: [^nil]. ^tokens last kind ]
StScanner >> operandEnded [
    "Whether the last token ends an operand (a name, a literal or a closing
     bracket), so that a minus sign after it is the binary operator and not a
     negative number's sign."
    ^#(#ident #int #char #str #sym #')' #']' #'}') includes: self lastKind ]
StScanner >> skipBlanks [
    "Skips white space and comments, counting lines. Signals a CompileError
     for a comment without its end."
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
    "Scans the whole source and answers the tokens, the last one #eof."
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
    "Scans a name (an #ident token) or a keyword (a #kw token with its colon;
     not when := follows)."
    | s j |
    s := pos. j := pos.
    [j <= source size and: [(self isLetter: (source at: j)) or: [(source at: j) isDigit]]] whileTrue: [j := j + 1].
    ((self peekAt: j) = $: and: [(self peekAt: j + 1) ~= $=])
        ifTrue: [self add: #kw value: (source copyFrom: s to: j) from: s to: j + 1. pos := j + 1]
        ifFalse: [self add: #ident value: (source copyFrom: s to: j - 1) from: s to: j. pos := j] ]
StScanner >> scanNumber [
    "Scans an integer literal: decimal, with an optional minus sign, or radix
     (16r1F, the digits uppercase). Signals a CompileError for a radix without
     digits, a radix outside 2 to 36, a digit too big for the radix (2r9),
     and for a floating point number."
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
            (base between: 2 and: 36) ifFalse: [^self error: 'a radix is 2 to 36'].
            v := 0.
            j + 1 to: k - 1 do: [:m |
                (source at: m) digitValue >= base ifTrue: [^self error: 'a digit too big for the radix'].
                v := v * base + (source at: m) digitValue].
            j := k]
        ifFalse: [
            ((self peekAt: j) = $. and: [self isDigit: (self peekAt: j + 1)])
                ifTrue: [^self error: 'floating point numbers are not supported']].
    neg ifTrue: [v := 0 - v].
    self add: #int value: v from: s to: j.
    pos := j ]
StScanner >> scanString: from [
    "Scans the string literal whose opening quote is at from, a doubled quote
     standing for one; answers {its text. the index after it}. Signals a
     CompileError for a string without its end."
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
    "Scans a token that starts with c, not a letter or digit: a character
     literal, a string, a # literal, :=, punctuation or a binary operator.
     Signals a CompileError for an unexpected character."
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
    "Scans what follows #: #( and #[ (literal and byte arrays), or a symbol,
     quoted, a name with colons, or binary. Signals a CompileError for
     anything else."
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

StNode >> line [
    "The source line the node starts on."
    ^line ]
StNode >> line: n [
    "Sets the source line the node starts on."
    line := n ]
StNode >> isReturn [
    "Whether the node is a ^ statement: false here."
    ^false ]
StNode >> isBlock [
    "Whether the node is a block: false here."
    ^false ]
StNode >> isSend [
    "Whether the node is a message send: false here."
    ^false ]
StNode >> isVariable [
    "Whether the node is a variable: false here."
    ^false ]
StNode >> isLiteral [
    "Whether the node is a literal: false here."
    ^false ]
StNode >> isAssign [
    "Whether the node is an assignment: false here."
    ^false ]
StLiteral class >> value: v [
    "A new literal node for v."
    ^self new setValue: v ]
StLiteral >> setValue: v [
    "Sets the literal's value."
    value := v ]
StLiteral >> value [
    "The literal's value."
    ^value ]
StLiteral >> isLiteral [
    "Answers true: the node is a literal."
    ^true ]
StVariable class >> name: n line: l [
    "A new variable node for name n, on line l."
    ^self new setName: n; line: l; yourself ]
StVariable >> setName: n [
    "Sets the variable's name."
    name := n ]
StVariable >> name [
    "The variable's name, a String."
    ^name ]
StVariable >> isVariable [
    "Answers true: the node is a variable."
    ^true ]
StVariable >> isSuper [
    "Whether the variable is super."
    ^name = 'super' ]
StAssign class >> name: n value: v line: l [
    "A new assignment node of value v to the variable named n, on line l."
    ^self new setName: n value: v; line: l; yourself ]
StAssign >> setName: n value: v [
    "Sets the assigned variable's name and the value's node."
    name := n. value := v ]
StAssign >> name [
    "The name of the assigned variable."
    ^name ]
StAssign >> value [
    "The node of the assigned expression."
    ^value ]
StAssign >> isAssign [
    "Answers true: the node is an assignment."
    ^true ]
StSend class >> receiver: r selector: s arguments: a line: l [
    "A new send node: receiver r, selector s, arguments a, on line l."
    ^self new setReceiver: r selector: s arguments: a; line: l; yourself ]
StSend >> setReceiver: r selector: s arguments: a [
    "Sets the receiver, selector and arguments."
    receiver := r. selector := s. arguments := a ]
StSend >> receiver [
    "The node of the receiver."
    ^receiver ]
StSend >> selector [
    "The selector, a String."
    ^selector ]
StSend >> arguments [
    "The argument nodes, an Array."
    ^arguments ]
StSend >> isSend [
    "Answers true: the node is a send."
    ^true ]
StSend >> isSuperSend [
    "Whether the send is to super."
    ^receiver isVariable and: [receiver isSuper] ]
StCascade class >> receiver: r messages: m [
    "A new cascade node: receiver r and messages m, an Array of {selector.
     arguments}."
    ^self new setReceiver: r messages: m ]
StCascade >> setReceiver: r messages: m [
    "Sets the receiver and the messages."
    receiver := r. messages := m ]
StCascade >> receiver [
    "The node of the cascade's receiver."
    ^receiver ]
StCascade >> messages [
    "The messages, an Array of {selector. argument nodes}."
    ^messages ]
StBlock class >> arguments: a temps: t statements: s [
    "A new block node with argument names a, temp names t and statement nodes
     s."
    ^self new setArguments: a temps: t statements: s ]
StBlock >> setArguments: a temps: t statements: s [
    "Sets the arguments, temps and statements."
    arguments := a. temps := t. statements := s ]
StBlock >> arguments [
    "The names of the block's arguments."
    ^arguments ]
StBlock >> temps [
    "The names of the block's temps."
    ^temps ]
StBlock >> statements [
    "The block's statement nodes."
    ^statements ]
StBlock >> isBlock [
    "Answers true: the node is a block."
    ^true ]
StBlock >> isBlock: n [
    "Whether the block takes n arguments."
    ^arguments size = n ]
StBrace class >> elements: e [
    "A new brace array node with element nodes e."
    ^self new setElements: e ]
StBrace >> setElements: e [
    "Sets the element nodes."
    elements := e ]
StBrace >> elements [
    "The element nodes."
    ^elements ]
StReturn class >> expr: e [
    "A new ^ node returning expression e."
    ^self new setExpr: e ]
StReturn >> setExpr: e [
    "Sets the returned expression's node."
    expr := e ]
StReturn >> expr [
    "The node of the returned expression."
    ^expr ]
StReturn >> isReturn [
    "Answers true: the node is a ^ statement."
    ^true ]
StMethod class >> selector: s arguments: a temps: t primitive: p statements: st line: l [
    "A new method node: selector s, argument names a, temp names t, primitive
     number p (0 for none), statements st, on line l."
    ^self new setSelector: s arguments: a temps: t primitive: p statements: st; line: l; yourself ]
StMethod >> setSelector: s arguments: a temps: t primitive: p statements: st [
    "Sets the selector, arguments, temps, primitive number and statements."
    selector := s. arguments := a. temps := t. primitive := p. statements := st ]
StMethod >> selector [
    "The method's selector, a String."
    ^selector ]
StMethod >> arguments [
    "The names of the method's arguments."
    ^arguments ]
StMethod >> temps [
    "The names of the method's temps."
    ^temps ]
StMethod >> primitive [
    "The method's primitive number, 0 if it has none."
    ^primitive ]
StMethod >> statements [
    "The method's statement nodes."
    ^statements ]

"---- the parser -------------------------------------------------------------------"

StParser class >> on: aString [
    "A parser on aString's tokens. Signals a CompileError if aString does not
     scan.
     (StParser on: '3 + 4. 5') doIt statements size >>> 2"
    ^self new setTokens: (StScanner scan: aString) source: aString ]
StParser >> setTokens: t source: aString [
    "Sets the tokens and the source text, and starts at the first token."
    tokens := t. index := 1. source := aString ]
StParser >> setTokens: t [
    "Sets the tokens and starts at the first token, with no source text."
    tokens := t. index := 1 ]
StParser >> peek [
    "The next token, not consumed (the #eof token at the end)."
    ^tokens at: (index min: tokens size) ]
StParser >> peek: k [
    "The token k after the next one, not consumed (the #eof token past the
     end)."
    ^tokens at: (index + k min: tokens size) ]
StParser >> next [
    "Consumes the next token and answers it."
    | t | t := tokens at: index. index := index + 1. ^t ]
StParser >> error: aString [
    "Signals a CompileError for the next token's line, its text prefixed with
     the line number."
    ^(CompileError new) line: self peek line; signal: 'line ', self peek line printString, ': ', aString ]
StParser >> expect: k [
    "Consumes the next token and answers it if it is of kind k; signals a
     CompileError if not."
    (self peek is: k) ifFalse: [^self error: k, ' expected']. ^self next ]
StParser >> atBin: op [
    "Whether the next token is the binary operator op."
    ^self peek isBin: op ]
StParser >> items [
    "Parses a file's contents into its items, in order: {#method. class name.
     meta. StMethod. source} for a `Class >> pattern [ body ]` definition,
     {#expr. node. line} for an expression, {#vars. names} for a | declaration
     |. What file-in compiles and runs."
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
    "Whether a method definition starts here: a name, optionally class, then
     >>."
    | k |
    (self peek is: #ident) ifFalse: [^false].
    k := 1.
    (((self peek: 1) is: #ident) and: [(self peek: 1) value = 'class']) ifTrue: [k := 2].
    ^(self peek: k) isBin: '>>' ]
StParser >> methodDef [
    "Parses a method's pattern and its body in brackets, with temps and a
     primitive pragma in either order; answers an StMethod."
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
    "Parses a method's pattern and a body without brackets, up to the end;
     answers an StMethod."
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
    "Parses a method's pattern and body, the body in brackets (as in a file)
     or not (as in the browser); answers an StMethod. A body that begins with
     a block is told from one in brackets by trying methodDef first."
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
    "Parses statements up to the end, with temps first, as an StMethod with
     the selector DoIt: what the REPL compiles."
    | temps stmts |
    temps := #().
    ((self atBin: '|') or: [self atBin: '||']) ifTrue: [temps := self temps].
    stmts := self statements: #eof.
    ^StMethod selector: 'DoIt' arguments: #() temps: temps primitive: 0 statements: stmts line: 1 ]
StParser >> pattern [
    "Parses a method pattern, unary, binary or keyword; answers {selector.
     argument names}. Signals a CompileError if there is none."
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
    "Parses a temps declaration between bars (|| for none); answers the names."
    | out |
    (self atBin: '||') ifTrue: [self next. ^#()].
    self next.
    out := OrderedCollection new.
    [self peek is: #ident] whileTrue: [out add: self next value].
    (self atBin: '|') ifFalse: [^self error: '| expected'].
    self next.
    ^out asArray ]
StParser >> pragma [
    "Parses <primitive: N> and answers N. Signals a CompileError for any other
     pragma."
    | t n |
    self next.
    t := self expect: #kw.
    t value = 'primitive:' ifFalse: [^self error: 'only <primitive: N> is known'].
    n := (self expect: #int) value.
    (self atBin: '>') ifFalse: [^self error: '> expected'].
    self next.
    ^n ]
StParser >> statements: end [
    "Parses statements separated by periods up to a token of kind end (not
     consumed); a statement that starts with ^ becomes an StReturn. Answers an
     Array of nodes."
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
    "Parses an expression: an assignment, or a cascade or a send below it."
    | t |
    t := self peek.
    ((t is: #ident) and: [(self peek: 1) is: #':=']) ifTrue: [
        self next. self next.
        ^StAssign name: t value value: self expression line: t line].
    ^self cascade ]
StParser >> cascade [
    "Parses a keyword expression and the cascade parts after it, if any;
     answers the send or an StCascade. Signals a CompileError for a cascade on
     something that is not a send."
    | e msgs |
    e := self keywordExpr.
    (self peek is: #';') ifFalse: [^e].
    e isSend ifFalse: [^self error: 'cascade without a message'].
    msgs := OrderedCollection new.
    msgs add: (Array with: e selector with: e arguments).
    [self peek is: #';'] whileTrue: [self next. msgs add: self cascadeMessage].
    ^StCascade receiver: e receiver messages: msgs asArray ]
StParser >> cascadeMessage [
    "Parses one message of a cascade after its semicolon; answers {selector.
     argument nodes}."
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
    "Parses a keyword send, or the binary expression if there is no keyword."
    | r line sel args |
    r := self binaryExpr.
    (self peek is: #kw) ifFalse: [^r].
    line := self peek line.
    sel := ''. args := OrderedCollection new.
    [self peek is: #kw] whileTrue: [sel := sel, self next value. args add: self binaryExpr].
    ^StSend receiver: r selector: sel arguments: args asArray line: line ]
StParser >> binaryExpr [
    "Parses binary sends from left to right over unary expressions."
    | r t |
    r := self unaryExpr.
    [self peek is: #bin] whileTrue: [
        t := self next.
        r := StSend receiver: r selector: t value arguments: (Array with: self unaryExpr) line: t line].
    ^r ]
StParser >> unaryExpr [
    "Parses a primary and the unary sends after it."
    | r t |
    r := self primary.
    [(self peek is: #ident) and: [((self peek: 1) is: #':=') not]] whileTrue: [
        t := self next.
        r := StSend receiver: r selector: t value arguments: #() line: t line].
    ^r ]
StParser >> primary [
    "Parses a primary: a variable, a literal, a parenthesized expression, a
     block or a brace array. Signals a CompileError if none is there."
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
    "Parses a block in brackets, its arguments, temps and statements; answers
     an StBlock."
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
    "Parses a literal array's elements after #( up to its ): numbers,
     characters, strings, symbols, nil true false, bare names and keywords as
     symbols, nested arrays and byte arrays. Answers an immutable Array."
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
    "Parses a byte array's elements after #[ up to its ]; answers an immutable
     ByteArray. Signals a CompileError for an element outside 0 to 255."
    | out v |
    out := OrderedCollection new.
    [self peek is: #int] whileTrue: [
        v := self next value.
        (v between: 0 and: 255) ifFalse: [^self error: 'byte out of range'].
        out add: v].
    self expect: #']'.
    ^(ByteArray withAll: out) beImmutable ]

"---- variables and scopes ---------------------------------------------------------"

StVar class >> name: n kind: k scope: s [
    "A new variable named n, of kind k (#arg #temp or #copied), owned by scope
     s; not captured, assigned or remote."
    ^self new setName: n kind: k scope: s ]
StVar >> setName: n kind: k scope: s [
    "Sets the name, kind and scope, and clears the flags."
    name := n. kind := k. scope := s. captured := false. assigned := false. remote := false. vidx := -1 ]
StVar >> name [
    "The variable's name."
    ^name ]
StVar >> kind [
    "The variable's kind: #arg, #temp or #copied."
    ^kind ]
StVar >> scope [
    "The StScope that owns the variable's slot."
    ^scope ]
StVar >> captured [
    "Whether an inner block uses the variable."
    ^captured ]
StVar >> assigned [
    "Whether the variable is assigned to."
    ^assigned ]
StVar >> remote [
    "Whether the variable lives in its scope's temp vector."
    ^remote ]
StVar >> vidx [
    "The variable's index (0-based) in the temp vector, -1 if it is not
     remote."
    ^vidx ]
StVar >> origin [
    "For a copied variable, the outer variable it is a copy of."
    ^origin ]
StVar >> origin: v [
    "Sets the outer variable this copy is of."
    origin := v ]
StVar >> beCaptured [
    "Marks the variable as used from an inner block."
    captured := true ]
StVar >> beAssigned [
    "Marks the variable as assigned to."
    assigned := true ]
StVar >> beRemote: i [
    "Puts the variable in the temp vector at index i."
    remote := true. vidx := i ]

StScope class >> parent: p isBlock: b [
    "A new scope inside scope p (nil for a method), a block's if b."
    ^self new setParent: p isBlock: b ]
StScope >> setParent: p isBlock: b [
    "Sets the parent and the kind, with empty variables, literals and code."
    parent := p. isBlock := b.
    args := OrderedCollection new. locals := OrderedCollection new. remotes := OrderedCollection new.
    copied := OrderedCollection new. lits := OrderedCollection new. code := OrderedCollection new ]
StScope >> args [
    "The argument variables, in order."
    ^args ]
StScope >> locals [
    "The local temp variables (after settle, not those in the temp vector)."
    ^locals ]
StScope >> locals: c [
    "Sets the local temp variables."
    locals := c ]
StScope >> remotes [
    "The variables kept in the temp vector, in order of their index."
    ^remotes ]
StScope >> copied [
    "The variables copied into the block's closure, in order."
    ^copied ]
StScope >> vector [
    "The variable that holds the temp vector, or nil if the scope has none."
    ^vector ]
StScope >> vector: v [
    "Sets the variable that holds the temp vector."
    vector := v ]
StScope >> lits [
    "The literals so far, in order."
    ^lits ]
StScope >> code [
    "The instructions so far: Arrays of an opcode and its operands, and
     StLabels."
    ^code ]
StScope >> isBlock [
    "Whether the scope is a block's."
    ^isBlock ]
StScope >> declareLocal: aName [
    "Adds a temp variable named aName (nil for a hidden one, as a to:do:
     limit) and answers it."
    | v | v := StVar name: aName kind: #temp scope: self. locals add: v. ^v ]
StScope >> capture: v [
    "The variable in this block's copied values that copies outer variable v,
     added if it is not there yet."
    | c |
    copied do: [:x | x origin == v ifTrue: [^x]].
    c := StVar name: v name kind: #copied scope: self.
    c origin: v.
    copied add: c.
    ^c ]
StScope >> lit: v [
    "The index (0-based) of literal v in this scope, added if needed; equal
     numbers, strings, symbols and characters, and identical globals, are
     shared. Signals a CompileError for more than 255 literals (the
     header's count has 8 bits; assemble: checks again with the selector
     and the class added)."
    | shared |
    shared := v isInteger or: [v isString or: [v isCharacter or: [v class == Association]]].
    shared ifTrue: [
        lits doWithIndex: [:x :i | (x class == v class and: [v class == Association ifTrue: [x == v] ifFalse: [x = v]])
            ifTrue: [^i - 1]]].
    lits add: v.
    lits size > 255 ifTrue: [^CompileError new signal: 'too many literals'].
    ^lits size - 1 ]

StLex class >> parent: p real: r [
    "A new lexical level inside p (nil at the method), whose names live in
     scope r."
    ^self new setParent: p real: r ]
StLex >> setParent: p real: r [
    "Sets the parent level and the real scope, with no names yet."
    parent := p. real := r. names := Dictionary new ]
StLex >> real [
    "The StScope whose slots this level's names live in."
    ^real ]
StLex >> names [
    "The Dictionary of this level's names to their StVars."
    ^names ]
StLex >> lookup: aName [
    "The StVar named aName at this level or an enclosing one, or nil (an
     instance variable or a global)."
    | s |
    s := self.
    [s == nil] whileFalse: [(s names includesKey: aName) ifTrue: [^s names at: aName]. s := s parent].
    ^nil ]
StLex >> parent [
    "The enclosing lexical level, or nil."
    ^parent ]
StLex >> declare: aName as: v [
    "Declares aName at this level as variable v."
    names at: aName put: v ]

StLabel >> pos [
    "The label's byte offset in the code, once assembled."
    ^pos ]
StLabel >> pos: n [
    "Sets the label's byte offset."
    pos := n ]

"---- the compiler -------------------------------------------------------------"

Compiler class >> evaluate: aString [
    "Compiles aString as a doIt with nil as the receiver, runs it and answers
     its value.
     Compiler evaluate: '3 + 4' >>> 7"
    ^self evaluate: aString for: nil ]
Compiler class >> evaluate: aString for: anObject [
    "Compiles aString as a doIt in anObject's class, runs it with anObject as
     self and answers the value of its last statement.
     Compiler evaluate: 'self + 1' for: 41 >>> 42"
    | m |
    m := self new compileDoIt: aString for: anObject class.
    ^anObject executeMethod: m ]
Object >> executeMethod: aMethod [
    "Runs aMethod, a method without arguments, with the receiver as self and
     answers its value. A VM primitive (112); signals an Error if aMethod is
     not such a method."
    <primitive: 112> ^self error: 'not a method without arguments' ]
Compiler >> compileDoIt: aString for: aClass [
    "Compiles aString as a doIt method for aClass: temps and statements, the
     last statement returned. Answers the CompiledMethod, not installed."
    | node stmts |
    node := (StParser on: aString) doIt.
    stmts := node statements.
    (stmts notEmpty and: [stmts last isReturn not]) ifTrue: [
        stmts := stmts copy.
        stmts at: stmts size put: (StReturn expr: stmts last)].
    node setSelector: 'DoIt' arguments: #() temps: node temps primitive: 0 statements: stmts.
    ^self compileMethod: node in: aClass ]
Compiler >> compile: aString in: aClass [
    "Compiles a method (its pattern and body, the body in brackets or not) for
     aClass, installs it in aClass's method dictionary, notes its source for
     the browser (MethodSource) and answers it."
    | m |
    m := self compileSource: aString in: aClass.
    aClass addSelector: m selector asSymbol withMethod: m.
    MethodSource note: aString class: aClass selector: m selector.
    ^m ]
Compiler >> compileSource: aString in: aClass [
    "Compiles a method's source for aClass and answers the CompiledMethod, not
     installed."
    ^self compileMethod: (StParser on: aString) methodEither in: aClass ]
Compiler >> compileMethod: aNode in: aClass [
    "Compiles the StMethod aNode for aClass, its instance variables known;
     answers the CompiledMethod."
    ivars := aClass allInstVarNames asArray.
    methodClass := aClass.
    ^self compile: aNode ]
Compiler >> error: aString [
    "Signals a CompileError with aString."
    ^CompileError new signal: aString ]
Compiler >> compile: m [
    "Compiles StMethod m: declares its arguments and temps, runs pass 1 (scope
     analysis) and pass 2 (code), ending with returnSelf if the last statement
     does not return, adds the selector and the method class as the last
     literals and assembles it. Signals a CompileError for over 15 arguments
     or a name declared twice."
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
Compiler >> anStatements: stmts in: lex [
    "Pass 1 (scope analysis) over statements stmts at lexical level lex."
    stmts do: [:s | self an: s in: lex] ]
Compiler >> an: n in: lex [
    "Pass 1 (scope analysis) over node n at level lex: marks variables used or
     assigned from an inner block as captured and assigned, makes scopes for
     real blocks and levels for blocks compiled in line, and a hidden limit
     temp for to:do:. Signals a CompileError for an assignment to a
     pseudo-variable or an argument."
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
    "Pass 1 over a block compiled in line: its arguments and temps become
     temps of the enclosing scope (the arguments marked assigned when
     assignedArgs, as a loop variable is), in a new lexical level."
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
    "Pass 1 over a real block: a new StScope with its arguments and temps, and
     its statements analysed in it. Signals a CompileError for over 15 block
     arguments."
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
    "Ends pass 1: in each scope a temp that is both captured and assigned
     moves into the temp vector, and a scope with any gets the variable that
     holds the vector."
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
    "Which parts of send n are blocks compiled in line: an Array of {block
     node. number of arguments}, or nil if the send is a real send. ifTrue:
     and the like, and: or:, whileTrue: whileFalse: repeat, to:do: (to:by:do:
     with a literal non-zero step), and ifNil: and the like, each only with
     literal blocks of the right arity; never for super."
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
Compiler >> isBlock: n args: k [
    "Whether node n is a literal block of k arguments."
    ^n isBlock and: [n arguments size = k] ]

"pass 2"
Compiler >> begin: scope [
    "Starts a scope's code: if it has a temp vector, emits pushNewVector (38)
     of its size and popStoreTemp (24) into the vector's temp."
    scope vector == nil ifFalse: [
        self emit: scope op: 38 with: scope remotes size.
        self emit: scope op: 24 with: scope vector] ]
Compiler >> emit: scope op: op [
    "Appends instruction op, without operands, to scope's code."
    scope code add: (Array with: op) ]
Compiler >> emit: scope op: op with: a [
    "Appends instruction op with operand a (a number, an StVar or an StLabel)
     to scope's code."
    scope code add: (Array with: op with: a) ]
Compiler >> emit: scope op: op with: a with: b [
    "Appends instruction op with operands a and b to scope's code."
    scope code add: (Array with: op with: a with: b) ]
Compiler >> emit: scope label: l [
    "Places label l here in scope's code."
    scope code add: l ]
Compiler >> genEffect: n in: lex [
    "Pass 2: the code for node n as a statement whose value is not used: an
     assignment ends with a pop-and-store, anything else with pop (6)."
    n isAssign
        ifTrue: [self genValue: n value in: lex. self genStore: n name in: lex pop: true]
        ifFalse: [self genValue: n in: lex. self emit: lex real op: 6] ]
Compiler >> genValue: n in: lex [
    "Pass 2: the code that pushes node n's value. Literals, variables,
     assignments, brace arrays (pushArray, 30), cascades (dup 5 and pop 6
     around each message but the last), blocks, sends compiled in line and
     real sends. Signals a CompileError for a ^ inside an expression and for a
     brace array over 255 elements."
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
    "Pass 2: pushes literal v: pushNil, pushTrue or pushFalse (1 2 3),
     pushInt8 (26) for -128 to 127, otherwise pushLit (18) of its index."
    v == nil ifTrue: [^self emit: sc op: 1].
    v == true ifTrue: [^self emit: sc op: 2].
    v == false ifTrue: [^self emit: sc op: 3].
    (v isInteger and: [v between: -128 and: 127]) ifTrue: [^self emit: sc op: 26 with: (v bitAnd: 255)].
    self emit: sc op: 18 with: (sc lit: (self literal: v)) ]
Compiler >> literal: v [
    "The literal to store for v: a copy made immutable for a String that is
     not a Symbol, so that literal strings cannot be changed; v itself
     otherwise."
    (v isString and: [v isSymbol not]) ifTrue: [^v copy beImmutable].
    ^v ]
Compiler >> specialIndexOf: sel nargs: n [
    "The index k (0-based) of sel among the special selectors of sendSpecial,
     or nil if it is not one or does not take n arguments.
     (Compiler new specialIndexOf: '+' nargs: 1) >>> 0"
    | i |
    i := #(#+ #- #< #> #<= #>= #= #~= #* #/ #\\ #// #bitAnd: #bitOr: #bitShift: #== #class #at: #at:put:
           #size #value #value: #isNil #notNil #new #new: #~~) indexOf: sel asSymbol.
    i = 0 ifTrue: [^nil].
    sel asSymbol numArgs = n ifFalse: [^nil].
    ^i - 1 ]
Compiler >> genSend: sel nargs: n in: sc super: sup [
    "Pass 2: emits a send of sel with n arguments: superSend (33) for super,
     sendSpecial (34) for a special selector, send (32) otherwise, with the
     selector's literal index and n."
    | k |
    sup ifTrue: [^self emit: sc op: 33 with: (sc lit: sel asSymbol) with: n].
    k := self specialIndexOf: sel nargs: n.
    k == nil ifFalse: [^self emit: sc op: 34 with: k].
    self emit: sc op: 32 with: (sc lit: sel asSymbol) with: n ]
Compiler >> genLoadName: name line: line in: lex [
    "Pass 2: pushes the variable named name: a pseudo-variable, a temp or
     argument (genLoadVar:in:), an instance variable (pushInst, 16), or a
     global's association (pushLitVar, 19). Signals a CompileError for
     thisContext."
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
    "The association of the global named name in Smalltalk; a global not
     defined yet is declared with nil."
    | sym |
    sym := name asSymbol.
    ^Smalltalk associationAt: sym ifAbsent: [
        Smalltalk at: sym put: nil.
        Smalltalk associationAt: sym ifAbsent: [nil]] ]
Compiler >> genLoadVar: v in: sc [
    "Pass 2: pushes variable v in scope sc: pushTemp (17), or pushTempInVector
     (27) for a remote one; from an outer scope through a copied value,
     captured in sc as needed."
    v scope == sc ifTrue: [
        ^v remote
            ifTrue: [self emit: sc op: 27 with: v vidx with: sc vector]
            ifFalse: [self emit: sc op: 17 with: v]].
    v remote ifTrue: [^self emit: sc op: 27 with: v vidx with: (sc capture: v scope vector)].
    self emit: sc op: 17 with: (sc capture: v) ]
Compiler >> genStore: name in: lex pop: pop [
    "Pass 2: stores the top into the variable named name: a temp
     (genStoreVar:in:pop:), an instance variable (storeInst 20, popStoreInst
     23) or a global (storeLitVar 22, popStoreLitVar 25); popping it if pop."
    | sc v |
    sc := lex real.
    v := lex lookup: name.
    v == nil ifFalse: [^self genStoreVar: v in: sc pop: pop].
    (ivars includes: name) ifTrue: [^self emit: sc op: (pop ifTrue: [23] ifFalse: [20]) with: (ivars indexOf: name) - 1].
    self emit: sc op: (pop ifTrue: [25] ifFalse: [22]) with: (sc lit: (self globalNamed: name)) ]
Compiler >> genStoreVar: v in: sc pop: pop [
    "Pass 2: stores the top into variable v in scope sc: storeTemp or
     popStoreTemp (21 24), or for a remote variable storeTempInVector or
     popStoreTempInVector (28 29). Signals a CompileError (internal) for a
     store into a copied variable, which settle rules out."
    v scope == sc ifTrue: [
        ^v remote
            ifTrue: [self emit: sc op: (pop ifTrue: [29] ifFalse: [28]) with: v vidx with: sc vector]
            ifFalse: [self emit: sc op: (pop ifTrue: [24] ifFalse: [21]) with: v]].
    v remote ifTrue: [^self emit: sc op: (pop ifTrue: [29] ifFalse: [28]) with: v vidx with: (sc capture: v scope vector)].
    ^self error: 'internal: a store into a copied variable' ]
Compiler >> genBlock: b in: lex [
    "Pass 2 for a real block: compiles it into its own CompiledBlock (the last
     statement's value returned with blockReturn, 9; an empty block answers
     nil), then in the outer scope pushes its copied values and emits
     pushClosure (31) with the block's literal index and their count."
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
    "Pass 2: the code of an in-line block's statements, leaving its value
     pushed (nil for an empty block)."
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
    "Pass 2: the code of an in-line block's statements, leaving nothing
     pushed."
    | inner sc |
    inner := analysis at: b.
    sc := lex real.
    b statements do: [:st |
        st isReturn
            ifTrue: [self genValue: st expr in: inner. self emit: sc op: 7]
            ifFalse: [self genEffect: st in: inner]] ]
Compiler >> inlinedArg: b [
    "The variable of an in-line block's first argument (a loop variable or the
     ifNotNil: value)."
    ^(analysis at: b) names at: b arguments first ]
Compiler >> genInline: n in: lex [
    "Pass 2 for a send compiled in line (ifTrue: and the like, and: or:, the
     while loops, repeat, to:do:, ifNil: and the like): jumps (35 36 37) and
     labels in place of the send, the loops and to:do: answering nil; to:do:
     compares with <= (or >= for a negative step) and adds the step with
     sendSpecial. Signals a CompileError (internal) for another selector."
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
    "Pass 2: for an in-line ifNotNil: block, stores the receiver's value (on
     the stack) into the block's argument, or pops it if the block takes none."
    b arguments isEmpty
        ifTrue: [self emit: sc op: 6]
        ifFalse: [self genStoreVar: (self inlinedArg: b) in: sc pop: true] ]

"assembly"
Compiler >> opLength: op [
    "The length in bytes of bytecode op with its operands: 1 below 16, 3 for
     27 28 29 31 32 33 35 36 37, 2 for the rest.
     (Compiler new opLength: 32) >>> 3"
    op < 16 ifTrue: [^1].
    (#(27 28 29 31 32 33 35 36 37) includes: op) ifTrue: [^3].
    ^2 ]
Compiler >> stackEffect: ins [
    "How much instruction ins changes the operand stack's depth: +1 for a
     push, -1 for a pop, a store-and-pop or a conditional jump, and for
     arrays, closures and sends what they take and push."
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
    "Assembly: turns scope sc's instructions into bytes (temps numbered args,
     copied, locals then the vector; labels resolved to 16-bit jump offsets),
     works out the maximum stack depth, and answers a new CompiledMethod or
     CompiledBlock with its header (nargs, temps, literals, primitive, copied,
     the block bit, the depth), literals and bytes. Signals a CompileError for
     over 255 temps, a jump too long or a stack over 255 deep."
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
    nlits > 255 ifTrue: [^CompileError new signal: 'too many literals'].
    header := nargs + (ntemps bitShift: 8) + (nlits bitShift: 16) + (prim bitShift: 24)
        + (sc copied size bitShift: 36) + ((isBlock ifTrue: [1] ifFalse: [0]) bitShift: 44) + (maxd bitShift: 45).
    bytes := bytes contents.
    m := (isBlock ifTrue: [CompiledBlock] ifFalse: [CompiledMethod]) header: header numBytes: bytes size.
    sc lits doWithIndex: [:l :i | m literalAt: i put: l].
    1 to: bytes size do: [:i | m byteAt: i put: (bytes at: i)].
    "A method runs from a copy in the method cache, which the scavenger does
     not see: its literals must be far before it runs (a scavenge moves the
     near ones out, and the method's slots with them)."
    (sc lits anySatisfy: [:l | l isNear]) ifTrue: [Smalltalk scavenge].
    ^m ]
