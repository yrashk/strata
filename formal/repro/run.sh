#!/bin/sh
# Runs formal/repro/walkreset.s (formal/FINDINGS.md F1) on the emulator and
# on the RTL, both with two cores and 4 KiB Local Stores, and compares what
# they print. Builds that RTL configuration into build-f44/ first.
#
#   formal/repro/run.sh
set -eu
cd "$(dirname "$0")/../.."
B=build-f44
make BUILD=$B NCORES=2 DLS_KIB=4 ILS_KIB=4 $B/sasm $B/strata-emu $B/strata-rtl > /dev/null
$B/sasm -o $B/walkreset.stx formal/repro/walkreset.s
# (halt lines and counts are timing: core 0 may or may not halt once before its reset)
$B/strata-emu -c 2 -L 4 -T virtual -g none $B/walkreset.stx > $B/walkreset.emu 2>&1 || true
$B/strata-rtl -T virtual -g none $B/walkreset.stx > $B/walkreset.rtl 2>&1 || true
e=$(grep -v '^core [0-9]*: halt\|^total cycles' $B/walkreset.emu | tr '\n' ' ')
r=$(grep -v '^core [0-9]*: halt\|^total cycles' $B/walkreset.rtl | tr '\n' ' ')
echo "emulator: $e"
echo "RTL:      $r"
[ "$e" = "$r" ] && echo "walkreset: OK" || { echo "walkreset: FAIL"; exit 1; }
