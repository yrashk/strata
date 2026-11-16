/* fardata.c: far data (lang/cc/DESIGN.md, "Far data"): a static array that
 * does not fit the D-LS, a heap that goes past it, pointers into both used
 * like any others (the library's string functions, sprintf, structures),
 * and far_read / far_write, which go around the cache, seeing what plain
 * stores wrote and being seen by plain loads afterwards. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strata.h>

static long big[20000];                 /* 160 KB: the arena */
static int small[4] = { 1, 2, 3, 4 };   /* fits: the D-LS */

struct rec { long k; char name[24]; struct rec *next; };

static const char *where(void *p) { return (long)p >= 0x10000 ? "far" : "near"; }

int main(void)
{
    long i, s = 0, w[8];
    int n = 0, nfar = 0;
    struct rec *head = 0, *r;
    char *text;
    for (i = 0; i < 20000; i++) big[i] = i * 3;
    for (i = 0; i < 20000; i++) s = s + big[i];
    printf("big: %s, sum %ld; small: %s, %d\n", where(big), s, where(small), small[3]);
    for (i = 0; i < 2000; i++) {        /* 80 KB of records: the heap in the D-LS, then the far one */
        r = malloc(sizeof *r);
        if (!r) break;
        r->k = i;
        sprintf(r->name, "rec%ld", i);
        r->next = head;
        head = r;
    }
    s = 0;
    for (r = head; r; r = r->next) {
        if (strcmp(r->name + 3, "0") == 0 || r->k == 1999) printf("%s %ld\n", r->name, r->k);
        s = s + r->k;
        n++;
        if ((long)r >= 0x10000) nfar++;
    }
    printf("%d records (%s), %s in the far heap, sum %ld\n", n, nfar > 0 ? "some far" : "all near",
           nfar < n ? "not all" : "all", s);
    text = malloc(100000);              /* one large block: far */
    memset(text, 'x', 99999);
    text[99999] = 0;
    strcpy(text + 50000, "middle");
    printf("text: %s, %d, %s\n", where(text), (int)strlen(text), text + 50000);
    big[8] = 77;                        /* a plain store, then far_read: it must see it */
    far_read((long)&big[8], w, 64);
    printf("far_read: %ld %ld\n", w[0], w[1]);
    w[1] = 1234;                        /* far_write, then a plain load: it must see it */
    far_write((long)&big[8], w, 64);
    printf("after far_write: %ld %ld %ld\n", big[8], big[9], big[10]);
    while (head) { r = head->next; free(head); head = r; }
    free(text);
    r = malloc(sizeof *r);
    printf("after free: %s\n", r ? "allocated again" : "none");
    return 0;
}
