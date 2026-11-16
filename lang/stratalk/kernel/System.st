"System.st: Smalltalk (the globals, the VM), and Stratalk (start-up, the REPL)."

Object subclass: #Stratalk slots: ''.
Stratalk class slots: 'replFrame interactive'.
"The program, on the class side: the VM sends start to Stratalk when it
 has loaded the image, and start reads the arguments and runs the REPL, an
 expression or a file. replFrame is the frame an unhandled error goes back
 to (the REPL line or the file-in running), interactive whether the REPL
 prompts and edits lines on the console. It has no instances."

"---- Smalltalk: the global names, and the VM's services ------------------------"

SystemDictionary >> specialObjects [
    "Answers the VM's Array of special objects: the class table (at 3), the
     symbol table (at 12), the selectors the VM sends itself
     (mustBeBoolean, cannotReturn:, start...) and what start is sent to. A
     VM primitive (111).
     Smalltalk specialObjects class >>> Array"
    <primitive: 111> ]
SystemDictionary >> symbolTable [
    "Answers the table of the Symbols, an Array that asSymbol searches by
     hash so that each name has one Symbol.
     (Smalltalk symbolTable includes: #yourself) >>> true"
    ^self specialObjects at: 12 ]
SystemDictionary >> classTable [
    "Answers the class table, an Array: slot i + 1 holds the class (or
     metaclass) whose classIndex is i, as object headers name it.
     Smalltalk classTable class >>> Array"
    ^self specialObjects at: 3 ]
SystemDictionary >> noteNewSymbol [
    "Answers the receiver; asSymbol sends it after adding a Symbol to the
     table. Here it does nothing."
    ^self ]
SystemDictionary >> newClassIndex [
    "Answers the first free index in the class table, from 32 on (the first
     32 are the VM's); signals an Error if the table is full."
    | t |
    t := self classTable.
    33 to: t size do: [:i | (t at: i) == nil ifTrue: [^i - 1]].
    ^self error: 'no room for another class' ]
SystemDictionary >> registerClass: aClass [
    "Puts aClass in the class table at its classIndex."
    self classTable at: aClass classIndex + 1 put: aClass ]
SystemDictionary >> allClassesDo: aBlock [
    "Runs aBlock on each class of the class table (not the metaclasses), in
     the order of the table.
     | n | n := 0. Smalltalk allClassesDo: [:c | c == Object ifTrue: [n := n + 1]]. n >>> 1"
    self classTable do: [:c | (c notNil and: [c ~~ 0 and: [c isClass and: [c theNonMetaClass == c]]]) ifTrue: [aBlock value: c]] ]
SystemDictionary >> allClasses [
    "Answers an OrderedCollection of all the classes, sorted by name.
     Smalltalk allClasses first >>> Array"
    | out | out := OrderedCollection new. self allClassesDo: [:c | out add: c]. ^out sort: [:a :b | a name <= b name] ]
SystemDictionary >> at: key put: value [
    "Sets the global named key to value and answers value; signals an Error
     if key is not a Symbol.
     [Smalltalk at: 'x' put: 3] on: Error do: [:e | e messageText] >>> 'global names are symbols'"
    key isSymbol ifFalse: [^self error: 'global names are symbols'].
    ^super at: key put: value ]
SystemDictionary >> printOn: aStream [
    "Writes 'Smalltalk' on aStream.
     Smalltalk printString >>> 'Smalltalk'"
    aStream nextPutAll: 'Smalltalk' ]
SystemDictionary >> stdout: aString [
    "Writes the bytes of aString to standard output (handle 1), not through
     the Transcript's buffer. A VM primitive (100)."
    <primitive: 100> ]
SystemDictionary >> stderr: aString [
    "Writes the bytes of aString to standard error (handle 2). A VM
     primitive (110)."
    <primitive: 110> ]
SystemDictionary >> readLine [
    "Answers the next line of standard input as a String without its end, or
     nil at the end of the input; an empty String if the read is
     interrupted. A VM primitive (101)."
    "A line of standard input without its end, nil at the end" <primitive: 101> ]
SystemDictionary >> quit: anInteger [
    "Ends the program with the exit code anInteger, after flushing the
     Transcript and putting the console back in cooked mode."
    Transcript flush.
    self stdinIsConsole ifTrue: [self consoleMode: 0].
    self primQuit: anInteger ]
