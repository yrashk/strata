"Window.st: a window of the window server (ws), through its messages
 (os/ws/ws.s; os/spec/ws.toml). The server draws: text in its 8 x 16
 font, and filled rectangles, into the window's surface, and shows them.
 A Window keeps the endpoint to ws in register 4 while it is open
 (pipe's: files can still be read; closing gives it back)."

Object subclass: #Window slots: 'server id width height title'.
Object subclass: #WindowEvent slots: 'kind value width height'.

Window class >> opCreate [ ^40 ]
Window class >> opText [ ^42 ]
Window class >> opFill [ ^43 ]
Window class >> opEvent [ ^44 ]
Window class >> opDestroy [ ^45 ]
Window class >> opTitle [ ^46 ]
Window class >> cellWidth [ ^8 ]
Window class >> cellHeight [ ^16 ]
Window class >> rgb: r g: g b: b [ ^((r bitShift: 16) + (g bitShift: 8)) + b ]
Window class >> open: aTitle [
    "A window: the tile the server gives it decides its size."
    ^self new open: aTitle ]

Window >> open: aTitle [
    | data r |
    server := Server named: 'ws' into: 4.
    data := ByteArray new: 24.
    data putTitle: aTitle at: 16.
    r := server request: Window opCreate handle: 0 mode: 0 data: data replySize: 16.
    r result <= 0 ifTrue: [Server restorePipe. ^Error new signal: 'ws refused the window'].
    id := r result.
    width := r u64At: 0.
    height := r u64At: 8.
    title := aTitle.
    ^self ]
Window >> id [ ^id ]
Window >> width [ ^width ]
Window >> height [ ^height ]
Window >> columns [ ^width // Window cellWidth ]
Window >> rows [ ^height // Window cellHeight ]
Window >> title: aString [
    | data |
    title := aString.
    data := ByteArray new: 8.
    data putTitle: aString at: 0.
    server request: Window opTitle handle: id mode: 0 data: data replySize: 0 ]
Window >> fillX: x y: y width: w height: h color: c [
    | data |
    data := ByteArray new: 40.
    data putU64: x at: 0; putU64: y at: 8; putU64: w at: 16; putU64: h at: 24; putU64: c at: 32.
    ^server request: Window opFill handle: id mode: 0 data: data replySize: 0 ]
Window >> clear: c [ ^self fillX: 0 y: 0 width: width height: height color: c ]
Window >> text: aString x: x y: y color: fg background: bg [
    "aString at pixel (x, y); bg -1: drawn over what is there."
    | s data |
    s := aString size > 160 ifTrue: [aString copyFrom: 1 to: 160] ifFalse: [aString].
    data := ByteArray new: 32 + s size.
    data putU64: x at: 0; putU64: y at: 8; putU64: fg at: 16; putU64: (bg < 0 ifTrue: [(1 bitShift: 64) - 1] ifFalse: [bg]) at: 24.
    1 to: s size do: [:i | data at: 32 + i put: (s at: i) value \\ 256].
    ^server request: Window opText handle: id mode: 0 data: data replySize: 0 ]
Window >> text: aString column: c row: r color: fg background: bg [
    ^self text: aString x: c * Window cellWidth y: r * Window cellHeight color: fg background: bg ]
Window >> nextEvent [ ^self nextEventWait: 0 ]
Window >> pollEvent [
    "An event if one is waiting, else nil."
    ^self eventFrom: (server send: Window opEvent handle: id length: 0 mode: 1 data: nil) ]
Window >> nextEventWait: ticks [
    "The next event; ticks > 0: nil when none came in that many microseconds."
    ^self eventFrom: (server send: Window opEvent handle: id length: ticks mode: 0 data: nil) ]
Window >> eventFrom: r [
    | e |
    r result = -1 ifTrue: [^WindowEvent new setKind: 3 value: 0 width: 0 height: 0].
    r result < 0 ifTrue: [^nil].
    e := WindowEvent new setKind: (r u64At: 0) value: (r u64At: 8) width: (r u64At: 16) height: (r u64At: 24).
    e isResize ifTrue: [width := e width. height := e height].
    ^e ]
Window >> close [
    server request: Window opDestroy handle: id mode: 0 data: nil replySize: 0.
    Server restorePipe ]
Window >> printOn: aStream [ aStream nextPutAll: 'a Window '; print: title; space; print: width; nextPut: $x; print: height ]

WindowEvent >> setKind: k value: v width: w height: h [ kind := k. value := v. width := w. height := h ]
WindowEvent >> kind [ ^kind ]
WindowEvent >> value [ ^value ]
WindowEvent >> width [ ^width ]
WindowEvent >> height [ ^height ]
WindowEvent >> isKey [ ^kind = 1 ]
WindowEvent >> isResize [ ^kind = 2 ]
WindowEvent >> isClose [ ^kind = 3 ]
WindowEvent >> isPointer [ ^kind = 6 ]
WindowEvent >> isWheel [ ^kind = 7 ]
WindowEvent >> keys [
    "A key event's bytes (up to 8, as a terminal would send them)."
    | s v |
    s := WriteStream on: (String new: 8).
    v := value.
    width timesRepeat: [s nextPut: (Character value: (v bitAnd: 255)). v := v bitShift: -8].
    ^s contents ]
WindowEvent >> x [ ^value bitAnd: 65535 ]
WindowEvent >> y [ ^(value bitShift: -16) bitAnd: 65535 ]
WindowEvent >> buttons [ ^(value bitShift: -32) bitAnd: 255 ]
WindowEvent >> wheel [ | d | d := (value bitShift: -40) bitAnd: 255. ^d > 127 ifTrue: [d - 256] ifFalse: [d] ]
WindowEvent >> printOn: aStream [
    aStream nextPutAll: (#('key' 'size' 'close' 'focus' 'blur' 'pointer' 'wheel') at: kind ifAbsent: ['event']).
    self isKey ifTrue: [aStream space; print: self keys].
    (self isPointer or: [self isWheel]) ifTrue: [aStream space; print: self x; nextPut: $@; print: self y] ]

ByteArray >> putU64: v at: offset [
    "v (0 .. 2^64 - 1, or negative: two's complement), little-endian at offset (0-based)."
    | x |
    x := v < 0 ifTrue: [v + (1 bitShift: 64)] ifFalse: [v].
    1 to: 8 do: [:i | self at: offset + i put: (x bitAnd: 255). x := x bitShift: -8] ]
ByteArray >> putTitle: aString at: offset [
    1 to: (aString size min: 8) do: [:i | self at: offset + i put: (aString at: i) value \\ 256] ]
