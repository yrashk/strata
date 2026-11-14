# ladder.py: the runner behind run.sh (see README.md). Run from the repository root.
import os, re, subprocess, sys, shutil

B = os.environ.get("BUILD", "build")
T = "lang/cc/tests"
OUT = os.path.join(T, "out")
BATCH = int(os.environ.get("CC_BATCH", "24"))      # tests per boot
SECS = int(os.environ.get("CC_TIMEOUT", "60"))     # host seconds per boot
PROMPT = "strata$ "
BASE = ["-t", "sys"] + [B + "/prog/" + p for p in ("proc", "dev", "fs", "tty", "pipe")] + \
       ["-t", "bin", B + "/prog/sh", B + "/prog/rm", B + "/prog/cc", "-t", "lib", B + "/cc/cc.lib"]

def tests(args, fast):
    """the tests to run: (rung, path) in ladder order"""
    all_ = []
    for rung in sorted(os.listdir(T + "/ladder")):
        d = T + "/ladder/" + rung
        if os.path.isdir(d):
            all_ += [(rung, d + "/" + f) for f in sorted(os.listdir(d)) if f.endswith(".c")]
    if fast:
        want = set(open(fast).read().split())
        all_ = [t for t in all_ if os.path.basename(t[1]) in want]
    if args:
        all_ = [t for t in all_ if any(t[0].startswith(a) or os.path.basename(t[1]) == a or t[1] == a for a in args)]
    return all_

def boot(batch, tag):
    """one boot compiling and running the batch -> the console output (None: no output at all)"""
    d = os.path.join(OUT, "disk-" + tag)
    shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
    files, script = [], []
    for i, (rung, path) in enumerate(batch):
        n = "t%02d.c" % i
        shutil.copyfile(path, d + "/" + n); files.append(d + "/" + n)
        script += ["cc -o t %s" % n, "echo @@C%02d $?" % i, "t", "echo @@R%02d $?" % i, "rm t"]
    script.append("halt")
    open(d + "/in.txt", "w").write("\n".join(script) + "\n")
    open(d + "/rc", "w").write("")
    subprocess.run([B + "/mkdisk", "-o", d + "/disk.img", "-k", B + "/kernel.stx", "-t", "etc", d + "/rc"] + BASE +
                   ["-t", "test"] + files, check=True, stdout=subprocess.DEVNULL)
    try:
        p = subprocess.run([B + "/strata-emu", "-c", "8", "-g", "none", "-d", d + "/disk.img", "-i", d + "/in.txt",
                            B + "/bootrom.stx"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=SECS)
        out = p.stdout
    except subprocess.TimeoutExpired as e:
        out = e.stdout or b""
    return out.decode("latin-1")

def clean(text):
    """a program's output without what the shell adds after a non-zero status: "[exit N]" and the prompt's "[N] " """
    return re.sub(r"(\[(exit|fault|killed)[^\]\n]*\]\n)?\[\d+\] $", "", text)

def parse(out, n):
    """-> per test: (compile output, compile status, run output, run status), None where the session did not get that far"""
    res = []
    for i in range(n):
        m = re.search(re.escape(PROMPT + "cc -o t t%02d.c\n" % i) + "(.*?)" + re.escape(PROMPT + "echo @@C%02d $?\n" % i) +
                      r"@@C%02d (\d+)\n" % i, out, re.S)
        if not m: res.append(None); continue
        r = re.search(re.escape(PROMPT + "echo @@C%02d $?\n" % i) + r"@@C%02d \d+\n" % i + re.escape(PROMPT + "t\n") + "(.*?)" +
                      re.escape(PROMPT + "echo @@R%02d $?\n" % i) + r"@@R%02d (\d+)\n" % i, out, re.S)
        res.append((clean(m.group(1)), int(m.group(2)), clean(r.group(1)) if r else None, int(r.group(2)) if r else None))
    return res

def verdict(path, r):
    if r is None: return "TIMEOUT", "the session stopped in this test"
    cout, cst, rout, rst = r
    if cst != 0: return "CC", cout.strip().split("\n")[0][:100]
    if rout is None: return "TIMEOUT", "the program did not end"
    base = path[:-2]
    want = open(base + ".out", "rb").read().decode("latin-1") if os.path.exists(base + ".out") else ""
    code = int(open(base + ".exit").read()) if os.path.exists(base + ".exit") else 0
    if rst != code: return "EXIT", "status %d, expected %d" % (rst, code)
    if rout != want: return "OUT", "output differs"
    return "PASS", ""

def main():
    args = sys.argv[1:]
    verbose = "-v" in args
    if verbose: args.remove("-v")
    fast = None
    if "-f" in args:
        i = args.index("-f"); fast = args[i + 1]; del args[i:i + 2]
    todo = tests(args, fast)
    expect = {}
    if os.path.exists(T + "/ladder/EXPECT.tsv"):
        for line in open(T + "/ladder/EXPECT.tsv"):
            if line.strip() and not line.startswith("#"):
                f = line.rstrip("\n").split("\t"); expect[f[0]] = f[1] if len(f) > 1 else ""
    os.makedirs(OUT, exist_ok=True)
    results = []
    queue = list(todo); k = 0
    while queue:
        batch, queue = queue[:BATCH], queue[BATCH:]
        res = parse(boot(batch, "%03d" % k), len(batch)); k += 1
        for i, (t, r) in enumerate(zip(batch, res)):
            v, why = verdict(t[1], r)
            results.append((t[0], os.path.basename(t[1]), v, why))
            if v == "TIMEOUT":            # the rest of the batch did not run: boot again for it
                queue = batch[i + 1:] + queue
                break
    with open(OUT + "/results.tsv", "w") as f:
        for r in results: f.write("\t".join(r) + "\n")
    bad = 0; tot = [0, 0, 0]
    for rung in sorted(set(r[0] for r in results)):
        rr = [r for r in results if r[0] == rung]
        ok = sum(1 for r in rr if r[2] == "PASS")
        xf = sum(1 for r in rr if r[2] != "PASS" and r[1] in expect)
        xp = [r[1] for r in rr if r[2] == "PASS" and r[1] in expect]
        fails = [r for r in rr if r[2] != "PASS" and r[1] not in expect]
        tot[0] += ok; tot[1] += len(rr); tot[2] += xf
        print("%-24s %3d / %3d pass%s%s" % (rung, ok, len(rr), ", %d expected to fail" % xf if xf else "",
                                           ", %d FAIL" % len(fails) if fails else ""))
        if verbose or fast:
            for r in fails: print("    %-6s %-32s %s" % (r[2], r[1], r[3]))
        for x in xp: print("    passes but is listed in EXPECT.tsv: " + x)
        bad += len(fails)
    print("%-24s %3d / %3d pass, %d expected to fail, %d unexpected" % ("total", tot[0], tot[1], tot[2], bad))
    sys.exit(1 if bad else 0)

main()
