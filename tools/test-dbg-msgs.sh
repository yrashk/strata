#!/bin/sh
# test-dbg-msgs.sh: StrataOS's messages under the debugger (strata-dbg's
# msgs, msg and msgs stats; the engine's msgs, msg, msgstats), on a
# deterministic run (-j -T virtual).
#
#   tools/test-dbg-msgs.sh bootrom.stx disk.img      (-v first: show the transcript)
#
# The shell runs `ls /etc`, `cat /doc/motd`, the pipeline `seq 3 | wc` and
# then `ps`, where a breakpoint stops the machine. Every request must be
# there with the right sender, receiver and names (from os/spec/, through
# build/msgops.txt), paired with its reply: the shell's SPAWN to proc,
# proc's CREATE to the kernel and the kernel's EXITED back, the QUERY of ls,
# cat's OPEN and READ of the file (the bytes it read), the pipe made by the
# shell, seq's WRITE into it and wc's READ of the same bytes. Then live mode
# while the machine runs on; going back in time drops the messages after the
# new position, and running forward again to the same stop gives the same
# ones.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
verbose=0
if [ "${1:-}" = "-v" ]; then verbose=1; shift; fi
b="$here/${BUILD:-build}"
rom=${1:-$b/bootrom.stx}
disk=${2:-$b/disk.img}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$disk" "$tmp/disk.img"
cat > "$tmp/cmd" <<'EOF'
break process ps
input ls /etc\ncat /doc/motd\nseq 3 | wc\nps\n
continue
msgs 400
msgs stats
msg op PIPE
msgs 3 server pipe
reverse-step-round 20000
msgs 1
continue
msgs 1
delete
msgs live server proc
continue
quit
EOF
# (the last continue runs ps to its end and the machine waits at the prompt: a
# pause ends it, after a few seconds; a session that hangs is ended after 300 s)
( sleep 300 & echo $! > "$tmp/guard"; wait; pkill -f "strata-emu.*$tmp/disk.img" ) 2>/dev/null &
(
  cat "$tmp/cmd" | head -n 14
  sleep 3
  printf 'quit\n'
) | "$b/strata-dbg" -c 8 -j -T virtual -g none -d "$tmp/disk.img" --os "$b" "$rom" > "$tmp/out" 2>&1 &
dpid=$!
# the last `continue` never stops by itself: interrupt it (as Ctrl-C does)
sleep 1
while kill -0 $dpid 2>/dev/null && ! grep -q "while the machine runs: StrataOS" "$tmp/out"; do sleep 1; done
# (until ps has ended: the kernel's EXITED for it is printed; 60 s at most)
n=0
while [ $n -lt 60 ] && kill -0 $dpid 2>/dev/null && ! sed -n '/while the machine runs: StrataOS/,$p' "$tmp/out" | grep -q "EXITED 7"; do
  sleep 1; n=$((n + 1))
done
sleep 1
pkill -INT -f "strata-dbg -c 8 -j -T virtual -g none -d $tmp/disk.img" 2>/dev/null
wait $dpid
kill "$(cat "$tmp/guard")" 2>/dev/null
[ $verbose = 1 ] && cat "$tmp/out"

python3 - "$tmp/out" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
bad = []
def need(what, pat, text=t):
    if not re.search(pat, text, re.M):
        bad.append(what)
# the listing at the stop (`msgs 400`): a request line, then its reply line
listing = t[t.find("(sdb) msgs 400"):t.find("(sdb) msgs stats")]
rows = re.findall(r"^#(\d+) +t (\d+) +core (\d+)->(\d+) +(\S+) +-> (\S+) +(\S+) (\d+) +h (-?\d+) len (-?\d+) mode (-?\d+)(.*)\n +=> (.*)$", listing, re.M)
if len(rows) < 60:
    bad.append("the listing (%d messages)" % len(rows))
