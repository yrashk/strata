"Object.st: the root of the classes, nil, the booleans, and classes themselves."

nil subclass: #Object slots: ''.
Object subclass: #UndefinedObject slots: ''.
Object subclass: #Boolean slots: ''.
Boolean subclass: #True slots: ''.
Boolean subclass: #False slots: ''.
Object subclass: #Behavior slots: 'superclass methodDict format classIndex'.
Behavior subclass: #ClassDescription slots: ''.
ClassDescription subclass: #Class slots: 'name instVarNames'.
ClassDescription subclass: #Metaclass slots: 'thisClass instVarNames'.
Object subclass: #Message slots: 'selector arguments'.
Object subclass: #Frame slots: ''.

"---- Object ----------------------------------------------------------------"

Object >> == anObject [ <primitive: 40> ]
Object >> ~~ anObject [ ^(self == anObject) not ]
Object >> = anObject [ ^self == anObject ]
Object >> ~= anObject [ ^(self = anObject) not ]
Object >> hash [ ^self identityHash ]
Object >> identityHash [ <primitive: 42> ]
Object >> class [ <primitive: 41> ]
Object >> yourself [ ^self ]
Object >> isNil [ ^false ]
Object >> notNil [ ^true ]
Object >> isString [ ^false ]
Object >> isSymbol [ ^false ]
Object >> isNumber [ ^false ]
Object >> isInteger [ ^false ]
Object >> isCharacter [ ^false ]
Object >> isArray [ ^false ]
Object >> isBlock [ ^false ]
Object >> isClass [ ^false ]
Object >> isCollection [ ^false ]
Object >> isKindOf: aClass [
    | c |
    c := self class.
    [c == nil] whileFalse: [c == aClass ifTrue: [^true]. c := c superclass].
    ^false ]
Object >> isMemberOf: aClass [ ^self class == aClass ]
Object >> respondsTo: aSymbol [ ^(self class lookupSelector: aSymbol) notNil ]
Object >> ifNil: aBlock [ ^self ]
Object >> ifNotNil: aBlock [ ^aBlock cull: self ]
Object >> ifNil: nilBlock ifNotNil: aBlock [ ^aBlock cull: self ]
Object >> ifNotNil: aBlock ifNil: nilBlock [ ^aBlock cull: self ]
Object >> -> anObject [ ^Association key: self value: anObject ]
Object >> value [ ^self ]
Object >> isNear [ "True while the object is in the core's nursery" <primitive: 53> ]

Object >> basicSize [ <primitive: 43> ]
Object >> size [ ^self basicSize ]
Object >> basicAt: index [ <primitive: 44> ^self indexError: index ]
Object >> basicAt: index put: anObject [ <primitive: 45> ^self indexError: index ]
Object >> at: index [ <primitive: 44> ^self indexError: index ]
Object >> at: index put: anObject [ <primitive: 45> ^self indexError: index ]
Object >> instVarAt: index [ <primitive: 49> ^self indexError: index ]
Object >> instVarAt: index put: anObject [ <primitive: 50> ^self indexError: index ]
Object >> indexError: index [
    self isImmutable ifTrue: [^self error: 'this object cannot be changed'].
    index isInteger ifFalse: [^self error: 'an index must be an integer'].
    ^SubscriptOutOfBounds new signal: 'index ', index printString, ' is out of bounds' ]
Object >> isImmutable [ <primitive: 55> ]
Object >> beImmutable [ <primitive: 56> ]
Object >> shallowCopy [ <primitive: 48> ]
Object >> copy [ ^self shallowCopy postCopy ]
Object >> postCopy [ ^self ]
Object >> deepCopy [
    | c |
    c := self shallowCopy.
    1 to: self class instSize do: [:i | c instVarAt: i put: (self instVarAt: i) copy].
    ^c ]

Object >> perform: aSymbol [ <primitive: 51> ^self error: 'perform: needs a Symbol' ]
Object >> perform: aSymbol with: a [ <primitive: 51> ^self perform: aSymbol withArguments: {a} ]
Object >> perform: aSymbol with: a with: b [ <primitive: 51> ^self perform: aSymbol withArguments: {a. b} ]
Object >> perform: aSymbol with: a with: b with: c [
    <primitive: 51> ^self perform: aSymbol withArguments: {a. b. c} ]
