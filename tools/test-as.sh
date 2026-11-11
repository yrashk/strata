#!/bin/sh
# Tests os/progs/as.s, the Strata assembler written in Strata assembly,
# against the reference assembler sasm. Every image must be byte-identical.
#
#   tools/test-as.sh            (builds into build-as/, BUILD=dir to change)
#
# 1. Bare metal: `as` (built by sasm at origin 0) runs on the emulator, reads
#    the source from the console input and prints the image. Compared with
#    `sasm file.s`.
# 2. StrataOS front end: `as` built with `sasm -T 0x8000` runs under
#    tools/as-harness.s, which sets it up the way the kernel's `run` does
#    (a 1 MiB arena in c0, input at 0x80000, a0 = length, a1 = 1, halt
#    trapping to the harness's supervisor handler) and prints the image the program left at
#    0xC0000. Compared with `sasm -T 0x8000 file.s`.
# 3. Self-hosting: `as` assembling as.s reproduces the sasm-built `as`
#    byte for byte, in both modes (the bare-metal one is in the list below).
# 4. A feature test covering every instruction, pseudo-instruction,
#    directive and expression form, in both modes.
# 5. Error cases: inputs sasm rejects must make `as` stop with an error.
# 6. A real StrataOS boot on the emulator: `run as < hello.s > hello` writes
#    the same bytes as `sasm -T 0x8000`, and `run -n 2 hello` runs them.
#
# Inputs are every examples/*.s, os/kernel.s, firmware/bootrom.s and
# os/progs/as.s, with `.include` lines replaced by the included file (`as`
# itself skips `.include`: it has no file system).
#
# Needs python3 (include expansion, merging two images into one).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here" || exit 1
B=${BUILD:-build-as}
make -s BUILD="$B" "$B/sasm" "$B/strata-emu" || exit 1
SASM="$B/sasm"
EMU="$B/strata-emu -c 1 -m 4000000000"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

# expand FILE: print FILE with every .include line replaced by the file
expand() {
  python3 - "$1" <<'EOF'
import os, re, sys
def expand(path):
    d = os.path.dirname(path)
    for line in open(path, encoding='latin-1'):
        m = re.match(r'\s*\.include\s.*?"([^"]*)"', line)
        if m:
            expand(os.path.join(d, m.group(1)))
        else:
            sys.stdout.write(line)
expand(sys.argv[1])
EOF
}

# merge A B OUT: one STX2 image holding the sections of A and of B
merge() {
  python3 - "$1" "$2" "$3" <<'EOF'
import struct, sys
secs = []
for p in sys.argv[1:3]:
    d = open(p, 'rb').read()
    assert d[:4] == b'STX2'
    n, off = struct.unpack_from('<I', d, 4)[0], 8
    for _ in range(n):
        k, base, size, r = struct.unpack_from('<4I', d, off)
        secs.append(d[off:off + 16 + size])
        off += 16 + size
open(sys.argv[3], 'wb').write(b'STX2' + struct.pack('<I', len(secs)) + b''.join(secs))
EOF
}

# the assembler, both builds, and the harness image
$SASM -o "$B/as.stx" os/progs/as.s || exit 1
$SASM -T 0x8000 -o "$B/as-os.stx" os/progs/as.s || exit 1
$SASM -o "$tmp/harness.stx" tools/as-harness.s || exit 1
merge "$tmp/harness.stx" "$B/as-os.stx" "$B/as-harnessed.stx"

# the feature test source
cat >"$tmp/features.s" <<'EOF'
; every instruction, pseudo-instruction, directive and expression form
X = 5                                   ; plain constant
Y=X*3+(2<<4)|1                          ; no blanks, precedence
.equ Z, Y ^ 0x55 & ~3                   ; .equ
        .set W, -7 % 3                  ; .set, negative remainder
V       =       ((1 << 70) + 017 + 0b101 - 0x1F) / -2 ; shift mod 64, octal, binary, hex
        .TEXT                           ; upper case directive
