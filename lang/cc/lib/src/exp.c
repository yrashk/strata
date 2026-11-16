double ldexp(double, int);
/* exp: x = k ln 2 + r, |r| <= ln 2 / 2; exp(r) from a rational function of r */
double exp(double __x)
{
    double __hi, __lo, __r, __t, __c;
    int __k;
    if (__x != __x) return __x;
    if (__x > 0x1.62e42fefa39efp+9) return 0x1.fffffffffffffp+1023 * 2.0;
    if (__x < -0x1.74910d52d3051p+9) return 0.0;
    __k = (int)(0x1.71547652b82fep+0 * __x + (__x < 0.0 ? -0.5 : 0.5));
    __hi = __x - __k * 0x1.62e42fee00000p-1;
    __lo = __k * 0x1.a39ef35793c76p-33;
    __r = __hi - __lo;
    __t = __r * __r;
    __c = __r - __t * (0x1.555555555553ep-3 + __t * (-0x1.6c16c16bebd93p-9 + __t *
          (0x1.1566aaf25de2cp-14 + __t * (-0x1.bbd41c5d26bf1p-20 + __t * 0x1.6376972bea4d0p-25))));
    return ldexp(1.0 - ((__lo - (__r * __c) / (2.0 - __c)) - __hi), __k);
}
