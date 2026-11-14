#!/bin/sh
# The store under StrataOS: what the file server leaves on the disk, on the
# emulator, checked from outside with build/stdb.
#
#   tools/test-store.sh build/bootrom.stx build/disk.img
#
# 1. A session creates, appends to, copies, tags, renames and deletes files,
#    among them one of several hundred KiB; the emulator writes the disk back
#    (-w). The image must pass `stdb check` (every page of every tree, the
#    free space, the file system's own invariants), and `stdb dump` must show
#    the files the session left, with the right bytes.
# 2. The machine boots again from that image and reads the files back; `db`
#    (os/progs/db.s) reads the trees from the disk and shows them.
# 3. Power cuts. A session that only creates files is run again and again
#    with the disk's power cut after N written blocks (--disk-cut), for N
#    over the whole session, half of the runs with a volatile write cache
#    that loses blocks not yet flushed (--disk-cache). Every image left must
#    pass the check; every file of the original disk must be there unchanged;
#    each file of the session must be absent, empty (made, not yet closed)
#    or whole; and the machine must boot from it and list its files.
# 4. Snapshots (`snap`): two are taken while files change; each shows the
#    files of its time through /@NAME/ paths and cannot be written; the disk
#    with them passes the check; after a second boot they still read, and
#    deleting them gives their space back.
# 5. `snap -r` restores a snapshot: the files, names and tags are again
#    what they were, and the pages are accounted for.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
n=${NCORES:-8}
rom=$1
disk=$2
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "test-store: $*" >&2; exit 1; }
run() { # run INPUT DISK OUT [emulator options]: a session; the console's transcript -> $tmp/out.txt
  in=$1; d=$2; shift 2
  "$b/strata-emu" -c "$n" -j -T virtual -g none -m 4000000000 -d "$d" -i "$in" "$@" "$rom" >"$tmp/out.txt" 2>"$tmp/err.txt"
}

# ---- 1. a session that changes files ---------------------------------------------------
cat >"$tmp/s1.txt" <<'EOF'
echo hello > /notes/a
echo more >> a
seq 40000 > /nums/big
seq 300 > mid
cp motd m2
tag m2 x y
mv m2 /keep/m3
cp about gone
rm gone
echo first > twice
echo second > twice
touch /notes/empty
halt
EOF
run "$tmp/s1.txt" "$disk" -w "$tmp/d1.img" || fail "the first session did not end well"
"$b/stdb" check "$tmp/d1.img" >"$tmp/check.txt" 2>&1 || { cat "$tmp/check.txt" >&2; fail "the disk the session left fails its check"; }
"$b/stdb" dump "$tmp/d1.img" >"$tmp/dump1.txt"
"$b/stdb" dump "$disk" >"$tmp/dump0.txt"
python3 - "$tmp" <<'EOF' || exit 1
import sys, hashlib
tmp = sys.argv[1]
def fnv(b):
    h = 0xCBF29CE484222325
    for c in b: h = ((h ^ c) * 0x100000001B3) & (2**64 - 1)
    return "%016x" % h
def dump(p):
    d = {}
    for l in open(p):
        w = l.split()
        d[w[0]] = dict(x.split("=", 1) if "=" in x else (x, "") for x in w[1:])
    return d
d0, d1 = dump(tmp + "/dump0.txt"), dump(tmp + "/dump1.txt")
def want(name, data, tags):
    e = d1.get(name)
    assert e, "no file " + name
    assert int(e["size"]) == len(data), "%s: size %s, not %d" % (name, e["size"], len(data))
    assert e["sum"] == fnv(data), name + ": other bytes"
    assert e.get("tags", "") == tags, "%s: tags %s, not %s" % (name, e.get("tags", ""), tags)
