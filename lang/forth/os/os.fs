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
\ A name that is no file may be one of the Forth ports of os/progs (seq.fs,
\ cat.fs, ...) or their sys.fs: they are kept together in one disk file,
\ progs.pk, since the disk's directory has room for 128 files. INCLUDED runs
\ the word in KVAR 39 (once: it clears it) for such a name: this one includes
\ /progs.pk with the name (in sbuf) on the stack. Its text (lang/forth/
\ progs.fs) finds the name in its index, interprets that part of itself and
\ puts (pack) back in KVAR 39.
: (pack) ( a u -- ) >sbuf s" /progs.pk" included ; \ a port of os/progs, or "no such file"
' (pack) 39 kvar !
: require ( i*x "name" -- j*x )                 \ include NAME.fs for good, once
  parse-name here swap 2dup 2>r move  s" .fs" 2r@ + swap move  2r> 3 + \ the file's name, at HERE
  2dup find-name if 2drop exit then  included ; \ a file ends by defining a word with its name

\ core.fs and this file were compiled with INLINE-LIMIT at 4 (the platform's
\ start-up value): only one-instruction primitives were copied, the rest are
\ called, which saves about 2.5 KiB of the 32 KiB of code space. What is
\ compiled from now on gets the usual inlining (net.fs and httpd.fs lower it).
16 inline-limit !

\ ---- greeting (the console only; not for `forth FILE` or `forth -e ...`) --------------
\ Defined, run and forgotten: (mark) remembers the dictionary, (release)
\ forgets everything defined since (this is how the tools come and go).
$10000 chere - unused (mark)                    \ what is free, measured before the banner's own code
: .banner ( code data -- )
  ." Strata Forth 0.1 (native code, " cores . cores 1 = if ." thread" else ." threads" then
  ." , StrataOS 0.1) " swap . ." code bytes free, " . ." data bytes free" cr ;
32 kvar cell+ @ 0= [if] .banner [else] 2drop [then]
(release)
