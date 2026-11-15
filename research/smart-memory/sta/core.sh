#!/bin/sh
# One core (strata_core with its Transfer Unit, multiplier, divider, ALU and
# decoder; the Local Stores and the save table stay memories) through Yosys
# to the gates of mini.lib, then sta.py's class-to-class longest paths.
# No place and route; about a minute per run.
#
#   research/smart-memory/sta/core.sh [STREAM [LS_1P]]      (each 0, the default, or 1)
#
# Output in research/smart-memory/build/syn/s<STREAM>[p]/: stat.txt (cells and
# area in transistors), sta.txt.
set -eu
here=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$here"
st=${1:-0}
sp=${2:-0}
out=research/smart-memory/build/syn/s$st
[ "$sp" = 0 ] || out="${out}p"
mkdir -p "$out"
sv2v rtl/strata_pkg.sv rtl/strata_decode.sv rtl/strata_alu.sv rtl/strata_div.sv rtl/strata_mul.sv \
     rtl/strata_ram.sv rtl/strata_ram1.sv rtl/strata_tu.sv rtl/strata_core.sv > "$out/core.v"
cat > "$out/map.ys" <<YS
read_verilog $out/core.v
chparam -set NCORES 1 -set STREAM $st -set LS_1P $sp strata_core
hierarchy -top strata_core
proc
opt -fast
memory -nomap
select -set small t:\$mem_v2 r:SIZE<=256 %i strata_core/ctab %d
memory_map @small
opt -fast
flatten
techmap
opt -fast
abc -liberty research/smart-memory/sta/mini.lib
opt_clean
tee -o $out/stat.txt stat -liberty research/smart-memory/sta/mini.lib
write_json $out/mapped.json
YS
yosys -q -l "$out/yosys.log" "$out/map.ys" 2>&1 | grep -v 'Replacing memory' || true
python3 research/smart-memory/sta/sta.py "$out/mapped.json" strata_core 60 > "$out/sta.txt"
grep -E 'cells$|DFF|mem_v2' "$out/stat.txt"
head -1 "$out/sta.txt"
