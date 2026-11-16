/* asm.c: Strata assembly inside C, and the machine's own instructions.
   In StrataOS:  cc asm.c   and then   asm
   (lang/cc/DESIGN.md says what asm("...") accepts; <strata.h> lists the intrinsics) */
#include <stdio.h>
#include <strata.h>

enum { BIAS = 40 };
int total = 5;

/* at file scope the labels of an asm block are functions */
long twice(long x);
long add_total(long x);
asm("twice:\n"
    "    add   a0, a0, a0        ; a0 = 2 x\n"
    "    ret\n"
    "add_total:\n"
    "    lw    t0, {total}       ; a C object as a memory operand\n"
    "    add   a0, a0, t0\n"
    "    ret");

int plus100(int x) { return x + 100; }

int main(void)
{
    long a = 3, b = 4, r = 0;
    long buf[2];

    asm("ld    t0, {a}\n"
        "ld    t1, {b}\n"
        "mul   t0, t0, t1\n"
        "addi  t0, t0, {BIAS}          ; an enumeration constant as a number\n"
        "sd    t0, {r}");
    printf("3 * 4 + 40 = %ld\n", r);

    asm("      li    t0, 0\n"
        "      li    t1, 10\n"
        "loop: add   t0, t0, t1        ; a label of this function\n"
        "      addi  t1, t1, -1\n"
        "      bnez  t1, loop\n"
        "      sd    t0, {r}\n"
        "      la    t3, {total}       ; the address of a C object\n"
        "      sw    t0, 0(t3)");
    printf("1 + ... + 10 = %ld, total = %d\n", r, total);

    asm("li    a0, 1\n"
        "call  {plus100}               ; a C function\n"
        "sd    a0, {r}");
    printf("plus100(1) = %ld, twice(21) = %ld, add_total(1) = %ld\n", r, twice(21), add_total(1));

    /* the same machine through intrinsics: a transfer to the arena and back */
    buf[0] = 0x1122334455667788;
    buf[1] = 0;
    __tput(1, (long)buf, 0, 0x1000, 8);
    __tget(2, (long)(buf + 1), 0, 0x1000, 8);
    __twait(6);
    printf("through the arena: %lx, the arena is %ld KiB\n", buf[1], __clen(0) >> 10);
    return 0;
}
