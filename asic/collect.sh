#!/bin/sh
# Copies a finished run's reports into asic/results/gf180mcu-N/.
#
#   asic/collect.sh N
#
# summary.txt     asic/summarize.py: area by class, SRAM, clock per corner,
#                 the critical path, run time per step
# metrics.json    LibreLane's final metrics (all of them)
# synth-stat.rpt  Yosys's cell counts after synthesis
# sta/CORNER/     the post-route STA: worst paths (the first 400 lines of
#                 max.rpt and min.rpt), power, the summary
# config.json, macro_placement.cfg   what the run was given
# The pictures are asic/render.sh's (die-full.png, die-zoom.png,
# die-annotated.png; Git LFS).
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
n=$1
out="$here/build/asic/gf180mcu-$n"
run="$out/runs/${ASIC_TAG:-run}"
res="$here/asic/results/gf180mcu-$n"
mkdir -p "$res"
period=$(python3 -c "import json; print(json.load(open('$out/config.json'))['CLOCK_PERIOD'])")
python3 "$here/asic/summarize.py" "$run" "$period" > "$res/summary.txt"
cp "$run/final/metrics.json" "$res/metrics.json"
cp "$out/config.json" "$out/macro_placement.cfg" "$res/"
cp "$run"/*-yosys-synthesis/reports/stat.rpt "$res/synth-stat.rpt"
sta=$(ls -d "$run"/*-openroad-stapostpnr | tail -1)
for c in "$sta"/*/; do
  name=$(basename "$c")
  mkdir -p "$res/sta/$name"
  head -400 "$c/max.rpt" > "$res/sta/$name/max.rpt"
  head -400 "$c/min.rpt" > "$res/sta/$name/min.rpt"
  cp "$c/power.rpt" "$res/sta/$name/" 2>/dev/null || true
done
cp "$sta/summary.rpt" "$res/sta/" 2>/dev/null || true
cat "$res/summary.txt"
