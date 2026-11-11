\ =============================================================================
\ overlay.fs: code overlays, for programs bigger than code space
\ =============================================================================
\
\   require overlay
\   N U overlays          \ room for N overlays (at most 31) of U code bytes each
\   overlay  : a ... ;  : b ... ;      \ overlay 1
\   overlay  : c ... ;                 \ overlay 2
\   resident : main ... a c ... ;      \ resident code again (RESIDENT ends the last one)
\
\ Code space is the I-LS: 64 KiB per core, of which a StrataOS program has
\ 32 KiB, and about 8 KiB are left after the kernel and core.fs. An overlay
\ is a part of a program compiled into one fixed region at the top of code
\ space; every overlay is compiled into the same region, and its code is
\ kept in far memory (the store). One overlay is in the region at a time:
\ calling a word of another one brings that one in first, the way the
\ hardware's code paging does (xcall, xmiss), but in software. Bringing
\ overlay n in is two moves of its bytes: store -> code mirror (through the
\ free part of the compiler's staging buffer: there is no far-to-far
\ transfer), then mirror -> I-LS with `tgetx`. The mirror is what StrataOS
\ reloads the I-LS from after a context switch, so the region holds the
\ right overlay after a switch too.
\
\ How calls work. Everything defined between OVERLAY and the next OVERLAY or
\ RESIDENT is in that overlay: RESIDENT (or the next OVERLAY) marks its words
\ for the kernel (flag F_OVL, the overlay's number in the header's fold byte)
\ and saves its code in the store. The kernel compiles a use of a marked word
\ as its overlay xt (n << 16 | address) and a call of OVJUMP (from resident
\ code: bring n in, run the word) or OVCALL (from another overlay: the same,
\ then bring the caller's overlay back, since that is where the call
\ returns). Within an overlay a call is a plain call. ' gives the overlay
\ xt, and EXECUTE, COMPILE, and the interpreter know it. CATCH, redefined
\ below, brings back the overlay it was called from also when the word it
\ ran throws.
\
\ Rules. A defining word with DOES> must be resident (the words it makes
\ jump to its does-code); data (VARIABLE, CREATE, VALUE) may be defined in an
\ overlay, their stubs are its code. An xt of overlay code that is not an
\ overlay xt (a quotation [: ;], a :NONAME, NAME>XT) runs only while its
\ overlay is in. One thread only (not with forth -n N). OVERLAYS takes the
\ store from the bottom of the far heap (the heap starts after it: call it
\ before using the heap); on bare metal the store is at c0 offset $30000.
\ Costs: a call into another overlay is about 40 instructions more than a
\ plain one, plus the moves when it is not in (ovl-loads counts them).

inline-limit @  4 inline-limit !                \ resident code space is scarce: primitives are called

37 kvar constant ovl                            \ the kernel's block: +0 the overlay being compiled,
                                                \ +8 OVCALL, +16 OVJUMP, +24 where code space ends now
variable ovcur                                  \ the overlay in the region (0: none)
variable #ovl                                   \ overlays made so far (the last one's number)
variable ovmax                                  \ how many the store has room for
variable ovsize                                 \ bytes of the region (0: no OVERLAYS yet)
variable ovbase                                 \ where the region starts in the I-LS
variable ovstore                                \ c0 offset of the store: overlay n at (n - 1) * ovsize
variable ovres                                  \ resident CHERE while an overlay is being made
variable ovlast                                 \ the newest word before it
variable ovl-loads                              \ overlays brought in (a count, for the curious)
create ovlens 32 cells allot                    \ each overlay's code bytes