big = "".join("%d\n" % i for i in range(1, 40001)).encode()
want("a", b"hello\nmore\n", "notes")
want("big", big, "nums")
want("mid", "".join("%d\n" % i for i in range(1, 301)).encode(), "")
want("twice", b"second\n", "")
want("empty", b"", "notes")
assert "gone" not in d1 and "m2" not in d1
assert d1["m3"]["sum"] == d0["motd"]["sum"] and d1["m3"]["tags"] == "keep,x,y", d1["m3"]
for k, v in d0.items():
    assert d1.get(k) == v, "a file of the original disk changed: " + k
assert set(d1) - set(d0) == {"a", "big", "mid", "twice", "empty", "m3"}, set(d1) - set(d0)
EOF
"$b/stdb" get "$tmp/d1.img" big | cmp -s - "$tmp/big.txt" 2>/dev/null
echo "test-store: the session's disk: $(sed 's/^[^:]*: //' "$tmp/check.txt")"

# ---- 2. the machine boots from it again --------------------------------------------------
cat >"$tmp/s2.txt" <<'EOF'
cat a
cat twice
tags m3
seq 40000 > again
db
db fs/name
db -p 3
halt
EOF
run "$tmp/s2.txt" "$tmp/d1.img" -w "$tmp/d2.img" || fail "the second boot did not end well"
grep -q '^hello$' "$tmp/out.txt" && grep -q '^more$' "$tmp/out.txt" && grep -q '^second$' "$tmp/out.txt" ||
  { cat "$tmp/out.txt" >&2; fail "the second boot does not read what the first wrote"; }
"$b/stdb" check "$tmp/d2.img" >/dev/null 2>"$tmp/check.txt" || { cat "$tmp/check.txt" >&2; fail "the disk after the second boot fails its check"; }
"$b/stdb" get "$tmp/d2.img" big >"$tmp/big1"
"$b/stdb" get "$tmp/d2.img" again >"$tmp/big2"
cmp -s "$tmp/big1" "$tmp/big2" || fail "a file written on the second boot differs from the first's"
[ "$(wc -l <"$tmp/big1")" -eq 40000 ] || fail "the large file does not have its lines"
# `db` walks the trees from the disk, below the file system: the trees are
# listed, the names tree holds the first session's files, and a page that is
# not a tree page is refused
grep -q '^fs/obj  *root page [0-9]*, height [0-9]' "$tmp/out.txt" && grep -q '^catalog  *root page' "$tmp/out.txt" ||
  { cat "$tmp/out.txt" >&2; fail "db does not list the trees"; }
for f in a big mid twice empty m3 motd; do
  grep -q "^\"$f\" = " "$tmp/out.txt" || fail "db fs/name does not show $f"
done
names=$(grep -c '^"[^"]*" = "' "$tmp/out.txt")
files=$("$b/stdb" dump "$tmp/d1.img" | wc -l | tr -d ' ')
[ "$names" -eq $((files + 1)) ] || fail "db fs/name shows $names names: not the first session's $files files and one more"
grep -q '^db: not a tree page: 3' "$tmp/err.txt" "$tmp/out.txt" || fail "db -p took a page that is not a tree's"
echo "test-store: read back after a second boot; db walks the trees"


# ---- 3. power cuts -----------------------------------------------------------------------
cat >"$tmp/s3.txt" <<'EOF'
seq 3000 > /cut/c1
echo one > /cut/c2
seq 20000 > c3
cp motd c4
tag c4 cut
echo two > c2
halt
EOF
run "$tmp/s3.txt" "$disk" -w "$tmp/ref.img" || fail "the cut session did not end well"
"$b/stdb" dump "$tmp/ref.img" >"$tmp/ref.txt"
cat >"$tmp/s4.txt" <<'EOF'
ls /cut
halt
EOF
cuts=0
ncut=1
step=${CUT_STEP:-13}
while :; do
  cache=""
  [ $((ncut % 2)) -eq 0 ] && cache="--disk-cache $ncut"
  # shellcheck disable=SC2086
  run "$tmp/s3.txt" "$disk" -w "$tmp/c.img" --disk-cut "$ncut" $cache
  grep -q 'power cut' "$tmp/err.txt" || break # the session ended before the cut
  "$b/stdb" check "$tmp/c.img" >/dev/null 2>"$tmp/check.txt" ||
    { cat "$tmp/check.txt" >&2; fail "cut after $ncut blocks ($cache): the disk fails its check"; }
  "$b/stdb" dump "$tmp/c.img" >"$tmp/c.txt"
  python3 - "$tmp" "$ncut" <<'EOF' || exit 1
