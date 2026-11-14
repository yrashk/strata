#!/bin/sh
# Runs every proof (formal/*.sby, each of its tasks) and prints the table of
# results; with -r only prints the table from the last runs.
#
#   formal/run.sh [-r] [NAME ...]
#
# Results and counterexample traces are in formal/build/NAME_TASK/. A failed
# assertion is reported by its line in formal/build/strata.v (the sv2v
# output); formal/vcdpeek.py prints signals of a trace.
set -u
cd "$(dirname "$0")/.."
report=0
[ "${1:-}" = -r ] && { report=1; shift; }
names=${*:-$(ls formal/*.sby | sed 's|formal/||; s|\.sby||')}
rc=0
if [ $report = 0 ]; then
  for n in $names; do
    sby -f --prefix formal/build/$n formal/$n.sby > formal/build/$n.log 2>&1 || rc=1
    grep -h 'DONE' formal/build/$n.log | sed 's/^SBY [0-9:]* //'
  done
fi
printf '\n%-10s %-7s %-6s %-6s %-8s %s\n' target task mode depth result cpu-s
for n in $names; do
  for t in $(sby --dumptasks formal/$n.sby); do
    d=formal/build/${n}_$t
    [ -f "$d/status" ] || { printf '%-10s %-7s %-6s %-6s %-8s\n' "$n" "$t" - - "not run"; continue; }
    mode=$(awk '$1 == "mode" { print $2 }' "$d/config.sby" | head -1)
    depth=$(awk '$1 == "depth" { print $2 }' "$d/config.sby" | head -1)
    set -- $(cat "$d/status")
    printf '%-10s %-7s %-6s %-6s %-8s %s\n' "$n" "$t" "$mode" "$depth" "$1" "${3:-}"
  done
done
exit $rc
