#!/bin/sh
# One core (strata_core with its Transfer Unit, multiplier, divider, ALU and
# decoder; the Local Stores and the save table stay memories) through Yosys
# to the gates of mini.lib, then sta.py: the longest paths between classes
# of start and end points, and where in the execute cycle the probes below
# are ready. No place and route; a minute or two per run.
#
#   research/pipeline/sta/core.sh [ripple|ks [TAG CUTS]]
#
# ripple: Yosys's default adders and an area-oriented mapping (as
# research/smart-memory/sta/core.sh); ks: Kogge-Stone carry trees and a
# delay-oriented mapping, closer to what a timing-driven flow builds.
# CUTS (a comma-separated list of signals, with a TAG naming the run): each
# loses its driver (Yosys cutpoint) and becomes a start point, as if it
# were a register: the paths that remain are those of a core cut into
# stages there; the arrival at the cut itself is in the run without CUTS.
# CORE: another strata_core source in place of rtl/strata_core.sv (as
# research/pipeline/exp/ writes them).
# Output in research/pipeline/build/syn/<mode>[-TAG]/.
set -eu
here=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$here"
mode=${1:-ks}
tag=${2:-}
cuts=${3:-}
out=research/pipeline/build/syn/$mode${tag:+-$tag}
cutcmd=
[ -z "$cuts" ] || cutcmd="cutpoint $(echo "$cuts" | sed 's/\([^,]*\)/w:\1/g; s/,/ /g')"
mkdir -p "$out"
# the signals whose arrival is asked for: decode, register and capability
# reads, granule lookups, the ALU, branch, load/store address and checks,
# the overlay map, transfer faults, the CSR read
probes="d,ra,rb,rc,cap_a,cd_cap,ka,kd,g_a,g_d,live_a,live_cd,xc_key,xm_inslot,xm_li,xm_lk_off,xm_lk_far,xm_i,alu_y,br_taken,maddr,mok,mload,xm_hit,xm_target,xm_link,xf_fault,amo_fault,csr_rv,pc_br,pc4,give_valid,tu_iss_valid,held,hz_rd_stall"
keep=$(echo "$probes" | sed 's/\([^,]*\)/w:\1/g; s/,/ /g')
if [ "$mode" = ks ]; then
  tm="techmap -map +/techmap.v -map +/choices/kogge-stone.v"
  abc="abc -D 1 -liberty research/pipeline/sta/mini.lib"
else
  tm="techmap"
  abc="abc -liberty research/pipeline/sta/mini.lib"
fi
sv2v rtl/strata_pkg.sv rtl/strata_decode.sv rtl/strata_alu.sv rtl/strata_div.sv rtl/strata_mul.sv \
     rtl/strata_ram.sv rtl/strata_tu.sv "${CORE:-rtl/strata_core.sv}" > "$out/core.v"
cat > "$out/map.ys" <<YS
read_verilog $out/core.v
chparam -set NCORES 1 strata_core
hierarchy -top strata_core
proc
opt -fast
memory -nomap
select -set small t:\$mem_v2 r:SIZE<=256 %i strata_core/ctab %d
memory_map @small
opt -fast
flatten
$cutcmd
setattr -set keep 1 $keep
$tm
opt -fast
$abc
opt_clean
tee -o $out/stat.txt stat -liberty research/pipeline/sta/mini.lib
write_json $out/mapped.json
YS
yosys -q -l "$out/yosys.log" "$out/map.ys" 2>&1 | grep -v 'Replacing memory' || true
python3 research/pipeline/sta/sta.py "$out/mapped.json" strata_core 60 "$probes" > "$out/sta.txt"
grep -E 'cells$|DFF' "$out/stat.txt" | head -5
sed -n '1,30p' "$out/sta.txt"
