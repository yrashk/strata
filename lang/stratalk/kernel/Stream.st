"Stream.st: streams over collections, and the standard output."

Object subclass: #Stream slots: ''.
"Something that gives or takes elements one at a time: next, nextPut:,
 atEnd. A subclass defines those three; Stream adds writing several
 elements, printing and displaying objects (print:, <<), loops over what
 is left (do:) and the separators (space, tab, cr). No slots.
 (ReadStream on: #(1 2 3)) next >>> 1"

Stream subclass: #PositionableStream slots: 'collection position readLimit'.
"A stream over a sequenceable collection (a String, an Array...), with a
 position that can be read and moved: peeking, skipping, reading up to an
 element or a line. collection is what is streamed over; position is the
 number of elements already read (0 at the start); readLimit is how many
 there are to read.
 (ReadStream on: 'key=value') upTo: $= >>> 'key'"

PositionableStream subclass: #ReadStream slots: ''.
"A PositionableStream that only reads: made with on: (or on:from:to:)
 over a collection, it answers its elements in order, then nil. No slots
 of its own.
 (ReadStream on: 'hello') next: 3 >>> 'hel'"

PositionableStream subclass: #WriteStream slots: 'writeLimit'.
"A PositionableStream that builds a collection: nextPut: and nextPutAll:
 write at the position, growing the collection (twice its size and 16)
 when it is full; contents answers what was written. on: starts empty
 (whatever the collection held is overwritten), with: starts after the
 collection's elements. writeLimit is the size of the collection, where
 it has to grow.
 | w | w := WriteStream on: String new. w << 'x = ' << 3. w contents >>> 'x = 3'"

WriteStream subclass: #ReadWriteStream slots: ''.
"A WriteStream that can also be read back: after reset (or position:) next
 answers what was written, and contents answers everything written, not
 only up to the position. No slots of its own.
 | w | w := ReadWriteStream on: String new. w nextPutAll: 'abc'. w reset. w next >>> $a"

Stream subclass: #StdioStream slots: 'buffer count handle'.
"A write stream on standard output (handle 1) or standard error (handle
 2): the console's tty, or what the shell connected (a pipe, a file).
 Transcript is the one on handle 1. Characters are kept in buffer (512
 bytes; count of them are used) and written with the VM's stdout: or
 stderr: primitive (100, 110: a WRITE on the handle) when a line ends,
 when the buffer is full or on flush. nextLine reads a line of standard
 input."

Stream >> next [
    "Answers the next element and moves past it. Each subclass defines it."
    ^self subclassResponsibility ]
Stream >> nextPut: anObject [
    "Writes anObject as the next element and answers it. Each subclass
     defines it."
    ^self subclassResponsibility ]
Stream >> atEnd [
    "Answers whether there is nothing more to read. Each subclass defines it."
    ^self subclassResponsibility ]
Stream >> nextPutAll: aCollection [
    "Writes each element of aCollection, in order; answers aCollection.
     | w | w := WriteStream on: Array new. w nextPutAll: #(1 2). w contents >>> #(1 2)"
    aCollection do: [:e | self nextPut: e]. ^aCollection ]
Stream >> do: aBlock [
    "Runs aBlock with each element left to read, up to the end.
     | s n | s := ReadStream on: #(1 2 3). n := 0. s do: [:e | n := n + e]. n >>> 6"
    [self atEnd] whileFalse: [aBlock value: self next] ]
Stream >> next: n [
    "Answers a String of the next n elements, or of those left if fewer. The
     elements must be characters.
     (ReadStream on: 'hi') next: 5 >>> 'hi'"
    | out | out := WriteStream on: (String new: n). n timesRepeat: [self atEnd ifFalse: [out nextPut: self next]]. ^out contents ]
Stream >> print: anObject [
    "Writes anObject's printString (printOn:) on the receiver.
     | w | w := WriteStream on: String new. w print: 'a'. w contents >>> '''a'''"
    anObject printOn: self ]
