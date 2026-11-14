double log(double);
double log10(double __x)
{
    double __r = log(__x) * 0x1.bcb7b1526e50ep-2, __p = 1.0;
    int __n = (int)(__r + 0.5), __i;
    if (__r > 0.5 && __n < 23 && __r - __n < 1e-12 && __n - __r < 1e-12) {  /* a power of ten? */
        for (__i = 0; __i < __n; __i++) __p = __p * 10.0;
        if (__p == __x) return __n;
    }
    return __r;
}
