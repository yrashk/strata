"OS.st: StrataOS's servers, through their messages (os/spec/*.toml has
 every operation; OSServers.st, made from it, has a class per server and a
 method per op). An OSServer is an endpoint in one of the process's
 capability registers (proc 1, fs 2, tty 3, pipe 4: every process is born
 with them; others are looked up by name into register 2, which is fs's:
 `Server restoreFs` gives it back) and a server index (header word 48: a
 core's second server). A request is a message: an operation, a handle,
 a length, a mode and data out; a result, a handle, a length, a mode and
 data back (at most 1024 bytes of data each way)."

Object subclass: #OSServer slots: 'register lookup index'.
"An endpoint of a StrataOS server: what a message is sent to. register is
 the capability register that holds the endpoint (1 proc, 2 fs, 3 tty, 4
 pipe), lookup the server's name when it has to be looked up into that
 register first (nil: the register already holds it), index the server
 of the core (header word 48; 0: the core's first). send:handle:length:mode:data:
 sends one message and answers an OSReply; op:named:args:request:reply:,
 which the generated classes of OSServers.st (ProcServer, FsServer, ...)
 use, packs the request's fields from a Dictionary by the op's spec.
 (OSServer register: 1 lookup: nil index: 0) printString >>> 'OSServer (c1)'"

Object subclass: #OSReply slots: 'result handle length mode data spec'.
"The reply to one message to a server: result (the reply's first word; <
 0 an error), handle, length and mode (its other words) and data (a
 ByteArray of 1024 bytes, the reply's data at its start). spec, when the
 op's spec is known, is the reply's layout, from which fields decodes a
 Dictionary. u8At: .. s64At: read little-endian words at a 0-based offset.
 ((OSReply new setResult: 0 handle: 0 length: 2 mode: 0 data: #[1 2]) u16At: 0) >>> 513"

OSServer subclass: #Server slots: ''.
"An OSServer reached by its register, or its name, with requests made of
 the raw words: Server proc, Server fs, Server tty, Server pipe, Server db,
 Server named: 'dev'. The generated classes of OSServers.st (ProcServer
 default, ...) are the friendlier way: Server is for an op they lack.
 Server db printString >>> 'Server (c4, server 1)'"

Object subclass: #Proc slots: ''.
"The process server, proc, in a few class-side questions: info (INFO),
 ps (PS: a ProcessInfo per process) and cores (CORES). Proc ps is what
 the shell's ps shows. No instances; ProcServer default has every op."

Object subclass: #Fs slots: ''.
"The file system server, fs, in a few class-side questions: statfs
 (STATFS), sizeOf: (STAT) and tags (TAGS2). Files themselves are File's.
 No instances; FsServer default has every op."

Object subclass: #Dev slots: ''.
"The device manager, dev, in two class-side questions: devices (DEVS,
 the platform table) and time (TIME, the wall clock). dev is looked up
 by name (LOOKUP 'dev') into register 2 for each request. No instances;
 DevServer default has every op."

Object subclass: #Tty slots: ''.
"The console server, tty (capability register 3), in three class-side
 requests: raw and cooked (CONMODE) and foreground: (SETFG). No
 instances; TtyServer default has every op."

Object subclass: #Blk slots: ''.
"The disk's raw blocks, read through fs (READBLK, which fs hands on to
 the block server, blk): Blk block: n. No instances."

Object subclass: #Db slots: 'namespace tree'.
"One tree of the store for programs: keys and values (Strings, compared
 as unsigned bytes), in key order, in a namespace of the program's own.
 namespace and tree are the two names, written NAMESPACE/TREE (Db tree:
 'demo/notes'). Reads go to the db server (DBGET, DBSCAN, through
 register 4 with server index 1), writes to fs (DBBATCH, which fs hands
 on to db), each one a commit of its own. Used like a Dictionary: at:,
 at:put:, removeKey:, keysAndValuesDo:.
 (Db tree: 'demo/notes') printString >>> 'Db demo/notes'"

Object subclass: #ProcessInfo slots: 'pid state core parent flags threads switches kib name'.
"One process as proc's PS reply describes it (Proc ps answers a
 collection of them): pid, state (1 running, 2 ready, 3 blocked, 4
 ended), core (its first core), parent (0: none), flags (2: a server),
 threads, switches (its context switches), kib (KiB moved) and name (up
 to 8 characters).
 (ProcessInfo new setPid: 3 state: 2 core: 1 parent: 1 flags: 0 threads: 1 switches: 0 kib: 0 name: 'sh') printString >>> '3 sh (core 1, ready)'"

