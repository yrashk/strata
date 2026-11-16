#!/bin/sh
# Builds and runs the experiments of research/smart-memory/exp with
# Verilator (the test benches) and Yosys (gate counts, small modules only).
#
#   research/smart-memory/exp/run.sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/exp
verilator --binary --timing -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-BLKSEQ -Wno-INITIALDLY \
  --top-module ls_unified_tb -Mdir build/exp/obj -o ls_unified_tb exp/ls_unified.sv exp/ls_unified_tb.sv \
  > build/exp/build.log 2>&1 || { grep -A8 '%Error' build/exp/build.log; exit 1; }
for a in "+jump=4 +data=4 +unit=0 +exec=2" "+jump=4 +data=4 +unit=60 +exec=2" "+jump=4 +data=4 +unit=100 +exec=2" \
         "+jump=2 +data=3 +unit=100 +exec=2" "+jump=8 +data=8 +unit=100 +exec=6"; do
  # shellcheck disable=SC2086
  build/exp/obj/ls_unified_tb $a | grep -v '^-'
done
sv2v exp/ls_unified.sv > build/exp/ls_unified.v
yosys -q -p "read_verilog build/exp/ls_unified.v; synth -top ls_unified -flatten; abc -g cmos2; opt_clean; tee -o build/exp/ls_unified.stat stat -tech cmos"
grep -E 'DFF|_NAND_|_NOR_|_NOT_|transistors' build/exp/ls_unified.stat