import sys
tmp, n = sys.argv[1], sys.argv[2]
def dump(p):
    d = {}
    for l in open(p):
        w = l.split()
        d[w[0]] = " ".join(w[1:])
    return d
d0, ref, c = dump(tmp + "/dump0.txt"), dump(tmp + "/ref.txt"), dump(tmp + "/c.txt")
for k, v in d0.items():
    assert c.get(k) == v, "cut after %s blocks: a file of the original disk changed: %s" % (n, k)
one = "size=4 sum=" # c2 holds "one\n" before it holds "two\n"
for k, v in c.items():
    if k in d0: continue
    assert k in ref, "cut after %s blocks: a file from nowhere: %s" % (n, k)
    size = v.split()[0]
    whole = v.split()[:2] == ref[k].split()[:2]
    assert whole or size == "size=0" or (k == "c2" and size == "size=4"), \
        "cut after %s blocks: %s is neither absent, empty nor whole: %s" % (n, k, v)
EOF
  if [ $((cuts % 8)) -eq 0 ]; then # and the machine boots from it
    run "$tmp/s4.txt" "$tmp/c.img" || fail "cut after $ncut blocks: the machine does not boot from the disk"
    grep -q 'all cores halted' "$tmp/out.txt" || fail "cut after $ncut blocks: the boot did not reach the shell"
  fi
  cuts=$((cuts + 1))
  ncut=$((ncut + step))
done
[ "$cuts" -ge 10 ] || fail "only $cuts cuts fell inside the session"
echo "test-store: $cuts power cuts (every $step blocks, every other one with a write cache losing blocks): each disk passes its check and holds whole files"
# ---- 4. snapshots ------------------------------------------------------------------------
cat >"$tmp/s5.txt" <<'EOF'
echo one > /notes/v
seq 30000 > keep
snap first
echo two > v
rm keep
seq 9000 > other
snap second
echo three > v
tag v late
cat /@first/v
cat /@second/v
cat v
wc < /@first/keep
ls /@first/notes
tags /@first/v
echo x > /@first/w
rm /@first/v
snap
df
halt
EOF
run "$tmp/s5.txt" "$disk" -w "$tmp/sn.img" || fail "the snapshot session did not end well"
python3 - "$tmp/out.txt" <<'EOF' || { cat "$tmp/out.txt" >&2; exit 1; }
import sys
t = open(sys.argv[1], errors="replace").read()
def after(cmd, n=1):
    i = t.index("$ " + cmd + "\n") + len(cmd) + 3
    return t[i:].split("\n")[:n]
assert after("cat /@first/v") == ["one"], "the first snapshot's file"
assert after("cat /@second/v") == ["two"], "the second snapshot's file"
assert after("cat v") == ["three"], "the live file"
assert after("wc < /@first/keep")[0].split()[0] == "30000", "a file deleted since, read from its snapshot"
assert after("tags /@first/v")[0].rstrip().endswith("notes"), "a snapshot shows the tags of its time"
assert "cannot open /@first/w" in t and "no such file: /@first/v" in t, "a snapshot was written"
assert after("snap", 2)[0].startswith("first ") and after("snap", 2)[1].startswith("second "), "the list"
EOF
"$b/stdb" check "$tmp/sn.img" >"$tmp/check.txt" 2>&1 || { cat "$tmp/check.txt" >&2; fail "a disk with snapshots fails its check"; }
used1=$(grep '^disk:' "$tmp/out.txt" | tail -1 | awk '{print $4}')
cat >"$tmp/s6.txt" <<'EOF'
cat /@first/v
wc < /@first/keep
snap -d first
cat /@first/v
cat /@second/v
snap -d second
snap
df
halt
EOF
run "$tmp/s6.txt" "$tmp/sn.img" -w "$tmp/sn2.img" || fail "the boot from a disk with snapshots did not end well"
grep -q '^one$' "$tmp/out.txt" && grep -q '^two$' "$tmp/out.txt" && grep -q '^30000 ' "$tmp/out.txt" && grep -q '(no snapshots)' "$tmp/out.txt" ||
  { cat "$tmp/out.txt" >&2; fail "snapshots after a second boot: read, deleted"; }
