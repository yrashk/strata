#!/bin/sh
# The ECP5 place-and-route results and die pictures, in one command:
# synthesizes the N-core system, places and routes it with nextpnr, draws the
# die (routed and placed views), and replaces fpga/results/ecp5-N/ with what
# came out, with the wall-clock time of every stage in times.txt.
#
#   fpga/ecp5-runs.sh 1 2         # 1 and 2 cores, in parallel
#   fpga/ecp5-runs.sh render 1    # only redraw, from the committed data
#                                 # (fpga/results/ecp5-1/die-data.json.gz)
#
# The flow: fpga/synth.sh ecp5 N, fpga/pnr.sh (LFE5U-85F CABGA381, static
# placer, router1, a 10 MHz target, THREADS=4 by default so that two runs
# take under half of an 18-core machine), fpga/render.py. NXMAP=n sets the
# overlay map entries (default 16). Needs Yosys, sv2v, nextpnr-ecp5 (the OSS
# CAD Suite under build/tools/ is used when it is there) and Python with
# numpy and Pillow (build/venv when it is there); fpga/README.md has the
# setup. COMMIT in each results directory is the last commit that changed
# rtl/ ("+dirty" when rtl/ had uncommitted changes).
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here"
py=python3
[ -x build/venv/bin/python ] && py=build/venv/bin/python
nextpnr=nextpnr-ecp5
[ -x build/tools/oss-cad-suite/bin/nextpnr-ecp5 ] && nextpnr=build/tools/oss-cad-suite/bin/nextpnr-ecp5
npver=$($nextpnr --version 2>&1 | sed -n 's/.*Version nextpnr-\([0-9.]*\).*/\1/p')
nx=${NXMAP:-}

render() {   # N: the two pictures from fpga/results/ecp5-N/die-data.json.gz
  out=fpga/results/ecp5-$1${nx:+-x$nx}
  commit=$(cat "$out/COMMIT")
  cores=$([ "$1" = 1 ] && echo "one core" || echo "$1 cores")
  fm=$(sed -n 's/.*Max frequency for clock .*: \([0-9.]*\) MHz.*/\1/p' "$out/times.txt" | tail -1)
  t0=$(date +%s)
  $py fpga/render.py "$out/die-data.json.gz" "$out/die.png" --web "$out/die-1600.webp" \
    --title "Strata: $cores on a Lattice ECP5-85F" \
    --note "nextpnr-ecp5 $npver, LFE5U-85F (CABGA381, speed 6), placed and routed; RTL of commit $commit." \
    --note "$(sed -n 's/^path: //p' "$out/times.txt")" > /dev/null
  $py fpga/render.py "$out/die-data.json.gz" "$out/die-placed.png" --web "$out/die-placed-1600.webp" --placed \
    --title "Strata: $cores on a Lattice ECP5-85F" \
    --note "nextpnr-ecp5 $npver, LFE5U-85F (CABGA381, speed 6), the placement; RTL of commit $commit." \
    --note "The cells only, without the routing." > /dev/null
  echo "render: $(( $(date +%s) - t0 )) s (both pictures)"
}

one() {   # N
  n=$1
  syn=fpga/build/ecp5-$n${nx:+-x$nx}
  pnr=fpga/build/pnr-ecp5-$n${nx:+-x$nx}
  out=fpga/results/ecp5-$n${nx:+-x$nx}
  commit=$(git log -1 --format=%h -- rtl/)
  git diff --quiet HEAD -- rtl/ || commit="$commit+dirty"
  t0=$(date +%s)
  fpga/synth.sh ecp5 "$n" $nx > "$syn.summary" 2>&1
  t1=$(date +%s)
  rm -rf "$pnr"
  THREADS=${THREADS:-4} CLK_MHZ=10 fpga/pnr.sh "$syn/strata.json" "$pnr" > "$pnr.out" 2>&1 || true
  t2=$(date +%s)
  log=$pnr/nextpnr.log
  mkdir -p "$out"
  rm -f "$out"/*
  echo "$commit" > "$out/COMMIT"
  grep -v '^Warning' "$syn.summary" > "$out/summary.txt"
  cp "$syn/stat.txt" "$syn/synth.ys" "$pnr/board.lpf" "$out/"
  gzip -9 -c "$syn/yosys.log" > "$out/yosys.log.gz"
  gzip -9 -c "$syn/strata.json" > "$out/strata.json.gz"
  gzip -9 -c "$log" > "$out/nextpnr.log.gz"
  [ -f "$pnr/report.json" ] && gzip -9 -c "$pnr/report.json" > "$out/report.json.gz"
  {
    echo "RTL of commit $commit; nextpnr-ecp5 $npver; $(date '+%Y-%m-%d')"
    echo "synthesis: $(( t1 - t0 )) s"
    echo "place and route: $(( t2 - t1 )) s (nextpnr, all of it)"
    grep -E 'Static Placer Time|SA placement time|HeAP Placer Time|Router1 time|Router2 time' "$log" | sed 's/^Info: /  /' || true
    grep -E 'TRELLIS_COMB:|TRELLIS_FF:|DP16KD:|MULT18X18D:' "$log" | head -4 | sed 's/^Info: */  /'
    grep 'Max frequency for clock' "$log" | sed 's/^Info: //' | tail -1
    grep 'ERROR' "$log" || true
    # the critical path in one line: where it starts and ends, logic and wire
    sed -n '/Critical path report for clock/,/ns routing$/p' "$log" > "$pnr/crit.txt"
    if [ -s "$pnr/crit.txt" ]; then
      from=$(sed -n 's/.*clk-to-q .* Source \(.*\)\.[A-Z0-9]*$/\1/p' "$pnr/crit.txt" | head -1 | sed -E 's/_(TRELLIS_FF|LUT4)_.*//')
      to=$(grep 'setup' "$pnr/crit.txt" | sed -E 's/.*Source (.*)\.[A-Z0-9]+$/\1/; s/_(TRELLIS_FF|LUT4)_.*//')
      tail -1 "$pnr/crit.txt" | sed -E 's/^Info: ([0-9.]+) ns logic, ([0-9.]+) ns routing$/\1 \2/' |
        awk -v f="${from##*.u_core.}" -v t="${to##*.u_core.}" '{ printf "path: Longest path %.1f ns, %d%% of it wire: from %s to %s.\n", $1+$2, 100*$2/($1+$2), f, t }'
    fi
  } > "$out/times.txt"
  # the critical path, with Yosys's long cell names cut after the signal
  sed -n '/Critical path report for clock/,/^Info: Max frequency/p' "$log" |
    grep -v 'Defined in:\|cells_map_trellis\|arith_map' |
    sed -E 's/_(LUT4|CCU2C|PFUMX|L6MUX21|TRELLIS_FF|MULT18X18D)_[][A-Za-z0-9_$]*/_(\1...)/g' > "$out/timing.txt"
  # what the pictures need, small: every cell's site and group, every
  # routed wire's group (fpga/render.py --extract)
  design=$pnr/routed.json
  [ -f "$design" ] || { design=$pnr/placed.json; }
  if [ -f "$design" ]; then
    $py fpga/render.py "$design" --extract "$out/die-data.json.gz" \
      ${pnr:+--report "$pnr/report.json"} > /dev/null
    render "$n" >> "$out/times.txt"
  fi
  echo "ecp5-$n: $(grep '^ecp5' "$out/summary.txt")"
  cat "$out/times.txt"
}

if [ "${1:-}" = render ]; then
  shift
  for n in "$@"; do render "$n"; done
  exit
fi
for n in "$@"; do one "$n" & done
wait
