\ =============================================================================
\ tools.fs: words, dump, .cap, .caps, .jit, .fcache
\ =============================================================================
\
\ Part of Strata Forth (see core.fs). On bare metal this file is embedded in
\ the image after core.fs. Under StrataOS it is a disk file: each of these
\ words is a stub (os/os.fs) that loads this file, runs the word and forgets
\ the file again, so the tools cost no code space when they are not running;
\ `require tools` loads them for good.

variable #words                                 \ for WORDS
: words ( -- )                                  \ every word, newest first
  0 #words !  latest begin ?dup while
    dup name>string 26 kvar @ over + 72 > if cr then type space
    1 #words +!  name>link
  repeat cr #words @ . ." words" cr ;
: dump ( addr u -- )                            \ hex dump of D-LS
  base @ >r hex  bounds ?do
    cr i 4 u.r ." :"  i 16 + i ?do space i c@ 2 u.r loop
  16 +loop cr  r> base ! ;

\ ---- capabilities, the far cache, the JIT ---------------------------------------------------
: .perms ( p -- )                                \ rwxadv
  s" rwxadv" 0 do over 1 i lshift and if dup i + c@ else [char] - then emit loop 2drop ;
: .space ( s -- ) 5 * s" ?    ?    T2   T3   dev  core ep   " drop + 5 type ;
: .cap ( c# -- )                                 \ one capability register
  dup ." c" 0 .r ." : " dup cvalid 0= if drop ." (empty)" cr exit then
  dup cperms dup 8 rshift 7 and .space .perms
  ."  base " dup cbase h. ." len " clen h. cr ;
: .caps ( -- ) 16 0 do i cvalid if i .cap then loop ; \ every capability register in use
: .fcache ( -- )                                 \ far cache statistics
  5 kvar dup @ . ." hits, " cell+ dup @ . ." misses, " cell+ @ . ." write-backs" cr ;
: code-end ( -- a )                              \ where code ends, this file aside if it is
  34 kvar @ if 35 kvar cell+ @ else chere then ; \ loaded for one command only (StrataOS)
: .jit ( -- )                                    \ code space and installs
  ." kernel " 22 kvar h. ." .. code " code-end h. ." .. limit $10000: "
  $10000 code-end - . ." bytes free" cr
  4 kvar dup @ . ." installs, " cell+ @ . ." bytes installed (tput + tgetx), "
  6 kvar @ . ." xexec trampolines" cr ;
create tools.fs                                 \ REQUIRE looks for this name: the file is loaded
