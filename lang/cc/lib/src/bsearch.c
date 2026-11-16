/* bsearch: binary search of a sorted array */
void *bsearch(const void *__key, const void *__base, unsigned long __n, unsigned long __size,
              int (*__cmp)(const void *, const void *))
{
    const char *__b = __base, *__p;
    unsigned long __lo = 0, __hi = __n, __m;
    int __c;
    while (__lo < __hi) {
        __m = __lo + (__hi - __lo) / 2;
        __p = __b + __m * __size;
        __c = __cmp(__key, __p);
        if (!__c) return (void *)__p;
        if (__c < 0) __hi = __m;
        else __lo = __m + 1;
    }
    return 0;
}
