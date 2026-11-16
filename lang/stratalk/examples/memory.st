"memory.st: where objects live. New objects are made near (in the core's
 D-LS nursery); the ones that survive a scavenge are copied out to far
 memory in one transfer. Far objects are read through the far cache."

| a stats keep |
a := Array new: 10.
Transcript showln: 'a new Array is near: ', a isNear printString.
Smalltalk scavenge.
Transcript showln: 'after a scavenge: ', a isNear printString.
Transcript showln: 'a Symbol is always far: ', #hello isNear not printString.
keep := OrderedCollection new.
1 to: 3000 do: [:i | keep add: i printString].
stats := Smalltalk vm.
#('scavenges' 'promoted (bytes)' 'far cache misses' 'far reads (bytes)' 'far writes (bytes)')
    do: [:k | Transcript showln: k, ': ', (stats at: k) printString].