Object >> perform: aSymbol withArguments: anArray [
    <primitive: 52>
    ^self error: 'perform: with the wrong number of arguments' ]

Object >> error: aString [ ^Error new signal: aString ]
Object >> halt [ ^Halt new signal: 'halt' ]
Object >> doesNotUnderstand: aMessage [
    ^MessageNotUnderstood new message: aMessage receiver: self; signal ]
Object >> subclassResponsibility [ ^self error: 'a subclass should have implemented this' ]
Object >> shouldNotImplement [ ^self error: 'this message is not appropriate here' ]
Object >> mustBeBoolean [ ^NonBooleanReceiver new signal: self printString, ' is not a Boolean' ]
Object >> assert: aBlock [ aBlock value ifFalse: [^AssertionFailure new signal: 'assertion failed'] ]

Object >> printOn: aStream [
    | n |
    n := self class name.
    aStream nextPutAll: ((n first isVowel) ifTrue: ['an '] ifFalse: ['a ']); nextPutAll: n ]
Object >> displayOn: aStream [ self printOn: aStream ]
Object >> printString [
    | s |
    s := WriteStream on: (String new: 16).
    self printOn: s.
    ^s contents ]
Object >> displayString [
    | s |
    s := WriteStream on: (String new: 16).
    self displayOn: s.
    ^s contents ]
Object >> printNl [ Transcript showln: self printString ]
Object >> displayNl [ Transcript showln: self displayString ]
Object >> storeString [ ^self printString ]

"---- nil ----------------------------------------------------------------------"

UndefinedObject >> isNil [ ^true ]
UndefinedObject >> notNil [ ^false ]
UndefinedObject >> ifNil: aBlock [ ^aBlock value ]
UndefinedObject >> ifNotNil: aBlock [ ^nil ]
UndefinedObject >> ifNil: nilBlock ifNotNil: aBlock [ ^nilBlock value ]
UndefinedObject >> ifNotNil: aBlock ifNil: nilBlock [ ^nilBlock value ]
UndefinedObject >> printOn: aStream [ aStream nextPutAll: 'nil' ]
UndefinedObject >> subclass: aSymbol slots: aString [
    ^Class new: aSymbol super: nil slots: aString format: 0 ]

"---- the booleans ------------------------------------------------------------"

Boolean >> printOn: aStream [ aStream nextPutAll: self printString ]
Boolean >> | aBoolean [ ^self or: [aBoolean] ]
Boolean >> & aBoolean [ ^self and: [aBoolean] ]
True >> printString [ ^'true' ]
True >> not [ ^false ]
True >> ifTrue: aBlock [ ^aBlock value ]
True >> ifFalse: aBlock [ ^nil ]
True >> ifTrue: t ifFalse: f [ ^t value ]
True >> ifFalse: f ifTrue: t [ ^t value ]
True >> and: aBlock [ ^aBlock value ]
True >> or: aBlock [ ^true ]
True >> xor: aBoolean [ ^aBoolean not ]
False >> printString [ ^'false' ]
False >> not [ ^true ]
False >> ifTrue: aBlock [ ^nil ]
False >> ifFalse: aBlock [ ^aBlock value ]
False >> ifTrue: t ifFalse: f [ ^f value ]
False >> ifFalse: f ifTrue: t [ ^f value ]
False >> and: aBlock [ ^false ]
False >> or: aBlock [ ^aBlock value ]
False >> xor: aBoolean [ ^aBoolean ]

"---- classes --------------------------------------------------------------------"

