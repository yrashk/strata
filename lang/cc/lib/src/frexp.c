/* frexp: x = m 2^e with 0.5 <= |m| < 1 */
double frexp(double __x, int *__e)
{
    union { double __d; unsigned long __u; } __v;
    int __k;
    __v.__d = __x;
    __k = __v.__u >> 52 & 0x7ff;
    *__e = 0;
    if (__k == 0x7ff || __x == 0.0) return __x;
    if (!__k) {                                 /* subnormal: scale it up first */
        __v.__d = __x * 0x1.0000000000000p+54;    /* 2^54 */
        __k = (int)(__v.__u >> 52 & 0x7ff) - 54;
    }
    *__e = __k - 1022;
    __v.__u = (__v.__u & ~(0x7ffUL << 52)) | 1022UL << 52;
    return __v.__d;
}
