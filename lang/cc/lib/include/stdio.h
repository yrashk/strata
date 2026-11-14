#ifndef _STDIO_H
#define _STDIO_H
#include <stddef.h>
#include <stdarg.h>
/* a FILE * is a StrataOS handle plus one */
typedef struct __file FILE;
#define stdin ((FILE *)1)
#define stdout ((FILE *)2)
#define stderr ((FILE *)3)
#define EOF (-1)
int putchar(int c);
int puts(const char *s);
int fputc(int c, FILE *f);
int putc(int c, FILE *f);
int fputs(const char *s, FILE *f);
int fflush(FILE *f);
int printf(const char *fmt, ...);
int fprintf(FILE *f, const char *fmt, ...);
int sprintf(char *s, const char *fmt, ...);
int snprintf(char *s, size_t n, const char *fmt, ...);
int vprintf(const char *fmt, va_list ap);
int vfprintf(FILE *f, const char *fmt, va_list ap);
int vsprintf(char *s, const char *fmt, va_list ap);
int vsnprintf(char *s, size_t n, const char *fmt, va_list ap);
int getchar(void);
int fgetc(FILE *f);
int getc(FILE *f);
char *fgets(char *s, int n, FILE *f);
FILE *fopen(const char *name, const char *mode);
int fclose(FILE *f);
size_t fread(void *p, size_t size, size_t n, FILE *f);
size_t fwrite(const void *p, size_t size, size_t n, FILE *f);
int remove(const char *name);
#endif
