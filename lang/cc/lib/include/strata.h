#ifndef _STRATA_H
#define _STRATA_H
/* What is particular to Strata: C sees only the data Local Store. The
   arena (system memory behind capability c0, 832 KiB) is read and written
   with transfers; offset and n are multiples of 8 and the buffer is 8-byte
   aligned. Offsets from 0x7F000 belong to the system. */
void far_read(unsigned long offset, void *buffer, unsigned long n);
void far_write(unsigned long offset, const void *buffer, unsigned long n);
/* StrataOS handles: 0 stdin, 1 stdout, 2 stderr */
int open(const char *name, int mode);   /* 0 read, 1 write, 2 append */
long read(int fd, void *buffer, unsigned long n);
long write(int fd, const void *buffer, unsigned long n);
int close(int fd);
int unlink(const char *name);
void _exit(int code);
#endif
