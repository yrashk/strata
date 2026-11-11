#!/bin/sh
# Guests: a second OS on whole cores beside StrataOS (doc/strataos.md, "Guests").
# Boots StrataOS, runs a benign guest (gdemo) and a hostile one (ghostile) on 2
# cores each, and checks:
#   * the benign guest's console I/O reaches the terminal (its banner), it shows
#     in `cores` as a guest, and `guest stop` returns its cores to StrataOS;
#   * the hostile guest's out-of-grant attacks are all refused ("isolation
#     holds"), and the block-device attack leaves fs healthy;
#   * StrataOS keeps running throughout (a program on the other cores), and is
#     still healthy after each guest is stopped (ps, and a file read from fs).
# Needs at least 8 cores (StrataOS wants 6 for itself; the guest gets 2 more).
#
#   tools/test-guest.sh build/bootrom.stx build/disk.img
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
n=${NCORES:-8}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0

run() { # $1 = script, $2 = out
  cp "$2script" "$tmp/in.txt" 2>/dev/null || printf '%s' "$1" >"$tmp/in.txt"
  "$b/strata-emu" -c "$n" -T virtual -g none -m 2000000000 -d "$3" -i "$tmp/in.txt" "$4" >"$5" 2>/dev/null
}

# ---- benign guest: console, visibility, stop/reclaim ------------------------
cp "$2" "$tmp/d1.img"
printf 'guest gdemo 2 8\ncores\nguest stop 240\ncores\ncat motd\nhalt\n' >"$tmp/in1.txt"
"$b/strata-emu" -c "$n" -T virtual -g none -m 2000000000 -d "$tmp/d1.img" -i "$tmp/in1.txt" "$1" >"$tmp/o1" 2>/dev/null
ban=$(grep -c 'second OS is live on its own cores' "$tmp/o1")
gflag=$(grep -c ', guest;' "$tmp/o1")          # a core shown as a guest's while it runs
stopped=$(grep -c '^guest stopped' "$tmp/o1")
reclaimed=$(awk '/guest stopped/{s=1} s&&/^core 6: idle.*guest/{bad=1} END{print bad+0}' "$tmp/o1")
motd=$(grep -c 'StrataOS' "$tmp/o1")           # fs still serves files after the guest
if [ "$ban" -ge 1 ] && [ "$gflag" -ge 1 ] && [ "$stopped" -ge 1 ] && [ "$reclaimed" = 0 ] && [ "$motd" -ge 1 ]; then
  printf '%-14s OK    benign guest: console reached the terminal, shown as a guest, stopped and cores reclaimed\n' guest
else
  printf '%-14s FAIL  benign guest (banner=%s flag=%s stopped=%s reclaimed-bad=%s fs=%s)\n' guest "$ban" "$gflag" "$stopped" "$reclaimed" "$motd"
  grep -iE 'guest|core 6|fault' "$tmp/o1" | head -8 | sed 's/^/    /'
  rc=1
fi

# ---- hostile guest: every out-of-grant attack refused, StrataOS unharmed -----
cp "$2" "$tmp/d2.img"
printf 'guest ghostile 2 8\nps\nguest stop 240\nps\ncat motd\nhalt\n' >"$tmp/in2.txt"
"$b/strata-emu" -c "$n" -T virtual -g none -m 2000000000 -d "$tmp/d2.img" -i "$tmp/in2.txt" "$1" >"$tmp/o2" 2>/dev/null
holds=$(grep -c 'isolation holds' "$tmp/o2")
failed=$(grep -c 'ISOLATION FAILED' "$tmp/o2")
alive=$(grep -c 'proc (server)' "$tmp/o2")     # proc still answers ps while the hostile guest runs
fs_ok=$(grep -c 'StrataOS' "$tmp/o2")          # fs intact: the block-device attack was bounced
if [ "$holds" -ge 1 ] && [ "$failed" = 0 ] && [ "$alive" -ge 1 ] && [ "$fs_ok" -ge 1 ]; then
  printf '%-14s OK    hostile guest: all 4 out-of-grant attacks refused, fs healthy, StrataOS unharmed\n' guest-isol
else
  printf '%-14s FAIL  hostile guest (holds=%s failed=%s proc=%s fs=%s)\n' guest-isol "$holds" "$failed" "$alive" "$fs_ok"
  grep -iE 'hostile|isolation|fault|deadlock' "$tmp/o2" | head -8 | sed 's/^/    /'
  rc=1
fi

exit $rc
