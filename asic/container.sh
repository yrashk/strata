#!/bin/sh
# Runs a command in LibreLane's container, with the worktree at the same
# path and the PDK from build/asic/pdk (what asic/run.sh does for the flow).
#
#   asic/container.sh DIR COMMAND...      (DIR: the working directory)
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
dir=$1
shift
exec docker run --rm --cpus "${ASIC_THREADS:-2}" -u "$(id -u):$(id -g)" \
  -v "$here:$here" -w "$dir" -e HOME=/tmp -e PDK_ROOT="$here/build/asic/pdk" \
  ghcr.io/librelane/librelane:3.0.17 "$@"
