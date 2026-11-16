/* regvars.c: variables in callee-saved registers (lang/cc/DESIGN.md,
 * "Register variables"): names in nested and sibling scopes, increments in
 * every position, narrow types that wrap, values read before a variable
 * changes, calls and recursion, and the bodies that keep every variable in
 * the frame (an address taken, a directive, an array parameter, asm). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#define ADDR(x) (&(x))

struct node { int v; struct node *next; };

int scopes(void)
{
    int i, s = 0;
    for (i = 0; i < 5; i++) {
        int k = i * 3;
        s = s + k;
        {
            int i = 100;                /* the same name inside: the outer one keeps its value */
            s = s + i;
            i++;
        }
    }
    for (i = 0; i < 3; i++) { int k = i; s = s + k; }  /* a sibling scope: the same names again */
    return s + i;
}

int increments(void)
{
    int i = 5, j, k, a[8];
    unsigned char u = 250;
    signed char c = 120;
    unsigned short h = 65530;
    unsigned w = 0xfffffff0u;
    long n = 0;
    _Bool b = 0;
    char *p, *q, buf[8];
    j = i++ + 10;                       /* 15, i 6 */
    k = ++i * 2;                        /* 14, i 7 */
    k = k + i--;                        /* 21, i 6 */
    k = k + --i;                        /* 26, i 5 */
    for (j = 0; j < 8; j++) a[j] = j * j;
    j = 0;
    a[j++] = a[3];
    u += 10;
    c += 10;
    h += 10;
    w += 32;
    b++;
    b++;
    for (n = 0; n < 4; n++) u++;
    strcpy(buf, "abcdef");
    p = buf;
    q = buf + 6;
    while (p < q) n = n * 3 + *p++;
    while (q > buf) n = n + *--q;
    printf("inc %d %d %d %d %u %d %u %u %d %ld\n", i, j, k, a[0], u, c, h, w, b, n);
    return k;
}

int pick(int x, int y) { return x > y ? x : y; }

int conds(void)
{
    int i, j, m = 0, t = 0;
    for (i = 0, j = 10; i < j; i++, j--) {
        m = m + (i > j - 4 ? i : j);
        t = t + pick(i, j) - (i & 1 ? j : 0);
        if (i == 3) continue;
        t++;
    }
    do {
        i--;
        if (i == 2) break;
    } while (i > 0);
    return m * 1000 + t * 10 + i;
}

int fold(struct node *p)
{
    int s = 0;
    while (p) { s = s * 7 + p->v; p = p->next; }
    return s;
}

/* more variables than registers: the ones used most get them */
long many(int depth, long a, long b)
{
    long v1 = a + 1, v2 = b + 2, v3 = v1 * 3, v4 = v2 * 4, v5 = v3 + v4, v6 = v5 - a, v7 = v6 ^ b;
    long v8 = v7 + 8, v9 = v8 * 2, v10 = v9 - v1, v11 = v10 + v2, v12 = v11 * 3, v13 = v12 - 13, r = 0;
    int i;
    for (i = 0; i < 3; i++) r = r + v1 + v2 + v3 + v4 + v5 + v6 + v7 + v8 + v9 + v10 + v11 + v12 + v13;
    if (depth > 0) r = r + many(depth - 1, v3 & 255, v13 & 255);
    return r + v1 * v13;
}

int by_value(const void *a, const void *b)
{
    int x = *(const int *)a, y = *(const int *)b, d = x - y;
    return d < 0 ? -1 : d > 0;
}

int sum(int n, ...)
{
    va_list ap;
    int s = 0;
    va_start(ap, n);
    while (n-- > 0) s = s + va_arg(ap, int);
    va_end(ap);
    return s;
}

int nine(int a, int b, int c, int d, int e, int f, int g, int h, int k)
{
    int i, s = 0;
    for (i = 0; i < 3; i++) s = s + a + b + c + d + e + f + g + h + k;
    return s;
}

int addressed(void)
{
    int t = 5, u = 6, i, *q = &t;
    for (i = 0; i < 3; i++) { *q = *q + 1; *ADDR(u) = u + t; }
    return t * 100 + u;
}

int directive(int n)
{
    int i, s = 0;
    for (i = 0; i < n; i++)
#if 1
        s = s + i;
#endif
    return s;
}

int arrays(int n)
{
    int g(int a[][3], int k);           /* a parameter list with [ in it */
    int m[2][3], i, j, s = 0;
    for (i = 0; i < 2; i++) for (j = 0; j < 3; j++) m[i][j] = i + j + n;
    s = g(m, 2);
    return s;
}

int g(int a[][3], int k)
{
    int i, j, s = 0;
    for (i = 0; i < k; i++) for (j = 0; j < 3; j++) s = s * 2 + a[i][j];
    return s;
}

#ifdef __strata__
int with_asm(int n)
{
    int i, s = 0;
    for (i = 0; i < n; i++) s = s + i;
    asm("addi t0, t0, 0");
    return s;
}
#else
int with_asm(int n) { return n * (n - 1) / 2; }
#endif

int narrow(void)
{
    int x = ~0, y = 0, i;
    unsigned z = 3;
    short s = 300;
    if (x != 0xffffffff) y = y + 1;     /* compared as unsigned */
    if ((char)s != 44) y = y + 2;
    if ((unsigned char)x != 255) y = y + 4;
    for (i = 0; i < 40; i++) z = z * 5;  /* wraps at 32 bits */
    return y * 1000 + (int)(z % 1000);
}

int main(void)
{
    struct node n3 = { 3, 0 }, n2 = { 2, &n3 }, n1 = { 1, &n2 };
    int v[6] = { 5, 3, 9, 1, 7, 2 }, i;
    int (*f)(int, int) = pick;
    printf("scopes %d\n", scopes());
    printf("increments %d\n", increments());
    printf("conds %d\n", conds());
    printf("fold %d\n", fold(&n1));
    printf("many %ld\n", many(3, 5, 7));
    qsort(v, 6, sizeof v[0], by_value);
    for (i = 0; i < 6; i++) printf("%d%c", v[i], i < 5 ? ' ' : '\n');
    printf("sum %d nine %d\n", sum(4, 1, 2, 3, 4), nine(1, 2, 3, 4, 5, 6, 7, 8, 9));
    printf("addressed %d directive %d arrays %d asm %d\n", addressed(), directive(10), arrays(1), with_asm(5));
    printf("narrow %d\n", narrow());
    for (i = 0; i < 3; i++) printf("f %d\n", f(i, 1));
    printf("line %d %s\n", __LINE__, "con" "cat");
    return 0;
}
