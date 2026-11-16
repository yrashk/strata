double sqrt(double);
double fabs(double);
/* hypot: sqrt(x^2 + y^2) without the squares overflowing */
double hypot(double __x, double __y)
{
    double __t;
    __x = fabs(__x);
    __y = fabs(__y);
    if (__x < __y) { __t = __x; __x = __y; __y = __t; }
    if (__x == 0.0 || __x + __x == __x) return __x;
    __t = __y / __x;
    return __x * sqrt(1.0 + __t * __t);
}
