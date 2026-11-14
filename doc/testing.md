# Testing

The tests are listed in `tools/tests.sh`, one line each, and run by
`tools/run-tests.sh`: it builds what the chosen tests need with one
`make -j`, runs them several at a time, each with its own log, and prints a
line per test with its time, then the failures and the slowest tests.

```
make test           # every test, each one run: the gate before a push
make test-fast      # the fast tier: the edit-and-test loop
make test-mid       # the fast and middle tiers
make test-cached    # every test, except those unchanged since they passed
make test-changed   # the tests that what differs from main can reach
make test-one T=sh  # one test (or several, or a pattern: T='conf-*')
make test-list      # the tests: name, tier, what it needs built, command
```

`make test` is the only target that runs every test whatever happened
before, and the one a push waits for. The others take a result from the
cache when the test has passed with the same inputs (below).

## The tiers

Times are from an 18-core Apple M5 Pro with 48 GB, with nothing else running
(they double when other checkouts test at the same time).

| tier | target | what it runs | time |
|---|---|---|---|
| fast | `make test-fast` | the examples on emulator and RTL, instruction by instruction (all but `gfx`); the conformance suite on interpreter, JIT and RTL; the shell, `vi`, files, preemption on the emulator; the JIT against the interpreter; the store with small pages | TFAST |
| mid | `make test-mid` | the fast tier, and: a short StrataOS session in lockstep with the RTL (`os/demo-short.txt`); `gfx` and the framebuffer on the RTL; the rest of the OS tests on the emulator (`vi.fs`, the Forth ports, the store, network, HTTP, the window server, wdoom, kira, isolation, guests, the session under the JIT); the debuggers; the store against its model and with a million files | TMID |
| full | `make test`, `make test-cached` | the mid tier, and: the two StrataOS sessions in lockstep with the RTL (`os/demo.txt`, `os/guest-demo.txt`); Ctrl-C on both machines; the process limits; the small configuration (`small-*`: 8 overlay map entries, examples and session); the smaller Local Stores (`ls*`) and the reproductions of what the proofs found (`formal-repro`); the WebAssembly builds under node (`wasm`, `wasm-rtl`) | TFULL |

A tier is a set of tests, not a different way of running them: a test does
the same thing in every tier. What decides a test's tier is how long it
takes; the longest (the sessions on the RTL: 160 million cycles at about
400,000 a second) are in the full tier only, and one of them sets the time
of `make test`, since nothing runs longer than the longest test once there
are enough processors for the rest.

`make test-small`, `make test-ls`, `make test-wasm`, `make test-wasm-rtl`,
`make test-jit`, `make test-dbg`, `make test-kira`, `make test-wdoom`,
`make test-stdb` and `make conformance` are still there. `make test-forth`
and `make formal` are not part of `make test`.

## One test

```
make test-one T=boot-short            # by name
make test-one T='ex-* conf-timer'     # several; patterns in quotes
tools/run-tests.sh -v sh              # the same, showing the whole log if it fails
tools/test-sh.sh build/bootrom.stx build/disk.img    # the script itself, nothing built first
```

The log of a test is `build/test/NAME.log`, kept until the test runs again;
the last summary is `build/test/summary.txt`. `tools/run-tests.sh -n ...`
says what would be built and run and does neither; `-j N` (or `JOBS=N` with
make) sets how many tests run at once (default: one per processor).

## What changed

`make test-changed` (`tools/run-tests.sh -c -g [BASE]`) takes the files
that differ from `BASE` (default `main`: its merge base with `HEAD`),
committed or not, and runs the tests they can reach:

| changed | tests |
|---|---|
| `rtl/`, `sim/` | those that run the RTL |
| `emu/` | those that run the emulator (nearly all), the WebAssembly build |
| `os/`, `firmware/`, `lang/forth/`, `examples/` | those that boot StrataOS; for `examples/` and `lang/forth/` also those that run the examples and the bare-metal Forth |
| `dbg/`, `web/`, `tools/stdb/` | the debuggers; the WebAssembly builds; the store's tests and those that boot StrataOS |
| a test's script, its expected output, its input (`tools/test-sh.sh`, `tools/test-sh.out`, `os/demo.txt`, `conformance/tests/timer.s`) | that test |
| `doc/`, `site/`, `fpga/`, `asic/`, `formal/` (not `formal/repro/`), `*.md` | none |
| `asm/`, `common/`, the `Makefile`, `tools/run-tests.sh`, `tools/tests.sh`, anything not listed | all |

It then builds only what those tests need: a change in `os/progs/` does
not build the other RTL configurations or the WebAssembly modules unless a
chosen test runs them.

## The caches

