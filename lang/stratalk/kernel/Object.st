"Object.st: the root of the classes, nil, the booleans, and classes themselves."

nil subclass: #Object slots: ''.
"The root of the classes (its superclass is nil): what every object
 answers, from identity and class tests to indexed access, copying,
 perform:, signalling errors and printing. It has no slots. An object is
 near (in the nursery, in the core's data Local Store) or far (in the far
 heap); SmallIntegers, Characters and nil are not objects in memory at all.
 Object new printString >>> 'an Object'"

Object subclass: #UndefinedObject slots: ''.
"The class of nil, its one instance: the value of every variable and slot
 not yet assigned. Its ifNil: family runs the nil branch, and nil
 subclass:slots: makes a class with no superclass, as Object is made.
 nil isNil >>> true"

Object subclass: #Boolean slots: ''.
"The abstract class of true and false. Its subclasses True and False have
 one instance each and implement the conditionals and the logic by running
 or skipping the blocks they are given. The compiler compiles ifTrue:,
 ifFalse:, and:, or:, whileTrue: and their kin in line when the arguments
 are literal blocks; then a condition that is not a Boolean gets
 mustBeBoolean from the VM.
 (3 > 2) & (2 > 3) >>> false"

Boolean subclass: #True slots: ''.
"The class of true: ifTrue: runs its block, ifFalse: does not, and: runs
 its block, or: answers true without running it.
 (3 > 2) class >>> True"

Boolean subclass: #False slots: ''.
"The class of false: ifFalse: runs its block, ifTrue: does not, or: runs
 its block, and: answers false without running it.
 (3 < 2) class >>> False"

Object subclass: #Behavior slots: 'superclass methodDict format classIndex'.
"A class as the VM sees it: the superclass, the method dictionary (a
 MethodDictionary, probed on each send), the format and the index in the
 class table, by which object headers name their class. format holds the
 number of named slots in its low 16 bits and the instance format above
 them: 0 no indexed slots, 1 pointers, 2 bytes, 3 compiled code, 4 words.
 Behavior makes instances and answers the questions about methods and the
 hierarchy.
 Association instSize >>> 2"

Behavior subclass: #ClassDescription slots: ''.
"The common superclass of Class and Metaclass. It adds nothing to Behavior
 here.
 Class superclass >>> ClassDescription"

ClassDescription subclass: #Class slots: 'name instVarNames'.
"A class that is not a metaclass: a Behavior with a name (a Symbol) and the
 names of its named slots (instVarNames, an Array of Strings). Each class
 is the one instance of its own Metaclass. subclass:slots: and its kin
 define new classes at run time.
 Association instVarNames >>> #('key' 'value')"

ClassDescription subclass: #Metaclass slots: 'thisClass instVarNames'.
"The class of a class: Object class is a Metaclass whose one instance is
 Object. thisClass is that instance; instVarNames are the names of the
 class-side slots, which a kernel file gives with a `X class slots:` line.
 Object class theNonMetaClass >>> Object"

Object subclass: #Message slots: 'selector arguments'.
"A message as a value: a selector and an Array of arguments. The VM makes
 one when a lookup fails and sends it with doesNotUnderstand:, and
 MessageNotUnderstood keeps it.
 [3 foo: 4] on: MessageNotUnderstood do: [:e | e message arguments] >>> #(4)"

Object subclass: #Frame slots: ''.
"The VM's stack frames, as far as exceptions and unwinding need them, all
 on the class side: there are no instances. A frame is named by a
 SmallInteger (the position of its header on the Smalltalk stack), and 0
 is no frame. A frame's flags are 1 a block's frame, 2 an ensure: or
 ifCurtailed: (primitive 198), 4 an on:do: (primitive 199), 8 unwound, 16
 its handler is running."

"---- Object ----------------------------------------------------------------"

Object >> == anObject [
    "Answers whether the receiver and anObject are the same object. A VM
     primitive (40), which the compiler also sends without a lookup.
     #a == #a >>> true"
    <primitive: 40> ]
Object >> ~~ anObject [
    "Answers whether the receiver and anObject are not the same object.
     3 ~~ 4 >>> true"
    ^(self == anObject) not ]
Object >> = anObject [
    "Answers whether the receiver equals anObject: here identity; classes
     with a value (numbers, strings, collections) redefine it, and hash with it.
     Object new = Object new >>> false"
    ^self == anObject ]
Object >> ~= anObject [
    "Answers whether the receiver does not equal anObject.
     3 ~= 4 >>> true"
    ^(self = anObject) not ]
Object >> hash [
    "Answers a SmallInteger for hashed collections; objects that are = must
     answer the same. Here the identityHash.
     7 hash >>> 7"
    ^self identityHash ]
Object >> identityHash [
    "Answers a SmallInteger that stays the same for this object. A VM
     primitive (42): a SmallInteger answers itself, a Character its value,
     nil 0, an object the 17-bit hash kept in its header.
     $a identityHash >>> 97"
    <primitive: 42> ]
Object >> class [
    "Answers the receiver's class. A VM primitive (41).
     3 class >>> SmallInteger"
    <primitive: 41> ]
Object >> yourself [
    "Answers the receiver: the last message of a cascade that should answer
     the receiver rather than the last result.
     (OrderedCollection new add: 3; yourself) size >>> 1"
    ^self ]
