double atan2(double, double);
double sqrt(double);
double acos(double __x)
{
    if (__x > 1.0 || __x < -1.0) return (__x - __x) / (__x - __x);
    return atan2(sqrt((1.0 - __x) * (1.0 + __x)), __x);
}
