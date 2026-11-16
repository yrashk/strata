"Collection.st: collections. Arrays, strings, symbols, byte arrays,
 ordered collections, intervals, sets and dictionaries."

Object subclass: #Collection slots: ''.
Collection subclass: #SequenceableCollection slots: ''.
SequenceableCollection subclass: #ArrayedCollection slots: ''.
ArrayedCollection variableSubclass: #Array slots: ''.
ArrayedCollection byteSubclass: #String slots: ''.
String subclass: #Symbol slots: ''.
ArrayedCollection byteSubclass: #ByteArray slots: ''.
SequenceableCollection subclass: #OrderedCollection slots: 'array firstIndex lastIndex'.
SequenceableCollection subclass: #Interval slots: 'start stop step'.
Collection subclass: #HashedCollection slots: 'tally array'.
HashedCollection subclass: #Set slots: ''.
Set subclass: #IdentitySet slots: ''.
HashedCollection subclass: #Dictionary slots: ''.
Dictionary subclass: #IdentityDictionary slots: ''.
IdentityDictionary subclass: #SystemDictionary slots: ''.
Object subclass: #Association slots: 'key value'.
Object subclass: #MethodDictionary slots: 'tally keys values'.
Object subclass: #Point slots: 'x y'.

"---- Collection -----------------------------------------------------------------"

Collection class >> with: a [ ^self new add: a; yourself ]
Collection class >> with: a with: b [ ^self new add: a; add: b; yourself ]
Collection class >> with: a with: b with: c [ ^self new add: a; add: b; add: c; yourself ]
Collection class >> with: a with: b with: c with: d [ ^self new add: a; add: b; add: c; add: d; yourself ]
Collection class >> withAll: aCollection [ ^self new addAll: aCollection; yourself ]
Collection >> isCollection [ ^true ]
Collection >> do: aBlock [ ^self subclassResponsibility ]
Collection >> add: anObject [ ^self subclassResponsibility ]
Collection >> addAll: aCollection [ aCollection do: [:e | self add: e]. ^aCollection ]
Collection >> remove: anObject [ ^self remove: anObject ifAbsent: [NotFound new signal: 'not found'] ]
Collection >> removeAll: aCollection [ aCollection do: [:e | self remove: e]. ^aCollection ]
Collection >> size [ | n | n := 0. self do: [:e | n := n + 1]. ^n ]
Collection >> isEmpty [ ^self size = 0 ]
Collection >> notEmpty [ ^self isEmpty not ]
Collection >> isEmptyOrNil [ ^self isEmpty ]
Collection >> ifEmpty: aBlock [ ^self isEmpty ifTrue: [aBlock value] ifFalse: [self] ]
Collection >> ifNotEmpty: aBlock [ ^self isEmpty ifTrue: [self] ifFalse: [aBlock cull: self] ]
Collection >> includesIdentity: anObject [ self do: [:e | e == anObject ifTrue: [^true]]. ^false ]
Collection >> includes: anObject [ self do: [:e | e = anObject ifTrue: [^true]]. ^false ]
Collection >> occurrencesOf: anObject [ | n | n := 0. self do: [:e | e = anObject ifTrue: [n := n + 1]]. ^n ]
Collection >> anyOne [ self do: [:e | ^e]. ^self error: 'the collection is empty' ]
Collection >> do: aBlock separatedBy: sepBlock [
    | first |
    first := true.
    self do: [:e | first ifTrue: [first := false] ifFalse: [sepBlock value]. aBlock value: e] ]
Collection >> collect: aBlock [ | out | out := OrderedCollection new. self do: [:e | out add: (aBlock value: e)]. ^out ]
Collection >> select: aBlock [ | out | out := self copyEmpty. self do: [:e | (aBlock value: e) ifTrue: [out add: e]]. ^out ]
Collection >> reject: aBlock [ ^self select: [:e | (aBlock value: e) not] ]
Collection >> detect: aBlock [ ^self detect: aBlock ifNone: [NotFound new signal: 'nothing was found'] ]
Collection >> detect: aBlock ifNone: noneBlock [ self do: [:e | (aBlock value: e) ifTrue: [^e]]. ^noneBlock value ]
Collection >> inject: init into: aBlock [ | acc | acc := init. self do: [:e | acc := aBlock value: acc value: e]. ^acc ]
Collection >> allSatisfy: aBlock [ self do: [:e | (aBlock value: e) ifFalse: [^false]]. ^true ]
Collection >> anySatisfy: aBlock [ self do: [:e | (aBlock value: e) ifTrue: [^true]]. ^false ]
Collection >> count: aBlock [ | n | n := 0. self do: [:e | (aBlock value: e) ifTrue: [n := n + 1]]. ^n ]
Collection >> sum [ ^self inject: 0 into: [:a :b | a + b] ]
Collection >> max [ ^self inject: self anyOne into: [:a :b | a max: b] ]
Collection >> min [ ^self inject: self anyOne into: [:a :b | a min: b] ]
Collection >> copyEmpty [ ^self species new ]
Collection >> species [ ^self class ]
Collection >> asArray [ | a i | a := Array new: self size. i := 0. self do: [:e | a at: (i := i + 1) put: e]. ^a ]
Collection >> asOrderedCollection [ ^OrderedCollection new addAll: self; yourself ]
Collection >> asSet [ ^Set new addAll: self; yourself ]
Collection >> asBag [ ^self asOrderedCollection ]
Collection >> asSortedCollection [ ^self asArray sort ]
Collection >> asSortedCollection: aBlock [ ^self asArray sort: aBlock ]
Collection >> sorted [ ^self asArray sort ]
Collection >> sorted: aBlock [ ^self asArray sort: aBlock ]
Collection >> printOn: aStream [
    aStream nextPutAll: self class name; nextPutAll: ' ('.
    self do: [:e | aStream print: e] separatedBy: [aStream space].
    aStream nextPut: $) ]
