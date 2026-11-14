/* host.c: cc.c as a cross compiler.
 *
 * cc.c is written for StrataOS: its large tables live in the arena behind
 * far_read / far_write, it reads /bin/cc.lib, and it folds floating-point
 * constants with the run-time library's routines. This file gives it those
 * on an ordinary 64-bit little-endian machine, so that the same source,
 * compiled by the host's C compiler, is strata-cc: it writes the images cc
 * writes inside StrataOS, byte for byte.
 *
 *   strata-cc [-o OUT] [-p] [-h KIB] FILE.c
 *
 * cc.lib is the file named by the environment variable CC_LIB, or
 * cc/cc.lib beside the program (build/strata-cc, build/cc/cc.lib).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

#define ARENA 0xD0000
static unsigned char arena[ARENA];
static char libpath[1024];

/* transfers: checked as the machine would (8-byte alignment, the arena's size) */
static void chk(unsigned long off, const void *buf, unsigned long n)
{
    if ((off & 7) || (n & 7) || ((unsigned long)buf & 7) || off + n > ARENA) {
        fprintf(stderr, "strata-cc: bad transfer: offset %#lx, %#lx bytes, buffer %p\n", off, n, buf);
        abort();
    }
}

void far_read(unsigned long off, void *buf, unsigned long n)
{
    chk(off, buf, n);
    memcpy(buf, arena + off, n);
}

void far_write(unsigned long off, const void *buf, unsigned long n)
{
    chk(off, buf, n);
    memcpy(arena + off, buf, n);
}

int cc_open(const char *name, int mode)
{
    if (!strcmp(name, "/bin/cc.lib")) name = libpath;
    return open(name, mode ? O_WRONLY | O_CREAT | O_TRUNC : O_RDONLY, 0644);
}

/* lib/fp.s: IEEE doubles as 64-bit patterns */
static double d(long a) { double x; memcpy(&x, &a, 8); return x; }
static long l(double x) { long a; memcpy(&a, &x, 8); return a; }

long __fadd(long a, long b) { return l(d(a) + d(b)); }
long __fsub(long a, long b) { return l(d(a) - d(b)); }
long __fmul(long a, long b) { return l(d(a) * d(b)); }
long __fdiv(long a, long b) { return l(d(a) / d(b)); }
long __itof(long a) { return l((double)a); }
long __utof(long a) { return l((double)(unsigned long)a); }

long __fcmp(long a, long b)
{
    double x = d(a), y = d(b);
    return x < y ? -1 : x == y ? 0 : x > y ? 1 : 2;
}

/* toward zero; out of range: the nearest value, as fp.s gives */
long __ftoi(long a)
{
    double x = d(a);
    if (x != x) return 0;
    if (x >= 9223372036854775808.0) return 0x7fffffffffffffffL;
    if (x < -9223372036854775808.0) return -0x7fffffffffffffffL - 1;
    return (long)x;
}

long __ftou(long a)
{
    double x = d(a);
    if (x != x || x <= 0) return 0;
    if (x >= 18446744073709551616.0) return -1;
    return (long)(unsigned long)x;
}

long __f2d(long a)
{
    float f;
    int i = (int)a;
    memcpy(&f, &i, 4);
    return l((double)f);
}

long __d2f(long a)
{
    float f = (float)d(a);
    int i;
    memcpy(&i, &f, 4);
    return (long)i;
}

int cc_main(int argc, char **argv);

int main(int argc, char **argv)
{
    char *e = getenv("CC_LIB"), *s;
    if (e) snprintf(libpath, sizeof libpath, "%s", e);
    else {
        snprintf(libpath, sizeof libpath - 16, "%s", argv[0]);
        s = strrchr(libpath, '/');
        strcpy(s ? s + 1 : libpath, "cc/cc.lib");
    }
    return cc_main(argc, argv);
}