Stream >> display: anObject [
    "Writes anObject's displayString (displayOn:) on the receiver: a string
     without its quotes.
     | w | w := WriteStream on: String new. w display: 'a'. w contents >>> 'a'"
    anObject displayOn: self ]
Stream >> << anObject [
    "Writes a string as it is, anything else as it is displayed; answers the
     receiver, so << can be chained.
     | w | w := WriteStream on: String new. w << 'x = ' << 3. w contents >>> 'x = 3'"
    anObject isString ifTrue: [self nextPutAll: anObject] ifFalse: [anObject displayOn: self] ]
Stream >> space [
    "Writes a space.
     | w | w := WriteStream on: String new. w nextPut: $a; space; nextPut: $b. w contents >>> 'a b'"
    self nextPut: Character space ]
Stream >> tab [
    "Writes a tab.
     | w | w := WriteStream on: String new. w tab. w contents first value >>> 9"
    self nextPut: Character tab ]
Stream >> cr [
    "Writes the end of a line, a line feed (10).
     | w | w := WriteStream on: String new. w cr. w contents first value >>> 10"
    self nextPut: Character cr ]
Stream >> nl [
    "Writes the end of a line, as cr.
     | w | w := WriteStream on: String new. w nl. w contents first value >>> 10"
    self nextPut: Character cr ]
Stream >> show: aString [
    "Writes aString's displayString; any object can be shown.
     | w | w := WriteStream on: String new. w show: 42. w contents >>> '42'"
    self nextPutAll: aString displayString ]
Stream >> showln: aString [
    "Writes aString's displayString and the end of a line.
     | w | w := WriteStream on: String new. w showln: 'a'. w contents size >>> 2"
    self nextPutAll: aString displayString; cr ]
Stream >> flush [
    "Writes out what is buffered; nothing for a stream with no buffer.
     Answers the receiver."
    ^self ]

