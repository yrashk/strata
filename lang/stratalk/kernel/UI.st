"UI.st: the graphical tools, in windows of the window server: a
 Workspace, a ClassBrowser and an Inspector. The server draws text in
 cells of 8 x 16; a pane is a rectangle of cells. Keys come as a terminal
 sends them (arrows: ESC [ A ...); the pointer selects.

   Workspace open        ClassBrowser open        anObject inspect
   stratalk -w           stratalk -b              (from a terminal of ws)"

Object subclass: #UIApp slots: 'window panes focus done status'.
"A tool in a Window of ws: panes of character cells, the one with the
 focus taking the keys, a status line at the bottom, and an event loop.
 window is the Window, panes the Panes in Tab order, focus the pane with
 the focus, done true once the loop should end, status the status line's
 text. A subclass lays its panes out (layout) and may take keys first
 (command:). Keys every tool shares: Tab the next pane, Ctrl-Q quit, Esc
 quit (where quitsOnEscape); a click focuses the pane under the pointer.
 UIApp open opens one in a window of its own."

Object subclass: #Pane slots: 'app x y w h title'.
"A rectangle of character cells in a UIApp's window: its top row is the
 title line, the rows under it the body. app is the UIApp, x and y the
 top left cell, w and h the size in cells, title the title's text. Pane
 itself draws only the title; ListPane and TextPane draw a body and take
 keys and clicks."

Pane subclass: #ListPane slots: 'items selection top onSelect'.
"A Pane that lists items (anything, shown by displayString), one a row,
 with one selected. items is an OrderedCollection, selection the selected
 index (0: none), top the number of items scrolled off above, onSelect a
 one-argument block run with the item each time one is selected. Keys:
 the arrows, Page Up and Down, Home and End move the selection, a letter
 selects the next item that begins with it; a click selects."

Pane subclass: #TextPane slots: 'lines row col top editable'.
"A Pane that shows text, and edits it when editable. lines is an
 OrderedCollection of Strings, row the cursor's line (from 1), col its
 column (from 0), top the number of lines scrolled off above, editable
 true to take keys (printable characters, Return, Backspace). The arrows,
 Home, End and Page Up and Down move the cursor; a click puts it there."

UIApp subclass: #Workspace slots: 'text last'.
"A UIApp of one editable TextPane of code. The cursor's line is the code:
 Ctrl-P evaluates it and prints the result under it ('  -> ' and the
 printString), Ctrl-D evaluates it, Ctrl-O evaluates it and inspects the
 result, Ctrl-B opens a ClassBrowser in the same window, Ctrl-Q quits.
 Esc does not quit it. text is the TextPane, last the last value
 evaluated. Workspace open, or stratalk -w."

UIApp subclass: #ClassBrowser slots: 'classes selectors source meta sources'.
"A UIApp of three panes: the classes (a ListPane), the selected class's
 selectors (a ListPane) and a source pane (an editable TextPane) that
 shows the class's definition or the selected method's source, from
 MethodSource. t toggles the class side (meta) when the source pane does
 not have the focus; Ctrl-S compiles the source pane's text into the
 class; Esc and Ctrl-Q close it. sources is not used. ClassBrowser open,
 Smalltalk browse, or stratalk -b."

UIApp subclass: #Inspector slots: 'object stack list detail'.
"A UIApp that shows an object's slots: a ListPane of name: value lines
 (self, class, the named slots, up to 200 indexed ones) and a TextPane
 with the selected value's printString. Return goes into the selected
 value, Backspace back out; Esc closes. object is the object shown, stack
 the objects gone into from, list and detail the two panes. anObject
 inspect, or Ctrl-O in a Workspace."

"---- colours ------------------------------------------------------------------"

UIApp class >> background [
    "The tools' background colour, an XRGB word (dark blue).
     UIApp background >>> 725024"
    ^Window rgb: 11 g: 16 b: 32 ]
UIApp class >> foreground [
    "The tools' text colour, an XRGB word (light grey).
     UIApp foreground >>> 14212841"
    ^Window rgb: 216 g: 222 b: 233 ]
UIApp class >> accent [
    "The colour of the focused pane's title, the status line and the
     cursor, an XRGB word (light blue).
     UIApp accent >>> 8962256"
    ^Window rgb: 136 g: 192 b: 208 ]
UIApp class >> selection [
    "The colour of a pane's title line, an XRGB word (dark grey).
     UIApp selection >>> 3028032"
    ^Window rgb: 46 g: 52 b: 64 ]
UIApp class >> dim [
    "The colour of an unfocused pane's title, an XRGB word (grey).
     UIApp dim >>> 7239820"
    ^Window rgb: 110 g: 120 b: 140 ]
UIApp class >> error [
    "The colour for errors, an XRGB word (red).
     UIApp error >>> 15429220"
    ^Window rgb: 235 g: 110 b: 100 ]

"---- the application: a window, panes, the event loop -------------------------"

UIApp class >> open [
    "Opens a Window of ws titled by the class's title, runs a new tool in
     it until it quits, and closes the window (also on an error). Answers
     the tool."
    | w |
    w := Window open: self title.
    ^[self new openIn: w] ensure: [w close] ]
UIApp class >> title [
    "The title of the tool's window (8 characters are shown).
     UIApp title >>> 'stratalk'"
    ^'stratalk' ]
UIApp >> openIn: aWindow [
    "Runs the tool in aWindow, already open: lays the panes out, gives the
     first the focus, draws, and runs the event loop until done. Answers
     the receiver; the window stays open."
    window := aWindow.
    panes := OrderedCollection new.
    status := ''.
    done := false.
    self layout.
    focus := panes first.
    self drawAll.
    self loop.
    ^self ]
UIApp >> window [
    "The Window the tool is in."
    ^window ]
UIApp >> columns [
    "The window's width in character cells."
    ^window columns ]
UIApp >> rows [
    "The window's height in character cells."
    ^window rows ]
UIApp >> layout [
    "Makes the panes, adding each with add:, for the window's size now;
     the first added gets the focus. A subclass's responsibility."
    ^self subclassResponsibility ]
UIApp >> add: aPane [
    "Adds aPane after the others (in Tab order) and answers it."
    panes add: aPane. ^aPane ]
UIApp >> loop [
    "The event loop: waits for the window's events (ws EVENT) until done.
     A close ends it; a resize lays the panes out again and redraws; keys
     go to keys:; a pointer event with a button held to click:row:, in
     cells."
    | e |
    [done] whileFalse: [
        e := window nextEvent.
        e == nil ifFalse: [
            e isClose ifTrue: [done := true].
            e isResize ifTrue: [panes := OrderedCollection new. self layout. focus := panes first. self drawAll].
            e isKey ifTrue: [self keys: e keys].
            (e isPointer and: [e buttons ~= 0]) ifTrue: [self click: e x // Window cellWidth row: e y // Window cellHeight]]] ]
UIApp >> keys: aString [
    "Handles the bytes of a key event, as a terminal sends them: an escape
     sequence goes to escape:, any other character to key:."
    | s c |
    s := ReadStream on: aString.
    [s atEnd] whileFalse: [
        c := s next.
        c value = 27
            ifTrue: [self escape: s]
            ifFalse: [self key: c]] ]
UIApp >> escape: s [
    "Reads the rest of an escape sequence from the stream s, after its ESC,
     and hands it on: ESC [ A, B, C, D, H, F (the arrows, Home, End) and
     ESC [ n ~ (Home, Insert, Delete, End, Page Up, Page Down) to special:
     as a Symbol (#up, #pageDown, ...; #none for another); ESC alone to
     key:."
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
    "Handles the character c: Tab moves the focus to the next pane, Ctrl-Q
     quits, Esc quits where quitsOnEscape; otherwise command: may take it,
     and if it does not the focused pane gets it."
    c value = 9 ifTrue: [^self nextPane].
    c value = 17 ifTrue: [^done := true].
    (c value = 27 and: [self quitsOnEscape]) ifTrue: [^done := true].
    (self command: c) ifTrue: [^self].
    focus key: c ]
UIApp >> quitsOnEscape [
    "Answers whether Esc quits the tool: true here."
    ^true ]
UIApp >> command: c [
    "Answers whether the tool took the character c as a command of its
     own; none here, false."
    ^false ]
UIApp >> special: aSymbol [
    "Hands a special key (#up, #down, #left, #right, #home, #end, #pageUp,
     #pageDown, ...) to the focused pane."
    focus special: aSymbol ]
UIApp >> nextPane [
    "Gives the focus to the next pane, after the last the first, and
     redraws."
    | i |
    i := panes indexOf: focus.
    focus := panes at: i \\ panes size + 1.
    self drawAll ]
UIApp >> click: col row: r [
    "Handles a click at cell (col, r): the pane that contains it gets the
     focus and the click, and everything is redrawn."
    panes do: [:p | (p contains: col row: r) ifTrue: [
        focus := p.
        p click: col row: r.
        ^self drawAll]] ]
UIApp >> status: aString [
    "Sets the status line's text to aString and draws it."
    status := aString. self drawStatus ]
UIApp >> drawAll [
    "Redraws the whole window: clears it (ws FILL), draws every pane and
     the status line."
    window clear: UIApp background.
    panes do: [:p | p draw].
    self drawStatus ]
UIApp >> drawStatus [
    "Draws the status line, the window's last row, in the accent colour
     (ws TEXT), padded or cut to the window's width."
    | s |
    s := status , (String new: (self columns - status size max: 0) withAll: $ ).
    window text: (s copyFrom: 1 to: (s size min: self columns)) column: 0 row: self rows - 1
        color: UIApp background background: UIApp accent ]
UIApp >> hasFocus: aPane [
    "Answers whether aPane has the focus."
    ^focus == aPane ]

"---- panes ---------------------------------------------------------------------------"

Pane >> app: anApp x: ax y: ay w: aw h: ah title: aString [
    "Places the pane in anApp: its top left cell (ax, ay), aw cells wide
     and ah high (the title line included), titled aString. Answers the
     receiver."
    app := anApp. x := ax. y := ay. w := aw. h := ah. title := aString ]
Pane >> contains: col row: r [
    "Answers whether the cell (col, r) of the window is in the pane."
    ^(col between: x and: x + w - 1) and: [r between: y and: y + h - 1] ]
Pane >> line: aString at: r color: fg background: bg [
    "Draws aString as row r of the pane (0: the title line), padded with
     spaces or cut to the pane's width, in colour fg on bg (ws TEXT)."
    | s |
    s := aString size >= w ifTrue: [aString copyFrom: 1 to: w] ifFalse: [aString , (String new: w - aString size withAll: $ )].
    app window text: s column: x row: y + r color: fg background: bg ]
Pane >> draw [
    "Draws the pane: its title line (the title in the accent colour when
     the pane has the focus, else dim), then its body."
    self line: ' ' , title at: 0 color: ((app hasFocus: self) ifTrue: [UIApp accent] ifFalse: [UIApp dim]) background: UIApp selection.
    self drawBody ]
Pane >> drawBody [
    "Draws the rows under the title; nothing here."
    ^self ]
Pane >> key: c [
    "Handles a character typed while the pane has the focus; nothing here."
    ^self ]
Pane >> special: aSymbol [
    "Handles a special key (#up, #home, ...) while the pane has the focus;
     nothing here."
    ^self ]
Pane >> click: col row: r [
    "Handles a click at cell (col, r) of the window; nothing here."
    ^self ]
Pane >> bodyRows [
    "The number of rows under the title line."
    ^h - 1 ]

ListPane >> items: aCollection [
    "Makes aCollection (as an OrderedCollection) the items, with none
     selected and the list scrolled to the top. Does not redraw."
    items := aCollection asOrderedCollection. selection := 0. top := 0 ]
ListPane >> items [
    "The items listed, an OrderedCollection."
    ^items ]
ListPane >> onSelect: aBlock [
    "Sets the block run with the item each time one is selected."
    onSelect := aBlock ]
ListPane >> selection [
    "The selected item's index, 0 when none is."
    ^selection ]
ListPane >> selected [
    "The selected item, or nil when none is."
    ^(selection between: 1 and: items size) ifTrue: [items at: selection] ifFalse: [nil] ]
ListPane >> select: i [
    "Selects the item at index i, scrolling to show it, runs the onSelect
     block with it and redraws the whole tool. Does nothing if i is not an
     item's index."
    (i between: 1 and: items size) ifFalse: [^self].
    selection := i.
    selection <= top ifTrue: [top := selection - 1].
    selection > (top + self bodyRows) ifTrue: [top := selection - self bodyRows].
    onSelect == nil ifFalse: [onSelect value: self selected].
    app drawAll ]
ListPane >> drawBody [
    "Draws the items in view, one a row, the selected one in reverse."
    | i item |
    1 to: self bodyRows do: [:r |
        i := top + r.
        item := i <= items size ifTrue: [' ' , (items at: i) displayString] ifFalse: [''].
        i = selection
            ifTrue: [self line: item at: r color: UIApp background background: UIApp foreground]
            ifFalse: [self line: item at: r color: UIApp foreground background: UIApp background]] ]
ListPane >> special: aSymbol [
    "Moves the selection: #up and #down by one, #pageUp and #pageDown by a
     pane's height, #home and #end to the first and the last item."
    aSymbol == #up ifTrue: [^self select: (selection - 1 max: 1)].
    aSymbol == #down ifTrue: [^self select: (selection + 1 min: items size)].
    aSymbol == #pageUp ifTrue: [^self select: (selection - self bodyRows max: 1)].
    aSymbol == #pageDown ifTrue: [^self select: (selection + self bodyRows min: items size)].
    aSymbol == #home ifTrue: [^self select: 1].
    aSymbol == #end ifTrue: [^self select: items size] ]
ListPane >> key: c [
    "For a letter c, selects the next item after the selected one (going
     round) whose displayString begins with it, in either case. Other
     characters are ignored."
    | n i |
    c isLetter ifFalse: [^self].
    n := items size.
    1 to: n do: [:k |
        i := (selection + k - 1) \\ n + 1.
        ((items at: i) displayString asLowercase beginsWith: (String with: c asLowercase)) ifTrue: [^self select: i]] ]
ListPane >> click: col row: r [
    "Selects the item on row r of the window, if r is under the title and
     there is an item there."
    r > y ifTrue: [self select: top + r - y] ]

TextPane >> setText: aString [
    "Makes aString's lines the text (one empty line if it has none) and
     puts the cursor at the start. Does not redraw."
    lines := (aString lines collect: [:l | l]) asOrderedCollection.
    lines isEmpty ifTrue: [lines add: ''].
    row := 1. col := 0. top := 0 ]
TextPane >> text [
    "Answers the text, its lines joined by carriage returns."
    | s |
    s := WriteStream on: (String new: 256).
    lines do: [:l | s nextPutAll: l] separatedBy: [s nextPut: Character cr].
    ^s contents ]
TextPane >> editable: aBoolean [
    "Sets whether the pane takes keys that change the text (and shows a
     cursor)."
    editable := aBoolean ]
TextPane >> lines [
    "The text's lines, an OrderedCollection of Strings."
    ^lines ]
TextPane >> row [
    "The cursor's line, from 1."
    ^row ]
TextPane >> currentLine [
    "The cursor's line of text, a String."
    ^lines at: row ]
TextPane >> insertLine: aString after: r [
    "Inserts aString as a new line after line r (0: before the first).
     Does not move the cursor or redraw."
    lines add: aString beforeIndex: r + 1 ]
TextPane >> moveTo: r column: c [
    "Moves the cursor to line r, column c, each kept within the text, and
     scrolls to show it. Does not redraw."
    row := (r max: 1) min: lines size.
    col := (c max: 0) min: (lines at: row) size.
    row <= top ifTrue: [top := row - 1].
    row > (top + self bodyRows) ifTrue: [top := row - self bodyRows] ]
TextPane >> drawBody [
    "Draws the lines in view and, when the pane is editable and has the
     focus, the cursor (the character under it in reverse)."
    | i l |
    1 to: self bodyRows do: [:r |
        i := top + r.
        l := i <= lines size ifTrue: [lines at: i] ifFalse: [''].
        self line: l at: r color: UIApp foreground background: UIApp background].
    ((app hasFocus: self) and: [editable == true]) ifTrue: [
        | ch | ch := col < (lines at: row) size ifTrue: [String with: ((lines at: row) at: col + 1)] ifFalse: [' '].
        app window text: ch column: x + col row: y + row - top color: UIApp background background: UIApp accent] ]
TextPane >> redrawRow [
    "Draws the cursor's line again, with the cursor: what a key that
     changes only that line needs."
    | l |
    l := lines at: row.
    self line: l at: row - top color: UIApp foreground background: UIApp background.
    ((app hasFocus: self) and: [editable == true]) ifTrue: [
        | ch | ch := col < l size ifTrue: [String with: (l at: col + 1)] ifFalse: [' '].
        app window text: ch column: x + col row: y + row - top color: UIApp background background: UIApp accent] ]
TextPane >> key: c [
    "Edits the text with the character c, when editable: Return (13 or
     10) splits the line at the cursor, Backspace (127 or 8) deletes the
     character before it or joins the line to the one above, a printable
     character is inserted. Others are ignored. Redraws what changed."
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
    "Moves the cursor: #up and #down a line, #left and #right a character
     (across line ends), #home and #end to the line's start and end,
     #pageUp and #pageDown by a pane's height; then redraws the body."
    aSymbol == #up ifTrue: [self moveTo: row - 1 column: col].
    aSymbol == #down ifTrue: [self moveTo: row + 1 column: col].
    aSymbol == #left ifTrue: [col > 0 ifTrue: [col := col - 1] ifFalse: [self moveTo: row - 1 column: 9999]].
    aSymbol == #right ifTrue: [col < (lines at: row) size ifTrue: [col := col + 1] ifFalse: [self moveTo: row + 1 column: 0]].
    aSymbol == #home ifTrue: [col := 0].
    aSymbol == #end ifTrue: [col := (lines at: row) size].
    aSymbol == #pageUp ifTrue: [self moveTo: row - self bodyRows column: col].
    aSymbol == #pageDown ifTrue: [self moveTo: row + self bodyRows column: col].
    self drawBody ]
TextPane >> click: col0 row: r [
    "Moves the cursor to the cell (col0, r) of the window, if r is under
     the title."
    r > y ifTrue: [self moveTo: top + r - y column: col0 - x] ]

"---- Workspace: lines of code; Ctrl-P prints, Ctrl-D does, Ctrl-O inspects ----"

Workspace class >> title [
    "The title of a Workspace's window.
     Workspace title >>> 'workspc'"
    ^'workspc' ]
Workspace >> layout [
    "Makes the one TextPane, the whole window but the status line, editable
     and holding a few lines to try; shows the version in the status line.
     A resize lays it out again, so the text goes back to those lines."
    text := self add: (TextPane new app: self x: 0 y: 0 w: self columns h: self rows - 1
        title: 'Workspace   Ctrl-P print it  Ctrl-D do it  Ctrl-O inspect it  Ctrl-B browse  Ctrl-Q quit').
    text editable: true.
    text setText: '3 + 4' , (String with: Character cr) , '100 factorial' , (String with: Character cr) ,
        '(1 to: 10) collect: [:i | i * i]' , (String with: Character cr) , 'Proc ps'.
    self status: 'Stratalk ' , Smalltalk version ]
Workspace >> quitsOnEscape [
    "Answers false: Esc does not quit a Workspace."
    ^false ]
Workspace >> relayout [
    "Takes the window back from a tool shown in it (an Inspector, a
     ClassBrowser) and redraws."
    done := false. self drawAll ]
Workspace >> command: c [
    "Takes the Workspace's keys: Ctrl-P prints it, Ctrl-D does it, Ctrl-O
     inspects it (an Inspector in the same window), Ctrl-B opens a
     ClassBrowser in the same window. Answers whether c was one of them."
    c value = 16 ifTrue: [self evaluate: true. ^true].
    c value = 4 ifTrue: [self evaluate: false. ^true].
    c value = 15 ifTrue: [self evaluate: false. (Inspector on: last) openOn: last in: window. self relayout. ^true].
    c value = 2 ifTrue: [ClassBrowser new openIn: window. self relayout. ^true].
    ^false ]
Workspace >> evaluate: print [
    "Evaluates the cursor's line (what comes before a ' -> ' in it) and
     keeps the value in last; with print true, inserts '  -> ' and its
     printString as the next line. The status line says ok, or the
     error's messageText."
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

ClassBrowser class >> title [
    "The title of a ClassBrowser's window.
     ClassBrowser title >>> 'browser'"
    ^'browser' ]
ClassBrowser class >> openIn: aWindow [
    "Runs a new ClassBrowser in aWindow, already open, until it quits;
     answers it."
    ^self new openIn: aWindow ]
ClassBrowser >> layout [
    "Makes the panes: the classes (the top half's left third, every class
     of the system), the selectors (the rest of the top half) and the
     source (the bottom half, editable); the status line counts the
     classes."
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
ClassBrowser >> quitsOnEscape [
    "Answers whether Esc closes the browser: not while the source pane has
     the focus."
    ^focus ~~ source ]
ClassBrowser >> currentClass [
    "The selected class, or its metaclass on the class side; nil when no
     class is selected."
    | c |
    classes selected == nil ifTrue: [^nil].
    c := Smalltalk at: classes selected asSymbol ifAbsent: [^nil].
    ^meta ifTrue: [c class] ifFalse: [c] ]
ClassBrowser >> command: c [
    "Takes the browser's keys: t (outside the source pane) toggles the
     class side, Ctrl-S accepts the source pane. Answers whether c was one
     of them."
    (c = $t and: [focus ~~ source]) ifTrue: [meta := meta not. self showClass. ^true].
    c value = 19 ifTrue: [self accept. ^true].
    ^false ]
ClassBrowser >> showClass [
    "Shows the selected class: its selectors in the selectors pane, its
     definition in the source pane, its slots and methods counted in the
     status line."
    | c |
    c := self currentClass.
    c == nil ifTrue: [^self].
    selectors items: (c selectors collect: [:s | s asString]) asArray.
    source setText: (self definitionOf: c).
    self status: c name , '   ' , c instSize printString , ' slots, ' , c selectors size printString , ' methods' ]
ClassBrowser >> definitionOf: c [
    "Answers the class definition of c, as a kernel file writes it
     (Super subclass: #Name slots: '...'); '' for a metaclass."
    | s |
    s := WriteStream on: (String new: 128).
    c isClass & (c theNonMetaClass == c) ifTrue: [
        s nextPutAll: (c superclass == nil ifTrue: ['nil'] ifFalse: [c superclass name]);
          nextPutAll: ' subclass: #'; nextPutAll: c name; nextPutAll: ' slots: '''.
        c instVarNames do: [:n | s nextPutAll: n] separatedBy: [s space].
        s nextPutAll: ''''].
    ^s contents ]
ClassBrowser >> showMethod [
    "Shows the selected method's source in the source pane and names it in
     the status line."
    | c sel |
    c := self currentClass. sel := selectors selected.
    (c == nil or: [sel == nil]) ifTrue: [^self].
    source setText: (self sourceOf: sel asSymbol in: c).
    self status: c name , '>>' , sel ]
ClassBrowser >> sourceOf: sel in: c [
    "Answers the source of c's method sel from MethodSource, or a note
     and the selector when it has none."
    ^MethodSource sourceOf: sel in: c ifAbsent: [
        '"no source: compiled from somewhere else"' , (String with: Character cr) , sel ] ]
ClassBrowser >> accept [
    "Compiles the source pane's text as a method of the current class and
     lists its selectors again. The status line says what was accepted, or
     the error."
    | c m |
    c := self currentClass.
    c == nil ifTrue: [^self status: 'no class'].
    m := [c compile: source text] on: Error do: [:e | ^self status: 'Error: ' , e messageText].
    self status: 'accepted: ' , m printString.
    selectors items: (c selectors collect: [:s | s asString]) asArray ]

"---- Inspector: an object's slots; Enter goes into one, Backspace back ----"

Inspector class >> title [
    "The title of an Inspector's window.
     Inspector title >>> 'inspect'"
    ^'inspect' ]
Inspector class >> on: anObject [
    "Answers an Inspector of anObject, not yet open."
    ^self new setObject: anObject ]
Inspector >> setObject: anObject [
    "Makes anObject the one shown, with nothing gone into yet."
    object := anObject. stack := OrderedCollection new ]
Inspector >> openOn: anObject [
    "Inspects anObject in a new Window of ws until the Inspector quits,
     then closes the window; answers the Inspector."
    | w |
    object := anObject. stack := OrderedCollection new.
    w := Window open: 'inspect'.
    ^[self openIn: w] ensure: [w close] ]
Inspector >> openOn: anObject in: aWindow [
    "Inspects anObject in aWindow, already open, until the Inspector
     quits; answers it."
    object := anObject. stack := OrderedCollection new. ^self openIn: aWindow ]
Inspector >> layout [
    "Makes the panes: the slots list (all but the bottom 4 rows) and a
     3-row value pane under it, not editable; fills the list."
    list := self add: (ListPane new app: self x: 0 y: 0 w: self columns h: self rows - 4 title: 'Inspector   Enter: into   Backspace: back   Esc: close').
    detail := self add: (TextPane new app: self x: 0 y: self rows - 4 w: self columns h: 3 title: 'Value').
    detail editable: false.
    detail setText: ''.
    list onSelect: [:item | self showSlot].
    self refresh ]
Inspector >> slots [
    "Answers the object's {name. value} pairs: self, class, each named
     slot, and the first 200 indexed slots ('[1]', ...)."
    | out names |
    out := OrderedCollection new.
    out add: (Array with: 'self' with: object).
    out add: (Array with: 'class' with: object class).
    names := object class allInstVarNames.
    names doWithIndex: [:n :i | out add: (Array with: n with: (object instVarAt: i))].
    1 to: (object basicSize min: 200) do: [:i | out add: (Array with: '[' , i printString , ']' with: (object basicAt: i))].
    ^out ]
Inspector >> refresh [
    "Lists the object's slots as name: printString ('?' where printString
     fails); the status line gives its class, near or far, and how deep
     the inspector has gone."
    | s |
    s := self slots.
    list items: (s collect: [:p | (p at: 1) , ': ' , ([(p at: 2) printString] on: Error do: [:e | '?'])]).
    self status: object class name , ' (' , (object isNear ifTrue: ['near'] ifFalse: ['far']) , ')' , (stack isEmpty ifTrue: [''] ifFalse: ['   depth ' , stack size printString]) ]
Inspector >> showSlot [
    "Shows the selected slot's value's printString in the value pane."
    | p |
    p := self slots at: list selection ifAbsent: [^self].
    detail setText: ([(p at: 2) printString] on: Error do: [:e | '?']).
    detail drawBody ]
Inspector >> key: c [
    "Return goes into the selected slot's value, Backspace back to the
     object before; other keys as for any UIApp."
    (c value = 13 or: [c value = 10]) ifTrue: [^self dive].
    (c value = 127 or: [c value = 8]) ifTrue: [^self back].
    super key: c ]
Inspector >> dive [
    "Inspects the selected slot's value, keeping the object shown now to
     go back to; redraws."
    | p |
    p := self slots at: list selection ifAbsent: [^self].
    stack add: object.
    object := p at: 2.
    self refresh. self drawAll ]
Inspector >> back [
    "Inspects again the object the last dive came from, if any; redraws."
    stack isEmpty ifTrue: [^self].
    object := stack removeLast.
    self refresh. self drawAll ]

Object >> inspect [
    "Opens an Inspector on the receiver in a new window of ws, until it is
     closed; answers the Inspector."
    ^(Inspector on: self) openOn: self ]
SystemDictionary >> browse [
    "Opens a ClassBrowser in a new window of ws, until it is closed;
     answers the browser."
    ^ClassBrowser open ]

"---- method sources: the kernel's files on the disk, and what was compiled here ----"

Object subclass: #MethodSource slots: ''.
MethodSource class slots: 'files compiled'.
"Where the ClassBrowser finds a method's source: what was compiled in
 this session (compile:, fileIn), else the kernel's .st files on the
 disk (/stratalk/). Class side only: files caches the files' contents,
 compiled maps 'Class>>selector' to the source last compiled.
 MethodSource selectorOf: 'at: i put: v [ ^v ]' >>> 'at:put:'"
MethodSource class >> note: aString class: aClass selector: aSymbol [
    "Keeps aString as the source of aClass's method aSymbol, for the
     browser: what compile: and fileIn call."
    compiled == nil ifTrue: [compiled := Dictionary new].
    compiled at: aClass name , '>>' , aSymbol put: aString ]
MethodSource class >> sourceOf: sel in: aClass ifAbsent: aBlock [
    "Answers the source of aClass's method sel: the last one compiled in
     this session, else the kernel's file's (fromFiles:in:ifAbsent:), else
     the value of aBlock."
    | key |
    key := aClass name , '>>' , sel.
    compiled == nil ifFalse: [(compiled at: key ifAbsent: [nil]) ifNotNil: [:s | ^s]].
    ^self fromFiles: sel in: aClass ifAbsent: aBlock ]
MethodSource class >> fromFiles: sel in: aClass ifAbsent: aBlock [
    "Answers aClass's method sel as a kernel file has it: the line that
     begins 'Class >> ' with this selector (without that prefix), and the
     lines after it that begin with a space or a tab, up to the first that
     does not (or is empty). Answers the value of aBlock if no file has
     it."
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
    "Answers the selector a method's pattern text gives, the text before
     its [: a keyword selector's keywords joined, else the first word.
     MethodSource selectorOf: 'at: i put: v [ ^v ]' >>> 'at:put:'
     MethodSource selectorOf: ', aString [ ^self ]' >>> ','"
    | toks sel |
    toks := (aPattern copyFrom: 1 to: ((aPattern indexOf: $[) - 1 max: 0)) substrings.
    toks isEmpty ifTrue: [^''].
    (toks first last = $:) ifFalse: [^toks first].
    sel := WriteStream on: (String new: 32).
    toks do: [:t | t last = $: ifTrue: [sel nextPutAll: t]].
    ^sel contents ]
MethodSource class >> files [
    "Answers the contents of the kernel's source files (the names in
     SourceFiles), read from /stratalk/ through fs the first time and kept;
     a file that cannot be read is ''."
    files == nil ifTrue: [
        files := (Smalltalk at: #SourceFiles ifAbsent: [#()]) collect: [:n |
            [(File named: '/stratalk/' , n) contents] on: Error do: [:e | '']]].
    ^files ]
