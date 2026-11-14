/* sin(x + y) for |x| <= pi/4, y the tail of x */
double __ksin(double __x, double __y)
{
    double __z = __x * __x, __v = __z * __x, __r;
    __r = 0x1.111111110f8a6p-7 + __z * (-0x1.a01a019c161d5p-13 + __z * (0x1.71de357b1fe7dp-19 +
          __z * (-0x1.ae5e68a2b9cebp-26 + __z * 0x1.5d93a5acfd57cp-33)));
    return __x - ((__z * (0.5 * __y - __v * __r) - __y) - __v * -0x1.5555555555549p-3);
}