start: lbl2:    nop                     ; two labels
        ADD   a0, a1, a2                ; upper case mnemonic
        sub x1,x2,x31  # hash comment
        and   fp, s0, zero // slash comment
        or t0,t1,t2 ; c
        xor t3, t4, t5
        sll t6, s1, s2
        srl s3, s4, s5
        sra s6, s7, s8
        slt s9, s10, s11
        sltu a3, a4, a5
        mul a6, a7, gp
        mulhu tp, ra, sp
        divu a0, a0, a0
        remu a0, a0, a0
        div a0, a0, a0
        rem a0, a0, a0
        addi a0, a0, -32768
        slti a0, a0, 32767
        sltiu a0, a0, 'a'
        andi a0, a0, 0xffff
        ori a0, a0, 0b1010
        xori a0, a0, 017
        slli a0, a0, 63
        srli a0, a0, X
        srai a0, a0, 0
        lui a0, 0xffff
        lui a0, -1
        ld a0, 8(sp)
        lw a0, (sp)
        lwu a0, -8 ( a1 )
        lh a0, (X+1)*2(a2)
        lhu a0, Z(zero)
        lb a0, -1(t0)
        lbu a0, 0x7fff(t0)
        sd a0, 0(sp)
        sw a0, 4(sp)
        sh a0, 2(sp)
        sb a0, 1(sp)
back:   beq a0, a1, start
        bne a0, a1, fwd
        blt a0, a1, back
        bge a0, a1, fwd
        bltu a0, a1, .
        bgeu a0, a1, . + 8
        jal ra, fwd
        jal zero, start
        jalr ra, a0, 4
        tget tg0, a0, c1, a2, a3
        tput tg15, a0, c15, zero, a1
        tgetx tg7, s0, c9, s3, s4
        twait tg0, tg3, tg15
        twait 0x8001
        tpoll a0, tg1
        tpoll a0, tg1, tg2
        tpoll a0, 3
        tamo.add a0, c6, a1, a2
        tamo.swap a0, c6, a1, a2
        tamo.cas a0, c6, a1, a2
        tamo.and a0, c6, a1, a2
        tamo.or a0, c6, a1, a2
        cmov c1, c2
        cjoin c1, c2
        cshare c1, c2
        catomic c1, c2
        csplit c1, c2, a0
        crestrict c1, c2, a0
        cbase a0, c1
        clen a0, c1
        cperms a0, c1
        cvalid a0, c1
        cpoll a0
        cgive c2, a0
        ctake c3
        ctake c3, t0
        cclear c4
        csave c13, 63
        crestore c13, 62
        csavex c13, a0
        crestorex c12, t6
        csrr a0, cycle
        csrr a0, instret
        csrr a0, cause
        csrr a0, epc
        csrr a0, tval
        csrr a0, tvec
        csrr a0, ccr
        csrr a0, coreid
        csrr a0, ttag
        csrr a0, tdata
        csrr a0, tgeom
        csrr a0, ncores
        csrr a0, scratch
        csrr a0, stalls
        csrr a0, takefrom
        csrr a0, corebase
        csrr a0, corecount
        csrr a0, reserved17
        csrr a0, status
        csrr a0, ucause
        csrr a0, uepc
        csrr a0, utval
        csrr a0, utvec
        csrr a0, sscratch
        csrr a0, ipend
        csrr a0, xslot
        csrr a0, 17
        csrr a0, X+0x100
        csrw tvec, a0
        csrw 0xffff, a0
        halt
        eret
        svc
        ltag a0, a1
        linst a0
        xmap 7, a0, c3, a1
        xmap 15, a0, c3, a1
        xunmap 3
        xunmap 15
        xcall ra, c3, a0
        xret ra
        xret t0
        cdom c1, c2
        crevoke c3, c4
        cundom c5, c6
        csend c7, c8
        crecv c9, c10
        cmkep c11, a5
        tany a0, a1
        mv a0, a1
        li a0, 0x7fff
        li a0, -0x8000
        li a0, 0x8000
        li a0, 0x7fffffff
        li a0, -0x80000000
        li a0, 0x80000000
        li a0, -1
        li a0, 0x123456789abcdef0
        li a0, later
        li a0, 'z' - 'a'
        li a0, '\n'
        li a0, '\\'
        li a0, '\''
        li a0, ';'
        li a0, '#'
        li a0, ','
        li a0, '\0'
        li a0, '\t' + '\r'
        li a0, .
        li a0, . - start
        li a0, V
        li a0, W
        la a0, dat
        la a1, start
        seqz a0, a1
        snez a0, a1
        neg a0, a1
        j fwd
        call fwd
        ret
        jr a0
        tfence
        beqz a0, fwd
        bnez a0, back
        bltz a0, fwd
        bgez a0, fwd
        bgtz a0, fwd
        blez a0, fwd
        bgt a0, a1, fwd
        ble a0, a1, fwd
        bgtu a0, a1, fwd
        bleu a0, a1, fwd
