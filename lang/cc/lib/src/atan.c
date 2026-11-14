double fabs(double);
static const double __atanhi[] = { 0x1.dac670561bb4fp-2, 0x1.921fb54442d18p-1,
                                   0x1.f730bd281f69bp-1, 0x1.921fb54442d18p+0 };
static const double __atanlo[] = { 0x1.a2b7f222f65e2p-56, 0x1.1a62633145c07p-55,
                                   0x1.007887af0cbbdp-56, 0x1.1a62633145c07p-54 };
/* atan: the argument is brought below 7/16 by one of four identities
   (around 0.5, 1, 1.5 and infinity), then a polynomial */
double atan(double __x)
{
    double __a, __z, __w, __s;
    int __id = -1;
    if (__x != __x || __x == 0.0) return __x;
    __a = fabs(__x);
    if (__a >= 0.4375) {
        if (__a < 0.6875) { __id = 0; __a = (2.0 * __a - 1.0) / (2.0 + __a); }
        else if (__a < 1.1875) { __id = 1; __a = (__a - 1.0) / (__a + 1.0); }
        else if (__a < 2.4375) { __id = 2; __a = (__a - 1.5) / (1.0 + 1.5 * __a); }
        else { __id = 3; __a = -1.0 / __a; }
    }
    __z = __a * __a;
    __w = __z * __z;
    __s = __z * (0x1.555555555550dp-2 + __w * (0x1.24924920083ffp-3 + __w * (0x1.745cdc54c206ep-4 +
          __w * (0x1.10d66a0d03d51p-4 + __w * (0x1.97b4b24760debp-5 + __w * 0x1.0ad3ae322da11p-6))))) +
          __w * (-0x1.999999998ebc4p-3 + __w * (-0x1.c71c6fe231671p-4 + __w * (-0x1.3b0f2af749a6dp-4 +
          __w * (-0x1.dde2d52defd9ap-5 + __w * -0x1.2b4442c6a6c2fp-5))));
    if (__id < 0) return __x - __x * __s;
    __a = __atanhi[__id] - ((__a * __s - __atanlo[__id]) - __a);
    return __x < 0.0 ? -__a : __a;
}
