#!/bin/sh
# The standard-cell area of a run prepared by asic/run.sh (ASIC_PREP=1 is
# enough), with Yosys on the host: synthesis to the PDK's cells, no
# LibreLane, no placement. A few minutes for one core. The numbers are a
# plain `synth; dfflibmap; abc` mapping: close to, not the same as, what
# LibreLane's synthesis step reports (asic/results/*/synth-stat.rpt).
#
#   asic/area.sh RUN_DIR        (e.g. build/asic/gf180mcu-1-1p-ocd1024)
#
# ASIC_PDK_ROOT: where the PDK is (default build/asic/pdk, asic/pdk.sh);
# ASIC_SCL: the cell library (default gf180mcu_fd_sc_mcu7t5v0).
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
out=$(cd "$1" && pwd)
pdk=${ASIC_PDK_ROOT:-$here/build/asic/pdk}
scl=${ASIC_SCL:-gf180mcu_fd_sc_mcu7t5v0}
case $scl in
  gf180mcu_as_sc_mcu7t3v3) corner=tt_025C_3v30 ;;
  *) corner=tt_025C_5v00 ;;
esac
lib="$pdk/gf180mcuD/libs.ref/$scl/lib/${scl}__$corner.lib"
[ -f "$lib" ] || { echo "no liberty file $lib (asic/pdk.sh, or ASIC_PDK_ROOT)"; exit 2; }
read -r n ls1p top < "$out/prep.txt"
cat > "$out/area.ys" <<YS
read_verilog $out/src/strata.v $out/gf180mcu_fd_ip_sram__sram512x8m8wm1.bb.v $out/gf180mcu_fd_ip_sram__sram256x8m8wm1.bb.v $out/gf180mcu_ocd_ip_sram__sram1024x8m8wm1.bb.v
chparam -set NCORES $n -set LS_1P $ls1p $top
hierarchy -top $top
synth -top $top -flatten
dfflibmap -liberty $lib
abc -liberty $lib
opt_clean
tee -o $out/area-stat.txt stat -liberty $lib
YS
yosys -q -l "$out/area.log" "$out/area.ys" 2>&1 | grep -v 'Replacing memory' || true
grep -E 'Chip area|ip_sram__|__dff' "$out/area-stat.txt" | sed 's/^ *//'
