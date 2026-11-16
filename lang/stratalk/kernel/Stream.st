"Stream.st: streams over collections, and the standard output."

Object subclass: #Stream slots: ''.
Stream subclass: #PositionableStream slots: 'collection position readLimit'.
PositionableStream subclass: #ReadStream slots: ''.
PositionableStream subclass: #WriteStream slots: 'writeLimit'.
WriteStream subclass: #ReadWriteStream slots: ''.
Stream subclass: #StdioStream slots: 'buffer count handle'.

Stream >> next [ ^self subclassResponsibility ]
Stream >> nextPut: anObject [ ^self subclassResponsibility ]
Stream >> atEnd [ ^self subclassResponsibility ]
Stream >> nextPutAll: aCollection [ aCollection do: [:e | self nextPut: e]. ^aCollection ]
Stream >> do: aBlock [ [self atEnd] whileFalse: [aBlock value: self next] ]
Stream >> next: n [ | out | out := WriteStream on: (String new: n). n timesRepeat: [self atEnd ifFalse: [out nextPut: self next]]. ^out contents ]
Stream >> print: anObject [ anObject printOn: self ]
Stream >> display: anObject [ anObject displayOn: self ]
Stream >> << anObject [ anObject isString ifTrue: [self nextPutAll: anObject] ifFalse: [anObject displayOn: self] ]
Stream >> space [ self nextPut: Character space ]
Stream >> tab [ self nextPut: Character tab ]
Stream >> cr [ self nextPut: Character cr ]
Stream >> nl [ self nextPut: Character cr ]
Stream >> show: aString [ self nextPutAll: aString displayString ]
Stream >> showln: aString [ self nextPutAll: aString displayString; cr ]
Stream >> flush [ ^self ]

PositionableStream class >> on: aCollection [ ^self basicNew setCollection: aCollection ]
PositionableStream class >> on: aCollection from: start to: stop [
    ^(self on: (aCollection copyFrom: start to: stop)) ]
PositionableStream >> setCollection: aCollection [ collection := aCollection. position := 0. readLimit := aCollection size ]
PositionableStream >> atEnd [ ^position >= readLimit ]
PositionableStream >> next [
    position >= readLimit ifTrue: [^nil].
    position := position + 1.
    ^collection at: position ]
PositionableStream >> peek [ position >= readLimit ifTrue: [^nil]. ^collection at: position + 1 ]
PositionableStream >> peekFor: anObject [ self peek = anObject ifTrue: [self next. ^true]. ^false ]
PositionableStream >> skip: n [ position := (position + n max: 0) min: readLimit ]
PositionableStream >> position [ ^position ]
PositionableStream >> position: n [ position := n ]
PositionableStream >> reset [ position := 0 ]
PositionableStream >> skipSeparators [ [self atEnd not and: [self peek isSeparator]] whileTrue: [self next] ]
PositionableStream >> upTo: anObject [
    | out e |
    out := WriteStream on: (collection species new: 16).
    [self atEnd or: [(e := self next) = anObject]] whileFalse: [out nextPut: e].
    ^out contents ]
PositionableStream >> upToEnd [
    | out |
    out := WriteStream on: (collection species new: 16).
    [self atEnd] whileFalse: [out nextPut: self next].
    ^out contents ]
PositionableStream >> nextLine [ ^self upTo: Character cr ]
PositionableStream >> contents [ ^collection copyFrom: 1 to: readLimit ]
PositionableStream >> collection [ ^collection ]

WriteStream class >> on: aCollection [ ^self basicNew setCollection: aCollection; truncate ]
WriteStream class >> with: aCollection [ ^(self basicNew setCollection: aCollection) setToEnd ]
WriteStream >> setCollection: aCollection [ super setCollection: aCollection. writeLimit := aCollection size ]
WriteStream >> truncate [ readLimit := 0. position := 0 ]
WriteStream >> setToEnd [ position := readLimit := collection size ]
WriteStream >> nextPut: anObject [
    position >= writeLimit ifTrue: [self grow].
    position := position + 1.
    position > readLimit ifTrue: [readLimit := position].
    ^collection at: position put: anObject ]
WriteStream >> nextPutAll: aCollection [
    | n |
    (aCollection isString and: [collection isString]) ifFalse: [^super nextPutAll: aCollection].
    n := aCollection size.
    [position + n > writeLimit] whileTrue: [self grow].
    collection replaceFrom: position + 1 to: position + n with: aCollection startingAt: 1.
    position := position + n.
    position > readLimit ifTrue: [readLimit := position].
    ^aCollection ]
WriteStream >> grow [
    | new |
    new := collection species new: collection size * 2 + 16.
    new replaceFrom: 1 to: collection size with: collection startingAt: 1.
    collection := new.
    writeLimit := new size ]
WriteStream >> contents [ ^collection copyFrom: 1 to: position ]
WriteStream >> isEmpty [ ^position = 0 ]

ReadWriteStream >> contents [ ^collection copyFrom: 1 to: readLimit ]
ReadWriteStream >> next [
    position >= readLimit ifTrue: [^nil].
    position := position + 1.
    ^collection at: position ]

"---- the standard streams: the console or what the shell connected -------------"

StdioStream class >> handle: n [ ^self basicNew setHandle: n ]
StdioStream >> setHandle: n [ handle := n. buffer := String new: 512. count := 0 ]
StdioStream >> nextPut: aChar [
    count = buffer size ifTrue: [self flush].
    count := count + 1.
    buffer at: count put: aChar.
    aChar = Character cr ifTrue: [self flush].
    ^aChar ]
StdioStream >> nextPutAll: aString [
    | s |
    s := aString displayString.
    count + s size > buffer size ifTrue: [self flush].
    s size > buffer size ifTrue: [^self write: s].
    buffer replaceFrom: count + 1 to: count + s size with: s startingAt: 1.
    count := count + s size.
    (s includes: Character cr) ifTrue: [self flush].
    ^aString ]
StdioStream >> flush [
    count > 0 ifTrue: [self write: (buffer copyFrom: 1 to: count). count := 0] ]
StdioStream >> write: aString [ handle = 2 ifTrue: [Smalltalk stderr: aString] ifFalse: [Smalltalk stdout: aString] ]
StdioStream >> atEnd [ ^false ]
StdioStream >> nextLine [ self flush. ^Smalltalk readLine ]