fwd:    a: b: c:
        .align 16
        .byte 1, 2, -1, 'x', 255, 0x1ff, ',', ';'
        .half 0x1234, -2
        .word 0xdeadbeef, start, fwd - start
        .dword -7 / 2, -7 % 2, 7 / -2, 1 << 63 >> 63, ~0 >> 1, -1 >> 70
        .ascii "a;b#c//d\"e\\f\n\t\r\0\x41\x4g\xz\q", "ignored"
        .asciz "z"
        .string "q"
        .space 5
        .space 3, 0xAA
        .zero 2
        .align 8
        .global foo
        .globl bar
        .data
dat:    .dword start, fwd, dat, .
        .org 0x40
        .byte 7
        .far
        .align 64
        .space 10
        .cluster
        .byte 1
        .text
later = 0x1234
        .org . + 12
        nop
EOF

run_bare() { # SRC OUT ERR
  $EMU -i "$1" "$B/as.stx" >"$2" 2>"$3"
}
run_os() { # SRC OUT ERR
  $EMU -i "$1" "$B/as-harnessed.stx" >"$2" 2>"$3"
}

check() { # NAME SRC
  name=$1 src=$2
  for mode in bare os; do
    if [ $mode = bare ]; then
      $SASM -o "$tmp/ref.stx" "$src" 2>"$tmp/sasm.err" || { echo "$name: sasm failed"; cat "$tmp/sasm.err"; fail=1; continue; }
      run_bare "$src" "$tmp/out.stx" "$tmp/emu.err"
    else
      if [ "$(wc -c <"$src")" -gt 262144 ]; then
        # the OS-mode input area holds 256 KiB (the expanded StrataOS 0.1 kernel
        # with its code units is larger): bare mode above covers it
        printf '%-12s %-5s skip  input larger than 256 KiB\n' "$name" $mode
        continue
      fi
      if ! $SASM -T 0x8000 -o "$tmp/ref.stx" "$src" 2>"$tmp/sasm.err"; then
        # sasm rejects it at this origin (os/kernel.s does `.org 0x4000`): so must as
        run_os "$src" "$tmp/out.stx" "$tmp/emu.err"
        if grep -q 'halt a0=0 ' "$tmp/emu.err" && grep -q '^line [0-9]*: ' "$tmp/out.stx"; then
          printf '%-12s %-5s ok    rejected by both: %s\n' "$name" $mode "$(head -1 "$tmp/out.stx")"
        else
          printf '%-12s %-5s FAIL  (sasm rejects it, as does not)\n' "$name" $mode; fail=1
        fi
        continue
      fi
      run_os "$src" "$tmp/out.stx" "$tmp/emu.err"
    fi
    steps=$(sed -n 's/.*instret=\([0-9]*\).*/\1/p' "$tmp/emu.err" | head -1)
    if cmp -s "$tmp/ref.stx" "$tmp/out.stx"; then
      printf '%-12s %-5s ok    %8s bytes  %10s instructions\n' "$name" $mode "$(wc -c <"$tmp/ref.stx" | tr -d ' ')" "$steps"
    else
      printf '%-12s %-5s FAIL\n' "$name" $mode
      head -c 300 "$tmp/out.stx" | strings | head -3 | sed 's/^/    /'
      sed 's/^/    /' "$tmp/emu.err"
      fail=1
    fi
  done
}

