\ =============================================================================
\ vi.fs: a text editor in the manner of vi, in Strata Forth (StrataOS)
\ =============================================================================
\
\   forth vi.fs [FILE]        edit FILE (a path, or a name under the current
\                             tag path; one that does not exist is made by :w);
\                             in another tag path: forth /vi.fs FILE
\   include vi.fs             at the Forth prompt; then  vi FILE  (or  vi),
\                             as often as wanted
\
\ The Forth port of os/progs/vi.s (doc/strataos.md 2.12 describes them both):
\ the same modes, motions, operators with counts, undo and redo, ., search,
\ : commands, status line, screen-size question (ESC [ 6 n, 80 x 24 without
\ an answer, Ctrl-L), and highlighting of Strata assembly and Strata Forth in
\ the site's colours, with the same rules. The keys are vi.s's. Given the
\ same keys, it writes the same files (tools/test-vifs.sh checks that).
\
\ How it fits. The program is about four times the code space a Forth
\ program has left under StrataOS (some 8 KiB of the 32), so most of it is in
\ code overlays (overlay.fs): finding a line of the text and the terminal
\ output are resident (2 KiB); the rest is nineteen overlays, brought in one
\ at a time into a region of 4.1 KiB at the top of code space when a word of
\ theirs is called (a call into another overlay costs some 400 instructions,
\ there and back). The byte loops (finding lines, keywords, identifiers,
\ strings) are code words, assembled with core.fs's assembler. Data space is
\ the other limit: the D-LS holds one chunk of text, the line being edited,
\ the screen's state and the words' names; the rest is in the far heap.
\
\ Where the text lives. In the far heap, as vi.s keeps it in its arena: the
\ text in chunks of 2 KiB (runs of whole lines, in the order of a chunk table
\ in the D-LS: store number, bytes, lines), the undo history (96 KiB), the
\ register (what y d c x took: 48 KiB), the keyword tables and the message
\ texts. The heap is smaller than vi.s's arena (Forth's code mirror, include
\ buffers and the overlay store come out of the same 1 MiB), so the text can
\ be 368 KiB (vi.s: 500); a file that does not fit is cut short, and vi says
\ so. . repeats a change of up to 64 keys (vi.s: 256).
\
\ Keys. vi.fs talks to the tty itself through (msg) and the standard handles
\ (KVAR 38): raw mode (CONMODE), READs that wait or not. An Esc is told from
\ an escape sequence by time (a "[" within 30 ms; the tty reads one byte
\ ahead for a reader that polls in raw mode). It catches interrupts (proc
\ CATCH), so Ctrl-C comes as a READ that returns -2: the key Ctrl-C. (One that
\ comes during the 30 ms is not seen: MS does not say it was cut short.)
\
\ The keyword tables are generated at build time (tools/vi-syntax.py ->
\ vi-syntax.fs, a disk file next to this one) from the sources the site's
\ highlighter uses, like vi.s's; vi.fs reads them once, into far memory.
\ Compiling the editor costs some 6 M instructions at every start.

[defined] overlay.fs 0= [if] include /overlay.fs [then] \ (by /NAME: whatever the current tag path)
inline-limit @  4 inline-limit !                \ code space: primitives are called, not copied
19 4160 overlays                               \ nineteen overlays of up to 4.1 KiB of code

\ The program is in two files (an included file's text must fit in 64 KiB with
\ the files it includes): vi-text.fs, then vi-edit.fs.
include /vi-text.fs
include /vi-edit.fs
inline-limit !

\ ---- started as `forth vi.fs [FILE]`: edit FILE, then leave ---------------------------------------
32 kvar cell+ @ [if] 32 kvar 2@ swap cmd-word 2drop cmd-word 2drop cmd-word vi-main 2drop bye [then]
