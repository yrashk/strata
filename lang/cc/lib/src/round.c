double trunc(double);
/* round: to the nearest integer, halves away from zero */
double round(double __x)
{
    double __t = trunc(__x), __f = __x - __t;
    if (__f >= 0.5) return __t + 1.0;
    if (__f <= -0.5) return __t - 1.0;
    return __t;
}