for f in examples/*.s os/kernel.s firmware/bootrom.s os/progs/as.s; do
  n=$(basename "$f" .s)
  expand "$f" >"$tmp/$n.s"
  check "$n" "$tmp/$n.s"
done
check features "$tmp/features.s"

# self-hosting: the image `as` makes of as.s is the image sasm made of it
expand os/progs/as.s >"$tmp/as-src.s"
run_bare "$tmp/as-src.s" "$tmp/as1.stx" /dev/null
run_os "$tmp/as-src.s" "$tmp/as2.stx" /dev/null
if cmp -s "$tmp/as1.stx" "$B/as.stx" && cmp -s "$tmp/as2.stx" "$B/as-os.stx"; then
  echo "self-host    ok    as assembles itself into the sasm-built as (both origins)"
else
  echo "self-host    FAIL"; fail=1
fi

# error cases: sasm must reject each, and `as` must stop with exit code 1
nerr=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  printf '%b\n' "$line" >"$tmp/bad.s"
  if $SASM -o "$tmp/bad.stx" "$tmp/bad.s" 2>/dev/null; then
    echo "error case accepted by sasm (test is wrong): $line"; fail=1; continue
  fi
  run_bare "$tmp/bad.s" "$tmp/bad.out" "$tmp/bad.err"
  if grep -q 'halt a0=1 ' "$tmp/bad.err" && grep -q '^line [0-9]*: ' "$tmp/bad.out"; then
    nerr=$((nerr + 1))
  else
    echo "error case FAIL: $line"; cat "$tmp/bad.out" "$tmp/bad.err" | sed 's/^/    /'; fail=1
  fi
done <<'EOF'
foo a0
.foo
add a0, a1
add a0, a1, a2, a3
addi a0, a0, 40000
addi a0, a0, -32769
andi a0, a0, -1
lui a0, 65536
slli a0, a0, 64
li a0, undefined_sym
lbl: nop\nlbl: nop
X = 1\nX = 2
beq a0, a1, 3
j 0x800000
.byte 1,2,3,4,5,6,7,8,9
.align 3
.align 0
.org 4\n.org 0
X = Y\nY = 1
.equ A, B\nB = 1
.equ A
csrr a0, 0x10000
csrr a0, -1
ld a0, 8
ld a0, 8(a0
ld a0, 40000(a0)
.ascii "abc
.ascii abc
li a0, 1/0
li a0, 1%0
.data\nl: .byte 1\n.text\nbeq a0, a0, l
xmap 16, a0, c0, a1
xret
csend c1
cmkep c1, c2
csavex c1, c2
crestorex a0, a1
tany a0
csave c0, 64
.byte 1\nnop
ctake c1, a0, a1
cclear c1, a0
twait
twait tg0, 5
tpoll a0
la a0, -1
.space -1
.space X\nX = 1
add a0, a1, x32
add a0, a1, A0
cmov c16, c0
tget tg16, a0, c0, a1, a2
add a0, a1, a2 junk
li a0, 1 2
li a0, (1
li a0, 'ab'
li a0, 'a
.org 0x10000\nnop
.data\n.org 0x10000\n.byte 1
EOF
echo "errors       ok    $nerr rejected inputs rejected by as too"

# a real StrataOS boot: `run as < hello.s > hello`, then run the result. The
# disk holds what StrataOS 0.1 needs to come up (its servers and the shell)
# plus the `as` built here and hello.s.
OSB="$B/prog/proc $B/prog/dev $B/prog/fs $B/prog/tty $B/prog/pipe $B/prog/sh $B/prog/cat"
make -s BUILD="$B" "$B/mkdisk" "$B/bootrom.stx" "$B/kernel.stx" $OSB || exit 1
mkdir -p "$tmp/disk"
cp "$B/as-os.stx" "$tmp/disk/as"
expand examples/hello.s >"$tmp/disk/hello.s"
$SASM -T 0x8000 -o "$tmp/hello.ref" "$tmp/disk/hello.s" || exit 1
"$B/mkdisk" -o "$tmp/disk.img" -k "$B/kernel.stx" $OSB "$tmp/disk/as" "$tmp/disk/hello.s" >/dev/null 2>&1 || exit 1
printf 'run as < hello.s > hello\ncat hello\nrun -n 2 hello\nhalt\n' >"$tmp/session.txt"
$B/strata-emu -c 8 -T virtual -g none -m 4000000000 -d "$tmp/disk.img" -i "$tmp/session.txt" "$B/bootrom.stx" >"$tmp/boot.out" 2>&1
# the emulator keeps disk writes in memory, so read the new file back with `cat`
python3 - "$tmp/boot.out" "$tmp/hello.os" <<'EOF2'
import sys
d = open(sys.argv[1], 'rb').read()
try:
    a = d.index(b'$ cat hello\n') + len(b'$ cat hello\n')
    open(sys.argv[2], 'wb').write(d[a:d.index(b"strata$ run -n 2 hello")])
except ValueError:
    pass
EOF2
if cmp -s "$tmp/hello.ref" "$tmp/hello.os" && grep -q 'Hello from Strata core 1 of 2' "$tmp/boot.out"; then
  echo "StrataOS     ok    booted, ran \`run as < hello.s > hello\` and \`run -n 2 hello\`"
else
  echo "StrataOS     FAIL"; sed 's/^/    /' "$tmp/boot.out" | tail -20; fail=1
fi

if [ $fail = 0 ]; then echo "all as tests passed"; else echo "SOME as TESTS FAILED"; fi
exit $fail
