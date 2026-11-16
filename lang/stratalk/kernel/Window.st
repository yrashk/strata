"Window.st: a window of the window server (ws), through its messages
 (os/ws/ws.s; os/spec/ws.toml). The server draws: text in its 8 x 16
 font, and filled rectangles, into the window's surface, and shows them.
 A Window keeps the endpoint to ws in a register that standard input and
 output do not use while it is open: pipe's (4), or tty's (3) when they are
 pipes (in a terminal of ws), or fs's (2); closing gives it back."

Object subclass: #Window slots: 'server id width height title register'.
"A window of the window server, ws: a client's handle on one of the at
 most 4 tiles the server shows. Opening one looks ws up into a capability
 register that standard input and output do not use (pipe's, 4; else
 tty's, 3; else fs's, 2), whose own server is out of reach until it is
 closed; every draw is then a message to ws (TEXT, FILL, TITLE) and input
 comes as WindowEvents (EVENT). server is the Server endpoint, id the
 window's id (1..4) from CREATE, width and height the surface's size in
 pixels (kept up to date by resize events), title the name shown in its
 tag (8 bytes at most), register the capability register ws is in.
 Window rgb: 255 g: 0 b: 0 >>> 16711680"

Object subclass: #WindowEvent slots: 'kind value width height'.
"One event of a window, as ws's EVENT reply gives it: kind (1 key, 2
 resize, 3 close, 4 focus in, 5 focus out, 6 pointer, 7 wheel), value
 (a key's bytes, or the pointer's position, buttons and wheel packed in
 bits), and width and height (the surface's size now; for a key, width
 is the number of bytes). Made by Window nextEvent and pollEvent.
 (WindowEvent new setKind: 1 value: 26984 width: 2 height: 0) keys >>> 'hi'"

Window class >> opCreate [
    "The ws op that opens a window: CREATE, 40.
     Window opCreate >>> 40"
    ^40 ]
Window class >> opText [
    "The ws op that draws text: TEXT, 42.
     Window opText >>> 42"
    ^42 ]
Window class >> opFill [
    "The ws op that fills a rectangle: FILL, 43.
     Window opFill >>> 43"
    ^43 ]
Window class >> opEvent [
    "The ws op that waits for the window's next event: EVENT, 44.
     Window opEvent >>> 44"
    ^44 ]
Window class >> opDestroy [
    "The ws op that closes a window: DESTROY, 45.
     Window opDestroy >>> 45"
    ^45 ]
Window class >> opTitle [
    "The ws op that changes a window's title: TITLE, 46.
     Window opTitle >>> 46"
    ^46 ]
Window class >> cellWidth [
    "The width of a character cell of ws's text font, in pixels.
     Window cellWidth >>> 8"
    ^8 ]
Window class >> cellHeight [
    "The height of a character cell of ws's text font, in pixels.
     Window cellHeight >>> 16"
    ^16 ]
Window class >> rgb: r g: g b: b [
    "Answers the XRGB colour word of red r, green g and blue b (each
     0..255), as TEXT and FILL take it.
     Window rgb: 1 g: 2 b: 3 >>> 66051"
    ^((r bitShift: 16) + (g bitShift: 8)) + b ]
Window class >> open: aTitle [
    "Answers a new open Window titled aTitle (8 characters are shown). The
     tile the server gives it decides its size. See Window >> open:."
    ^self new open: aTitle ]

Window >> open: aTitle [
    "Opens the receiver as a window of ws and answers it. Looks ws up
     (proc LOOKUP 'ws') into the register Window freeRegister answers, then sends CREATE with
     the title in the request's data; the reply's result becomes the id and
     its two u64 fields the width and height. Signals an Error if there is
     no ws, or if ws refuses (4 windows open, the boot splash showing),
     giving the register back to its own server first. While the window is
     open the register is noted as lent (SystemDictionary >> lend:to:name:):
     a message to the register's own server (Db, pipe) puts it back for the
     message and ws again after it."
    | data r |
    register := Window freeRegister.
    server := Server named: 'ws' into: register.
    Smalltalk lend: register to: server name: 'ws'.
    data := ByteArray new: 24.
    data putTitle: aTitle at: 16.
    r := server request: Window opCreate handle: 0 mode: 0 data: data replySize: 16.
    r result <= 0 ifTrue: [self giveBack. ^Error new signal: 'ws refused the window'].
    id := r result.
    width := r u64At: 0.
    height := r u64At: 8.
    title := aTitle.
    ^self ]
Window >> id [
    "The window's id at ws (1..4), from CREATE."
    ^id ]
Window >> width [
    "The width of the window's surface in pixels, as of the last CREATE or
     resize event."
    ^width ]
Window >> height [
    "The height of the window's surface in pixels, as of the last CREATE
     or resize event."
    ^height ]
