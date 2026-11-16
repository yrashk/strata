(Smalltalk vm at: 'scavenges') > 0
| x | x := Array new: 3. x isNear
(Array new: 3000) isNear
#sym isNear
3 isNear
| keep | keep := Array new: 3. Smalltalk scavenge. keep isNear
(Smalltalk vm at: 'far heap (bytes)') >= 1048576
