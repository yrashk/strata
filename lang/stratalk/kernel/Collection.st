"Collection.st: collections. Arrays, strings, symbols, byte arrays,
 ordered collections, intervals, sets and dictionaries."

Object subclass: #Collection slots: ''.
"The abstract root of the collections: a group of elements that a
 subclass enumerates with do:. On top of do: (and add:, remove:ifAbsent:
 where a subclass has them) it builds counting, testing, searching,
 enumerating (collect:, select:, inject:into:) and converting
 (asArray, asSet, sorted). It has no slots.
 #(1 2 3) inject: 0 into: [:a :b | a + b] >>> 6"

Collection subclass: #SequenceableCollection slots: ''.
"An abstract Collection whose elements have an order and are reached by
 index, 1 to size, with at: and at:put:. Adds first, last, indexOf:,
 copying (copyFrom:to:, , and reversed), comparing element by element and
 an in-place stable merge sort. Its subclasses are ArrayedCollection,
 OrderedCollection and Interval.
 #(5 6 7) indexOf: 6 >>> 2"

SequenceableCollection subclass: #ArrayedCollection slots: ''.
"An abstract SequenceableCollection of fixed size, its elements stored in
 the object's own indexed slots: Array, String, Symbol and ByteArray. Made
 with new: (basicNew:, the VM puts an object over 2 KiB in the far heap);
 it cannot grow, so add: is refused. Copying uses the VM's block copy
 (primitive 57).
 (Array new: 3 withAll: 0) >>> #(0 0 0)"

ArrayedCollection variableSubclass: #Array slots: ''.
"A fixed-size sequence of any objects, indexed from 1; the result of most
 sequenceable collect: and select:. A literal #(...) is immutable: copy it
 before changing it. Prints as #(...), its elements printed.
 #(3 1 2) copy sort >>> #(1 2 3)"

ArrayedCollection byteSubclass: #String slots: ''.
"A fixed-size sequence of bytes holding UTF-8 text; at: answers one byte
 as a Character, so a character outside ASCII takes several indices.
 Comparison, equality and hashing are VM primitives over the bytes. Adds
 case conversion, searching, splitting, trimming, parsing an integer and
 format:. A literal 'string' is immutable.
 ('hello' copyFrom: 2 to: 4) asUppercase >>> 'ELL'"

String subclass: #Symbol slots: ''.
"A String that is unique: one Symbol per sequence of bytes, so Symbols are
 compared with == and hash by identity. Made with asSymbol or
 Symbol intern:, which looks it up in the system's symbol table and
 otherwise makes it in far memory. Symbols are selectors and global names;
 they cannot be changed, and as a block they send themselves (value:).
 #(1 2 3) collect: #negated >>> #(-1 -2 -3)"

ArrayedCollection byteSubclass: #ByteArray slots: ''.
"A fixed-size sequence of bytes, each answered as an Integer 0 to 255.
 Written #[1 2 3] and printed the same way; asString reads its bytes as a
 String.
 'AB' asByteArray >>> #[65 66]"

SequenceableCollection subclass: #OrderedCollection slots: 'array firstIndex lastIndex'.
"A SequenceableCollection that grows and shrinks at both ends: add: and
 addLast:, addFirst:, removeFirst and removeLast are cheap, insertion and
 removal in the middle shift the elements. array is the store, which is
 replaced by one twice as large when an end is reached; firstIndex and
 lastIndex bound the elements in it.
 (OrderedCollection new add: 3; addFirst: 4; yourself) >>> OrderedCollection (4 3)"

SequenceableCollection subclass: #Interval slots: 'start stop step'.
"An arithmetic progression of Integers from start to stop by step, kept
 as its three slots and not stored element by element. Made with
 Number to: and to:by:, or Interval from:to:by:; read-only. Its species
 is Array, so collect: and select: answer Arrays.
 (1 to: 10 by: 3) asArray >>> #(1 4 7 10)"

Collection subclass: #HashedCollection slots: 'tally array'.
"An abstract Collection kept in a hash table by open addressing with
 linear probing: array, whose size is a power of two, holds the elements
 or nil, and tally counts them. The table doubles when it is three
 quarters full. Subclasses say what the key of an element is and how keys
 hash and compare (hashOf:, sameKey:as:, keyOf:).
 Set new capacity >>> 16"

