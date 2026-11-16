#!/bin/sh
# Runs Strata through LibreLane's Classic flow (Yosys, OpenROAD, OpenSTA,
# KLayout) on GF180MCU, in LibreLane's container.
#
#   asic/run.sh [NCORES [PERIOD_NS]]       (1, 2 or 6 cores; 40 ns by default)
#
# ASIC_LS1P=1: every core with LS_1P = 1, its two Local Stores in one
# single-port memory (asic/rtl/gf180mcu/strata_ram1.sv: the same RAM as the
# RTL's, where the default's strata_ram.sv is a stand-in). ASIC_SRAM=ocd1024
# (with ASIC_LS1P=1): that memory from the 1024 x 8 macros of
# gf180mcu_ocd_ip_sram instead of the PDK's 512 x 8. ASIC_PREP=1: stop
# before LibreLane, with the netlist source, the macro list, the placement
# and the die size in the run's directory (no container, no PDK needed);
# asic/area.sh then gives the standard-cell area with Yosys on the host.
#
# NCORES 1: one strata_core (with its Transfer Unit, multiplier, divider);
# its far bus, gift / take, granule and control ports are the chip's pins.
# NCORES > 1: strata_top with T2 (asic/mktop.py: T3 and the device block
# are outside, their bus ports pins).
#
# Environment: ASIC_THREADS (8: OpenROAD threads and the container's CPU
# quota), ASIC_STRIP_UM (each core's logic strip, um), ASIC_TAG (run tag;
# default "run"), ASIC_TO (stop after this LibreLane step), ASIC_FROM
# (continue the run ASIC_TAG from this step, e.g. OpenROAD.Floorplan after
# an ASIC_TO=OpenROAD.STAPrePNR run: synthesis is not repeated).
#
# Needs: docker, sv2v and yosys on the host (as fpga/synth.sh does), the
# LibreLane venv and the PDK (asic/README.md: build/asic/venv, asic/pdk.sh).
# Everything goes to build/asic/gf180mcu-<n>/; asic/collect.sh copies the
# reports into asic/results/.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
n=${1:-1}
period=${2:-40}
threads=${ASIC_THREADS:-8}
tag=${ASIC_TAG:-run}
image=ghcr.io/librelane/librelane:3.0.17
pdk_root="$here/build/asic/pdk"
scl=${ASIC_SCL:-gf180mcu_fd_sc_mcu7t5v0}
suffix=""
[ "$scl" = gf180mcu_fd_sc_mcu7t5v0 ] || suffix="-${scl##*_}"
ls1p=${ASIC_LS1P:-0}
sram=${ASIC_SRAM:-fd512}
[ "$ls1p" = 0 ] || suffix="$suffix-1p"
[ "$sram" = fd512 ] || suffix="$suffix-$sram"
defs=""
case $sram in
  fd512) ;;
  ocd1024) [ "$ls1p" = 1 ] || { echo "ASIC_SRAM=ocd1024 needs ASIC_LS1P=1"; exit 2; }
           defs="-DASIC_SRAM_OCD" ;;
  *) echo "unknown ASIC_SRAM $sram"; exit 2 ;;
esac
out="$here/build/asic/gf180mcu-$n$suffix"
mkdir -p "$out/src"
cd "$here"

# the RTL, through sv2v as for the FPGA, with the memories in SRAM macros:
# strata_ram (the Local Stores) is replaced by asic/rtl/gf180mcu/strata_ram.sv,
# and asic/mktop.py makes strata_core's save table, T2 and the multi-core top
python3 asic/mktop.py core rtl/strata_core.sv > "$out/src/strata_core.sv"
core="rtl/strata_pkg.sv rtl/strata_decode.sv rtl/strata_alu.sv rtl/strata_div.sv rtl/strata_mul.sv
      rtl/strata_tu.sv $out/src/strata_core.sv asic/rtl/gf180mcu/strata_ram.sv
      asic/rtl/gf180mcu/strata_ram1.sv
      asic/rtl/gf180mcu/strata_sram_w.sv"
