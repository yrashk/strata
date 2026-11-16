/* qsort: Shell's sort, the elements exchanged byte by byte */
void qsort(void *__base, unsigned long __n, unsigned long __size, int (*__cmp)(const void *, const void *))
{
    char *__b = __base, *__p, *__q, __t;
    unsigned long __gap, __i, __j, __k;
    for (__gap = 1; __gap < __n / 3; __gap = 3 * __gap + 1) ;
    for (; __gap; __gap = __gap / 3)
        for (__i = __gap; __i < __n; __i++)
            for (__j = __i; __j >= __gap; __j = __j - __gap) {
                __p = __b + (__j - __gap) * __size;
                __q = __b + __j * __size;
                if (__cmp(__p, __q) <= 0) break;
                for (__k = 0; __k < __size; __k++) { __t = __p[__k]; __p[__k] = __q[__k]; __q[__k] = __t; }
            }
}
