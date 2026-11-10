\ =============================================================================
\ os/os.fs: the StrataOS part of Strata Forth that is written in Forth
\ =============================================================================
\
\ Embedded in the image after core.fs (the Makefile concatenates them) and
\ compiled at start-up. Most of the StrataOS support is in the kernel and in
\ os/platform.s, to save code space:
\
\   included ( addr u -- )   interpret a file (read into the arena through the
\                            file server, then interpreted like core.fs)
\   see words dump .cap .caps .jit .fcache disasm dis
\                            are not in the dictionary: when the interpreter
\                            meets one, it includes tools.fs or see.fs, runs
\                            the word and forgets the file again. The tools
\                            take none of the 32 KiB of code space a StrataOS
\                            program has while they are not running.
\
\ This file adds the parsing words:

: include ( i*x "name" -- j*x ) parse-name included ; \ interpret a file
: require ( i*x "name" -- j*x )                 \ include NAME.fs for good, once
  parse-name here swap 2dup 2>r move  s" .fs" 2r@ + swap move  2r> 3 + \ the file's name, at HERE
  2dup find-name if 2drop exit then  included ; \ a file ends by defining a word with its name

\ ---- greeting (the console only; not for `forth FILE` or `forth -e ...`) --------------
\ Defined, run and forgotten: (mark) remembers the dictionary, (release)
\ forgets everything defined since (this is how the tools come and go).
$10000 chere - unused (mark)                    \ what is free, measured before the banner's own code
: .banner ( code data -- )
  ." Strata Forth 0.1 (native code, " cores . cores 1 = if ." thread" else ." threads" then
  ." , StrataOS 0.1) " swap . ." code bytes free, " . ." data bytes free" cr ;
32 kvar cell+ @ 0= [if] .banner [else] 2drop [then]
(release)
