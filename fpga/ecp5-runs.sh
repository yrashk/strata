#!/bin/sh
# Redoes the ECP5 results in one go: synthesizes the 1-core system three
# ways, places and routes them with nextpnr, draws each die, and replaces
# fpga/results/ecp5-1*/ with what came out.
#
#   fpga/ecp5-runs.sh            # all three, in parallel (about 1.5 hours)
#   fpga/ecp5-runs.sh xmap12     # just one: full, xmap12 or xmap4
#
#   full    the system as synthesized: placed only (99.6% of the logic
#           cells; routing it did not finish in an hour). ROUTE_FULL=1 tries.
#   xmap12  the overlay map cut from 16 entries to 12: placed and routed
#   xmap4   ... to 4: placed and routed
#
# The flow is fpga/synth.sh (NXMAP=N for the variants), fpga/pnr.sh with the
# static placer, router1 and a 10 MHz target, and fpga/render.py; see
# fpga/README.md, "Place and route". Needs Yosys and sv2v, nextpnr-ecp5 (the
# OSS CAD Suite under build/tools/ is used if it is there), and Python with
# numpy and Pillow (build/venv if it is there). Each results directory gets
# a COMMIT file: the last commit that changed rtl/ (and "+dirty" if rtl/ had
# uncommitted changes).
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here"
py=python3
[ -x build/venv/bin/python ] && py=build/venv/bin/python
commit=$(git log -1 --format=%h -- rtl/)   # the last commit that changed the RTL
git diff --quiet HEAD -- rtl/ || commit="$commit+dirty"
nextpnr=nextpnr-ecp5
[ -x build/tools/oss-cad-suite/bin/nextpnr-ecp5 ] && nextpnr=build/tools/oss-cad-suite/bin/nextpnr-ecp5
npver=$($nextpnr --version 2>&1 | sed -n 's/.*Version nextpnr-\([0-9.]*\).*/\1/p')

one() {   # name
  case $1 in
    full)   nx= ;     res=ecp5-1;        place=${ROUTE_FULL:+0}; place=${place:-1}
            what="the whole 1-core system as synthesized" ;;
    xmap12) nx=12;    res=ecp5-1-xmap12; place=0
            what="the 1-core system, overlay map cut from 16 to 12 entries" ;;
    xmap4)  nx=4;     res=ecp5-1-xmap4;  place=0
            what="the 1-core system, overlay map cut from 16 to 4 entries" ;;
    *) echo "unknown run $1"; exit 2 ;;
  esac
  syn=fpga/build/ecp5-1${nx:+-xmap$nx}
  pnr=fpga/build/pnr-$res
  out=fpga/results/$res
  log=fpga/build/ecp5-runs-$1.log
  echo "$1: synthesis ($(date +%H:%M))"
  NXMAP=$nx fpga/synth.sh ecp5 1 2>&1 | grep -v '^Warning' > "$syn.summary"
  rm -rf "$pnr"
  echo "$1: place$([ "$place" = 1 ] || echo ' and route') ($(date +%H:%M))"
  THREADS=${THREADS:-4} CLK_MHZ=10 PLACE=$place fpga/pnr.sh "$syn/strata.json" "$pnr" > "$log" 2>&1 || true
  if [ "$place" = 1 ]; then design=$pnr/placed.json; rep=$pnr/report-placed.json; nlog=$pnr/nextpnr-placed.log
  else                      design=$pnr/routed.json; rep=$pnr/report.json;        nlog=$pnr/nextpnr.log; fi
  # the lines under the title: what this is, and how fast
  if [ "$place" = 1 ]; then
    how="placed only. $(sed -n "s/.*Max frequency for clock .*: \([0-9.]*\) MHz.*/Clock estimate after placement: \1 MHz./p" "$nlog" | tail -1)"
  else
    how="placed and routed. $(sed -n 's/^Info: \([0-9.]*\) ns logic, \([0-9.]*\) ns routing$/\1 \2/p' "$nlog" | head -1 |
         awk '{ printf "Longest path %.1f ns, %d%% of it wire.", $1 + $2, 100 * $2 / ($1 + $2) }')"
  fi
  mkdir -p "$out"
  rm -f "$out"/*
  echo "$commit" > "$out/COMMIT"
  cp "$syn.summary" "$out/summary.txt"
  cp "$syn/stat.txt" "$syn/synth.ys" "$out/"
  gzip -9 -c "$syn/yosys.log" > "$out/yosys.log.gz"
  gzip -9 -c "$syn/strata.json" > "$out/strata.json.gz"
  [ -n "$nx" ] && { diff rtl/strata_pkg.sv "$syn/strata_pkg.sv" > "$out/strata_pkg.diff" || true; }
  cp "$pnr/board.lpf" "$out/"
  [ -f "$nlog" ] && gzip -9 -c "$nlog" > "$out/$(basename "$nlog").gz"
  [ -f "$rep" ] && gzip -9 -c "$rep" > "$out/$(basename "$rep").gz"
  if [ -f "$design" ]; then
    gzip -9 -c "$design" > "$out/$(basename "$design").gz"
    # the critical path, with Yosys's long cell names cut after the signal
    [ "$place" = 1 ] || sed -n '/Critical path report for clock/,/^Info: Max frequency/p' "$nlog" |
      grep -v 'Defined in:\|cells_map_trellis\|arith_map' |
      sed -E 's/_(LUT4|CCU2C|PFUMX|L6MUX21|TRELLIS_FF|MULT18X18D)_[][A-Za-z0-9_$]*/_(\1...)/g' > "$out/timing.txt"
    $py fpga/render.py "$design" "$out/die.png" --report "$rep" --web "$out/die-1600.webp" \
      --note "nextpnr-ecp5 $npver, LFE5U-85F (CABGA381, speed 6), $what," \
      --note "$how RTL of commit $commit." > /dev/null
  fi
  echo "$1: done ($(date +%H:%M)): $(grep '^ecp5' "$out/summary.txt"); $how"
}

if [ $# -gt 0 ]; then
  for r in "$@"; do one "$r"; done
else
  one full & one xmap12 & one xmap4 &
  wait
fi
