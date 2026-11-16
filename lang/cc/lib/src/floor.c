double trunc(double);
double floor(double __x)
{
    double __t = trunc(__x);
    return __t > __x ? __t - 1.0 : __t;
}
