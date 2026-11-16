"File.st: files in the file system (fs), read and written whole or in
 parts; filing a source file in."

Object subclass: #File slots: 'name'.

File class >> named: aString [ ^self new setName: aString ]
File class >> fs [ ^Server fs ]
File class >> primOpen: aName mode: n [
    "fs OPEN: 0 read, 1 write, 2 append -> an id, or < 0"
    ^(self fs send: 3 handle: 0 length: nil mode: n data: aName) result ]
File class >> primRead: h into: aString count: n [
    "fs READ: at most n bytes (and 1024) into aString -> how many, 0 at the end"
    | r k |
    r := self fs send: 1 handle: h length: (n min: 1024) mode: 0 data: nil.
    k := r result.
    1 to: (k min: aString size) do: [:i | aString at: i put: (Character value: (r data at: i))].
    ^k ]
File class >> primWrite: h from: aString count: n [
    "fs WRITE"
    ^(self fs send: 2 handle: h length: nil mode: 0 data: (aString copyFrom: 1 to: n)) result ]
File class >> primClose: h [ ^(self fs send: 4 handle: h length: 0 mode: 0 data: nil) result ]
File class >> primSize: aName [ "fs STAT: the size, or < 0" ^(self fs send: 27 handle: 0 length: nil mode: 0 data: aName) result ]
File class >> primDelete: aName [ "fs UNLINK" ^(self fs send: 11 handle: 0 length: nil mode: 0 data: aName) result ]
File class >> exists: aName [ ^(self primSize: aName) >= 0 ]
File class >> contentsOf: aName [ ^(self named: aName) contents ]
File class >> write: aString to: aName [ ^(self named: aName) write: aString ]
File >> setName: aString [ name := aString ]
File >> name [ ^name ]
File >> exists [ ^File exists: name ]
File >> size [ ^File primSize: name ]
File >> delete [ ^File primDelete: name ]
File >> open: mode [
    | h |
    h := File primOpen: name mode: mode.
    h < 0 ifTrue: [^FileError new signal: 'cannot open ', name].
    ^h ]
File >> contents [
    "All of it, as a String."
    | h out buf n |
    h := self open: 0.
    out := WriteStream on: (String new: 1024).
    buf := String new: 1024.
    [[(n := File primRead: h into: buf count: 1024) > 0] whileTrue: [
        out nextPutAll: (n = 1024 ifTrue: [buf] ifFalse: [buf copyFrom: 1 to: n])]]
        ensure: [File primClose: h].
    ^out contents ]
File >> lines [ ^self contents lines ]
File >> write: aString [ ^self write: aString mode: 1 ]
File >> append: aString [ ^self write: aString mode: 2 ]
File >> write: aString mode: m [
    | h i n |
    h := self open: m.
    i := 1.
    [[i <= aString size] whileTrue: [
        n := (aString size - i + 1) min: 1000.
        File primWrite: h from: (aString copyFrom: i to: i + n - 1) count: n.
        i := i + n]] ensure: [File primClose: h].
    ^aString ]
File >> fileIn [ ^Compiler new fileIn: self contents ]
File >> printOn: aStream [ aStream nextPutAll: 'File '; print: name ]
Smalltalk at: #FileStream put: File.

Compiler >> fileIn: aString [
    "The items of a source file, in order: class definitions and statements
     are run, methods are compiled into their classes."
    | result |
    result := nil.
    (StParser on: aString) items do: [:it |
        (it at: 1) = #method ifTrue: [
            | cls m |
            cls := Smalltalk at: (it at: 2) asSymbol ifAbsent: [nil].
            (cls notNil and: [cls isClass]) ifFalse: [^CompileError new signal: 'no class ', (it at: 2)].
            (it at: 3) ifTrue: [cls := cls class].
            m := Compiler new compileMethod: (it at: 4) in: cls.
            cls addSelector: (it at: 4) selector asSymbol withMethod: m.
            MethodSource note: (it at: 5) class: cls selector: m selector].
        (it at: 1) = #expr ifTrue: [
            | node |
            node := StMethod selector: 'DoIt' arguments: #() temps: #() primitive: 0
                statements: (Array with: (StReturn expr: (it at: 2))) line: (it at: 3).
            result := nil executeMethod: (Compiler new compileMethod: node in: UndefinedObject)]].
    ^result ]
Compiler class >> fileIn: aString [ ^self new fileIn: aString ]