Behavior >> superclass [ ^superclass ]
Behavior >> methodDict [ ^methodDict ]
Behavior >> classIndex [ ^classIndex ]
Behavior >> instSize [ ^format bitAnd: 65535 ]
Behavior >> instanceFormat [ ^format bitShift: -16 ]
Behavior >> isVariable [ ^self instanceFormat ~= 0 ]
Behavior >> isClass [ ^true ]
Behavior >> basicNew [ <primitive: 46> ^self error: 'this class needs new:' ]
Behavior >> basicNew: n [ <primitive: 47> ^self error: 'this class cannot have indexed instances' ]
Behavior >> basicNewFar: n [ "Made directly in far memory: never moved" <primitive: 54> ^self basicNew: n ]
Behavior >> new [ ^self basicNew initialize ]
Behavior >> new: n [ ^(self basicNew: n) initialize ]
Object >> initialize [ ^self ]
Behavior >> lookupSelector: aSymbol [
    | c m |
    c := self.
    [c == nil] whileFalse: [
        m := c methodDict at: aSymbol ifAbsent: [nil].
        m == nil ifFalse: [^m].
        c := c superclass].
    ^nil ]
Behavior >> includesSelector: aSymbol [ ^methodDict includesKey: aSymbol ]
Behavior >> selectors [ ^methodDict keys ]
Behavior >> canUnderstand: aSymbol [ ^(self lookupSelector: aSymbol) notNil ]
Behavior >> inheritsFrom: aClass [
    | c |
    c := superclass.
    [c == nil] whileFalse: [c == aClass ifTrue: [^true]. c := c superclass].
    ^false ]
Behavior >> includesBehavior: aClass [ ^self == aClass or: [self inheritsFrom: aClass] ]
Behavior >> allInstVarNames [
    | names |
    names := superclass == nil ifTrue: [OrderedCollection new] ifFalse: [superclass allInstVarNames].
    names addAll: self instVarNames.
    ^names ]
Behavior >> compiledMethodAt: aSymbol [ ^methodDict at: aSymbol ]
Behavior >> addSelector: aSymbol withMethod: aMethod [
    methodDict at: aSymbol put: aMethod.
    Smalltalk flushCaches ]
Behavior >> removeSelector: aSymbol [
    methodDict removeKey: aSymbol ifAbsent: [nil].
    Smalltalk flushCaches ]
Behavior >> subclasses [
    | out |
    out := OrderedCollection new.
    Smalltalk allClassesDo: [:c | c superclass == self ifTrue: [out add: c]].
    ^out ]
Behavior >> allSubclasses [
    | out |
    out := OrderedCollection new.
    self subclasses do: [:c | out add: c; addAll: c allSubclasses].
    ^out ]
Behavior >> withAllSuperclasses [
    | out c |
    out := OrderedCollection new.
    c := self.
    [c == nil] whileFalse: [out add: c. c := c superclass].
    ^out ]
Behavior >> printOn: aStream [ aStream nextPutAll: self name ]
Behavior >> compile: aString [ ^Compiler new compile: aString in: self ]
Behavior >> >> aSymbol [ ^self compiledMethodAt: aSymbol ]
Behavior >> setSuperclass: aClass methodDict: aDict format: anInteger index: anIndex [
    superclass := aClass. methodDict := aDict. format := anInteger. classIndex := anIndex ]
Behavior >> setFormat: anInteger [ format := anInteger ]

