/* logicval.c: && and || as values inside arithmetic. The value of a && or
 * || is made where its jumps land; code for the other operand (here a value
 * reloaded from the frame, which the jumps spill it to) must come before
 * that point, or the jumps skip it: 2 + p + (!p && x > 0x10000) once gave
 * 65536, the comparison's constant left in the register. */
#include <stdio.h>
int p, s, arr[4]; long x;
int id(int v) { return v; }
int two(int a, int b) { return a * 10 + b; }
int main(void)
{
    int y = 5;
    p = 0; s = 0; x = 0x10000;
    printf("F %d\n", 2 + p + (!p && x > 0x10000));
    printf("F2 %d\n", 2 + p - s + (!p && x > 0x10000));
    printf("R %d\n", (!p && x > 0x10000) + 2 + p);
    printf("O %d\n", y + p + (p || x > 0x10000));
    printf("O2 %d\n", y + p + (p || x >= 0x10000));
    printf("C %d\n", y + p < (!p && x >= 0x10000) + 6);
    printf("M %d\n", (y + p) * (!p && x >= 0x10000));
    printf("P %d\n", *(arr + p + (!p && x > 0x10000)) );
    arr[p + 1] = !p && x > 0x10000;
    printf("A %d %d\n", arr[1], arr[0]);
    printf("G %d\n", two(y + p, !p && x > 0x10000));
    printf("T %d\n", y + p + (x > 0x10000 ? 3 : 4));
    printf("N %d\n", y + p + !(!p && x > 0x10000));
    printf("S %d\n", y + p + (p < 1 && x > 0x10000 || s == 0));
    return 0;
}
