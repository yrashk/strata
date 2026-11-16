"OS.st: StrataOS's servers, through their messages (os/spec/*.toml has
 every operation). A Server is an endpoint in one of the process's
 capability registers: proc 1, fs 2, tty 3, pipe 4 (every process is born
 with them), or one looked up by name. A request is a message: an
 operation, a handle, a mode and data out; a result word, a handle and
 data back."

Object subclass: #Server slots: 'name register'.
Object subclass: #ServerReply slots: 'result data'.
Object subclass: #Proc slots: ''.
Object subclass: #Fs slots: ''.
Object subclass: #Dev slots: ''.
Object subclass: #ProcessInfo slots: 'pid state core parent flags threads switches kib name'.

Server class >> register: n name: aString [ ^self new setRegister: n name: aString ]
Server class >> proc [ ^self register: 1 name: 'proc' ]
Server class >> fs [ ^self register: 2 name: 'fs' ]
Server class >> tty [ ^self register: 3 name: 'tty' ]
Server class >> pipe [ ^self register: 4 name: 'pipe' ]
Server class >> named: aString into: n [
    "A server registered under aString (proc LOOKUP), its endpoint in
     register n (1..4): what was there is given up until it is looked up
     again (`Server named: 'fs' into: 2`)."
    | r |
    r := Smalltalk osLookup: aString into: n.
    r < 0 ifTrue: [^Error new signal: 'no server named ', aString].
    ^self register: n name: aString ]
Server class >> dev [ "dev borrows fs's register; Server restoreFs gives it back" ^self named: 'dev' into: 2 ]
Server class >> restoreFs [ ^self named: 'fs' into: 2 ]
Server >> setRegister: n name: aString [ register := n. name := aString ]
Server >> register [ ^register ]
Server >> name [ ^name ]
Server >> request: op [ ^self request: op handle: 0 mode: 0 data: nil replySize: 0 ]
Server >> request: op handle: h [ ^self request: op handle: h mode: 0 data: nil replySize: 0 ]
Server >> request: op replySize: n [ ^self request: op handle: 0 mode: 0 data: nil replySize: n ]
Server >> request: op handle: h mode: m data: bytes replySize: n [
    "Send the message and wait for the reply. bytes: nil, a String or a
     ByteArray (at most 512 bytes); n: the reply's data wanted (at most 512)."
    | reply r |
    reply := n > 0 ifTrue: [ByteArray new: n] ifFalse: [nil].
    r := Smalltalk osSend: register op: op handle: h mode: m data: bytes reply: reply.
    ^ServerReply new setResult: r data: reply ]
Server >> printOn: aStream [ aStream nextPutAll: 'Server '; nextPutAll: name; nextPutAll: ' (c'; print: register; nextPut: $) ]

ServerReply >> setResult: r data: bytes [ result := r. data := bytes ]
ServerReply >> result [ ^result ]
ServerReply >> data [ ^data ]
ServerReply >> isError [ ^result < 0 ]
ServerReply >> u8At: i [ ^data at: i + 1 ]
ServerReply >> u16At: i [ ^(self u8At: i) + ((self u8At: i + 1) bitShift: 8) ]
ServerReply >> u32At: i [ ^(self u16At: i) + ((self u16At: i + 2) bitShift: 16) ]
ServerReply >> u64At: i [ ^(self u32At: i) + ((self u32At: i + 4) bitShift: 32) ]
ServerReply >> s64At: i [ | v | v := self u64At: i. ^v >= (1 bitShift: 63) ifTrue: [v - (1 bitShift: 64)] ifFalse: [v] ]
ServerReply >> stringAt: i size: n [
    "Bytes i .. i + n - 1 as a String, up to the first zero byte."
    | s k |
    s := WriteStream on: (String new: n).
    k := 0.
    [k < n and: [(self u8At: i + k) ~= 0]] whileTrue: [s nextPut: (Character value: (self u8At: i + k)). k := k + 1].
    ^s contents ]
ServerReply >> printOn: aStream [ aStream nextPutAll: 'a reply: '; print: result ]

"---- proc: processes ------------------------------------------------------------"

Proc class >> server [ ^Server proc ]
Proc class >> info [
    "INFO: a Dictionary of the system's summary."
    | r d |
    r := self server request: 16 replySize: 64.
    r isError ifTrue: [^Error new signal: 'proc INFO failed'].
    d := Dictionary new.
    #('cores' 'free heap' 'total heap' 'processes' 'kernel unit loads' 'context switches' 'KiB moved')
        doWithIndex: [:k :i | d at: k put: (r u64At: (i - 1) * 8)].
    ^d ]
