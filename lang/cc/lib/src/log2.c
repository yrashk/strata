double log(double);
double frexp(double, int *);
double log2(double __x)
{
    int __e;
    if (__x > 0.0 && __x + __x != __x && frexp(__x, &__e) == 0.5) return __e - 1;   /* a power of two */
    return log(__x) * 0x1.71547652b82fep+0;
}
