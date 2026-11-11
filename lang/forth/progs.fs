\ =============================================================================
\ progs.fs: the head of progs.pk, the pack of the Forth ports of os/progs (StrataOS)
\ =============================================================================
\
\ The ports (lang/forth/progs/NAME.fs) and their library sys.fs are not files
\ on the disk: its directory has room for 128 files, and nearly all are
\ taken. tools/forth-pack.py makes one file of them, progs.pk: this text, with
\ an index put in where it says (a line "OFFSET LENGTH port NAME" per file)
\ and the pack's size in front of PK-DONE, then the files. INCLUDED, given a name that is
\ no file, runs the word in KVAR 39 instead (once: it clears it): os.fs's
\ (pack), which includes /progs.pk with the name in sbuf and on the stack.
\ So `forth seq.fs 20`, `include seq.fs`, `require sys` and an INCLUDE in a
\ port all find them.
\
\ INCLUDED has read the whole pack into far memory and interprets this text:
\ the index lines note where the port and sys.fs are, the loader's words are
\ forgotten ((MARK), (RELEASE)), sys.fs is interpreted where it lies
\ (EVALUATE-FAR) unless it is loaded already, then the port, under its own
\ name (the name slot KVAR 29 points at: errors say "seq.fs:12:"); and then
\ the pack's text ends (SOURCE-ID's neighbours, KVAR 7 + 8 and + 16, are where
\ the far text's next line is and where it ends). A name that is no port is
\ "no such file", as before, and leaves nothing behind.

' (pack) 39 kvar !                              \ for the next name that is no file
(mark)
2variable pk-want  pk-want 2!                   \ the name asked for (in sbuf)
2variable pk-port  2variable pk-sys  0 0 pk-port 2!  0 0 pk-sys 2! \ where they are: offset, length
: pk-base ( a u -- a' u' )                      \ a path's last component
  dup >r begin dup while 2dup + 1- c@ '/' <> while 1- repeat then r> swap /string ;
: port ( off len "name" -- )                    \ a line of the index: the port wanted? sys.fs?
  parse-name 2dup pk-want 2@ pk-base str= if 2drop pk-port 2! exit then
  s" sys.fs" str= if pk-sys 2! else 2drop then ;
\ {{INDEX}}
: pk-done ( size -- foff u sfoff su )           \ the port's text and sys.fs's in far memory
  aligned 40 kvar @ swap -                      \ (the pack starts where INCLUDED put it: the next file
  pk-port 2@ dup 0= if                          \ goes after it)
    2drop drop  pk-want 2@ swap 33 kvar 2!  0 7 kvar !  (release) -309 throw then \ "NAME: no such file"
  >r over + r>  rot pk-sys 2@ >r + r>
  pk-want 2@ pk-base 31 min 29 kvar @ 2dup + 0 swap c! swap move ; \ errors name the port
{{SIZE}} pk-done (release) [defined] sys.fs [if] 2drop [else] evaluate-far [then]
evaluate-far  7 kvar 16 + @ 7 kvar 8 + !        \ the port; then the pack's text ends here