SystemDictionary >> primQuit: anInteger [
    "Ends the program at once with the exit code anInteger. A VM primitive
     (102)."
    <primitive: 102> ]
SystemDictionary >> quit [
    "Ends the program with the exit code 0."
    self quit: 0 ]
SystemDictionary >> arguments [
    "Answers the program's arguments after the VM's own options, an Array of
     Strings. A VM primitive (103).
     Smalltalk arguments class >>> Array"
    <primitive: 103> ]
SystemDictionary >> flushCaches [
    "Empties the VM's method and lookup caches, so that the next sends look
     their methods up again; needed after a method changes. Answers the
     receiver. A VM primitive (104)."
    <primitive: 104> ]
SystemDictionary >> vmStats [
    "Answers the VM's 16 counters, an Array of SmallIntegers in the order of
     VMStats names. A VM primitive (105).
     Smalltalk vmStats size >>> 16"
    <primitive: 105> ]
SystemDictionary >> scavenge [
    "Moves every live near object out of the nursery to the far heap, leaving
     the nursery empty, and answers the receiver. A VM primitive (106)."
    <primitive: 106> ]
SystemDictionary >> garbageCollect [
    "Scavenges, then marks and sweeps the far heap, making the dead objects'
     space free; answers the receiver. A VM primitive (107)."
    <primitive: 107> ]
SystemDictionary >> snapshot: aString [
    "Writes the far heap, after a scavenge, to the file named aString: an
     image the VM can start from. A VM primitive (108); signals an Error if
     the file cannot be written."
    <primitive: 108> ^self error: 'the snapshot could not be written' ]
SystemDictionary >> milliseconds [
    "Answers the clock in milliseconds, a SmallInteger, for measuring
     durations. A VM primitive (109).
     Smalltalk milliseconds class >>> SmallInteger"
    <primitive: 109> ]
SystemDictionary >> version [
    "Answers the name and version of the system.
     Smalltalk version >>> 'Stratalk 0.1'"
    ^'Stratalk 0.1' ]
SystemDictionary >> vm [
    "Answers a VMStats with the VM's counters as they are now; it prints one
     per line.
     Smalltalk vm class >>> VMStats"
    ^VMStats new ]

Object subclass: #VMStats slots: 'values'.
"The VM's counters at one moment, by name: sends, bytecodes, the far heap
 and its cache, the method and lookup caches, the collections. values is
 the Array from Smalltalk vmStats. Smalltalk vm makes one.
 (Smalltalk vm at: 'sends') > 0 >>> true"

VMStats >> initialize [
    "Reads the counters from the VM (Smalltalk vmStats)."
    values := Smalltalk vmStats ]
VMStats >> names [
    "Answers the names of the counters, in their order in values.
     Smalltalk vm names first >>> 'sends'"
    ^#('sends' 'bytecodes' 'far heap used' 'far cache hits' 'far cache misses' 'far reads (bytes)'
       'far writes (bytes)' 'method cache misses' 'lookup cache misses' 'scavenges' 'promoted (bytes)'
       'remembered' 'full collections' 'nursery (bytes)' 'far heap (bytes)' 'freed (bytes)') ]
VMStats >> at: aString [
    "Answers the counter named aString, one of names; signals NotFound for
     another name.
     (Smalltalk vm at: 'sends') isInteger >>> true"
    | i |
    i := self names indexOf: aString.
    i = 0 ifTrue: [^NotFound new signal: 'no VM counter named ' , aString printString].
    ^values at: i ]
VMStats >> printOn: aStream [
    "Writes each counter on aStream, its name, ': ' and its value, one a line."
    self names doWithIndex: [:n :i |
        i <= values size ifTrue: [
            aStream nextPutAll: n; nextPutAll: ': '; print: (values at: i); cr]] ]
VMStats >> flush [
    "Writes the far cache back and empties it, by a scavenge."
    "Write the far cache back and empty it" Smalltalk scavenge ]

"---- Stratalk: what the VM sends #start to -------------------------------------"

