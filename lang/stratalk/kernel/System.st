"System.st: Smalltalk (the globals, the VM), and Stratalk (start-up, the REPL)."

Object subclass: #Stratalk slots: ''.
Stratalk class slots: 'replFrame interactive'.

"---- Smalltalk: the global names, and the VM's services ------------------------"

SystemDictionary >> specialObjects [ <primitive: 111> ]
SystemDictionary >> symbolTable [ ^self specialObjects at: 12 ]
SystemDictionary >> classTable [ ^self specialObjects at: 3 ]
SystemDictionary >> noteNewSymbol [ ^self ]
SystemDictionary >> newClassIndex [
    | t |
    t := self classTable.
    33 to: t size do: [:i | (t at: i) == nil ifTrue: [^i - 1]].
    ^self error: 'no room for another class' ]
SystemDictionary >> registerClass: aClass [ self classTable at: aClass classIndex + 1 put: aClass ]
SystemDictionary >> allClassesDo: aBlock [
    self classTable do: [:c | (c notNil and: [c ~~ 0 and: [c isClass and: [c theNonMetaClass == c]]]) ifTrue: [aBlock value: c]] ]
SystemDictionary >> allClasses [ | out | out := OrderedCollection new. self allClassesDo: [:c | out add: c]. ^out sort: [:a :b | a name <= b name] ]
SystemDictionary >> at: key put: value [
    key isSymbol ifFalse: [^self error: 'global names are symbols'].
    ^super at: key put: value ]
SystemDictionary >> printOn: aStream [ aStream nextPutAll: 'Smalltalk' ]
SystemDictionary >> stdout: aString [ <primitive: 100> ]
SystemDictionary >> stderr: aString [ <primitive: 110> ]
SystemDictionary >> readLine [ "A line of standard input without its end, nil at the end" <primitive: 101> ]
SystemDictionary >> quit: anInteger [
    Transcript flush.
    self stdinIsConsole ifTrue: [self consoleMode: 0].
    self primQuit: anInteger ]
SystemDictionary >> primQuit: anInteger [ <primitive: 102> ]
SystemDictionary >> quit [ self quit: 0 ]
SystemDictionary >> arguments [ <primitive: 103> ]
SystemDictionary >> flushCaches [ <primitive: 104> ]
SystemDictionary >> vmStats [ <primitive: 105> ]
SystemDictionary >> scavenge [ <primitive: 106> ]
SystemDictionary >> garbageCollect [ <primitive: 107> ]
SystemDictionary >> snapshot: aString [ <primitive: 108> ^self error: 'the snapshot could not be written' ]
SystemDictionary >> milliseconds [ <primitive: 109> ]
SystemDictionary >> version [ ^'Stratalk 0.1' ]
SystemDictionary >> vm [ ^VMStats new ]

Object subclass: #VMStats slots: 'values'.
VMStats >> initialize [ values := Smalltalk vmStats ]
VMStats >> names [
    ^#('sends' 'bytecodes' 'far heap used' 'far cache hits' 'far cache misses' 'far reads (bytes)'
       'far writes (bytes)' 'method cache misses' 'lookup cache misses' 'scavenges' 'promoted (bytes)'
       'remembered' 'full collections' 'nursery (bytes)' 'far heap (bytes)' 'freed (bytes)') ]
VMStats >> at: aString [ ^values at: (self names indexOf: aString) ]
VMStats >> printOn: aStream [
    self names doWithIndex: [:n :i |
        i <= values size ifTrue: [
            aStream nextPutAll: n; nextPutAll: ': '; print: (values at: i); cr]] ]
VMStats >> flush [ "Write the far cache back and empty it" Smalltalk scavenge ]

"---- Stratalk: what the VM sends #start to -------------------------------------"

Stratalk class >> start [
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
    ^self fileIn: args first arguments: (args copyFrom: 2 to: args size) ]
Stratalk class >> banner [
    Transcript showln: Smalltalk version, ': type an expression; "Smalltalk quit" or an end of input to leave' ]
Stratalk class >> repl [
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
    "Where an unhandled error comes back to."
    replFrame := Frame current.
    self evaluateAndPrint: aString.
    replFrame := nil ]
Stratalk class >> evaluateAndPrint: aString [
    | r |
    r := Compiler evaluate: aString.
    Transcript showln: r printString ]
Stratalk class >> fileIn: aName arguments: anArray [
    replFrame := Frame current.
    Smalltalk at: #Arguments put: anArray.
    (File named: aName) fileIn.
    Transcript flush.
    Smalltalk quit: 0 ]
Stratalk class >> unhandled: anException [
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
Stratalk class >> stackOverflow [ ^StackOverflow new signal: 'the stack overflowed' ]
