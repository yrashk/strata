#!/bin/sh
# The Forth ports of os/progs (lang/forth/progs/NAME.fs, run as `forth NAME.fs
# ARGS`) against the assembly programs, on the emulator.
#
#   tools/test-fs-progs.sh build/bootrom.stx build/disk.img     (-u: update the .out)
#
# One StrataOS session runs every case twice: as the assembly program (seq 20)
# and as the port (forth seq.fs 20: every ported program of the command line
# is replaced, pipes and lists too). A case marked x must give the same bytes
# both ways (the console's transcript, the echo of the command aside: the
# program's output, its error messages, the shell's report of its exit status)
# -- these are the programs whose output is the result: cat, seq, wc, grep,
# hexdump, ls, the files cp, mv, tag write... A case marked o is a status
# report whose layout or wording may differ (ps, cores, uptime, units): its
# port's transcript, with every number replaced by #, is compared with
# tools/test-fs-progs.out instead. Then a second session interrupts `forth
# spin.fs` with Ctrl-C (the console's break) and checks that the shell is back,
# as for spin, and a third runs ports at the Forth prompt (include seq.fs, then
# seq 5). The emulator runs with the virtual timer (-j -T virtual), so the
# sessions are deterministic.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
n=${NCORES:-8}
upd=0
if [ "${1:-}" = "-u" ]; then upd=1; shift; fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/cases.txt" <<'EOF'
# kind name: the command (as the assembly programs; the ports are put in by the script)
x seq: seq 20
x seq: seq 0
x seq: seq
x seq: seq 3000 | wc
x seq: seq 12abc
x cat: cat /doc/motd /doc/about
x cat: cat nosuch /doc/motd
x cat: seq 30 | cat
x cat: cat < /doc/about
x cat: cat /src/as.s | wc
x cat: cat /doc/about > c1; cat c1 c1; rm c1
x upper: upper < /doc/motd
x upper: seq 3 | upper
x upper: cat /src/hello.s | upper | wc
x wc: wc < /doc/motd
x wc: wc < /src/sh.s
x wc: seq 5000 | wc
x wc: wc < /doc/about
x grep: grep the < /doc/motd
x grep: grep < /doc/about
x grep: grep vi /src/hello.s < /doc/motd
x grep: seq 100 | grep 7
x grep: cat /src/sh.s | grep ecall | wc
x grep: grep nothing-like-this < /doc/motd
x hexdump: hexdump 0
x hexdump: hexdump 1
x hexdump: hexdump
x hexdump: hexdump x1
x hexdump: hexdump 99999
x pipes: seq 200 | grep 1 | upper | wc
x pipes: seq 50 > p1; wc < p1; cat p1 p1 | grep 5 | wc; rm p1
X touch: echo hello > t1
X touch: touch t2 /tt/t1 /a/-b/c
X touch: touch
X touch: ls /tt
X touch: cat t1 t2
X cp: cp t1 t3
X cp: cp -t /src/hello.s h1
X cp: cp /src/sh.s big; wc < big; rm big
X cp: cp t1 /tt/t1
X cp: cp nope z
X cp: cp a
X cp: cp a b c
X cp: tags /src/h1 /demo/h1 t3 nope
X cp: wc < /demo/h1
X mv: mv /src/h1 /demo/
X mv: mv /demo/h1 h2
X mv: mv nope z
X mv: mv a
X ls: ls /demo
X ls: ls -t /tt
X ls: ls /nope
X ls: ls /demo/h2
X ls: ls -t /demo/h2
X ls: ls /src/-demo
X tag: tag t3 tg1 tg2
X tag: tag t3 bad/tag
X tag: tag nope tg1
X tag: tag t3
X tag: tags /tg1/t3
X tag: untag /tg2/t3 tg1
X tag: tags /tg2/t3
X tag: retag /tg2/t3 tg3 tg4
X tag: tags /tg4/t3
X tag: retag /tg3/t3
X tag: tags t3
X tags: tags
X rm: rm t1 t2 t3 /demo/h2 /tt/t1 nope
X rm: rm
X rm: ls
x df: df
x devs: devs
x spin: spin 5 z
x spin: spin 3
o uptime: uptime
o free: free
o cores: cores
o ps: ps
o sched: sched
o sched: sched 3ms
o sched: sched 2000
o sched: sched 1x
o sched: sched 1s
o units: units
EOF
python3 - "$tmp" <<'PY'
import re, sys
tmp = sys.argv[1]
ports = "cat cores cp devs df free grep hexdump ls mv ps rm sched seq spin tag tags touch units untag retag upper uptime wc".split()
def to_fs(cmd):
    out, start = [], True
    for tok in re.split(r"(\s+)", cmd):
        if start and tok in ports:
            tok = "forth %s.fs" % tok
        if tok.strip():
            start = tok in ("|", ";", "&&", "||")
        out.append(tok)
    return "".join(out)
cases = []
for line in open(tmp + "/cases.txt"):
    if line.startswith("#") or not line.strip():
        continue
    kind, rest = line.split(" ", 1)
    name, cmd = rest.split(":", 1)
    if kind == "X" and cases and cases[-1][0] == "X":   # a sequence: its commands one after
        cases[-1] = ("X", cases[-1][1] + " " + name, cases[-1][2] + "\n" + cmd.strip())  # the other
    else:
        cases.append((kind, name, cmd.strip()))