Window >> columns [
    "The number of whole character cells across the window."
    ^width // Window cellWidth ]
Window >> rows [
    "The number of whole character cells down the window."
    ^height // Window cellHeight ]
Window >> title: aString [
    "Sets the window's title to aString: sends ws TITLE with its first 8
     bytes (padded with zeros). The reply's result is not looked at."
    | data |
    title := aString.
    data := ByteArray new: 8.
    data putTitle: aString at: 0.
    server request: Window opTitle handle: id mode: 0 data: data replySize: 0 ]
Window >> fillX: x y: y width: w height: h color: c [
    "Fills the rectangle at pixel (x, y), w by h pixels, with colour c (an
     XRGB word, see Window rgb:g:b:): sends ws FILL with the five u64s.
     Answers the OSReply (result 0, or -1: no such window)."
    | data |
    data := ByteArray new: 40.
    data putU64: x at: 0; putU64: y at: 8; putU64: w at: 16; putU64: h at: 24; putU64: c at: 32.
    ^server request: Window opFill handle: id mode: 0 data: data replySize: 0 ]
Window >> clear: c [
    "Fills the whole window with colour c (ws FILL); answers the OSReply."
    ^self fillX: 0 y: 0 width: width height: height color: c ]
Window >> text: aString x: x y: y color: fg background: bg [
    "Draws aString with its top left corner at pixel (x, y), in colour fg
     on bg: sends ws TEXT (x, y, fg, bg as u64s, then the bytes). A bg of
     -1 draws over what is there. At most 160 characters are sent, the
     rest is cut. Answers the OSReply."
    | s data |
    s := aString size > 160 ifTrue: [aString copyFrom: 1 to: 160] ifFalse: [aString].
    data := ByteArray new: 32 + s size.
    data putU64: x at: 0; putU64: y at: 8; putU64: fg at: 16; putU64: (bg < 0 ifTrue: [(1 bitShift: 64) - 1] ifFalse: [bg]) at: 24.
    1 to: s size do: [:i | data at: 32 + i put: (s at: i) value \\ 256].
    ^server request: Window opText handle: id mode: 0 data: data replySize: 0 ]
Window >> text: aString column: c row: r color: fg background: bg [
    "Draws aString starting at character cell (c, r), both from 0, in
     colour fg on bg (ws TEXT, see text:x:y:color:background:)."
    ^self text: aString x: c * Window cellWidth y: r * Window cellHeight color: fg background: bg ]
Window >> nextEvent [
    "Answers the window's next WindowEvent, waiting for it as long as it
     takes (ws EVENT, no timeout)."
    ^self nextEventWait: 0 ]
Window >> pollEvent [
    "Answers the window's next WindowEvent if one is waiting, else nil:
     ws EVENT with mode bit 0, which does not block."
    ^self eventFrom: (server send: Window opEvent handle: id length: 0 mode: 1 data: nil) ]
Window >> nextEventWait: ticks [
    "Answers the window's next WindowEvent: ws EVENT with ticks as the
     timeout, in microseconds (0: wait as long as it takes). Answers nil
     when none came in that time."
    ^self eventFrom: (server send: Window opEvent handle: id length: ticks mode: 0 data: nil) ]
Window >> eventFrom: r [
    "Answers the WindowEvent of an EVENT reply r: its four u64 fields
     become the kind, value, width and height, and a resize updates the
     receiver's size. A result of -1 (the window is gone) answers a close
     event; any other error (no event, a timeout) answers nil."
    | e |
    r result = -1 ifTrue: [^WindowEvent new setKind: 3 value: 0 width: 0 height: 0].
    r result < 0 ifTrue: [^nil].
    e := WindowEvent new setKind: (r u64At: 0) value: (r u64At: 8) width: (r u64At: 16) height: (r u64At: 24).
    e isResize ifTrue: [width := e width. height := e height].
    ^e ]
Window >> close [
    "Closes the window (ws DESTROY) and gives the register back to its own
     server (giveBack)."
    server request: Window opDestroy handle: id mode: 0 data: nil replySize: 0.
    self giveBack ]
Window >> giveBack [
    "Looks the register's own server up into it again (proc LOOKUP of proc,
     fs, tty or pipe, for register 1 to 4), undoing what open: did."
    Smalltalk lentRegisters removeKey: register ifAbsent: [nil].
    Smalltalk osLookup: (OSServer ownServerOf: register) into: register ]
Window class >> freeRegister [
    "Answers a capability register that standard input, output and error do
     not use, for ws's endpoint: 4 (pipe's), else 3 (tty's, when they are
     pipes, as in a terminal of ws), else 2 (fs's)."
    | used |
    used := Smalltalk stdioRegisters.
    #(4 3 2) do: [:r | ((used bitShift: 0 - r) bitAnd: 1) = 0 ifTrue: [^r]].
    ^2 ]
SystemDictionary >> stdioRegisters [
    "Answers a bit mask of the capability registers that standard input,
     output and error are reached through (bit r for register r). A VM
     primitive (125); without it, tty's register 3."
    <primitive: 125> ^1 bitShift: 3 ]
