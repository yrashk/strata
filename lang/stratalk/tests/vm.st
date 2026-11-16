(Smalltalk vm at: 'scavenges') > 0
| x | x := Array new: 3. x isNear
(Array new: 3000) isNear
#sym isNear
3 isNear
| keep | keep := Array new: 3. Smalltalk scavenge. keep isNear
(Smalltalk vm at: 'far heap (bytes)') >= 1048576
Smalltalk garbageCollect. (Smalltalk vm at: 'full collections') > 0
| k | k := OrderedCollection new. 1 to: 200 do: [:i | k add: (Array new: 400)]. k := nil. 1 to: 40 do: [:j | | a | a := (1 to: 300) collect: [:i | Array new: 300]]. (Smalltalk vm at: 'full collections') > 1
(Smalltalk vm at: 'freed (bytes)') > 10000000
| keep | keep := (1 to: 2000) collect: [:i | i printString]. Smalltalk garbageCollect. (keep at: 1999) , (keep at: 7)
