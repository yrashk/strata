double exp(double);
double log(double);
double trunc(double);
double fabs(double);
/* pow: by squaring when y is an integer (exact while the powers are), else exp(y log x) */
double pow(double __x, double __y)
{
    double __r = 1.0, __b, __n;
    if (__y == 0.0 || __x == 1.0) return 1.0;
    if (__x != __x || __y != __y) return __x + __y;
    if (trunc(__y) == __y && fabs(__y) < 2147483648.0) {
        __b = __x;
        for (__n = fabs(__y); __n >= 1.0; __n = trunc(__n * 0.5)) {
            if (__n * 0.5 != trunc(__n * 0.5)) __r = __r * __b;
            __b = __b * __b;
        }
        return __y < 0.0 ? 1.0 / __r : __r;
    }
    if (__x < 0.0) {
        if (__x - __x != 0.0) return __y > 0.0 ? -__x : 0.0;    /* the negative infinity */
        if (trunc(__y) != __y) return (__x - __x) / (__x - __x);
        return exp(__y * log(-__x));            /* a huge integer: even */
    }
    if (__x == 0.0) return __y < 0.0 ? 1.0 / (__x * __x) : 0.0;
    return exp(__y * log(__x));
}
