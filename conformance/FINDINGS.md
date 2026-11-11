# Conformance findings

Discrepancies found by the conformance suite. Repro = the test file in
conformance/tests/. Failing cells are listed in xfail.txt.

## F1. cgive outside the core window: wrong tval on the RTL - FIXED
Repro: mc.s (core 1, user mode, corebase 1, corecount 2, cgive with t0 = 2).
Spec: gen-insns-cap.tex CGIVE: capop, tval = X[rx] (window-relative) for a
window violation; the physical node for an out-of-range or halted node.
interp/jit: tval 2. RTL: tval 3 (the physical node).
Fixed in rtl/strata_core.sv: CF_GIVE traps with rb before the physical-node
check.

## F2. The emulator ignores CCR.PTRAP for in-flight device reads - FIXED
Repro: pend.s.
Spec: ch-memory.tex, gen-insns-ls.tex: cause 9, tval = the address.
RTL: traps pend. interp/jit: waited until another core released the read.
Fixed in emu/emu.c, in the load/store pending check.
ltag/linst: the emulator now checks the set's entry against pending ranges
(wait, or pend with PTRAP), as the RTL does; pend.s covers both.

## F3. The emulator's halt does not wait for in-flight device reads - FIXED
Repro: haltdrain.s.
Spec: HALT, ch-traps.tex, ch-intercore.tex: halt drains all of the core's
transfers.
RTL: drains. interp/jit: halted at once (a later cgive to the core got capop).
Decided: halt drains every transfer of the core, device reads included,
also in user mode before it traps to the supervisor (the RTL's rule).
Fixed in emu/emu.c (OP_SYS: halt waits while a tag is busy; the JIT
interprets while a device read is pending, so it runs that step()).
Consequence: a core must not halt with a break read in flight (write the
release port first); the emulator otherwise reports a deadlock.

## F4. One release completes every pending break read (emu) or only one (RTL) - FIXED
Repro: brkrel.s (now also checks that core 1's report arrived after the
one release).
Decided: one write to the release port completes, with 0, every break read
waiting at that moment on every core (the emulator's rule); reads issued
later wait for the next Ctrl-C or release.
Fixed in rtl/strata_dev.sv: per-core brk_wait/brk_rel bits replace the
single brk_wait/brk_rel; a release marks every waiting core, and each
core's next try returns 0 (a pending release wins over a stored Ctrl-C).
One break read per core is in flight at a time (the manual's rule); the
emulator still accepts up to 4 pending device reads per core.

## F5. A transfer is not ordered after an in-flight device read over the same D-LS bytes - FIXED
Repro: pendxfer.s (now also part C: with CCR.PTRAP, the overlapping tput
traps pend, tval = its D-LS address).
Decided: a transfer whose D-LS range overlaps an in-flight device read of
the same core waits at issue until the read completes, as loads and stores
do; with CCR.PTRAP it traps pend. tgetx (I-LS) is not affected.
Fixed in emu/emu.c (the transfer issue checks the pending reads before the
tag) and rtl/strata_tu.sv (iss_hz: the command overlaps a queued device
get; not accepted until it retires) + rtl/strata_core.sv (K_XFER:
pending(ra) on iss_hz).

## F6. A capability with an unaligned base reaches bytes outside its range - FIXED
Repro: capalign.s (now: csplit at 4 and at 0xfff traps capop, tval = the
offset; csplit at 8 works and a tget at offset 0 reads far bytes 8..15;
the same in device space: 0x11 traps, 0x10 works).
Decided: capabilities are always 8-byte aligned. csplit traps capop unless
the offset is a multiple of 8. No other instruction makes a base: boot
capabilities start at 0, cjoin/crestrict/cshare/catomic/cdom/crevoke keep
the base, cmkep's base is a node number. The rule is uniform: device ports
and windows (platform table) are 8-byte aligned, and device transfers still
address single bytes by offset.
Fixed in emu/emu.c and rtl/strata_core.sv (CF_SPLIT). xfer.s made its
"shorter than a word" atomic capability by splitting at 4; it now uses an
empty one (split at 0).

## F7. doc/strataos.md: crecv without R traps perm; manual, emulator and RTL trap capinv (tval = ce)
The suite expects capinv. Fix the design document.

## F8. The manual is stale
- No svc / cause 14.
- No user-mode inbox rule (ctake, cpoll and tany with bit 16 trap priv in
  user mode).
- Device space 0x3000 (now 0x5000), T3 16 MiB (now 64 MiB), a 5-entry
  platform table (now 7 entries, 256 bytes).
- No timer and no framebuffer controller.
- "Every byte to the one port" contradicts the one-byte-per-beat rule
  (devspan.s).
- "Only the break read is ever reported busy" is out of date.
- ch-encoding.tex says reserved fields are "ignored"; ch-appendices.tex says
  they are "checked" (illegal). Both implementations ignore them.
- The block-device error order is not stated; both implementations check
  op > lba > range > perm.
- F3-F6 (doc/strataos.md 1.2 and 1.5 state them; the manual must too):
  - csplit (gen-insns-cap.tex): capop unless the offset is a multiple of 8;
    a note in the capability chapter that bases are always 8-byte aligned.
  - The console release port (platform.h comment and the device chapter):
    one write completes every break read waiting at that moment, on every
    core, with 0; later reads wait for the next Ctrl-C or release.
  - ch-memory.tex hazard table and the transfer instructions (tget, tput):
    a transfer whose D-LS range overlaps an in-flight device read waits at
    issue (pend with CCR.PTRAP, tval = the D-LS address).
  - HALT, ch-traps.tex, ch-intercore.tex: halt drains device reads too
    (also in user mode, before the halt trap); a break read must be
    released first.

## F9. Fifteen revocation domains limited StrataOS to 14 processes - REPLACED
The ISA had 16 revocation domains (a 4-bit field in every capability, 0 =
none); StrataOS gave each 1 MiB arena one and the framebuffer another.
Decided: revocation by address. T3 and T2 are divided into 256 KiB
granules with a 16-bit generation and a head bit each; a capability
carries a revocable flag and the generation of its base's granule. cdom
makes a granule-aligned range revocable, crevoke / cundom revoke the
revoker's range (every unit it touches, whole), and a revoker can be cut
and joined at granule boundaries, so one revoker covers many regions.
dom.s was rewritten (alignment traps, units and cjoin, revoker pieces,
gifts and the save table, T2, 40 regions); mc.s revokes a whole granule.
Edge case, decided and tested: a zero-length piece cut at the very end of
a region has its base in the next granule and lives and dies with it.
