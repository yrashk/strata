#!/bin/sh
# test-files.sh: a disk with many files, more than one message of a listing
# holds.
#
#   tools/test-files.sh bootrom.stx files-test/disk.img
#
# The disk is the standard one plus 300 files tagged many (f000 .. f299, each
# holding its own name). One session on the emulator: ls lists all 300 (in
# parts); files from all over the listing are read; a file is created, one
# removed, one renamed, one tagged, and the listings and the tags' counts
# follow; then the disk the session left is checked from outside (stdb
# check) and holds what the session did (stdb dump).
set -e
BUILD=${BUILD:-build}
ROM=${1:-$BUILD/bootrom.stx}
DISK=${2:-$BUILD/files-test/disk.img}
T=$BUILD/test-files
mkdir -p $T
cp "$DISK" $T/disk.img
fail() { echo "test-files: FAILED: $1"; tail -30 $T/$2.txt; exit 1; }
has() { grep -q "$2" $T/$1.txt || fail "$3" $1; }

cat > $T/in1 <<'EOF2'
echo many-count
ls /many | wc
cat /many/f000
cat /many/f127
cat /many/f128
cat /many/f299
df
echo hello-new > n1
cat n1
echo 2 > n2
echo 3 > n3
echo 4 > n4
rm /many/f150
cat /many/f150
mv /many/f298 g298
cat /many/g298
tag /many/f299 extra
ls /extra
tags /many/f299
echo after-count
ls /many | wc
echo all-count
ls / | wc
tags
halt
EOF2
$BUILD/strata-emu -c 12 -g none -m 40000000000 -d $T/disk.img -w $T/after.img -i $T/in1 "$ROM" > $T/out1.txt 2>&1 || fail "the emulator exited with an error" out1
if grep -q 'fault\|panic' $T/out1.txt; then fail "a fault was reported" out1; fi
python3 - $T/out1.txt <<'PY' || fail "the first session's listings are not right" out1
import sys, re
t = open(sys.argv[1], errors='replace').read()
def after(mark):
    m = re.search(re.escape(mark) + r'\n(?:strata\$ [^\n]*\n)?\s*(\d+)\s+(\d+)\s+(\d+)', t)
    return int(m.group(1)) if m else -1
many, left, every = after('many-count'), after('after-count'), after('all-count')
print("ls /many: %d files, then %d; ls /: %d lines" % (many, left, every))
ok = many == 300 and left == 300      # 299 files and the facet line "extra/"
for want in ('f000', 'f127', 'f128', 'f299', 'hello-new', 'f298'):
    ok = ok and re.search(r'^%s$' % want, t, re.M) is not None
ok = ok and re.search(r'^many +299', t, re.M) is not None and re.search(r'^extra +1', t, re.M) is not None
sys.exit(0 if ok else 1)
PY
has out1 '^f299  *5$' "ls /extra did not list the tagged file"
has out1 'cat: .*f150' "the removed file could still be read"

# what reached the disk
$BUILD/stdb check $T/after.img > $T/check.txt 2>&1 || fail "the disk the session left fails its check" check
$BUILD/stdb dump $T/after.img > $T/dump.txt
has dump '^n4 size=2 ' "the fourth new file is not on the disk"
has dump '^f299 .*tags=.*extra' "the new tag is not on the tagged file on the disk"
has dump '^g298 size=5 ' "the renamed file is not on the disk under its new name"
if grep -q '^f150 \|^f298 ' $T/dump.txt; then fail "a removed or renamed file is still on the disk" dump; fi
echo "test-files: ok    300 files and the standard ones: listings in parts, create, remove, rename, tag; the disk checked"
