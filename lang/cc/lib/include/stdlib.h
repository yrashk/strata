#ifndef _STDLIB_H
#define _STDLIB_H
#include <stddef.h>
#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1
#define RAND_MAX 32767
void exit(int code);
void abort(void);
void *malloc(size_t n);
void free(void *p);
void *calloc(size_t n, size_t size);
void *realloc(void *p, size_t n);
int abs(int x);
long labs(long x);
int atoi(const char *s);
long atol(const char *s);
long strtol(const char *s, char **end, int base);
unsigned long strtoul(const char *s, char **end, int base);
double atof(const char *s);
double strtod(const char *s, char **end);
long double strtold(const char *s, char **end);
#ifdef __STRATA_CC__
float strtof(const char *s, char **end);
#endif
int rand(void);
void srand(unsigned seed);
#endif
