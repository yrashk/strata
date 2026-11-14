# The tests of `make test`, one per line, read by tools/run-tests.sh (see
# doc/testing.md).
#
#   t NAME TIER NEEDS INPUTS COMMAND
#
# TIER    fast (make test-fast), mid (make test-mid adds these) or full
#         (make test adds these)
# NEEDS   the make targets that build what it reads (build-main: the tools,
#         the simulators, the examples, StrataOS; see the Makefile)
# INPUTS  what it reads, for the result cache and for the selection by what
#         changed: emu rtl dbg sasm stdb (the programs in its build
#         directory), os (boot ROM and disk), ex (every example; ex:NAME:
#         one), forth (the bare-metal image), wasm, wasmrtl, and files or
#         directories (the files on its command line and those its script
#         names are added)
# COMMAND runs from the repository's root with BUILD and NCORES set; $B is
#         the build directory. Its exit status is the verdict; it keeps its
#         scratch files to itself (mktemp), since tests run at the same time.
#
# D is the build directory of the tests that follow ('$B': the default
# configuration; '$B/small' and the like: another RTL configuration).

OS='$B/bootrom.stx $B/disk.img'

# ---- the examples, emulator against RTL instruction by instruction ------------
for e in examples/*.s; do
  e=$(basename "$e" .s)
  case $e in gfx) tier=mid ;; *) tier=fast ;; esac    # (gfx: 10 million RTL cycles)
  t "ex-$e" $tier build-main "emu rtl ex:$e" "tools/compare.sh \$B/examples/$e.stx"
done

# ---- the store on the host -------------------------------------------------------
t stdb-model   mid  build-stdb-test '$B/stdb-test' '$B/stdb-test'
t stdb-million mid  build-stdb-test '$B/stdb-many' '$B/stdb-many 1000000'
t stdb-small   fast build-stdb-test '$B/stdb-many' '$B/stdb-many 20000 1024'

# ---- StrataOS sessions in lockstep with the RTL --------------------------------
# (a short session first: the boot, a file, a two-core program, a pipeline, halt)
t boot-short   mid  build-main "emu rtl os stdb" "tools/compare-boot.sh $OS os/demo-short.txt short"
t boot         full build-main "emu rtl os stdb" "tools/compare-boot.sh $OS os/demo.txt"
t boot-guests  full build-main "emu rtl os stdb" "tools/compare-boot.sh $OS os/guest-demo.txt guests"

# ---- StrataOS ---------------------------------------------------------------------
t break        full build-main "emu rtl os" "tools/test-break.sh $OS"
t sh           fast build-main "emu os" "tools/test-sh.sh $OS"
t vi           fast build-main "emu os" "tools/test-vi.sh $OS"
t vifs         mid  build-main "emu os" "tools/test-vifs.sh $OS"
t fs-progs     mid  build-main "emu os" "tools/test-fs-progs.sh $OS"
t store        mid  build-main "emu os stdb" "tools/test-store.sh $OS"
t files        fast "build-main build-test-disks" "emu stdb" 'tools/test-files.sh $B/bootrom.stx $B/files-test/disk.img'
t net          mid  build-main "emu os" "tools/test-net.sh $OS"
t http         mid  "build-main build-test-disks" "emu" 'tools/test-http.sh $B/bootrom.stx $B/http-test/disk.img'
t ws           mid  build-main "emu os" "tools/test-ws.sh $OS"
t wdoom        mid  build-main "emu os" "tools/test-wdoom.sh $OS"
t kira         mid  build-main "emu os" "tools/test-kira.sh $OS"
t preempt      fast build-main "emu os" "tools/test-preempt.sh $OS"
t isolate      mid  "build-main build-test-disks" "emu" 'tools/test-isolate.sh $B/bootrom.stx $B/isol-test/disk.img'
t guest        mid  build-main "emu os" "tools/test-guest.sh $OS"
t procs        full build-main "emu os" "tools/test-procs.sh $OS"
t boot-jit     mid  build-main "emu os" "tools/test-boot-jit.sh $OS os/demo.txt"

# ---- the framebuffer, the JIT, the debuggers --------------------------------------
t fb           mid  build-main "emu rtl" 'tools/test-fb.sh $B/examples/gfx.stx'
t jit          fast "build-main build-forth" "emu ex forth" 'tools/test-jit.sh'
# (the debugger's engine in the WebAssembly build too, where that can be built)
if command -v node >/dev/null 2>&1 && command -v "${EMCC:-emcc}" >/dev/null 2>&1; then
  t dbg        mid  "build-main build-wasm" "emu dbg ex os wasm \$B/kernel.map" 'tools/test-dbg.sh'
else
  t dbg        mid  build-main "emu dbg ex os \$B/kernel.map" 'tools/test-dbg.sh'
fi

# ---- the conformance suite: each test on interpreter, JIT and RTL -----------------
for c in conformance/tests/*.s; do
  c=$(basename "$c" .s)
  t "conf-$c" fast build-main "emu rtl sasm conformance/tests/$c.s conformance/tests/lib conformance/tests/data conformance/xfail.txt" "conformance/run.sh $c"
done

# ---- the small (FPGA) configuration: 8 overlay map entries ------------------------
D='$B/small'
t small-examples full build-small "emu rtl ex" 'EMU_ARGS="-X 8" tools/compare.sh $B/small/examples/*.stx'
t small-boot     full build-small "emu rtl os stdb" 'EMU_ARGS="-X 8" tools/compare-boot.sh $B/small/bootrom.stx $B/small/disk.img os/demo.txt'

# ---- smaller Local Stores -----------------------------------------------------------
# (32/32: every example; 16/4 and 4/32: those whose data and stack, and code, fit)
lsb=""; for e in clock faults hello mandel pipeline race; do lsb="$lsb \$B/ls16-4/examples/$e.stx"; done
lsc=""; for e in clock faults hello mandel overlay race; do lsc="$lsc \$B/ls4-32/examples/$e.stx"; done
D='$B/ls32'
t ls32-examples  full build-ls32 "emu rtl ex" 'EMU_ARGS="-L 32" tools/compare.sh $B/ls32/examples/*.stx'
t ls32-lssize    full build-ls32 "emu rtl sasm conformance/tests/lssize.s conformance/tests/lib" 'EMU_ARGS="-L 32" conformance/run.sh lssize'
t ls32-boot      full "build-ls32 build-main" "emu rtl $OS" "EMU_ARGS=\"-L 32\" tools/test-ls-boot.sh $OS"
D='$B/ls16-4'
t ls16-4-examples full build-ls16-4 "emu rtl ex" "EMU_ARGS=\"-L 16,4\" tools/compare.sh $lsb"
t ls16-4-lssize   full build-ls16-4 "emu rtl sasm conformance/tests/lssize.s conformance/tests/lib" 'EMU_ARGS="-L 16,4" conformance/run.sh lssize'
D='$B/ls4-32'
t ls4-32-examples full build-ls4-32 "emu rtl ex" "EMU_ARGS=\"-L 4,32\" tools/compare.sh $lsc"
t ls4-32-boot     full "build-ls4-32 build-main" "emu rtl $OS" "EMU_ARGS=\"-L 4,32\" tools/test-ls-boot.sh $OS"
D='$B'
t ls64-32-boot    full build-main "emu os" "EMU_ARGS=\"-L 64,32\" RTL=none tools/test-ls-boot.sh $OS"
# two cores and 4 KiB Local Stores (build-f44/): what the formal proofs found
D='build-f44'
t formal-repro    full build-f44 "emu rtl sasm formal/repro/walkreset.s formal/repro/stopstore.s" 'formal/repro/run.sh'
D='$B'

# ---- the WebAssembly builds under node ------------------------------------------------
if command -v node >/dev/null 2>&1 && command -v "${EMCC:-emcc}" >/dev/null 2>&1; then
  t wasm full build-wasm-test "emu sasm ex forth wasm \$B/ws/wsdemo.stx \$B/netrelay $OS" 'tools/test-wasm.sh'
else
  skip wasm "needs node and ${EMCC:-emcc}"
fi
if command -v node >/dev/null 2>&1 && command -v "${EMXX:-em++}" >/dev/null 2>&1 && [ "$N" = "${WEB_RTL_CORES:-8}" ]; then
  t wasm-rtl full build-wasm-rtl-test "rtl ex wasmrtl" 'tools/test-wasm-rtl.sh'
else
  skip wasm-rtl "needs node and ${EMXX:-em++}, and NCORES = WEB_RTL_CORES"
fi
