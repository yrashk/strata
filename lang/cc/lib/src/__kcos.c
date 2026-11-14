/* cos(x + y) for |x| <= pi/4, y the tail of x */
double __kcos(double __x, double __y)
{
    double __z = __x * __x, __w, __r;
    __r = __z * (0x1.555555555554cp-5 + __z * (-0x1.6c16c16c15177p-10 + __z * (0x1.a01a019cb1590p-16 +
          __z * (-0x1.27e4f809c52adp-22 + __z * (0x1.1ee9ebdb4b1c4p-29 + __z * -0x1.8fae9be8838d4p-37)))));
    __w = 1.0 - 0.5 * __z;
    return __w + (((1.0 - __w) - 0.5 * __z) + (__z * __r - __x * __y));
}
