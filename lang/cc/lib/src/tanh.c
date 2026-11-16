double exp(double);
double fabs(double);
double sinh(double);
double tanh(double __x)
{
    double __a = fabs(__x), __e;
    if (__x != __x) return __x;
    if (__a < 0.125) {
        __e = exp(__a);
        return sinh(__x) / (0.5 * (__e + 1.0 / __e));
    }
    if (__a > 20.0) return __x < 0.0 ? -1.0 : 1.0;
    __e = exp(2.0 * __a);
    __e = (__e - 1.0) / (__e + 1.0);
    return __x < 0.0 ? -__e : __e;
}
