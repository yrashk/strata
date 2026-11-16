\ hexdump.fs: show a raw disk block (the Forth port of os/progs/hexdump.s)
\   forth hexdump.fs 0         the first 256 bytes of block 0, 16 a row:
\   000  53 54 46 53 01 00 00 00 00 00 00 00 00 00 00 00  |STFS............|
[defined] sys.fs 0= [if] include /sys.fs [then]

33 constant op-readblk                          \ READBLK: the block's 512 bytes, below the file system
: printable ( c -- c' ) dup bl - 95 u< 0= if drop '.' then ;
: bytes. ( a -- ) 16 0 ?do space dup i + c@ 2 hex. loop drop ;
: chars. ( a -- ) 16 0 ?do dup i + c@ printable emit loop drop ;
: row ( a off -- ) 3 hex. space  dup bytes.  ."   |" chars. ." |" cr ; \ 16 bytes at a
: block# ( a u -- n ) arg 2swap 2drop num dup 0< if drop s" usage: hexdump BLOCK" usage then ;
: hexdump-main ( a u -- )
  block#  0 0 op-readblk fs 0> 0= if s" hexdump: cannot read that block" fail then
  inb 512 msg>  16 0 do inb i 16 * +  i 16 * row loop ;
' hexdump-main main: hexdump
