\ Strata Forth under StrataOS: what the bare-metal Forth does not have.
\ Fed to `forth < ostest.fs` by tests/run-os.sh; expected output: tests/os.out.
\ ---- files
include inc1.fs
from-inc1 from-inc2
include nofile.fs
include incerr.fs
fine  [defined] never .
s" inc2.fs" included  from-inc2
\ ---- tools on demand: loaded for one command, then forgotten
[defined] dis .  [defined] .fcache .  [defined] see .
chere  $0508FFF8 dis  chere = .
: t1 ( -- ) ." hi" ;  t1  ' t1 xt>name name>size .
.fcache
: uses-tool ( -- ) .fcache ;
require tools  [defined] .fcache .  [defined] tools.fs .
: uses-tool ( -- ) .fcache ;  uses-tool
require tools
\ ---- one thread: the multicore words say so
cores .
' dup 1 run-on
heap-cap 1 give
tmp-cap 0 take
\ ---- capabilities of a StrataOS process, time
0 cvalid . 5 cvalid . heap-cap . tmp-cap . 9 cvalid .
ticks 20 ms ticks swap - 19000 > .
\ ---- the end
bye