Stratalk class >> start [
    "Starts the program, as the VM's first send: sets the Transcript to
     standard output, resets the JIT (on with -j), then by the arguments:
     none, the interactive REPL; -e and an expression, prints its value; -,
     the REPL on standard input without a prompt; -w the Workspace; -b the
     ClassBrowser; else files in the named file, with the other arguments in
     the global Arguments (quitting with 1 if an unhandled error ended it)."
    | args |
    Smalltalk at: #Transcript put: (StdioStream handle: 1).
    args := Smalltalk arguments.
    Jit reset.
    (args notEmpty and: [args first = '-j']) ifTrue: [Jit on. args := args copyFrom: 2 to: args size].
    interactive := false.
    args isEmpty ifTrue: [interactive := true. self banner. ^self repl].
    (args first = '-e' and: [args size >= 2]) ifTrue: [
        self evaluateAndPrint: ((args copyFrom: 2 to: args size) inject: '' into: [:a :b | a isEmpty ifTrue: [b] ifFalse: [a, ' ', b]]).
        ^Smalltalk quit: 0].
    args first = '-' ifTrue: [^self repl].
    args first = '-w' ifTrue: [Workspace open. ^Smalltalk quit: 0].
    args first = '-b' ifTrue: [ClassBrowser open. ^Smalltalk quit: 0].
    self fileIn: args first arguments: (args copyFrom: 2 to: args size).
    "back here only when an unhandled error ended the file-in"
    Transcript flush.
    ^Smalltalk quit: 1 ]
Stratalk class >> banner [
    "Writes the version and how to leave to the Transcript, as the
     interactive REPL starts."
    Transcript showln: Smalltalk version, ': type an expression; "Smalltalk quit" or an end of input to leave' ]
Stratalk class >> repl [
    "Reads lines (with a LineEditor and the prompt st> when interactive, else
     plainly from standard input), evaluates each that is not blank and
     prints its value, until the end of the input; then quits with 0."
    | line editor |
    editor := interactive == true ifTrue: [LineEditor new] ifFalse: [nil].
    [editor == nil
        ifTrue: [
            interactive == true ifTrue: [Transcript show: 'st> '; flush].
            line := Smalltalk readLine]
        ifFalse: [line := editor readLine: 'st> '].
     line == nil] whileFalse: [
        line trimSeparators isEmpty ifFalse: [self evaluateLine: line]].
    interactive == true ifTrue: [Transcript cr].
    Smalltalk quit: 0 ]
Stratalk class >> evaluateLine: aString [
    "Evaluates and prints aString as a REPL line; its frame is where an
     unhandled error comes back to, ending the line."
    "Where an unhandled error comes back to."
    replFrame := Frame current.
    self evaluateAndPrint: aString.
    replFrame := nil ]
Stratalk class >> evaluateAndPrint: aString [
    "Compiles and runs the expression aString and writes its value's
     printString and a new line to the Transcript."
    | r |
    r := Compiler evaluate: aString.
    Transcript showln: r printString ]
Stratalk class >> fileIn: aName arguments: anArray [
    "Files in the source file aName, with anArray in the global Arguments,
     then quits with 0. An unhandled error comes back to this frame and ends
     the file-in (start then quits with 1)."
    replFrame := Frame current.
    Smalltalk at: #Arguments put: anArray.
    (File named: aName) fileIn.
    Transcript flush.
    Smalltalk quit: 0 ]
Stratalk class >> unhandled: anException [
    "Reports an exception no handler took (an Error's or a Halt's
     defaultAction): writes 'Error: ' and its text to standard error, with a
     backtrace when interactive, then returns to the REPL line or the
     file-in running, or quits with 1 if there is none."
    "An error no handler took: say so, then go back to the prompt."
    Transcript flush.
    Smalltalk stderr: 'Error: ', anException messageText, (String with: Character cr).
    interactive == true ifTrue: [
        | s | s := WriteStream on: (String new: 256).
        anException printBacktraceOn: s.
        Smalltalk stderr: s contents].
    replFrame == nil ifTrue: [Smalltalk quit: 1].
    Frame unwindTo: replFrame from: (Frame sender: Frame current).
    Frame return: nil to: replFrame ]
Stratalk class >> stackOverflow [
    "Signals StackOverflow. The VM sends this when a send would overflow the
     Smalltalk stack, dropping the send."
    ^StackOverflow new signal: 'the stack overflowed' ]