Object >> isNil [
    "Answers whether the receiver is nil: false here.
     3 isNil >>> false"
    ^false ]
Object >> notNil [
    "Answers whether the receiver is not nil: true here.
     3 notNil >>> true"
    ^true ]
Object >> isString [
    "Answers whether the receiver is a String: false here.
     3 isString >>> false"
    ^false ]
Object >> isSymbol [
    "Answers whether the receiver is a Symbol: false here.
     3 isSymbol >>> false"
    ^false ]
Object >> isNumber [
    "Answers whether the receiver is a number: false here.
     '3' isNumber >>> false"
    ^false ]
Object >> isInteger [
    "Answers whether the receiver is an Integer: false here.
     '3' isInteger >>> false"
    ^false ]
Object >> isCharacter [
    "Answers whether the receiver is a Character: false here.
     3 isCharacter >>> false"
    ^false ]
Object >> isArray [
    "Answers whether the receiver is an Array: false here.
     'abc' isArray >>> false"
    ^false ]
Object >> isBlock [
    "Answers whether the receiver is a BlockClosure: false here.
     3 isBlock >>> false"
    ^false ]
Object >> isClass [
    "Answers whether the receiver is a class or a metaclass: false here.
     3 isClass >>> false"
    ^false ]
Object >> isCollection [
    "Answers whether the receiver is a Collection: false here.
     3 isCollection >>> false"
    ^false ]
Object >> isKindOf: aClass [
    "Answers whether the receiver's class is aClass or a subclass of it.
     3 isKindOf: Integer >>> true"
    | c |
    c := self class.
    [c == nil] whileFalse: [c == aClass ifTrue: [^true]. c := c superclass].
    ^false ]
Object >> isMemberOf: aClass [
    "Answers whether the receiver's class is aClass itself.
     3 isMemberOf: Integer >>> false"
    ^self class == aClass ]
Object >> respondsTo: aSymbol [
    "Answers whether the receiver's class or a superclass has a method for
     aSymbol (doesNotUnderstand: aside).
     3 respondsTo: #printString >>> true"
    ^(self class lookupSelector: aSymbol) notNil ]
Object >> ifNil: aBlock [
    "Answers the receiver, without running aBlock: it is not nil. Compiled in
     line when aBlock is a literal block.
     3 ifNil: [0] >>> 3"
    ^self ]
Object >> ifNotNil: aBlock [
    "Answers aBlock's value, given the receiver if it takes an argument.
     3 ifNotNil: [:x | x + 1] >>> 4"
    ^aBlock cull: self ]
Object >> ifNil: nilBlock ifNotNil: aBlock [
    "Answers aBlock's value, given the receiver if it takes an argument;
     nilBlock does not run.
     3 ifNil: [0] ifNotNil: [:x | x * 2] >>> 6"
    ^aBlock cull: self ]
Object >> ifNotNil: aBlock ifNil: nilBlock [
    "Answers aBlock's value, given the receiver if it takes an argument;
     nilBlock does not run.
     3 ifNotNil: [:x | x * 2] ifNil: [0] >>> 6"
    ^aBlock cull: self ]
Object >> -> anObject [
    "Answers an Association with the receiver as its key and anObject as its
     value.
     (3 -> 4) value >>> 4"
    ^Association key: self value: anObject ]
Object >> value [
    "Answers the receiver, so that any object can stand where a block would
     be evaluated with value.
     3 value >>> 3"
    ^self ]
Object >> isNear [
    "Answers whether the receiver is a near object: one in the core's
     nursery, in the data Local Store, not yet moved to the far heap. A VM
     primitive (53); far objects, SmallIntegers, Characters and nil answer
     false. A new object is near until a scavenge moves it out."
    "True while the object is in the core's nursery" <primitive: 53> ]

Object >> basicSize [
    "Answers the number of indexed slots (or bytes, or words) of the
     receiver, 0 for one without them. A VM primitive (43) that subclasses
     do not redefine.
     #(1 2 3) basicSize >>> 3"
    <primitive: 43> ]
Object >> size [
    "Answers the number of indexed elements; here the basicSize.
     Object new size >>> 0"
    ^self basicSize ]
Object >> basicAt: index [
    "Answers the indexed element at index (1-based): an object, or a
     SmallInteger for byte and word objects. A VM primitive (44) that
     subclasses do not redefine; on failure, indexError:.
     #(5 6 7) basicAt: 2 >>> 6"
    <primitive: 44> ^self indexError: index ]
Object >> basicAt: index put: anObject [
    "Stores anObject at the indexed slot index (1-based) and answers it. A VM
     primitive (45); on failure (a bad index, an immutable receiver, a value
     that does not fit a byte or word object), indexError:.
     (Array new: 2) basicAt: 1 put: 9; yourself >>> #(9 nil)"
    <primitive: 45> ^self indexError: index ]