SystemDictionary >> osSend: reg op: op handle: h length: n mode: m server: index data: bytes reply: reply [
    "Sends one message to the endpoint in capability register reg (1..4)
     and answers the reply's result word. A VM primitive (116): op, h, n
     and m are the request's words, index the core's server (header word
     48; 0: none); bytes (a String or ByteArray, or nil) is the request's
     data, and the reply's data is copied into reply (as much as fits, at
     most 1024 bytes; nil: none). n nil means the data's size. Answers -1
     if an argument is not of those kinds."
    <primitive: 116> ^-1 ]
SystemDictionary >> osReply [
    "Answers {handle. length. mode}: the other words of the last reply
     osSend: received. A VM primitive (119)."
    <primitive: 119> ]
SystemDictionary >> osLookup: aName into: reg [
    "Looks the server named aName up (proc LOOKUP) and puts its endpoint
     into capability register reg (1..4), replacing what was there.
     Answers 0, or below 0 if there is no such server. A VM primitive
     (117); -4 if it fails."
    <primitive: 117> ^-4 ]

"---- reaching a server, and the generic request ----------------------------"

OSServer class >> register: n lookup: aName index: i [
    "Answers an endpoint in capability register n, looked up by aName
     before each message when aName is not nil, with server index i (0:
     the core's first server). Sends nothing."
    ^self new setRegister: n lookup: aName index: i ]
OSServer >> setRegister: n lookup: aName index: i [
    "Sets the register, the name to look up (or nil) and the server index;
     answers the receiver."
    register := n. lookup := aName. index := i ]
OSServer >> register [
    "The capability register (1..4) the endpoint is in."
    ^register ]
OSServer >> index [
    "The server of the core the messages go to (header word 48): 0 the
     core's first, 1 its second (db on pipe's core)."
    ^index ]
OSServer >> connect [
    "For a server reached by name, looks it up (proc LOOKUP) into its
     register before a message, each time: the register is lent (fs's,
     usually). Signals an Error if there is no server of that name. Does
     nothing for a server whose register holds it already."
    | r |
    lookup == nil ifTrue: [^self].
    r := Smalltalk osLookup: lookup into: register.
    r < 0 ifTrue: [^Error new signal: 'no server named ', lookup] ]
