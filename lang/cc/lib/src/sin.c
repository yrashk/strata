int __rempio2(double, double *);
double __ksin(double, double);
double __kcos(double, double);
double sin(double __x)
{
    double __y[2];
    if (__x != __x || __x - __x != 0.0) return __x - __x;
    switch (__rempio2(__x, __y)) {
    case 0: return __ksin(__y[0], __y[1]);
    case 1: return __kcos(__y[0], __y[1]);
    case 2: return -__ksin(__y[0], __y[1]);
    }
    return -__kcos(__y[0], __y[1]);
}
