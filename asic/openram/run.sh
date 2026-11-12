#!/bin/sh
# Generates a GF180MCU SRAM macro with OpenRAM (its gf180mcu technology: a
# 3.3 V 6T 1rw bitcell), in a python:3.12 container (it needs git): GDS, LEF, Liberty
# (analytical delays) and Verilog in build/asic/openram/<name>/.
#
#   asic/openram/run.sh WORD_BITS WORDS
#
# No DRC / LVS (OpenRAM's gf180mcu support is experimental; Magic is not in
# this container), so the macro's area is the number this gives.
set -eu
here=$(cd "$(dirname "$0")/../.." && pwd)
bits=$1
words=$2
name="gf180_sram_${bits}x${words}"
out="$here/build/asic/openram/$name"
py="$here/build/asic/openram/py"
mkdir -p "$out"
cat > "$out/config.py" <<EOF
word_size = $bits
num_words = $words
write_size = 8
num_rw_ports = 1
num_r_ports = 0
num_w_ports = 0
tech_name = "gf180mcu"
nominal_corner_only = True
process_corners = ["TT"]
supply_voltages = [3.3]
temperatures = [25]
check_lvsdrc = False
analytical_delay = True
route_supplies = "ring"
output_path = "$out"
output_name = "$name"
EOF
docker run --rm --cpus "${ASIC_THREADS:-4}" -u "$(id -u):$(id -g)" -v "$here:$here" -w "$out" \
  -e HOME=/tmp -e USER=openram -e LOGNAME=openram -e PDK_ROOT="$here/build/asic/pdk" -e PYTHONPATH="$py" python:3.12 \
  sh -c "[ -d '$py/openram' ] || pip install -q --target '$py' openram==1.2.48 numpy scipy scikit-learn;
         OPENRAM_HOME='$py/openram/compiler' OPENRAM_TECH='$py/openram/technology' \
         python3 '$py/openram/sram_compiler.py' -v config.py" \
  2>&1 | tee "$out/openram.log"
ls -la "$out"
