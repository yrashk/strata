#!/bin/sh
# Runs the tests listed in tools/tests.sh: builds what the chosen tests need
# (one `make -j`), runs them several at a time, each with its own log, and
# prints one line per test with its time, then the failures and the slowest.
# doc/testing.md describes the tiers, the selection and the caches.
#
#   tools/run-tests.sh [options] [NAME ...]    (NAME: a test, or a pattern: 'conf-*')
#     -t TIER     fast, mid or full (default full; mid includes fast, full everything);
#                 ignored when tests are named
#     -c          take the result of a test from the cache when it has passed
#                 before with exactly these inputs (the files it reads, by
#                 content: the simulators, the images, its script, its inputs)
#     -g [BASE]   only the tests that what changed can reach: the files that
#                 differ from BASE (default main: its merge base with HEAD),
#                 committed or not
#     -j N        tests at a time (default: the number of processors)
#     -l          list the chosen tests (tier, what each needs built, command)
#     -n          build nothing and run nothing: say what would run
#     -v          show the log of every test that fails
#
# Logs: $BUILD/test/NAME.log; the summary: $BUILD/test/summary.txt.
# The exit status is 0 only if every chosen test passed.
#
# The result cache is $STRATA_CACHE/results (default ~/.cache/strata, shared
# by every checkout: a key holds contents only, no paths); STRATA_CACHE=
# (empty) keeps results under $BUILD/test/cache instead. Every pass is
# recorded; only -c reads them.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here" || exit 2
B=${BUILD:-build}
N=${NCORES:-8}
MAKE=${MAKE:-make}
out="$B/test"
reg="$out/registry"
cache_root=${STRATA_CACHE-$HOME/.cache/strata}
[ -n "$cache_root" ] && rcache="$cache_root/results" || rcache="$out/cache"
export B N

now() { perl -MTime::HiRes=time -e 'printf "%.2f\n", time'; }
sha() { shasum -a 256 | cut -c1-40; }

# ---- one test (run-tests.sh --one NAME: the parent starts these) -------------
# class DIR WORD: the files an input word stands for
class() {
  case $2 in
    emu)  echo "$1/strata-emu" ;;
    rtl)  echo "$1/strata-rtl" ;;
    dbg)  echo "$1/strata-dbg" ;;
    sasm) echo "$1/sasm" ;;
    stdb) echo "$1/stdb" ;;
    stdb-test) echo "$1/stdb-test $1/stdb-many" ;;
    os)   echo "$1/bootrom.stx $1/disk.img" ;;
    ex)   echo "$1/examples/*.stx" ;;
    ex:*) echo "$1/examples/${2#ex:}.stx" ;;
    forth) echo "$1/forth.stx" ;;
    wasm) echo "$1/web/strata-emu.js $1/web/strata-emu.wasm" ;;
    wasmrtl) echo "$1/web/strata-rtl.js $1/web/strata-rtl.wasm" ;;
    *)    echo "$2" ;;
  esac
}

# inputs DIR WORDS CMD: every file the test reads, one per line: what the
# words stand for, the files named on its command line, and the files of the
# source tree its scripts name ($here/PATH, tools/NAME)
inputs() {
  d=$1
  {
    for w in $2; do
      for f in $(eval "echo $(class "$d" "$w")"); do
        if [ -d "$f" ]; then find "$f" -type f; else echo "$f"; fi
      done
    done
    eval "set -- $3"
    for w in "$@"; do
      [ -f "$w" ] || continue
      echo "$w"
      case $w in *.sh)
        grep -v '^[[:space:]]*#' "$w" | grep -oE '(\$here/|tools/)[A-Za-z0-9_./-]+' | sed 's|^\$here/||' |
          while read -r f; do [ -f "$f" ] && echo "$f"; done ;;
      esac
    done
  } | sort -u
}

