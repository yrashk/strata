"UI.st: the graphical tools, in windows of the window server: a
 Workspace, a ClassBrowser and an Inspector. The server draws text in
 cells of 8 x 16; a pane is a rectangle of cells. Keys come as a terminal
 sends them (arrows: ESC [ A ...); the pointer selects.

   Workspace open        ClassBrowser open        anObject inspect
   stratalk -w           stratalk -b              (from a terminal of ws)"

Object subclass: #UIApp slots: 'window panes focus done status'.
Object subclass: #Pane slots: 'app x y w h title'.
Pane subclass: #ListPane slots: 'items selection top onSelect'.
Pane subclass: #TextPane slots: 'lines row col top editable'.
UIApp subclass: #Workspace slots: 'text last'.
UIApp subclass: #ClassBrowser slots: 'classes selectors source meta sources'.
UIApp subclass: #Inspector slots: 'object stack list detail'.

"---- colours ------------------------------------------------------------------"

UIApp class >> background [ ^Window rgb: 11 g: 16 b: 32 ]
UIApp class >> foreground [ ^Window rgb: 216 g: 222 b: 233 ]
UIApp class >> accent [ ^Window rgb: 136 g: 192 b: 208 ]
UIApp class >> selection [ ^Window rgb: 46 g: 52 b: 64 ]
UIApp class >> dim [ ^Window rgb: 110 g: 120 b: 140 ]
UIApp class >> error [ ^Window rgb: 235 g: 110 b: 100 ]

"---- the application: a window, panes, the event loop -------------------------"

UIApp class >> open [
    | w |
    w := Window open: self title.
    ^[self new openIn: w] ensure: [w close] ]
UIApp class >> title [ ^'stratalk' ]
UIApp >> openIn: aWindow [
    window := aWindow.
    panes := OrderedCollection new.
    status := ''.
    done := false.
    self layout.
    focus := panes first.
    self drawAll.
    self loop.
    ^self ]
UIApp >> window [ ^window ]
UIApp >> columns [ ^window columns ]
UIApp >> rows [ ^window rows ]
UIApp >> layout [ ^self subclassResponsibility ]
UIApp >> add: aPane [ panes add: aPane. ^aPane ]
UIApp >> loop [
    | e |
    [done] whileFalse: [
        e := window nextEvent.
        e == nil ifFalse: [
            e isClose ifTrue: [done := true].
            e isResize ifTrue: [panes := OrderedCollection new. self layout. focus := panes first. self drawAll].
            e isKey ifTrue: [self keys: e keys].
            (e isPointer and: [e buttons ~= 0]) ifTrue: [self click: e x // Window cellWidth row: e y // Window cellHeight]]] ]
UIApp >> keys: aString [
    | s c |
    s := ReadStream on: aString.
    [s atEnd] whileFalse: [
        c := s next.
        c value = 27
            ifTrue: [self escape: s]
            ifFalse: [self key: c]] ]
UIApp >> escape: s [
    "ESC [ X, ESC [ n ~, or ESC alone"
    | c n |
    s atEnd ifTrue: [^self key: (Character value: 27)].
    s peek = $[ ifFalse: [^self key: (Character value: 27)].
    s next.
    c := s next.
    c isDigit ifTrue: [n := c digitValue. [s atEnd not and: [s peek isDigit]] whileTrue: [n := n * 10 + s next digitValue]. s next.
        ^self special: (#(#home #insert #delete #end #pageUp #pageDown) at: n ifAbsent: [#none])].
    self special: (c = $A ifTrue: [#up] ifFalse: [c = $B ifTrue: [#down] ifFalse: [c = $C ifTrue: [#right] ifFalse: [
        c = $D ifTrue: [#left] ifFalse: [c = $H ifTrue: [#home] ifFalse: [c = $F ifTrue: [#end] ifFalse: [#none]]]]]]) ]
UIApp >> key: c [
    c value = 9 ifTrue: [^self nextPane].
    c value = 17 ifTrue: [^done := true].
    (c value = 27 and: [self quitsOnEscape]) ifTrue: [^done := true].
    (self command: c) ifTrue: [^self].
    focus key: c ]
UIApp >> quitsOnEscape [ ^true ]
UIApp >> command: c [ "true if the app took the key" ^false ]
UIApp >> special: aSymbol [ focus special: aSymbol ]
UIApp >> nextPane [
    | i |
    i := panes indexOf: focus.
    focus := panes at: i \\ panes size + 1.
    self drawAll ]
UIApp >> click: col row: r [
    panes do: [:p | (p contains: col row: r) ifTrue: [
        focus := p.
        p click: col row: r.
        ^self drawAll]] ]
UIApp >> status: aString [ status := aString. self drawStatus ]
UIApp >> drawAll [
    window clear: UIApp background.
    panes do: [:p | p draw].
    self drawStatus ]
UIApp >> drawStatus [
    | s |
    s := status , (String new: (self columns - status size max: 0) withAll: $ ).
    window text: (s copyFrom: 1 to: (s size min: self columns)) column: 0 row: self rows - 1
        color: UIApp background background: UIApp accent ]
UIApp >> hasFocus: aPane [ ^focus == aPane ]

"---- panes ---------------------------------------------------------------------------"

Pane >> app: anApp x: ax y: ay w: aw h: ah title: aString [ app := anApp. x := ax. y := ay. w := aw. h := ah. title := aString ]
Pane >> contains: col row: r [ ^(col between: x and: x + w - 1) and: [r between: y and: y + h - 1] ]
Pane >> line: aString at: r color: fg background: bg [
    "Row r of the pane (0: the title line), padded to its width."
    | s |
    s := aString size >= w ifTrue: [aString copyFrom: 1 to: w] ifFalse: [aString , (String new: w - aString size withAll: $ )].
    app window text: s column: x row: y + r color: fg background: bg ]
Pane >> draw [
    self line: ' ' , title at: 0 color: ((app hasFocus: self) ifTrue: [UIApp accent] ifFalse: [UIApp dim]) background: UIApp selection.
    self drawBody ]
Pane >> drawBody [ ^self ]
Pane >> key: c [ ^self ]
Pane >> special: aSymbol [ ^self ]
Pane >> click: col row: r [ ^self ]
Pane >> bodyRows [ ^h - 1 ]

ListPane >> items: aCollection [ items := aCollection asOrderedCollection. selection := 0. top := 0 ]
ListPane >> items [ ^items ]
ListPane >> onSelect: aBlock [ onSelect := aBlock ]
ListPane >> selection [ ^selection ]
ListPane >> selected [ ^(selection between: 1 and: items size) ifTrue: [items at: selection] ifFalse: [nil] ]
ListPane >> select: i [
    (i between: 1 and: items size) ifFalse: [^self].
    selection := i.
    selection <= top ifTrue: [top := selection - 1].
    selection > (top + self bodyRows) ifTrue: [top := selection - self bodyRows].
    onSelect == nil ifFalse: [onSelect value: self selected].
    app drawAll ]
ListPane >> drawBody [
    | i item |
    1 to: self bodyRows do: [:r |
        i := top + r.
        item := i <= items size ifTrue: [' ' , (items at: i) displayString] ifFalse: [''].
        i = selection
            ifTrue: [self line: item at: r color: UIApp background background: UIApp foreground]
            ifFalse: [self line: item at: r color: UIApp foreground background: UIApp background]] ]
ListPane >> special: aSymbol [
    aSymbol == #up ifTrue: [^self select: (selection - 1 max: 1)].
    aSymbol == #down ifTrue: [^self select: (selection + 1 min: items size)].
    aSymbol == #pageUp ifTrue: [^self select: (selection - self bodyRows max: 1)].
    aSymbol == #pageDown ifTrue: [^self select: (selection + self bodyRows min: items size)].
    aSymbol == #home ifTrue: [^self select: 1].
    aSymbol == #end ifTrue: [^self select: items size] ]
ListPane >> key: c [
    "A letter: the next item that begins with it."
    | n i |
    c isLetter ifFalse: [^self].
    n := items size.
    1 to: n do: [:k |
        i := (selection + k - 1) \\ n + 1.
        ((items at: i) displayString asLowercase beginsWith: (String with: c asLowercase)) ifTrue: [^self select: i]] ]
ListPane >> click: col row: r [ r > y ifTrue: [self select: top + r - y] ]

TextPane >> setText: aString [
    lines := (aString lines collect: [:l | l]) asOrderedCollection.
    lines isEmpty ifTrue: [lines add: ''].
    row := 1. col := 0. top := 0 ]
TextPane >> text [
    | s |
    s := WriteStream on: (String new: 256).
    lines do: [:l | s nextPutAll: l] separatedBy: [s nextPut: Character cr].
    ^s contents ]
TextPane >> editable: aBoolean [ editable := aBoolean ]
TextPane >> lines [ ^lines ]
TextPane >> row [ ^row ]
TextPane >> currentLine [ ^lines at: row ]
TextPane >> insertLine: aString after: r [ lines add: aString beforeIndex: r + 1 ]
TextPane >> moveTo: r column: c [
    row := (r max: 1) min: lines size.
    col := (c max: 0) min: (lines at: row) size.
    row <= top ifTrue: [top := row - 1].
    row > (top + self bodyRows) ifTrue: [top := row - self bodyRows] ]
TextPane >> drawBody [
    | i l |
    1 to: self bodyRows do: [:r |
        i := top + r.
        l := i <= lines size ifTrue: [lines at: i] ifFalse: [''].
        self line: l at: r color: UIApp foreground background: UIApp background].
    ((app hasFocus: self) and: [editable == true]) ifTrue: [
        | ch | ch := col < (lines at: row) size ifTrue: [String with: ((lines at: row) at: col + 1)] ifFalse: [' '].
        app window text: ch column: x + col row: y + row - top color: UIApp background background: UIApp accent] ]
TextPane >> redrawRow [
    | l |
    l := lines at: row.
    self line: l at: row - top color: UIApp foreground background: UIApp background.
    ((app hasFocus: self) and: [editable == true]) ifTrue: [
        | ch | ch := col < l size ifTrue: [String with: (l at: col + 1)] ifFalse: [' '].
        app window text: ch column: x + col row: y + row - top color: UIApp background background: UIApp accent] ]
TextPane >> key: c [
    | l oldTop |
    editable == true ifFalse: [^self].
    l := lines at: row.
    oldTop := top.
    (c value = 13 or: [c value = 10]) ifTrue: [
        lines at: row put: (l copyFrom: 1 to: col).
        self insertLine: (l copyFrom: col + 1 to: l size) after: row.
        self moveTo: row + 1 column: 0.
        ^self drawBody].
    (c value = 127 or: [c value = 8]) ifTrue: [
        col > 0 ifTrue: [
            lines at: row put: (l copyFrom: 1 to: col - 1) , (l copyFrom: col + 1 to: l size).
            col := col - 1.
            ^self redrawRow].
        row > 1 ifTrue: [
            | prev | prev := lines at: row - 1.
            lines at: row - 1 put: prev , l.
            lines removeIndex: row.
            self moveTo: row - 1 column: prev size.
            ^self drawBody].
        ^self].
    c value >= 32 ifTrue: [
        lines at: row put: (l copyFrom: 1 to: col) , (String with: c) , (l copyFrom: col + 1 to: l size).
        col := col + 1.
        ^self redrawRow] ]
TextPane >> special: aSymbol [
    aSymbol == #up ifTrue: [self moveTo: row - 1 column: col].
    aSymbol == #down ifTrue: [self moveTo: row + 1 column: col].
    aSymbol == #left ifTrue: [col > 0 ifTrue: [col := col - 1] ifFalse: [self moveTo: row - 1 column: 9999]].
    aSymbol == #right ifTrue: [col < (lines at: row) size ifTrue: [col := col + 1] ifFalse: [self moveTo: row + 1 column: 0]].
    aSymbol == #home ifTrue: [col := 0].
    aSymbol == #end ifTrue: [col := (lines at: row) size].
    aSymbol == #pageUp ifTrue: [self moveTo: row - self bodyRows column: col].
    aSymbol == #pageDown ifTrue: [self moveTo: row + self bodyRows column: col].
    self drawBody ]
TextPane >> click: col0 row: r [ r > y ifTrue: [self moveTo: top + r - y column: col0 - x] ]

"---- Workspace: lines of code; Ctrl-P prints, Ctrl-D does, Ctrl-O inspects ----"

Workspace class >> title [ ^'workspc' ]
Workspace >> layout [
    text := self add: (TextPane new app: self x: 0 y: 0 w: self columns h: self rows - 1
        title: 'Workspace   Ctrl-P print it  Ctrl-D do it  Ctrl-O inspect it  Ctrl-B browse  Ctrl-Q quit').
    text editable: true.
    text setText: '3 + 4' , (String with: Character cr) , '100 factorial' , (String with: Character cr) ,
        '(1 to: 10) collect: [:i | i * i]' , (String with: Character cr) , 'Proc ps'.
    self status: 'Stratalk ' , Smalltalk version ]
Workspace >> quitsOnEscape [ ^false ]
Workspace >> relayout [ "back from a tool shown in this window" done := false. self drawAll ]
Workspace >> command: c [
    c value = 16 ifTrue: [self evaluate: true. ^true].
    c value = 4 ifTrue: [self evaluate: false. ^true].
    c value = 15 ifTrue: [self evaluate: false. (Inspector on: last) openOn: last in: window. self relayout. ^true].
    c value = 2 ifTrue: [ClassBrowser new openIn: window. self relayout. ^true].
    ^false ]
Workspace >> evaluate: print [
    | code r |
    code := text currentLine.
    (code includesSubstring: ' -> ') ifTrue: [code := code copyFrom: 1 to: (code indexOfSubCollection: ' -> ') - 1].
    r := [Compiler evaluate: code] on: Error do: [:e | self status: 'Error: ' , e messageText. ^self].
    last := r.
    print ifTrue: [
        text insertLine: '  -> ' , r printString after: text row.
        text moveTo: text row + 1 column: 0.
        text drawBody].
    self status: 'ok' ]

"---- ClassBrowser: classes, their selectors, a method's source ----------------"

ClassBrowser class >> title [ ^'browser' ]
ClassBrowser class >> openIn: aWindow [ ^self new openIn: aWindow ]
ClassBrowser >> layout [
    | half third |
    half := self rows - 1 // 2.
    third := self columns // 3.
    meta == nil ifTrue: [meta := false].
    classes := self add: (ListPane new app: self x: 0 y: 0 w: third h: half title: 'Classes').
    selectors := self add: (ListPane new app: self x: third y: 0 w: self columns - third h: half title: 'Selectors   t: class side').
    source := self add: (TextPane new app: self x: 0 y: half w: self columns h: self rows - 1 - half
        title: 'Source   Ctrl-S accept   Tab: next pane   Esc, Ctrl-Q: close').
    source editable: true.
    source setText: ''.
    classes items: (Smalltalk allClasses collect: [:c | c name asString]).
    classes onSelect: [:n | self showClass].
    selectors items: #().
    selectors onSelect: [:s | self showMethod].
    self status: Smalltalk allClasses size printString , ' classes' ]
ClassBrowser >> quitsOnEscape [ ^focus ~~ source ]
ClassBrowser >> currentClass [
    | c |
    classes selected == nil ifTrue: [^nil].
    c := Smalltalk at: classes selected asSymbol ifAbsent: [^nil].
    ^meta ifTrue: [c class] ifFalse: [c] ]
ClassBrowser >> command: c [
    (c = $t and: [focus ~~ source]) ifTrue: [meta := meta not. self showClass. ^true].
    c value = 19 ifTrue: [self accept. ^true].
    ^false ]
ClassBrowser >> showClass [
    | c |
    c := self currentClass.
    c == nil ifTrue: [^self].
    selectors items: (c selectors collect: [:s | s asString]) asArray.
    source setText: (self definitionOf: c).
    self status: c name , '   ' , c instSize printString , ' slots, ' , c selectors size printString , ' methods' ]
ClassBrowser >> definitionOf: c [
    | s |
    s := WriteStream on: (String new: 128).
    c isClass & (c theNonMetaClass == c) ifTrue: [
        s nextPutAll: (c superclass == nil ifTrue: ['nil'] ifFalse: [c superclass name]);
          nextPutAll: ' subclass: #'; nextPutAll: c name; nextPutAll: ' slots: '''.
        c instVarNames do: [:n | s nextPutAll: n] separatedBy: [s space].
        s nextPutAll: ''''].
    ^s contents ]
ClassBrowser >> showMethod [
    | c sel |
    c := self currentClass. sel := selectors selected.
    (c == nil or: [sel == nil]) ifTrue: [^self].
    source setText: (self sourceOf: sel asSymbol in: c).
    self status: c name , '>>' , sel ]
ClassBrowser >> sourceOf: sel in: c [
    ^MethodSource sourceOf: sel in: c ifAbsent: [
        '"no source: compiled from somewhere else"' , (String with: Character cr) , sel ] ]
ClassBrowser >> accept [
    | c m |
    c := self currentClass.
    c == nil ifTrue: [^self status: 'no class'].
    m := [c compile: source text] on: Error do: [:e | ^self status: 'Error: ' , e messageText].
    self status: 'accepted: ' , m printString.
    selectors items: (c selectors collect: [:s | s asString]) asArray ]

"---- Inspector: an object's slots; Enter goes into one, Backspace back ----"

Inspector class >> title [ ^'inspect' ]
Inspector class >> on: anObject [ ^self new setObject: anObject ]
Inspector >> setObject: anObject [ object := anObject. stack := OrderedCollection new ]
Inspector >> openOn: anObject [
    | w |
    object := anObject. stack := OrderedCollection new.
    w := Window open: 'inspect'.
    ^[self openIn: w] ensure: [w close] ]
Inspector >> openOn: anObject in: aWindow [ object := anObject. stack := OrderedCollection new. ^self openIn: aWindow ]
Inspector >> layout [
    list := self add: (ListPane new app: self x: 0 y: 0 w: self columns h: self rows - 4 title: 'Inspector   Enter: into   Backspace: back   Esc: close').
    detail := self add: (TextPane new app: self x: 0 y: self rows - 4 w: self columns h: 3 title: 'Value').
    detail editable: false.
    detail setText: ''.
    list onSelect: [:item | self showSlot].
    self refresh ]
Inspector >> slots [
    "{name. value} pairs: the object, its named slots, its first indexed ones"
    | out names |
    out := OrderedCollection new.
    out add: (Array with: 'self' with: object).
    out add: (Array with: 'class' with: object class).
    names := object class allInstVarNames.
    names doWithIndex: [:n :i | out add: (Array with: n with: (object instVarAt: i))].
    1 to: (object basicSize min: 200) do: [:i | out add: (Array with: '[' , i printString , ']' with: (object basicAt: i))].
    ^out ]
Inspector >> refresh [
    | s |
    s := self slots.
    list items: (s collect: [:p | (p at: 1) , ': ' , ([(p at: 2) printString] on: Error do: [:e | '?'])]).
    self status: object class name , ' (' , (object isNear ifTrue: ['near'] ifFalse: ['far']) , ')' , (stack isEmpty ifTrue: [''] ifFalse: ['   depth ' , stack size printString]) ]
Inspector >> showSlot [
    | p |
    p := self slots at: list selection ifAbsent: [^self].
    detail setText: ([(p at: 2) printString] on: Error do: [:e | '?']).
    detail drawBody ]
Inspector >> key: c [
    (c value = 13 or: [c value = 10]) ifTrue: [^self dive].
    (c value = 127 or: [c value = 8]) ifTrue: [^self back].
    super key: c ]
Inspector >> dive [
    | p |
    p := self slots at: list selection ifAbsent: [^self].
    stack add: object.
    object := p at: 2.
    self refresh. self drawAll ]
Inspector >> back [
    stack isEmpty ifTrue: [^self].
    object := stack removeLast.
    self refresh. self drawAll ]

Object >> inspect [ ^(Inspector on: self) openOn: self ]
SystemDictionary >> browse [ ^ClassBrowser open ]

"---- method sources: the kernel's files on the disk, and what was compiled here ----"

Object subclass: #MethodSource slots: ''.
MethodSource class slots: 'files compiled'.
MethodSource class >> note: aString class: aClass selector: aSymbol [
    "What compile: and fileIn compiled, kept for the browser."
    compiled == nil ifTrue: [compiled := Dictionary new].
    compiled at: aClass name , '>>' , aSymbol put: aString ]
MethodSource class >> sourceOf: sel in: aClass ifAbsent: aBlock [
    | key |
    key := aClass name , '>>' , sel.
    compiled == nil ifFalse: [(compiled at: key ifAbsent: [nil]) ifNotNil: [:s | ^s]].
    ^self fromFiles: sel in: aClass ifAbsent: aBlock ]
MethodSource class >> fromFiles: sel in: aClass ifAbsent: aBlock [
    "The kernel's file that defines it: the line beginning 'Class >> ' with this
     selector, and the indented lines after it."
    | prefix |
    prefix := aClass name , ' >> '.
    self files do: [:text | | lines i |
        lines := text lines.
        i := 1.
        [i <= lines size] whileTrue: [ | l |
            l := lines at: i.
            ((l beginsWith: prefix) and: [(self selectorOf: (l copyFrom: prefix size + 1 to: l size)) = sel asString])
                ifTrue: [ | out j |
                    out := WriteStream on: (String new: 256).
                    out nextPutAll: (l copyFrom: prefix size + 1 to: l size).
                    j := i + 1.
                    [j <= lines size and: [(lines at: j) notEmpty and: [(lines at: j) first isSeparator]]] whileTrue: [
                        out nextPut: Character cr; nextPutAll: (lines at: j). j := j + 1].
                    ^out contents].
            i := i + 1]].
    ^aBlock value ]
MethodSource class >> selectorOf: aPattern [
    "The selector a method's pattern text gives: 'at: i put: v [ ...' -> 'at:put:'"
    | toks sel |
    toks := (aPattern copyFrom: 1 to: ((aPattern indexOf: $[) - 1 max: 0)) substrings.
    toks isEmpty ifTrue: [^''].
    (toks first last = $:) ifFalse: [^toks first].
    sel := WriteStream on: (String new: 32).
    toks do: [:t | t last = $: ifTrue: [sel nextPutAll: t]].
    ^sel contents ]
MethodSource class >> files [
    "The kernel's sources, read from /stratalk/ once."
    files == nil ifTrue: [
        files := (Smalltalk at: #SourceFiles ifAbsent: [#()]) collect: [:n |
            [(File named: '/stratalk/' , n) contents] on: Error do: [:e | '']]].
    ^files ]
