#!/bin/sh
# Fetches the PDK that LibreLane 3.0.17 is pinned to (librelane/pdk_hashes.yaml)
# into build/asic/pdk with ciel.
#
#   asic/pdk.sh [gf180mcu|sky130]
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
fam=${1:-gf180mcu}
case $fam in
  gf180mcu) rev=54435919abffb937387ec956209f9cf5fd2dfbee ;;
  sky130)   rev=8afc8346a57fe1ab7934ba5a6056ea8b43078e71 ;;
  *) echo "unknown PDK family $fam"; exit 2 ;;
esac
shift || true
# extra arguments: libraries beyond ciel's default set, e.g. the 3.3 V
# cells: asic/pdk.sh gf180mcu gf180mcu_as_sc_mcu7t3v3 (the defaults are kept)
libs=""
if [ $# -gt 0 ] && [ "$fam" = gf180mcu ]; then
  for l in gf180mcu_fd_io gf180mcu_fd_pr gf180mcu_fd_sc_mcu7t5v0 gf180mcu_fd_sc_mcu9t5v0 gf180mcu_fd_ip_sram "$@"; do
    libs="$libs -l $l"
  done
fi
# shellcheck disable=SC2086
"$here/build/asic/venv/bin/ciel" enable --pdk-root "$here/build/asic/pdk" --pdk-family "$fam" $libs "$rev"

# The 3.3 V library's LibreLane configuration in this open_pdks build does
# not load: the PDK configuration wants <library>/no_synth.cells (it has
# synth_exclude.cells) and TIMING_VIOLATION_CORNERS (set by LibreLane's
# compatibility layer only for the older format). Both are added here, in
# the local copy of the PDK.
as3="$here/build/asic/pdk/gf180mcuD/libs.tech/openlane/gf180mcu_as_sc_mcu7t3v3"
if [ -d "$as3" ]; then
  [ -f "$as3/no_synth.cells" ] || cp "$as3/synth_exclude.cells" "$as3/no_synth.cells"
  grep -q TIMING_VIOLATION_CORNERS "$as3/config.tcl" ||
    printf '\n# asic/pdk.sh\nset ::env(TIMING_VIOLATION_CORNERS) "*tt*"\n' >> "$as3/config.tcl"
fi
