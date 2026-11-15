#!/bin/sh
# StrataOS as a guest of StrataOS (doc/strataos.md, "StrataOS as a guest").
# Boots StrataOS on 12 cores (as `make boot`: the host's servers take cores
# 1..5, the guest the 6 empty ones), starts the guest StrataOS (`guest -p strataos 6 24`:
# the kernel and a RAM disk in one image, os/guests/strataos/) with the console
# attached to it, and checks:
#   * the guest's kernel boots on its 6 cores (its banner), its servers start
#     and its shell runs /etc/rc (the guest's motd, from its RAM disk);
#   * commands typed reach the guest's shell, and their output the console: a
#     listing of the guest's disk, a pipeline through the guest's pipe server,
#     a file written to and read back from the RAM disk, the guest's ps;
#   * Ctrl-] gives the console back to the host's shell, which sees the
#     guest's cores, and `guest stop` ends it and takes them back;
#   * a second guest StrataOS on the same cores, halted from inside: its
#     console comes back to the host's shell, and `guest stop` reclaims it;
#   * the host is unharmed: its own files, and programs on the cores the
#     guest had.
#
#   tools/test-guest-os.sh build/bootrom.stx build/disk.img
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cp "$2" "$tmp/d.img"
{
  printf 'guest -p strataos 6 24\n'
  printf 'ls /bin\n'
  printf 'seq 12 | grep 1 | wc\n'
  printf 'cp /doc/motd /tmp-note\n'
  printf 'cat /tmp-note\n'
  printf 'ps\n'
  printf '\035cores\nguest stop 240\ncores\n-c 6 hello\n-c 11 hello\n'
  printf 'guest -p strataos 6 24\nhalt\nguest stop 240\ncat /doc/motd\nhalt\n'
} >"$tmp/in.txt"
"$b/strata-emu" -c 12 -T virtual -g none -m 6000000000 -d "$tmp/d.img" -i "$tmp/in.txt" "$1" >"$tmp/o" 2>/dev/null

ok=1
check() { # $1 = what, $2 = count wanted at least, $3 = count
  if [ "$3" -lt "$2" ]; then
    printf '    missing: %s (%s, wanted %s)\n' "$1" "$3" "$2" >>"$tmp/why"
    ok=0
  fi
}
check "the guest kernel's banner, twice" 2 "$(grep -c 'microkernel): 6 cores' "$tmp/o")"
check "the guest's motd (its rc, from the RAM disk)" 2 "$(grep -c 'running as a guest of StrataOS' "$tmp/o")"
check "ls of the guest's /bin" 1 "$(grep -c 'hello' "$tmp/o")"
check "the guest's pipeline (seq | grep | wc: 4 lines)" 1 "$(grep -cE '^ *4 +4 +' "$tmp/o")"
check "the guest's ps (its servers)" 1 "$(grep -c 'tty (server)' "$tmp/o")"
check "the guest's cores, seen from the host" 6 "$(grep -c ', guest;' "$tmp/o")"
check "guest stop, twice" 2 "$(grep -c '^guest stopped' "$tmp/o")"
check "the second guest's halt: its console back" 1 "$(grep -c 'closed the console' "$tmp/o")"
check "the cores back: programs on them" 2 "$(grep -c '^Hello from Strata' "$tmp/o")"
check "the host's own files" 1 "$(grep -c 'Welcome to StrataOS 0.1' "$tmp/o")"
check "the second guest and the host halted" 2 "$(grep -c 'all cores halted' "$tmp/o")"
if [ $ok = 1 ]; then
  printf '%-14s OK    StrataOS booted as a guest (6 cores, RAM disk), ran commands on its console, was stopped, and booted and halted again; the host unharmed\n' guest-os
  exit 0
fi
printf '%-14s FAIL  StrataOS as a guest\n' guest-os
cat "$tmp/why"
grep -vE '^core [0-9]+: halt' "$tmp/o" | tail -25 | sed 's/^/    /'
exit 1
