/* vla.c: variable-length arrays. Their storage is from the heap, and it is
 * given back wherever control leaves the array's scope: at the end of the
 * block, by return, break, continue and goto. This program leaves each way
 * so often that it would run out of memory if one of them kept the storage.
 *
 * In StrataOS:   cc /src/vla.c       and then   vla
 */
#include <stdio.h>

long sum(int n)
{
    long a[n], s = 0;
    int i;
    for (i = 0; i < n; i++) a[i] = i;
    for (i = 0; i < n; i++) s += a[i];
    return s;
}

long leave(int n, int how)
{
    long total = 0;
    int i;
    for (i = 0; i < 3; i++) {
        long a[n];
        a[n - 1] = i;
        total += a[n - 1];
        if (how == 0) continue;
        {
            char b[n * 8];
            b[0] = 1;
            total += b[0];
            if (how == 1) break;
            if (how == 2) goto out;         /* forward, out of two scopes */
            if (how == 3) {
                if (i < 2) goto again;      /* back: out of b's scope, a's stays */
                goto out;
            }
        }
        continue;
again:
        total += 100;
    }
out:
    return total;
}

int main(void)
{
    long t = 0;
    int i, n = 0;

    printf("sum(100) = %ld\n", sum(100));
    for (i = 0; i < 400; i++) t += leave(500, i & 3);
    printf("left 400 times: %ld\n", t);
retry:
    {
        long big[2000];                     /* 16 KiB: there is no room for two */
        big[1999] = n;
        if (++n < 50) goto retry;           /* back, to before its declaration */
        printf("retried %ld times\n", big[1999] + 1);
    }
    return 0;
}
