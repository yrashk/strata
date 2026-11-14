#!/bin/sh
# A build step whose outputs are kept in a cache that every checkout of the
# repository shares: when the same step has run before on the same inputs,
# anywhere, its outputs are copied instead of built (the Verilator models and
# the Emscripten builds take the longest; doc/testing.md).
#
#   tools/build-cache.sh ID -o OUT [-o OUT ...] -i INPUT [-i INPUT ...] -- COMMAND ...
#
# ID      text that tells this step from others on the same inputs: the
#         compiler and its version, the flags, the parameters (never a path
#         of the build directory)
# OUT     a file COMMAND writes
# INPUT   a file or a directory (every file under it) that COMMAND reads
#
# The key is a hash of ID and of the inputs' names and contents, so a hit is
# a build of exactly these sources; an entry is written under a temporary
# name and renamed, so checkouts building at once do not see half of one.
# The cache is $STRATA_CACHE/builds (default ~/.cache/strata); STRATA_CACHE=
# (empty) runs COMMAND and keeps nothing. Entries not used for 30 days are
# removed.
set -u
id=$1; shift
outs=""; ins=""
while [ $# -gt 0 ]; do
  case $1 in
    -o) outs="$outs $2"; shift 2 ;;
    -i) ins="$ins $2"; shift 2 ;;
    --) shift; break ;;
    *) echo "build-cache: unexpected $1" >&2; exit 2 ;;
  esac
done
root=${STRATA_CACHE-$HOME/.cache/strata}
[ -n "$root" ] || exec "$@"
cache="$root/builds"
# shellcheck disable=SC2086
key=$( { echo "$id"; uname -sm
         find $ins -type f ! -name '.*' ! -name '*.pyc' | LC_ALL=C sort | while read -r f; do
           printf '%s %s\n' "$(shasum -a 256 <"$f" | cut -c1-40)" "$f"
         done; } | shasum -a 256 | cut -c1-40)
e="$cache/$key"
if [ -f "$e/ok" ]; then
  hit=1
  for o in $outs; do [ -f "$e/$(basename "$o")" ] || hit=0; done
  if [ $hit = 1 ]; then
    for o in $outs; do
      mkdir -p "$(dirname "$o")" && cp -p "$e/$(basename "$o")" "$o.tmp$$" && mv -f "$o.tmp$$" "$o" && touch "$o" || exit 1
    done
    touch "$e/ok"
    echo "build-cache: $outs from the cache ($key)"
    exit 0
  fi
fi
"$@" || exit $?
if mkdir -p "$cache" 2>/dev/null && mkdir "$e.tmp$$" 2>/dev/null; then
  for o in $outs; do cp -p "$o" "$e.tmp$$/" || { rm -rf "$e.tmp$$"; exit 0; }; done
  : >"$e.tmp$$/ok"
  rm -rf "$e"; mv "$e.tmp$$" "$e" 2>/dev/null || rm -rf "$e.tmp$$"
  find "$cache" -mindepth 2 -maxdepth 2 -name ok -mtime +30 2>/dev/null | while read -r f; do rm -rf "$(dirname "$f")"; done
fi
exit 0
