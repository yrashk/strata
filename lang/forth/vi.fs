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
\ the site's colours and of C (.c, .h), with the same rules; a comment's
\ state over lines is kept as vi.s keeps it (every 16th line, and the last
\ top line). The keys are vi.s's. Given the
\ same keys, it writes the same files (tools/test-vifs.sh checks that).
\
\ How it fits. The program's code is several times the I-LS a program has
\ under StrataOS, and needs no arrangement for that: like every word compiled
\ after start-up it is in code units in far memory, which StrataOS pages into
\ the code cache as they are called (lang/forth/README.md, "Code paging").
\ The byte loops (finding lines, keywords, identifiers, strings) are code
\ words, assembled with core.fs's assembler. Data space is the limit: the
\ D-LS holds one chunk of text, the line being edited, the screen's state and
\ the words' names; the rest is in the far heap.
\
\ Where the text lives. In the far heap, as vi.s keeps it in its arena: the
\ text in chunks of 2 KiB (runs of whole lines, in the order of a chunk table
\ in the D-LS: store number, bytes, lines), the undo history (96 KiB), the
\ register (what y d c x took: 48 KiB), the keyword tables and the message
\ texts. The heap is smaller than vi.s's arena (Forth's code mirror, include
\ buffers and code units come out of the same 1 MiB), so the text can be
\ 400 KiB (vi.s: 500); a file that does not fit is cut short, and vi says so.
\ . repeats a change of up to 64 keys (vi.s: 256).
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
\ highlighter uses and from cc, like vi.s's; vi.fs reads them once, into far
\ memory.
\ Compiling the editor costs some 6 M instructions at every start.

inline-limit @  4 inline-limit !                \ dense code (more of it in the cache): primitives are called

\ The program is in two files (an included file's text must fit in 64 KiB with
\ the files it includes): vi-text.fs, then vi-edit.fs.
include /vi-text.fs
include /vi-edit.fs
inline-limit !

\ ---- started as `forth vi.fs [FILE]`: edit FILE, then leave ---------------------------------------
32 kvar cell+ @ [if] 32 kvar 2@ swap cmd-word 2drop cmd-word 2drop cmd-word vi-main 2drop bye [then]
