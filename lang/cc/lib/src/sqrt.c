double frexp(double, int *);
double ldexp(double, int);
/* sqrt: Newton's iteration on the significand, from a straight line */
double sqrt(double __x)
{
    double __m, __y;
    int __e, __i;
    if (__x != __x || __x == 0.0) return __x;
    if (__x < 0.0) return (__x - __x) / (__x - __x);
    if (__x + __x == __x) return __x;           /* the infinity */
    __m = frexp(__x, &__e);                     /* 0.5 <= m < 1 */
    if (__e & 1) { __m = __m + __m; __e--; }    /* an even exponent: 0.5 <= m < 2 */
    __y = 0.41731 + 0.59016 * __m;
    for (__i = 0; __i < 6; __i++) __y = 0.5 * (__y + __m / __y);
    return ldexp(__y, __e / 2);
}