Window >> printOn: aStream [
    "Writes 'a Window', the title and the size in pixels, as
     a Window 'workspc' 640x480."
    aStream nextPutAll: 'a Window '; print: title; space; print: width; nextPut: $x; print: height ]

WindowEvent >> setKind: k value: v width: w height: h [
    "Sets the four fields of the event, as an EVENT reply carries them;
     answers the receiver."
    kind := k. value := v. width := w. height := h ]
WindowEvent >> kind [
    "The event's kind: 1 key, 2 resize, 3 close, 4 focus in, 5 focus out,
     6 pointer, 7 wheel."
    ^kind ]
WindowEvent >> value [
    "The event's value word: a key's bytes (the first in the low byte), or
     the pointer's x, y, buttons and wheel packed in bits; 0 for the others."
    ^value ]
WindowEvent >> width [
    "The surface's width in pixels; for a key event, the number of bytes."
    ^width ]
WindowEvent >> height [
    "The surface's height in pixels."
    ^height ]
WindowEvent >> isKey [
    "Answers whether this is a key event (kind 1).
     (WindowEvent new setKind: 1 value: 97 width: 1 height: 0) isKey >>> true"
    ^kind = 1 ]
WindowEvent >> isResize [
    "Answers whether this is a resize event (kind 2): draw again at the
     new size."
    ^kind = 2 ]
WindowEvent >> isClose [
    "Answers whether this is a close event (kind 3: Alt+Q, or the window
     is gone)."
    ^kind = 3 ]
WindowEvent >> isPointer [
    "Answers whether this is a pointer event (kind 6): a press, a release,
     or a move with a button held."
    ^kind = 6 ]
WindowEvent >> isWheel [
    "Answers whether this is a wheel event (kind 7)."
    ^kind = 7 ]
WindowEvent >> keys [
    "Answers a key event's bytes as a String (up to 8, as a terminal
     would send them: an arrow is ESC [ A ...).
     (WindowEvent new setKind: 1 value: 26984 width: 2 height: 0) keys >>> 'hi'"
    | s v |
    s := WriteStream on: (String new: 8).
    v := value.
    width timesRepeat: [s nextPut: (Character value: (v bitAnd: 255)). v := v bitShift: -8].
    ^s contents ]
WindowEvent >> x [
    "The pointer's x in the surface, in pixels (bits 0-15 of the value).
     (WindowEvent new setKind: 6 value: 16r100500030 width: 0 height: 0) x >>> 48"
    ^value bitAnd: 65535 ]
WindowEvent >> y [
    "The pointer's y in the surface, in pixels (bits 16-31 of the value).
     (WindowEvent new setKind: 6 value: 16r100500030 width: 0 height: 0) y >>> 80"
    ^(value bitShift: -16) bitAnd: 65535 ]
WindowEvent >> buttons [
    "The pointer's buttons held, one bit each (bits 32-39 of the value).
     (WindowEvent new setKind: 6 value: 16r100500030 width: 0 height: 0) buttons >>> 1"
    ^(value bitShift: -32) bitAnd: 255 ]
WindowEvent >> wheel [
    "The wheel's vertical step, signed (bits 40-47 of the value): above 0
     away from the user.
     (WindowEvent new setKind: 7 value: 16rFF0000000000 width: 0 height: 0) wheel >>> -1"
    | d | d := (value bitShift: -40) bitAnd: 255. ^d > 127 ifTrue: [d - 256] ifFalse: [d] ]
WindowEvent >> printOn: aStream [
    "Writes the kind's name, then a key event's bytes or a pointer or
     wheel event's x@y.
     (WindowEvent new setKind: 6 value: 16r100500030 width: 0 height: 0) printString >>> 'pointer 48@80'"
    aStream nextPutAll: (#('key' 'size' 'close' 'focus' 'blur' 'pointer' 'wheel') at: kind ifAbsent: ['event']).
    self isKey ifTrue: [aStream space; print: self keys].
    (self isPointer or: [self isWheel]) ifTrue: [aStream space; print: self x; nextPut: $@; print: self y] ]

ByteArray >> putU64: v at: offset [
    "Stores v little-endian in the 8 bytes from offset (0-based) and
     answers the receiver. v is 0 .. 2^64 - 1, or negative (stored in
     two's complement). Signals an index error past the end.
     (ByteArray new: 8) putU64: 258 at: 0; yourself >>> #[2 1 0 0 0 0 0 0]"
    | x |
    x := v < 0 ifTrue: [v + (1 bitShift: 64)] ifFalse: [v].
    1 to: 8 do: [:i | self at: offset + i put: (x bitAnd: 255). x := x bitShift: -8] ]
ByteArray >> putTitle: aString at: offset [
    "Stores the first 8 characters of aString (at most) as bytes from
     offset (0-based), as ws takes a title; answers the receiver.
     (ByteArray new: 4) putTitle: 'ab' at: 1; yourself >>> #[0 97 98 0]"
    1 to: (aString size min: 8) do: [:i | self at: offset + i put: (aString at: i) value \\ 256] ]