one() {
  line=$(awk -F'\t' -v n="$1" '$1 == n' "$reg")
  [ -n "$line" ] || { echo "run-tests: no test $1" >&2; exit 2; }
  name=$1
  dir=$(printf '%s' "$line" | cut -f4); inp=$(printf '%s' "$line" | cut -f5); cmd=$(printf '%s' "$line" | cut -f6)
  eval "D=$dir"
  log="$out/$name.log"
  key=$( { echo "$cmd"; echo "$N"; uname -sm
           inputs "$D" "$inp" "$cmd" | while read -r f; do
             if [ -f "$f" ]; then printf '%s %s\n' "$(shasum -a 256 <"$f" | cut -c1-40)" "$f"; else echo "missing $f"; fi
           done; } | sha)
  if [ "$USE_CACHE" = 1 ] && [ -f "$rcache/$key" ]; then
    sed 1d "$rcache/$key" >"$log"; touch "$rcache/$key"
    was=$(sed -n '1s/ .*//p' "$rcache/$key")
    echo "ok cached $was 0" >"$out/$name.res"
    exit 0
  fi
  t0=$(now)
  ( export BUILD="$D" NCORES="$N"; eval "$cmd" ) >"$log" 2>&1 </dev/null
  rc=$?
  t1=$(now)
  # this shell's children: user and system seconds
  times >"$out/$name.times"
  cpu=$(sed -n '2p' "$out/$name.times" | awk '{ split($0, a, /[ms ]+/); printf "%.1f", a[1] * 60 + a[2] + a[3] * 60 + a[4] }'); rm -f "$out/$name.times"
  secs=$(echo "$t0 $t1" | awk '{ printf "%.1f", $2 - $1 }')
  if [ $rc -eq 0 ]; then
    mkdir -p "$rcache" && { echo "$secs $name"; cat "$log"; } >"$rcache/$key.$$" && mv -f "$rcache/$key.$$" "$rcache/$key"
    echo "ok run $secs $cpu" >"$out/$name.res"
    printf 'ok    %-18s %7ss  (cpu %ss)\n' "$name" "$secs" "$cpu"
  else
    echo "FAIL run $secs $cpu" >"$out/$name.res"
    printf 'FAIL  %-18s %7ss  (exit %s; log: %s)\n' "$name" "$secs" "$rc" "$log"
  fi
  exit 0
}

if [ "${1:-}" = "--one" ]; then one "$2"; fi

# ---- the options ---------------------------------------------------------------
tier=full; USE_CACHE=0; changed=0; base=main; list=0; dry=0; verbose=0
jobs=$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
while [ $# -gt 0 ]; do
  case $1 in
    -t) tier=$2; shift ;;
    -c) USE_CACHE=1 ;;
    -g) changed=1; case ${2:-} in ''|-*) ;; *) if git rev-parse -q --verify "$2^{commit}" >/dev/null 2>&1; then base=$2; shift; fi ;; esac ;;
    -j) jobs=$2; shift ;;
    -l) list=1 ;;
    -n) dry=1 ;;
    -v) verbose=1 ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*) echo "run-tests: unknown option $1" >&2; exit 2 ;;
    *) break ;;
  esac
  shift
done
export USE_CACHE
case $tier in fast) tmax=1 ;; mid) tmax=2 ;; full) tmax=3 ;; *) echo "run-tests: tier $tier (fast, mid, full)" >&2; exit 2 ;; esac
mkdir -p "$out"

# ---- the tests (tools/tests.sh calls t and skip) ------------------------------
: >"$reg.new"; : >"$out/skipped"
D='$B'
# t NAME TIER NEEDS INPUTS COMMAND
t() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$D" "$4" "$5" >>"$reg.new"; }
skip() { printf '%s\t%s\n' "$1" "$2" >>"$out/skipped"; }
. "$here/tools/tests.sh"
mv -f "$reg.new" "$reg"
dups=$(cut -f1 "$reg" | sort | uniq -d)
[ -z "$dups" ] || { echo "run-tests: tools/tests.sh names a test twice:" $dups >&2; exit 2; }

# ---- which of them -------------------------------------------------------------
sel="$out/selected"
if [ $# -gt 0 ]; then
  : >"$sel"
  for pat in "$@"; do
    found=0
    for n in $(cut -f1 "$reg"); do
      # shellcheck disable=SC2254
      case $n in $pat) echo "$n" >>"$sel"; found=1 ;; esac
    done
    [ $found = 1 ] || { echo "run-tests: no test matches $pat (run-tests.sh -l lists them)" >&2; exit 2; }
  done
  sort -u -o "$sel" "$sel"