Class >> name [ ^name ]
Class >> instVarNames [ ^instVarNames ]
Class >> class: aMetaclass [ ^self ]
Class >> setName: aSymbol instVarNames: anArray [ name := aSymbol. instVarNames := anArray ]
Class >> theNonMetaClass [ ^self ]
Class >> category [ ^'' ]
Class >> subclass: aSymbol slots: aString [ ^Class new: aSymbol super: self slots: aString format: nil ]
Class >> variableSubclass: aSymbol slots: aString [ ^Class new: aSymbol super: self slots: aString format: 1 ]
Class >> byteSubclass: aSymbol slots: aString [ ^Class new: aSymbol super: self slots: aString format: 2 ]
Class >> wordSubclass: aSymbol slots: aString [ ^Class new: aSymbol super: self slots: aString format: 4 ]
Class >> slots: aString [ ^self class slots: aString ]
Class class >> new: aSymbol super: aClass slots: aString format: aFormat [
    "Define a class, or redefine one that exists with the same slots."
    | old names fmt meta cls superMeta |
    names := (aString substrings: ' ') collect: [:s | s asString].
    fmt := aFormat.
    fmt == nil ifTrue: [fmt := aClass == nil ifTrue: [0] ifFalse: [aClass instanceFormat]].
    old := Smalltalk at: aSymbol ifAbsent: [nil].
    (old notNil and: [old isClass]) ifTrue: [
        (old superclass == aClass and: [old instVarNames asArray = names asArray])
            ifTrue: [^old].
        ^self error: 'redefining ', aSymbol, ' with other slots is not supported'].
    superMeta := aClass == nil ifTrue: [Class] ifFalse: [aClass class].
    meta := Metaclass basicNewFar: 0.
    meta setSuperclass: superMeta methodDict: MethodDictionary new
        format: superMeta instSize index: Smalltalk newClassIndex.
    cls := meta basicNewFar: 0.
    cls setSuperclass: aClass methodDict: MethodDictionary new
        format: (aClass == nil ifTrue: [0] ifFalse: [aClass instSize]) + names size + (fmt bitShift: 16)
        index: Smalltalk newClassIndex.
    cls setName: aSymbol instVarNames: names asArray.
    meta setThisClass: cls instVarNames: #().
    Smalltalk registerClass: cls.
    Smalltalk registerClass: meta.
    Smalltalk at: aSymbol put: cls.
    ^cls ]

Metaclass >> name [ ^thisClass name, ' class' ]
Metaclass >> instVarNames [ ^instVarNames ]
Metaclass >> theNonMetaClass [ ^thisClass ]
Metaclass >> setThisClass: aClass instVarNames: anArray [ thisClass := aClass. instVarNames := anArray ]
Metaclass >> slots: aString [
    | names |
    names := (aString substrings: ' ') collect: [:s | s asString].
    names asArray = instVarNames asArray ifTrue: [^self].
    instVarNames size = 0 ifFalse: [^self error: 'class slots can be given once'].
    "every instance of this metaclass is its one class: it grows"
    ^self error: 'class slots of a class made at run time are not supported' ]

"---- frames: the VM's stack, as far as exceptions need it -----------------"

Frame class >> current [ "The frame of the method that sends this" <primitive: 90> ]
Frame class >> sender: aFrame [ <primitive: 91> ]
Frame class >> method: aFrame [ <primitive: 92> ]
Frame class >> receiver: aFrame [ <primitive: 93> ]
Frame class >> arg: index of: aFrame [ <primitive: 94> ]
Frame class >> flags: aFrame [ <primitive: 95> ]
Frame class >> flags: anInteger of: aFrame [ <primitive: 96> ]
Frame class >> return: anObject to: aFrame [ "aFrame returns anObject; frames above it are dropped" <primitive: 97> ]
Frame class >> restart: aFrame [ <primitive: 98> ]
Frame class >> homeOf: aClosure [ <primitive: 99> ]
Frame class >> unwindTo: target from: start [
    "Run the unwind blocks (ensure:, ifCurtailed:) of the frames from start up to target."
    | f fl |
    f := start.
    [f = target or: [f = 0]] whileFalse: [
        fl := Frame flags: f.
        (fl bitAnd: 10) = 2 ifTrue: [
            Frame flags: (fl bitOr: 8) of: f.
            (Frame arg: 1 of: f) value].
        f := Frame sender: f] ]
Frame class >> printBacktraceFrom: start on: aStream [
    | f n m |
    f := start. n := 0.
    [f = 0 or: [n >= 24]] whileFalse: [
        m := Frame method: f.
        aStream nextPutAll: '  '; nextPutAll: (Frame receiver: f) class name;
            nextPutAll: '>>'; nextPutAll: m selector; nextPut: Character cr.
        n := n + 1.
        f := Frame sender: f] ]

Message >> selector [ ^selector ]
Message >> arguments [ ^arguments ]
Message >> selector: aSymbol arguments: anArray [ selector := aSymbol. arguments := anArray ]
Message >> printOn: aStream [
    arguments size = 0 ifTrue: [^aStream nextPutAll: selector].
    (selector keywords) with: arguments do: [:k :a |
        aStream nextPutAll: k; space; print: a; space] ]
