double copysign(double __x, double __y)
{
    union { double __d; unsigned long __u; } __v, __w;
    __v.__d = __x;
    __w.__d = __y;
    __v.__u = (__v.__u << 1 >> 1) | (__w.__u >> 63 << 63);
    return __v.__d;
}
