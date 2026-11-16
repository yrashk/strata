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
Object subclass: #OSReply slots: 'result handle length mode data spec'.
OSServer subclass: #Server slots: ''.
Object subclass: #Proc slots: ''.
Object subclass: #Fs slots: ''.
Object subclass: #Dev slots: ''.
Object subclass: #Tty slots: ''.
Object subclass: #Blk slots: ''.
Object subclass: #Db slots: 'namespace tree'.
Object subclass: #ProcessInfo slots: 'pid state core parent flags threads switches kib name'.

SystemDictionary >> osSend: reg op: op handle: h length: n mode: m server: index data: bytes reply: reply [
    "The message primitive: n nil means the data's size."
    <primitive: 116> ^-1 ]
SystemDictionary >> osReply [ "{handle. length. mode} of the last reply" <primitive: 119> ]
SystemDictionary >> osLookup: aName into: reg [ <primitive: 117> ^-4 ]

"---- reaching a server, and the generic request ----------------------------"

OSServer class >> register: n lookup: aName index: i [ ^self new setRegister: n lookup: aName index: i ]
OSServer >> setRegister: n lookup: aName index: i [ register := n. lookup := aName. index := i ]
OSServer >> register [ ^register ]
OSServer >> index [ ^index ]
OSServer >> connect [
    "A server reached by name: looked up into its register (each time: the
     register is lent, fs's)."
    | r |
    lookup == nil ifTrue: [^self].
    r := Smalltalk osLookup: lookup into: register.
    r < 0 ifTrue: [^Error new signal: 'no server named ', lookup] ]
OSServer >> disconnect [ (lookup notNil and: [register = 2]) ifTrue: [Server restoreFs] ]
OSServer >> send: op handle: h length: n mode: m data: bytes [
    "One message; an OSReply (its data undecoded)."
    | reply r words |
    reply := ByteArray new: 1024.
    self connect.
    r := Smalltalk osSend: register op: op handle: h length: n mode: m server: index data: bytes reply: reply.
    words := Smalltalk osReply.
    self disconnect.
    ^OSReply new setResult: r handle: (words at: 1) length: (words at: 2) mode: (words at: 3) data: reply ]
OSServer >> op: num named: aString args: args request: reqSpec reply: repSpec [
    | data n r |
    data := self pack: reqSpec from: args.
    data isEmpty ifTrue: [data := nil].
    n := args at: 'length' ifAbsent: [nil].
    r := self send: num handle: (args at: 'handle' ifAbsent: [0]) length: n
        mode: (args at: 'mode' ifAbsent: [0]) data: data.
    ^r spec: repSpec name: aString ]
OSServer >> pack: spec from: args [
    | out |
    out := WriteStream on: (ByteArray new: 64).
    self pack: spec from: args into: out.
    ^out contents ]
OSServer >> pack: spec from: args into: out [
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
    aStream nextPutAll: self class name; nextPutAll: ' (c'; print: register.
    index = 0 ifFalse: [aStream nextPutAll: ', server '; print: index].
    aStream nextPut: $) ]
String >> asByteArray [ | b | b := ByteArray new: self size. 1 to: self size do: [:i | b at: i put: (self at: i) value \\ 256]. ^b ]
ByteArray >> asByteArray [ ^self ]

OSReply >> setResult: r handle: h length: n mode: m data: bytes [ result := r. handle := h. length := n. mode := m. data := bytes ]
OSReply >> spec: aSpec name: aString [ spec := aSpec ]
OSReply >> result [ ^result ]
OSReply >> handle [ ^handle ]
OSReply >> length [ ^length ]
OSReply >> mode [ ^mode ]
OSReply >> data [ ^data ]
OSReply >> isError [ ^result < 0 ]
OSReply >> dataSize [ ^(length > 0 and: [length <= data size]) ifTrue: [length] ifFalse: [data size] ]
OSReply >> u8At: i [ ^data at: i + 1 ]
OSReply >> u16At: i [ ^(self u8At: i) + ((self u8At: i + 1) bitShift: 8) ]
OSReply >> u32At: i [ ^(self u16At: i) + ((self u16At: i + 2) bitShift: 16) ]
OSReply >> u64At: i [ ^(self u32At: i) + ((self u32At: i + 4) bitShift: 32) ]
OSReply >> s64At: i [ | v | v := self u64At: i. ^v >= (1 bitShift: 63) ifTrue: [v - (1 bitShift: 64)] ifFalse: [v] ]
OSReply >> stringAt: i size: n [
    "Bytes i .. i + n - 1 as a String, up to the first zero byte."
    | s k |
    s := WriteStream on: (String new: n).
    k := 0.
    [k < n and: [i + k < data size and: [(self u8At: i + k) ~= 0]]] whileTrue: [
        s nextPut: (Character value: (self u8At: i + k)). k := k + 1].
    ^s contents ]