else
  awk -F'\t' -v m=$tmax 'BEGIN { r["fast"] = 1; r["mid"] = 2; r["full"] = 3 } r[$2] <= m { print $1 }' "$reg" >"$sel"
fi

# -g: what changed, and the tests it reaches
if [ $changed = 1 ]; then
  mb=$(git merge-base HEAD "$base" 2>/dev/null) || { echo "run-tests: no merge base with $base" >&2; exit 2; }
  { git diff --name-only "$mb"; git ls-files -o --exclude-standard; } | sort -u >"$out/changed"
  # each changed file: the input words it reaches ("ALL": every test; "": none
  # by a word, though a test that names the file itself is still chosen)
  hit=""
  all=0
  while read -r f; do
    case $f in
      doc/*|site/*|fpga/*|asic/*|.github/*|*.md|LICENSE*|.gitignore|formal/*.sby|formal/props/*|formal/spec/*|formal/run.sh) w="" ;;
      formal/repro/*) w="" ;;
      rtl/*|sim/*) w="rtl wasmrtl" ;;
      emu/jit/fuzz.py) w="" ;;
      emu/*) w="emu wasm" ;;
      dbg/*) w="dbg" ;;
      web/web_rtl*) w="wasmrtl" ;;
      web/*) w="wasm" ;;
      examples/*) w="ex os" ;;
      os/*.txt) w="" ;;              # a session's input: the tests that name it
      firmware/*|os/*) w="os" ;;
      lang/forth/tests/*) w="" ;;
      lang/cc/tests/*|lang/cc/*.md) w="" ;;
      lang/cc/*) w="os" ;;
      lang/forth/*) w="os forth" ;;
      tools/stdb/*) w="stdb stdb-test os" ;;
      conformance/*) w="" ;;
      tools/test-*|tools/compare*|tools/*.out|tools/*.js|tools/net-echo.py|tools/dlsgap.s) w="" ;;
      tools/kira-*|tools/wdoom-assets.py|tools/web-code.py|tools/web-stamp.sh|tools/vi-shots.sh|tools/bench-jit.sh|tools/fs-progs-speed.sh) w="" ;;
      *) w=ALL ;;      # asm/, common/, the Makefile, the test runner, anything not listed
    esac
    [ "$w" = ALL ] && all=1
    hit="$hit $w"
  done <"$out/changed"
  if [ $all = 0 ]; then
    : >"$sel.g"
    for n in $(cat "$sel"); do
      line=$(awk -F'\t' -v n="$n" '$1 == n' "$reg")
      inp=$(printf '%s' "$line" | cut -f5); cmd=$(printf '%s' "$line" | cut -f6)
      take=0
      # (a disk or an example on its command line counts as the word)
      case "$inp $cmd" in *disk.img*) inp="$inp os" ;; esac
      case $cmd in *examples/*) inp="$inp ex" ;; esac
      for w in $inp; do
        case $w in ex:*) w=ex ;; esac
        case " $hit " in *" $w "*) take=1 ;; esac
      done
      if [ $take = 0 ]; then
        # the source files it names: on its command line, in its scripts, as inputs
        inputs "$B" "$inp" "$cmd" | grep -Fxf "$out/changed" >/dev/null && take=1
      fi
      [ $take = 1 ] && echo "$n" >>"$sel.g"
    done
    mv -f "$sel.g" "$sel"
  fi
  echo "changed since $base ($(wc -l <"$out/changed" | tr -d ' ') files): $(wc -l <"$sel" | tr -d ' ') tests chosen"
fi

if [ $list = 1 ]; then
  for n in $(cat "$sel"); do awk -F'\t' -v n="$n" '$1 == n { printf "%-18s %-5s %-34s %s\n", $1, $2, $3, $6 }' "$reg"; done
  [ -s "$out/skipped" ] && awk -F'\t' '{ printf "%-18s skipped: %s\n", $1, $2 }' "$out/skipped"
  exit 0
fi
ntests=$(wc -l <"$sel" | tr -d ' ')
if [ "$ntests" -eq 0 ]; then echo "no tests to run"; exit 0; fi

# ---- build what they need --------------------------------------------------------
needs=$(for n in $(cat "$sel"); do awk -F'\t' -v n="$n" '$1 == n { print $3 }' "$reg"; done | tr ' ' '\n' | sort -u | tr '\n' ' ')
if [ $dry = 1 ]; then
  echo "would build: $needs"; echo "would run ($ntests): $(tr '\n' ' ' <"$sel")"; exit 0
fi
T0=$(now)
if ! $MAKE -j "$jobs" BUILD="$B" NCORES="$N" $needs >"$out/build.log" 2>&1; then
  grep -v '^make\[[0-9]*\]: \(Entering\|Leaving\|Nothing\)' "$out/build.log" | tail -40
  echo "run-tests: the build failed (log: $out/build.log)"; exit 2
fi
T1=$(now)
echo "$T0 $T1" | awk -v n="$needs" '{ printf "built %s in %.1fs\n", n, $2 - $1 }'

# ---- run: the longest (by the last run here) first -------------------------------
touch "$out/times"
for n in $(cat "$sel"); do
  rm -f "$out/$n.res"
  awk -v n="$n" '$1 == n { t = $2 } END { print (t == "" ? 99999 : t), n }' "$out/times"
done | sort -rn | cut -d' ' -f2 >"$out/order"
xargs -P "$jobs" -n 1 "$here/tools/run-tests.sh" --one <"$out/order"
T2=$(now)
# results nobody has used for 30 days leave the cache
find "$rcache" -type f -mtime +30 -exec rm -f {} + 2>/dev/null

# ---- the summary -----------------------------------------------------------------
{
  nok=0; ncached=0; nfail=0; failed=""; cached=""
  : >"$out/times.run"
  for n in $(cat "$out/order"); do
    if [ -f "$out/$n.res" ]; then read -r st how secs cpu <"$out/$n.res"; else st=FAIL how=lost secs=0 cpu=0; fi
    case $st in ok) nok=$((nok + 1)) ;; *) nfail=$((nfail + 1)); failed="$failed $n" ;; esac
    if [ "$how" = cached ]; then ncached=$((ncached + 1)); cached="$cached $n"; else echo "$secs $cpu $n" >>"$out/times.run"; fi
  done
  [ -z "$cached" ] || echo "unchanged since they passed ($ncached):$cached" | fold -s -w 100
  echo
  if [ -s "$out/times.run" ]; then
    echo "slowest:"
    sort -rn "$out/times.run" | head -8 | while read -r secs cpu n; do
      was=$(awk -v n="$n" '$1 == n { print $2 }' "$out/times")
      note=""
      [ -n "$was" ] && note=$(echo "$secs $was" | awk '$1 > 1.5 * $2 && $1 - $2 > 5 { printf "  (was %ss)", $2 }')
      printf '  %-18s %7ss  cpu %7ss%s\n' "$n" "$secs" "$cpu" "$note"
    done
    # remember the times of the tests that ran
    { awk 'NR == FNR { new[$3] = $1; next } !($1 in new)' "$out/times.run" "$out/times"
      awk '{ print $3, $1 }' "$out/times.run"; } >"$out/times.new" && mv -f "$out/times.new" "$out/times"
  fi
  [ -s "$out/skipped" ] && awk -F'\t' '{ printf "skipped: %s (%s)\n", $1, $2 }' "$out/skipped"
  for n in $failed; do
    echo "FAILED: $n   ($out/$n.log)"
    if [ $verbose = 1 ]; then sed 's/^/    /' "$out/$n.log"; else tail -12 "$out/$n.log" | sed 's/^/    /'; fi
  done
  cpu=$(awk '{ s += $2 } END { printf "%.0f", s }' "$out/times.run")
  echo "$T0 $T1 $T2" | awk -v ok=$nok -v c=$ncached -v f=$nfail -v cpu="$cpu" \
    '{ printf "%d passed (%d of them unchanged, not run), %d failed; build %.1fs, tests %.1fs (cpu %ss), %.1fs in all\n", ok, c, f, $2 - $1, $3 - $2, cpu, $3 - $1 }'
  [ $nfail -eq 0 ] && echo "tests: OK" || echo "tests: FAILED"
} | tee "$out/summary.txt"
grep -q '^tests: OK$' "$out/summary.txt"
