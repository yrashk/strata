double fmod(double, double);
/* x = n pi/2 + (y[0] + y[1]), |y[0]| <= pi/4; -> n mod 4. pi/2 is taken in
   two parts, the first of 33 bits, so that n times it is exact while n is
   below 2^20. A larger argument first loses its whole turns: the remainder
   by the first part of 2 pi is exact, and the quotient times the second
   part is taken from it. The accuracy that is left falls as x grows; beyond
   2^53 there is none, and the result is only one of the right range. */
int __rempio2(double __x, double *__y)
{
    double __n, __r, __w;
    long __k;
    if (__x > 1048576.0 || __x < -1048576.0) {
        if (__x > 9e15 || __x < -9e15) __x = fmod(__x, 0x1.921fb54442d18p+2);
        else {
            __r = fmod(__x, 0x1.921fb54400000p+2);
            __x = __r - (__x - __r) / 0x1.921fb54400000p+2 * 0x1.0b4611a626331p-32;
        }
    }
    __n = __x * 0x1.45f306dc9c883p-1;
    __k = (long)(__n + (__n < 0.0 ? -0.5 : 0.5));
    __n = __k;
    __r = __x - __n * 0x1.921fb54400000p+0;
    __w = __n * 0x1.0b4611a626331p-34;
    __y[0] = __r - __w;
    __y[1] = (__r - __y[0]) - __w;
    return __k & 3;
}