HashedCollection subclass: #Set slots: ''.
"A HashedCollection without duplicates, by = and hash. nil is never
 added. Enumerates in the order of its hash table, not the order of
 adding.
 (Set withAll: #(1 2 2 3)) size >>> 3"

Set subclass: #IdentitySet slots: ''.
"A Set that compares its elements with == and hashes them by identity.
 (IdentitySet new add: 'x'; add: 'x' copy; yourself) size >>> 2"

HashedCollection subclass: #Dictionary slots: ''.
"A HashedCollection of Associations, looked up by key (= and hash): at:,
 at:put:, removeKey:. Its elements, for do:, collect: and includes:, are
 the values. Enumerates in the order of its hash table.
 (Dictionary new at: #a put: 1; yourself) at: #a >>> 1"

Dictionary subclass: #IdentityDictionary slots: ''.
"A Dictionary that compares its keys with == and hashes them by identity:
 for keys such as Symbols or objects without their own =.
 | d | d := IdentityDictionary new. d at: 'k' put: 1. d includesKey: 'k' copy >>> false"

IdentityDictionary subclass: #SystemDictionary slots: ''.
"The class of Smalltalk, the single dictionary of global variables by
 Symbol (classes among them). Its methods, in System.st, OS.st and
 others, also reach the VM and StrataOS: the symbol and class tables,
 standard input and output, the OS servers.
 (Smalltalk at: #Array) == Array >>> true"

Object subclass: #Association slots: 'key value'.
"A key and a value, paired: what a Dictionary holds and answers from
 associationsDo:. Made with -> on any object, or Association key:value:.
 key and value are its two slots, both settable.
 (3 -> 4) value >>> 4"

Object subclass: #MethodDictionary slots: 'tally keys values'.
"A class's methods by selector, laid out for the VM's method lookup:
 keys and values are two parallel far Arrays whose size is a power of
 two, probed linearly from the selector's identity hash; tally counts the
 methods. The arrays double when half full. Reached with a class's
 methodDict.
 (Array methodDict includesKey: #isArray) >>> true"

Object subclass: #Point slots: 'x y'.
"A pair of coordinates x and y, made with Number @ or Point x:y:. Adds,
 subtracts and multiplies by a number or another Point; = compares both
 coordinates.
 (3 @ 4) + (1 @ 1) >>> 4@5"

"---- Collection -----------------------------------------------------------------"

Collection class >> with: a [
    "Answers a new collection holding a.
     (OrderedCollection with: 1) >>> OrderedCollection (1)"
    ^self new add: a; yourself ]
Collection class >> with: a with: b [
    "Answers a new collection holding a and b, added in that order.
     (OrderedCollection with: 1 with: 2) >>> OrderedCollection (1 2)"
    ^self new add: a; add: b; yourself ]
Collection class >> with: a with: b with: c [
    "Answers a new collection holding a, b and c, added in that order.
     (OrderedCollection with: 1 with: 2 with: 3) >>> OrderedCollection (1 2 3)"
    ^self new add: a; add: b; add: c; yourself ]
Collection class >> with: a with: b with: c with: d [
    "Answers a new collection holding a, b, c and d, added in that order.
     (OrderedCollection with: 1 with: 2 with: 3 with: 4) size >>> 4"
    ^self new add: a; add: b; add: c; add: d; yourself ]
Collection class >> withAll: aCollection [
    "Answers a new collection holding the elements of aCollection.
     (OrderedCollection withAll: #(3 4)) >>> OrderedCollection (3 4)"
    ^self new addAll: aCollection; yourself ]
Collection >> isCollection [
    "Answers true: the receiver is a collection.
     #(1 2) isCollection >>> true"
    ^true ]
Collection >> do: aBlock [
    "Evaluates aBlock with each element. Every concrete subclass defines it;
     here it signals an Error (subclassResponsibility)."
    ^self subclassResponsibility ]
Collection >> add: anObject [
    "Adds anObject and answers it. Defined by the collections that can
     grow; here it signals an Error (subclassResponsibility)."
    ^self subclassResponsibility ]
Collection >> addAll: aCollection [
    "Adds each element of aCollection, in its order, and answers aCollection.
     (OrderedCollection new addAll: #(1 2); yourself) >>> OrderedCollection (1 2)"
    aCollection do: [:e | self add: e]. ^aCollection ]
Collection >> remove: anObject [
    "Removes one element equal to anObject and answers anObject. Signals
     NotFound if there is none.
     (OrderedCollection withAll: #(1 2 3)) remove: 2; yourself >>> OrderedCollection (1 3)"
    ^self remove: anObject ifAbsent: [NotFound new signal: 'not found'] ]
Collection >> removeAll: aCollection [
    "Removes each element of aCollection with remove: and answers
     aCollection; signals NotFound for one that is not there.
     (OrderedCollection withAll: #(1 2 3 4)) removeAll: #(1 3); yourself >>> OrderedCollection (2 4)"
    aCollection do: [:e | self remove: e]. ^aCollection ]
Collection >> size [
    "The number of elements, counted with do:. Most subclasses answer it
     directly.
     (1 to: 5) size >>> 5"
    | n | n := 0. self do: [:e | n := n + 1]. ^n ]
Collection >> isEmpty [
    "Answers whether the collection has no elements.
     #() isEmpty >>> true"
    ^self size = 0 ]
Collection >> notEmpty [
    "Answers whether the collection has an element.
     #(1) notEmpty >>> true"
    ^self isEmpty not ]
Collection >> isEmptyOrNil [
    "Answers whether the collection is empty; nil answers true too.
     #() isEmptyOrNil >>> true"
    ^self isEmpty ]
Collection >> ifEmpty: aBlock [
    "Answers aBlock's value if the collection is empty, and the collection
     otherwise.
     #() ifEmpty: ['none'] >>> 'none'"
    ^self isEmpty ifTrue: [aBlock value] ifFalse: [self] ]
Collection >> ifNotEmpty: aBlock [
    "Answers aBlock's value, given the collection if it takes an argument,
     if the collection has elements; the collection itself otherwise.
     #(1 2) ifNotEmpty: [:c | c size] >>> 2"
    ^self isEmpty ifTrue: [self] ifFalse: [aBlock cull: self] ]
Collection >> includesIdentity: anObject [
    "Answers whether anObject itself (==) is an element.
     #(#a #b) includesIdentity: #a >>> true"
    self do: [:e | e == anObject ifTrue: [^true]]. ^false ]
Collection >> includes: anObject [
    "Answers whether an element is equal (=) to anObject.
     #(1 2 3) includes: 2 >>> true"
    self do: [:e | e = anObject ifTrue: [^true]]. ^false ]
Collection >> occurrencesOf: anObject [
    "The number of elements equal to anObject.
     #(1 2 1 1) occurrencesOf: 1 >>> 3"
    | n | n := 0. self do: [:e | e = anObject ifTrue: [n := n + 1]]. ^n ]
Collection >> anyOne [
    "Answers the first element that do: gives. Signals an Error (error:) if
     the collection is empty.
     #(7 8) anyOne >>> 7"
    self do: [:e | ^e]. ^self error: 'the collection is empty' ]
Collection >> do: aBlock separatedBy: sepBlock [
    "Evaluates aBlock with each element and sepBlock, with no argument,
     between two of them.
     | s | s := WriteStream on: String new. #(1 2 3) do: [:e | s print: e] separatedBy: [s nextPutAll: ', ']. s contents >>> '1, 2, 3'"
    | first |
    first := true.
    self do: [:e | first ifTrue: [first := false] ifFalse: [sepBlock value]. aBlock value: e] ]
Collection >> collect: aBlock [
    "Answers an OrderedCollection of aBlock's values for each element.
     Sequenceable collections, Sets and Dictionaries have their own."
    | out | out := OrderedCollection new. self do: [:e | out add: (aBlock value: e)]. ^out ]
Collection >> select: aBlock [
    "Answers a collection like the receiver (copyEmpty) with the elements
     for which aBlock answers true.
     ((Set withAll: #(1 2 3 4)) select: [:e | e even]) size >>> 2"
    | out | out := self copyEmpty. self do: [:e | (aBlock value: e) ifTrue: [out add: e]]. ^out ]
Collection >> reject: aBlock [
    "Answers the elements for which aBlock answers false, as select: does.
     #(1 2 3 4) reject: [:e | e even] >>> #(1 3)"
    ^self select: [:e | (aBlock value: e) not] ]
Collection >> detect: aBlock [
    "Answers the first element for which aBlock answers true. Signals
     NotFound if there is none.
     #(1 2 3 4) detect: [:e | e > 2] >>> 3"
    ^self detect: aBlock ifNone: [NotFound new signal: 'nothing was found'] ]
Collection >> detect: aBlock ifNone: noneBlock [
    "Answers the first element for which aBlock answers true, or
     noneBlock's value if there is none.
     #(1 2) detect: [:e | e > 2] ifNone: [0] >>> 0"
    self do: [:e | (aBlock value: e) ifTrue: [^e]]. ^noneBlock value ]
Collection >> inject: init into: aBlock [
    "Folds the elements: aBlock gets the value so far (init at first) and
     an element, and its value is the next value so far; answers the last.
     #(1 2 3) inject: 0 into: [:a :b | a + b] >>> 6"
    | acc | acc := init. self do: [:e | acc := aBlock value: acc value: e]. ^acc ]
Collection >> allSatisfy: aBlock [
    "Answers whether aBlock answers true for every element (true if empty).
     #(2 4) allSatisfy: [:e | e even] >>> true"
    self do: [:e | (aBlock value: e) ifFalse: [^false]]. ^true ]
Collection >> anySatisfy: aBlock [
    "Answers whether aBlock answers true for some element.
     #(1 2) anySatisfy: [:e | e > 1] >>> true"
    self do: [:e | (aBlock value: e) ifTrue: [^true]]. ^false ]
Collection >> count: aBlock [
    "The number of elements for which aBlock answers true.
     #(1 2 3) count: [:e | e odd] >>> 2"
    | n | n := 0. self do: [:e | (aBlock value: e) ifTrue: [n := n + 1]]. ^n ]
Collection >> sum [
    "The sum of the elements, 0 if there are none.
     #(1 2 3) sum >>> 6"
    ^self inject: 0 into: [:a :b | a + b] ]
Collection >> max [
    "The largest element, by max:. Signals an Error (error:) if the
     collection is empty.
     #(3 9 2) max >>> 9"
    ^self inject: self anyOne into: [:a :b | a max: b] ]
Collection >> min [
    "The smallest element, by min:. Signals an Error (error:) if the
     collection is empty.
     #(3 9 2) min >>> 2"
    ^self inject: self anyOne into: [:a :b | a min: b] ]
Collection >> copyEmpty [
    "Answers a new, empty collection of the receiver's species.
     #(1 2) copyEmpty >>> #()"
    ^self species new ]
Collection >> species [
    "The class that copies and results like the receiver are made of: its
     own class here.
     #(1 2) species >>> Array"
    ^self class ]
Collection >> asArray [
    "Answers an Array of the elements, in the order of do:.
     (Set withAll: #(5)) asArray >>> #(5)"
    | a i | a := Array new: self size. i := 0. self do: [:e | a at: (i := i + 1) put: e]. ^a ]
Collection >> asOrderedCollection [
    "Answers a new OrderedCollection of the elements.
     #(1 2) asOrderedCollection >>> OrderedCollection (1 2)"
    ^OrderedCollection new addAll: self; yourself ]
Collection >> asSet [
    "Answers a new Set of the elements, without duplicates.
     #(1 1 2) asSet size >>> 2"
    ^Set new addAll: self; yourself ]
Collection >> asBag [
    "Answers the elements as an OrderedCollection: there is no Bag class.
     #(1 2) asBag >>> OrderedCollection (1 2)"
    ^self asOrderedCollection ]
Collection >> asSortedCollection [
    "Answers the elements sorted ascending by <=, as an Array: there is no
     SortedCollection class.
     #(3 1 2) asSortedCollection >>> #(1 2 3)"
    ^self asArray sort ]
Collection >> asSortedCollection: aBlock [
    "Answers the elements sorted by aBlock (true when its first argument
     goes first), as an Array.
     #(3 1 2) asSortedCollection: [:a :b | a > b] >>> #(3 2 1)"
    ^self asArray sort: aBlock ]
Collection >> sorted [
    "Answers a new Array of the elements sorted ascending by <=; the
     receiver is unchanged.
     #(3 1 2) sorted >>> #(1 2 3)"
    ^self asArray sort ]
Collection >> sorted: aBlock [
    "Answers a new Array of the elements sorted by aBlock (true when its
     first argument goes first), stably.
     #(3 1 2) sorted: [:a :b | a > b] >>> #(3 2 1)"
    ^self asArray sort: aBlock ]
Collection >> printOn: aStream [
    "Prints the class name and the elements, printed, in parentheses.
     (OrderedCollection withAll: #(1 $a 'b')) printString >>> 'OrderedCollection (1 $a ''b'')'"
    aStream nextPutAll: self class name; nextPutAll: ' ('.
    self do: [:e | aStream print: e] separatedBy: [aStream space].
    aStream nextPut: $) ]
Collection >> displayOn: aStream [
    "Prints the class name and the elements, displayed (strings without
     quotes), in parentheses.
     (OrderedCollection withAll: #(1 $a 'b')) displayString >>> 'OrderedCollection (1 a b)'"
    aStream nextPutAll: self class name; nextPutAll: ' ('.
    self do: [:e | e displayOn: aStream] separatedBy: [aStream space].
    aStream nextPut: $) ]

"---- SequenceableCollection ------------------------------------------------------"

SequenceableCollection >> do: aBlock [
    "Evaluates aBlock with each element, from index 1 to size.
     | s | s := 0. #(1 2 3) do: [:e | s := s + e]. s >>> 6"
    1 to: self size do: [:i | aBlock value: (self at: i)] ]
SequenceableCollection >> doWithIndex: aBlock [
    "Evaluates aBlock with each element and its index, in order.
     | s | s := 0. #(10 20) doWithIndex: [:e :i | s := s + (e * i)]. s >>> 50"
    1 to: self size do: [:i | aBlock value: (self at: i) value: i] ]
SequenceableCollection >> withIndexDo: aBlock [
    "Evaluates aBlock with each element and its index, in order; the same
     as doWithIndex:.
     | s | s := 0. #(10 20) withIndexDo: [:e :i | s := s + (e * i)]. s >>> 50"
    1 to: self size do: [:i | aBlock value: (self at: i) value: i] ]
SequenceableCollection >> keysAndValuesDo: aBlock [
    "Evaluates aBlock with each index and the element there, in order.
     | s | s := 0. #(10 20) keysAndValuesDo: [:i :e | s := s + (e * i)]. s >>> 50"
    1 to: self size do: [:i | aBlock value: i value: (self at: i)] ]
SequenceableCollection >> reverseDo: aBlock [
    "Evaluates aBlock with each element, from the last to the first.
     | o | o := OrderedCollection new. #(1 2 3) reverseDo: [:e | o add: e]. o >>> OrderedCollection (3 2 1)"
    self size to: 1 by: -1 do: [:i | aBlock value: (self at: i)] ]
SequenceableCollection >> with: other do: aBlock [
    "Evaluates aBlock with each element and the element of other at the
     same index; other must be at least as long.
     | s | s := 0. #(1 2) with: #(10 20) do: [:a :b | s := s + (a * b)]. s >>> 50"
    1 to: self size do: [:i | aBlock value: (self at: i) value: (other at: i)] ]
SequenceableCollection >> with: other collect: aBlock [
    "Answers a collection of the species of aBlock's values for each
     element and the element of other at the same index.
     #(1 2) with: #(10 20) collect: [:a :b | a + b] >>> #(11 22)"
    | out | out := self species new: self size.
    1 to: self size do: [:i | out at: i put: (aBlock value: (self at: i) value: (other at: i))].
    ^out ]
SequenceableCollection >> collect: aBlock [
    "Answers a collection of collectSpecies (an Array, a String for
     Strings) of aBlock's value for each element, in order.
     #(1 2 3) collect: [:e | e * e] >>> #(1 4 9)"
    | out | out := self collectSpecies new: self size.
    1 to: self size do: [:i | out at: i put: (aBlock value: (self at: i))].
    ^out ]
SequenceableCollection >> collectSpecies [
    "The class of what collect: answers: Array.
     (1 to: 3) collectSpecies >>> Array"
    ^Array ]
SequenceableCollection >> select: aBlock [
    "Answers a collection of the receiver's species with the elements for
     which aBlock answers true, in order.
     #(1 2 3 4) select: [:e | e even] >>> #(2 4)"
    | out | out := WriteStream on: (self species new: self size).
    self do: [:e | (aBlock value: e) ifTrue: [out nextPut: e]].
    ^out contents ]
SequenceableCollection >> first [
    "The first element. Signals SubscriptOutOfBounds if empty.
     #(5 6 7) first >>> 5"
    ^self at: 1 ]
SequenceableCollection >> second [
    "The second element.
     #(5 6 7) second >>> 6"
    ^self at: 2 ]
SequenceableCollection >> third [
    "The third element.
     #(5 6 7) third >>> 7"
    ^self at: 3 ]
SequenceableCollection >> last [
    "The last element. Signals SubscriptOutOfBounds if empty.
     #(5 6 7) last >>> 7"
    ^self at: self size ]
SequenceableCollection >> first: n [
    "Answers a copy of the first n elements.
     #(5 6 7) first: 2 >>> #(5 6)"
    ^self copyFrom: 1 to: n ]
SequenceableCollection >> last: n [
    "Answers a copy of the last n elements.
     #(5 6 7) last: 2 >>> #(6 7)"
    ^self copyFrom: self size - n + 1 to: self size ]
SequenceableCollection >> allButFirst [
    "Answers a copy without the first element.
     #(5 6 7) allButFirst >>> #(6 7)"
    ^self copyFrom: 2 to: self size ]
SequenceableCollection >> allButLast [
    "Answers a copy without the last element.
     #(5 6 7) allButLast >>> #(5 6)"
    ^self copyFrom: 1 to: self size - 1 ]
SequenceableCollection >> isEmpty [
    "Answers whether the size is 0.
     '' isEmpty >>> true"
    ^self size = 0 ]
SequenceableCollection >> indexOf: anObject [
    "The index of the first element equal to anObject, or 0.
     #(5 6 7) indexOf: 6 >>> 2"
    ^self indexOf: anObject ifAbsent: [0] ]
SequenceableCollection >> indexOf: anObject ifAbsent: aBlock [
    "The index of the first element equal to anObject, or aBlock's value
     if there is none.
     #(5 6 7) indexOf: 9 ifAbsent: [-1] >>> -1"
    1 to: self size do: [:i | (self at: i) = anObject ifTrue: [^i]].
    ^aBlock value ]
SequenceableCollection >> includes: anObject [
    "Answers whether an element is equal to anObject.
     #(5 6 7) includes: 7 >>> true"
    ^(self indexOf: anObject) > 0 ]
SequenceableCollection >> = other [
    "Answers whether other has the same species, the same size and equal
     elements at each index. An Interval's species is Array, so it can
     equal an Array.
     (1 to: 3) = #(1 2 3) >>> true"
    self == other ifTrue: [^true].
    self species == other species ifFalse: [^false].
    self size = other size ifFalse: [^false].
    1 to: self size do: [:i | (self at: i) = (other at: i) ifFalse: [^false]].
    ^true ]
SequenceableCollection >> hash [
    "A hash of the size and the elements' hashes, 30 bits, consistent with =.
     #(1 2) hash = #(1 2) copy hash >>> true"
    | h | h := self size. self do: [:e | h := (h * 31 + e hash) bitAnd: 16r3FFFFFFF]. ^h ]
SequenceableCollection >> copyFrom: start to: stop [
    "Answers a new collection of the species with the elements from start
     to stop (empty if stop is before start). Signals SubscriptOutOfBounds
     for an index outside the receiver.
     #(5 6 7 8) copyFrom: 2 to: 3 >>> #(6 7)"
    | out n |
    n := stop - start + 1 max: 0.
    out := self species new: n.
    1 to: n do: [:i | out at: i put: (self at: start + i - 1)].
    ^out ]
SequenceableCollection >> copyWith: anObject [
    "Answers a copy one longer, anObject at the end.
     #(1 2) copyWith: 3 >>> #(1 2 3)"
    | out | out := self species new: self size + 1.
    1 to: self size do: [:i | out at: i put: (self at: i)].
    out at: out size put: anObject.
    ^out ]
SequenceableCollection >> copyWithout: anObject [
    "Answers a copy without the elements equal to anObject.
     #(1 2 1 3) copyWithout: 1 >>> #(2 3)"
    ^self reject: [:e | e = anObject] ]
SequenceableCollection >> , other [
    "Answers a new collection of the species: the receiver's elements, then
     other's.
     (1 to: 2) , #(3) >>> #(1 2 3)"
    | out n |
    n := self size.
    out := self species new: n + other size.
    1 to: n do: [:i | out at: i put: (self at: i)].
    1 to: other size do: [:i | out at: n + i put: (other at: i)].
    ^out ]
SequenceableCollection >> reversed [
    "Answers a new collection of the species with the elements in reverse
     order.
     #(1 2 3) reversed >>> #(3 2 1)"
    | out n | n := self size. out := self species new: n.
    1 to: n do: [:i | out at: i put: (self at: n - i + 1)].
    ^out ]
SequenceableCollection >> reverse [
    "Answers a reversed copy, as reversed does.
     'abc' reverse >>> 'cba'"
    ^self reversed ]
SequenceableCollection >> readStream [
    "Answers a ReadStream over the elements.
     'abc' readStream next >>> $a"
    ^ReadStream on: self ]
SequenceableCollection >> writeStream [
    "Answers a WriteStream that writes over the receiver from its start.
     ((Array new: 2) writeStream nextPut: 3; contents) >>> #(3)"
    ^WriteStream on: self ]
SequenceableCollection >> replaceFrom: start to: stop with: other startingAt: s [
    "Puts other's elements from index s into the receiver at start to stop,
     one at a time, and answers the receiver.
     (OrderedCollection withAll: #(1 2 3)) replaceFrom: 1 to: 2 with: #(7 8 9) startingAt: 2; yourself >>> OrderedCollection (8 9 3)"
    start to: stop do: [:i | self at: i put: (other at: s + i - start)] ]
SequenceableCollection >> replaceFrom: start to: stop with: other [
    "Puts other's elements, from its first, into the receiver at start to
     stop, and answers the receiver.
     (Array new: 3) replaceFrom: 1 to: 2 with: #(7 8); yourself >>> #(7 8 nil)"
    self replaceFrom: start to: stop with: other startingAt: 1 ]
SequenceableCollection >> swap: i with: j [
    "Exchanges the elements at indices i and j.
     #(1 2 3) copy swap: 1 with: 3; yourself >>> #(3 2 1)"
    | t | t := self at: i. self at: i put: (self at: j). self at: j put: t ]
SequenceableCollection >> sort [
    "Sorts the elements in place, ascending by <=, and answers the receiver.
     #(3 1 2) copy sort >>> #(1 2 3)"
    ^self sort: [:a :b | a <= b] ]
SequenceableCollection >> sort: aBlock [
    "Sorts the elements in place by aBlock, which answers true when its
     first argument goes before its second, and answers the receiver. A
     merge sort, stable, through two scratch Arrays; the receiver needs
     at:put: (not an Interval or a literal).
     #(3 1 2) copy sort: [:a :b | a > b] >>> #(3 2 1)"
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
    "One step of sort:: merges the sorted runs src lo to mid - 1 and mid to
     hi - 1 into dst lo to hi - 1, the left run first on a tie."
    | i j k |
    i := lo. j := mid. k := lo.
    [k < hi] whileTrue: [
        (j >= hi or: [i < mid and: [aBlock value: (src at: i) value: (src at: j)]])
            ifTrue: [dst at: k put: (src at: i). i := i + 1]
            ifFalse: [dst at: k put: (src at: j). j := j + 1].
        k := k + 1] ]
SequenceableCollection >> asArray [
    "Answers a new Array of the elements.
     (1 to: 3) asArray >>> #(1 2 3)"
    ^Array withAll: self ]
SequenceableCollection >> allOccurrencesOf: x [
    "The number of elements equal to x.
     #(1 2 1 1) allOccurrencesOf: 1 >>> 3"
    ^self count: [:e | e = x] ]
SequenceableCollection >> indexOfSubCollection: sub [
    "The index where the first run of elements equal to sub's begins, or 0.
     'hello world' indexOfSubCollection: 'world' >>> 7"
    ^self indexOfSubCollection: sub startingAt: 1 ]
SequenceableCollection >> indexOfSubCollection: sub startingAt: start [
    "The index, start or after, where the first run of elements equal to
     sub's begins, or 0. An empty sub is found at start.
     'abcabc' indexOfSubCollection: 'bc' startingAt: 3 >>> 5"
    | n m ok |
    n := self size. m := sub size.
    start to: n - m + 1 do: [:i |
        ok := true.
        1 to: m do: [:j | (ok and: [(self at: i + j - 1) ~= (sub at: j)]) ifTrue: [ok := false]].
        ok ifTrue: [^i]].
    ^0 ]

ArrayedCollection class >> new [
    "Answers an empty instance.
     Array new >>> #()"
    ^self new: 0 ]
ArrayedCollection class >> new: n [
    "Answers an instance of n elements, each nil (0 for bytes). The VM
     makes it in the far heap when it is over 2 KiB.
     Array new: 3 >>> #(nil nil nil)"
    ^self basicNew: n ]
ArrayedCollection class >> new: n withAll: anObject [
    "Answers an instance of n elements, each anObject.
     Array new: 3 withAll: 0 >>> #(0 0 0)"
    | a | a := self new: n. 1 to: n do: [:i | a at: i put: anObject]. ^a ]
ArrayedCollection class >> with: a [
    "Answers an instance holding a.
     Array with: 1 >>> #(1)"
    ^(self new: 1) at: 1 put: a; yourself ]
ArrayedCollection class >> with: a with: b [
    "Answers an instance holding a and b.
     Array with: 1 with: 2 >>> #(1 2)"
    ^(self new: 2) at: 1 put: a; at: 2 put: b; yourself ]
ArrayedCollection class >> with: a with: b with: c [
    "Answers an instance holding a, b and c.
     Array with: 1 with: 2 with: 3 >>> #(1 2 3)"
    ^(self new: 3) at: 1 put: a; at: 2 put: b; at: 3 put: c; yourself ]
ArrayedCollection class >> with: a with: b with: c with: d [
    "Answers an instance holding a, b, c and d.
     Array with: 1 with: 2 with: 3 with: 4 >>> #(1 2 3 4)"
    ^(self new: 4) at: 1 put: a; at: 2 put: b; at: 3 put: c; at: 4 put: d; yourself ]
ArrayedCollection class >> with: a with: b with: c with: d with: e [
    "Answers an instance holding a, b, c, d and e.
     Array with: 1 with: 2 with: 3 with: 4 with: 5 >>> #(1 2 3 4 5)"
    ^(self new: 5) at: 1 put: a; at: 2 put: b; at: 3 put: c; at: 4 put: d; at: 5 put: e; yourself ]
ArrayedCollection class >> withAll: aCollection [
    "Answers an instance holding the elements of aCollection, in the order
     of its do:.
     Array withAll: (1 to: 3) >>> #(1 2 3)"
    | a i | a := self new: aCollection size. i := 0.
    aCollection do: [:e | a at: (i := i + 1) put: e].
    ^a ]
ArrayedCollection >> size [
    "The number of indexed elements. A VM primitive (43, basicSize).
     #(1 2 3) size >>> 3"
    <primitive: 43> ]
ArrayedCollection >> add: anObject [
    "Signals an Error (shouldNotImplement): an arrayed collection has a
     fixed size. Use copyWith: or an OrderedCollection."
    ^self shouldNotImplement ]
ArrayedCollection >> replaceFrom: start to: stop with: other startingAt: s [
    "Puts other's elements from index s into the receiver at start to stop,
     and answers the receiver. A VM primitive (57) when both have the same
     format (pointers or bytes); otherwise element by element, which
     signals SubscriptOutOfBounds for an index outside either.
     (Array new: 5) replaceFrom: 2 to: 3 with: #(7 8 9) startingAt: 2; yourself >>> #(nil 8 9 nil nil)"
    <primitive: 57>
    super replaceFrom: start to: stop with: other startingAt: s ]
ArrayedCollection >> copyFrom: start to: stop [
    "Answers a new instance of the species with the elements from start to
     stop (empty if stop is before start), copied by replaceFrom:to:with:startingAt:.
     'hello' copyFrom: 2 to: 4 >>> 'ell'"
    | out n |
    n := stop - start + 1 max: 0.
    out := self species new: n.
    out replaceFrom: 1 to: n with: self startingAt: start.
    ^out ]
ArrayedCollection >> , other [
    "Answers a new instance of the species: the receiver's elements, then
     other's, by block copies.
     'ab' , 'cd' >>> 'abcd'"
    | out n |
    n := self size.
    out := self species new: n + other size.
    out replaceFrom: 1 to: n with: self startingAt: 1.
    out replaceFrom: n + 1 to: out size with: other startingAt: 1.
    ^out ]

"---- Array ------------------------------------------------------------------------"

Array >> isArray [
    "Answers true: the receiver is an Array.
     #(1) isArray >>> true"
    ^true ]
Array >> printOn: aStream [
    "Prints #( and the elements, printed, then ).
     #(1 $a 'b' #c) printString >>> '#(1 $a ''b'' #c)'"
    aStream nextPut: $#; nextPut: $(.
    self do: [:e | aStream print: e] separatedBy: [aStream space].
    aStream nextPut: $) ]
Array >> displayOn: aStream [
    "Prints ( and the elements, displayed, then ).
     #(1 $a 'b' #c) displayString >>> '(1 a b c)'"
    aStream nextPut: $(.
    self do: [:e | e displayOn: aStream] separatedBy: [aStream space].
    aStream nextPut: $) ]
Array >> isLiteral [
    "Answers whether every element answers true to isLiteral (numbers,
     Characters, Strings, Symbols, ByteArrays, such Arrays).
     #('a' #b 3 $c) isLiteral >>> true"
    ^self allSatisfy: [:e | e isLiteral] ]
Object >> isLiteral [
    "Answers whether the object could be written as a literal inside an
     array literal: false here; numbers, Characters, Strings, Symbols,
     ByteArrays and Arrays of them answer true.
     Object new isLiteral >>> false"
    ^false ]

"---- String: bytes (UTF-8); at: answers a Character per byte ---------------------"

String class >> new: n [
    "Answers a String of n bytes, each 0. The VM makes it in the far heap
     when it is over 2 KiB.
     (String new: 3) size >>> 3"
    ^self basicNew: n ]
String class >> with: aChar [
    "Answers a String of the one character aChar.
     String with: $a >>> 'a'"
    ^(self new: 1) at: 1 put: aChar; yourself ]
String class >> new: n withAll: aChar [
    "Answers a String of n bytes, each aChar.
     String new: 3 withAll: $z >>> 'zzz'"
    | s | s := self new: n. 1 to: n do: [:i | s at: i put: aChar]. ^s ]
String class >> cr [
    "Answers a String of one line end: Character cr, byte 10 (LF).
     String cr first value >>> 10"
    ^self with: Character cr ]
String class >> tab [
    "Answers a String of one tab character (9).
     String tab first value >>> 9"
    ^self with: Character tab ]
String class >> space [
    "Answers a String of one space.
     String space >>> ' '"
    ^self with: Character space ]
String >> at: i [
    "The byte at index i, as a Character. A VM primitive (60); signals
     SubscriptOutOfBounds for an index outside 1 to size.
     'abc' at: 2 >>> $b"
    <primitive: 60> ^self indexError: i ]
String >> at: i put: aChar [
    "Stores the Character aChar as the byte at index i and answers it. A VM
     primitive (61); signals SubscriptOutOfBounds for an index outside, an
     Error for an immutable String (a literal).
     'abc' copy at: 2 put: $X; yourself >>> 'aXc'"
    <primitive: 61> ^self indexError: i ]
String >> isString [
    "Answers true: the receiver is a String.
     'abc' isString >>> true"
    ^true ]
String >> isLiteral [
    "Answers true: a String can be written as a literal.
     'abc' isLiteral >>> true"
    ^true ]
String >> species [
    "Answers String: what copies of a String (or a Symbol) are.
     #abc species >>> String"
    ^String ]
String >> collectSpecies [
    "Answers String: collect: on a String answers a String, so its block
     must answer Characters.
     'abc' collect: [:c | c asUppercase] >>> 'ABC'"
    ^String ]
String >> = aString [
    "Answers whether aString has the same bytes. A VM primitive (58);
     false for an argument that is not made of bytes. A String equals the
     Symbol of the same bytes, but not the other way round.
     'abc' = 'abc' copy >>> true"
    <primitive: 58>
    ^false ]
String >> hash [
    "A hash of the bytes: FNV-1a, 30 bits. A VM primitive (59).
     'abc' hash = 'abc' copy hash >>> true"
    <primitive: 59> ]
String >> compare: aString [
    "Answers -1, 0 or 1 as the receiver sorts before, the same as or after
     aString, byte by byte. A VM primitive (63); signals an Error (error:)
     if aString is not a String.
     'abc' compare: 'abd' >>> -1"
    <primitive: 63> ^self error: 'a string was expected' ]
String >> < aString [
    "Answers whether the receiver sorts before aString, byte by byte.
     'abc' < 'abd' >>> true"
    ^(self compare: aString) < 0 ]
String >> > aString [
    "Answers whether the receiver sorts after aString, byte by byte.
     'b' > 'abc' >>> true"
    ^(self compare: aString) > 0 ]
String >> <= aString [
    "Answers whether the receiver sorts before aString or equals it.
     'abc' <= 'abc' >>> true"
    ^(self compare: aString) <= 0 ]
String >> >= aString [
    "Answers whether the receiver sorts after aString or equals it.
     'abc' >= 'abd' >>> false"
    ^(self compare: aString) >= 0 ]
String >> asString [
    "Answers the receiver itself.
     'abc' asString >>> 'abc'"
    ^self ]
String >> asSymbol [
    "Answers the unique Symbol with the receiver's bytes, made by
     Symbol intern: if it is new.
     'abc' asSymbol >>> #abc"
    ^Symbol intern: self ]
String >> asUppercase [
    "Answers a copy with the ASCII letters in upper case.
     'Hello' asUppercase >>> 'HELLO'"
    ^self collect: [:c | c asUppercase] ]
String >> asLowercase [
    "Answers a copy with the ASCII letters in lower case.
     'Hello' asLowercase >>> 'hello'"
    ^self collect: [:c | c asLowercase] ]
String >> size [
    "The number of bytes (not of characters, for text outside ASCII). A
     VM primitive (43).
     'hello' size >>> 5"
    <primitive: 43> ]
String >> isEmpty [
    "Answers whether the String has no bytes.
     '' isEmpty >>> true"
    ^self size = 0 ]
String >> includesSubstring: aString [
    "Answers whether aString occurs in the receiver.
     'hello world' includesSubstring: 'o w' >>> true"
    ^(self indexOfSubCollection: aString) > 0 ]
String >> beginsWith: aString [
    "Answers whether the receiver starts with aString.
     'hello' beginsWith: 'he' >>> true"
    ^self size >= aString size and: [(self copyFrom: 1 to: aString size) = aString] ]
String >> endsWith: aString [
    "Answers whether the receiver ends with aString.
     'hello' endsWith: 'lo' >>> true"
    ^self size >= aString size and: [(self copyFrom: self size - aString size + 1 to: self size) = aString] ]
String >> asInteger [
    "Answers the decimal Integer the whole String spells, with an optional
     leading minus sign; nil if it is empty or has any other character
     (spaces and a plus sign included).
     '-42' asInteger >>> -42"
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
String >> asNumber [
    "Answers asInteger: the numbers are Integers, there are no floats.
     '17' asNumber >>> 17"
    ^self asInteger ]
String >> trimSeparators [
    "Answers a copy without the separators (spaces, tabs, line ends) at
     either end.
     '  hi  ' trimSeparators >>> 'hi'"
    | a b |
    a := 1. b := self size.
    [a <= b and: [(self at: a) isSeparator]] whileTrue: [a := a + 1].
    [b >= a and: [(self at: b) isSeparator]] whileTrue: [b := b - 1].
    ^self copyFrom: a to: b ]
String >> trimBoth [
    "Answers trimSeparators: a copy without separators at either end.
     ' hi ' trimBoth >>> 'hi'"
    ^self trimSeparators ]
String >> substrings [
    "Answers an OrderedCollection of the pieces between spaces, without
     empty ones; only the space separates (not tabs or line ends).
     'a  b c' substrings >>> OrderedCollection ('a' 'b' 'c')"
    ^self substrings: ' ' ]
String >> substrings: separators [
    "Answers an OrderedCollection of the pieces between runs of the
     characters in separators (a String, or any collection of Characters),
     without empty ones.
     'a,b;;c' substrings: ',;' >>> OrderedCollection ('a' 'b' 'c')"
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
    "Answers an OrderedCollection of the lines, split at each line end
     (Character cr, LF), without it. A final line end does not add an empty
     line; a carriage return is kept.
     ('one', String cr, 'two') lines >>> OrderedCollection ('one' 'two')"
    | out start |
    out := OrderedCollection new.
    start := 1.
    1 to: self size do: [:i | (self at: i) = Character cr ifTrue: [out add: (self copyFrom: start to: i - 1). start := i + 1]].
    start <= self size ifTrue: [out add: (self copyFrom: start to: self size)].
    ^out ]
String >> occurrencesOfString: aString [
    "The number of occurrences of aString that do not overlap; 0 for an
     empty aString.
     'abcabcab' occurrencesOfString: 'ab' >>> 3"
    | n i | n := 0. i := 1.
    aString isEmpty ifTrue: [^0].
    [(i := self indexOfSubCollection: aString startingAt: i) > 0] whileTrue: [n := n + 1. i := i + aString size].
    ^n ]
String >> copyReplaceAll: old with: new [
    "Answers a copy with each occurrence of old, from left to right without
     overlap, replaced by new; a plain copy for an empty old.
     'a-b-c' copyReplaceAll: '-' with: '+' >>> 'a+b+c'"
    | out i j |
    old isEmpty ifTrue: [^self copy].
    out := WriteStream on: (String new: self size).
    i := 1.
    [(j := self indexOfSubCollection: old startingAt: i) > 0] whileTrue: [
        out nextPutAll: (self copyFrom: i to: j - 1); nextPutAll: new.
        i := j + old size].
    out nextPutAll: (self copyFrom: i to: self size).
    ^out contents ]
String >> format: anArray [
    "Answers a copy with each {N} replaced by the displayString of
     anArray at: N; a { without a closing } is kept. Signals an Error if
     what is between the braces is not an index of anArray.
     '{1} and {2}' format: #(3 'four') >>> '3 and four'"
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
    "The index of the first element equal to x at start or after, or 0.
     #(1 2 3 2) indexOf: 2 startingAt: 3 >>> 4"
    start to: self size do: [:i | (self at: i) = x ifTrue: [^i]].
    ^0 ]
String >> printOn: aStream [
    "Prints the String between single quotes, each quote in it doubled:
     the literal that reads back as the String.
     'it''s' printString size >>> 7"
    aStream nextPut: $'.
    self do: [:c | aStream nextPut: c. c = $' ifTrue: [aStream nextPut: c]].
    aStream nextPut: $' ]
String >> displayOn: aStream [
    "Puts the String's bytes on aStream, without quotes.
     (WriteStream on: String new) display: 'abc'; contents >>> 'abc'"
    aStream nextPutAll: self ]
String >> displayString [
    "Answers the receiver itself: a String displays as its text.
     'abc' displayString >>> 'abc'"
    ^self ]
String >> keywords [
    "Answers an OrderedCollection of the keywords of a selector, each with
     its colon; a selector without colons is answered whole.
     'at:put:' keywords >>> OrderedCollection ('at:' 'put:')"
    | out start |
    out := OrderedCollection new.
    start := 1.
    1 to: self size do: [:i | (self at: i) = $: ifTrue: [out add: (self copyFrom: start to: i). start := i + 1]].
    start <= self size ifTrue: [out add: (self copyFrom: start to: self size)].
    ^out ]
String >> numArgs [
    "The number of arguments a message with this selector takes: the
     number of colons, or 1 for a binary selector (one not starting with
     a letter), 0 for an empty String.
     'at:put:' numArgs >>> 2"
    | n |
    self size = 0 ifTrue: [^0].
    (self at: 1) isLetter ifFalse: [^1].
    n := self occurrencesOf: $:.
    ^n ]
String >> asByteArray [
    "Answers a ByteArray of the String's bytes.
     'AB' asByteArray >>> #[65 66]"
    | b | b := ByteArray new: self size. 1 to: self size do: [:i | b at: i put: (self at: i) value]. ^b ]

"---- Symbol: unique; made in far memory -----------------------------------------"

Symbol class >> intern: aString [
    "Answers the unique Symbol with aString's bytes: found in the symbol
     table (Smalltalk symbolTable, open addressing by aString hash), or
     made in far memory (basicNewFar:) and entered there.
     (Symbol intern: 'abc') == #abc >>> true"
    | table i s n probes |
    table := Smalltalk symbolTable.
    n := table size.
    i := (aString hash bitAnd: n - 1) + 1.
    probes := 0.
    [(s := table at: i) == nil] whileFalse: [
        (s size = aString size and: [s sameAs: aString]) ifTrue: [^s].
        i := i \\ n + 1.
        (probes := probes + 1) >= n ifTrue: [self growTable. ^self intern: aString]].
    s := Symbol basicNewFar: aString size.
    s replaceFrom: 1 to: aString size with: aString startingAt: 1.
    table at: i put: s.
    Smalltalk noteNewSymbol.
    probes > 8 ifTrue: [self growTableIfFull].
    ^s ]
Symbol class >> growTableIfFull [
    "Doubles the symbol table when it is over three quarters full: sent
     when an intern: had to look far for a free slot."
    | t |
    t := Smalltalk symbolTable.
    (t count: [:e | e notNil]) * 4 > (t size * 3) ifTrue: [self growTable] ]
Symbol class >> growTable [
    "Puts every Symbol into a table twice the size, which becomes the
     symbol table (the special objects' slot 12)."
    | old new n |
    old := Smalltalk symbolTable.
    n := old size * 2.
    new := Array new: n.
    old do: [:s | s == nil ifFalse: [ | i |
        i := (s asString hash bitAnd: n - 1) + 1.
        [(new at: i) == nil] whileFalse: [i := i \\ n + 1].
        new at: i put: s]].
    Smalltalk specialObjects at: 12 put: new ]
Symbol class >> new: n [
    "Signals an Error (error:): Symbols are made with asSymbol or intern:."
    ^self error: 'symbols are made with asSymbol' ]
String >> sameAs: aString [
    "Answers whether aString has the same bytes (case matters). A VM
     primitive (58), as = is; false for an argument not made of bytes.
     'x' sameAs: #x >>> true"
    <primitive: 58> ^false ]
Symbol >> isSymbol [
    "Answers true: the receiver is a Symbol.
     #abc isSymbol >>> true"
    ^true ]
Symbol >> asSymbol [
    "Answers the receiver itself.
     #abc asSymbol == #abc >>> true"
    ^self ]
Symbol >> asString [
    "Answers a new String (near if small) with the Symbol's bytes, which
     can be changed.
     #abc asString >>> 'abc'"
    | s | s := String new: self size. s replaceFrom: 1 to: self size with: self startingAt: 1. ^s ]
Symbol >> = anObject [
    "Answers whether anObject is the receiver itself: Symbols are unique,
     so a String is never equal to one.
     #abc = 'abc' >>> false"
    ^self == anObject ]
Symbol >> hash [
    "The identity hash, as = is identity.
     #abc hash = #abc hash >>> true"
    ^self identityHash ]
Symbol >> species [
    "Answers String: copies of a Symbol are Strings.
     #abc , 'd' >>> 'abcd'"
    ^String ]
Symbol >> printOn: aStream [
    "Prints # and the Symbol's bytes.
     #abc printString >>> '#abc'"
    aStream nextPut: $#; nextPutAll: self ]
Symbol >> displayString [
    "Answers the Symbol's bytes as a String, without #.
     #abc displayString >>> 'abc'"
    ^self asString ]
Symbol >> value: anObject [
    "Sends the receiver, a unary selector, to anObject and answers the
     result: a Symbol serves as a one-argument block.
     #negated value: 3 >>> -3"
    ^anObject perform: self ]
Symbol >> value: a value: b [
    "Sends the receiver, a binary or one-keyword selector, to a with b and
     answers the result: a Symbol serves as a two-argument block.
     #(1 2 3) inject: 0 into: #+ >>> 6"
    ^a perform: self with: b ]
Symbol >> cull: anObject [
    "Sends the receiver, a unary selector, to anObject, as value: does.
     #negated cull: 3 >>> -3"
    ^anObject perform: self ]
Symbol >> numArgs [
    "The number of arguments of the selector the Symbol names.
     #at:put: numArgs >>> 2"
    ^super numArgs ]
Symbol >> shallowCopy [
    "Answers the receiver itself: a Symbol is not copied.
     #abc shallowCopy == #abc >>> true"
    ^self ]
Symbol >> deepCopy [
    "Answers the receiver itself: a Symbol is not copied.
     #abc deepCopy == #abc >>> true"
    ^self ]
Symbol >> at: i put: c [
    "Signals an Error (error:): Symbols cannot be changed."
    ^self error: 'symbols cannot be changed' ]

"---- ByteArray --------------------------------------------------------------------"

ByteArray >> isLiteral [
    "Answers true: a ByteArray can be written as a literal, #[...].
     #[1 2 3] isLiteral >>> true"
    ^true ]
ByteArray >> asString [
    "Answers a new String with the same bytes.
     #[104 105] asString >>> 'hi'"
    | s | s := String new: self size. s replaceFrom: 1 to: self size with: self asStringBytes startingAt: 1. ^s ]
ByteArray >> asStringBytes [
    "Answers a new String with the same bytes, made byte by byte through
     Character value:.
     #[104 105] asStringBytes >>> 'hi'"
    | s | s := String new: self size. 1 to: self size do: [:i | s at: i put: (Character value: (self at: i))]. ^s ]
ByteArray >> printOn: aStream [
    "Prints #[ and the bytes in decimal, then ].
     (ByteArray new: 2) printString >>> '#[0 0]'"
    aStream nextPutAll: '#['.
    self do: [:e | aStream print: e] separatedBy: [aStream space].
    aStream nextPut: $] ]

"---- OrderedCollection -------------------------------------------------------------"

OrderedCollection class >> new [
    "Answers an empty OrderedCollection with room for 8.
     OrderedCollection new >>> OrderedCollection ()"
    ^self new: 8 ]
OrderedCollection class >> new: n [
    "Answers an empty OrderedCollection with room for n (at least 4); n is
     not a size, as it is for an Array.
     (OrderedCollection new: 100) size >>> 0"
    ^self basicNew setArray: (Array new: (n max: 4)) ]
OrderedCollection >> setArray: anArray [
    "Makes anArray the empty store, the elements to begin in its middle."
    array := anArray. firstIndex := anArray size // 2 + 1. lastIndex := firstIndex - 1 ]
OrderedCollection >> size [
    "The number of elements.
     (OrderedCollection withAll: #(5 6)) size >>> 2"
    ^lastIndex - firstIndex + 1 ]
OrderedCollection >> at: i [
    "The element at index i. Signals SubscriptOutOfBounds for an index
     outside 1 to size.
     (OrderedCollection withAll: #(5 6)) at: 2 >>> 6"
    (i between: 1 and: lastIndex - firstIndex + 1) ifFalse: [^self indexError: i].
    ^array at: firstIndex + i - 1 ]
OrderedCollection >> at: i put: v [
    "Replaces the element at index i with v and answers v. Signals
     SubscriptOutOfBounds for an index outside 1 to size: it does not grow.
     (OrderedCollection withAll: #(5 6)) at: 1 put: 9; yourself >>> OrderedCollection (9 6)"
    (i between: 1 and: lastIndex - firstIndex + 1) ifFalse: [^self indexError: i].
    ^array at: firstIndex + i - 1 put: v ]
OrderedCollection >> do: aBlock [
    "Evaluates aBlock with each element, first to last.
     | s | s := 0. (OrderedCollection withAll: #(5 6)) do: [:e | s := s + e]. s >>> 11"
    firstIndex to: lastIndex do: [:i | aBlock value: (array at: i)] ]
OrderedCollection >> add: v [
    "Adds v at the end and answers v.
     (OrderedCollection new add: 3; add: 4; yourself) >>> OrderedCollection (3 4)"
    ^self addLast: v ]
OrderedCollection >> addLast: v [
    "Adds v at the end, growing the store if needed, and answers v.
     (OrderedCollection new addLast: 3; addLast: 4; yourself) >>> OrderedCollection (3 4)"
    lastIndex = array size ifTrue: [self grow].
    lastIndex := lastIndex + 1.
    ^array at: lastIndex put: v ]
OrderedCollection >> addFirst: v [
    "Adds v at the start, growing the store if needed, and answers v.
     (OrderedCollection new addFirst: 3; addFirst: 4; yourself) >>> OrderedCollection (4 3)"
    firstIndex = 1 ifTrue: [self grow].
    firstIndex := firstIndex - 1.
    ^array at: firstIndex put: v ]
OrderedCollection >> grow [
    "Replaces the store with one twice as large plus 4, the elements copied
     to its middle so that both ends have room."
    | n new off |
    n := self size.
    new := Array new: array size * 2 + 4.
    off := new size - n // 2.
    new replaceFrom: off + 1 to: off + n with: array startingAt: firstIndex.
    array := new. firstIndex := off + 1. lastIndex := off + n ]
OrderedCollection >> removeFirst [
    "Removes the first element and answers it. Signals an Error (error:) if
     the collection is empty.
     (OrderedCollection withAll: #(5 6 7)) removeFirst >>> 5"
    | v |
    self isEmpty ifTrue: [^self error: 'the collection is empty'].
    v := array at: firstIndex. array at: firstIndex put: nil.
    firstIndex := firstIndex + 1.
    ^v ]
OrderedCollection >> removeLast [
    "Removes the last element and answers it. Signals an Error (error:) if
     the collection is empty.
     (OrderedCollection withAll: #(5 6 7)) removeLast >>> 7"
    | v |
    self isEmpty ifTrue: [^self error: 'the collection is empty'].
    v := array at: lastIndex. array at: lastIndex put: nil.
    lastIndex := lastIndex - 1.
    ^v ]
OrderedCollection >> removeFirst: n [
    "Removes the first n elements and answers them as an Array. Signals an
     Error (error:) if there are fewer.
     (OrderedCollection withAll: #(5 6 7)) removeFirst: 2 >>> #(5 6)"
    | out | out := Array new: n. 1 to: n do: [:i | out at: i put: self removeFirst]. ^out ]
OrderedCollection >> removeIndex: i [
    "Removes the element at index i, closing the gap, and answers it.
     Signals SubscriptOutOfBounds for an index outside 1 to size.
     (OrderedCollection withAll: #(5 6 7)) removeIndex: 2; yourself >>> OrderedCollection (5 7)"
    | v |
    v := self at: i.
    array replaceFrom: firstIndex + i - 1 to: lastIndex - 1 with: array startingAt: firstIndex + i.
    array at: lastIndex put: nil.
    lastIndex := lastIndex - 1.
    ^v ]
OrderedCollection >> remove: v ifAbsent: aBlock [
    "Removes the first element equal to v and answers it, or answers
     aBlock's value if there is none.
     (OrderedCollection withAll: #(5 6 7)) remove: 9 ifAbsent: [0] >>> 0"
    | i |
    i := self indexOf: v.
    i = 0 ifTrue: [^aBlock value].
    ^self removeIndex: i ]
OrderedCollection >> removeAll [
    "Removes every element, the store replaced by a new one for 8.
     (OrderedCollection withAll: #(5 6 7)) removeAll; yourself >>> OrderedCollection ()"
    self setArray: (Array new: 8) ]
OrderedCollection >> insert: v before: i [
    "Inserts v at index i, the elements from i on moving one up, and
     answers v. i may be size + 1 (at the end).
     (OrderedCollection withAll: #(5 6 7)) insert: 1 before: 2; yourself >>> OrderedCollection (5 1 6 7)"
    self addLast: nil.
    self size to: i + 1 by: -1 do: [:j | self at: j put: (self at: j - 1)].
    ^self at: i put: v ]
OrderedCollection >> add: v beforeIndex: i [
    "Inserts v at index i and answers v, as insert:before: does.
     (OrderedCollection withAll: #(5 6 7)) add: 1 beforeIndex: 1; yourself >>> OrderedCollection (1 5 6 7)"
    ^self insert: v before: i ]
OrderedCollection >> species [
    "Answers OrderedCollection.
     (OrderedCollection new) species >>> OrderedCollection"
    ^OrderedCollection ]
OrderedCollection >> copyEmpty [
    "Answers a new, empty OrderedCollection.
     (OrderedCollection withAll: #(5 6)) copyEmpty >>> OrderedCollection ()"
    ^OrderedCollection new ]
OrderedCollection >> collect: aBlock [
    "Answers an OrderedCollection of aBlock's value for each element.
     (OrderedCollection withAll: #(5 6 7)) collect: [:e | e * 2] >>> OrderedCollection (10 12 14)"
    | out | out := OrderedCollection new: self size. self do: [:e | out addLast: (aBlock value: e)]. ^out ]
OrderedCollection >> select: aBlock [
    "Answers an OrderedCollection of the elements for which aBlock answers
     true.
     (OrderedCollection withAll: #(5 6 7)) select: [:e | e odd] >>> OrderedCollection (5 7)"
    | out | out := OrderedCollection new. self do: [:e | (aBlock value: e) ifTrue: [out addLast: e]]. ^out ]
OrderedCollection >> copyFrom: start to: stop [
    "Answers a new OrderedCollection of the elements from start to stop.
     Signals SubscriptOutOfBounds for an index outside 1 to size.
     (OrderedCollection withAll: #(5 6 7)) copyFrom: 2 to: 3 >>> OrderedCollection (6 7)"
    | out | out := OrderedCollection new. start to: stop do: [:i | out add: (self at: i)]. ^out ]
OrderedCollection >> , other [
    "Answers a copy with other's elements added at the end.
     (OrderedCollection withAll: #(5 6)) , #(7) >>> OrderedCollection (5 6 7)"
    ^self copy addAll: other; yourself ]
OrderedCollection >> postCopy [
    "After copy: gives the copy its own store, so that changing one does not
     change the other.
     | a b | a := OrderedCollection withAll: #(1). b := a copy. b add: 2. a >>> OrderedCollection (1)"
    array := array copy ]
OrderedCollection >> copyWith: anObject [
    "Answers a copy with anObject added at the end.
     (OrderedCollection withAll: #(1 2)) copyWith: 3 >>> OrderedCollection (1 2 3)"
    ^self copy addLast: anObject; yourself ]
OrderedCollection >> with: other collect: aBlock [
    "Answers an OrderedCollection of aBlock's values for each element and
     the element of other at the same index.
     (OrderedCollection withAll: #(1 2)) with: #(10 20) collect: [:a :b | a + b] >>> OrderedCollection (11 22)"
    | out | out := OrderedCollection new: self size.
    1 to: self size do: [:i | out addLast: (aBlock value: (self at: i) value: (other at: i))].
    ^out ]
OrderedCollection >> reversed [
    "Answers a new OrderedCollection with the elements in reverse order.
     (OrderedCollection withAll: #(5 6 7)) reversed >>> OrderedCollection (7 6 5)"
    | out | out := OrderedCollection new. self reverseDo: [:e | out add: e]. ^out ]
SequenceableCollection class >> new: n [
    "Answers new, n ignored: for the sequenceable classes that are not
     sized at creation. ArrayedCollection and OrderedCollection have their
     own."
    ^self new ]

"---- Interval ------------------------------------------------------------------------"

Interval class >> from: a to: b by: s [
    "Answers the Interval from a to b by s; signals an Error for a step of
     0. Number to:by: makes the same.
     Interval from: 1 to: 10 by: 3 >>> 1 to: 10 by: 3"
    s = 0 ifTrue: [^self error: 'the step of an Interval cannot be 0'].
    ^self basicNew setFrom: a to: b by: s ]
Interval >> setFrom: a to: b by: s [
    "Sets the start, the stop and the step."
    start := a. stop := b. step := s ]
Interval >> size [
    "The number of elements: 0 when stop is before start in the direction
     of step.
     (10 to: 1 by: -3) size >>> 4"
    step > 0 ifTrue: [^stop - start // step + 1 max: 0]. ^start - stop // step negated + 1 max: 0 ]
Interval >> at: i [
    "The i-th element, start + (step * (i - 1)). Signals
     SubscriptOutOfBounds for an index outside 1 to size.
     (1 to: 10 by: 3) at: 2 >>> 4"
    (i between: 1 and: self size) ifFalse: [^self indexError: i]. ^start + (step * (i - 1)) ]
Interval >> do: aBlock [
    "Evaluates aBlock with each element, from start toward stop.
     | s | s := 0. (1 to: 4) do: [:i | s := s + i]. s >>> 10"
    | i |
    i := start.
    step > 0
        ifTrue: [[i <= stop] whileTrue: [aBlock value: i. i := i + step]]
        ifFalse: [[i >= stop] whileTrue: [aBlock value: i. i := i + step]] ]
Interval >> collect: aBlock [
    "Answers an Array of aBlock's value for each element.
     (1 to: 4) collect: [:i | i * i] >>> #(1 4 9 16)"
    | out i | out := Array new: self size. i := 0. self do: [:e | out at: (i := i + 1) put: (aBlock value: e)]. ^out ]
Interval >> species [
    "Answers Array: what copies of an Interval are.
     (1 to: 6) select: [:i | i even] >>> #(2 4 6)"
    ^Array ]
Interval >> printOn: aStream [
    "Prints the expression that makes it: start to: stop, with by: step
     unless the step is 1.
     (1 to: 10 by: 3) printString >>> '1 to: 10 by: 3'"
    aStream print: start; nextPutAll: ' to: '; print: stop.
    step = 1 ifFalse: [aStream nextPutAll: ' by: '; print: step] ]
Interval >> first [
    "The start. It is answered even for an empty Interval.
     (1 to: 10 by: 3) first >>> 1"
    ^start ]
Interval >> last [
    "The last element reached from start by step, which may be before stop.
     Signals an Error for an empty Interval.
     (1 to: 9 by: 3) last >>> 7"
    self size = 0 ifTrue: [^self error: 'an empty Interval has no last element'].
    ^stop - ((stop - start) \\ step) ]

"---- hashed collections: open addressing, the size a power of two ------------------"

HashedCollection class >> new [
    "Answers an empty collection with a table of 16.
     Set new size >>> 0"
    ^self new: 8 ]
HashedCollection class >> new: n [
    "Answers an empty collection whose table, a power of two at least 8 and
     at least 2n, holds n elements without growing.
     (Set new: 100) capacity >>> 256"
    | size |
    size := 8.
    [size < (n * 2)] whileTrue: [size := size * 2].
    ^self basicNew setTally: 0 array: (Array new: size) ]
HashedCollection >> setTally: n array: anArray [
    "Sets the count and the table."
    tally := n. array := anArray ]
HashedCollection >> size [
    "The number of elements.
     (Set withAll: #(1 2 3)) size >>> 3"
    ^tally ]
HashedCollection >> capacity [
    "The size of the hash table, a power of two.
     Set new capacity >>> 16"
    ^array size ]
HashedCollection >> hashOf: key [
    "The hash a key is placed by: its hash here, its identityHash in the
     identity collections.
     Set new hashOf: 3 >>> 3"
    ^key hash ]
HashedCollection >> keyAt: index [
    "The table's entry at index: an element, an Association or nil."
    ^array at: index ]
HashedCollection >> sameKey: a as: b [
    "Answers whether keys a and b are the same key: a = b here, a == b in
     the identity collections."
    ^a = b ]
HashedCollection >> findIndex: key [
    "The index of the table entry for key, or of the empty slot where it
     would go: linear probing from its hash. The table always has an
     empty slot."
    | n i e |
    n := array size.
    i := ((self hashOf: key) bitAnd: n - 1) + 1.
    [(e := array at: i) == nil or: [self sameKey: (self keyOf: e) as: key]] whileFalse: [i := i \\ n + 1].
    ^i ]
HashedCollection >> keyOf: element [
    "The key of a table entry: the element itself here, an Association's
     key in a Dictionary."
    ^element ]
HashedCollection >> grow [
    "Replaces the table with one twice as large and places each entry in
     it again."
    | old |
    old := array.
    array := Array new: old size * 2.
    old do: [:e | e == nil ifFalse: [array at: (self findIndex: (self keyOf: e)) put: e]] ]
HashedCollection >> checkGrow [
    "Grows the table if it is three quarters full."
    tally * 4 >= (array size * 3) ifTrue: [self grow] ]
HashedCollection >> rehashFrom: index [
    "After a removal at index: places again the entries that follow it up
     to the next empty slot, so that none is cut off from its probe."
    | n i e |
    n := array size.
    i := index \\ n + 1.
    [(e := array at: i) == nil] whileFalse: [
        array at: i put: nil.
        array at: (self findIndex: (self keyOf: e)) put: e.
        i := i \\ n + 1] ]
HashedCollection >> do: aBlock [
    "Evaluates aBlock with each element (each value, in a Dictionary), in
     the order of the table.
     | s | s := 0. (Set withAll: #(1 2 3)) do: [:e | s := s + e]. s >>> 6"
    array do: [:e | e == nil ifFalse: [aBlock value: (self valueOf: e)]] ]
HashedCollection >> valueOf: element [
    "What do: gives for a table entry: the element itself here, an
     Association's value in a Dictionary."
    ^element ]

Set >> add: anObject [
    "Adds anObject unless an equal element is there, and answers anObject.
     nil is not added.
     (Set new add: 3; add: 3; yourself) size >>> 1"
    | i |
    anObject == nil ifTrue: [^anObject].
    i := self findIndex: anObject.
    (array at: i) == nil ifTrue: [array at: i put: anObject. tally := tally + 1. self checkGrow].
    ^anObject ]
Set >> includes: anObject [
    "Answers whether an element is equal to anObject, by a hash lookup.
     (Set withAll: #(1 2)) includes: 2 >>> true"
    ^(array at: (self findIndex: anObject)) notNil ]
Set >> remove: anObject ifAbsent: aBlock [
    "Removes the element equal to anObject and answers anObject, or answers
     aBlock's value if there is none.
     (Set withAll: #(1 2)) remove: 2; yourself >>> Set (1)"
    | i |
    i := self findIndex: anObject.
    (array at: i) == nil ifTrue: [^aBlock value].
    array at: i put: nil.
    tally := tally - 1.
    self rehashFrom: i.
    ^anObject ]
Set >> collect: aBlock [
    "Answers a Set of aBlock's values for the elements: equal values count
     once.
     ((Set withAll: #(1 2 3 4)) collect: [:e | e \\ 2]) size >>> 2"
    | out | out := Set new. self do: [:e | out add: (aBlock value: e)]. ^out ]
Set >> = other [
    "Answers whether other is a Set of the same class with the same
     elements.
     (Set withAll: #(1 2)) = (Set withAll: #(2 1)) >>> true"
    self == other ifTrue: [^true].
    self class == other class ifFalse: [^false].
    self size = other size ifFalse: [^false].
    ^self allSatisfy: [:e | other includes: e] ]
Set >> hash [
    "The size: equal Sets have equal hashes."
    ^self size ]
Set >> printOn: aStream [
    "Prints the class name and the elements, printed, in parentheses, in
     the order of the table.
     (Set withAll: #(4)) printString >>> 'Set (4)'"
    aStream nextPutAll: self class name; nextPutAll: ' ('.
    self do: [:e | aStream print: e] separatedBy: [aStream space].
    aStream nextPut: $) ]
IdentitySet >> hashOf: key [
    "Answers key's identityHash.
     (IdentitySet new hashOf: #a) = #a identityHash >>> true"
    ^key identityHash ]
IdentitySet >> sameKey: a as: b [
    "Answers whether a and b are the same object (==)."
    ^a == b ]

Dictionary >> keyOf: assoc [
    "The key of a table entry, an Association."
    ^assoc key ]
Dictionary >> valueOf: assoc [
    "The value of a table entry, an Association: what do: gives."
    ^assoc value ]
Dictionary >> at: key [
    "The value at key. Signals KeyNotFound if there is no such key.
     (Dictionary new at: #a put: 1; yourself) at: #a >>> 1"
    ^self at: key ifAbsent: [KeyNotFound new signal: 'key not found: ', key printString] ]
Dictionary >> at: key ifAbsent: aBlock [
    "The value at key, or aBlock's value if there is no such key.
     (Dictionary new at: #a put: 1; yourself) at: #b ifAbsent: [0] >>> 0"
    | a |
    a := array at: (self findIndex: key).
    a == nil ifTrue: [^aBlock value].
    ^a value ]
Dictionary >> at: key ifPresent: aBlock [
    "Answers aBlock's value, given the value at key if it takes an
     argument, when there is such a key; nil otherwise.
     (Dictionary new at: #a put: 1; yourself) at: #a ifPresent: [:v | v + 10] >>> 11"
    | a |
    a := array at: (self findIndex: key).
    a == nil ifTrue: [^nil].
    ^aBlock cull: a value ]
Dictionary >> at: key ifAbsentPut: aBlock [
    "The value at key; if there is none, puts aBlock's value there first.
     | d | d := Dictionary new. d at: #a ifAbsentPut: [5]. d at: #a ifAbsentPut: [6] >>> 5"
    ^self at: key ifAbsent: [self at: key put: aBlock value] ]
Dictionary >> at: key put: value [
    "Puts value at key, replacing the value of an existing key, and answers
     value. A new key gets a new Association.
     (Dictionary new at: #a put: 1; at: #a put: 2; yourself) at: #a >>> 2"
    | i a |
    i := self findIndex: key.
    a := array at: i.
    a == nil
        ifTrue: [array at: i put: (Association key: key value: value). tally := tally + 1. self checkGrow]
        ifFalse: [a value: value].
    ^value ]
Dictionary >> associationAt: key ifAbsent: aBlock [
    "The Association for key, or aBlock's value if there is no such key.
     (Dictionary new at: #a put: 1; yourself) associationAt: #a ifAbsent: [nil] >>> #a->1"
    | a |
    a := array at: (self findIndex: key).
    a == nil ifTrue: [^aBlock value].
    ^a ]
Dictionary >> add: anAssociation [
    "Puts anAssociation itself in the table (replacing the one with the
     same key) and answers it.
     (Dictionary new add: #a -> 1; yourself) at: #a >>> 1"
    | i |
    i := self findIndex: anAssociation key.
    (array at: i) == nil ifTrue: [tally := tally + 1].
    array at: i put: anAssociation.
    self checkGrow.
    ^anAssociation ]
Dictionary >> includesKey: key [
    "Answers whether there is a value at key.
     (Dictionary new at: #a put: 1; yourself) includesKey: #a >>> true"
    ^(array at: (self findIndex: key)) notNil ]
Dictionary >> includes: value [
    "Answers whether some value (not key) is equal to value.
     (Dictionary new at: #a put: 1; yourself) includes: 1 >>> true"
    self do: [:v | v = value ifTrue: [^true]]. ^false ]
Dictionary >> removeKey: key [
    "Removes key and answers its value. Signals KeyNotFound if there is no
     such key.
     (Dictionary new at: #a put: 1; yourself) removeKey: #a >>> 1"
    ^self removeKey: key ifAbsent: [KeyNotFound new signal: 'key not found: ', key printString] ]
Dictionary >> removeKey: key ifAbsent: aBlock [
    "Removes key and answers its value, or answers aBlock's value if there
     is no such key.
     (Dictionary new at: #a put: 1; yourself) removeKey: #b ifAbsent: [0] >>> 0"
    | i a |
    i := self findIndex: key.
    a := array at: i.
    a == nil ifTrue: [^aBlock value].
    array at: i put: nil.
    tally := tally - 1.
    self rehashFrom: i.
    ^a value ]
Dictionary >> keysAndValuesDo: aBlock [
    "Evaluates aBlock with each key and its value, in the order of the
     table.
     | s | s := 0. (Dictionary new at: 2 put: 3; yourself) keysAndValuesDo: [:k :v | s := k * v]. s >>> 6"
    array do: [:a | a == nil ifFalse: [aBlock value: a key value: a value]] ]
Dictionary >> associationsDo: aBlock [
    "Evaluates aBlock with each Association, in the order of the table.
     | s | (Dictionary new at: 2 put: 3; yourself) associationsDo: [:a | s := a]. s >>> 2->3"
    array do: [:a | a == nil ifFalse: [aBlock value: a]] ]
Dictionary >> keysDo: aBlock [
    "Evaluates aBlock with each key, in the order of the table.
     | s | (Dictionary new at: 2 put: 3; yourself) keysDo: [:k | s := k]. s >>> 2"
    array do: [:a | a == nil ifFalse: [aBlock value: a key]] ]
Dictionary >> associations [
    "Answers an OrderedCollection of the Associations, in the order of the
     table.
     (Dictionary new at: 2 put: 3; yourself) associations >>> OrderedCollection (2->3)"
    | out | out := OrderedCollection new. self associationsDo: [:a | out add: a]. ^out ]
Dictionary >> keys [
    "Answers an OrderedCollection of the keys, in the order of the table.
     (Dictionary new at: 1 put: 10; at: 2 put: 20; yourself) keys sorted >>> #(1 2)"
    | out | out := OrderedCollection new. self keysDo: [:k | out add: k]. ^out ]
Dictionary >> values [
    "Answers an OrderedCollection of the values, in the order of the table.
     (Dictionary new at: 1 put: 10; at: 2 put: 20; yourself) values sorted >>> #(10 20)"
    | out | out := OrderedCollection new. self do: [:v | out add: v]. ^out ]
Dictionary >> keyAtValue: v [
    "A key whose value is equal to v, or nil.
     (Dictionary new at: 2 put: 3; yourself) keyAtValue: 3 >>> 2"
    self keysAndValuesDo: [:k :x | x = v ifTrue: [^k]]. ^nil ]
Dictionary >> collect: aBlock [
    "Answers an OrderedCollection of aBlock's value for each value.
     (Dictionary new at: 2 put: 3; yourself) collect: [:v | v * 10] >>> OrderedCollection (30)"
    | out | out := OrderedCollection new. self do: [:v | out add: (aBlock value: v)]. ^out ]
Dictionary >> select: aBlock [
    "Answers a new dictionary of the same class with the keys whose value
     aBlock answers true for.
     (Dictionary new at: 1 put: 10; at: 2 put: 20; yourself) select: [:v | v > 15] >>> Dictionary (2->20)"
    | out | out := self class new.
    self associationsDo: [:a | (aBlock value: a value) ifTrue: [out at: a key put: a value]].
    ^out ]
Dictionary >> = other [
    "Answers whether other is a Dictionary of the same class with the same
     keys, each with an equal value.
     (Dictionary new at: 1 put: 2; yourself) = (Dictionary new at: 1 put: 2; yourself) >>> true"
    self == other ifTrue: [^true].
    self class == other class ifFalse: [^false].
    self size = other size ifFalse: [^false].
    self keysAndValuesDo: [:k :v | (other includesKey: k) ifFalse: [^false]. (other at: k) = v ifFalse: [^false]].
    ^true ]
Dictionary >> hash [
    "The size: equal Dictionaries have equal hashes."
    ^self size ]
Dictionary >> printOn: aStream [
    "Prints the class name and the Associations, key->value, in
     parentheses, in the order of the table.
     (Dictionary new at: 1 put: 2; yourself) printString >>> 'Dictionary (1->2)'"
    aStream nextPutAll: self class name; nextPutAll: ' ('.
    self associations do: [:a | aStream print: a] separatedBy: [aStream space].
    aStream nextPut: $) ]
IdentityDictionary >> hashOf: key [
    "Answers key's identityHash."
    ^key identityHash ]
IdentityDictionary >> sameKey: a as: b [
    "Answers whether keys a and b are the same object (==)."
    ^a == b ]

Association class >> key: k value: v [
    "Answers a new Association of k and v; k -> v makes the same.
     Association key: 1 value: 2 >>> 1->2"
    ^self basicNew key: k value: v ]
Association >> key: k value: v [
    "Sets the key and the value."
    key := k. value := v ]
Association >> key [
    "The key.
     (3 -> 4) key >>> 3"
    ^key ]
Association >> value [
    "The value.
     (3 -> 4) value >>> 4"
    ^value ]
Association >> value: v [
    "Replaces the value with v.
     (3 -> 4) value: 5; yourself >>> 3->5"
    value := v ]
Association >> key: k [
    "Replaces the key with k (not to be done to one in a Dictionary).
     (3 -> 4) key: 5; yourself >>> 5->4"
    key := k ]
Association >> printOn: aStream [
    "Prints key->value, both printed.
     (#a -> 'b') printString >>> '#a->''b'''"
    aStream print: key; nextPutAll: '->'; print: value ]
Association >> = other [
    "Answers whether other is an Association with an equal key and an equal
     value.
     (3 -> 4) = (3 -> 4) >>> true"
    ^(other isKindOf: Association) and: [key = other key and: [value = other value]] ]
Association >> hash [
    "The key's hash.
     (3 -> 4) hash = 3 hash >>> true"
    ^key hash ]

"---- method dictionaries: as the VM probes them -----------------------------------"

MethodDictionary class >> new [
    "Answers an empty MethodDictionary, itself and its two arrays of 8 in
     far memory.
     MethodDictionary new size >>> 0"
    ^(self basicNewFar: 0) setEmpty; yourself ]
MethodDictionary >> setEmpty [
    "Makes it empty: no methods, two new far Arrays of 8."
    tally := 0. keys := Array basicNewFar: 8. values := Array basicNewFar: 8 ]
MethodDictionary >> indexOf: aSymbol [
    "The index of aSymbol in keys, or of the empty slot where it would go:
     linear probing from its identityHash, as the VM's lookup does."
    | n i k |
    keys == nil ifTrue: [self setEmpty].
    n := keys size.
    i := (aSymbol identityHash bitAnd: n - 1) + 1.
    [(k := keys at: i) == nil or: [k == aSymbol]] whileFalse: [i := i \\ n + 1].
    ^i ]
MethodDictionary >> at: aSymbol ifAbsent: aBlock [
    "The method for the selector aSymbol, or aBlock's value if there is none.
     (MethodDictionary new at: #foo put: 1; yourself) at: #bar ifAbsent: [0] >>> 0"
    | i |
    i := self indexOf: aSymbol.
    (keys at: i) == nil ifTrue: [^aBlock value].
    ^values at: i ]
MethodDictionary >> at: aSymbol [
    "The method for the selector aSymbol. Signals KeyNotFound if there is
     none.
     (Collection methodDict at: #sum) class >>> CompiledMethod"
    ^self at: aSymbol ifAbsent: [KeyNotFound new signal: 'no method ', aSymbol] ]
MethodDictionary >> includesKey: aSymbol [
    "Answers whether there is a method (not nil) for the selector aSymbol.
     (Array methodDict includesKey: #isArray) >>> true"
    ^(self at: aSymbol ifAbsent: [nil]) notNil ]
MethodDictionary >> at: aSymbol put: aMethod [
    "Puts aMethod for the selector aSymbol and answers it; the arrays double
     when they would be over half full.
     (MethodDictionary new at: #foo put: 1; yourself) at: #foo >>> 1"
    | i |
    i := self indexOf: aSymbol.
    (keys at: i) == nil ifTrue: [
        tally := tally + 1.
        tally * 2 > keys size ifTrue: [self grow. i := self indexOf: aSymbol]].
    keys at: i put: aSymbol.
    values at: i put: aMethod.
    ^aMethod ]
MethodDictionary >> grow [
    "Replaces keys and values with far Arrays twice as large and places
     each method in them again."
    | ok ov |
    ok := keys. ov := values.
    keys := Array basicNewFar: ok size * 2. values := Array basicNewFar: ok size * 2.
    1 to: ok size do: [:j | (ok at: j) == nil ifFalse: [
        | i | i := self indexOf: (ok at: j). keys at: i put: (ok at: j). values at: i put: (ov at: j)]] ]
MethodDictionary >> removeKey: aSymbol ifAbsent: aBlock [
    "Removes the method for the selector aSymbol and answers it, or answers
     aBlock's value if there is none. The arrays are rebuilt.
     (MethodDictionary new at: #b put: 1; at: #a put: 2; yourself) removeKey: #b ifAbsent: [0] >>> 1"
    | old |
    old := self at: aSymbol ifAbsent: [^aBlock value].
    self rebuildWithout: aSymbol.
    ^old ]
MethodDictionary >> rebuildWithout: aSymbol [
    "Replaces keys and values with new far Arrays of the same size holding
     every method but aSymbol's, and counts them again."
    | ok ov |
    ok := keys. ov := values.
    keys := Array basicNewFar: ok size. values := Array basicNewFar: ok size. tally := 0.
    1 to: ok size do: [:j | ((ok at: j) == nil or: [(ok at: j) == aSymbol]) ifFalse: [
        | i | i := self indexOf: (ok at: j). keys at: i put: (ok at: j). values at: i put: (ov at: j). tally := tally + 1]] ]
MethodDictionary >> keysDo: aBlock [
    "Evaluates aBlock with each selector, in the order of the table.
     | s | (MethodDictionary new at: #a put: 1; yourself) keysDo: [:k | s := k]. s >>> #a"
    keys == nil ifFalse: [keys do: [:k | k == nil ifFalse: [aBlock value: k]]] ]
MethodDictionary >> keys [
    "Answers an OrderedCollection of the selectors, sorted.
     (MethodDictionary new at: #b put: 1; at: #a put: 2; yourself) keys >>> OrderedCollection (#a #b)"
    | out | out := OrderedCollection new. self keysDo: [:k | out add: k]. ^out sort: [:a :b | a <= b] ]
MethodDictionary >> keysAndValuesDo: aBlock [
    "Evaluates aBlock with each selector and its method, in the order of
     the table.
     | s | s := 0. (MethodDictionary new at: #a put: 1; at: #b put: 2; yourself) keysAndValuesDo: [:k :v | s := s + v]. s >>> 3"
    keys == nil ifTrue: [^self].
    1 to: keys size do: [:i | (keys at: i) == nil ifFalse: [aBlock value: (keys at: i) value: (values at: i)]] ]
MethodDictionary >> size [
    "The number of methods.
     (MethodDictionary new at: #a put: 1; yourself) size >>> 1"
    ^tally ]

"---- Point -----------------------------------------------------------------------------"

Point class >> x: ax y: ay [
    "Answers the Point ax@ay; Number @ makes the same.
     Point x: 3 y: 4 >>> 3@4"
    ^self basicNew setX: ax y: ay ]
Point >> setX: ax y: ay [
    "Sets the coordinates."
    x := ax. y := ay ]
Point >> x [
    "The x coordinate.
     (3 @ 4) x >>> 3"
    ^x ]
Point >> y [
    "The y coordinate.
     (3 @ 4) y >>> 4"
    ^y ]
Point >> + p [
    "Answers the sum with p: a Point, coordinate by coordinate, or a number
     added to both.
     (3 @ 4) + 1 >>> 4@5"
    ^p isNumber ifTrue: [Point x: x + p y: y + p] ifFalse: [Point x: x + p x y: y + p y] ]
Point >> - p [
    "Answers the difference with p: a Point, coordinate by coordinate, or a
     number taken from both.
     (3 @ 4) - (1 @ 2) >>> 2@2"
    ^p isNumber ifTrue: [Point x: x - p y: y - p] ifFalse: [Point x: x - p x y: y - p y] ]
Point >> * n [
    "Answers the Point with both coordinates multiplied by the number n.
     (3 @ 4) * 2 >>> 6@8"
    ^Point x: x * n y: y * n ]
Point >> = p [
    "Answers whether p is a Point with the same coordinates.
     (3 @ 4) = (3 @ 4) >>> true"
    ^(p isKindOf: Point) and: [x = p x and: [y = p y]] ]
Point >> hash [
    "A hash of both coordinates, consistent with =.
     (3 @ 4) hash = (3 @ 4) hash >>> true"
    ^x hash bitXor: y hash ]
Point >> printOn: aStream [
    "Prints x@y.
     (3 @ 4) printString >>> '3@4'"
    aStream print: x; nextPut: $@; print: y ]
