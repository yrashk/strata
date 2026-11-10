\ preempt.fs: Forth compiles and runs code while another process shares its
\ core (tests/run-os.sh starts `spin` on the same core). Every round defines
\ a word, runs it and forgets it again; the dispatcher switches between the
\ two processes many times meanwhile and reloads the I-LS from the code
\ mirror each time (svc SET_MIRROR). A lost instruction would crash or change
\ the sum.
variable acc
: round ( -- ) s" (mark) : t ( -- n ) 0 2000 0 do i + loop ; t acc +! (release)" evaluate ;
: rounds ( n -- ) 0 do round loop ;
150 rounds
acc @ . cr
: check ( -- ) heap-cap clen 0> if ." heap ok " then  8 far@ drop  12 dup * . cr ;
check
