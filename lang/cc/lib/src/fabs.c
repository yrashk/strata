double fabs(double __x)
{
    union { double __d; unsigned long __u; } __v;
    __v.__d = __x;
    __v.__u = __v.__u << 1 >> 1;
    return __v.__d;
}
