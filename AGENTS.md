# Working in this repository

`HANDOFF.md` says what is here, what state it is in and how the work is
done. This file says which tests to run when. `doc/testing.md` has the
details (the tiers, the selection, the caches, how to add a test).

## Which tests, when

| when | run | takes |
|---|---|---|
| after each edit, while working on something | `make test-fast` | about 15 s |
| one test failed, or one test is what you are working on | `make test-one T=NAME` (log: `build/test/NAME.log`) | that test |
| a piece of work is done, before committing it | `make test-mid` | about a minute |
| before asking for a merge, or when the change is wide | `make test-changed` | what the change reaches: seconds to 8 minutes |
| before a push, and before saying that the suite passes | `make test` | about 8 minutes |

- `make test-fast`, `test-mid`, `test-changed` and `test-cached` skip a test
  that has already passed with the same inputs (the simulators, the images,
  its script, by content), so running them again after a small change costs
  only what the change reaches. Start with the smallest one that can show
  the mistake you might have made.
- `make test` runs every test every time and takes nothing from the cache.
  It is the only one that counts for the rule in `HANDOFF.md`: a push goes
  out only after the full `make test` exits 0. A green `test-cached` or
  `test-changed` is not that, and is not to be reported as "the full suite
  passes".
- Do not run `make test` to look for one failure, and do not run it again
  after each fix. Read the failing test's log, fix, rerun that test with
  `make test-one T=NAME`, then `make test-mid`; run `make test` once when
  everything else is green. It takes minutes: start it in the background
  and go on with something that does not change the tree.
- What a change needs at least, before the full run:
  - `rtl/`, `sim/`: `make test-fast` (the examples and the conformance
    suite on the RTL), then `make test-mid` (a StrataOS session on the RTL);
  - `emu/`: `make test-fast`, then `make test-mid`;
  - `os/`, `firmware/`, `lang/forth/`: `make test-fast` (shell, `vi`,
    files, preemption), then the test of what you changed (`make test-one
    T=net`, `T=kira`, ...), then `make test-mid`;
  - `asm/`, `common/`, the `Makefile`, `tools/run-tests.sh`,
    `tools/tests.sh`: everything can be reached; `make test-mid`, then
    `make test`;
  - a test's script or expected output: that test (`make test-one`);
  - `doc/`, `site/`, `*.md`: no test reads them (`make test-changed` says
    so).
- `make test-list` lists the tests with their tiers. `make test-forth` and
  `make formal` are not part of `make test`: run them when you change
  `lang/forth/` or the RTL that the proofs cover.
- Tests run at the same time, yours and those of other checkouts. A test
  you add keeps its scratch files in its own `mktemp -d`, copies the disk
  before booting from it, and takes host ports from a range of its own. It
  goes into `tools/tests.sh` (one line), not into the `Makefile`.
- A test that fails only when the machine is busy is still a finding: say
  so with its log instead of rerunning until it passes.
- Times are for an 18-core machine with nothing else running; with other
  checkouts testing they double. The caches (`~/.cache/strata`) are shared
  by every checkout, so a test another checkout ran on the same inputs is
  not run again by the cached targets.