Collection >> displayOn: aStream [
    aStream nextPutAll: self class name; nextPutAll: ' ('.
    self do: [:e | e displayOn: aStream] separatedBy: [aStream space].
    aStream nextPut: $) ]

"---- SequenceableCollection ------------------------------------------------------"

SequenceableCollection >> do: aBlock [ 1 to: self size do: [:i | aBlock value: (self at: i)] ]
SequenceableCollection >> doWithIndex: aBlock [ 1 to: self size do: [:i | aBlock value: (self at: i) value: i] ]
SequenceableCollection >> withIndexDo: aBlock [ 1 to: self size do: [:i | aBlock value: (self at: i) value: i] ]
SequenceableCollection >> keysAndValuesDo: aBlock [ 1 to: self size do: [:i | aBlock value: i value: (self at: i)] ]
SequenceableCollection >> reverseDo: aBlock [ self size to: 1 by: -1 do: [:i | aBlock value: (self at: i)] ]
SequenceableCollection >> with: other do: aBlock [ 1 to: self size do: [:i | aBlock value: (self at: i) value: (other at: i)] ]
SequenceableCollection >> with: other collect: aBlock [
    | out | out := self species new: self size.
    1 to: self size do: [:i | out at: i put: (aBlock value: (self at: i) value: (other at: i))].
    ^out ]
SequenceableCollection >> collect: aBlock [
    | out | out := self collectSpecies new: self size.
    1 to: self size do: [:i | out at: i put: (aBlock value: (self at: i))].
    ^out ]
SequenceableCollection >> collectSpecies [ ^Array ]
SequenceableCollection >> select: aBlock [
    | out | out := WriteStream on: (self species new: self size).
    self do: [:e | (aBlock value: e) ifTrue: [out nextPut: e]].
    ^out contents ]
SequenceableCollection >> first [ ^self at: 1 ]
SequenceableCollection >> second [ ^self at: 2 ]
SequenceableCollection >> third [ ^self at: 3 ]
SequenceableCollection >> last [ ^self at: self size ]
SequenceableCollection >> first: n [ ^self copyFrom: 1 to: n ]
SequenceableCollection >> last: n [ ^self copyFrom: self size - n + 1 to: self size ]
SequenceableCollection >> allButFirst [ ^self copyFrom: 2 to: self size ]
SequenceableCollection >> allButLast [ ^self copyFrom: 1 to: self size - 1 ]
SequenceableCollection >> isEmpty [ ^self size = 0 ]
SequenceableCollection >> indexOf: anObject [ ^self indexOf: anObject ifAbsent: [0] ]
SequenceableCollection >> indexOf: anObject ifAbsent: aBlock [
    1 to: self size do: [:i | (self at: i) = anObject ifTrue: [^i]].
    ^aBlock value ]
SequenceableCollection >> includes: anObject [ ^(self indexOf: anObject) > 0 ]
SequenceableCollection >> = other [
    self == other ifTrue: [^true].
    self species == other species ifFalse: [^false].
    self size = other size ifFalse: [^false].
    1 to: self size do: [:i | (self at: i) = (other at: i) ifFalse: [^false]].
    ^true ]
SequenceableCollection >> hash [ | h | h := self size. self do: [:e | h := (h * 31 + e hash) bitAnd: 16r3FFFFFFF]. ^h ]
SequenceableCollection >> copyFrom: start to: stop [
    | out n |
    n := stop - start + 1 max: 0.
    out := self species new: n.
    1 to: n do: [:i | out at: i put: (self at: start + i - 1)].
    ^out ]
SequenceableCollection >> copyWith: anObject [
    | out | out := self species new: self size + 1.
    1 to: self size do: [:i | out at: i put: (self at: i)].
    out at: out size put: anObject.
    ^out ]
SequenceableCollection >> copyWithout: anObject [ ^self reject: [:e | e = anObject] ]
SequenceableCollection >> , other [
    | out n |
    n := self size.
    out := self species new: n + other size.
    1 to: n do: [:i | out at: i put: (self at: i)].
    1 to: other size do: [:i | out at: n + i put: (other at: i)].
    ^out ]
SequenceableCollection >> reversed [
    | out n | n := self size. out := self species new: n.
    1 to: n do: [:i | out at: i put: (self at: n - i + 1)].
    ^out ]
