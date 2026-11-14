/* ldexp: x 2^n */
double ldexp(double __x, int __n)
{
    union { double __d; unsigned long __u; } __v;
    if (__n > 1023) {                           /* in steps, so that the last one rounds or overflows */
        __x = __x * 0x1.0000000000000p+1023; /* 2^1023 */
        __n = __n - 1023;
        if (__n > 1023) {
            __x = __x * 0x1.0000000000000p+1023;
            __n = __n - 1023;
            if (__n > 1023) __n = 1023;
        }
    } else if (__n < -1022) {
        __x = __x * 0x1.0000000000000p-969;    /* 2^-969: 2^-1022 2^53 */
        __n = __n + 969;
        if (__n < -1022) {
            __x = __x * 0x1.0000000000000p-969;
            __n = __n + 969;
            if (__n < -1022) __n = -1022;
        }
    }
    __v.__u = (unsigned long)(__n + 1023) << 52;
    return __x * __v.__d;
}
