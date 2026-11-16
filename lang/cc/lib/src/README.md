# The library in C

`libc.s` is the library every program carries. The functions here are C
source, one file each, packed into `cc.lib` under their own names
(`qsort.c` is `qsort`). When a program has been read and still uses a
function that neither it nor `libc.s` defines, `cc` looks for that member
and compiles it as if it followed the program; a source may need others in
turn (`pow` needs `exp` and `log`). A program pays only for what it calls.

Rules for a file here:

- its name is the function's, and it defines that function (helpers shared
  by several are files of their own: `__rempio2.c`, `__ksin.c`, `__kcos.c`);
- it includes nothing and declares what it calls itself;
- every other identifier in it begins with two underscores: the program's
  macros and type names are still defined when it is compiled.

The bootstrap compiler (`cc0`) does not have this: its programs are limited
to `libc.s`.

The mathematical functions follow the classic methods: the argument is
reduced, then a polynomial. Measured against another library on random
arguments, results are within a few units in the last place; the
exceptions are `sin`, `cos` and `tan` of arguments beyond about 1e9, which
lose accuracy as the argument grows (nothing is left at 2^53: the result is
then only a number between -1 and 1), and `pow` with a fractional exponent, whose
error grows with the logarithm of the result (twelve digits are right at
the ends of the range). `pow` with an integer exponent multiplies, and is
exact while the powers are.

The coefficients of the polynomials and the split constants (`exp`, `log`,
`sin`, `cos`, `atan` and their helpers) are those of fdlibm:

    Copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.
    Developed at SunPro, a Sun Microsystems, Inc. business.
    Permission to use, copy, modify, and distribute this
    software is freely granted, provided that this notice
    is preserved.
