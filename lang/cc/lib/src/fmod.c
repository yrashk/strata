/* fmod: x - n y, n the quotient toward zero; exact: the long division of
   the two significands, a bit at a time */
double fmod(double __x, double __y)
{
    union { double __d; unsigned long __u; } __a, __b;
    unsigned long __mx, __my, __s;
    int __ex, __ey;
    __a.__d = __x;
    __b.__d = __y;
    __s = __a.__u >> 63 << 63;
    __a.__u = __a.__u << 1 >> 1;
    __b.__u = __b.__u << 1 >> 1;
    __ex = __a.__u >> 52;
    __ey = __b.__u >> 52;
    if (__b.__u == 0 || __ex == 0x7ff || __b.__u > 0x7ffUL << 52) return (__x * __y) / (__x * __y);
    if (__a.__u < __b.__u) return __x;
    if (__a.__u == __b.__u) return 0.0 * __x;
    __mx = __a.__u & 0xfffffffffffffUL;
    __my = __b.__u & 0xfffffffffffffUL;
    if (__ex) __mx = __mx | 1UL << 52;          /* subnormals count from exponent 1 */
    else __ex = 1;
    if (__ey) __my = __my | 1UL << 52;
    else __ey = 1;
    for (; __ex > __ey; __ex--) {
        if (__mx >= __my) __mx = __mx - __my;
        __mx = __mx << 1;
    }
    if (__mx >= __my) __mx = __mx - __my;
    if (!__mx) return 0.0 * __x;
    while (!(__mx >> 52) && __ex > 1) { __mx = __mx << 1; __ex--; }
    if (__mx >> 52) __a.__u = (__mx & 0xfffffffffffffUL) | (unsigned long)__ex << 52;
    else __a.__u = __mx;
    __a.__u = __a.__u | __s;
    return __a.__d;
}
