#!/bin/sh
# Renders the die of a run: asic/results/gf180mcu-N/die-{full,zoom,annotated}.png
# (full size, in Git LFS) and the web copies in site/hardware/asic/img/.
#
#   asic/render.sh N [LAYOUT]
#
# LAYOUT: the run's final GDS by default; a DEF (e.g. a placement step's)
# renders the cells' outlines instead (a preview before routing).
# The zoom is an 800 x 600 um box at the left edge of core 0's logic strip:
# the edge of its I-LS macros, the standard cells and the wiring.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
n=$1
out="$here/build/asic/gf180mcu-$n"
run="$out/runs/${ASIC_TAG:-run}"
lay=${2:-$(ls "$run"/final/gds/*.gds "$run"/*-klayout-streamout/*.klayout.gds 2>/dev/null | head -1)}
res="$here/asic/results/gf180mcu-$n"
web="$here/site/hardware/asic/img"
mkdir -p "$res" "$web"
tech="$here/build/asic/pdk/gf180mcuD/libs.tech/klayout/tech"
ref="$here/build/asic/pdk/gf180mcuD/libs.ref"

die=$(python3 -c "import json; d = json.load(open('$out/config.json'))['DIE_AREA']; print(f'{d[2]},{d[3]}')")
zoom=$(python3 "$here/asic/zoombox.py" "$out/macro_placement.cfg")
lefs="$(ls "$ref"/gf180mcu_fd_sc_mcu7t5v0/techlef/*__nom.tlef),$(ls "$ref"/gf180mcu_fd_sc_mcu7t5v0/lef/*.lef | paste -sd, -),$(ls "$ref"/gf180mcu_fd_ip_sram/lef/*.lef | paste -sd, -)"

ASIC_THREADS=2 "$here/asic/container.sh" "$out" \
  klayout -b -r "$here/asic/render.py" -rd in="$lay" -rd lyp="$tech/gf180mcu.lyp" \
    -rd lyt="$tech/gf180mcu.lyt" -rd map="$tech/gf180mcu.map" -rd lefs="$lefs" \
    -rd out="$res/die" -rd die="$die" -rd zoom="$zoom"
W=${die%,*}
H=${die#*,}
"$here/build/asic/venv/bin/python" "$here/asic/annotate.py" "$res/die-full.png" \
  "$out/macro_placement.cfg" "$W" "$H" "$res/die-annotated.png" "$web/gf180mcu-$n"
"$here/build/asic/venv/bin/python" -c "
from PIL import Image
im = Image.open('$res/die-zoom.png'); w = 1200
im.resize((w, int(im.height * w / im.width)), Image.LANCZOS).convert('P', palette=Image.ADAPTIVE, colors=256).save('$web/gf180mcu-$n-zoom.png', optimize=True)"
ls -la "$res"/die-*.png "$web"/gf180mcu-"$n"-*.png
