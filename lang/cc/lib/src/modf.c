double trunc(double);
double copysign(double, double);
/* modf: the integer part to *ip, the fraction returned, both with x's sign */
double modf(double __x, double *__ip)
{
    double __t = trunc(__x);
    *__ip = __t;
    if (__t == __x) return copysign(0.0, __x);      /* an integer, an infinity */
    return __x - __t;
}