SequenceableCollection >> reverse [ ^self reversed ]
SequenceableCollection >> readStream [ ^ReadStream on: self ]
SequenceableCollection >> writeStream [ ^WriteStream on: self ]
SequenceableCollection >> replaceFrom: start to: stop with: other startingAt: s [
    start to: stop do: [:i | self at: i put: (other at: s + i - start)] ]
SequenceableCollection >> replaceFrom: start to: stop with: other [ self replaceFrom: start to: stop with: other startingAt: 1 ]
SequenceableCollection >> swap: i with: j [ | t | t := self at: i. self at: i put: (self at: j). self at: j put: t ]
SequenceableCollection >> sort [ ^self sort: [:a :b | a <= b] ]
SequenceableCollection >> sort: aBlock [
    "In place: a merge sort, stable."
    | n src dst w tmp |
    n := self size.
    n < 2 ifTrue: [^self].
    src := Array new: n.
    1 to: n do: [:i | src at: i put: (self at: i)].
    dst := Array new: n.
    w := 1.
    [w < n] whileTrue: [
        1 to: n by: w * 2 do: [:lo |
            self merge: src into: dst from: lo mid: (lo + w min: n + 1) to: (lo + (2 * w) min: n + 1) by: aBlock].
        tmp := src. src := dst. dst := tmp.
        w := w * 2].
    1 to: n do: [:i | self at: i put: (src at: i)] ]
SequenceableCollection >> merge: src into: dst from: lo mid: mid to: hi by: aBlock [
    | i j k |
    i := lo. j := mid. k := lo.
    [k < hi] whileTrue: [
        (j >= hi or: [i < mid and: [aBlock value: (src at: i) value: (src at: j)]])
            ifTrue: [dst at: k put: (src at: i). i := i + 1]
            ifFalse: [dst at: k put: (src at: j). j := j + 1].
        k := k + 1] ]
SequenceableCollection >> asArray [ ^Array withAll: self ]
SequenceableCollection >> allOccurrencesOf: x [ ^self count: [:e | e = x] ]
SequenceableCollection >> indexOfSubCollection: sub [ ^self indexOfSubCollection: sub startingAt: 1 ]
SequenceableCollection >> indexOfSubCollection: sub startingAt: start [
    | n m ok |
    n := self size. m := sub size.
    start to: n - m + 1 do: [:i |
        ok := true.
        1 to: m do: [:j | (ok and: [(self at: i + j - 1) ~= (sub at: j)]) ifTrue: [ok := false]].
        ok ifTrue: [^i]].
    ^0 ]

ArrayedCollection class >> new [ ^self new: 0 ]
ArrayedCollection class >> new: n [ ^self basicNew: n ]
ArrayedCollection class >> new: n withAll: anObject [
    | a | a := self new: n. 1 to: n do: [:i | a at: i put: anObject]. ^a ]
ArrayedCollection class >> with: a [ ^(self new: 1) at: 1 put: a; yourself ]
ArrayedCollection class >> with: a with: b [ ^(self new: 2) at: 1 put: a; at: 2 put: b; yourself ]
ArrayedCollection class >> with: a with: b with: c [ ^(self new: 3) at: 1 put: a; at: 2 put: b; at: 3 put: c; yourself ]
ArrayedCollection class >> with: a with: b with: c with: d [
    ^(self new: 4) at: 1 put: a; at: 2 put: b; at: 3 put: c; at: 4 put: d; yourself ]
ArrayedCollection class >> withAll: aCollection [
    | a i | a := self new: aCollection size. i := 0.
    aCollection do: [:e | a at: (i := i + 1) put: e].
    ^a ]
ArrayedCollection >> size [ <primitive: 43> ]
ArrayedCollection >> add: anObject [ ^self shouldNotImplement ]
ArrayedCollection >> replaceFrom: start to: stop with: other startingAt: s [
    <primitive: 57>
    super replaceFrom: start to: stop with: other startingAt: s ]
ArrayedCollection >> copyFrom: start to: stop [
    | out n |
    n := stop - start + 1 max: 0.
    out := self species new: n.
    out replaceFrom: 1 to: n with: self startingAt: start.
    ^out ]
ArrayedCollection >> , other [
    | out n |
    n := self size.
    out := self species new: n + other size.
    out replaceFrom: 1 to: n with: self startingAt: 1.
    out replaceFrom: n + 1 to: out size with: other startingAt: 1.
    ^out ]

"---- Array ------------------------------------------------------------------------"

Array >> isArray [ ^true ]
Array >> printOn: aStream [
    aStream nextPut: $#; nextPut: $(.
    self do: [:e | e printInArrayOn: aStream] separatedBy: [aStream space].
    aStream nextPut: $) ]
Array >> displayOn: aStream [
    aStream nextPut: $(.
    self do: [:e | e displayOn: aStream] separatedBy: [aStream space].
    aStream nextPut: $) ]