OSReply >> fields [
    "The data decoded by the op's spec: a Dictionary of the fields' names;
     'records' holds the records of a repeated group, each a Dictionary."
    | d |
    d := Dictionary new.
    d at: 'result' put: result.
    spec == nil ifTrue: [^d].
    result < 0 ifTrue: [^d].
    self decode: spec at: 0 to: self dataSize into: d.
    ^d ]
OSReply >> decode: aSpec at: start to: end into: d [
    "-> the offset after what was decoded."
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
OSReply >> printOn: aStream [ aStream nextPutAll: 'an OSReply '; print: result ]

"---- Server: the endpoints by name (OSServer's simplest use) ------------------"

Server class >> proc [ ^self register: 1 lookup: nil index: 0 ]
Server class >> fs [ ^self register: 2 lookup: nil index: 0 ]
Server class >> tty [ ^self register: 3 lookup: nil index: 0 ]
Server class >> pipe [ ^self register: 4 lookup: nil index: 0 ]
Server class >> db [ ^self register: 4 lookup: nil index: 1 ]
Server class >> named: aString [ ^self register: 2 lookup: aString index: 0 ]
Server class >> named: aString into: n [
    "A server's endpoint kept in register n (1..4) until given back."
    | r |
    r := Smalltalk osLookup: aString into: n.
    r < 0 ifTrue: [^Error new signal: 'no server named ', aString].
    ^self register: n lookup: nil index: 0 ]
Server class >> restoreFs [ ^Smalltalk osLookup: 'fs' into: 2 ]
Server class >> restorePipe [ ^Smalltalk osLookup: 'pipe' into: 4 ]
Server >> request: op [ ^self request: op handle: 0 mode: 0 data: nil replySize: 0 ]
Server >> request: op handle: h [ ^self request: op handle: h mode: 0 data: nil replySize: 0 ]
Server >> request: op replySize: n [ ^self request: op handle: 0 mode: 0 data: nil replySize: n ]
Server >> request: op handle: h mode: m data: bytes replySize: n [
    ^self send: op handle: h length: nil mode: m data: bytes ]

"---- the friendlier faces of a few servers ------------------------------------"

Proc class >> info [ "INFO: a Dictionary of the system's summary" ^ProcServer default info fields ]
Proc class >> ps [
    "PS: a ProcessInfo per process."
    ^(ProcServer default ps fields at: 'records') collect: [:r | ProcessInfo fromFields: r] ]
Proc class >> cores [ "CORES: a Dictionary per core" ^ProcServer default cores fields at: 'records' ]

ProcessInfo class >> fromFields: d [
    ^self new setPid: (d at: 'pid') state: (d at: 'state') core: (d at: 'core') parent: (d at: 'parent')
        flags: (d at: 'flags') threads: (d at: 'threads') switches: (d at: 'switches')
        kib: (d at: 'KiB moved') name: (ProcessInfo nameOf: (d at: 'name')) ]
ProcessInfo class >> nameOf: n [
    "The u64 name field: 8 bytes, zero-padded."
    | s x |
    s := WriteStream on: (String new: 8).
    x := n.
    [x > 0] whileTrue: [s nextPut: (Character value: (x bitAnd: 255)). x := x bitShift: -8].
    ^s contents ]
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

Fs class >> statfs [ "{total blocks. used blocks. files}" | f | f := FsServer default statfs fields.
    ^Array with: (f at: 'total blocks') with: (f at: 'used blocks') with: (f at: 'files') ]
Fs class >> sizeOf: aPath [ ^File primSize: aPath ]
Fs class >> tags [
    "Every tag's name -> the files carrying it (TAGS2, part by part)."
    | out cursor r |
    out := OrderedCollection new.
    cursor := 0.
    [r := FsServer default tags2: (Dictionary new at: 'handle' put: cursor; yourself).
     r isError ifFalse: [(r fields at: 'records' ifAbsent: [#()]) do: [:t | out add: (t at: 'the name') -> (t at: 'files carrying it')]].
     r isError not and: [r result > 0 and: [(cursor := r handle) ~= 0]]] whileTrue.
    ^out ]

Dev class >> devices [ "DEVS: a Dictionary per entry of the platform table" ^DevServer default devs fields at: 'records' ]
Dev class >> time [ "TIME: {EPOCH. ZONE}" | f | f := DevServer default time fields. ^Array with: (f at: 'EPOCH') with: (f at: 'ZONE') ]

Tty class >> raw [ "The console: keys as they come, no echo" ^TtyServer default conmode: (Dictionary new at: 'handle' put: 1; yourself) ]
Tty class >> cooked [ "The console: lines, echoed" ^TtyServer default conmode: (Dictionary new at: 'handle' put: 0; yourself) ]
Tty class >> foreground: aPid [ ^TtyServer default setfg: (Dictionary new at: 'handle' put: aPid; yourself) ]

Blk class >> block: n [
    "Block n of the disk (512 bytes), through fs (READBLK)."
    | r |
    r := FsServer default readblk: (Dictionary new at: 'handle' put: n; yourself).
    r isError ifTrue: [^Error new signal: 'cannot read block ', n printString].
    ^r data copyFrom: 1 to: 512 ]

"Db: a tree of the store for programs: keys and values (Strings), in key order."
Db class >> tree: aString [
    "aString: 'NAMESPACE/TREE'"
    | i |
    i := aString indexOf: $/.
    i = 0 ifTrue: [^Error new signal: 'a tree is named NAMESPACE/TREE'].
    ^self new setNamespace: (aString copyFrom: 1 to: i - 1) tree: (aString copyFrom: i + 1 to: aString size) ]
Db >> setNamespace: n tree: t [ namespace := n. tree := t ]
Db >> names: key [
    | d |
    d := Dictionary new.
    d at: 'namespace name length' put: namespace size; at: 'tree name length' put: tree size; at: 'key length' put: key size.
    d at: 'the namespace''s name' put: namespace; at: 'the tree''s name' put: tree; at: 'the key' put: key.
    ^d ]
Db >> at: key [ ^self at: key ifAbsent: [KeyNotFound new signal: 'no key ', key printString] ]
Db >> at: key ifAbsent: aBlock [
    | r |
    r := DbServer default dbget: (self names: key).
    r isError ifTrue: [^aBlock value].
    ^(r data copyFrom: 1 to: r result) asStringBytes ]
Db >> batch: kind key: key value: value [
    "DBBATCH through fs: one item, one commit."
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
Db >> at: key put: value [ ^self batch: 1 key: key value: value ]
Db >> removeKey: key [ ^self batch: 2 key: key value: '' ]
Db >> keysAndValuesDo: aBlock [
    "In key order, part by part (DBSCAN)."
    | key mode r recs |
    key := ''. mode := 0.
    [r := DbServer default dbscan: ((self names: key) at: 'mode' put: mode; yourself).
     (r isError or: [r result <= 0]) ifTrue: [^self].
     recs := self records: r.
     recs do: [:kv | aBlock value: kv key value: kv value].
     recs isEmpty ifTrue: [^self].
     key := recs last key. mode := 1] repeat ]
Db >> records: r [
    "{u16 key length, u16 value length, u32 0, key, value} each padded to 8"
    | out off |
    out := OrderedCollection new.
    off := 0.
    r result timesRepeat: [ | kl vl k v |
        kl := r u16At: off. vl := r u16At: off + 2.
        k := r stringAt: off + 8 size: kl.
        v := r stringAt: off + 8 + (kl + 7 // 8 * 8) size: vl.
        out add: k -> v.
        off := off + 8 + (kl + 7 // 8 * 8) + (vl + 7 // 8 * 8)].
    ^out ]
Db >> printOn: aStream [ aStream nextPutAll: 'Db '; nextPutAll: namespace; nextPut: $/; nextPutAll: tree ]
