#!/bin/sh
# The architectural conformance suite: runs every test program in
# conformance/tests/ on the three implementations
#   interp  the emulator, interpreting only        (strata-emu -j)
#   jit     the emulator with the JIT               (strata-emu -J)
#   rtl     the Verilated RTL                       (strata-rtl)
# and prints a table test x machine.
#
# A test prints its SIGNATURE (lines "sig <hex>") and a verdict ("pass" or
# "fail", after "bad/got/exp" lines naming each failed self-check). A cell
# is "pass" when the machine ran the test to completion (every core halted,
# no unhandled fault, no timeout), printed "pass", and - for jit and rtl -
# printed exactly the interpreter's signature. Otherwise it says why:
#   FAIL n    n self-checks failed               SIG       signature differs from interp
#   NOVERD    no verdict printed (hang, fault)   TIMEOUT   step / cycle limit reached
#   FAULT     an unhandled trap halted a core
# Known discrepancies are listed in conformance/xfail.txt ("test machine
# reason", see conformance/FINDINGS.md); such a cell shows "xfail" and does
# not fail the run ("XPASS" when it unexpectedly passes: remove the entry).
# When the interpreter itself is listed for a test, the other machines'
# signatures are not compared with it (only their verdicts count).
#
# A test may put extra simulator arguments on a line "; args: ..." in its
# header (paths relative to the repository root), e.g. console input.
#
#   conformance/run.sh [-v] [test ...]     (default: every conformance/tests/*.s)
#   -v: show the outputs of failing cells
#
# Every run uses the virtual timer (-T virtual) and no window (-g none).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
ncores=${NCORES:-8}
out="$b/conformance"
mkdir -p "$out"
verbose=0
if [ "${1:-}" = "-v" ]; then verbose=1; shift; fi
if [ $# -eq 0 ]; then
  set -- $(ls "$here"/conformance/tests/*.s | sed 's|.*/||; s|\.s$||')
fi
xfail="$here/conformance/xfail.txt"
start=$(date +%s)

# verdict FILE.out FILE.err EXIT -> prints the cell (before the signature comparison)
verdict() {
  if grep -q '^timeout' "$2"; then echo TIMEOUT; return; fi
  if grep -q '^deadlock' "$2"; then echo DEADLOCK; return; fi
  if grep -q 'fault' "$2"; then echo FAULT; return; fi
  if grep -q '^pass$' "$1"; then
    [ "$3" -eq 0 ] && echo pass || echo "EXIT$3"
    return
  fi
  if grep -q '^fail$' "$1"; then echo "FAIL$(grep -c '^bad ' "$1")"; return; fi
  echo NOVERD
}

printf '%-16s %-9s %-9s %-9s %s\n' test interp jit rtl signature
bad=0
ntests=0
nsig=0
for t in "$@"; do
  t=$(basename "$t" .s)
  src="$here/conformance/tests/$t.s"
  img="$out/$t.stx"
  ntests=$((ntests + 1))
  if ! "$b/sasm" -o "$img" "$src" 2>"$out/$t.asm.err"; then
    printf '%-16s %s\n' "$t" "ASSEMBLY FAILED"; cat "$out/$t.asm.err"; bad=1; continue
  fi
  args=$(sed -n 's/^; args: *//p' "$src" | head -1 | sed "s|\\\$ROOT|$here|g")
  # "; stdin: open": console input that never ends and never comes (a FIFO
  # we hold open for writing), so input reads wait as at a terminal
  fifo=""
  if grep -q '^; stdin: open' "$src"; then
    fifo="$out/$t.fifo"; rm -f "$fifo"; mkfifo "$fifo"; exec 3<>"$fifo"
    args="$args -i $fifo"
  fi
  # the three machines run at once
  ( cd "$here" && "$b/strata-emu" -c "$ncores" -j -T virtual -g none -m 100000000 $args "$img" \
      >"$out/$t.interp.out" 2>"$out/$t.interp.err" </dev/null; echo $? >"$out/$t.interp.ec" ) &
  ( cd "$here" && "$b/strata-emu" -c "$ncores" -J -T virtual -g none -m 100000000 $args "$img" \
      >"$out/$t.jit.out" 2>"$out/$t.jit.err" </dev/null; echo $? >"$out/$t.jit.ec" ) &
  ( cd "$here" && "$b/strata-rtl" -T virtual -g none -m 400000000 $args "$img" \
      >"$out/$t.rtl.out" 2>"$out/$t.rtl.err" </dev/null; echo $? >"$out/$t.rtl.ec" ) &
  wait
  if [ -n "$fifo" ]; then exec 3>&-; rm -f "$fifo"; fi
  grep '^sig ' "$out/$t.interp.out" >"$out/$t.interp.sig"
  n=$(wc -l <"$out/$t.interp.sig" | tr -d ' ')
  nsig=$((nsig + n))
  sigdiff=""
  line="$(printf '%-16s' "$t")"
  # a known-wrong interpreter is no reference: then only the verdicts count
  refok=1
  [ -f "$xfail" ] && grep -qE "^$t +interp( |$)" "$xfail" && refok=0
  for m in interp jit rtl; do
    v=$(verdict "$out/$t.$m.out" "$out/$t.$m.err" "$(cat "$out/$t.$m.ec")")
    grep '^sig ' "$out/$t.$m.out" >"$out/$t.$m.sig"
    if [ "$m" != interp ] && [ $refok -eq 1 ] && ! cmp -s "$out/$t.interp.sig" "$out/$t.$m.sig"; then
      sigdiff="$sigdiff $m"
      [ "$v" = pass ] && v=SIG
    fi
    known=0
    [ -f "$xfail" ] && grep -qE "^$t +$m( |$)" "$xfail" && known=1
    if [ $known -eq 1 ]; then
      if [ "$v" = pass ]; then v=XPASS; else v=xfail; fi
    elif [ "$v" != pass ]; then
      bad=1
      if [ $verbose -eq 1 ]; then
        echo "---- $t on $m: $v"; grep -v '^sig ' "$out/$t.$m.out" | head -20; head -5 "$out/$t.$m.err"
        [ -n "$sigdiff" ] && diff "$out/$t.interp.sig" "$out/$t.$m.sig" | head -6
      fi
    fi
    line="$line $(printf '%-9s' "$v")"
  done
  if [ $refok -eq 0 ]; then line="$line not compared ($n entries)"
  elif [ -z "$sigdiff" ]; then line="$line same ($n entries)"; else line="$line differs:$sigdiff"; fi
  echo "$line"
done
end=$(date +%s)
echo "$ntests tests, $nsig signature entries per machine, $((end - start)) s"
[ $bad -eq 0 ] && echo "conformance: OK" || echo "conformance: FAILED"
exit $bad
