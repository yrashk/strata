/* math.c: <math.h>. The functions are C source in the library, compiled
 * with the program that calls them (lang/cc/lib/src); the arithmetic under
 * them is the software floating point of every C program here.
 *
 * In StrataOS:   cc /src/math.c
 *                math          (a table)      math 2.5      (one argument)
 */
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

void row(double x)
{
    printf("%8.4f %12.9f %12.9f %12.9f %14.9f %12.9f\n", x, sqrt(fabs(x)), sin(x), cos(x), exp(x), atan(x));
}

/* the integral of f over [a, b] by Simpson's rule */
double simpson(double (*f)(double), double a, double b, int n)
{
    double h = (b - a) / n, s = f(a) + f(b);
    int i;
    for (i = 1; i < n; i++) s += f(a + i * h) * (i & 1 ? 4 : 2);
    return s * h / 3;
}

double bell(double x) { return exp(-x * x / 2) / sqrt(2 * M_PI); }

int main(int argc, char **argv)
{
    double x, ip;
    int e;

    printf("       x      sqrt|x|       sin x        cos x          exp x       atan x\n");
    if (argc > 1) {
        row(atof(argv[1]));
        return 0;
    }
    for (x = -2; x <= 2; x += 0.5) row(x);
    printf("pi = %.15f = 4 atan 1 = %.15f\n", M_PI, 4 * atan(1.0));
    printf("log 10 = %.12f, log10 1000 = %g, log2 1024 = %g\n", log(10.0), log10(1000.0), log2(1024.0));
    printf("pow: 2^10 = %g, 10^15 = %.0f, 2^0.5 = %.12f, 2^-2 = %g\n", pow(2, 10), pow(10, 15), pow(2, 0.5), pow(2, -2));
    printf("floor, ceil, round, trunc of -2.5: %g %g %g %g\n", floor(-2.5), ceil(-2.5), round(-2.5), trunc(-2.5));
    printf("fmod(10, 3) = %g, fmod(-7.5, 2) = %g, hypot(3, 4) = %g\n", fmod(10, 3), fmod(-7.5, 2), hypot(3, 4));
    x = frexp(48.0, &e);
    printf("48 = %g * 2^%d, ldexp(0.75, 6) = %g", x, e, ldexp(0.75, 6));
    x = modf(3.25, &ip);
    printf(", modf(3.25) = %g + %g\n", ip, x);
    printf("atan2(1, -1) = %.12f, asin 1 = %.12f, acos 0.5 = %.12f\n", atan2(1, -1), asin(1.0), acos(0.5));
    printf("sinh 1 = %.12f, cosh 1 = %.12f, tanh 1 = %.12f, tan 1 = %.12f\n", sinh(1.0), cosh(1.0), tanh(1.0), tan(1.0));
    printf("sin 1e6 = %.12f, cos 1e9 = %.9f\n", sin(1e6), cos(1e9));
    printf("sqrt -1 is %s, 1/0 is %s, exp 1000 is %s\n", isnan(sqrt(-1.0)) ? "not a number" : "a number",
           isinf(HUGE_VAL) ? "infinite" : "finite", isinf(exp(1000.0)) ? "infinite" : "finite");
    printf("the bell curve from -1 to 1: %.9f\n", simpson(bell, -1, 1, 20));
    return 0;
}
