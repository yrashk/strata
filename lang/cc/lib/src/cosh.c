double exp(double);
double fabs(double);
double cosh(double __x)
{
    double __a = fabs(__x), __e;
    if (__a > 709.0) {
        __e = exp(0.5 * __a);
        return 0.5 * __e * __e;
    }
    __e = exp(__a);
    return 0.5 * (__e + 1.0 / __e);
}
