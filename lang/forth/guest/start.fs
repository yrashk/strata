\ =============================================================================
\ guest/start.fs: the last lines of the embedded source of the guest image
\ =============================================================================
\ Embedded after core.fs, tools.fs and see.fs (the Makefile concatenates
\ them): the greeting. A guest has no framebuffer, no files and no network:
\ gfx.fs and the words on files or servers are not for it.
: .banner ( -- )
  ." Strata Forth 0.1 (native code, " cores . ." cores, a StrataOS guest, "
  far-size 20 rshift . ." MiB far heap) "
  $10000 chere - . ." code bytes free, " unused . ." data bytes free" cr ;
.banner