Object >> printInArrayOn: aStream [ self printOn: aStream ]
Symbol >> printInArrayOn: aStream [ aStream nextPutAll: self ]
Array >> printInArrayOn: aStream [
    aStream nextPut: $(.
    self do: [:e | e printInArrayOn: aStream] separatedBy: [aStream space].
    aStream nextPut: $) ]
Array >> isLiteral [ ^self allSatisfy: [:e | e isLiteral] ]
Object >> isLiteral [ ^false ]

"---- String: bytes (UTF-8); at: answers a Character per byte ---------------------"

String class >> new: n [ ^self basicNew: n ]
String class >> with: aChar [ ^(self new: 1) at: 1 put: aChar; yourself ]
String class >> new: n withAll: aChar [ | s | s := self new: n. 1 to: n do: [:i | s at: i put: aChar]. ^s ]
String class >> cr [ ^self with: Character cr ]
String class >> tab [ ^self with: Character tab ]
String class >> space [ ^self with: Character space ]
String >> at: i [ <primitive: 60> ^self indexError: i ]
String >> at: i put: aChar [ <primitive: 61> ^self indexError: i ]
String >> isString [ ^true ]
String >> isLiteral [ ^true ]
String >> species [ ^String ]
String >> collectSpecies [ ^String ]
String >> = aString [
    <primitive: 58>
    ^false ]
String >> hash [ <primitive: 59> ]
String >> compare: aString [ <primitive: 63> ^self error: 'a string was expected' ]
String >> < aString [ ^(self compare: aString) < 0 ]
String >> > aString [ ^(self compare: aString) > 0 ]
String >> <= aString [ ^(self compare: aString) <= 0 ]
String >> >= aString [ ^(self compare: aString) >= 0 ]
String >> asString [ ^self ]
String >> asSymbol [ ^Symbol intern: self ]
String >> asUppercase [ ^self collect: [:c | c asUppercase] ]
String >> asLowercase [ ^self collect: [:c | c asLowercase] ]
String >> size [ <primitive: 43> ]
String >> isEmpty [ ^self size = 0 ]
String >> includesSubstring: aString [ ^(self indexOfSubCollection: aString) > 0 ]
String >> beginsWith: aString [ ^self size >= aString size and: [(self copyFrom: 1 to: aString size) = aString] ]
String >> endsWith: aString [ ^self size >= aString size and: [(self copyFrom: self size - aString size + 1 to: self size) = aString] ]
String >> asInteger [
    | n neg i c |
    n := 0. neg := false. i := 1.
    (self size > 0 and: [(self at: 1) = $-]) ifTrue: [neg := true. i := 2].
    i > self size ifTrue: [^nil].
    [i <= self size] whileTrue: [
        c := self at: i.
        c isDigit ifFalse: [^nil].
        n := n * 10 + c digitValue.
        i := i + 1].
    ^neg ifTrue: [0 - n] ifFalse: [n] ]
String >> asNumber [ ^self asInteger ]
String >> trimSeparators [
    | a b |
    a := 1. b := self size.
    [a <= b and: [(self at: a) isSeparator]] whileTrue: [a := a + 1].
    [b >= a and: [(self at: b) isSeparator]] whileTrue: [b := b - 1].
    ^self copyFrom: a to: b ]
String >> trimBoth [ ^self trimSeparators ]
String >> substrings [ ^self substrings: ' ' ]
String >> substrings: separators [
    | out start i |
    out := OrderedCollection new.
    i := 1.
    [i <= self size] whileTrue: [
        [i <= self size and: [separators includes: (self at: i)]] whileTrue: [i := i + 1].
        start := i.
        [i <= self size and: [(separators includes: (self at: i)) not]] whileTrue: [i := i + 1].
        i > start ifTrue: [out add: (self copyFrom: start to: i - 1)]].
    ^out ]
String >> lines [
    | out start |
    out := OrderedCollection new.
    start := 1.
    1 to: self size do: [:i | (self at: i) = Character cr ifTrue: [out add: (self copyFrom: start to: i - 1). start := i + 1]].
    start <= self size ifTrue: [out add: (self copyFrom: start to: self size)].
    ^out ]
String >> occurrencesOfString: aString [
    | n i | n := 0. i := 1.
    [(i := self indexOfSubCollection: aString startingAt: i) > 0] whileTrue: [n := n + 1. i := i + aString size].
    ^n ]
String >> copyReplaceAll: old with: new [
    | out i j |
    out := WriteStream on: (String new: self size).
    i := 1.
    [(j := self indexOfSubCollection: old startingAt: i) > 0] whileTrue: [
        out nextPutAll: (self copyFrom: i to: j - 1); nextPutAll: new.
        i := j + old size].
    out nextPutAll: (self copyFrom: i to: self size).
    ^out contents ]
String >> format: anArray [
    "'{1} and {2}' format: #(a b)"
    | out i c j |
    out := WriteStream on: (String new: self size).
    i := 1.
    [i <= self size] whileTrue: [
        c := self at: i.
        (c = ${ and: [(j := self indexOf: $} startingAt: i) > 0])
            ifTrue: [out nextPutAll: (anArray at: (self copyFrom: i + 1 to: j - 1) asInteger) displayString. i := j + 1]
            ifFalse: [out nextPut: c. i := i + 1]].
    ^out contents ]
