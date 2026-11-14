#!/bin/sh
# test-files.sh: a disk with more files than one window of the file server's
# directory (128 entries) or one DIR message (126 records) holds.
#
#   tools/test-files.sh bootrom.stx files-test/disk.img
#
# The disk is the standard one plus 300 files tagged many (f000 .. f299, each
# holding its own name): 415 files in a directory of 1024 entries. One
# session on the emulator: ls lists all 300 (three DIR messages); files of
# several windows are read; df counts them; a file is created, one removed,
# one renamed, one tagged, and the listings and the tags' counts follow;
# then the blocks the file server wrote are read back from the device (the
# emulator does not write a disk image back, so there is no second boot).
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
cat f000
cat f127
cat f128
cat f299
df
echo hello-new > n1
cat n1
echo 2 > n2
echo 3 > n3
echo 4 > n4
rm f150
cat f150
mv f298 g298
cat g298
tag f299 extra
ls /extra
tags f299
echo after-count
ls /many | wc
echo all-count
ls / | wc
tags
hexdump 0
hexdump 27
hexdump 65
hexdump 73
EOF2
$BUILD/strata-emu -c 12 -g none -m 40000000000 -d $T/disk.img -i $T/in1 "$ROM" > $T/out1.txt 2>&1 || fail "the emulator exited with an error" out1
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

# what reached the disk (hexdump N reads block N from the device): the header's
# directory size (offset 56: 1024), the fourth new file's directory entry
# (number 418: the third of block 1 + 418 / 16), the new tag's name (the tag
# table starts at block 65) and f299's tag set (entry 414: many and extra,
# bits 10 and 11)
has out1 '^030  .. .. .. .. 41 00 00 00 00 04 00 00' "the header does not say 1024 entries, or the tag table is not at block 65"
has out1 '^040  6e 34 00 00' "the new file's directory entry is not on the disk"
has out1 '^0b0  65 78 74 72 61 00' "the new tag's name is not on the disk"
has out1 '^0f0  00 0c 00 00 00 00 00 00' "the tagged file's tag set is not on the disk"
echo "test-files: ok    415 files: listings in parts, several directory windows, create, remove, rename, tag, the blocks written"
