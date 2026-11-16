"File.st: files in the file system (fs), read and written whole or in
 parts; filing a source file in."

Object subclass: #File slots: 'name'.
"A file of the file system by its name: the fs server (Server fs,
 capability register 2) is asked for each operation, and nothing is kept
 open between them. contents reads a whole file into a String, write:
 and append: write one; exists, size and delete ask about it by name;
 fileIn compiles a source file. The class side has the requests to fs
 (OPEN, READ, WRITE, CLOSE, STAT, UNLINK). name is the file's name, a
 String. FileStream is another name of this class.
 (File named: 'a.txt') printString >>> 'File ''a.txt'''"

File class >> named: aString [
    "Answers the File of the name aString; the file need not exist.
     (File named: 'a.txt') name >>> 'a.txt'"
    ^self new setName: aString ]
File class >> fs [
    "The file system server, Server fs."
    ^Server fs ]
File class >> primOpen: aName mode: n [
    "Opens the file aName with an fs OPEN: n is 0 to read, 1 to write (made
     empty), 2 to append. Answers the handle, or a number < 0 if it fails."
    ^(self fs send: 3 handle: 0 length: nil mode: n data: aName) result ]
File class >> primRead: h into: aString count: n [
    "Reads at most n bytes (and at most 1024) of the open handle h with an fs
     READ, into aString from its start. Answers how many were read, 0 at the
     end of the file (< 0 on an error)."
    | r k |
    r := self fs send: 1 handle: h length: (n min: 1024) mode: 0 data: nil.
    k := r result.
    1 to: (k min: aString size) do: [:i | aString at: i put: (Character value: (r data at: i))].
    ^k ]
File class >> primWrite: h from: aString count: n [
    "Writes the first n characters of aString on the open handle h with an
     fs WRITE. Answers fs's result: how many were written, or < 0."
    ^(self fs send: 2 handle: h length: nil mode: 0 data: (aString copyFrom: 1 to: n)) result ]
File class >> primClose: h [
    "Closes the handle h with an fs CLOSE; answers fs's result."
    ^(self fs send: 4 handle: h length: 0 mode: 0 data: nil) result ]
File class >> primSize: aName [
    "Answers the size in bytes of the file aName, asked with an fs STAT, or
     a number < 0 if there is no such file."
    ^(self fs send: 27 handle: 0 length: nil mode: 0 data: aName) result ]
File class >> primDelete: aName [
    "Removes the file aName with an fs UNLINK; answers fs's result, < 0 if
     it failed."
    ^(self fs send: 11 handle: 0 length: nil mode: 0 data: aName) result ]
File class >> exists: aName [
    "Answers whether there is a file aName (an fs STAT of it succeeds)."
    ^(self primSize: aName) >= 0 ]
File class >> contentsOf: aName [
    "Answers all of the file aName as a String; signals a FileError if it
     cannot be opened."
    ^(self named: aName) contents ]
File class >> write: aString to: aName [
    "Writes aString as the whole of the file aName, created or emptied
     first; answers aString. Signals a FileError if it cannot be opened."
    ^(self named: aName) write: aString ]
File >> setName: aString [
    "Sets the file's name to aString."
    name := aString ]
File >> name [
    "The file's name, as it was given.
     (File named: 'a.txt') name >>> 'a.txt'"
    ^name ]
File >> exists [
    "Answers whether the file exists (an fs STAT of it succeeds)."
    ^File exists: name ]
File >> size [
    "Answers the file's size in bytes (fs STAT), or a number < 0 if it does
     not exist."
    ^File primSize: name ]
File >> delete [
    "Removes the file (fs UNLINK); answers fs's result, < 0 if it failed."
    ^File primDelete: name ]
File >> open: mode [
    "Opens the file with an fs OPEN in mode (0 read, 1 write, 2 append) and
     answers the handle. Signals a FileError if fs refuses."
    | h |
    h := File primOpen: name mode: mode.
    h < 0 ifTrue: [^FileError new signal: 'cannot open ', name].
    ^h ]
File >> contents [
    "Answers all of the file as a String, read 1024 bytes at a time (fs
     READ) and closed after, even on an error. Signals a FileError if it
     cannot be opened."
    | h out buf n |
    h := self open: 0.
    out := WriteStream on: (String new: 1024).
    buf := String new: 1024.
    [[(n := File primRead: h into: buf count: 1024) > 0] whileTrue: [
        out nextPutAll: (n = 1024 ifTrue: [buf] ifFalse: [buf copyFrom: 1 to: n])]]
        ensure: [File primClose: h].
    ^out contents ]
File >> lines [
    "Answers the file's lines, as String lines splits its contents."
    ^self contents lines ]
File >> write: aString [
    "Writes aString as the whole of the file, which is created or emptied
     first; answers aString. Signals a FileError if it cannot be opened."
    ^self write: aString mode: 1 ]
File >> append: aString [
    "Writes aString at the end of the file; answers aString. Signals a
     FileError if it cannot be opened."
    ^self write: aString mode: 2 ]
File >> write: aString mode: m [
    "Opens the file in mode m (1 write, 2 append), writes aString in parts
     of at most 1000 characters (fs WRITE) and closes it, even on an error;
     answers aString. Signals a FileError if the file cannot be opened or a
     WRITE fails or writes less than it was given."
    | h i n |
    h := self open: m.
    i := 1.
    [[i <= aString size] whileTrue: [
        n := (aString size - i + 1) min: 1000.
        (File primWrite: h from: (aString copyFrom: i to: i + n - 1) count: n) = n
            ifFalse: [^FileError new signal: 'cannot write ' , self name].
        i := i + n]] ensure: [File primClose: h].
    ^aString ]
File >> fileIn [
    "Reads the file and files it in as Smalltalk source (Compiler fileIn:):
     classes are defined, methods compiled, statements run. Answers the value
     of the last statement."
    ^Compiler new fileIn: self contents ]
File >> printOn: aStream [
    "Writes File and the name, as a literal string.
     (File named: 'a.txt') printString >>> 'File ''a.txt'''"
    aStream nextPutAll: 'File '; print: name ]
Smalltalk at: #FileStream put: File.

Compiler >> fileIn: aString [
    "Runs the items of a source file, in order: class definitions and
     statements are run, methods are compiled into their classes (and their
     source noted for the class browser). Answers the value of the last
     statement, nil if there is none. Signals a CompileError for a method of
     a class that does not exist.
     Compiler new fileIn: '1. 2 * 5' >>> 10"
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
Compiler class >> fileIn: aString [
    "Files in the source aString with a new Compiler: see Compiler >> fileIn:.
     Compiler fileIn: '3 + 4' >>> 7"
    ^self new fileIn: aString ]
