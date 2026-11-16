double frexp(double, int *);
/* log: x = 2^k (1 + f), sqrt(2)/2 < 1 + f < sqrt(2); log(1 + f) from s = f / (2 + f) */
double log(double __x)
{
    double __f, __s, __z, __w, __r, __h;
    int __k;
    if (__x != __x) return __x;
    if (__x == 0.0) return -1.0 / (__x * __x);
    if (__x < 0.0) return (__x - __x) / (__x - __x);
    if (__x + __x == __x) return __x;
    __f = frexp(__x, &__k);
    if (__f < 0x1.6a09e667f3bcdp-1) { __f = __f + __f; __k--; }
    __f = __f - 1.0;
    __s = __f / (2.0 + __f);
    __z = __s * __s;
    __w = __z * __z;
    __r = __z * (0x1.5555555555593p-1 + __w * (0x1.2492494229359p-2 + __w *
          (0x1.7466496cb03dep-3 + __w * 0x1.2f112df3e5244p-3))) +
          __w * (0x1.999999997fa04p-2 + __w * (0x1.c71c51d8e78afp-3 + __w * 0x1.39a09d078c69fp-3));
    __h = 0.5 * __f * __f;
    return __k * 0x1.62e42fee00000p-1 - ((__h - (__s * (__h + __r) + __k * 0x1.a39ef35793c76p-33)) - __f);
}
