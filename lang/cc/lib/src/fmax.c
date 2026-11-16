double fmax(double __x, double __y)
{
    if (__x != __x) return __y;
    if (__y != __y) return __x;
    return __x > __y ? __x : __y;
}
