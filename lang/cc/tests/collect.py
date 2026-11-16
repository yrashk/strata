# collect.py SUITES_DIR OUT_DIR WORK_DIR: verify candidate tests on the host and sort them into rungs
import os, re, subprocess, sys, shutil
suites, out, work = sys.argv[1:4]
RUNGS = ["01-int-control", "02-functions", "03-pointers-arrays", "04-structs", "05-preproc",
         "06-init", "07-funcptr-switch-goto", "08-c99-misc", "09-float"]
STD = {"stdio.h", "stdlib.h", "string.h", "stdarg.h", "stddef.h", "stdint.h", "limits.h",
       "stdbool.h", "ctype.h", "assert.h", "math.h", "float.h"}
def strip(src):
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
    src = re.sub(r"//[^\n]*", " ", src)
    return src
def nostr(src):
    return re.sub(r'"(\\.|[^"\\])*"|\'(\\.|[^\'\\])*\'', '""', src)
def classify(raw, c99dir):
    s = strip(raw); t = nostr(s)
    flags = []
    incs = re.findall(r'#\s*include\s*([<"])([^>"]+)[>"]', s)
    for q, h in incs:
        if q == '"' or h not in STD: return None, "needs header " + h
    if re.search(r"\b(__attribute__|__asm__|asm\s*\(|typeof|__typeof|__builtin_(?!va_)|_Generic|_Alignof|_Alignas|_Static_assert|_Noreturn|_Complex|_Thread_local|__int128|setjmp|signal\s*\(|fopen|__extension__|alloca)\b", t):
        return None, "extension or C11 or unsupported library"
    if re.search(r"\(\s*\{", t) and re.search(r"\}\s*\)", t) and re.search(r"=\s*\(\s*\{|\(\s*\{[^}]*;", t):
        return None, "statement expression"
    if re.search(r"&&\s*[A-Za-z_]\w*\s*[;,)]", t) and "goto *" in t: return None, "computed goto"
    if re.search(r"\b(printf|puts|putchar|sprintf|snprintf|fprintf|vprintf|vsprintf|fputs|putc)\b", t): flags.append("printf")
    if re.search(r"\b(malloc|calloc|free|realloc|exit|abort|atoi|strtol|qsort|abs|rand)\b", t): flags.append("stdlib")
    if re.search(r"\b(str(len|cmp|cpy|cat|chr|ncmp|ncpy|rchr|str)|mem(cpy|set|cmp|move|chr))\b", t): flags.append("string")
    if re.search(r"\bva_(list|start|arg|end)\b", t): flags.append("stdarg")
    if re.search(r"\b(float|double)\b|\b\d+\.\d*([eE][-+]?\d+)?[fFlL]?\b|\b\d+[eE][-+]?\d+|\.\d+", t): flags.append("float")
    r = 1
    nfun = len(re.findall(r"^[A-Za-z_][\w\s\*]*\([^;{}]*\)\s*\{", t, flags=re.M))
    if nfun > 1 or re.search(r"^(static\s+|extern\s+)?(unsigned\s+|signed\s+)?(int|char|long|short)\s+\w+\s*(=[^;]*)?;", t, flags=re.M): r = 2
    if re.search(r"\[|\bsizeof\b|\b(char|short|long|unsigned|signed|void)\b|[=(,]\s*&\s*\w|\*\s*\w+\s*[=;,)]|\"\"", t): r = 3
    if re.search(r"\b(struct|union|enum|typedef)\b", t): r = 4
    if re.search(r"#\s*(define|if|ifdef|ifndef|undef|line|error|pragma|elif|else)\b", s): r = 5
    if re.search(r"=\s*\{|\]\s*=\s*\"\"|\bstatic\b[^;(]*;", t): r = 6
    if re.search(r"\b(switch|goto)\b|\(\s*\*\s*\w*\s*(\[[^\]]*\])?\s*\)\s*\(", t): r = 7
    c99 = [r"\blong\s+long\b", r"\b_Bool\b|\bbool\b", r"\.\.\.|\bva_list\b", r"\binline\b|\brestrict\b",
           r"\b(int|unsigned|char|long|short|signed)\s+\w*\s*:\s*\d+\s*[;,]", r"[{,]\s*\.\w+\s*=|[{,]\s*\[[^\]]+\]\s*=",
           r"\(\s*(struct\s+\w+|union\s+\w+|int|char|long|short|unsigned)\s*\**\s*(\[\s*\d*\s*\])?\s*\)\s*\{",
           r"\bfor\s*\(\s*(int|char|long|unsigned)\b", r"\b\d+[uU]?(ll|LL)[uU]?\b"]
    if c99dir or any(re.search(x, t) for x in c99) or re.search(r"//", re.sub(r"/\*.*?\*/", " ", nostr(raw), flags=re.S)): r = 8
    if "float" in flags: r = 9
    return r, flags