Proc class >> ps [
    "PS: a ProcessInfo per process."
    | r out |
    r := self server request: 9 replySize: 512.
    r isError ifTrue: [^Error new signal: 'proc PS failed'].
    out := OrderedCollection new.
    0 to: (r result min: 16) - 1 do: [:i | out add: (ProcessInfo fromReply: r at: i * 32)].
    ^out ]
Proc class >> cores [
    "CORES: per core: {core. running pid. runnable. processes. flags. switches}."
    | r out |
    r := self server request: 31 replySize: 512.
    r isError ifTrue: [^Error new signal: 'proc CORES failed'].
    out := OrderedCollection new.
    0 to: (r result min: 16) - 1 do: [:i | | b |
        b := i * 32.
        out add: {r u8At: b. r u8At: b + 1. r u8At: b + 2. r u8At: b + 3. r u8At: b + 4. r u32At: b + 8}].
    ^out ]
Proc class >> pid [ ^self ps detect: [:p | p name = 'stratalk'] ifNone: [nil] ]

ProcessInfo class >> fromReply: r at: b [
    ^self new setPid: (r u8At: b) state: (r u8At: b + 1) core: (r u8At: b + 2) parent: (r u8At: b + 3)
        flags: (r u8At: b + 4) threads: (r u8At: b + 5) switches: (r u32At: b + 8) kib: (r u32At: b + 12)
        name: (r stringAt: b + 16 size: 8) ]
ProcessInfo >> setPid: p state: s core: c parent: pa flags: f threads: t switches: sw kib: k name: n [
    pid := p. state := s. core := c. parent := pa. flags := f. threads := t. switches := sw. kib := k. name := n ]
ProcessInfo >> pid [ ^pid ]
ProcessInfo >> name [ ^name ]
ProcessInfo >> core [ ^core ]
ProcessInfo >> parent [ ^parent ]
ProcessInfo >> switches [ ^switches ]
ProcessInfo >> isServer [ ^(flags bitAnd: 2) ~= 0 ]
ProcessInfo >> stateName [ ^#('running' 'ready' 'blocked' 'ended') at: state ifAbsent: ['?'] ]
ProcessInfo >> printOn: aStream [
    aStream print: pid; space; nextPutAll: name; nextPutAll: ' (core '; print: core;
        nextPutAll: ', '; nextPutAll: self stateName; nextPut: $) ]
SequenceableCollection >> at: i ifAbsent: aBlock [ (i between: 1 and: self size) ifFalse: [^aBlock value]. ^self at: i ]

"---- fs: the file system --------------------------------------------------------"

Fs class >> server [ ^Server fs ]
Fs class >> statfs [
    "STATFS: {total blocks. used blocks. files}"
    | r |
    r := self server request: 32 replySize: 24.
    r isError ifTrue: [^Error new signal: 'fs STATFS failed'].
    ^Array with: (r u64At: 0) with: (r u64At: 8) with: (r u64At: 16) ]
Fs class >> sizeOf: aPath [ ^File primSize: aPath ]
Fs class >> tags [
    "TAGS2: every tag's name and how many files carry it, as Associations."
    | out cursor r off n len |
    out := OrderedCollection new.
    cursor := 0.
    [r := self server request: 41 handle: cursor mode: 0 data: nil replySize: 512.
     r isError ifTrue: [^out].
     off := 0.
     1 to: r result do: [:i |
        n := r u16At: off. len := r u16At: off + 2.
        out add: (r stringAt: off + 16 size: len) -> (r u64At: off + 8).
        off := off + n].
     r result > 0 and: [(cursor := self lastCursor: r) ~= 0]] whileTrue.
    ^out ]
Fs class >> lastCursor: r [ "TAGS2 answers its cursor in the handle word; not kept by osSend" ^0 ]

"---- dev: the devices -----------------------------------------------------------"

Dev class >> server [ ^Server dev ]
Dev class >> devices [
    "DEVS: per entry {type. index. space. base. size}"
    | r out s |
    s := self server.
    r := s request: 23 replySize: 512.
    Server restoreFs.
    r isError ifTrue: [^Error new signal: 'dev DEVS failed'].
    out := OrderedCollection new.
    0 to: (r result min: 16) - 1 do: [:i | | b |
        b := i * 32.
        out add: {r u16At: b. r u16At: b + 2. r u16At: b + 4. r u64At: b + 16. r u64At: b + 24}].
    ^out ]
Dev class >> time [
    "TIME: {microseconds since 1970 when the timer read 0. the zone in seconds}"
    | r |
    r := self server request: 67 replySize: 32.
    Server restoreFs.
    r isError ifTrue: [^Error new signal: 'dev TIME failed'].
    ^Array with: (r u64At: 0) with: (r s64At: 8) ]

SystemDictionary >> osSend: reg op: op handle: h mode: m data: bytes reply: reply [ <primitive: 116> ^-1 ]
SystemDictionary >> osLookup: aName into: reg [ <primitive: 117> ^-4 ]
