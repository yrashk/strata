\ =============================================================================
\ httpd-ps.fs: /~ps for httpd.fs, what the machine is doing
\ =============================================================================
\
\ httpd.fs loads this file for each request of /~ps, runs ps-page and
\ forgets the file again ((tool), the way the interpreter loads see.fs), so
\ the page costs no code space between requests. It asks proc (endpoint
\ register 1) for INFO, CORES and PS.
\
\ Most of the page is made while the file is read: the lines below the
\ definitions are interpreted, not compiled, so they cost no code space
\ either. They write the page into a buffer in data space (also forgotten
\ with the file); ps-page then answers with it, its length known.

inline-limit @  4 inline-limit !                \ code space is scarce: primitives are called

16 constant op-info  31 constant op-cores  9 constant op-ps \ proc's (os/spec/proc.toml)
\ Their replies go into dir-buf (httpd.fs's: a page needs no listing).
dir-buf constant info                           \ INFO: 64 bytes, u64 each:
: cores#    ( -- n ) info @ ;
: heap-free ( -- u ) info 8 + @ ;
: memory    ( -- u ) info 16 + @ ;
: processes ( -- n ) info 24 + @ ;
: units-in  ( -- n ) info 32 + @ ;              \ kernel code units loaded
: switches  ( -- n ) info 40 + @ ;
: kib-moved ( -- n ) info 48 + @ ;
dir-buf 64 + constant core-recs                 \ CORES: 32 bytes a core: u8 core, pid running, runnable,
                                                \ processes; u32 switches at 8, KiB moved at 12
dir-buf 576 + constant proc-recs                \ PS: 32 bytes a process: u8 pid, state, core, parent,
                                                \ flags, threads; u32 switches, KiB at 8, 12; the name at 16
: proc@ ( op -- n ) >r 0 0 0 r> 1 (msg) ;       \ a request to proc (endpoint register 1)
: records> ( n buf -- n ) 64 2 pick 32 * 5 tget ; \ the reply's n records -> buf
: num ( n -- ) <# #s #> out ;                   \ a number, to the page
: td ( a u -- ) s" <td>" out out s" </td>" out ; \ a table cell
\ A table row is a record's fields, each named by its offset: a byte below 8, a u32 from 8.
: field@ ( record offset -- n ) tuck + swap 8 < if c@ else l@ then ;
: fields ( record a u -- ) bounds ?do dup i c@ field@ <# #s #> td loop drop ; \ the fields at offsets a u
create core-fields 0 c, 1 c, 2 c, 3 c, 8 c, 12 c, \ core running runnable processes switches KiB
create proc-fields 0 c, 3 c, 2 c, 5 c, 8 c, 12 c, \ pid parent | (state) | core threads switches KiB
: state-name ( record -- a u ) 1+ c@ 4 min 8 * s" ?       running ready   blocked zombie  " drop + 8 -trailing ;
: core-row ( i -- ) s" <tr>" out  32 * core-recs + core-fields 6 fields  s" </tr>" out out-nl ;
: proc-row ( i -- )
  s" <tr>" out  32 * proc-recs +  dup proc-fields 2 fields  dup state-name td
  dup proc-fields 2 + 4 fields  16 + 16 zcount td  s" </tr>" out out-nl ;
: rows ( n xt -- ) swap 0 max 0 ?do i over execute loop drop ; \ a table row per record
variable #page                                  \ the page: the data space left, nearly all
unused 128 - constant /page  create page /page allot
: >page ( a u -- ) /page #page @ - min  tuck page #page @ + swap move  #page +! ; \ append
' >page is out                                  \ httpd.fs's generated pages write to OUT
: ps-page ( -- ) ;                              \ (the page was sent as the file was read)

\ ---- the page, made and sent as the file is read ---------------------------------------
op-info proc@ drop  info 64 64 5 tget
op-cores proc@ 0 max  core-recs records>        \ (the count stays on the stack for the table)
s" <html><head><title>what the machine is doing</title>" out
s" <link rel='stylesheet' href='/style.css'></head><body>" out out-nl
s" <h1>StrataOS 0.1: what the machine is doing</h1>" out out-nl
s" <p>Up " out  ticks 100000 / 10 /mod num s" ." out num  s"  s; " out
cores# num s"  cores, " out  processes num s"  processes, " out  units-in num s"  kernel units loaded; " out
switches num s"  context switches have moved " out  kib-moved num s"  KiB of Local Store; heap: " out
heap-free 10 rshift num s"  KiB free of " out  memory 10 rshift num s"  KiB.</p>" out out-nl
s" <h2>Cores</h2><table><tr><th>core</th><th>running</th><th>runnable</th>" out
s" <th>processes</th><th>switches</th><th>KiB moved</th></tr>" out out-nl
' core-row rows  s" </table>" out out-nl         \ (the count from CORES)
s" <h2>Processes</h2><table><tr><th>pid</th><th>parent</th><th>state</th><th>core</th>" out
s" <th>threads</th><th>switches</th><th>KiB moved</th><th>name</th></tr>" out out-nl
op-ps proc@ 0 max  proc-recs records>  ' proc-row rows  s" </table>" out out-nl
s" <p class='foot'><a href='/'>home</a> &middot; <a href='/~/'>every file</a></p>" out
s" </body></html>" out out-nl
here s" text/html" tuck s,  #page @ s" 200 OK" respond   \ the answer (the type copied out of
head? 0= [if] page #page @ send [then]          \ the buffer that S" interpreted reuses)
inline-limit !                                  \ inlining as it was