14 kvar constant v-chere  17 kvar constant v-cbase  16 kvar constant stage \ the compiler's
\ The transfers are compiled in place (like core.fs's control structures): the
\ instructions tget/tput/tgetx tg0, a0, c0, a1, a2 with a0..a2 from the stack.
: ov-move ( src dst n buf -- )                  \ c0 -> buf -> c0 (the transfers of one tag are in order)
  [ %a0 %s1 0 addi,  %a2 %s0 0 ld,  %a1 %s0 16 ld,  0 0 xfer insn,  %a1 %s0 8 ld,  0 1 xfer insn,
    %s1 %s0 24 ld,  %s0 %s0 32 addi, ] ;
: ov-getx ( ils off len -- )                    \ c0 -> I-LS: code installed (tgetx)
  [ %a2 %s1 0 addi,  %a1 %s0 0 ld,  %a0 %s0 8 ld,  0 2 xfer insn,  %s1 %s0 16 ld,  %s0 %s0 24 addi, ] ;
: ov-buf ( -- a u )                             \ the staging buffer's free part (a definition may be in it)
  v-chere @ v-cbase @ - aligned  dup stage +  4096 rot - ;
: ov-copy ( src dst u -- )                      \ c0 -> c0, a staging buffer's free part at a time
  begin dup while
    ov-buf swap >r over min  3 pick 3 pick 2 pick r> ov-move
    >r rot r@ + rot r@ + rot r> -
  repeat drop 2drop ;
: ov-slot ( n -- off ) 1- ovsize @ * ovstore @ + ; \ where overlay n is kept
: ov-save ( -- )                                \ the overlay being made, as far as it is installed -> the store
  ovl @ dup 0= if drop exit then  ovbase @ over ov-slot
  v-cbase @ ovbase @ -  dup 4 pick cells ovlens + !  ov-copy drop ;
: ov-load ( n -- )                              \ overlay n in the region (0: nothing to do)
  dup ovcur @ = if drop exit then
  ovcur @ ovl @ = if ov-save then               \ the overlay being made goes to the store first
  dup ovcur !  ?dup 0= if exit then
  1 ovl-loads +!  dup cells ovlens + @ ?dup 0= if drop exit then  >r
  ov-slot ovbase @ r@ ov-copy                   \ store -> code mirror (far offset = I-LS address)
  ovbase @ dup r> ov-getx ;                     \ mirror -> I-LS
: ovjump ( i*x oxt -- j*x )                     \ from resident code: run an overlay word
  dup 16 rshift ov-load  $ffff and execute ;
: ovcall ( i*x oxt -- j*x )                     \ from an overlay: the same, then the caller's back
  ovcur @ >r  dup 16 rshift ov-load  $ffff and execute  r> ov-load ;
' ovcall ovl 8 + !  ' ovjump ovl 16 + !         \ the kernel compiles calls of overlay words to these
: catch ( i*x xt -- j*x 0 | i*x n )             \ CATCH that also brings back the caller's overlay
  ovcur @ >r catch r> ov-load ;

: overlays ( n u -- )                           \ room for n overlays of u code bytes, at the top
  ovsize @ cores 1 > or abort" overlays: again, or with threads"
  swap 31 min swap  aligned  $10000 over -  dup chere 64 + < abort" overlays: not that much code space"
  dup ovbase !  ovl 24 + !  dup ovsize !  over ovmax !
  * aligned  23 kvar @ if                       \ StrataOS: the store from the bottom of the heap,
    fflush finval  0 clen ovstore !             \ joined to c0 (the heap starts after it)
    heap-cap swap tmp-cap csplit  0 heap-cap cjoin  tmp-cap heap-cap cmov
  else drop $30000 ovstore ! then ;             \ bare metal: c0 has room there
: resident ( -- )                               \ the end of an overlay: its words marked, its code saved
  ovl @ ?dup 0= if exit then  install ov-save
  latest begin dup ovlast @ <> while            \ every word since OVERLAY: F_OVL, the number
    dup 8 + dup c@ $40 or swap c!  2dup 9 + c!  name>link
  repeat 2drop
  ovres @ dup v-chere ! v-cbase !  0 ovl !  ovbase @ ovl 24 + ! ;
: overlay ( -- )                                \ what is defined from now on is in a new overlay
  resident  #ovl @ ovmax @ < 0= abort" overlay: no room for another (OVERLAYS)"
  install  1 #ovl +!  #ovl @ dup ovl ! ovcur !  0 #ovl @ cells ovlens + !
  latest ovlast !  chere ovres !  ovbase @ dup v-chere ! v-cbase !  $10000 ovl 24 + ! ;
inline-limit !                                  \ inlining as it was
create overlay.fs                               \ REQUIRE looks for this name: the file is loaded