with open(tmp + "/in.txt", "w") as f:
    for i, (kind, name, cmd) in enumerate(cases):
        fs = "\n".join(to_fs(c) for c in cmd.split("\n"))
        f.write("echo '==== %d s'\n%s\necho '==== %d f'\n%s\n" % (i, cmd, i, fs))
    f.write("echo '==== end'\n\x04")
open(tmp + "/cases.py", "w").write(repr(cases))
PY
cp "$2" "$tmp/d.img"
"$b/strata-emu" -c "$n" -j -T virtual -g none -m 20000000000 -d "$tmp/d.img" -i "$tmp/in.txt" "$1" >"$tmp/raw.out" 2>"$tmp/err.out"
if [ -n "${FSP_KEEP:-}" ]; then cp "$tmp/raw.out" "$tmp/in.txt" "$FSP_KEEP"; fi
python3 - "$tmp" "$here/tools/test-fs-progs.out" "$upd" <<'PY'
import re, sys
tmp, expf, upd = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
cases = eval(open(tmp + "/cases.py").read())
raw = open(tmp + "/raw.out", "rb").read().decode("latin-1").replace("\r", "")
parts = re.split(r"^.*?==== (\d+|end) ?([sf]?)\n", raw, flags=re.M)
sec = {}
for i in range(1, len(parts) - 1, 3):
    sec[(parts[i], parts[i + 1])] = parts[i + 2]
def clean(t):
    lines = t.split("\n")
    lines = [l for l in lines if not re.search(r"strata\$ echo '==== ", l)]
    t = "\n".join(lines)
    return re.sub(r"forth (\w+)\.fs", r"\1", t)
fails, own = [], []
for i, (kind, name, cmd) in enumerate(cases):
    s, f = sec.get((str(i), "s")), sec.get((str(i), "f"))
    if s is None or f is None:
        fails.append("%s: %s: no output (the session ended early)" % (name, cmd)); continue
    s, f = clean(s), clean(f)
    if "***" in f:
        fails.append("%s: %s: a Forth error:\n%s" % (name, cmd, f))
    if kind in "xX" and s != f:
        fails.append("%s: %s:\n--- %s\n%s--- the port\n%s" % (name, cmd, cmd, s, f))
    if kind == "o":
        # numbers masked, and the padding with them: a count with one digit more or less moves a column
        own.append("==== " + cmd + "\n" + re.sub(r" +", " ", re.sub(r"\d+", "#", f)))
own = "".join(own)
if upd:
    open(expf, "w").write(own); print("tools/test-fs-progs.out updated")
elif own != open(expf).read():
    import difflib
    fails.append("the status reports differ from tools/test-fs-progs.out:\n" +
                 "".join(difflib.unified_diff(open(expf).read().splitlines(1), own.splitlines(1))))
if "all cores halted" not in raw:
    fails.append("the session did not end")
for x in fails[:12]:
    print(x)
if fails:
    print("%-14s FAIL  %d of %d cases" % ("test-fs-progs", len(fails), len(cases))); sys.exit(1)
print("%-14s OK    %d cases: %d with the same output as the assembly program, %d status reports" %
      ("test-fs-progs", len(cases), sum(k in "xX" for k, _, _ in cases), sum(k == "o" for k, _, _ in cases)))
PY
st=$?
[ $st -eq 0 ] || exit 1
[ $upd -eq 1 ] && exit 0
# Ctrl-C: the console's break while `forth spin.fs` (forever) runs: killed, as spin is
printf 'forth spin.fs\necho after-break\n\004' >"$tmp/in2.txt"
cp "$2" "$tmp/d2.img"
"$b/strata-emu" -c "$n" -j -T virtual -g none -b ${FSP_BREAK:-40000000} -m 4000000000 -d "$tmp/d2.img" -i "$tmp/in2.txt" "$1" >"$tmp/raw2.out" 2>/dev/null
python3 - "$tmp/raw2.out" <<'PY' || { echo "test-fs-progs  FAIL  Ctrl-C did not end forth spin.fs"; exit 1; }
import sys
r = open(sys.argv[1], "rb").read()
s, c, a = r.find(b"forth spin.fs\n"), r.find(b"^C"), r.rfind(b"\nafter-break\n")
sys.exit(0 if 0 <= s < c < a and r[s:c].count(b".") >= 1 else 1)
PY
# at the Forth prompt: include the port, then its word (twice), and the prompt is back
printf 'forth\ninclude seq.fs\nseq 3\nseq 2\ninclude wc.fs\n.( back) cr\nbye\nseq 4 | forth -e "include wc.fs wc bye"\n\004' >"$tmp/in3.txt"
cp "$2" "$tmp/d3.img"
"$b/strata-emu" -c "$n" -j -T virtual -g none -m 4000000000 -d "$tmp/d3.img" -i "$tmp/in3.txt" "$1" >"$tmp/raw3.out" 2>/dev/null
python3 - "$tmp/raw3.out" <<'PY' || { echo "test-fs-progs  FAIL  the ports at the Forth prompt"; exit 1; }
import sys
r = open(sys.argv[1], "rb").read().decode("latin-1").replace("\r", "")
sys.exit(0 if "seq 3\n1\n2\n3\n" in r and "seq 2\n1\n2\n" in r and "back" in r and "\n4 4 8\n" in r else 1)
PY
echo "test-fs-progs  OK    Ctrl-C, the ports at the Forth prompt"