PositionableStream class >> on: aCollection [
    "Answers a stream over aCollection, at its start.
     (ReadStream on: #(1 2 3)) next >>> 1"
    ^self basicNew setCollection: aCollection ]
PositionableStream class >> on: aCollection from: start to: stop [
    "Answers a stream over a copy of the elements start to stop of aCollection.
     (ReadStream on: 'abcdef' from: 2 to: 4) upToEnd >>> 'bcd'"
    ^(self on: (aCollection copyFrom: start to: stop)) ]
PositionableStream >> setCollection: aCollection [
    "Streams over aCollection from its start, to its size."
    collection := aCollection. position := 0. readLimit := aCollection size ]
PositionableStream >> atEnd [
    "Answers whether every element has been read.
     (ReadStream on: #()) atEnd >>> true"
    ^position >= readLimit ]
PositionableStream >> next [
    "Answers the next element and moves past it; nil at the end.
     (ReadStream on: 'ab') next; next; next >>> nil"
    position >= readLimit ifTrue: [^nil].
    position := position + 1.
    ^collection at: position ]
PositionableStream >> peek [
    "Answers the next element without moving past it; nil at the end.
     | s | s := ReadStream on: 'ab'. s peek >>> $a"
    position >= readLimit ifTrue: [^nil]. ^collection at: position + 1 ]
PositionableStream >> peekFor: anObject [
    "Answers whether the next element is equal to anObject, and moves past
     it if it is.
     | s | s := ReadStream on: 'ab'. (s peekFor: $a) -> s next >>> true->$b"
    self peek = anObject ifTrue: [self next. ^true]. ^false ]
PositionableStream >> skip: n [
    "Moves the position n elements on (back if n is negative), kept between
     the start and the end.
     | s | s := ReadStream on: 'abcdef'. s skip: 2. s next >>> $c"
    position := (position + n max: 0) min: readLimit ]
PositionableStream >> position [
    "The number of elements read (or written) so far; 0 at the start.
     | s | s := ReadStream on: 'abc'. s next. s position >>> 1"
    ^position ]
PositionableStream >> position: n [
    "Sets the position to n: the next element read is element n + 1. n is
     not checked.
     | s | s := ReadStream on: 'abcd'. s position: 2. s next >>> $c"
    position := n ]
PositionableStream >> reset [
    "Moves the position back to the start.
     | s | s := ReadStream on: 'abc'. s next; next. s reset. s next >>> $a"
    position := 0 ]
PositionableStream >> skipSeparators [
    "Moves past the white space (isSeparator) at the position.
     | s | s := ReadStream on: '   x'. s skipSeparators. s next >>> $x"
    [self atEnd not and: [self peek isSeparator]] whileTrue: [self next] ]
PositionableStream >> upTo: anObject [
    "Answers the elements up to the next one equal to anObject, not
     including it, and moves past that one; everything left if there is
     none. A collection like the one streamed over.
     (ReadStream on: #(1 2 3 4)) upTo: 3 >>> #(1 2)"
    | out e |
    out := WriteStream on: (collection species new: 16).
    [self atEnd or: [(e := self next) = anObject]] whileFalse: [out nextPut: e].
    ^out contents ]
PositionableStream >> upToEnd [
    "Answers the elements left, up to the end, and moves to the end.
     | s | s := ReadStream on: 'key=value'. s upTo: $=. s upToEnd >>> 'value'"
    | out |
    out := WriteStream on: (collection species new: 16).
    [self atEnd] whileFalse: [out nextPut: self next].
    ^out contents ]
PositionableStream >> nextLine [
    "Answers the characters up to the end of the line (a line feed), without
     it, and moves past it.
     | s | s := ReadStream on: 'one', (String with: Character cr), 'two'. s nextLine >>> 'one'"
    ^self upTo: Character cr ]
PositionableStream >> contents [
    "Answers a copy of all the elements to read, wherever the position is.
     | s | s := ReadStream on: 'abc'. s next. s contents >>> 'abc'"
    ^collection copyFrom: 1 to: readLimit ]
PositionableStream >> collection [
    "The collection streamed over itself, not a copy (for a WriteStream it
     may be longer than what was written).
     (ReadStream on: 'abc') collection >>> 'abc'"
    ^collection ]

WriteStream class >> on: aCollection [
    "Answers a stream that writes into aCollection from its start, empty:
     aCollection is a first buffer (grown, replaced by a bigger copy when full).
     (WriteStream on: (String new: 10)) contents >>> ''"
    ^self basicNew setCollection: aCollection; truncate ]
WriteStream class >> with: aCollection [
    "Answers a stream that writes after the elements of aCollection, which
     its contents begin with.
     | w | w := WriteStream with: 'abc'. w nextPutAll: 'de'. w contents >>> 'abcde'"
    ^(self basicNew setCollection: aCollection) setToEnd ]
WriteStream >> setCollection: aCollection [
    "Streams over aCollection; it can be written up to its size before it grows."
    super setCollection: aCollection. writeLimit := aCollection size ]
WriteStream >> truncate [
    "Empties the stream: nothing written, the position at the start.
     | w | w := WriteStream on: String new. w nextPutAll: 'abc'. w truncate. w contents >>> ''"
    readLimit := 0. position := 0 ]
WriteStream >> setToEnd [
    "Moves the position to the end of the collection, its whole size: after
     with:, past its elements. After writing it moves past the unused room of
     the grown collection too, not to the end of what was written."
    position := readLimit := collection size ]
WriteStream >> nextPut: anObject [
    "Writes anObject at the position, growing the collection if it is full,
     and answers anObject.
     | w | w := WriteStream on: String new. w nextPut: $a; nextPut: $b. w contents >>> 'ab'"
    position >= writeLimit ifTrue: [self grow].
    position := position + 1.
    position > readLimit ifTrue: [readLimit := position].
    ^collection at: position put: anObject ]
WriteStream >> nextPutAll: aCollection [
    "Writes the elements of aCollection and answers it. A string into a
     string is copied at once (replaceFrom:to:with:startingAt:), growing as
     needed; anything else goes element by element.
     | w | w := WriteStream on: String new. w nextPutAll: 'abc' >>> 'abc'"
    | n |
    (aCollection isString and: [collection isString]) ifFalse: [^super nextPutAll: aCollection].
    n := aCollection size.
    [position + n > writeLimit] whileTrue: [self grow].
    collection replaceFrom: position + 1 to: position + n with: aCollection startingAt: 1.
    position := position + n.
    position > readLimit ifTrue: [readLimit := position].
    ^aCollection ]
WriteStream >> grow [
    "Replaces the collection by a copy twice its size and 16 more.
     | w | w := WriteStream on: (String new: 0). w grow. w collection size >>> 16"
    | new |
    new := collection species new: collection size * 2 + 16.
    new replaceFrom: 1 to: collection size with: collection startingAt: 1.
    collection := new.
    writeLimit := new size ]
WriteStream >> contents [
    "Answers a copy of what was written, up to the position.
     | w | w := WriteStream on: String new. w nextPutAll: 'abcd'. w position: 2. w contents >>> 'ab'"
    ^collection copyFrom: 1 to: position ]
WriteStream >> isEmpty [
    "Answers whether the position is at the start: nothing written yet.
     (WriteStream on: String new) isEmpty >>> true"
    ^position = 0 ]

ReadWriteStream >> contents [
    "Answers a copy of everything written, whatever the position.
     | w | w := ReadWriteStream on: String new. w nextPutAll: 'abcd'. w position: 2. w contents >>> 'abcd'"
    ^collection copyFrom: 1 to: readLimit ]
ReadWriteStream >> next [
    "Answers the next element written and moves past it; nil at the end of
     what was written.
     | w | w := ReadWriteStream with: 'abc'. w reset. w upToEnd >>> 'abc'"
    position >= readLimit ifTrue: [^nil].
    position := position + 1.
    ^collection at: position ]

"---- the standard streams: the console or what the shell connected -------------"

StdioStream class >> handle: n [
    "Answers a stream on the process's handle n: 1 standard output, 2
     standard error."
    ^self basicNew setHandle: n ]
StdioStream >> setHandle: n [
    "Writes on handle n, with an empty buffer of 512 characters."
    handle := n. buffer := String new: 512. count := 0 ]
StdioStream >> nextPut: aChar [
    "Adds aChar to the buffer and answers it; writes the buffer out when it
     is full and after the end of a line."
    count = buffer size ifTrue: [self flush].
    count := count + 1.
    buffer at: count put: aChar.
    aChar = Character cr ifTrue: [self flush].
    ^aChar ]
StdioStream >> nextPutAll: aString [
    "Adds aString's displayString to the buffer and answers aString; writes
     the buffer out if aString does not fit or holds the end of a line. A
     string longer than the buffer is written at once."
    | s |
    s := aString displayString.
    count + s size > buffer size ifTrue: [self flush].
    s size > buffer size ifTrue: [^self write: s].
    buffer replaceFrom: count + 1 to: count + s size with: s startingAt: 1.
    count := count + s size.
    (s includes: Character cr) ifTrue: [self flush].
    ^aString ]
StdioStream >> flush [
    "Writes out what is in the buffer, if anything, and empties it."
    count > 0 ifTrue: [self write: (buffer copyFrom: 1 to: count). count := 0] ]
StdioStream >> write: aString [
    "Writes aString on the handle now, unbuffered: Smalltalk stderr: for
     handle 2, stdout: otherwise (VM primitives 110 and 100, a WRITE on the
     process's handle)."
    handle = 2 ifTrue: [Smalltalk stderr: aString] ifFalse: [Smalltalk stdout: aString] ]
StdioStream >> atEnd [
    "Answers false: an output stream has no end."
    ^false ]
StdioStream >> nextLine [
    "Answers the next line of standard input, without its end, or nil at
     the end of the input; flushes the output first, so a prompt shows.
     Smalltalk readLine: VM primitive 101."
    self flush. ^Smalltalk readLine ]