OSServer class >> ownServerOf: n [
    "The name of the server every process is born with in register n (1..4).
     OSServer ownServerOf: 4 >>> 'pipe'"
    ^#('proc' 'fs' 'tty' 'pipe') at: n ]
SystemDictionary >> lentRegisters [
    "Answers a Dictionary: register -> (the OSServer holding it -> the name
     of its server), for the registers 1..4 given to another server than
     their own (a Window's ws), while they are."
    ^self at: #LentRegisters ifAbsent: [self at: #LentRegisters put: Dictionary new] ]
SystemDictionary >> lend: n to: anOSServer name: aString [
    "Notes that register n holds anOSServer's server, named aString, until
     lentRegisters forgets it."
    self lentRegisters at: n put: anOSServer -> aString ]
OSServer >> disconnect [
    "After a message to a server looked up into register 2, gives that
     register back to fs (Server restoreFs)."
    (lookup notNil and: [register = 2]) ifTrue: [Server restoreFs] ]
OSServer >> send: op handle: h length: n mode: m data: bytes [
    "Sends one message (op, h, n, m and the data bytes, or nil) and answers
     an OSReply of the result, the reply's handle, length and mode and its
     data, undecoded (no spec). n nil means the data's size. Connects
     first and disconnects after, for a server reached by name. When the
     register is lent to another server (a Window's ws), the register's
     own server is put back for the message, and the other one after it."
    | reply r words holder |
    reply := ByteArray new: 1024.
    holder := Smalltalk lentRegisters at: register ifAbsent: [nil].
    (holder notNil and: [holder key == self]) ifTrue: [holder := nil].
    (holder notNil and: [lookup == nil]) ifTrue: [Smalltalk osLookup: (OSServer ownServerOf: register) into: register].
    self connect.
    r := Smalltalk osSend: register op: op handle: h length: n mode: m server: index data: bytes reply: reply.
    words := Smalltalk osReply.
    self disconnect.
    holder == nil ifFalse: [Smalltalk osLookup: holder value into: register].
    ^OSReply new setResult: r handle: (words at: 1) length: (words at: 2) mode: (words at: 3) data: reply ]
OSServer >> op: num named: aString args: args request: reqSpec reply: repSpec [
    "Sends op num and answers its OSReply, which decodes by repSpec. The
     request's words come from args (a Dictionary): 'handle', 'length' and
     'mode' (0, or the data's size, when absent); its data is packed from
     args by reqSpec (none when it packs to nothing). What every generated
     op method of OSServers.st calls; aString is the op's name."
    | data n r |
    data := self pack: reqSpec from: args.
    data isEmpty ifTrue: [data := nil].
    n := args at: 'length' ifAbsent: [nil].
    r := self send: num handle: (args at: 'handle' ifAbsent: [0]) length: n
        mode: (args at: 'mode' ifAbsent: [0]) data: data.
    ^r spec: repSpec name: aString ]
OSServer >> pack: spec from: args [
    "Answers a ByteArray of the fields of spec packed from args (a
     Dictionary by field name), as pack:from:into: does it. Sends nothing.
     (OSServer new pack: #(#(#u8 'a') #(#u16 'b')) from: (Dictionary new at: 'a' put: 1; at: 'b' put: 258; yourself)) >>> #[1 2 1]"
    | out |
    out := WriteStream on: (ByteArray new: 64).
    self pack: spec from: args into: out.
    ^out contents ]
OSServer >> pack: spec from: args into: out [
    "Writes the fields of spec, each {type. name} (or {#repeat. name.
     spec}), from args onto the byte stream out. #u8 .. #u64 and #s64 are
     little-endian (a missing value is 0, a String its first bytes), #bytes
     a String's or ByteArray's bytes, #text the same and a zero byte, #pad
     zeros to a multiple of 8, #repeat each Dictionary of the collection
     args at: name, by the inner spec."
    spec do: [:f | | type name v |
        type := f at: 1. name := f at: 2.
        type == #repeat
            ifTrue: [(args at: name ifAbsent: [#()]) do: [:rec | self pack: (f at: 3) from: rec into: out]]
            ifFalse: [
                v := args at: name ifAbsent: [nil].
                type == #pad ifTrue: [[out position \\ 8 = 0] whileFalse: [out nextPut: 0]].
                (#(#u8 #u16 #u32 #u64 #s64) includes: type) ifTrue: [
                    | n | n := #(1 2 4 8 8) at: (#(#u8 #u16 #u32 #u64 #s64) indexOf: type).
                    v isString
                        ifTrue: [1 to: n do: [:i | out nextPut: (i <= v size ifTrue: [(v at: i) value \\ 256] ifFalse: [0])]]
                        ifFalse: [
                            | x | x := v ifNil: [0].
                            x < 0 ifTrue: [x := x + (1 bitShift: 64)].
                            n timesRepeat: [out nextPut: (x bitAnd: 255). x := x bitShift: -8]]].
                (type == #bytes or: [type == #text]) ifTrue: [
                    v notNil ifTrue: [v asByteArray do: [:b | out nextPut: b]].
                    type == #text ifTrue: [out nextPut: 0]]]] ]
OSServer >> printOn: aStream [
    "Writes the class's name and the register, and the server index when
     it is not 0.
     Server db printString >>> 'Server (c4, server 1)'"
    aStream nextPutAll: self class name; nextPutAll: ' (c'; print: register.
    index = 0 ifFalse: [aStream nextPutAll: ', server '; print: index].
    aStream nextPut: $) ]
String >> asByteArray [
    "Answers a ByteArray of the characters' values (each mod 256).
     'hi' asByteArray >>> #[104 105]"
    | b | b := ByteArray new: self size. 1 to: self size do: [:i | b at: i put: (self at: i) value \\ 256]. ^b ]
ByteArray >> asByteArray [
    "Answers the receiver itself.
     #[1 2] asByteArray >>> #[1 2]"
    ^self ]

OSReply >> setResult: r handle: h length: n mode: m data: bytes [
    "Sets the reply's four words and its data; answers the receiver."
    result := r. handle := h. length := n. mode := m. data := bytes ]
OSReply >> spec: aSpec name: aString [
    "Sets the spec fields decodes the data by (aString, the op's name, is
     not kept); answers the receiver."
    spec := aSpec ]
OSReply >> result [
    "The reply's result word: what the op answers, below 0 an error."
    ^result ]
OSReply >> handle [
    "The reply's handle word (a cursor, an id: what the op says)."
    ^handle ]
OSReply >> length [
    "The reply's length word: usually the data's bytes."
    ^length ]
OSReply >> mode [
    "The reply's mode word."
    ^mode ]
OSReply >> data [
    "The reply's data: a ByteArray of 1024 bytes, what the server sent at
     its start."
    ^data ]
OSReply >> isError [
    "Answers whether the result is below 0.
     (OSReply new setResult: -4 handle: 0 length: 0 mode: 0 data: #[]) isError >>> true"
    ^result < 0 ]
OSReply >> dataSize [
    "The number of bytes of data that count: the length word when it is
     above 0 and within the data, else the data's size.
     (OSReply new setResult: 0 handle: 0 length: 2 mode: 0 data: #[1 2 3 4]) dataSize >>> 2"
    ^(length > 0 and: [length <= data size]) ifTrue: [length] ifFalse: [data size] ]
OSReply >> u8At: i [
    "The byte of the data at offset i (0-based).
     (OSReply new setResult: 0 handle: 0 length: 0 mode: 0 data: #[7 8]) u8At: 1 >>> 8"
    ^data at: i + 1 ]
OSReply >> u16At: i [
    "The little-endian 16-bit word of the data at offset i (0-based).
     (OSReply new setResult: 0 handle: 0 length: 0 mode: 0 data: #[1 2]) u16At: 0 >>> 513"
    ^(self u8At: i) + ((self u8At: i + 1) bitShift: 8) ]
OSReply >> u32At: i [
    "The little-endian 32-bit word of the data at offset i (0-based).
     (OSReply new setResult: 0 handle: 0 length: 0 mode: 0 data: #[0 0 1 0]) u32At: 0 >>> 65536"
    ^(self u16At: i) + ((self u16At: i + 2) bitShift: 16) ]
OSReply >> u64At: i [
    "The little-endian 64-bit word of the data at offset i (0-based),
     unsigned: it may be a LargeInteger.
     (OSReply new setResult: 0 handle: 0 length: 0 mode: 0 data: #[255 255 255 255 255 255 255 255]) u64At: 0 >>> 18446744073709551615"
    ^(self u32At: i) + ((self u32At: i + 4) bitShift: 32) ]
OSReply >> s64At: i [
    "The little-endian 64-bit word of the data at offset i (0-based), in
     two's complement.
     (OSReply new setResult: 0 handle: 0 length: 0 mode: 0 data: #[255 255 255 255 255 255 255 255]) s64At: 0 >>> -1"
    | v | v := self u64At: i. ^v >= (1 bitShift: 63) ifTrue: [v - (1 bitShift: 64)] ifFalse: [v] ]
OSReply >> stringAt: i size: n [
    "Answers bytes i .. i + n - 1 of the data (0-based) as a String, up to
     the first zero byte or the data's end.
     (OSReply new setResult: 0 handle: 0 length: 0 mode: 0 data: #[104 105 0 33]) stringAt: 0 size: 4 >>> 'hi'"
    | s k |
    s := WriteStream on: (String new: n).
    k := 0.
    [k < n and: [i + k < data size and: [(self u8At: i + k) ~= 0]]] whileTrue: [
        s nextPut: (Character value: (self u8At: i + k)). k := k + 1].
    ^s contents ]
OSReply >> fields [
    "Answers the data decoded by the op's spec: a Dictionary from the
     fields' names (as os/spec names them) to their values, with 'result'
     the result word. A repeated group's records are under 'records', each
     a Dictionary. With no spec, or an error result, only 'result'.
     ((OSReply new setResult: 0 handle: 0 length: 3 mode: 0 data: #[7 1 0]) spec: #(#(#u8 'a') #(#u16 'b')) name: 'X'; fields) at: 'b' >>> 1"
    | d |
    d := Dictionary new.
    d at: 'result' put: result.
    spec == nil ifTrue: [^d].
    result < 0 ifTrue: [^d].
    self decode: spec at: 0 to: self dataSize into: d.
    ^d ]
OSReply >> decode: aSpec at: start to: end into: d [
    "Decodes the fields of aSpec from offset start, not past end, into the
     Dictionary d, and answers the offset after them. A #bytes field takes
     as many bytes as the last field whose name says length (else the
     rest); #text runs to a zero byte; fields named '0' are skipped."
    | off lastLength |
    off := start.
    lastLength := nil.
    aSpec do: [:f | | type name |
        type := f at: 1. name := f at: 2.
        type == #repeat ifTrue: [off := self decodeRecords: (f at: 3) at: off to: end into: d].
        type == #pad ifTrue: [[off \\ 8 = 0] whileFalse: [off := off + 1]].
        (#(#u8 #u16 #u32 #u64 #s64) includes: type) ifTrue: [
            | n v | n := #(1 2 4 8 8) at: (#(#u8 #u16 #u32 #u64 #s64) indexOf: type).
            off + n <= end ifTrue: [
                v := type == #u8 ifTrue: [self u8At: off] ifFalse: [
                     type == #u16 ifTrue: [self u16At: off] ifFalse: [
                     type == #u32 ifTrue: [self u32At: off] ifFalse: [
                     type == #u64 ifTrue: [self u64At: off] ifFalse: [self s64At: off]]]].
                name = '0' ifFalse: [d at: name put: v].
                (name includesSubstring: 'length') ifTrue: [lastLength := v]].
            off := off + n].
        type == #bytes ifTrue: [
            | n | n := lastLength ifNil: [end - off].
            n := n min: end - off.
            d at: name put: (self stringAt: off size: n).
            lastLength := nil.
            off := off + n].
        type == #text ifTrue: [
            | s | s := self stringAt: off size: end - off.
            d at: name put: s.
            off := off + s size + 1]].
    ^off ]
OSReply >> decodeRecords: aSpec at: start to: end into: d [
    "Decodes records of aSpec from offset start until end (or, with a
     result above 0, that many records) into an OrderedCollection of
     Dictionaries at d's 'records'; answers the offset after them. A
     record's 'record bytes' field, if it has one, is its stride."
    | records off fixed stride |
    records := OrderedCollection new.
    fixed := aSpec inject: 0 into: [:s :f |
        s + ((#(#u8 #u16 #u32 #u64 #s64) includes: (f at: 1))
            ifTrue: [#(1 2 4 8 8) at: (#(#u8 #u16 #u32 #u64 #s64) indexOf: (f at: 1))] ifFalse: [0])].
    off := start.
    [off + fixed <= end and: [fixed > 0 and: [result <= 0 or: [records size < result]]]] whileTrue: [
        | r next |
        r := Dictionary new.
        next := self decode: aSpec at: off to: end into: r.
        stride := r at: 'record bytes' ifAbsent: [next - off].
        stride <= 0 ifTrue: [^end].
        records add: r.
        off := off + stride].
    d at: 'records' put: records.
    ^off ]
OSReply >> printOn: aStream [
    "Writes 'an OSReply' and the result.
     (OSReply new setResult: 3 handle: 0 length: 0 mode: 0 data: #[]) printString >>> 'an OSReply 3'"
    aStream nextPutAll: 'an OSReply '; print: result ]

"---- Server: the endpoints by name (OSServer's simplest use) ------------------"

Server class >> proc [
    "Answers the endpoint of proc, the process server: capability register 1.
     Server proc printString >>> 'Server (c1)'"
    ^self register: 1 lookup: nil index: 0 ]
Server class >> fs [
    "Answers the endpoint of fs, the file system server: capability
     register 2."
    ^self register: 2 lookup: nil index: 0 ]
Server class >> tty [
    "Answers the endpoint of tty, the console server: capability register 3."
    ^self register: 3 lookup: nil index: 0 ]
Server class >> pipe [
    "Answers the endpoint of pipe, the pipe server: capability register 4."
    ^self register: 4 lookup: nil index: 0 ]
Server class >> db [
    "Answers the endpoint of db, the store's server: the second server
     (index 1) of pipe's core, through capability register 4."
    ^self register: 4 lookup: nil index: 1 ]
Server class >> named: aString [
    "Answers an endpoint of the server named aString, looked up (proc
     LOOKUP) into register 2 before each message and fs given back after."
    ^self register: 2 lookup: aString index: 0 ]
Server class >> named: aString into: n [
    "Looks the server named aString up (proc LOOKUP) into capability
     register n (1..4) and answers its endpoint there; the register holds
     it until given back (restoreFs, restorePipe). Signals an Error if
     there is no such server."
    | r |
    r := Smalltalk osLookup: aString into: n.
    r < 0 ifTrue: [^Error new signal: 'no server named ', aString].
    ^self register: n lookup: nil index: 0 ]
Server class >> restoreFs [
    "Puts fs's endpoint back into register 2 (proc LOOKUP 'fs'); answers
     the lookup's result."
    ^Smalltalk osLookup: 'fs' into: 2 ]
Server class >> restorePipe [
    "Puts pipe's endpoint back into register 4 (proc LOOKUP 'pipe');
     answers the lookup's result."
    ^Smalltalk osLookup: 'pipe' into: 4 ]
Server >> request: op [
    "Sends op with no handle, mode or data; answers the OSReply."
    ^self request: op handle: 0 mode: 0 data: nil replySize: 0 ]
Server >> request: op handle: h [
    "Sends op with handle h and no data; answers the OSReply."
    ^self request: op handle: h mode: 0 data: nil replySize: 0 ]
Server >> request: op replySize: n [
    "Sends op with no handle or data; answers the OSReply. n is not used:
     the reply's data is always up to 1024 bytes."
    ^self request: op handle: 0 mode: 0 data: nil replySize: n ]
Server >> request: op handle: h mode: m data: bytes replySize: n [
    "Sends op with handle h, mode m and the data bytes (or nil; the length
     word is their size) and answers the OSReply. n is not used: the
     reply's data is always up to 1024 bytes."
    ^self send: op handle: h length: nil mode: m data: bytes ]

"---- the friendlier faces of a few servers ------------------------------------"

Proc class >> info [
    "Answers a summary of the system: proc INFO's fields as a Dictionary
     (cores, free heap, total heap, processes, kernel unit loads, context
     switches, KiB moved), through register 1."
    ^ProcServer default info fields ]
Proc class >> ps [
    "Answers the processes: proc PS (register 1), each record made a
     ProcessInfo (pid, state, core, parent, flags, threads, switches, KiB
     moved, name). Signals an error if PS fails (no records)."
    ^(ProcServer default ps fields at: 'records') collect: [:r | ProcessInfo fromFields: r] ]
Proc class >> cores [
    "Answers what every core is doing: proc CORES (register 1), a
     Dictionary per core (core, pid running, runnable, processes, flags,
     switches, KiB moved, cycles per switch and per trap)."
    ^ProcServer default cores fields at: 'records' ]

ProcessInfo class >> fromFields: d [
    "Answers a ProcessInfo of one record of proc's PS reply, a Dictionary
     of its fields (the name a u64, made a String by nameOf:)."
    ^self new setPid: (d at: 'pid') state: (d at: 'state') core: (d at: 'core') parent: (d at: 'parent')
        flags: (d at: 'flags') threads: (d at: 'threads') switches: (d at: 'switches')
        kib: (d at: 'KiB moved') name: (ProcessInfo nameOf: (d at: 'name')) ]
ProcessInfo class >> nameOf: n [
    "Answers the String of a u64 name field: up to 8 bytes, the first in
     the low byte, zero-padded.
     ProcessInfo nameOf: 26984 >>> 'hi'"
    | s x |
    s := WriteStream on: (String new: 8).
    x := n.
    [x > 0] whileTrue: [s nextPut: (Character value: (x bitAnd: 255)). x := x bitShift: -8].
    ^s contents ]
ProcessInfo >> setPid: p state: s core: c parent: pa flags: f threads: t switches: sw kib: k name: n [
    "Sets every field; answers the receiver."
    pid := p. state := s. core := c. parent := pa. flags := f. threads := t. switches := sw. kib := k. name := n ]
ProcessInfo >> pid [
    "The process's id."
    ^pid ]
ProcessInfo >> name [
    "The process's name, up to 8 characters."
    ^name ]
ProcessInfo >> core [
    "The process's first core."
    ^core ]
ProcessInfo >> parent [
    "The parent's pid, 0 for none."
    ^parent ]
ProcessInfo >> switches [
    "The number of context switches of the process."
    ^switches ]
ProcessInfo >> isServer [
    "Answers whether the process is a server (flags bit 1)."
    ^(flags bitAnd: 2) ~= 0 ]
ProcessInfo >> stateName [
    "The state's name: running, ready, blocked or ended; '?' for another.
     (ProcessInfo new setPid: 3 state: 3 core: 1 parent: 1 flags: 0 threads: 1 switches: 0 kib: 0 name: 'sh') stateName >>> 'blocked'"
    ^#('running' 'ready' 'blocked' 'ended') at: state ifAbsent: ['?'] ]
ProcessInfo >> printOn: aStream [
    "Writes the pid, the name, the core and the state's name.
     (ProcessInfo new setPid: 3 state: 2 core: 1 parent: 1 flags: 0 threads: 1 switches: 0 kib: 0 name: 'sh') printString >>> '3 sh (core 1, ready)'"
    aStream print: pid; space; nextPutAll: name; nextPutAll: ' (core '; print: core;
        nextPutAll: ', '; nextPutAll: self stateName; nextPut: $) ]
SequenceableCollection >> at: i ifAbsent: aBlock [
    "Answers the element at index i, or the value of aBlock if i is not
     between 1 and the size.
     #(1 2) at: 3 ifAbsent: [0] >>> 0"
    (i between: 1 and: self size) ifFalse: [^aBlock value]. ^self at: i ]

Fs class >> statfs [
    "Answers {total blocks. used blocks. files}: fs STATFS (register 2).
     A block is 512 bytes; used blocks counts snapshots' pages too."
    | f | f := FsServer default statfs fields.
    ^Array with: (f at: 'total blocks') with: (f at: 'used blocks') with: (f at: 'files') ]
Fs class >> sizeOf: aPath [
    "Answers the size in bytes of the file at aPath, or below 0 if there
     is none: fs STAT, through File primSize:."
    ^File primSize: aPath ]
Fs class >> tags [
    "Answers every tag as an OrderedCollection of Associations, the tag's
     name -> the number of files carrying it: fs TAGS2 (register 2), asked
     again with the reply's handle as the cursor until it is 0. A failed
     request ends the list."
    | out cursor r |
    out := OrderedCollection new.
    cursor := 0.
    [r := FsServer default tags2: (Dictionary new at: 'handle' put: cursor; yourself).
     r isError ifFalse: [(r fields at: 'records' ifAbsent: [#()]) do: [:t | out add: (t at: 'the name') -> (t at: 'files carrying it')]].
     r isError not and: [r result > 0 and: [(cursor := r handle) ~= 0]]] whileTrue.
    ^out ]

Dev class >> devices [
    "Answers the platform table: dev DEVS (dev looked up into register 2),
     a Dictionary per entry (type, index, space, node, info, base, size)."
    ^DevServer default devs fields at: 'records' ]
Dev class >> time [
    "Answers {EPOCH. ZONE}: the wall clock, dev TIME (dev looked up into
     register 2): the timer's EPOCH and the zone's offset (signed)."
    | f | f := DevServer default time fields. ^Array with: (f at: 'EPOCH') with: (f at: 'ZONE') ]

Tty class >> raw [
    "Makes the console raw: keys as they come, no echo (tty CONMODE,
     handle 1, through register 3). Answers the OSReply."
    ^TtyServer default conmode: (Dictionary new at: 'handle' put: 1; yourself) ]
Tty class >> cooked [
    "Makes the console cooked: lines, edited and echoed (tty CONMODE,
     handle 0, through register 3). Answers the OSReply."
    ^TtyServer default conmode: (Dictionary new at: 'handle' put: 0; yourself) ]
Tty class >> foreground: aPid [
    "Makes the process aPid the console's foreground, the one Ctrl-C
     interrupts (tty SETFG, through register 3; the pid is not checked).
     Answers the OSReply."
    ^TtyServer default setfg: (Dictionary new at: 'handle' put: aPid; yourself) ]

Blk class >> block: n [
    "Answers block n of the disk, a ByteArray of 512 bytes: fs READBLK
     (register 2), which fs hands on to blk. Answered even when the disk
     is not a store. Signals an Error past the disk's end."
    | r |
    r := FsServer default readblk: (Dictionary new at: 'handle' put: n; yourself).
    r isError ifTrue: [^Error new signal: 'cannot read block ', n printString].
    ^r data copyFrom: 1 to: 512 ]

"---- Db: a tree of the store for programs: keys and values (Strings), in key order ----"
Db class >> tree: aString [
    "Answers the Db of the tree named aString, 'NAMESPACE/TREE' (split at
     the first /). Sends nothing: the tree is made by its first write.
     Signals an Error if aString has no /.
     (Db tree: 'demo/notes') printString >>> 'Db demo/notes'"
    | i |
    i := aString indexOf: $/.
    i = 0 ifTrue: [^Error new signal: 'a tree is named NAMESPACE/TREE'].
    ^self new setNamespace: (aString copyFrom: 1 to: i - 1) tree: (aString copyFrom: i + 1 to: aString size) ]
Db >> setNamespace: n tree: t [
    "Sets the namespace's and the tree's names; answers the receiver."
    namespace := n. tree := t ]
Db >> names: key [
    "Answers the request fields of DBGET and DBSCAN for key in this tree:
     a Dictionary of the three lengths and the three names, as the spec
     names them. Sends nothing."
    | d |
    d := Dictionary new.
    d at: 'namespace name length' put: namespace size; at: 'tree name length' put: tree size; at: 'key length' put: key size.
    d at: 'the namespace''s name' put: namespace; at: 'the tree''s name' put: tree; at: 'the key' put: key.
    ^d ]
Db >> at: key [
    "Answers the value at key (a String), read with DBGET (db, through
     register 4). Signals KeyNotFound if the tree has no such key."
    ^self at: key ifAbsent: [KeyNotFound new signal: 'no key ', key printString] ]
Db >> at: key ifAbsent: aBlock [
    "Answers the value at key as a String: db DBGET (DbServer default:
     register 4, server index 1), the reply's result its length. Answers
     the value of aBlock if the request fails (no such key, tree or
     namespace)."
    | r |
    r := DbServer default dbget: (self names: key).
    r isError ifTrue: [^aBlock value].
    ^(r data copyFrom: 1 to: r result) asStringBytes ]
Db >> batch: kind key: key value: value [
    "Sends fs DBBATCH (66, register 2, which fs hands on to db) with one
     item, kind 1 put or 2 delete, of key and value: one commit. Answers
     value. Signals an Error if the store refuses it (a bad name or
     length, a private namespace, a full disk)."
    | head item data r |
    head := OSServer new pack: #(#(#u8 'n') #(#u8 't') #(#u16 'k') #(#u32 '0') #(#bytes 'ns') #(#bytes 'tr') #(#pad ''))
        from: (Dictionary new at: 'n' put: namespace size; at: 't' put: tree size; at: 'k' put: 0;
            at: 'ns' put: namespace; at: 'tr' put: tree; yourself).
    item := OSServer new pack: #(#(#u8 'what') #(#u8 '0') #(#u16 'kl') #(#u16 'vl') #(#u16 '0') #(#bytes 'key') #(#pad '') #(#bytes 'value') #(#pad ''))
        from: (Dictionary new at: 'what' put: kind; at: 'kl' put: key size; at: 'vl' put: value size;
            at: 'key' put: key; at: 'value' put: value; yourself).
    data := head , item.
    r := Server fs send: 66 handle: 1 length: nil mode: 0 data: data.
    r isError ifTrue: [^Error new signal: 'the store refused it (', r result printString, ')'].
    ^value ]
Db >> at: key put: value [
    "Puts value (a String) at key, in a commit of its own (fs DBBATCH, a
     put); answers value. Signals an Error if the store refuses it."
    ^self batch: 1 key: key value: value ]
Db >> removeKey: key [
    "Deletes key from the tree, in a commit of its own (fs DBBATCH, a
     delete); answers ''. Signals an Error if the store refuses it."
    ^self batch: 2 key: key value: '' ]
Db >> keysAndValuesDo: aBlock [
    "Evaluates aBlock with each key and its value, in key order: db DBSCAN
     (DbServer default: register 4, server index 1), part by part, from
     the start (mode 0) and then after the last key answered (mode 1).
     Stops at a failed or empty reply."
    | key mode r recs |
    key := ''. mode := 0.
    [r := DbServer default dbscan: ((self names: key) at: 'mode' put: mode; yourself).
     (r isError or: [r result <= 0]) ifTrue: [^self].
     recs := self records: r.
     recs do: [:kv | aBlock value: kv key value: kv value].
     recs isEmpty ifTrue: [^self].
     key := recs last key. mode := 1] repeat ]
Db >> records: r [
    "Answers the records of a DBSCAN reply r as key -> value Associations
     of Strings: as many as its result says, of those that came whole (the
     server fills up to 4032 bytes; a reply's data here is 1024 at most:
     keysAndValuesDo: asks again after the last key answered). Each record
     is {u16 key length, u16 value length, u32 0, the key, the value}, the
     key and the value each padded to 8 bytes."
    | out off limit |
    out := OrderedCollection new.
    off := 0.
    limit := r length min: r data size.
    r result timesRepeat: [ | kl vl k v |
        off + 8 > limit ifTrue: [^out].
        kl := r u16At: off. vl := r u16At: off + 2.
        off + 8 + (kl + 7 // 8 * 8) + (vl + 7 // 8 * 8) > limit ifTrue: [^out].
        k := r stringAt: off + 8 size: kl.
        v := r stringAt: off + 8 + (kl + 7 // 8 * 8) size: vl.
        out add: k -> v.
        off := off + 8 + (kl + 7 // 8 * 8) + (vl + 7 // 8 * 8)].
    ^out ]
Db >> printOn: aStream [
    "Writes 'Db' and the tree's name, NAMESPACE/TREE.
     (Db tree: 'a/b') printString >>> 'Db a/b'"
    aStream nextPutAll: 'Db '; nextPutAll: namespace; nextPut: $/; nextPutAll: tree ]