SequenceableCollection >> indexOf: x startingAt: start [
    start to: self size do: [:i | (self at: i) = x ifTrue: [^i]].
    ^0 ]
String >> printOn: aStream [
    aStream nextPut: $'.
    self do: [:c | aStream nextPut: c. c = $' ifTrue: [aStream nextPut: c]].
    aStream nextPut: $' ]
String >> displayOn: aStream [ aStream nextPutAll: self ]
String >> displayString [ ^self ]
String >> keywords [
    | out start |
    out := OrderedCollection new.
    start := 1.
    1 to: self size do: [:i | (self at: i) = $: ifTrue: [out add: (self copyFrom: start to: i). start := i + 1]].
    start <= self size ifTrue: [out add: (self copyFrom: start to: self size)].
    ^out ]
String >> numArgs [
    | n |
    self size = 0 ifTrue: [^0].
    (self at: 1) isLetter ifFalse: [^1].
    n := self occurrencesOf: $:.
    ^n ]
String >> asByteArray [ | b | b := ByteArray new: self size. 1 to: self size do: [:i | b at: i put: (self at: i) value]. ^b ]

"---- Symbol: unique; made in far memory -----------------------------------------"

Symbol class >> intern: aString [
    | table i s n |
    table := Smalltalk symbolTable.
    n := table size.
    i := (aString hash bitAnd: n - 1) + 1.
    [(s := table at: i) == nil] whileFalse: [
        (s size = aString size and: [s sameAs: aString]) ifTrue: [^s].
        i := i \\ n + 1].
    s := Symbol basicNewFar: aString size.
    s replaceFrom: 1 to: aString size with: aString startingAt: 1.
    table at: i put: s.
    Smalltalk noteNewSymbol.
    ^s ]
Symbol class >> new: n [ ^self error: 'symbols are made with asSymbol' ]
String >> sameAs: aString [ <primitive: 58> ^false ]
Symbol >> isSymbol [ ^true ]
Symbol >> asSymbol [ ^self ]
Symbol >> asString [ | s | s := String new: self size. s replaceFrom: 1 to: self size with: self startingAt: 1. ^s ]
Symbol >> = anObject [ ^self == anObject ]
Symbol >> hash [ ^self identityHash ]
Symbol >> species [ ^String ]
Symbol >> printOn: aStream [ aStream nextPut: $#; nextPutAll: self ]
Symbol >> displayString [ ^self asString ]
Symbol >> value: anObject [ ^anObject perform: self ]
Symbol >> value: a value: b [ ^a perform: self with: b ]
Symbol >> cull: anObject [ ^anObject perform: self ]
Symbol >> numArgs [ ^self asString numArgs ]
Symbol >> shallowCopy [ ^self ]
Symbol >> deepCopy [ ^self ]
Symbol >> at: i put: c [ ^self error: 'symbols cannot be changed' ]

"---- ByteArray --------------------------------------------------------------------"

ByteArray >> isLiteral [ ^true ]
ByteArray >> asString [ | s | s := String new: self size. s replaceFrom: 1 to: self size with: self asStringBytes startingAt: 1. ^s ]
ByteArray >> asStringBytes [ | s | s := String new: self size. 1 to: self size do: [:i | s at: i put: (Character value: (self at: i))]. ^s ]
ByteArray >> printOn: aStream [
    aStream nextPutAll: '#['.
    self do: [:e | aStream print: e] separatedBy: [aStream space].
    aStream nextPut: $] ]

"---- OrderedCollection -------------------------------------------------------------"

OrderedCollection class >> new [ ^self new: 8 ]
OrderedCollection class >> new: n [ ^self basicNew setArray: (Array new: (n max: 4)) ]
OrderedCollection >> setArray: anArray [ array := anArray. firstIndex := anArray size // 2 + 1. lastIndex := firstIndex - 1 ]
OrderedCollection >> size [ ^lastIndex - firstIndex + 1 ]
OrderedCollection >> at: i [
    (i between: 1 and: lastIndex - firstIndex + 1) ifFalse: [^self indexError: i].
    ^array at: firstIndex + i - 1 ]
OrderedCollection >> at: i put: v [
    (i between: 1 and: lastIndex - firstIndex + 1) ifFalse: [^self indexError: i].
    ^array at: firstIndex + i - 1 put: v ]
OrderedCollection >> do: aBlock [ firstIndex to: lastIndex do: [:i | aBlock value: (array at: i)] ]
OrderedCollection >> add: v [ ^self addLast: v ]
OrderedCollection >> addLast: v [
    lastIndex = array size ifTrue: [self grow].
    lastIndex := lastIndex + 1.
    ^array at: lastIndex put: v ]
OrderedCollection >> addFirst: v [
    firstIndex = 1 ifTrue: [self grow].
    firstIndex := firstIndex - 1.
    ^array at: firstIndex put: v ]
OrderedCollection >> grow [
    | n new off |
    n := self size.
    new := Array new: array size * 2 + 4.
    off := new size - n // 2.
    new replaceFrom: off + 1 to: off + n with: array startingAt: firstIndex.
    array := new. firstIndex := off + 1. lastIndex := off + n ]
OrderedCollection >> removeFirst [
    | v |
    self isEmpty ifTrue: [^self error: 'the collection is empty'].
    v := array at: firstIndex. array at: firstIndex put: nil.
    firstIndex := firstIndex + 1.
    ^v ]
OrderedCollection >> removeLast [
    | v |
    self isEmpty ifTrue: [^self error: 'the collection is empty'].
    v := array at: lastIndex. array at: lastIndex put: nil.
    lastIndex := lastIndex - 1.
    ^v ]
OrderedCollection >> removeFirst: n [ | out | out := Array new: n. 1 to: n do: [:i | out at: i put: self removeFirst]. ^out ]
OrderedCollection >> removeIndex: i [
    | v |
    v := self at: i.
    array replaceFrom: firstIndex + i - 1 to: lastIndex - 1 with: array startingAt: firstIndex + i.
    array at: lastIndex put: nil.
    lastIndex := lastIndex - 1.
    ^v ]
OrderedCollection >> remove: v ifAbsent: aBlock [
    | i |
    i := self indexOf: v.
    i = 0 ifTrue: [^aBlock value].
    ^self removeIndex: i ]
OrderedCollection >> removeAll [ self setArray: (Array new: 8) ]
OrderedCollection >> insert: v before: i [
    self addLast: nil.
    self size to: i + 1 by: -1 do: [:j | self at: j put: (self at: j - 1)].
    ^self at: i put: v ]
OrderedCollection >> add: v beforeIndex: i [ ^self insert: v before: i ]
OrderedCollection >> species [ ^OrderedCollection ]
OrderedCollection >> copyEmpty [ ^OrderedCollection new ]
OrderedCollection >> collect: aBlock [ | out | out := OrderedCollection new: self size. self do: [:e | out addLast: (aBlock value: e)]. ^out ]
OrderedCollection >> select: aBlock [ | out | out := OrderedCollection new. self do: [:e | (aBlock value: e) ifTrue: [out addLast: e]]. ^out ]
OrderedCollection >> copyFrom: start to: stop [ | out | out := OrderedCollection new. start to: stop do: [:i | out add: (self at: i)]. ^out ]
OrderedCollection >> , other [ ^self copy addAll: other; yourself ]
OrderedCollection >> postCopy [ array := array copy ]
OrderedCollection >> reversed [ | out | out := OrderedCollection new. self reverseDo: [:e | out add: e]. ^out ]
SequenceableCollection class >> new: n [ ^self new ]

"---- Interval ------------------------------------------------------------------------"

Interval class >> from: a to: b by: s [ ^self basicNew setFrom: a to: b by: s ]
Interval >> setFrom: a to: b by: s [ start := a. stop := b. step := s ]
Interval >> size [ step > 0 ifTrue: [^stop - start // step + 1 max: 0]. ^start - stop // step negated + 1 max: 0 ]
Interval >> at: i [ (i between: 1 and: self size) ifFalse: [^self indexError: i]. ^start + (step * (i - 1)) ]
Interval >> do: aBlock [
    | i |
    i := start.
    step > 0
        ifTrue: [[i <= stop] whileTrue: [aBlock value: i. i := i + step]]
        ifFalse: [[i >= stop] whileTrue: [aBlock value: i. i := i + step]] ]
Interval >> collect: aBlock [ | out i | out := Array new: self size. i := 0. self do: [:e | out at: (i := i + 1) put: (aBlock value: e)]. ^out ]
Interval >> species [ ^Array ]
Interval >> printOn: aStream [
    aStream print: start; nextPutAll: ' to: '; print: stop.
    step = 1 ifFalse: [aStream nextPutAll: ' by: '; print: step] ]
Interval >> first [ ^start ]
Interval >> last [ ^stop - ((stop - start) \\ step) ]

"---- hashed collections: open addressing, the size a power of two ------------------"

HashedCollection class >> new [ ^self new: 8 ]
HashedCollection class >> new: n [
    | size |
    size := 8.
    [size < (n * 2)] whileTrue: [size := size * 2].
    ^self basicNew setTally: 0 array: (Array new: size) ]
HashedCollection >> setTally: n array: anArray [ tally := n. array := anArray ]
HashedCollection >> size [ ^tally ]
HashedCollection >> capacity [ ^array size ]
HashedCollection >> hashOf: key [ ^key hash ]
HashedCollection >> keyAt: index [ ^array at: index ]
HashedCollection >> sameKey: a as: b [ ^a = b ]
HashedCollection >> findIndex: key [
    "The index of key, or of the empty slot where it would go."
    | n i e |
    n := array size.
    i := ((self hashOf: key) bitAnd: n - 1) + 1.
    [(e := array at: i) == nil or: [self sameKey: (self keyOf: e) as: key]] whileFalse: [i := i \\ n + 1].
    ^i ]
HashedCollection >> keyOf: element [ ^element ]
HashedCollection >> grow [
    | old |
    old := array.
    array := Array new: old size * 2.
    old do: [:e | e == nil ifFalse: [array at: (self findIndex: (self keyOf: e)) put: e]] ]
HashedCollection >> checkGrow [ tally * 4 >= (array size * 3) ifTrue: [self grow] ]
HashedCollection >> rehashFrom: index [
    "after a removal at index: put back what follows it"
    | n i e |
    n := array size.
    i := index \\ n + 1.
    [(e := array at: i) == nil] whileFalse: [
        array at: i put: nil.
        array at: (self findIndex: (self keyOf: e)) put: e.
        i := i \\ n + 1] ]
HashedCollection >> do: aBlock [ array do: [:e | e == nil ifFalse: [aBlock value: (self valueOf: e)]] ]
HashedCollection >> valueOf: element [ ^element ]

Set >> add: anObject [
    | i |
    anObject == nil ifTrue: [^anObject].
    i := self findIndex: anObject.
    (array at: i) == nil ifTrue: [array at: i put: anObject. tally := tally + 1. self checkGrow].
    ^anObject ]
Set >> includes: anObject [ ^(array at: (self findIndex: anObject)) notNil ]
Set >> remove: anObject ifAbsent: aBlock [
    | i |
    i := self findIndex: anObject.
    (array at: i) == nil ifTrue: [^aBlock value].
    array at: i put: nil.
    tally := tally - 1.
    self rehashFrom: i.
    ^anObject ]
Set >> collect: aBlock [ | out | out := Set new. self do: [:e | out add: (aBlock value: e)]. ^out ]
Set >> printOn: aStream [
    aStream nextPutAll: self class name; nextPutAll: ' ('.
    self do: [:e | aStream print: e] separatedBy: [aStream space].
    aStream nextPut: $) ]
IdentitySet >> hashOf: key [ ^key identityHash ]
IdentitySet >> sameKey: a as: b [ ^a == b ]

Dictionary >> keyOf: assoc [ ^assoc key ]
Dictionary >> valueOf: assoc [ ^assoc value ]
Dictionary >> at: key [ ^self at: key ifAbsent: [KeyNotFound new signal: 'key not found: ', key printString] ]
Dictionary >> at: key ifAbsent: aBlock [
    | a |
    a := array at: (self findIndex: key).
    a == nil ifTrue: [^aBlock value].
    ^a value ]
Dictionary >> at: key ifPresent: aBlock [
    | a |
    a := array at: (self findIndex: key).
    a == nil ifTrue: [^nil].
    ^aBlock cull: a value ]
Dictionary >> at: key ifAbsentPut: aBlock [ ^self at: key ifAbsent: [self at: key put: aBlock value] ]
Dictionary >> at: key put: value [
    | i a |
    i := self findIndex: key.
    a := array at: i.
    a == nil
        ifTrue: [array at: i put: (Association key: key value: value). tally := tally + 1. self checkGrow]
        ifFalse: [a value: value].
    ^value ]
Dictionary >> associationAt: key ifAbsent: aBlock [
    | a |
    a := array at: (self findIndex: key).
    a == nil ifTrue: [^aBlock value].
    ^a ]
Dictionary >> add: anAssociation [
    | i |
    i := self findIndex: anAssociation key.
    (array at: i) == nil ifTrue: [tally := tally + 1].
    array at: i put: anAssociation.
    self checkGrow.
    ^anAssociation ]
Dictionary >> includesKey: key [ ^(array at: (self findIndex: key)) notNil ]
Dictionary >> includes: value [ self do: [:v | v = value ifTrue: [^true]]. ^false ]
Dictionary >> removeKey: key [ ^self removeKey: key ifAbsent: [KeyNotFound new signal: 'key not found: ', key printString] ]
Dictionary >> removeKey: key ifAbsent: aBlock [
    | i a |
    i := self findIndex: key.
    a := array at: i.
    a == nil ifTrue: [^aBlock value].
    array at: i put: nil.
    tally := tally - 1.
    self rehashFrom: i.
    ^a value ]
Dictionary >> keysAndValuesDo: aBlock [ array do: [:a | a == nil ifFalse: [aBlock value: a key value: a value]] ]
Dictionary >> associationsDo: aBlock [ array do: [:a | a == nil ifFalse: [aBlock value: a]] ]
Dictionary >> keysDo: aBlock [ array do: [:a | a == nil ifFalse: [aBlock value: a key]] ]
Dictionary >> associations [ | out | out := OrderedCollection new. self associationsDo: [:a | out add: a]. ^out ]
Dictionary >> keys [ | out | out := OrderedCollection new. self keysDo: [:k | out add: k]. ^out ]
Dictionary >> values [ | out | out := OrderedCollection new. self do: [:v | out add: v]. ^out ]
Dictionary >> keyAtValue: v [ self keysAndValuesDo: [:k :x | x = v ifTrue: [^k]]. ^nil ]
Dictionary >> collect: aBlock [ | out | out := OrderedCollection new. self do: [:v | out add: (aBlock value: v)]. ^out ]
Dictionary >> select: aBlock [
    | out | out := self class new.
    self associationsDo: [:a | (aBlock value: a value) ifTrue: [out at: a key put: a value]].
    ^out ]
Dictionary >> printOn: aStream [
    aStream nextPutAll: self class name; nextPutAll: ' ('.
    self associations do: [:a | aStream print: a] separatedBy: [aStream space].
    aStream nextPut: $) ]
IdentityDictionary >> hashOf: key [ ^key identityHash ]
IdentityDictionary >> sameKey: a as: b [ ^a == b ]

Association class >> key: k value: v [ ^self basicNew key: k value: v ]
Association >> key: k value: v [ key := k. value := v ]
Association >> key [ ^key ]
Association >> value [ ^value ]
Association >> value: v [ value := v ]
Association >> key: k [ key := k ]
Association >> printOn: aStream [ aStream print: key; nextPutAll: '->'; print: value ]
Association >> = other [ ^(other isKindOf: Association) and: [key = other key and: [value = other value]] ]
Association >> hash [ ^key hash ]

"---- method dictionaries: as the VM probes them -----------------------------------"

MethodDictionary class >> new [ ^self basicNewFar: 0 ]
MethodDictionary >> setEmpty [ tally := 0. keys := Array basicNewFar: 8. values := Array basicNewFar: 8 ]
MethodDictionary >> indexOf: aSymbol [
    | n i k |
    keys == nil ifTrue: [self setEmpty].
    n := keys size.
    i := (aSymbol identityHash bitAnd: n - 1) + 1.
    [(k := keys at: i) == nil or: [k == aSymbol]] whileFalse: [i := i \\ n + 1].
    ^i ]
MethodDictionary >> at: aSymbol ifAbsent: aBlock [
    | i |
    i := self indexOf: aSymbol.
    (keys at: i) == nil ifTrue: [^aBlock value].
    ^values at: i ]
MethodDictionary >> at: aSymbol [ ^self at: aSymbol ifAbsent: [KeyNotFound new signal: 'no method ', aSymbol] ]
MethodDictionary >> includesKey: aSymbol [ ^(self at: aSymbol ifAbsent: [nil]) notNil ]
MethodDictionary >> at: aSymbol put: aMethod [
    | i |
    i := self indexOf: aSymbol.
    (keys at: i) == nil ifTrue: [
        tally := tally + 1.
        tally * 2 > keys size ifTrue: [self grow. i := self indexOf: aSymbol]].
    keys at: i put: aSymbol.
    values at: i put: aMethod.
    ^aMethod ]
MethodDictionary >> grow [
    | ok ov |
    ok := keys. ov := values.
    keys := Array basicNewFar: ok size * 2. values := Array basicNewFar: ok size * 2.
    1 to: ok size do: [:j | (ok at: j) == nil ifFalse: [
        | i | i := self indexOf: (ok at: j). keys at: i put: (ok at: j). values at: i put: (ov at: j)]] ]
MethodDictionary >> removeKey: aSymbol ifAbsent: aBlock [
    | old |
    old := self at: aSymbol ifAbsent: [^aBlock value].
    self rebuildWithout: aSymbol.
    ^old ]
MethodDictionary >> rebuildWithout: aSymbol [
    | ok ov |
    ok := keys. ov := values.
    keys := Array basicNewFar: ok size. values := Array basicNewFar: ok size. tally := 0.
    1 to: ok size do: [:j | ((ok at: j) == nil or: [(ok at: j) == aSymbol]) ifFalse: [
        | i | i := self indexOf: (ok at: j). keys at: i put: (ok at: j). values at: i put: (ov at: j). tally := tally + 1]] ]
MethodDictionary >> keysDo: aBlock [ keys == nil ifFalse: [keys do: [:k | k == nil ifFalse: [aBlock value: k]]] ]
MethodDictionary >> keys [ | out | out := OrderedCollection new. self keysDo: [:k | out add: k]. ^out sort: [:a :b | a <= b] ]
MethodDictionary >> keysAndValuesDo: aBlock [
    keys == nil ifTrue: [^self].
    1 to: keys size do: [:i | (keys at: i) == nil ifFalse: [aBlock value: (keys at: i) value: (values at: i)]] ]
MethodDictionary >> size [ ^tally ]

"---- Point -----------------------------------------------------------------------------"

Point class >> x: ax y: ay [ ^self basicNew setX: ax y: ay ]
Point >> setX: ax y: ay [ x := ax. y := ay ]
Point >> x [ ^x ]
Point >> y [ ^y ]
Point >> + p [ ^p isNumber ifTrue: [Point x: x + p y: y + p] ifFalse: [Point x: x + p x y: y + p y] ]
Point >> - p [ ^p isNumber ifTrue: [Point x: x - p y: y - p] ifFalse: [Point x: x - p x y: y - p y] ]
Point >> * n [ ^Point x: x * n y: y * n ]
Point >> = p [ ^(p isKindOf: Point) and: [x = p x and: [y = p y]] ]
Point >> hash [ ^x hash bitXor: y hash ]
Point >> printOn: aStream [ aStream print: x; nextPut: $@; print: y ]