def find(frm, to, op, data=None, reply=None):
    for r in rows:
        if re.fullmatch(frm, r[4]) and re.fullmatch(to, r[5]) and r[6] == op and \
           (data is None or re.search(data, r[11])) and (reply is None or re.search(reply, r[12])):
            return r
    bad.append("%s -> %s %s%s%s" % (frm, to, op, " " + data if data else "", " => " + reply if reply else ""))
find(r"sh\(\d+\)", r"proc\(1\)", "SPAWN", None, r"^\d+ ")
find(r"proc\(1\)", "kernel", "CREATE", r"pid=\d+", r"^0 +first_core=\d")
find(r"proc\(1\)", "kernel", "MEMORY", None, r"^0 +base=0x[0-9a-f]+ size=0x100000 +\+live t3")
find(r"proc\(1\)", r"fs\(3\)", "LOADIMG", r'path="ls"', r'"/bin/ls"')
find(r"kernel\(0\)", r"proc\(1\)", "EXITED", None, r"^0 ")
find(r"ls\(\d+\)", r"fs\(3\)", "QUERY", r'path="/etc"', r"^\d+ ")
find(r"cat\(\d+\)", r"fs\(3\)", "OPEN", r'path="/doc/motd"', r"^1 ")
find(r"cat\(\d+\)", r"fs\(3\)", "READ", None, r'^\d+ +bytes_read="')
find(r"cat\(\d+\)", r"tty\(4\)", "WRITE", r'bytes_to_write="')
find(r"sh\(\d+\)", r"pipe\(5\)", "PIPE", None, r"^\d+ ")
find(r"seq\(\d+\)", r"pipe\(5\)", "WRITE", r'bytes_to_write="1\\n2\\n3\\n"', r"^6 ")
find(r"wc\(\d+\)", r"pipe\(5\)", "READ", None, r'^6 +bytes_read="1\\n2\\n3\\n"')
find(r"sh\(\d+\)", r"tty\(4\)", "READ", None, r'^1 +bytes_read="p"')
# every reply comes from the receiver (or the kernel), after its request
for r in rows:
    m = re.search(r"\[(\S+)\(\d+\) core (\d+), (\d+) ticks", r[12])
    if m and r[5] != "kernel" and not r[5].startswith(m.group(1) + "("):
        bad.append("#%s: the reply comes from %s, not %s" % (r[0], m.group(1), r[5]))
waiting = [r for r in rows if r[12].startswith("(waiting)")]
if len(waiting) > 2:
    bad.append("%d requests without a reply" % len(waiting))
# the summary, the whole message, filters
need("stats", r"^pipe +PIPE 8 +1 +1 +0 ")
need("stats: tty READ", r"^tty +READ 1 +\d+ +\d+ +0 ")
need("msg op PIPE", r"^request: buffer t3 0x[0-9a-f]+, 0 data bytes kept")
need("msg op PIPE: the header", r"^  0000  08 00 00 00 00 00 00 00 ")
need("msg op PIPE: the reply", r"^reply: tick \d+")
need("msgs server pipe", r"\(3 shown; ")
# time travel: fewer messages back there, the same ones again at the same stop
counts = [int(n) for n in re.findall(r"\(\d+ shown; (\d+) messages since power-on", t)]
if len(counts) < 4 or not (counts[2] < counts[0] and counts[3] == counts[0]):
    bad.append("messages through time travel: %s" % counts)
# live, while ps runs to its end: the kernel's EXITED for it, and the reply to
# the shell's SPAWN of it (listed before the stop, answered since)
need("live", r"while the machine runs: StrataOS's messages are shown every 250 ms")
live = t[t.find("while the machine runs: StrataOS"):]
need("live: EXITED", r"kernel\(0\) +-> proc\(1\) +EXITED 7", live)
need("live: the SPAWN's reply", r"^#\d+ +<= \d+ +\[proc\(1\) core 1", live)
if bad:
    print("test-dbg-msgs: FAILED: " + "; ".join(bad))
    sys.exit(1)
print("test-dbg-msgs: ok    %d messages listed, paired with their replies; stats, msg, live, time travel" % len(rows))
PY
