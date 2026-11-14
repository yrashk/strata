/* strata.h for cc.c built on another machine (host.c): what the real
   <strata.h> gives the compiler when it runs in StrataOS */
#ifndef _STRATA_H
#define _STRATA_H
void far_read(unsigned long offset, void *buffer, unsigned long n);
void far_write(unsigned long offset, const void *buffer, unsigned long n);
int cc_open(const char *name, int mode);
#define open cc_open
#define main cc_main
#define STK_MIN 0               /* the stack is the host's */
#endif
