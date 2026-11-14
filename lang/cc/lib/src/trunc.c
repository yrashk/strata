/* trunc: toward zero: the fraction bits are cleared */
double trunc(double __x)
{
    union { double __d; unsigned long __u; } __v;
    int __e;
    __v.__d = __x;
    __e = (int)(__v.__u >> 52 & 0x7ff) - 1023;
    if (__e >= 52) return __x;                  /* an integer already, an infinity, a NaN */
    if (__e < 0) __v.__u = __v.__u >> 63 << 63; /* below 1: a zero of its sign */
    else __v.__u = __v.__u & ~(0xfffffffffffffUL >> __e);
    return __v.__d;
}
