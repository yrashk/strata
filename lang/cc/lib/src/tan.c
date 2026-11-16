int __rempio2(double, double *);
double __ksin(double, double);
double __kcos(double, double);
double tan(double __x)
{
    double __y[2], __s, __c;
    int __n;
    if (__x != __x || __x - __x != 0.0) return __x - __x;
    __n = __rempio2(__x, __y);
    __s = __ksin(__y[0], __y[1]);
    __c = __kcos(__y[0], __y[1]);
    return __n & 1 ? -__c / __s : __s / __c;
}