"$b/stdb" check "$tmp/sn2.img" >"$tmp/check.txt" 2>&1 || { cat "$tmp/check.txt" >&2; fail "the disk after its snapshots were deleted fails its check"; }
used2=$(grep '^disk:' "$tmp/out.txt" | tail -1 | awk '{print $4}')
[ "$used2" -lt "$used1" ] || fail "deleting the snapshots freed nothing ($used1 blocks used before, $used2 after)"
echo "test-store: snapshots: read as they were, not writable, checked on the disk, kept across a boot; deleting them freed $((used1 - used2)) blocks"
# ---- 5. restoring a snapshot -------------------------------------------------------------
# A session stops right after taking a snapshot; another goes on changing
# files (and takes a second snapshot), then restores the first: its disk
# must hold exactly what the first session's does, pass the check with the
# snapshots on it and after they are deleted, and the second snapshot must
# still read.
printf 'echo one > /notes/a\nseq 2000 > nums\nsnap s1\nhalt\n' >"$tmp/r0.txt"
run "$tmp/r0.txt" "$disk" -w "$tmp/r0.img" || fail "the session before the restore did not end well"
cat >"$tmp/r1.txt" <<'EOF'
echo one > /notes/a
seq 2000 > nums
snap s1
echo two > a
seq 50000 > big
rm motd
rm nums
tag a later
mv about about2
snap s2
echo three > a
snap -r s1
cat a
cat /@s2/a
ls big
snap -r nosuch
halt
EOF
run "$tmp/r1.txt" "$disk" -w "$tmp/r1.img" || fail "the restore session did not end well"
grep -q '^one$' "$tmp/out.txt" && grep -q '^two$' "$tmp/out.txt" && grep -q 'no such tag or file: big' "$tmp/out.txt" &&
  grep -q 'cannot restore' "$tmp/out.txt" || { cat "$tmp/out.txt" >&2; fail "after the restore: the old file, the later snapshot, the file made since"; }
"$b/stdb" check "$tmp/r1.img" >"$tmp/check.txt" 2>&1 || { cat "$tmp/check.txt" >&2; fail "the disk after a restore fails its check"; }
"$b/stdb" dump "$tmp/r0.img" >"$tmp/r0.dump"
"$b/stdb" dump "$tmp/r1.img" >"$tmp/r1.dump"
cmp -s "$tmp/r0.dump" "$tmp/r1.dump" || { diff "$tmp/r0.dump" "$tmp/r1.dump" | head -5 >&2; fail "the restored disk is not the disk of the snapshot"; }
printf 'snap -d s2\nsnap -d s1\ncat a\ndf\nhalt\n' >"$tmp/r2.txt"
run "$tmp/r2.txt" "$tmp/r1.img" -w "$tmp/r2.img" || fail "the boot after a restore did not end well"
"$b/stdb" check "$tmp/r2.img" >"$tmp/check.txt" 2>&1 || { cat "$tmp/check.txt" >&2; fail "the disk after the restore's snapshots were deleted fails its check"; }
"$b/stdb" dump "$tmp/r2.img" | cmp -s - "$tmp/r0.dump" || fail "deleting the snapshots after a restore changed the files"
echo "test-store: a snapshot restored: the disk holds what it held then; the later snapshot still reads; nothing is lost when both are deleted"
echo "test-store: OK"