if [ "$n" = 1 ]; then
  top=strata_core
  sv2v $defs $core > "$out/src/strata.v"
else
  top=strata_asic_top
  python3 asic/mktop.py top rtl/strata_top.sv rtl/strata_dev.sv > "$out/src/strata_asic_top.sv"
  python3 asic/mktop.py mem rtl/strata_mem.sv > "$out/src/strata_mem.sv"
  sv2v $defs $core rtl/strata_bus.sv asic/rtl/gf180mcu/strata_sram_sp.sv "$out/src/strata_mem.sv" \
       "$out/src/strata_asic_top.sv" > "$out/src/strata.v"
fi
cp asic/rtl/gf180mcu/*.bb.v asic/pdn_cfg.tcl "$out/"

# the macro instances' flattened names, for the placement
yosys -q -p "read_verilog $out/src/strata.v $out/gf180mcu_fd_ip_sram__sram512x8m8wm1.bb.v $out/gf180mcu_fd_ip_sram__sram256x8m8wm1.bb.v $out/gf180mcu_ocd_ip_sram__sram1024x8m8wm1.bb.v; chparam -set NCORES $n -set LS_1P $ls1p $top;
             hierarchy -top $top; flatten; select -write $out/macros.raw t:gf180mcu_*_ip_sram__*" \
  2>&1 | grep -v '^Warning: Replacing memory' || true
sed 's|^[^/]*/||' "$out/macros.raw" > "$out/macros.txt"
ASIC_SCL=$scl ASIC_THREADS=$threads ASIC_LS1P=$ls1p ASIC_SRAM=$sram python3 asic/mkconfig.py "$out" "$n" "$period" "$out/macros.txt"
echo "$n $ls1p $top" > "$out/prep.txt"
if [ -n "${ASIC_PREP:-}" ]; then
  echo "prepared $out (ASIC_PREP: LibreLane not run)"
  exit 0
fi
if [ "$sram" = ocd1024 ]; then
  echo "ASIC_SRAM=ocd1024: the macro's LEF, GDS and liberty are not in the PDK asic/pdk.sh fetches;"
  echo "the LibreLane run with it is not set up (asic/README.md). ASIC_PREP=1 and asic/area.sh work."
  exit 2
fi

# LibreLane in its container: the worktree at the same path, the PDK from
# build/asic/pdk, OpenROAD with threads (asic/bin/openroad-mt)
# resuming: LibreLane starts from the newest state_out.json in the run, so
# the step directories from ASIC_FROM on (an earlier, failed attempt) are
# removed first and the state is the one of the step before
resume=--overwrite
if [ -n "${ASIC_FROM:-}" ]; then
  rd="$out/runs/$tag"
  slug=$(echo "$ASIC_FROM" | tr 'A-Z.' 'a-z-')
  first=$(ls -d "$rd"/[0-9]*-"$slug" 2>/dev/null | head -1)
  if [ -n "$first" ]; then
    k=$(basename "$first" | cut -d- -f1)
    for d in "$rd"/[0-9]*-*; do
      [ "$(basename "$d" | cut -d- -f1)" -ge "$k" ] && rm -rf "$d"
    done
  fi
  resume="--from $ASIC_FROM"
fi
start=$(date +%s)
docker run --rm --cpus "$threads" -u "$(id -u):$(id -g)" \
  -v "$here:$here" -w "$out" \
  -e HOME=/tmp -e PDK_ROOT="$pdk_root" -e ASIC_THREADS="$threads" -e ASIC_OR_PRE \
  -e _OPENLANE_MAX_CORES="$threads" -e _LLN_OVERRIDE_OPENROAD="$here/asic/bin/openroad-mt" \
  "$image" \
  librelane --pdk-root "$pdk_root" --pdk gf180mcuD --scl "$scl" --run-tag "$tag" \
    $resume \
    ${ASIC_TO:+--to "$ASIC_TO"} config.json 2>&1 | tee "$out/flow.log"
echo "wall time: $(( $(date +%s) - start )) s" | tee -a "$out/flow.log"
