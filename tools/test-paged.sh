#!/bin/sh
# Programs as sasm assembles a StrataOS program by default (asm/sasm.c, "Paged
# code and far data"): vi with paged code and far data, sh with paged code
# (-n), cat, wc, grep, seq and ls with both. The disk build/paged-test/disk.img
# has them in place of the usual ones (the Makefile); the vi and shell tests
# then run on it unchanged and must give the same results.
#
#   tools/test-paged.sh build/bootrom.stx build/paged-test/disk.img
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
v=$("$here/tools/test-vi.sh" "$1" "$2" 2>&1 | tail -1)
s=$("$here/tools/test-sh.sh" "$1" "$2" 2>&1 | tail -1)
case "$v" in *" OK "*) ;; *) printf '%-14s FAIL  vi: %s\n' paged "$v"; exit 1 ;; esac
case "$s" in *" OK "*) ;; *) printf '%-14s FAIL  sh: %s\n' paged "$s"; exit 1 ;; esac
printf '%-14s OK    vi (paged, far data), sh (paged) and the utilities they run pass the vi and shell tests\n' paged
