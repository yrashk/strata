/* Strata prototype: encoding constants shared by the assembler and the
 * simulator harness. Mirrors rtl/strata_pkg.sv; keep the two in step. */
#ifndef STRATA_ISA_H
#define STRATA_ISA_H

#define DLS_BYTES 65536u
#define ILS_BYTES 65536u
#define BOOTROM_BYTES 4096u /* what a core-control reset reloads: the first 4 KiB of each Local Store's boot image (the boot ROM); the rest is cleared */
#define T2_BYTES  262144u
#define T3_BYTES  0x4000000u /* 64 MiB; the top 16 MiB is the framebuffer window */
#define GRAN_SHIFT 18        /* revocation granules of T2 and T3: 256 KiB */
#define GRAN_BYTES (1u << GRAN_SHIFT)

/* .stx image section kinds */
enum { SK_ILS = 1, SK_DLS = 2, SK_T3 = 3, SK_T2 = 4 };

enum {
  OP_ALU = 0x00, OP_ADDI = 0x01, OP_ANDI = 0x02, OP_ORI = 0x03, OP_XORI = 0x04,
  OP_SLLI = 0x05, OP_SRLI = 0x06, OP_SRAI = 0x07, OP_SLTI = 0x08, OP_SLTIU = 0x09,
  OP_LUI = 0x0A,
  OP_LD = 0x10, OP_LW = 0x11, OP_LWU = 0x12, OP_LH = 0x13, OP_LHU = 0x14,
  OP_LB = 0x15, OP_LBU = 0x16,
  OP_SD = 0x18, OP_SW = 0x19, OP_SH = 0x1A, OP_SB = 0x1B,
  OP_BEQ = 0x20, OP_BNE = 0x21, OP_BLT = 0x22, OP_BGE = 0x23, OP_BLTU = 0x24,
  OP_BGEU = 0x25, OP_JAL = 0x28, OP_JALR = 0x29,
  OP_XFER = 0x30, OP_TWAIT = 0x31, OP_TPOLL = 0x32, OP_TAMO = 0x33, OP_CAP = 0x34,
  OP_CSRR = 0x38, OP_CSRW = 0x39, OP_SYS = 0x3A, OP_LTAG = 0x3B, OP_LINST = 0x3C,
  OP_XMAP = 0x3D, OP_XCALL = 0x3E, OP_CAP2 = 0x35, OP_TANY = 0x36,
};

enum { ALU_ADD, ALU_SUB, ALU_AND, ALU_OR, ALU_XOR, ALU_SLL, ALU_SRL, ALU_SRA,
       ALU_SLT, ALU_SLTU, ALU_MUL, ALU_MULHU, ALU_DIVU, ALU_REMU, ALU_DIV, ALU_REM };

enum { XF_GET = 0, XF_PUT = 1, XF_GETX = 2 };
enum { AMO_ADD = 0, AMO_SWAP = 1, AMO_CAS = 2, AMO_AND = 3, AMO_OR = 4 };
enum { CF_MOV, CF_SPLIT, CF_JOIN, CF_SHARE, CF_ATOM, CF_RESTR, CF_BASE, CF_LEN,
       CF_PERMS, CF_GIVE, CF_TAKE, CF_CLEAR, CF_SAVE, CF_RESTORE, CF_VALID, CF_POLL };
enum { SYS_HALT = 0, SYS_ERET = 1, SYS_SVC = 2 };
/* trap cause of svc (the full list: common/stx.h stx_cause_names) */
enum { CAUSE_SVC = 14 };
/* second capability group (OP_CAP2, funct[3:0]) */
enum { C2_DOM, C2_REVOKE, C2_UNDOM, C2_SEND, C2_RECV, C2_MKEP, C2_SAVEX, C2_RESTOREX };

enum { CSR_CYCLE, CSR_INSTRET, CSR_CAUSE, CSR_EPC, CSR_TVAL, CSR_TVEC, CSR_CCR,
       CSR_COREID, CSR_TTAG, CSR_TDATA, CSR_TGEOM, CSR_NCORES, CSR_SCRATCH,
       CSR_STALLS, CSR_TAKEFROM, CSR_COREBASE, CSR_CORECOUNT, CSR_RESERVED17,
       CSR_STATUS, CSR_UCAUSE, CSR_UEPC, CSR_UTVAL, CSR_UTVEC, CSR_SSCRATCH, CSR_IPEND,
       CSR_XSLOT };

#endif
