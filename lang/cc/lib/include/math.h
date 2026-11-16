#ifndef _MATH_H
#define _MATH_H
/* The functions are C source in cc.lib (lang/cc/lib/src), compiled with the
   program that calls them. double only. */
#define HUGE_VAL (1e308 * 10.0)
#define INFINITY (1e308 * 10.0)
#define NAN (0.0 / 0.0)
#define M_E 2.7182818284590452354
#define M_LN2 0.69314718055994530942
#define M_LN10 2.30258509299404568402
#define M_PI 3.14159265358979323846
#define M_PI_2 1.57079632679489661923
#define M_PI_4 0.78539816339744830962
#define M_SQRT2 1.41421356237309504880
#define isnan(x) ((x) != (x))
#define isinf(x) ((x) == (x) && (x) - (x) != 0.0)
#define isfinite(x) ((x) - (x) == 0.0)
double fabs(double);
double copysign(double, double);
double floor(double);
double ceil(double);
double trunc(double);
double round(double);
double fmin(double, double);
double fmax(double, double);
double fmod(double, double);
double frexp(double, int *);
double ldexp(double, int);
double modf(double, double *);
double sqrt(double);
double hypot(double, double);
double exp(double);
double log(double);
double log2(double);
double log10(double);
double pow(double, double);
double sin(double);
double cos(double);
double tan(double);
double asin(double);
double acos(double);
double atan(double);
double atan2(double, double);
double sinh(double);
double cosh(double);
double tanh(double);
#endif
