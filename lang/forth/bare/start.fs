\ =============================================================================
\ bare/start.fs: the last lines of the embedded source on bare metal
\ =============================================================================
\ Embedded after core.fs, tools.fs and see.fs (the Makefile concatenates
\ them): the greeting.
: .banner ( -- )
  ." Strata Forth 0.1 (native code, " cores . ." cores, bare metal) "
  $10000 chere - . ." code bytes free, " unused . ." data bytes free" cr ;
.banner