Object >> at: index [
    "Answers the indexed element at index (1-based). The VM primitive 44, as
     basicAt:; on failure, indexError: signals SubscriptOutOfBounds or an
     Error.
     [#(5 6 7) at: 4] on: SubscriptOutOfBounds do: [:e | e messageText] >>> 'index 4 is out of bounds'"
    <primitive: 44> ^self indexError: index ]
Object >> at: index put: anObject [
    "Stores anObject at index (1-based) and answers it. The VM primitive 45,
     as basicAt:put:; on failure, indexError:.
     (Array new: 2) at: 2 put: 9; yourself >>> #(nil 9)"
    <primitive: 45> ^self indexError: index ]
Object >> instVarAt: index [
    "Answers the receiver's slot index (1-based), named slots first, then the
     indexed ones of a pointer object. A VM primitive (49); on failure,
     indexError:.
     (3 -> 4) instVarAt: 2 >>> 4"
    <primitive: 49> ^self indexError: index ]
Object >> instVarAt: index put: anObject [
    "Stores anObject in the receiver's slot index (1-based) and answers it. A
     VM primitive (50); on failure, indexError:.
     (3 -> 4) instVarAt: 2 put: 5; value >>> 5"
    <primitive: 50> ^self indexError: index ]
Object >> indexError: index [
    "Signals why an indexing primitive failed: an Error if index is not an
     integer or if the receiver is immutable, else SubscriptOutOfBounds.
     [#(1 2) at: 'x'] on: Error do: [:e | e messageText] >>> 'an index must be an integer'"
    index isInteger ifFalse: [^self error: 'an index must be an integer'].
    ((index between: 1 and: self basicSize) and: [self isImmutable])
        ifTrue: [^self error: 'this object cannot be changed'].
    ^SubscriptOutOfBounds new signal: 'index ', index printString, ' is out of bounds' ]
Object >> isImmutable [
    "Answers whether the receiver cannot be changed: true for SmallIntegers,
     Characters and nil, and for an object marked by beImmutable (literals
     are). A VM primitive (55).
     #(1 2) isImmutable >>> true"
    <primitive: 55> ]
Object >> beImmutable [
    "Marks the receiver immutable, in its header, and answers it: the
     primitives that store into an object fail on it from then on. A VM
     primitive (56); a far object is read, marked and written back.
     [(Array new: 2) beImmutable at: 1 put: 3] on: Error do: [:e | e messageText] >>> 'this object cannot be changed'"
    <primitive: 56> ]
Object >> shallowCopy [
    "Answers a new object of the same class, format and size whose slots are
     the receiver's (not copies of them). A VM primitive (48); SmallIntegers,
     Characters and nil answer themselves.
     | a | a := Array with: 'x'. a shallowCopy first == a first >>> true"
    <primitive: 48> ]
Object >> copy [
    "Answers a copy of the receiver: a shallowCopy, then postCopy sent to it,
     which a class redefines to copy what it must not share.
     | a | a := 3 -> 4. a copy == a >>> false"
    ^self shallowCopy postCopy ]
Object >> postCopy [
    "Answers the receiver; sent by copy to the fresh shallow copy, for a
     class to copy its parts. Here it does nothing.
     3 postCopy >>> 3"
    ^self ]
Object >> deepCopy [
    "Answers a shallowCopy whose slots, named and indexed, hold copies (with
     copy) of the receiver's. The bytes of a String or a ByteArray are
     copied by shallowCopy already.
     | a | a := Array with: 'x'. a deepCopy first == a first >>> false"
    | c |
    c := self shallowCopy.
    1 to: self class instSize do: [:i | c instVarAt: i put: (self instVarAt: i) copy].
    self class instanceFormat = 1 ifTrue: [
        1 to: self basicSize do: [:i | c basicAt: i put: (self basicAt: i) copy]].
    ^c ]

Object >> perform: aSymbol [
    "Sends the receiver the unary message aSymbol and answers the result.
     Signals an Error if aSymbol is not a Symbol or takes arguments.
     3 perform: #negated >>> -3"
    (self checkPerform: aSymbol arguments: 0) ifFalse: [^self].
    ^self basicPerform: aSymbol ]
Object >> perform: aSymbol with: a [
    "Sends the receiver the message aSymbol with the argument a and answers
     the result. Signals an Error if aSymbol is not a Symbol of one
     argument.
     3 perform: #+ with: 4 >>> 7"
    (self checkPerform: aSymbol arguments: 1) ifFalse: [^self].
    ^self basicPerform: aSymbol with: a ]
Object >> perform: aSymbol with: a with: b [
    "Sends the receiver the message aSymbol with the arguments a and b and
     answers the result. Signals an Error if aSymbol is not a Symbol of two
     arguments.
     3 perform: #between:and: with: 1 with: 5 >>> true"
    (self checkPerform: aSymbol arguments: 2) ifFalse: [^self].
    ^self basicPerform: aSymbol with: a with: b ]
Object >> perform: aSymbol with: a with: b with: c [
    "Sends the receiver the message aSymbol with the arguments a, b and c and
     answers the result. Signals an Error if aSymbol is not a Symbol of
     three arguments.
     (Array new: 2) perform: #replaceFrom:to:with: with: 1 with: 2 with: #(7 8) >>> #(7 8)"
    (self checkPerform: aSymbol arguments: 3) ifFalse: [^self].
    ^self basicPerform: aSymbol with: a with: b with: c ]
Object >> perform: aSymbol withArguments: anArray [
    "Sends the receiver the message aSymbol with the elements of anArray as
     its arguments and answers the result. Signals an Error if aSymbol is
     not a Symbol, anArray not an Array, or its size not the number of
     arguments aSymbol takes.
     3 perform: #+ withArguments: #(4) >>> 7"
    anArray isArray ifFalse: [^self error: 'perform:withArguments: needs an Array'].
    (self checkPerform: aSymbol arguments: anArray size) ifFalse: [^self].
    ^self basicPerform: aSymbol withArguments: anArray ]
Object >> checkPerform: aSymbol arguments: n [
    "Answers true if aSymbol is a Symbol that takes n arguments; else
     signals an Error (and answers false if that is resumed).
     [3 perform: #+ withArguments: #()] on: Error do: [:e | e messageText] >>> '#+ takes 1 argument(s), not 0'"
    aSymbol isSymbol ifFalse: [self error: 'perform: needs a Symbol'. ^false].
    aSymbol numArgs = n ifFalse: [
        self error: aSymbol printString , ' takes ' , aSymbol numArgs printString , ' argument(s), not ' , n printString.
        ^false].
    ^true ]
Object >> basicPerform: aSymbol [
    "perform: without the checks: a VM primitive (51), which takes the
     selector out of the arguments and sends the rest."
    <primitive: 51> ^self error: 'perform: needs a Symbol' ]
Object >> basicPerform: aSymbol with: a [
    "perform:with: without the checks (primitive 51)."
    <primitive: 51> ^self error: 'perform: needs a Symbol' ]
Object >> basicPerform: aSymbol with: a with: b [
    "perform:with:with: without the checks (primitive 51)."
    <primitive: 51> ^self error: 'perform: needs a Symbol' ]
Object >> basicPerform: aSymbol with: a with: b with: c [
    "perform:with:with:with: without the checks (primitive 51)."
    <primitive: 51> ^self error: 'perform: needs a Symbol' ]
Object >> basicPerform: aSymbol withArguments: anArray [
    "perform:withArguments: without the checks: a VM primitive (52)."
    <primitive: 52>
    ^self error: 'perform: needs a Symbol and an Array' ]

Object >> error: aString [
    "Signals an Error with aString as its messageText. Unhandled, it ends the
     expression at the REPL with the message and a backtrace.
     [3 error: 'no'] on: Error do: [:e | e messageText] >>> 'no'"
    ^Error new signal: aString ]
Object >> halt [
    "Signals Halt: unhandled, it stops the expression as an error does, with
     a backtrace.
     [3 halt] on: Halt do: [:e | e messageText] >>> 'halt'"
    ^Halt new signal: 'halt' ]
Object >> doesNotUnderstand: aMessage [
    "Signals MessageNotUnderstood for aMessage. The VM sends this when the
     lookup of a message fails; a handler that resumes gives the value of the
     failed send.
     [3 foo] on: MessageNotUnderstood do: [:e | e messageText] >>> '3 does not understand #foo'"
    ^MessageNotUnderstood new message: aMessage receiver: self; signal ]
Object >> subclassResponsibility [
    "Signals an Error: the body of a method that each subclass must define.
     [Object new subclassResponsibility] on: Error do: [:e | e messageText] >>> 'a subclass should have implemented this'"
    ^self error: 'a subclass should have implemented this' ]
Object >> shouldNotImplement [
    "Signals an Error: the body of an inherited method that does not apply to
     this class.
     [Object new shouldNotImplement] on: Error do: [:e | e messageText] >>> 'this message is not appropriate here'"
    ^self error: 'this message is not appropriate here' ]
Object >> mustBeBoolean [
    "Signals NonBooleanReceiver. The VM sends this to the condition of an
     in-line ifTrue:, whileTrue:, and: (and the like) when it is not a
     Boolean.
     [3 ifTrue: [4]] on: NonBooleanReceiver do: [:e | e messageText] >>> '3 is not a Boolean'"
    ^NonBooleanReceiver new signal: self printString, ' is not a Boolean' ]
Object >> assert: aBlock [
    "Signals AssertionFailure unless aBlock's value is true; answers the
     receiver. aBlock can also be a Boolean.
     [3 assert: [false]] on: AssertionFailure do: [:e | e messageText] >>> 'assertion failed'"
    aBlock value ifFalse: [^AssertionFailure new signal: 'assertion failed'] ]

Object >> printOn: aStream [
    "Writes a description of the receiver on aStream, for printString: here
     'a' or 'an' and the class name. Classes redefine it.
     Object new printString >>> 'an Object'"
    | n |
    n := self class name.
    aStream nextPutAll: ((n first isVowel) ifTrue: ['an '] ifFalse: ['a ']); nextPutAll: n ]
Object >> displayOn: aStream [
    "Writes the receiver on aStream as a user would read it, for
     displayString; here as printOn:. Strings and symbols write themselves
     without quotes.
     Object new displayString >>> 'an Object'"
    self printOn: aStream ]
Object >> printString [
    "Answers a String describing the receiver, as printOn: writes it: what
     the REPL prints for a value.
     'abc' printString >>> '''abc'''"
    | s |
    s := WriteStream on: (String new: 16).
    self printOn: s.
    ^s contents ]
Object >> displayString [
    "Answers a String of the receiver as displayOn: writes it.
     'abc' displayString >>> 'abc'"
    | s |
    s := WriteStream on: (String new: 16).
    self displayOn: s.
    ^s contents ]
Object >> printNl [
    "Writes the receiver's printString and a new line to the Transcript."
    Transcript showln: self printString ]
Object >> displayNl [
    "Writes the receiver's displayString and a new line to the Transcript."
    Transcript showln: self displayString ]
Object >> storeString [
    "Answers a String that would evaluate to an equal object; here the
     printString.
     3 storeString >>> '3'"
    ^self printString ]

"---- nil ----------------------------------------------------------------------"

UndefinedObject >> isNil [
    "Answers true: the receiver is nil.
     nil isNil >>> true"
    ^true ]
UndefinedObject >> notNil [
    "Answers false: the receiver is nil.
     nil notNil >>> false"
    ^false ]
UndefinedObject >> ifNil: aBlock [
    "Answers aBlock's value.
     nil ifNil: [3] >>> 3"
    ^aBlock value ]
UndefinedObject >> ifNotNil: aBlock [
    "Answers nil, without running aBlock.
     nil ifNotNil: [:x | 3] >>> nil"
    ^nil ]
UndefinedObject >> ifNil: nilBlock ifNotNil: aBlock [
    "Answers nilBlock's value; aBlock does not run.
     nil ifNil: [1] ifNotNil: [:x | 2] >>> 1"
    ^nilBlock value ]
UndefinedObject >> ifNotNil: aBlock ifNil: nilBlock [
    "Answers nilBlock's value; aBlock does not run.
     nil ifNotNil: [:x | 2] ifNil: [1] >>> 1"
    ^nilBlock value ]
UndefinedObject >> printOn: aStream [
    "Writes 'nil' on aStream.
     nil printString >>> 'nil'"
    aStream nextPutAll: 'nil' ]
UndefinedObject >> subclass: aSymbol slots: aString [
    "Defines a class named aSymbol with no superclass and the named slots in
     aString (separated by spaces), and answers it: how Object is made. See
     Class class >> new:super:slots:format:."
    ^Class new: aSymbol super: nil slots: aString format: 0 ]

"---- the booleans ------------------------------------------------------------"

Boolean >> printOn: aStream [
    "Writes 'true' or 'false' on aStream.
     (3 > 2) printString >>> 'true'"
    aStream nextPutAll: self printString ]
Boolean >> | aBoolean [
    "Answers the logical or of the receiver and aBoolean. Both are evaluated;
     or: evaluates its block only when needed.
     false | (3 > 2) >>> true"
    ^self or: [aBoolean] ]
Boolean >> & aBoolean [
    "Answers the logical and of the receiver and aBoolean. Both are
     evaluated; and: evaluates its block only when needed.
     true & false >>> false"
    ^self and: [aBoolean] ]
True >> printString [
    "Answers 'true'.
     true printString >>> 'true'"
    ^'true' ]
True >> not [
    "Answers false.
     true not >>> false"
    ^false ]
True >> ifTrue: aBlock [
    "Answers aBlock's value. Compiled in line when aBlock is a literal block.
     true ifTrue: [3] >>> 3"
    ^aBlock value ]
True >> ifFalse: aBlock [
    "Answers nil, without running aBlock.
     true ifFalse: [3] >>> nil"
    ^nil ]
True >> ifTrue: t ifFalse: f [
    "Answers the value of t; f does not run.
     true ifTrue: [1] ifFalse: [2] >>> 1"
    ^t value ]
True >> ifFalse: f ifTrue: t [
    "Answers the value of t; f does not run.
     true ifFalse: [1] ifTrue: [2] >>> 2"
    ^t value ]
True >> and: aBlock [
    "Answers aBlock's value: the receiver is true, so the result is the
     argument's.
     true and: [false] >>> false"
    ^aBlock value ]
True >> or: aBlock [
    "Answers true, without running aBlock.
     true or: [1/0] >>> true"
    ^true ]
True >> xor: aBoolean [
    "Answers the exclusive or of true and aBoolean: its negation.
     true xor: true >>> false"
    ^aBoolean not ]
False >> printString [
    "Answers 'false'.
     false printString >>> 'false'"
    ^'false' ]
False >> not [
    "Answers true.
     false not >>> true"
    ^true ]
False >> ifTrue: aBlock [
    "Answers nil, without running aBlock.
     false ifTrue: [3] >>> nil"
    ^nil ]
False >> ifFalse: aBlock [
    "Answers aBlock's value. Compiled in line when aBlock is a literal block.
     false ifFalse: [3] >>> 3"
    ^aBlock value ]
False >> ifTrue: t ifFalse: f [
    "Answers the value of f; t does not run.
     false ifTrue: [1] ifFalse: [2] >>> 2"
    ^f value ]
False >> ifFalse: f ifTrue: t [
    "Answers the value of f; t does not run.
     false ifFalse: [1] ifTrue: [2] >>> 1"
    ^f value ]
False >> and: aBlock [
    "Answers false, without running aBlock.
     false and: [1/0] >>> false"
    ^false ]
False >> or: aBlock [
    "Answers aBlock's value: the receiver is false, so the result is the
     argument's.
     false or: [true] >>> true"
    ^aBlock value ]
False >> xor: aBoolean [
    "Answers the exclusive or of false and aBoolean: aBoolean itself.
     false xor: true >>> true"
    ^aBoolean ]

"---- classes --------------------------------------------------------------------"

Behavior >> superclass [
    "The class this one inherits from; nil for Object.
     SmallInteger superclass >>> Integer"
    ^superclass ]
Behavior >> methodDict [
    "The MethodDictionary of the methods defined in this class, selector to
     CompiledMethod.
     Object methodDict class >>> MethodDictionary"
    ^methodDict ]
Behavior >> classIndex [
    "The index of this class in the class table: what the header of each of
     its instances holds to name it (0-based; the table's slot is one more)."
    ^classIndex ]
Behavior >> instSize [
    "The number of named slots of an instance, inherited ones included.
     Association instSize >>> 2"
    ^format bitAnd: 65535 ]
Behavior >> instanceFormat [
    "The format of the instances: 0 named slots only, 1 indexed pointers,
     2 bytes, 3 compiled code, 4 words.
     String instanceFormat >>> 2"
    ^format bitShift: -16 ]
Behavior >> isVariable [
    "Answers whether the instances have indexed slots (pointers, bytes or
     words).
     Array isVariable >>> true"
    ^self instanceFormat ~= 0 ]
Behavior >> isClass [
    "Answers true: the receiver is a class or a metaclass.
     Object isClass >>> true"
    ^true ]
Behavior >> basicNew [
    "Answers a new instance with its named slots nil and no indexed slots,
     made near, in the nursery, without initialize. A VM primitive (46); if
     it fails, signals an Error.
     Object basicNew printString >>> 'an Object'"
    <primitive: 46> ^self error: 'this class needs new:' ]
Behavior >> basicNew: n [
    "Answers a new instance with n indexed slots (nil, or 0 for bytes and
     words), without initialize. A VM primitive (47): near, or far when
     large; n must be a SmallInteger from 0 to 524287. Signals an Error for a
     class whose instances have no indexed slots.
     (Array basicNew: 3) size >>> 3"
    <primitive: 47> ^self error: 'this class cannot have indexed instances' ]
Behavior >> basicNewFar: n [
    "Answers a new instance with n indexed slots made directly in far memory,
     where it is never moved: how classes, symbols and methods are made. A VM
     primitive (54); if it fails, basicNew:.
     (Array basicNewFar: 2) size >>> 2"
    "Made directly in far memory: never moved" <primitive: 54> ^self basicNew: n ]
Behavior >> new [
    "Answers a new instance, made with basicNew and sent initialize.
     Object new printString >>> 'an Object'"
    ^self basicNew initialize ]
Behavior >> new: n [
    "Answers a new instance with n indexed slots, made with basicNew: and
     sent initialize.
     Array new: 2 >>> #(nil nil)"
    ^(self basicNew: n) initialize ]
Object >> initialize [
    "Sets up a new instance and answers it; new and new: send it. Here it
     does nothing: classes redefine it.
     3 initialize >>> 3"
    ^self ]
Behavior >> lookupSelector: aSymbol [
    "Answers the CompiledMethod a message aSymbol to an instance runs: the
     first found in this class and its superclasses, or nil.
     SmallInteger lookupSelector: #foo >>> nil"
    | c m |
    c := self.
    [c == nil] whileFalse: [
        m := c methodDict at: aSymbol ifAbsent: [nil].
        m == nil ifFalse: [^m].
        c := c superclass].
    ^nil ]
Behavior >> includesSelector: aSymbol [
    "Answers whether this class itself (not a superclass) defines aSymbol.
     SmallInteger includesSelector: #isNil >>> false"
    ^methodDict includesKey: aSymbol ]
Behavior >> selectors [
    "Answers the selectors of the methods this class defines, in no order.
     (Boolean selectors includes: #|) >>> true"
    ^methodDict keys ]
Behavior >> canUnderstand: aSymbol [
    "Answers whether an instance has a method for aSymbol, here or inherited.
     SmallInteger canUnderstand: #isNil >>> true"
    ^(self lookupSelector: aSymbol) notNil ]
Behavior >> inheritsFrom: aClass [
    "Answers whether aClass is a superclass of this class (not the class
     itself).
     SmallInteger inheritsFrom: Object >>> true"
    | c |
    c := superclass.
    [c == nil] whileFalse: [c == aClass ifTrue: [^true]. c := c superclass].
    ^false ]
Behavior >> includesBehavior: aClass [
    "Answers whether this class is aClass or inherits from it.
     Object includesBehavior: Object >>> true"
    ^self == aClass or: [self inheritsFrom: aClass] ]
Behavior >> allInstVarNames [
    "Answers an OrderedCollection of the names of all the named slots, the
     superclasses' first, in slot order.
     Association allInstVarNames >>> OrderedCollection ('key' 'value')"
    | names |
    names := superclass == nil ifTrue: [OrderedCollection new] ifFalse: [superclass allInstVarNames].
    names addAll: self instVarNames.
    ^names ]
Behavior >> compiledMethodAt: aSymbol [
    "Answers the CompiledMethod this class defines for aSymbol; signals
     KeyNotFound if it defines none.
     [Object compiledMethodAt: #foo] on: KeyNotFound do: [:e | e messageText] >>> 'no method foo'"
    ^methodDict at: aSymbol ]
Behavior >> addSelector: aSymbol withMethod: aMethod [
    "Installs aMethod as this class's method for aSymbol, replacing any, and
     empties the VM's method caches (Smalltalk flushCaches) so that sends
     find it."
    methodDict at: aSymbol put: aMethod.
    Smalltalk flushCaches ]
Behavior >> removeSelector: aSymbol [
    "Removes this class's method for aSymbol, if it has one, and empties the
     VM's method caches."
    methodDict removeKey: aSymbol ifAbsent: [nil].
    Smalltalk flushCaches ]
Behavior >> subclasses [
    "Answers an OrderedCollection of the classes whose superclass is this
     one, in class table order.
     Boolean subclasses >>> OrderedCollection (True False)"
    | out |
    out := OrderedCollection new.
    Smalltalk allClassesDo: [:c | c superclass == self ifTrue: [out add: c]].
    ^out ]
Behavior >> allSubclasses [
    "Answers an OrderedCollection of the subclasses, theirs, and so on, each
     followed by its own.
     Boolean allSubclasses size >>> 2"
    | out |
    out := OrderedCollection new.
    self subclasses do: [:c | out add: c; addAll: c allSubclasses].
    ^out ]
Behavior >> withAllSuperclasses [
    "Answers an OrderedCollection of this class and its superclasses, up to
     Object.
     True withAllSuperclasses >>> OrderedCollection (True Boolean Object)"
    | out c |
    out := OrderedCollection new.
    c := self.
    [c == nil] whileFalse: [out add: c. c := c superclass].
    ^out ]
Behavior >> printOn: aStream [
    "Writes the class's name on aStream.
     Object printString >>> 'Object'"
    aStream nextPutAll: self name ]
Behavior >> compile: aString [
    "Compiles the method source aString (a selector pattern, then the body)
     with the Compiler, installs it in this class and answers what the
     Compiler answers. Signals CompileError for a syntax error."
    ^Compiler new compile: aString in: self ]
Behavior >> >> aSymbol [
    "Answers the CompiledMethod this class defines for aSymbol, as
     compiledMethodAt:.
     (Object >> #yourself) selector >>> #yourself"
    ^self compiledMethodAt: aSymbol ]
Behavior >> setSuperclass: aClass methodDict: aDict format: anInteger index: anIndex [
    "Sets the four slots the VM reads; for Class class >> new:super:slots:format:."
    superclass := aClass. methodDict := aDict. format := anInteger. classIndex := anIndex ]
Behavior >> setFormat: anInteger [
    "Sets the format: the number of named slots, plus the instance format
     shifted left 16."
    format := anInteger ]

Class >> name [
    "The class's name, a Symbol.
     Object name >>> #Object"
    ^name ]
Class >> instVarNames [
    "The names of the named slots this class adds, an Array of Strings.
     Association instVarNames >>> #('key' 'value')"
    ^instVarNames ]
Class >> class: aMetaclass [
    "Answers the receiver; aMetaclass is not used."
    ^self ]
Class >> setName: aSymbol instVarNames: anArray [
    "Sets the name and the slot names; for Class class >> new:super:slots:format:."
    name := aSymbol. instVarNames := anArray ]
Class >> theNonMetaClass [
    "Answers the receiver: it is not a metaclass.
     Object theNonMetaClass >>> Object"
    ^self ]
Class >> category [
    "Answers the class's category: '' (classes have none here).
     Object category >>> ''"
    ^'' ]
Class >> subclass: aSymbol slots: aString [
    "Defines (or finds again) a subclass named aSymbol with the named slots
     in aString, separated by spaces, and answers it; its instances have the
     same format as this class's. See Class class >> new:super:slots:format:."
    ^Class new: aSymbol super: self slots: aString format: nil ]
Class >> variableSubclass: aSymbol slots: aString [
    "Defines a subclass named aSymbol whose instances also have indexed
     pointer slots (format 1), as Array, and answers it."
    ^Class new: aSymbol super: self slots: aString format: 1 ]
Class >> byteSubclass: aSymbol slots: aString [
    "Defines a subclass named aSymbol whose instances have indexed bytes
     (format 2), as String, and answers it."
    ^Class new: aSymbol super: self slots: aString format: 2 ]
Class >> wordSubclass: aSymbol slots: aString [
    "Defines a subclass named aSymbol whose instances have indexed 64-bit
     words (format 4), and answers it."
    ^Class new: aSymbol super: self slots: aString format: 4 ]
Class >> slots: aString [
    "Gives the class-side slots named in aString to this class, through its
     Metaclass (slots:): the `X class slots:` line of a kernel file."
    ^self class slots: aString ]
Class class >> new: aSymbol super: aClass slots: aString format: aFormat [
    "Defines the class aSymbol, a subclass of aClass (nil for a root) with
     the named slots in aString and the instance format aFormat (nil: the
     superclass's), and answers it: a new Metaclass and its class, both made
     far, entered in the class table and in Smalltalk. If a class with that
     name, superclass and slots exists, answers it; with other slots, signals
     an Error."
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
    Smalltalk registerClass: meta.
    cls := meta basicNewFar: 0.
    cls setSuperclass: aClass methodDict: MethodDictionary new
        format: (aClass == nil ifTrue: [0] ifFalse: [aClass instSize]) + names size + (fmt bitShift: 16)
        index: Smalltalk newClassIndex.
    Smalltalk registerClass: cls.
    cls setName: aSymbol instVarNames: names asArray.
    meta setThisClass: cls instVarNames: #().
    Smalltalk at: aSymbol put: cls.
    ^cls ]

Metaclass >> name [
    "The metaclass's name: its class's name followed by ' class'.
     Object class name >>> 'Object class'"
    ^thisClass name, ' class' ]
Metaclass >> instVarNames [
    "The names of the class-side slots, an Array of Strings.
     Object class instVarNames >>> #()"
    ^instVarNames ]
Metaclass >> theNonMetaClass [
    "Answers the class this is the metaclass of.
     Object class theNonMetaClass >>> Object"
    ^thisClass ]
Metaclass >> setThisClass: aClass instVarNames: anArray [
    "Sets the class and the class-side slot names; for Class class >>
     new:super:slots:format:."
    thisClass := aClass. instVarNames := anArray ]
Metaclass >> slots: aString [
    "Answers the receiver if aString names the class-side slots it has
     already. Otherwise signals an Error: class-side slots are given once,
     when the image is built, and cannot be added to a class made at run
     time."
    | names |
    names := (aString substrings: ' ') collect: [:s | s asString].
    names asArray = instVarNames asArray ifTrue: [^self].
    instVarNames size = 0 ifFalse: [^self error: 'class slots can be given once'].
    "every instance of this metaclass is its one class: it grows"
    ^self error: 'class slots of a class made at run time are not supported' ]

"---- frames: the VM's stack, as far as exceptions need it -----------------"

Frame class >> current [
    "Answers the frame of the method that sends this. A VM primitive (90)."
    "The frame of the method that sends this" <primitive: 90> ]
Frame class >> sender: aFrame [
    "Answers the frame of aFrame's caller, 0 if it has none. A VM primitive
     (91)."
    <primitive: 91> ]
Frame class >> method: aFrame [
    "Answers the compiled code that aFrame runs. A VM primitive (92)."
    <primitive: 92> ]
Frame class >> receiver: aFrame [
    "Answers the receiver (self) of aFrame. A VM primitive (93)."
    <primitive: 93> ]
Frame class >> arg: index of: aFrame [
    "Answers aFrame's temp index (1-based; the arguments come first). A VM
     primitive (94): Exception reads the class and the handler block of an
     on:do: frame with it, and the unwind block of an ensure:."
    <primitive: 94> ]
Frame class >> flags: aFrame [
    "Answers aFrame's flags: 1 a block's frame, 2 ensure: or ifCurtailed:, 4
     on:do:, 8 unwound, 16 its handler is running. A VM primitive (95)."
    <primitive: 95> ]
Frame class >> flags: anInteger of: aFrame [
    "Sets aFrame's flags to anInteger. A VM primitive (96)."
    <primitive: 96> ]
Frame class >> return: anObject to: aFrame [
    "Makes aFrame return anObject to its caller; the frames above it are
     dropped without running their unwind blocks (unwindTo:from: does that
     first). A VM primitive (97)."
    "aFrame returns anObject; frames above it are dropped" <primitive: 97> ]
Frame class >> restart: aFrame [
    "Runs aFrame's method again from its first bytecode, with the same
     receiver and arguments, its other temps nil and its flags 8 and 16
     cleared; the frames above it are dropped. A VM primitive (98): how
     Exception >> retry runs the on:do: again."
    <primitive: 98> ]
Frame class >> homeOf: aClosure [
    "Answers the frame of the method in which aClosure was made, or 0 if that
     frame is no longer on the stack. A VM primitive (99)."
    <primitive: 99> ]
Frame class >> unwindTo: target from: start [
    "Runs the unwind blocks (of ensure:, and of ifCurtailed: not finished) of
     the frames from start up to target, target excluded, each once: a frame
     is flagged 8 before its block runs."
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
    "Writes on aStream a line for each frame from start down to the first,
     at most 24: the receiver's class and the selector."
    | f n m |
    f := start. n := 0.
    [f = 0 or: [n >= 24]] whileFalse: [
        m := Frame method: f.
        aStream nextPutAll: '  '; nextPutAll: (Frame receiver: f) class name;
            nextPutAll: '>>'; nextPutAll: m selector; nextPut: Character cr.
        n := n + 1.
        f := Frame sender: f] ]

Message >> selector [
    "The message's selector, a Symbol.
     [3 foo: 4] on: MessageNotUnderstood do: [:e | e message selector] >>> #foo:"
    ^selector ]
Message >> arguments [
    "The message's arguments, an Array.
     (Message new selector: #+ arguments: #(4)) arguments >>> #(4)"
    ^arguments ]
Message >> selector: aSymbol arguments: anArray [
    "Sets the selector and the arguments."
    selector := aSymbol. arguments := anArray ]
Message >> printOn: aStream [
    "Writes the message on aStream as it would be sent: the selector, or each
     keyword followed by its argument's printString.
     (Message new selector: #size arguments: #()) printString >>> 'size'"
    arguments size = 0 ifTrue: [^aStream nextPutAll: selector].
    (selector keywords) doWithIndex: [:k :i |
        i > 1 ifTrue: [aStream space].
        aStream nextPutAll: k; space; print: (arguments at: i)] ]
