double exp(double);
double fabs(double);
double sinh(double __x)
{
    double __a = fabs(__x), __z, __e;
    if (__a < 0.125) {                          /* the series: the exponentials would cancel */
        __z = __x * __x;
        return __x * (1.0 + __z * (1.0 / 6 + __z * (1.0 / 120 + __z * (1.0 / 5040 + __z * (1.0 / 362880 + __z / 39916800)))));
    }
    if (__a > 709.0) {
        __e = exp(0.5 * __a);
        __e = 0.5 * __e * __e;
    } else {
        __e = exp(__a);
        __e = 0.5 * (__e - 1.0 / __e);
    }
    return __x < 0.0 ? -__e : __e;
}
