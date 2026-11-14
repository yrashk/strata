/* cmp.c: are two files the same? (for the compiler's self-compilation test)
   cmp A B  ->  "A B: same" and status 0, or where they first differ and 1 */
#include <stdio.h>
#include <strata.h>

char a[1024], b[1024];

int main(int argc, char **argv)
{
    int fa, fb, i;
    long na, nb, pos = 0;
    if (argc != 3) { printf("usage: cmp A B\n"); return 2; }
    fa = open(argv[1], 0);
    fb = open(argv[2], 0);
    if (fa < 0 || fb < 0) { printf("cmp: cannot read %s\n", argv[fa < 0 ? 1 : 2]); return 2; }
    for (;;) {
        na = read(fa, a, 1024);
        nb = read(fb, b, 1024);
        for (i = 0; i < na && i < nb; i++)
            if (a[i] != b[i]) { printf("%s %s: differ at byte %ld\n", argv[1], argv[2], pos + i); return 1; }
        if (na != nb) { printf("%s %s: differ in length\n", argv[1], argv[2]); return 1; }
        if (na <= 0) break;
        pos = pos + na;
    }
    printf("%s %s: same\n", argv[1], argv[2]);
    return 0;
}
