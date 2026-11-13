#!/bin/sh
# Runs the reproductions of formal/FINDINGS.md (walkreset.s: F1, stopstore.s:
# F2) on the emulator and on the RTL, both with two cores and 4 KiB Local
# Stores (F1 needs them), and compares what they print. Builds that RTL
# configuration into build-f44/ first.
#
#   formal/repro/run.sh
set -eu
cd "$(dirname "$0")/../.."
B=build-f44
make BUILD=$B NCORES=2 DLS_KIB=4 ILS_KIB=4 $B/sasm $B/strata-emu $B/strata-rtl > /dev/null
rc=0
for t in walkreset stopstore; do
  $B/sasm -o $B/$t.stx formal/repro/$t.s
  # (halt lines and counts are timing: a core may or may not halt before it is reset)
  $B/strata-emu -c 2 -L 4 -T virtual -g none $B/$t.stx > $B/$t.emu 2>&1 || true
  $B/strata-rtl -T virtual -g none $B/$t.stx > $B/$t.rtl 2>&1 || true
  e=$(grep -v '^core [0-9]*: halt\|^total cycles' $B/$t.emu | tr '\n' ' ')
  r=$(grep -v '^core [0-9]*: halt\|^total cycles' $B/$t.rtl | tr '\n' ' ')
  echo "$t: emulator: $e"
  echo "$t: RTL:      $r"
  [ "$e" = "$r" ] && echo "$t: OK" || { echo "$t: FAIL"; rc=1; }
done
exit $rc
