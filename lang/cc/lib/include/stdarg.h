#ifndef _STDARG_H
#define _STDARG_H
/* every argument of a variadic function is an 8-byte word, in order */
typedef char *va_list;
#ifdef __STRATA_VA__
#define va_start(ap, last) __builtin_va_start(ap, last)
#define va_arg(ap, type) __builtin_va_arg(ap, type)     /* a structure argument is its address */
#else
#define va_start(ap, last) ((ap) = (char *)&(last) + 8)
#define va_arg(ap, type) (*(type *)(((ap) += 8) - 8))
#endif
#define va_copy(d, s) ((d) = (s))
#define va_end(ap) ((void)0)
#endif
