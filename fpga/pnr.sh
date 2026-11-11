#!/bin/sh
# Places and routes the 1-core ECP5 netlist of fpga/synth.sh with nextpnr.
#
#   fpga/pnr.sh [NETLIST.json[.gz]] [OUTDIR]
#
# Defaults: fpga/results/ecp5-1/strata.json.gz (git lfs pull), out to
# fpga/build/pnr-ecp5-1/. Target: LFE5U-85F, CABGA381, speed 6 (the
# Radiona ULX3S part), pins and the 50 MHz clock target in
# fpga/ecp5/ulx3s.lpf. nextpnr-ecp5 comes from PATH (YosysHQ's OSS CAD
# Suite: fpga/README.md says which version these results are from).
#
# Writes: pnr-in.json (the netlist with only the board ports), placed.json
# (--no-route, PLACE=1), routed.json, report.json (utilisation, Fmax,
# critical paths), nextpnr.log, and timing.txt (the log's timing part).
#
# Knobs: PLACE=1 (placement only), PLACER (default static: nextpnr's default
# HeAP cannot legalise the full core, 99.6% of the logic cells), ROUTER
# (router1, the default, or router2), CLK_MHZ (instead of 50), THREADS, SEED.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
in=${1:-$here/fpga/results/ecp5-1/strata.json.gz}
out=${2:-$here/fpga/build/pnr-ecp5-1}
# the OSS CAD Suite unpacked under build/ (fpga/README.md), if it is there
[ -x "$here/build/tools/oss-cad-suite/bin/nextpnr-ecp5" ] && PATH=$here/build/tools/oss-cad-suite/bin:$PATH
threads=${THREADS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}
seed=${SEED:-1}
mkdir -p "$out"

# The external system-memory port is unused with T3_EXT = 0 (system memory
# is the block-RAM stand-in): a board top has no such pins, so drop it.
# (Only the ports go; no cell is removed: the stat is in strip-stat.txt.)
if [ ! -s "$out/pnr-in.json" ] || [ "$in" -nt "$out/pnr-in.json" ]; then
  case $in in
    *.gz) gunzip -c "$in" > "$out/synth.json"; in=$out/synth.json ;;
  esac
  yosys -q -p "read_json $in; delete -port */ext_t3_*; opt_clean; tee -o $out/strip-stat.txt stat;
               write_json $out/pnr-in.json" > "$out/strip.log"
fi

# CLK_MHZ=n: another clock target than the pin file's 50 MHz
lpf=$here/fpga/ecp5/ulx3s.lpf
if [ -n "${CLK_MHZ:-}" ]; then
  sed "s/FREQUENCY PORT \"clk\" 50 MHZ;/FREQUENCY PORT \"clk\" $CLK_MHZ MHZ;/" "$lpf" > "$out/board.lpf"
  lpf=$out/board.lpf
fi
common="--85k --package CABGA381 --speed 6 --json $out/pnr-in.json --lpf $lpf
        --threads $threads --seed $seed --timing-allow-fail --detailed-timing-report --placer ${PLACER:-static} ${ROUTER:+--router $ROUTER}"
if [ "${PLACE:-0}" = 1 ]; then
  # placement only, for a quick picture (the full run places the same way
  # with the same seed and thread count)
  date > "$out/time-placed.txt"
  nextpnr-ecp5 $common --no-route --write "$out/placed.json" --report "$out/report-placed.json" \
    --log "$out/nextpnr-placed.log" >/dev/null 2>&1 || echo "nextpnr failed: $?" >> "$out/time-placed.txt"
  date >> "$out/time-placed.txt"
  exit
fi
date > "$out/time.txt"
nextpnr-ecp5 $common --write "$out/routed.json" --report "$out/report.json" \
  --log "$out/nextpnr.log" >/dev/null 2>&1 || echo "nextpnr failed: $?" >> "$out/time.txt"
date >> "$out/time.txt"
sed -n '/Critical path report/,$p' "$out/nextpnr.log" > "$out/timing.txt"
grep -E 'Max frequency|Device utilisation' -A40 "$out/nextpnr.log" | head -60
