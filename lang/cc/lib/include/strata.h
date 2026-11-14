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

/* Intrinsics. Each of these compiles to one instruction; no declaration is
   needed (and none must be given). TAG, CAP, CD, CS, EP, CSR and MASK are
   integer constant expressions, encoded in the instruction: a transfer tag
   0..15, a capability register 0..15, a CSR number, a mask of tags. The
   other arguments are ordinary expressions. Results are long.

   __tget(TAG, ls, CAP, off, n)   far -> the data Local Store at ls
   __tput(TAG, ls, CAP, off, n)   the data Local Store -> far
   __tgetx(TAG, ils, CAP, off, n) far -> the instruction Local Store
   __twait(MASK)                  wait for these transfers
   __tpoll(MASK)                  -> the tags of MASK still in flight
   __tany(mask)                   wait for any of them, or a capability
   __tamo_add(CAP, addr, v)       far atomics: also _swap _cas _and _or
   __cbase(CAP) __clen(CAP) __cperms(CAP) __cvalid(CAP)
   __cmov(CD, CS) __cjoin(CD, CS) __cshare(CD, CS)
   __csplit(CD, CS, n) __crestrict(CD, CS, perms) __cclear(CD)
   __cgive(CS, core) __ctake(CD) __cpoll() __csend(CS, EP)
   __csrr(CSR) __csrw(CSR, v)     e.g. CSR_CYCLE, CSR_COREID below
   __svc(fn, a1, a2, a3, a4, a5)  the supervisor call (StrataOS: doc/strataos.md)
   __halt(code)                   end the thread
   __ltag(addr) __linst(addr)     the software cache's tag table              */
#define CSR_CYCLE 0
#define CSR_INSTRET 1
#define CSR_COREID 7
#define CSR_NCORES 11
#define CSR_XSLOT 25
#endif
