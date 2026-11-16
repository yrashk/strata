"UI.st: the graphical tools, in windows of the window server: a
 Workspace, a ClassBrowser and an Inspector. The server draws text in
 cells of 8 x 16; a pane is a rectangle of cells. Keys come as a terminal
 sends them (arrows: ESC [ A ...); the pointer selects.

   Workspace open        ClassBrowser open        anObject inspect
   stratalk -w           stratalk -b              (from a terminal of ws)

 Keys typed quickly come several to an event (up to 8 bytes), so an escape
 sequence can be cut between two events: its beginning waits for the rest
 (an ESC alone that nothing follows soon is the Esc key). The keys waiting
 are taken together and the window drawn once after them: a held arrow
 does not fall behind, and ws's queue (8 events) does not overflow. A
 list tells what was selected (a class's selectors, a method's source)
 once, after them."

Object subclass: #UIApp slots: 'window panes focus done status pending batch stale chosen'.
"A tool in a Window of ws: panes of character cells, the one with the
 focus taking the keys, a status line at the bottom, and an event loop.
 window is the Window, panes the Panes in Tab order, focus the pane with
 the focus, done true once the loop should end, status the status line's
 text, pending the start of an escape sequence an event cut short, batch
 true while the keys of several events are handled together, stale true
 when the window is to be drawn after them, chosen the lists whose
 selection changed meanwhile. A subclass lays its panes out (layout) and
 may take keys first (command:). Keys every tool shares: Tab the next
 pane, Ctrl-Q quit, Esc quit (where quitsOnEscape, and the pane with the
 focus has no use for it); a click focuses the pane under the pointer.
 UIApp open opens one in a window of its own."

Object subclass: #Pane slots: 'app x y w h title'.
"A rectangle of character cells in a UIApp's window: its top row is the
 title line, the rows under it the body. app is the UIApp, x and y the
 top left cell, w and h the size in cells, title the title's text. Pane
 itself draws only the title; ListPane and TextPane draw a body and take
 keys and clicks."

Pane subclass: #ListPane slots: 'items selection top onSelect all filter'.
"A Pane that lists items (anything, shown by displayString), one a row,
 with one selected. items is an OrderedCollection, selection the selected
 index (0: none), top the number of items scrolled off above, onSelect a
 one-argument block run with the item each time one is selected, all
 every item, filter the text typed (nil: no typeahead). Keys: the arrows,
 Page Up and Down, Home and End move the selection; with typeahead,
 typing narrows the list to the items that hold the text, Backspace takes
 a character back, Esc or Ctrl-U clears it; without, a letter selects the
 next item that begins with it. A click selects."

Pane subclass: #TextPane slots: 'lines row col top editable highlight opens'.
"A Pane that shows text, and edits it when editable. lines is an
 OrderedCollection of Strings, row the cursor's line (from 1), col its
 column (from 0), top the number of lines scrolled off above, editable
 true to take keys (printable characters, Return, Backspace, Delete),
 highlight true to colour the text as Stratalk (StHighlight), opens the
 quote (a comment's or a string's) still open at the start of each line.
 The arrows, Home, End and Page Up and Down move the cursor; a click puts
 it there."

Object subclass: #StHighlight slots: ''.
"Stratalk source in colours, a line at a time, as the website colours it
 (site/hl.js, stLines): comments; strings, $c characters and #symbols;
 numbers; keywords (at:put:); self, super, nil, true, false and
 thisContext; class names; block arguments and temporaries; ^, := and >>.
 A comment or a string goes on from one line to the next: runsOf:open:into:
 takes the quote still open at the line's start and answers the one open
 at its end."

UIApp subclass: #Workspace slots: 'text last'.
"A UIApp of one editable TextPane of code. The cursor's line is the code:
 Ctrl-P evaluates it and prints the result under it ('  -> ' and the
 printString), Ctrl-D evaluates it, Ctrl-O evaluates it and inspects the
 result, Ctrl-B opens a ClassBrowser in the same window, Ctrl-Q quits.
 Esc does not quit it. text is the TextPane, last the last value
 evaluated. Workspace open, or stratalk -w."

UIApp subclass: #ClassBrowser slots: 'classes selectors source meta'.
"A UIApp of three panes: the classes (a ListPane), the selected class's
 selectors (a ListPane) and a source pane (an editable TextPane) that
 shows the class's definition or the selected method's source, from
 MethodSource, in colours. Typing in a list narrows it (typeahead).
 Ctrl-T toggles the class side (meta); Ctrl-S compiles the source pane's
 text into the class; Esc (in a list with nothing typed) and Ctrl-Q
 close it. ClassBrowser open, Smalltalk browse, or stratalk -b."

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
    "The event loop: waits for the window's events (ws EVENT) until done,
     and hands each to handle:. While an escape sequence waits for its
     rest, waits 40 ms at most: if nothing came, its ESC was the Esc key."
    | e |
    [done] whileFalse: [
        e := pending == nil ifTrue: [window nextEvent] ifFalse: [window nextEventWait: 40000].
        (e == nil and: [pending notNil]) ifTrue: [self flushPending].
        e == nil ifFalse: [self handle: e]] ]