Both are under `$STRATA_CACHE` (default `~/.cache/strata`) and are shared
by every checkout of the repository on the machine; both are keyed by the
contents of files, never by paths or times, and entries are written under
a temporary name and renamed, so checkouts that test at the same time do
not disturb each other. Entries not used for 30 days are removed.

**Results** (`results/`). When a test passes, its log is stored under a
hash of its command line, `NCORES`, and the contents of every file it
reads: the simulators and images in its build directory (the `INPUTS`
column of `tools/tests.sh`), the files on its command line (its script,
the disk, the session's input), and the files of the source tree its
script names (`tools/test-sh.out`, `tools/net-echo.py`). With `-c`
(`test-fast`, `test-mid`, `test-cached`, `test-changed`), a test whose
hash is there is not run: it is listed as unchanged. Since the key is
taken from what was built, not from the sources, a change that leaves a
program's binary as it was (a comment in `emu/emu.c`) reruns nothing, a
change in `os/progs/` reruns the tests that read the disk and none of the
examples or the conformance suite, and a checkout that has just merged
`main` does not rerun what another checkout ran on the same commit.

`make test` writes results and never reads them.

A cached pass says that this test passed once with these inputs. It does
not say so again for what the inputs do not hold: the host's tools (node,
python3, nc), or the order of events in the tests that use the host's
clock (`boot-jit`, parts of `net`, `http`, `wasm`, `ws`, `wdoom`, `kira`).
That is why the gate runs everything.

**Builds** (`builds/`). The steps that take long (the emulator, each RTL
configuration's Verilator model, the two WebAssembly modules) go through
`tools/build-cache.sh`: the outputs are stored under a hash of the
compiler's version, the parameters, and every file in the directories the
step reads (`rtl/`, `sim/`, `emu/`, `web/`, `common/`, `asm/isa.h`) and
the `Makefile`; a step whose hash is there copies its outputs instead of
building. A new checkout gets all five RTL configurations and both
WebAssembly modules in a second or two.

To do without:

```
STRATA_CACHE= make test             # no shared cache: every build runs, results stay in build/test/cache
make clean && STRATA_CACHE= make test    # nothing from anywhere
rm -rf ~/.cache/strata              # empty it
```

## Adding a test

A line in `tools/tests.sh`:

```
t NAME TIER NEEDS INPUTS COMMAND
t sh fast build-main "emu os" "tools/test-sh.sh $OS"
```

- `TIER`: `fast` if it takes a few seconds, `mid` up to about a minute,
  else `full`.
- `NEEDS`: the make targets that build what it reads (`build-main`: the
  tools, both simulators, the examples, StrataOS; `build-test-disks`,
  `build-forth`, `build-small`, `build-wasm`, ...: see the `Makefile`).
- `INPUTS`: what it reads, for the result cache and `make test-changed`:
  `emu rtl dbg sasm stdb os ex ex:NAME forth wasm wasmrtl`, or paths. A
  test that reads something not named here, on its command line or in its
  script would be taken from the cache when that thing changes; `make
  test` would still run it.
- `COMMAND`: its exit status is the verdict. Tests run at the same time,
  so a test keeps its scratch files in a directory of its own (`mktemp
  -d`), copies the disk before it boots from it, and takes host ports from
  a range no other test uses (`tools/test-net.sh` shows how).

## Where the time goes

`make test` once ran its steps one after another: 39 minutes of processor
time in a row. The steps were already independent (each made its own
temporary directory), so they now run at the same time, and the time of
the suite is the time of its longest test. What was changed in the tests
themselves:

- `tools/compare-boot.sh` runs the emulator and the RTL at the same time
  instead of one after the other;
- `tools/test-procs.sh` and `tools/test-kira.sh` run their machines (three,
  and eight) at the same time, then check each;
- `tools/compare.sh` and `conformance/run.sh` are called once per example
  and per test, so one slow example does not hold the rest and each has
  its own result in the cache.

What still takes long, and why:

- `boot`, `small-boot` (7 minutes each), `boot-guests` (3): the RTL runs
  160 million cycles, one thread, about 2.5 µs a cycle for 8 cores.
  Booting is 7 million of them, so a checkpoint of the booted machine
  would save 4%. Compiler flags (`-O3`, `-mcpu=native`, LTO) made no
  difference that could be measured; Verilator's `--threads 2` made it 15%
  faster for 75% more processor time, and `--threads 4` slower.
- `procs` (4 minutes): two of its three machines wait in `spin` for a
  Ctrl-C that the emulator delivers at step 3,000,000,000 (`-b`,
  `PROCS_BREAK`), interpreting all the way.
- `kira`, `ws`, `wdoom` (20 to 60 s): they wait in host time (`Alt+Shift+W`
  holds the keyboard for a second) while almost no processor time passes.
