#!/bin/sh
# Synthesizes the Strata system with Yosys for one FPGA family and prints
# the resource summary.
#
#   fpga/synth.sh xc7|ecp5 [NCORES]
#
# System memory (T3) is external DRAM on a real board (LiteDRAM, see
# fpga/README.md); here it is a small 32 KiB block RAM placeholder so the
# rest of the system can be measured (the 64 MiB default must never reach
# synthesis as an array). The cluster store (T2) is 64 KiB and the disk a
# 128 KiB block-RAM disk, as in fpga/arty/strata_arty.sv.
set -eu
fam=$1
n=${2:-2}
here=$(cd "$(dirname "$0")/.." && pwd)
out="$here/fpga/build/$fam-$n"
mkdir -p "$out"
cd "$here"
sv2v rtl/strata_pkg.sv rtl/strata_decode.sv rtl/strata_alu.sv rtl/strata_div.sv \
     rtl/strata_ram.sv rtl/strata_uart.sv rtl/strata_tu.sv rtl/strata_bus.sv \
     rtl/strata_mem.sv rtl/strata_dev.sv rtl/strata_core.sv rtl/strata_top.sv > "$out/strata.v"
case $fam in
  xc7)  synth="synth_xilinx -family xc7 -flatten
write_json $out/strata.json" ;;
  ecp5) synth="synth_ecp5 -json $out/strata.json" ;;
  *) echo "unknown family $fam"; exit 2 ;;
esac
cat > "$out/synth.ys" <<YS
read_verilog $out/strata.v
chparam -set NCORES $n -set T3_W 4096 -set T2_W 8192 -set DISK_WORDS 16384 strata_top
hierarchy -top strata_top
$synth
tee -o $out/stat.txt stat
YS
yosys -q -l "$out/yosys.log" "$out/synth.ys" >/dev/null

# Summary: the cell counts, family totals, and the two things to look for in
# the log (latches; big memories that did not become block RAM).
grep -E '^ +[0-9]+ +[A-Z][A-Za-z0-9_]*$' "$out/stat.txt"
awk -v fam="$fam" '
  $2 ~ /^LUT[1-6]$/                  { lut += $1 }
  $2 == "CCU2C"                      { carry += $1 }
  $2 ~ /^(RAM32M|RAM64M|RAM32X1D|RAM64X1D|RAM128X1D)$/ { lutram += $1 }
  $2 == "TRELLIS_DPR16X4"            { lutram += $1 }
  $2 ~ /^(FD[RSCP]E|TRELLIS_FF)$/    { ff += $1 }
  $2 ~ /^(RAMB36E1|DP16KD|PDPW16KD)$/ { bram += $1 }
  $2 == "RAMB18E1"                   { bram18 += $1 }
  $2 ~ /^(DSP48E1|MULT18X18D)$/      { dsp += $1 }
  END {
    if (fam == "ecp5")
      printf "ecp5: %d LUT4 + %d carry cells (2 LUT4 sites each) = %d LUT4 sites, %d FF, %d DP16KD, %d MULT18X18D, %d LUT-RAM cells\n",
             lut, carry, lut + 2 * carry, ff, bram, dsp, lutram
    else
      printf "xc7: %d LUT, %d FF, %d RAMB36 (+%d RAMB18), %d DSP48E1, %d LUT-RAM cells\n",
             lut, ff, bram, bram18, dsp, lutram
  }' "$out/stat.txt"
latches=$(grep -c 'Latch inferred' "$out/yosys.log" || true)
echo "latches inferred: $latches"
echo "memories built from flip-flops (fine when small; a Local Store, T2, T3 or the disk here is a bug):"
grep 'using FF mapping for memory' "$out/yosys.log" | sed 's/.*strata_top\./  /' | sort -u