UIApp >> handle: e [
    "A close ends the loop; a resize lays the panes out again and redraws;
     keys go to keys:, with those of the key events already waiting (ws
     EVENT without blocking), taken together (batch:); a pointer event with
     a button held to click:row:, in cells."
    | ks more |
    e isClose ifTrue: [done := true].
    e isResize ifTrue: [panes := OrderedCollection new. self layout. focus := panes first. self drawAll].
    e isKey ifTrue: [
        ks := e keys.
        [(more := window pollEvent) notNil and: [more isKey]] whileTrue: [ks := ks , more keys].
        self batch: [self keys: ks].
        more == nil ifFalse: [self handle: more]].
    (e isPointer and: [e buttons ~= 0]) ifTrue: [self click: e x // Window cellWidth row: e y // Window cellHeight] ]
UIApp >> batch: aBlock [
    "Runs aBlock with drawing put off: then tells the lists whose selection
     changed (their onSelect, once each), and redraws the window once if
     anything asked for it."
    | lists |
    batch := true. stale := false. chosen := OrderedCollection new.
    [aBlock value] ensure: [batch := false. lists := chosen. chosen := nil].
    lists do: [:p | p changed].
    stale ifTrue: [stale := false. self drawAll] ]
UIApp >> selectionChanged: aList [
    "Runs aList's onSelect now, or, while keys are taken together, once
     after them."
    chosen == nil ifTrue: [^aList changed].
    (chosen includes: aList) ifFalse: [chosen add: aList] ]
UIApp >> keys: aString [
    "Handles the bytes of a key event, as a terminal sends them, after what
     an earlier event left of an escape sequence: an escape sequence goes to
     escape:, any other character to key:. A sequence cut short is kept in
     pending for the next event; one cut short, then another one (or an
     ESC, then what cannot follow it in a sequence), lost its rest (ws's
     queue was full) and is dropped: it is not an Esc."
    | s c start |
    (pending notNil and: [aString notEmpty and: [aString first value = 27
        or: [pending size = 1 and: [aString first ~= $[]]]]) ifTrue: [pending := nil].
    s := ReadStream on: (pending == nil ifTrue: [aString] ifFalse: [pending , aString]).
    pending := nil.
    [s atEnd] whileFalse: [
        start := s position.
        c := s next.
        c value = 27
            ifTrue: [(self escape: s) ifFalse: [
                pending := s collection copyFrom: start + 1 to: s collection size.
                ^self]]
            ifFalse: [self key: c]] ]
UIApp >> escape: s [
    "Reads the rest of an escape sequence from the stream s, after its ESC,
     and hands it on: ESC [ A, B, C, D, H, F (the arrows, Home, End; also
     with modifiers, ESC [ 1 ; 5 D) and ESC [ n ~ or ESC [ n ; m ~ (Home,
     Insert, Delete, End, Page Up, Page Down) to special: as a Symbol (#up,
     #pageDown, ...; #none for another); ESC and another key to key:.
     Answers false, having done
     nothing, when the stream ends before the sequence does. A sequence
     whose end never came (a dropped event) is dropped, and the key after
     it is a key."
    | c n |
    s atEnd ifTrue: [^false].
    s peek = $[ ifFalse: [self key: (Character value: 27). ^true].
    s next.
    s atEnd ifTrue: [^false].
    c := s next.
    c value < 64 & c isDigit not ifTrue: [s skip: -1. ^true].
    c isDigit ifTrue: [
        n := c digitValue.
        [s atEnd not and: [s peek isDigit]] whileTrue: [n := n * 10 + s next digitValue].
        [s atEnd not and: [s peek isDigit or: [s peek = $;]]] whileTrue: [s next].
        s atEnd ifTrue: [^false].
        s peek value < 64 ifTrue: [^true].
        c := s next.
        c = $~ ifTrue: [self special: (#(#home #insert #delete #end #pageUp #pageDown) at: n ifAbsent: [#none]). ^true]].
    self special: (c = $A ifTrue: [#up] ifFalse: [c = $B ifTrue: [#down] ifFalse: [c = $C ifTrue: [#right] ifFalse: [
        c = $D ifTrue: [#left] ifFalse: [c = $H ifTrue: [#home] ifFalse: [c = $F ifTrue: [#end] ifFalse: [#none]]]]]]).
    ^true ]
UIApp >> flushPending [
    "No more came: an ESC alone was the Esc key; a sequence begun (ESC [ ...)
     lost its rest (ws dropped it, its queue full) and is dropped: taking it
     for Esc would close a tool while an arrow is held."
    | p |
    p := pending.
    pending := nil.
    p size = 1 ifTrue: [self key: (Character value: 27)] ]
UIApp >> key: c [
    "Handles the character c: Tab moves the focus to the next pane, Ctrl-Q
     quits, Esc quits where quitsOnEscape; otherwise command: may take it,
     and if it does not the focused pane gets it."
    c value = 9 ifTrue: [^self nextPane].
    c value = 17 ifTrue: [^done := true].
    (c value = 27 and: [focus takesEscape not and: [self quitsOnEscape]]) ifTrue: [^done := true].
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
     the status line. While keys are taken together, only notes that it is
     to be done after them."
    batch == true ifTrue: [^stale := true].
    window clear: UIApp background.
    panes do: [:p | p draw].
    self drawStatus ]
UIApp >> drawStatus [
    "Draws the status line, the window's last row, in the accent colour
     (ws TEXT), padded or cut to the window's width."
    | s |
    batch == true ifTrue: [^stale := true].
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
Pane >> takesEscape [
    "Answers whether Esc means something to the pane now (then it does not
     close the tool)."
    ^false ]
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
     selected, the list scrolled to the top and the typeahead's text
     cleared. Does not redraw."
    all := aCollection asOrderedCollection.
    items := all.
    selection := 0. top := 0.
    filter == nil ifFalse: [filter := ''] ]
ListPane >> typeahead [
    "Turns typeahead on: typing filters the list to the item that is the
     text, those that begin with it, then those that hold it elsewhere (in
     any case), and selects the first. Backspace takes a character back,
     Esc or Ctrl-U clears it (the list is whole again, the item selected
     stays so)."
    filter := '' ]
ListPane >> filter [
    "The typeahead's text ('' when none is typed; nil without typeahead)."
    ^filter ]
ListPane >> takesEscape [
    "Esc clears the typeahead's text while there is one."
    ^filter notNil and: [filter notEmpty] ]
ListPane >> filter: aString [
    "Makes aString the typeahead's text: lists the items that match it
     (all of them for ''), and selects the first, or, for '', the item that
     was selected; with no match, says so on the status line."
    | f exact first rest was |
    was := self selected.
    filter := aString.
    f := filter asLowercase.
    f isEmpty
        ifTrue: [items := all]
        ifFalse: [
            exact := OrderedCollection new. first := OrderedCollection new. rest := OrderedCollection new.
            all do: [:it | | l |
                l := it displayString asLowercase.
                l = f ifTrue: [exact add: it] ifFalse: [
                    (l beginsWith: f) ifTrue: [first add: it] ifFalse: [(l includesSubstring: f) ifTrue: [rest add: it]]]].
            items := exact addAll: first; addAll: rest; yourself].
    selection := 0. top := 0.
    items isEmpty ifTrue: [app status: 'no match: ' , filter. ^app drawAll].
    self select: ((f isEmpty and: [was notNil]) ifTrue: [(items indexOf: was) max: 1] ifFalse: [1]) ]
ListPane >> draw [
    "Draws the title line (the typeahead's text and the number of matches
     in place of the title while there is one), then the body."
    | t |
    t := (filter == nil or: [filter isEmpty]) ifTrue: [title] ifFalse: ['find: ' , filter , '_   (' , items size printString , ')'].
    self line: ' ' , t at: 0 color: ((app hasFocus: self) ifTrue: [UIApp accent] ifFalse: [UIApp dim]) background: UIApp selection.
    self drawBody ]
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
     block with it (through the tool: see selectionChanged:) and redraws the
     whole tool. Does nothing if i is not an item's index."
    (i between: 1 and: items size) ifFalse: [^self].
    selection := i.
    selection <= top ifTrue: [top := selection - 1].
    selection > (top + self bodyRows) ifTrue: [top := selection - self bodyRows].
    app selectionChanged: self.
    app drawAll ]
ListPane >> changed [
    "Runs the onSelect block with the selected item."
    onSelect == nil ifFalse: [onSelect value: self selected] ]
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
    "With typeahead: Backspace takes the text's last character back, Esc or
     Ctrl-U clears it, a printable character other than a space is added
     to it. Without: for a letter c, selects the next item after the
     selected one (going round) whose displayString begins with it, in
     either case. Other characters are ignored."
    | n i |
    filter == nil ifFalse: [
        (c value = 127 or: [c value = 8]) ifTrue: [
            filter isEmpty ifFalse: [self filter: (filter copyFrom: 1 to: filter size - 1)].
            ^self].
        (c value = 27 or: [c value = 21]) ifTrue: [filter isEmpty ifFalse: [self filter: '']. ^self].
        (c value > 32 and: [c value < 127]) ifTrue: [self filter: filter , (String with: c)].
        ^self].
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
TextPane >> column [
    "The cursor's column, from 0."
    ^col ]
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
TextPane >> highlight: aBoolean [
    "Sets whether the text is coloured as Stratalk."
    highlight := aBoolean ]
TextPane >> computeOpens [
    "Notes, for each line, the quote still open at its start (opens at: i),
     and after the last line (opens at: lines size + 1)."
    | q |
    opens := Array new: lines size + 1.
    q := nil.
    1 to: lines size do: [:i | opens at: i put: q. q := StHighlight runsOf: (lines at: i) open: q into: nil].
    opens at: lines size + 1 put: q ]
TextPane >> drawLine: i at: r [
    "Draws line i of the text at row r of the pane (an empty row past the
     end), in colours when highlight is on."
    | l runs |
    l := i <= lines size ifTrue: [lines at: i] ifFalse: [''].
    self line: l at: r color: UIApp foreground background: UIApp background.
    (highlight == true and: [i <= lines size]) ifFalse: [^self].
    runs := OrderedCollection new.
    StHighlight runsOf: l open: (opens at: i) into: runs.
    runs do: [:run | | a b |
        a := run at: 1. b := (run at: 2) min: w.
        a <= b ifTrue: [
            app window text: (l copyFrom: a to: b) column: x + a - 1 row: y + r
                color: (run at: 3) background: UIApp background]] ]
TextPane >> drawCursor [
    "When the pane is editable and has the focus, draws the cursor: the
     character under it in reverse."
    ((app hasFocus: self) and: [editable == true]) ifTrue: [
        | ch | ch := col < (lines at: row) size ifTrue: [String with: ((lines at: row) at: col + 1)] ifFalse: [' '].
        app window text: ch column: x + col row: y + row - top color: UIApp background background: UIApp accent] ]
TextPane >> drawBody [
    "Draws the lines in view and the cursor."
    highlight == true ifTrue: [self computeOpens].
    1 to: self bodyRows do: [:r | self drawLine: top + r at: r].
    self drawCursor ]
TextPane >> redrawRow [
    "Draws the cursor's line again, with the cursor: what a key that
     changes only that line needs (all of them when it opened or closed a
     comment or a string that goes on to the next lines)."
    | was |
    highlight == true ifTrue: [
        was := (opens notNil and: [opens size = (lines size + 1)]) ifTrue: [opens at: row + 1] ifFalse: [0].
        self computeOpens.
        was = (opens at: row + 1) ifFalse: [^self drawBody]].
    self drawLine: row at: row - top.
    self drawCursor ]
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
     (across line ends; not past the text's start or end), #home and #end
     to the line's start and end, #pageUp and #pageDown by a pane's height;
     #delete deletes the character under it (or joins the next line);
     then redraws the body."
    aSymbol == #up ifTrue: [self moveTo: row - 1 column: col].
    aSymbol == #down ifTrue: [self moveTo: row + 1 column: col].
    aSymbol == #left ifTrue: [col > 0 ifTrue: [col := col - 1] ifFalse: [row > 1 ifTrue: [self moveTo: row - 1 column: 9999]]].
    aSymbol == #right ifTrue: [col < (lines at: row) size ifTrue: [col := col + 1] ifFalse: [row < lines size ifTrue: [self moveTo: row + 1 column: 0]]].
    (aSymbol == #delete and: [editable == true]) ifTrue: [self deleteForward].
    aSymbol == #home ifTrue: [col := 0].
    aSymbol == #end ifTrue: [col := (lines at: row) size].
    aSymbol == #pageUp ifTrue: [self moveTo: row - self bodyRows column: col].
    aSymbol == #pageDown ifTrue: [self moveTo: row + self bodyRows column: col].
    self drawBody ]
TextPane >> deleteForward [
    "Deletes the character under the cursor, or at the line's end joins
     the next line to it."
    | l |
    l := lines at: row.
    col < l size ifTrue: [^lines at: row put: (l copyFrom: 1 to: col) , (l copyFrom: col + 2 to: l size)].
    row < lines size ifTrue: [
        lines at: row put: l , (lines at: row + 1).
        lines removeIndex: row + 1] ]
TextPane >> click: col0 row: r [
    "Moves the cursor to the cell (col0, r) of the window, if r is under
     the title."
    r > y ifTrue: [self moveTo: top + r - y column: col0 - x] ]

"---- StHighlight: Stratalk in colours ------------------------------------------"

StHighlight class >> comment [ "#5b7088" ^Window rgb: 91 g: 112 b: 136 ]
StHighlight class >> string [ "#f29bd4" ^Window rgb: 242 g: 155 b: 212 ]
StHighlight class >> symbol [ "#8ff0d2" ^Window rgb: 143 g: 240 b: 210 ]
StHighlight class >> number [ "#5be3a1" ^Window rgb: 91 g: 227 b: 161 ]
StHighlight class >> variable [ "#f5d7a6: block arguments, temporaries" ^Window rgb: 245 g: 215 b: 166 ]
StHighlight class >> system [ "#ff6b8b: ^ := >>" ^Window rgb: 255 g: 107 b: 139 ]
StHighlight class >> keyword [ "#c38bff" ^Window rgb: 195 g: 139 b: 255 ]
StHighlight class >> pseudo [ "#8a9bff: self super nil true false thisContext" ^Window rgb: 138 g: 155 b: 255 ]
StHighlight class >> className [ "white" ^Window rgb: 255 g: 255 b: 255 ]
StHighlight class >> runsOf: s open: quote into: runs [
    "Adds to runs (unless nil) the coloured parts of the line s, each
     {first. last. colour}, after a comment or a string (quote: its quote
     character) still open at its start; answers the quote still open at its
     end, or nil.
     | r | r := OrderedCollection new. StHighlight runsOf: 'x := 3' open: nil into: r. r size >>> 2"
    | i n c j w |
    n := s size.
    i := 1.
    quote == nil ifFalse: [
        j := self close: quote in: s from: 1.
        j = 0 ifTrue: [self run: 1 to: n colour: (self quoteColour: quote) into: runs. ^quote].
        self run: 1 to: j colour: (self quoteColour: quote) into: runs.
        i := j + 1].
    j := i.
    [j <= n and: [(s at: j) isSeparator]] whileTrue: [j := j + 1].
    (j <= n and: [(s at: j) = $|]) ifTrue: [ | k |
        k := j + 1.
        [k <= n and: [(s at: k) isAlphaNumeric or: [(s at: k) = $_ or: [(s at: k) isSeparator]]]] whileTrue: [k := k + 1].
        (k <= n and: [(s at: k) = $|]) ifTrue: [self run: j to: k colour: self variable into: runs. i := k + 1]].
    [i <= n] whileTrue: [
        c := s at: i.
        (c = $" or: [c = $']) ifTrue: [
            j := self close: c in: s from: i + 1.
            j = 0 ifTrue: [self run: i to: n colour: (self quoteColour: c) into: runs. ^c].
            self run: i to: j colour: (self quoteColour: c) into: runs.
            i := j]
        ifFalse: [
        (c = $$ and: [i < n]) ifTrue: [self run: i to: i + 1 colour: self string into: runs. i := i + 1]
        ifFalse: [
        c = $# ifTrue: [
            j := self symbolEnd: s from: i.
            j > i ifTrue: [self run: i to: j colour: self symbol into: runs. i := j]]
        ifFalse: [
        c isDigit ifTrue: [
            j := self numberEnd: s from: i.
            self run: i to: j colour: self number into: runs. i := j]
        ifFalse: [
        (c = $: and: [i < n and: [(s at: i + 1) isLetter or: [(s at: i + 1) = $_]]]) ifTrue: [
            j := self wordEnd: s from: i + 1.
            self run: i to: j colour: self variable into: runs. i := j]
        ifFalse: [
        (c = $^ or: [(c = $: and: [i < n and: [(s at: i + 1) = $=]]) or: [c = $> and: [i < n and: [(s at: i + 1) = $>]]]]) ifTrue: [
            j := c = $^ ifTrue: [i] ifFalse: [i + 1].
            self run: i to: j colour: self system into: runs. i := j]
        ifFalse: [
        (c isLetter or: [c = $_]) ifTrue: [
            j := self wordEnd: s from: i.
            (j < n and: [(s at: j + 1) = $: and: [j + 2 > n or: [(s at: j + 2) ~= $=]]])
                ifTrue: [self run: i to: j + 1 colour: self keyword into: runs. j := j + 1]
                ifFalse: [
                    w := s copyFrom: i to: j.
                    (#('self' 'super' 'nil' 'true' 'false' 'thisContext') includes: w)
                        ifTrue: [self run: i to: j colour: self pseudo into: runs]
                        ifFalse: [c isUppercase ifTrue: [self run: i to: j colour: self className into: runs]]].
            i := j]]]]]]].
        i := i + 1].
    ^nil ]
StHighlight class >> run: a to: b colour: c into: runs [
    "Adds {a. b. c} to runs, unless runs is nil."
    runs == nil ifFalse: [runs add: (Array with: a with: b with: c)] ]
StHighlight class >> quoteColour: q [
    "A comment's colour for a double quote, a string's for a single one."
    ^q = $" ifTrue: [self comment] ifFalse: [self string] ]
StHighlight class >> close: q in: s from: k [
    "The index of the quote q that closes one opened before k (a doubled
     quote is one inside), or 0 when the line has none."
    | i |
    i := k.
    [i <= s size] whileTrue: [
        (s at: i) = q ifTrue: [
            (i < s size and: [(s at: i + 1) = q]) ifTrue: [i := i + 1] ifFalse: [^i]].
        i := i + 1].
    ^0 ]
StHighlight class >> wordEnd: s from: k [
    "The index of the last letter, digit or _ of the word that begins at k."
    | i |
    i := k.
    [i < s size and: [(s at: i + 1) isAlphaNumeric or: [(s at: i + 1) = $_]]] whileTrue: [i := i + 1].
    ^i ]
StHighlight class >> numberEnd: s from: k [
    "The index of the last character of the number that begins at k: 16rFF,
     3.25, 1e10, 2e-3."
    | i |
    i := k.
    [i < s size and: [(s at: i + 1) isDigit]] whileTrue: [i := i + 1].
    (i + 1 < s size and: [(s at: i + 1) = $r and: [(s at: i + 2) isDigit or: [(s at: i + 2) isUppercase]]]) ifTrue: [
        i := i + 1.
        [i < s size and: [(s at: i + 1) isDigit or: [(s at: i + 1) isUppercase]]] whileTrue: [i := i + 1].
        ^i].
    (i + 1 < s size and: [(s at: i + 1) = $. and: [(s at: i + 2) isDigit]]) ifTrue: [
        i := i + 1.
        [i < s size and: [(s at: i + 1) isDigit]] whileTrue: [i := i + 1]].
    (i < s size and: [(s at: i + 1) = $e]) ifTrue: [ | j |
        j := i + 1.
        (j < s size and: [(s at: j + 1) = $-]) ifTrue: [j := j + 1].
        (j < s size and: [(s at: j + 1) isDigit]) ifTrue: [
            i := j.
            [i < s size and: [(s at: i + 1) isDigit]] whileTrue: [i := i + 1]]].
    ^i ]
StHighlight class >> symbolEnd: s from: k [
    "The index of the last character of the symbol whose # is at k (#at:put:,
     #'a b', #+, #( ); k when what follows is none."
    | i c |
    k = s size ifTrue: [^k].
    c := s at: k + 1.
    (c isLetter or: [c = $_]) ifTrue: [
        i := k + 1.
        [i < s size and: [(s at: i + 1) isAlphaNumeric or: [(s at: i + 1) = $_ or: [(s at: i + 1) = $:]]]] whileTrue: [i := i + 1].
        ^i].
    c = $' ifTrue: [i := self close: $' in: s from: k + 2. ^i = 0 ifTrue: [s size] ifFalse: [i]].
    c = $( ifTrue: [^k + 1].
    i := k.
    [i < s size and: ['-+*/\~<>=@%|&?!,' includes: (s at: i + 1)]] whileTrue: [i := i + 1].
    ^i ]

"---- Workspace: lines of code; Ctrl-P prints, Ctrl-D does, Ctrl-O inspects ----"

Workspace class >> title [
    "The title of a Workspace's window.
     Workspace title >>> 'workspc'"
    ^'workspc' ]
Workspace >> layout [
    "Makes the one TextPane, the whole window but the status line, editable
     and holding a few lines to try; shows the version in the status line.
     A resize lays it out again, keeping the text and the cursor."
    | old |
    old := text.
    text := self add: (TextPane new app: self x: 0 y: 0 w: self columns h: self rows - 1
        title: 'Workspace   Ctrl-P print it  Ctrl-D do it  Ctrl-O inspect it  Ctrl-B browse  Ctrl-Q quit').
    text editable: true; highlight: true.
    text setText: '3 + 4' , (String with: Character cr) , '100 factorial' , (String with: Character cr) ,
        '(1 to: 10) collect: [:i | i * i]' , (String with: Character cr) , 'Proc ps'.
    old == nil ifFalse: [text setText: old text. text moveTo: old row column: old column].
    self status: 'Stratalk ' , Smalltalk version ]
Workspace >> textPane [
    "The TextPane of code."
    ^text ]
Workspace >> quitsOnEscape [
    "Answers false: Esc does not quit a Workspace."
    ^false ]
Workspace >> relayout [
    "Takes the window back from a tool shown in it (an Inspector, a
     ClassBrowser) and redraws."
    done := false. self drawAll ]
Workspace >> command: c [
    "Takes the Workspace's keys: Ctrl-P prints it, Ctrl-D does it, Ctrl-O
     inspects it (an Inspector in the same window; nothing when it failed),
     Ctrl-B opens a ClassBrowser in the same window. Answers whether c was
     one of them."
    c value = 16 ifTrue: [self evaluate: true. ^true].
    c value = 4 ifTrue: [self evaluate: false. ^true].
    c value = 15 ifTrue: [
        (self evaluate: false) ifTrue: [(Inspector on: last) openOn: last in: window. self relayout].
        ^true].
    c value = 2 ifTrue: [ClassBrowser new openIn: window. self relayout. ^true].
    ^false ]
Workspace >> evaluate: print [
    "Evaluates the cursor's line and keeps the value in last; with print
     true, inserts '  -> ' and its printString as the next line. A line
     that is such a result is not evaluated. The status line says ok, or
     the error's messageText. Answers whether a value came."
    | code r |
    code := text currentLine.
    (code beginsWith: '  -> ') ifTrue: [self status: 'a result: put the cursor on the code'. ^false].
    r := [Compiler evaluate: code] on: Error do: [:e | self status: 'Error: ' , e messageText. ^false].
    last := r.
    print ifTrue: [
        text insertLine: '  -> ' , r printString after: text row.
        text moveTo: text row + 1 column: 0.
        text drawBody].
    self status: 'ok'.
    ^true ]

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
     classes. Laid out again after a resize, it selects the class and the
     selector that were selected."
    | half third wasClass wasSelector |
    classes == nil ifFalse: [wasClass := classes selected. wasSelector := selectors selected].
    half := self rows - 1 // 2.
    third := self columns // 3.
    meta == nil ifTrue: [meta := false].
    classes := self add: (ListPane new app: self x: 0 y: 0 w: third h: half title: 'Classes').
    selectors := self add: (ListPane new app: self x: third y: 0 w: self columns - third h: half title: 'Selectors   Ctrl-T: class side').
    source := self add: (TextPane new app: self x: 0 y: half w: self columns h: self rows - 1 - half
        title: 'Source   Ctrl-S accept   Tab: next pane   Ctrl-Q: close').
    source editable: true; highlight: true.
    source setText: ''.
    classes typeahead; items: (Smalltalk allClasses collect: [:c | c name asString]).
    selectors typeahead.
    classes onSelect: [:n | self showClass].
    selectors items: #().
    selectors onSelect: [:s | self showMethod].
    self status: Smalltalk allClasses size printString , ' classes   type to find one'.
    wasClass == nil ifFalse: [classes select: ((classes items indexOf: wasClass) max: 1)].
    wasSelector == nil ifFalse: [selectors select: (selectors items indexOf: wasSelector)] ]
ClassBrowser >> classList [
    "The pane of the classes' names."
    ^classes ]
ClassBrowser >> selectorList [
    "The pane of the selected class's selectors."
    ^selectors ]
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
    "Takes the browser's keys: Ctrl-T toggles the class side, Ctrl-S
     accepts the source pane. Answers whether c was one of them."
    c value = 20 ifTrue: [meta := meta not. self showClass. ^true].
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
    self files do: [:lines | | i |
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
    "Answers the kernel's source files (the names in SourceFiles), as
     lines, read from /stratalk/ through fs the first time and kept; a file
     that cannot be read has none."
    files == nil ifTrue: [
        files := (Smalltalk at: #SourceFiles ifAbsent: [#()]) collect: [:n |
            [(File named: '/stratalk/' , n) contents lines] on: Error do: [:e | #()]]].
    ^files ]
