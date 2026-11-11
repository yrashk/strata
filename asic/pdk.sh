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
"$here/build/asic/venv/bin/ciel" enable --pdk-root "$here/build/asic/pdk" --pdk-family "$fam" "$rev"
