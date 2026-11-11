\ hexdump.fs: show a raw disk block (the Forth port of os/progs/hexdump.s)
\   forth hexdump.fs 0         the first 256 bytes of block 0, 16 a row:
\   000  53 54 46 53 01 00 00 00 00 00 00 00 00 00 00 00  |STFS............|
\ The block comes from the file server's READBLK (below the file system).
[defined] sys.fs 0= [if] include /sys.fs [then]

: hex. ( u digits -- ) base @ >r hex >r <# r> 0 ?do # loop #> type r> base ! ;
: row ( a off -- )                              \ 16 bytes at a: the offset, hex, the characters
  3 hex. space  16 0 ?do space dup i + c@ 2 hex. loop
  ."   |" 16 0 ?do dup i + c@ dup 32 - 95 u< 0= if drop '.' then emit loop drop ." |" cr ;
: hexdump-main ( a u -- )
  arg 2swap 2drop num dup 0< if drop s" usage: hexdump BLOCK" usage then
  0 0 33 fs 0> 0= if s" hexdump: cannot read that block" +e e! 1 stop then
  inb 512 msg>  16 0 do inb i 16 * + i 16 * row loop ;
' hexdump-main main: hexdump
