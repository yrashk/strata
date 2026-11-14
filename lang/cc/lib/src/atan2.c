double atan(double);
/* atan2: the angle of the point (x, y), in (-pi, pi] */
double atan2(double __y, double __x)
{
    double __pi = 0x1.921fb54442d18p+1, __lo = 0x1.1a62633145c07p-53, __r;
    if (__x != __x || __y != __y) return __x + __y;
    if (__x == 0.0) {
        if (__y == 0.0) return 1.0 / __x < 0.0 ? (1.0 / __y < 0.0 ? -__pi : __pi) : __y;
        return __y < 0.0 ? -0.5 * __pi : 0.5 * __pi;
    }
    if (__x - __x != 0.0 && __y - __y != 0.0)       /* both infinite */
        __r = __x < 0.0 ? 0.75 * __pi : 0.25 * __pi, __r = __y < 0.0 ? -__r : __r;
    else {
        __r = atan(__y / __x);
        if (__x < 0.0) __r = __y < 0.0 || (__y == 0.0 && 1.0 / __y < 0.0) ? (__r - __lo) - __pi : (__r + __lo) + __pi;
    }
    return __r;
}