def run(path, std):
    exe = os.path.join(work, "a.out")
    c = subprocess.run(["cc", "-std=" + std, "-w", "-o", exe, path, "-lm"], capture_output=True)
    if c.returncode != 0: return None
    try:
        p = subprocess.run([exe], capture_output=True, timeout=3, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return None
    if p.returncode < 0: return None
    return p.returncode, p.stdout + p.stderr if False else p.stdout, p.stderr
cands = []
d = os.path.join(suites, "scc/tests/cc/execute")
for f in sorted(os.listdir(d)):
    if f.endswith(".c"): cands.append(("scc", os.path.join(d, f), "scc-" + f.replace("_", "-"), "tests/cc/execute/" + f, False, True))
for sub in ("c89", "c99"):
    d = os.path.join(suites, "lacc/test", sub)
    for f in sorted(os.listdir(d)):
        if f.endswith(".c"): cands.append(("lacc", os.path.join(d, f), "lacc-" + f, "test/%s/%s" % (sub, f), sub == "c99", False))
shutil.rmtree(os.path.join(out, "ladder"), ignore_errors=True)
man, dropped, counts = [], [], {}
for suite, path, name, up, c99dir, zero in cands:
    raw = open(path, encoding="latin-1").read()
    r, flags = classify(raw, c99dir)
    if r is None: dropped.append((suite, up, flags)); continue
    res = run(path, "c99")
    if res is None: dropped.append((suite, up, "does not build or run on the reference host")); continue
    code, so, se = res
    if zero and code != 0: dropped.append((suite, up, "reference host exit status %d" % code)); continue
    if se: dropped.append((suite, up, "writes to stderr")); continue
    if len(so) > 16384: dropped.append((suite, up, "output too long")); continue
    res2 = run(path, "c99")
    if res2 is None or res2[0] != code or res2[1] != so: dropped.append((suite, up, "not deterministic")); continue
    if re.search(r"%p|__DATE__|__TIME__|__FILE__", raw): dropped.append((suite, up, "host-dependent output")); continue
    rd = os.path.join(out, "ladder", RUNGS[r - 1]); os.makedirs(rd, exist_ok=True)
    shutil.copyfile(path, os.path.join(rd, name))
    base = name[:-2]
    if so: open(os.path.join(rd, base + ".out"), "wb").write(so)
    if code: open(os.path.join(rd, base + ".exit"), "w").write("%d\n" % code)
    man.append((RUNGS[r - 1], name, suite, up, ",".join(flags) or "-"))
    counts[(RUNGS[r - 1], suite)] = counts.get((RUNGS[r - 1], suite), 0) + 1
with open(os.path.join(out, "ladder", "MANIFEST.tsv"), "w") as f:
    f.write("# rung\tfile\tsuite\tupstream path\tflags\n")
    for m in sorted(man): f.write("\t".join(m) + "\n")
with open(os.path.join(work, "dropped.tsv"), "w") as f:
    for x in dropped: f.write("%s\t%s\t%s\n" % x)
for r in RUNGS: print(r, counts.get((r, "scc"), 0), counts.get((r, "lacc"), 0))
print("kept", len(man), "dropped", len(dropped))
