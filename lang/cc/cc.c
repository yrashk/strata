/* cc.c: the Strata C compiler.
 *
 *   cc [-o OUT] [-p] [-h KIB] FILE.c
 *
 * It reads C source and writes a StrataOS program image directly: no
 * assembler, no linker; the run-time library comes from /bin/cc.lib at
 * fixed addresses. -p pages the program's code in 4 KiB units; -h sizes
 * the heap.
 *
 * This is the compiler; cc.s, in assembly, is the bootstrap compiler that
 * can compile it (lang/cc/DESIGN.md, section 6). It is written in the C it
 * compiles, and within what a StrataOS program has: 40 KiB of data Local
 * Store for its tables (symbols, types, the value stack), the arena behind
 * far_read / far_write for everything large (the source text, identifiers,
 * macros, fixups and the image being built). With lang/cc/host/ in place of
 * StrataOS the same file is the cross compiler, build/strata-cc.
 *
 * One pass, no tree. Expressions leave descriptors of values on a value
 * stack (a constant, a register, an lvalue not loaded yet, a comparison not
 * made yet, pending jumps); code is emitted when an operation needs a value
 * in a register.
 *
 * For the bootstrap compiler's sake: functions are defined before they are
 * used where that is possible, and each compiles to less than 4 KiB.
 */
#include <strata.h>

/* ---- the arena (offsets); 0x10000..0x4FFFF hold this program's own code units ---- */
#define A_PT     0x00000        /* the parameter types of function types, 4 bytes each */
#define A_CS     0x01000        /* the cases of the switch statements open, 16 bytes each */
#define A_IDH    0x02000        /* identifier hash heads, 4 bytes each */
#define A_SV     0x02800        /* the input stack as scan_mark found it */
#define A_FIX    0x03000        /* fixups, 16 bytes each */
#define A_FIXEND 0x10000
#define A_LIB    0x50000        /* cc.lib, up to its member cc.units */
#define A_LIBEND 0x58000
#define A_ID     0x58000        /* identifier records */
#define A_IDEND  0x62000
#define A_MAC    0x62000        /* macro records and bodies */
#define A_MACEND 0x66000
#define A_XH     0x66000        /* macro expansions in progress */
#define A_XHEND  0x6A000
#define A_INC    0x6A000        /* included files, nested */
#define A_INCEND 0x6F000
#define A_SRC    0x6F000        /* a window on the source file */
#define A_SRCEND 0x7F000
#define A_CODE   0x80000        /* the image: code */
#define A_CODEEND 0xC0000
#define A_DATA   0xC0000        /* the image: D-LS from 0 */
#define A_RES    0xCA000        /* the image: the resident library, when the code is paged */
#define A_TMP    0xCD000        /* a function being moved to the next code unit */

/* ---- tokens: a punctuator of one character is its ASCII code ---- */
#define T_EOF 0
#define T_ID 128
#define T_NUM 129
#define T_STR 130
#define T_EQ 132
#define T_NE 133
#define T_LE 134
#define T_GE 135
#define T_SHL 136
#define T_SHR 137
#define T_LAND 138
#define T_LOR 139
#define T_INC 140
#define T_DEC 141
#define T_ARROW 142
#define T_ELL 143
#define T_ASG 144               /* op= : T_ASG + n for + - * / % & | ^ << >> */
#define K_FIRST 160
#define K_AUTO 160
#define K_BREAK 161
#define K_CASE 162
#define K_CHAR 163
#define K_CONST 164
#define K_CONTINUE 165
#define K_DEFAULT 166
#define K_DO 167
#define K_DOUBLE 168
#define K_ELSE 169
#define K_ENUM 170
#define K_EXTERN 171
#define K_FLOAT 172
#define K_FOR 173
#define K_GOTO 174
#define K_IF 175
#define K_INLINE 176
#define K_INT 177
#define K_LONG 178
#define K_REGISTER 179
#define K_RESTRICT 180
#define K_RETURN 181
#define K_SHORT 182
#define K_SIGNED 183
#define K_SIZEOF 184
#define K_STATIC 185
#define K_STRUCT 186
#define K_SWITCH 187
#define K_TYPEDEF 188
#define K_UNION 189
#define K_UNSIGNED 190
#define K_VOID 191
#define K_VOLATILE 192
#define K_WHILE 193
#define K_BOOL 194

/* ---- types: a type is an index into ty[] ---- */
#define TK_VOID 0
#define TK_BOOL 1
#define TK_CHAR 2
#define TK_SHORT 3
#define TK_INT 4
#define TK_LONG 5
#define TK_FLOAT 6
#define TK_DOUBLE 7
#define TK_PTR 8
#define TK_ARRAY 9
#define TK_FUNC 10
#define TK_STRUCT 11
#define TK_UNION 12
#define TF_UNS 1
#define TF_VARIADIC 2
#define TF_OLD 4
#define Y_VOID 0
#define Y_BOOL 1
#define Y_CHAR 2
#define Y_UCHAR 3
#define Y_SHORT 4
#define Y_USHORT 5
#define Y_INT 6
#define Y_UINT 7
#define Y_LONG 8
#define Y_ULONG 9
#define Y_FLOAT 10
#define Y_DOUBLE 11
#define Y_CHARP 12
#define Y_VOIDP 13
#define Y_FUNC0 14              /* int (), for functions used undeclared */
#define NTY 600
#define NPT 1024

struct ty {
    unsigned char kind, flags, align, x;
    int size;
    unsigned short base;        /* pointed-to, element or return type */
    unsigned short aux;         /* struct: first member; function: its first parameter type */
};                              /* kind, flags, align, x: x is 1 for a complete struct;
                                   size: bytes (0: incomplete); function: parameters.
                                   An array whose size is not a constant has x = 3 and
                                   its size, computed when it was declared, in the frame
                                   word aux; in a parameter list it waits for the
                                   function's entry: x = 4, size = the dimension's text
                                   kept in the arena, or x = 5, size = the count, when
                                   only the element type is variable */

/* ---- symbols: a symbol is an index into sy[]; 0 is none ---- */
#define SC_AUTO 1
#define SC_STATIC 2
#define SC_FUNC 3
#define SC_TYPEDEF 4
#define SC_ENUM 5
#define SC_MEMBER 6
#define SC_TAG 7
#define SF_DEF 1                /* defined: a function's body, an object's storage */
#define SF_S0 2                 /* a local addressed from s0 */
#define SF_EXT 4                /* no address yet */
#define SF_REF 8                /* the frame word holds the object's address */
#define SF_VLA 16               /* ... which malloc gave: a variable-length array */
#define NSY 700

struct sym {
    int id;                     /* its identifier record (arena offset) */
    unsigned short type;
    unsigned short prev;        /* the symbol this one hides; member: the next one */
    unsigned short aux;         /* scope depth; member: first bit | width << 8 */
    unsigned char cls, flags;
    int val;                    /* frame offset, address, enum value, member offset */
};

/* ---- identifier record in the arena: 16 bytes and the name ---- */
struct idr {
    int next;                   /* next of the hash chain */
    int mac;                    /* its macro record, or 0 */
    unsigned short sym, tag;    /* what it names now */
    unsigned char kw, len;
    unsigned short x;
    char name[64];
};

/* ---- value stack ---- */
#define VK_CONST 1              /* the constant val (plus sym's address) */
#define VK_REG 2                /* in evaluation register reg */
#define VK_LOC 3                /* lvalue at val(base register reg) */
#define VK_GLOB 4               /* lvalue at address val (plus sym's) */
#define VK_IND 5                /* lvalue at val(evaluation register reg) */
#define VK_SAVED 6              /* lvalue at val(the address kept in frame slot) */
#define VK_LADDR 7              /* the address reg + val, not computed yet */
#define VK_JMP 8                /* where control goes: val = a chain of jumps */
#define VK_CMP 9                /* a comparison not made yet: registers reg and val, condition flags */
#define VK_TMP 10               /* a value kept in the frame word at val */
#define VF_S0 1                 /* VK_LOC, VK_LADDR: from s0, not sp */
#define VF_INV 2                /* VK_JMP: the jumps are taken when it is false */
#define VF_DIRTY 4              /* VK_REG, VK_TMP: the bits above the type's width are not its extension */
#define NVS 24

struct val {
    unsigned char kind, reg, flags, bw;     /* bw: bit-field width, 0 if none */
    unsigned short type, sym;
    long val;
    int slot;
    int boff;                               /* bit-field: first bit */
};

/* ---- fixups (arena): loc, identifier, addend, kind ---- */
#define FK_JAL 1
#define FK_LUI 2
#define FK_MEM 3
#define FK_DATA 4

/* ---- the machine ---- */
#define OP_ADDI 1
#define OP_ANDI 2
#define OP_ORI 3
#define OP_XORI 4
#define OP_SLLI 5
#define OP_SRLI 6
#define OP_SRAI 7
#define OP_SLTI 8
#define OP_SLTIU 9
#define OP_LUI 10
#define OP_LD 16
#define OP_LW 17
#define OP_LWU 18
#define OP_LH 19
#define OP_LHU 20
#define OP_LB 21
#define OP_LBU 22
#define OP_SD 24
#define OP_SW 25
#define OP_SH 26
#define OP_SB 27
#define OP_BEQ 32
#define OP_BNE 33
#define OP_BLT 34
#define OP_BGE 35
#define OP_BLTU 36
#define OP_BGEU 37
#define OP_JAL 40
#define OP_JALR 41
#define OP_XCALL 62
#define A_ADD 0
#define A_SUB 1
#define A_AND 2
#define A_OR 3
#define A_XOR 4
#define A_SLL 5
#define A_SRL 6
#define A_SRA 7
#define A_SLT 8
#define A_SLTU 9
#define A_MUL 10
#define A_DIVU 12
#define A_REMU 13
#define A_DIV 14
#define A_REM 15
#define X_RA 1
#define X_SP 2
#define X_GP 3
#define X_TP 4
#define X_S0 8
#define X_A0 10
#define X_T6 31

#define CWSZ 1024
#define NIN 24
#define STRMAX 1024

/* ---- library (in StrataOS, <strata.h> declares these) ---- */
int open(const char *name, int mode);
long read(int fd, void *buf, unsigned long n);
long write(int fd, const void *buf, unsigned long n);
int close(int fd);
void _exit(int code);

/* ---- tables ---- */
struct ty ty[NTY];
int nty;
unsigned short ptrof[NTY];      /* the pointer type to each type, once made */
int npt;
int lastpn[16];                 /* the names of the parameter list read last */
int pn_set;
struct sym sy[NSY];
int nsy;
struct val vs[NVS];
struct val *vp;                 /* the top entry */
int rmask;                      /* evaluation registers in use */
long idl[10];                   /* the identifier record last looked up */
#define IDR ((struct idr *)idl)
int ereg[8] = { 5, 6, 7, 28, 29, 30, 10, 0 };   /* t0-t5, a0, zero */

/* ---- input ---- */
struct inp { long pos, end, mark; int kind, aux; };
struct inp instk[NIN];
int in_sp;
long in_pos, in_end, in_mark;
int in_kind, in_aux;
long swl[33];                   /* source window */
long sw_base;
int line;
int bol;
long src_top, xh_top, id_top, mac_top, fix_top;
int xh_hold;                    /* expansions are not freed: the scanner may be rewound */
int sf_fd, sf_eof, sf_st, sf_owed;      /* the source file, read as the scanner goes */
long sf_top, sf_pin, sf_shift;
char fnames[256];               /* file names by include depth, 32 bytes each */
char *fname;
int pp_mode;                    /* scanning the expression of #if */
char ifstk[32];
int if_sp;

/* ---- the current token ---- */
int tok;
long tk_val;
int tk_ty, tk_sym, tk_tag, tk_mac;
char tb[264];                   /* its spelling */
char strbuf[STRMAX + 8];
int str_len, str_cat, str_wide; /* str_wide: 4 bytes a character (L"...") */

/* ---- the image ---- */
long cwl[CWSZ / 8];             /* code window */
long code_org, code_pc, cw_base, lab_pc;
long dwl[32];                   /* data window */
long dw_base;
int dw_dirty;
long data_pc, res_end;
int paged, heapsz, split;
int nocode;
long fw[2];                     /* a scratch word for the arena */
long rbl[8], wbl[8];            /* byte reader and writer windows */
long rb_base, wb_pos;
long iob[130];                  /* file transfer buffer */

/* ---- the function being compiled ---- */
int fn_sym, fn_ret, fn_s0, fn_sret, fn_va;
int fn_live, fn_vla, fn_nsy0, brk_nsy, cnt_nsy;
int ce_soft, ce_fail;           /* a trial reading of an expression: an unknown name is not an error */
long fn_start, fn_pro, fn_fix0;
int fr_cur, fr_max, fr_keep, sp_bias;
long fn_rchain, brk_chain, cnt_chain, cnt_target;
int scope, loop_depth;
int cs_base, cs_top;
long cs_default;
int lb_id[32];
long lb_adr[32], lb_chain[32];
int nlabels;
int ds_class, d_name, in_params;
int ini_static, ini_dry, ini_pend, ini_comma, ini_desig;
long ini_cnt;
int id_main, id_func, id_asm, id_asm2;
long mem_off;
long ini_base;
char *out_name, *src_name;
char outbuf[40];
long lib_sym;
int lib_nsym;

/* ================= messages ================= */

int slen(char *s) { int n = 0; while (s[n]) n++; return n; }

void eputs(char *s) { write(2, s, slen(s)); }

void eputn(long n)
{
    char b[24];
    int i = 23;
    b[i] = 0;
    do { b[--i] = '0' + n % 10; n = n / 10; } while (n);
    eputs(b + i);
}

/* err(message, more): "file:line: message more", and stop */
void err(char *m, char *more)
{
    if (fname) { eputs(fname); eputs(":"); eputn(line); eputs(": "); }
    eputs(m);
    if (more) eputs(more);
    eputs("\n");
    _exit(1);
}

void errtok(char *m)
{
    if (tok == 0) err(m, "end of file");
    if (tok < 128) { tb[0] = tok; tb[1] = 0; }
    err(m, tb);
}

/* ================= the arena ================= */

long far_ld(long a) { far_read(a, fw, 8); return fw[0]; }
void far_sd(long a, long v) { fw[0] = v; far_write(a, fw, 8); }
int far_lw(long a) { far_read(a & ~7, fw, 8); return ((int *)fw)[(a >> 2) & 1]; }
void far_sw(long a, int v)
{
    far_read(a & ~7, fw, 8);
    ((int *)fw)[(a >> 2) & 1] = v;
    far_write(a & ~7, fw, 8);
}

/* a byte of the arena, through a 64-byte window */
int rb_get(long a)
{
    if ((unsigned long)(a - rb_base) >= 64) {
        rb_base = a & ~63;
        far_read(rb_base, rbl, 64);
    }
    return ((unsigned char *)rbl)[a - rb_base];
}

void wb_open(long a)
{
    wb_pos = a;
    if (a & 63) far_read(a & ~63, wbl, 64);
}

void wb_put(int c)
{
    ((char *)wbl)[wb_pos & 63] = c;
    wb_pos++;
    if ((wb_pos & 63) == 0) far_write(wb_pos - 64, wbl, 64);
}

long wb_close(void)
{
    if (wb_pos & 63) far_write(wb_pos & ~63, wbl, 64);
    rb_base = -1;
    sw_base = -1;
    return wb_pos;
}

/* ================= the image being built ================= */

void cw_flush(void)
{
    long a = A_CODE + cw_base - code_org;
    if (a + CWSZ > A_CODEEND) err("program too large", 0);
    far_write(a, cwl, CWSZ);
}

void emit(int w)
{
    if (nocode) return;
    ((int *)cwl)[(code_pc - cw_base) >> 2] = w;
    code_pc = code_pc + 4;
    if (code_pc - cw_base >= CWSZ) { cw_flush(); cw_base = cw_base + CWSZ; }
}

int code_rd(long a)
{
    if (a >= cw_base) return ((int *)cwl)[(a - cw_base) >> 2];
    return far_lw(A_CODE + a - code_org);
}

void code_wr(long a, int w)
{
    if (nocode) return;
    if (a >= cw_base) ((int *)cwl)[(a - cw_base) >> 2] = w;
    else far_sw(A_CODE + a - code_org, w);
}

/* start emitting at address a: the window that holds it, with what is there */
void cw_seek(long a)
{
    code_pc = a;
    cw_base = a & ~(CWSZ - 1);
    far_read(A_CODE + cw_base - code_org, cwl, CWSZ);
}

int enc(int op, int rd, int rs1, int imm)
{
    return op << 26 | rd << 21 | rs1 << 16 | (imm & 0xffff);
}
void e_i(int op, int rd, int rs1, int imm) { emit(enc(op, rd, rs1, imm)); }
void e_r(int fn, int rd, int rs1, int rs2) { emit(rd << 21 | rs1 << 16 | rs2 << 11 | fn); }

char *dw_seek(long a)
{
    if ((unsigned long)(a - dw_base) >= 256) {
        if (dw_dirty) far_write(A_DATA + dw_base, dwl, 256);
        dw_dirty = 0;
        dw_base = a & ~255;
        far_read(A_DATA + dw_base, dwl, 256);
    }
    return (char *)dwl + (a - dw_base);
}

void data_b(long a, int b) { *dw_seek(a) = b; dw_dirty = 1; }
int data_rb(long a) { return *(unsigned char *)dw_seek(a); }

void data_put(long a, long v, int n)
{
    while (n > 0) { data_b(a, v & 255); a++; v = v >> 8; n--; }
}

long data_alloc(int size, int align)
{
    long a = (data_pc + align - 1) & -align;
    if (a + size > 0xA000) err("data too large", 0);
    data_pc = a + size;
    return a;
}

/* a reference to be resolved when the symbol's address is known */
void fix_add(long loc, int s, int kind, long add)
{
    if (kind != FK_DATA && nocode) return;
    if (fix_top >= A_FIXEND) err("too many forward references", 0);
    ((int *)iob)[0] = loc;
    ((int *)iob)[1] = sy[s].id;
    ((int *)iob)[2] = add;
    ((int *)iob)[3] = kind;
    far_write(fix_top, iob, 16);
    fix_top = fix_top + 16;
}

/* ================= input ================= */

void in_push(long start, long end, int kind, int aux, long mark)
{
    struct inp *p;
    if (in_sp >= NIN) err("includes or macros nested too deeply", 0);
    p = &instk[in_sp++];
    p->pos = in_pos; p->end = in_end; p->kind = in_kind; p->aux = in_aux; p->mark = in_mark;
    in_pos = start; in_end = end; in_kind = kind; in_aux = aux; in_mark = mark;
}

void in_pop(void)
{
    struct inp *p = &instk[--in_sp];
    in_pos = p->pos; in_end = p->end; in_kind = p->kind; in_aux = p->aux; in_mark = p->mark;
}

int sf_q;                       /* question marks held back: a trigraph may follow */
int pop_n, pop_mac;             /* expansions ended so far, and the macro of the last */
int pp_busy;                    /* pp_expand: the macro was being expanded already */
int noexp;                      /* the next name is not a macro: it was found busy once (byte 1 before it) */
char tri_a[] = "=/'()!<>-", tri_b[] = "#\\^[]|{}~";

/* a character of the source, after trigraphs, to the window: backslash-
   newline pairs and carriage returns are removed; the newlines removed are
   put back after the line's own, so that lines keep their numbers */
void sf_char(int c)
{
    if (sf_st) {
        if (c == 13 && sf_st == 1) { sf_st = 2; return; }
        sf_st = 0;
        if (c == 10) { sf_owed++; return; }
        wb_put(92);
    }
    if (c == 13) return;
    if (c == 92) { sf_st = 1; return; }
    wb_put(c);
    if (c == 10) while (sf_owed) { wb_put(10); sf_owed--; }
}

/* more of the source file into its window: what the scanner has passed
   makes room (but not what a rewind may need: from sf_pin on) */
void src_fill(void)
{
    long keep = in_pos, d, p, n, sv[8], svp = wb_pos;
    int r, i, c;
    char *b = (char *)iob;
    for (i = 0; i < 8; i++) sv[i] = wbl[i];
    if (sf_pin >= 0 && sf_pin < keep) keep = sf_pin;
    keep = keep & ~7;
    d = keep - A_SRC;
    if (d > 0) {
        n = (sf_top - keep + 7) & ~7;
        for (p = 0; p < n; p = p + 1024) {
            r = n - p > 1024 ? 1024 : n - p;
            far_read(keep + p, iob, r);
            far_write(A_SRC + p, iob, r);
        }
        in_pos = in_pos - d;
        sf_top = sf_top - d;
        if (sf_pin >= 0) sf_pin = sf_pin - d;
        sf_shift = sf_shift + d;
    }
    if (sf_top + 2100 > A_SRCEND) err("initialiser too long", 0);
    wb_open(sf_top);
    while (wb_pos + 2100 <= A_SRCEND) {
        r = read(sf_fd, b, 1024);
        if (r <= 0) {
            sf_eof = 1;
            for (; sf_q; sf_q--) sf_char('?');
            if (sf_st) wb_put(92);
            break;
        }
        for (i = 0; i < r; i++) {
            c = b[i];
            if (c == '?') {
                if (sf_q < 2) sf_q++;
                else sf_char(c);
                continue;
            }
            if (sf_q == 2) {
                for (d = 0; tri_a[d] && tri_a[d] != c; d++) ;
                if (tri_a[d]) { c = tri_b[d]; sf_q = 0; }
            }
            for (; sf_q; sf_q--) sf_char('?');
            sf_char(c);
        }
    }
    sf_top = wb_close();
    in_end = sf_top;
    for (i = 0; i < 8; i++) wbl[i] = sv[i];
    wb_pos = svp;
}

/* the next character, or -1 at the end of the outermost file or of an
   argument being expanded; a finished expansion or include is left behind */
int nextc(void)
{
    for (;;) {
        if (in_pos < in_end) {
            if ((unsigned long)(in_pos - sw_base) >= 256) {
                sw_base = in_pos & ~7;
                far_read(sw_base, swl, 256);
            }
            return ((unsigned char *)swl)[in_pos++ - sw_base];
        }
        if (in_kind == 3) return -1;
        if (in_sp == 0) {
            if (sf_eof) return -1;
            src_fill();
            continue;
        }
        if (in_kind == 2) {
            if (in_aux) {           /* the macro may be expanded again */
                far_read(in_aux, fw, 8);
                ((char *)fw)[1] = 0;
                far_write(in_aux, fw, 8);
            }
            pop_n++;
            pop_mac = in_aux;
            if (!xh_hold) xh_top = in_mark;
        } else {
            src_top = in_mark;
            line = in_aux;
            fname = fname - 32;
            bol = 1;
        }
        in_pop();
    }
}

void unget(int c) { if (c >= 0) in_pos--; }

/* ================= identifiers ================= */

/* the record of the name s of n characters (made if new); IDR holds a copy */
int intern(char *s, int n)
{
    int h = 5381, i, a, hd;
    for (i = 0; i < n; i++) h = h * 33 + s[i];
    h = h & 511;
    a = far_lw(A_IDH + 4 * h);
    hd = a;
    while (a) {
        far_read(a, idl, 80);
        if (IDR->len == n) {
            for (i = 0; i < n && IDR->name[i] == s[i]; i++) ;
            if (i == n) return a;
        }
        a = IDR->next;
    }
    idl[0] = 0; idl[1] = 0;
    IDR->next = hd;
    IDR->len = n;
    for (i = 0; i < n; i++) IDR->name[i] = s[i];
    IDR->name[n] = 0;
    a = id_top;
    i = (16 + n + 8) & ~7;
    if (a + i > A_IDEND) err("too many identifiers", 0);
    id_top = a + i;
    far_write(a, idl, i);
    far_sw(A_IDH + 4 * h, a);
    return a;
}

/* change what an identifier names: field 0 the symbol, 1 the tag */
void id_set(int id, int field, int v)
{
    far_read(id + 8, fw, 8);
    ((unsigned short *)fw)[field] = v;
    far_write(id + 8, fw, 8);
}

int id_sym(int id) { far_read(id + 8, fw, 8); return ((unsigned short *)fw)[0]; }
int id_tag(int id) { far_read(id + 8, fw, 8); return ((unsigned short *)fw)[1]; }

char *id_name(int id) { far_read(id, idl, 80); return IDR->name; }

int streq(char *a, char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}

/* ================= files and the library ================= */

/* read a file into the arena at dst; -> its size, or -1 if it cannot be
   opened. Zero bytes follow it. With trunc, what does not fit is left out. */
long m_load(char *name, long dst, long max, int trunc)
{
    int fd = open(name, 0), n = 0, r, k;
    long p = dst;
    char *b = (char *)iob;
    if (fd < 0) return -1;
    for (;;) {
        r = read(fd, b + n, 1024 - n);
        if (r <= 0) break;
        n = n + r;
        k = n & ~7;
        if (!k) continue;
        if (p - dst + k > max - 16) {
            if (trunc) { n = 0; break; }
            err("source too large", 0);
        }
        far_write(p, iob, k);
        p = p + k;
        n = n - k;
        iob[0] = iob[k >> 3];
    }
    for (k = 0; k < 16; k++) b[n + k] = 0;
    far_write(p, iob, 16);
    close(fd);
    sw_base = -1;
    rb_base = -1;
    return p + n - dst;
}

/* remove every backslash-newline (and carriage return) from a text in the
   arena; the newlines removed are put back after the line's own */
long splice(long start, long size)
{
    long p = start, e = start + size;
    int c, owed = 0;
    wb_open(start);
    while (p < e) {
        c = rb_get(p++);
        if (c == 13) continue;
        if (c == 92) {
            if (rb_get(p) == 13 && rb_get(p + 1) == 10) p++;
            if (rb_get(p) == 10) { p++; owed++; continue; }
        }
        wb_put(c);
        if (c == 10) while (owed) { wb_put(10); owed--; }
    }
    return wb_close() - start;
}

long lib_sz, lib_len, lib_base;
/* a member of cc.lib: -> its arena offset (0: none), lib_sz = its size */
long lib_find(char *name)
{
    long d = lib_base + 8;
    for (;;) {
        far_read(d, iob, 32);
        if (!*(char *)iob) return 0;
        if (streq((char *)iob, name)) {
            lib_sz = ((int *)iob)[7];
            if (((int *)iob)[6] + lib_sz > lib_len) err("/bin/cc.lib is too large", 0);
            return lib_base + ((int *)iob)[6];
        }
        d = d + 32;
    }
}

/* the library's address for an identifier, or -1 */
long lib_lookup(int id)
{
    char *n = id_name(id);
    long p = lib_sym;
    int i;
    for (i = 0; i < lib_nsym; i++) {
        far_read(p, iob, 24);
        if (streq((char *)iob, n)) return ((int *)iob)[5];
        p = p + 24;
    }
    return -1;
}

/* ================= the preprocessor ================= */

void next(void);
long const_expr(void);

int isdig(int c) { return c >= '0' && c <= '9'; }
int isid1(int c) { return ((c | 32) >= 'a' && (c | 32) <= 'z') || c == '_'; }
int isid(int c) { return isid1(c) || isdig(c); }
int issp(int c) { return c == ' ' || c == 9 || c == 11 || c == 12 || c == 13; }

/* the next character of a directive line: a comment is a space, the newline
   that ends the line is returned and not consumed */
int pp_c(void)
{
    int c = nextc(), d, p;
    if (c == 10) { in_pos--; return c; }
    if (c != '/') return c;
    d = nextc();
    if (d == '/') {
        do c = nextc(); while (c >= 0 && c != 10);
        if (c == 10) in_pos--;
        return c;
    }
    if (d == '*') {
        p = 0;
        for (;;) {
            c = nextc();
            if (c < 0) return c;
            if (c == 10) line++;
            if (c == '/' && p == '*') return ' ';
            p = c;
        }
    }
    unget(d);
    return '/';
}

int pp_blank(void)
{
    int c;
    do c = pp_c(); while (c >= 0 && issp(c));
    return c;
}

void pp_unget(int c) { if (c >= 0 && c != 10) in_pos--; }

/* the identifier that comes next (after blanks) -> tb; its length, 0 if none */
int pp_word(void)
{
    int c = pp_blank(), n = 0;
    if (c < 0 || !isid1(c)) { pp_unget(c); tb[0] = 0; return 0; }
    while (c >= 0 && isid(c)) { if (n < 63) tb[n++] = c; c = nextc(); }
    unget(c);
    tb[n] = 0;
    return n;
}

void pp_eol(void)
{
    int c;
    do c = pp_c(); while (c >= 0 && c != 10);
}

char *pd_names[] = { "define", "undef", "include", "ifdef", "ifndef", "if", "elif",
                     "else", "endif", "error", "line", "pragma", 0 };

int pp_which(void)
{
    int i;
    for (i = 0; pd_names[i]; i++) if (streq(tb, pd_names[i])) return i + 1;
    return 0;
}

int pp_eval(void)
{
    int t = tok;
    long v;
    pp_mode = 1;
    next();
    v = const_expr();
    pp_mode = 0;
    if (tok) errtok("syntax error near ");
    tok = t;
    return v != 0;
}

/* in #if: the identifier in tb is 0, or `defined NAME` */
int pp_defined(void)
{
    int c, par, v;
    if (!streq(tb, "defined")) return 0;
    c = pp_blank();
    par = c == '(';
    if (!par) pp_unget(c);
    pp_word();
    intern(tb, slen(tb));
    v = IDR->mac != 0;
    if (par) pp_blank();
    return v;
}

/* skip lines to the group of the innermost conditional that is to be read,
   or past its #endif */
void pp_skip(void)
{
    int depth = 0, c, w;
    for (;;) {
        pp_eol();
        c = nextc();
        if (c < 0) err("#if without #endif", 0);
        line++;
        c = pp_blank();
        if (c != '#') { pp_unget(c); continue; }
        if (!pp_word()) continue;
        w = pp_which();
        if (w >= 4 && w <= 6) { depth++; continue; }
        if (w == 9) {
            if (depth) { depth--; continue; }
            if_sp--;
            break;
        }
        if (depth || (w != 7 && w != 8)) continue;
        if (ifstk[if_sp - 1]) continue;
        if (w == 8 || pp_eval()) { ifstk[if_sp - 1] = 1; break; }
    }
    pp_eol();
}


/* macro record: byte 0 kind (0 object-like, 1 function-like, 2 __LINE__,
   3 __FILE__), 1 busy, 2 parameters, 3 variadic, int 1 body length; the body
   follows at 16: text, with 0x80+n for parameter n, 0xC0+n for #n, 0xFF for ## */
long mh[2];
#define MH ((unsigned char *)mh)
int parm[32];
int pd_st;                      /* 1 blanks skipped, 2 no space next, 4 # waits, 8 something written */
long args[160];                 /* per argument: raw start, raw end, expanded start, expanded end */
int args_top;
char xbuf[1536];
int xb_top;

void xh_room(long e)
{
    xh_top = (e + 7) & ~7;
    if (xh_top > A_XHEND - 2048) err("macro expansion too long", 0);
}

void pd_sp(void)
{
    if ((pd_st & 11) == 9) wb_put(' ');
    pd_st = (pd_st | 8) & 12;
}

void pp_define(void)
{
    int id, np = 0, var = 0, kind = 0, c, i, q, h;
    long end;
    if (!pp_word()) err("bad macro definition", 0);
    id = intern(tb, slen(tb));
    c = nextc();
    if (c == '(') {
        kind = 1;
        for (;;) {
            if (np >= 31) err("bad macro definition", 0);
            if (pp_word()) parm[np++] = intern(tb, slen(tb));
            else {
                c = pp_blank();
                if (c == ')') break;
                if (c != '.') err("bad macro definition", 0);
                nextc(); nextc();
                var = 1;
                parm[np++] = intern("__VA_ARGS__", 11);
            }
            c = pp_blank();
            if (c == ')') break;
            if (c != ',') err("bad macro definition", 0);
        }
    } else unget(c);
    wb_open(mac_top + 16);
    pd_st = 0;
    for (;;) {
        c = pp_c();
        if (c < 0 || c == 10) break;
        if (issp(c)) { pd_st = pd_st | 1; continue; }
        if (isid1(c)) {
            in_pos--;
            pp_word();
            h = intern(tb, slen(tb));
            for (i = 0; i < np && parm[i] != h; i++) ;
            if (i < np) {
                if (pd_st & 4) { pd_st = pd_st & 8; wb_put(0xC0 + i); }
                else { pd_sp(); wb_put(0x80 + i); }
                pd_st = pd_st | 8;
                continue;
            }
            if (pd_st & 4) { pd_st = pd_st & 8; wb_put('#'); }
            else pd_sp();
            for (i = 0; tb[i]; i++) wb_put(tb[i]);
            continue;
        }
        if (isdig(c)) {
            pd_sp();
            do { wb_put(c); c = nextc(); } while (c >= 0 && (c == '.' || isid(c)));
            unget(c);
            continue;
        }
        if (c == '#') {
            c = nextc();
            if (c == '#') { wb_put(0xFF); pd_st = (pd_st & 8) | 2; continue; }
            unget(c);
            if (kind) { pd_sp(); pd_st = pd_st | 6; continue; }
            c = '#';
        }
        if (c == '"' || c == 39) {
            pd_sp();
            q = c;
            for (;;) {
                wb_put(c);
                c = nextc();
                if (c < 0) break;
                if (c == 10) { in_pos--; break; }
                if (c == 92) { wb_put(c); c = nextc(); continue; }
                if (c == q) { wb_put(c); break; }
            }
            continue;
        }
        pd_sp();
        wb_put(c);
    }
    end = wb_close();
    far_sd(mac_top, kind | np << 16 | var << 24 | (end - mac_top - 16) << 32);
    far_sw(id + 4, mac_top);
    mac_top = (end + 7) & ~7;
    if (mac_top > A_MACEND - 2048) err("too many macros", 0);
}

int pp_expand(void);

/* the ( of a macro call was read: copy its arguments as written to the
   expansion heap; -> how many */
int pp_collect(int base)
{
    int n = 0, depth = 0, c, q, i;
    long *a;
    args[base * 4] = xh_top;
    wb_open(xh_top);
    for (;;) {
        c = nextc();
        if (c < 0) err("unexpected end of file", 0);
        if (c == '/') {                 /* a comment is a blank */
            q = nextc();
            if (q == '/') {
                do c = nextc(); while (c >= 0 && c != 10);
            } else if (q == '*') {
                for (i = 0;; i = c) {
                    c = nextc();
                    if (c < 0) err("unexpected end of file", 0);
                    if (c == 10 && in_kind == 1) line++;
                    if (c == '/' && i == '*') break;
                }
                c = ' ';
            } else unget(q);
        }
        if (c == 10) { if (in_kind == 1) line++; c = ' '; }
        else if (c == '(') depth++;
        else if (c == ')') { if (depth == 0) break; depth--; }
        else if (c == ',' && depth == 0 && !(MH[3] && n >= MH[2] - 1)) {
            args[(base + n) * 4 + 1] = wb_pos;
            n++;
            if (base + n >= 39) err("macro expansion too long", 0);
            args[(base + n) * 4] = wb_pos;
            continue;
        } else if (c == '"' || c == 39) {
            q = c;
            for (;;) {
                wb_put(c);
                c = nextc();
                if (c < 0) break;
                if (c == 92) { wb_put(c); c = nextc(); continue; }
                if (c == q) break;
            }
            if (c < 0) continue;
        }
        wb_put(c);
    }
    args[(base + n) * 4 + 1] = wb_pos;
    n++;
    xh_room(wb_close());
    for (i = 0; i < n; i++) {
        a = &args[(base + i) * 4];
        while (a[0] < a[1] && issp(rb_get(a[0]))) a[0]++;
        while (a[1] > a[0] && issp(rb_get(a[1] - 1))) a[1]--;
    }
    if (n == 1 && MH[2] == 0 && args[base * 4] == args[base * 4 + 1]) n = 0;
    return n;
}

void xput(int c)
{
    if (xb_top >= 1536) err("macro expansion too long", 0);
    xbuf[xb_top++] = c;
}

/* expand an argument's text; the result goes to the expansion heap */
void pp_arg(int k)
{
    long *a = &args[k * 4];
    int xb0 = xb_top, c, q, n, i, r;
    char sv[72];
    in_push(a[0], a[1], 3, 0, 0);
    for (;;) {
        c = nextc();
        if (c < 0) break;
        if (c == 1) { noexp = 1; continue; }
        if (isid1(c)) {
            n = 0;
            r = pop_n;
            while (c >= 0 && isid(c)) { if (n < 63) tb[n++] = c; c = nextc(); }
            tb[n] = 0;
            unget(c);
            intern(tb, n);
            pp_busy = noexp;
            if (IDR->mac && !noexp && !(pop_n != r && pop_mac == IDR->mac)) {
                tk_mac = IDR->mac;
                for (i = 0; i <= n; i++) sv[i] = tb[i];
                r = pp_expand();
                for (i = 0; i <= n; i++) tb[i] = sv[i];
                if (r) continue;
            }
            noexp = 0;
            if (pp_busy) xput(1);
            for (i = 0; i < n; i++) xput(tb[i]);
            continue;
        }
        if (isdig(c)) {
            do { xput(c); c = nextc(); } while (c >= 0 && (c == '.' || isid(c)));
            unget(c);
            continue;
        }
        if (c == '"' || c == 39) {
            q = c;
            for (;;) {
                xput(c);
                c = nextc();
                if (c < 0) break;
                if (c == 92) { xput(c); c = nextc(); continue; }
                if (c == q) break;
            }
            if (c < 0) continue;
        }
        xput(c);
    }
    in_pop();
    a = &args[k * 4];
    a[2] = xh_top;
    wb_open(xh_top);
    for (i = xb0; i < xb_top; i++) wb_put(xbuf[i]);
    a[3] = wb_close();
    xh_room(a[3]);
    xb_top = xb0;
}

/* the body of macro m with its arguments (from args[base]) in place -> the
   expansion heap; -> the end of the text */
long pp_subst(int m, int base)
{
    long p = m + 16, pe, s, e;
    int c, q = 0, i, lit;
    pe = p + ((int *)mh)[1];
    wb_open(xh_top);
    while (p < pe) {
        c = rb_get(p++);
        if (q) {
            if (c == 92) { wb_put(c); c = rb_get(p++); }
            else if (c == q) q = 0;
            wb_put(c);
            continue;
        }
        if (c == '"' || c == 39) { q = c; wb_put(c); continue; }
        if (c < 0x80) { wb_put(c); continue; }
        if (c == 0xFF) continue;
        if (c < 0xC0) {
            i = (base + c - 0x80) * 4;
            if ((p - 2 >= m + 16 && rb_get(p - 2) == 0xFF) || (p < pe && rb_get(p) == 0xFF)) {
                for (s = args[i]; s < args[i + 1]; s++) {       /* pasted: as written */
                    c = rb_get(s);
                    if (c != 1) wb_put(c);
                }
                continue;
            }
            s = args[i + 2]; e = args[i + 3];
            while (s < e) wb_put(rb_get(s++));
            continue;
        }
        i = (base + c - 0xC0) * 4;
        wb_put('"');
        lit = 0;
        for (s = args[i]; s < args[i + 1]; s++) {
            c = rb_get(s);
            if (c == 1) continue;
            if (!lit && issp(c)) {      /* blanks: one space */
                while (s + 1 < args[i + 1] && issp(rb_get(s + 1))) s++;
                wb_put(' ');
                continue;
            }
            if (c == 92 && lit) {       /* an escape in a literal: both characters, escaped */
                wb_put(92);
                wb_put(92);
                s++;
                c = rb_get(s);
                if (c == '"' || c == 92) wb_put(92);
            } else if (c == '"') {
                wb_put(92);
                if (!lit) lit = c; else if (lit == c) lit = 0;
            } else if (c == 39) {
                if (!lit) lit = c; else if (lit == c) lit = 0;
            }
            wb_put(c);
        }
        wb_put('"');
    }
    e = wb_close();
    xh_room(e);
    return e;
}

/* -> 1 if the macro tk_mac (whose name was just scanned) is being read now,
   0 if the name stays an identifier */
int pp_expand(void)
{
    int m = tk_mac, kind, n, base, i, c;
    long mark = xh_top, s, e, v;
    far_read(m, mh, 16);
    pp_busy = MH[1];
    if (MH[1]) return 0;
    kind = MH[0];
    if (kind >= 2) {
        wb_open(mark);
        if (kind == 2) {
            v = 1;
            while (v * 10 <= line) v = v * 10;
            for (i = line; v; v = v / 10) { wb_put('0' + i / v); i = i % v; }
        } else {
            wb_put('"');
            for (i = 0; fname[i]; i++) wb_put(fname[i]);
            wb_put('"');
        }
        e = wb_close();
        xh_room(e);
        in_push(mark, e, 2, 0, mark);
        return 1;
    }
    if (kind == 1) {
        for (;;) {
            c = nextc();
            if (c < 0) return 0;
            if (c == '(') break;
            if (c == 10) { if (in_kind == 1) line++; continue; }
            if (issp(c)) continue;
            in_pos--;
            return 0;
        }
        base = args_top;
        n = pp_collect(base);
        far_read(m, mh, 16);
        if (n != MH[2]) {
            if (MH[3] && n + 1 == MH[2]) {
                args[(base + n) * 4] = xh_top;
                args[(base + n) * 4 + 1] = xh_top;
                n++;
            } else err("wrong number of macro arguments", 0);
        }
        args_top = base + n;
        for (i = 0; i < n; i++) pp_arg(base + i);
        far_read(m, mh, 16);
        s = xh_top;
        e = pp_subst(m, base);
        args_top = base;
    } else {
        s = m + 16;
        e = s + ((int *)mh)[1];
    }
    far_read(m, fw, 8);
    ((char *)fw)[1] = 1;
    far_write(m, fw, 8);
    in_push(s, e, 2, m, mark);
    return 1;
}

/* #include "FILE", <FILE>, or macros that expand to one of them */
void pp_include(void)
{
    int c = pp_blank(), q = 0, n = 0, k = args_top;
    long s, e, mark = src_top, xm = xh_top, p = 0;
    char *f;
    if (c != '"' && c != '<') {         /* not a name: the line's macros are expanded first */
        pp_unget(c);
        if (k >= 39) err("macro expansion too long", 0);
        args[k * 4] = xh_top;
        wb_open(xh_top);
        for (;;) {
            c = pp_c();
            if (c < 0 || c == 10) break;
            wb_put(c);
        }
        args[k * 4 + 1] = wb_close();
        xh_room(args[k * 4 + 1]);
        args_top = k + 1;
        pp_arg(k);
        args_top = k;
        for (p = args[k * 4 + 2]; p < args[k * 4 + 3]; p++) {
            c = rb_get(p);
            if (c != ' ' && c != 1) break;
        }
        p++;
    }
    if (c == '"') q = c;
    else if (c == '<') q = '>';
    else err("cannot include ", tb);
    for (;;) {
        c = !p ? nextc() : p < args[k * 4 + 3] ? rb_get(p++) : -1;
        if (c == q) break;
        if (c < 32 || n > 29) err("cannot include ", tb);
        tb[n++] = c;
    }
    tb[n] = 0;
    xh_top = xm;
    pp_eol();
    s = 0;
    if (q == '"') {
        e = m_load(tb, src_top, A_INCEND - src_top, 0);
        if (e >= 0) {
            s = src_top;
            e = s + splice(s, e);
            src_top = (e + 8) & ~7;
        }
    }
    if (!s) {
        s = lib_find(tb);
        if (!s) err("cannot include ", tb);
        e = s + lib_sz;
    }
    in_push(s, e, 1, line, mark);
    if (fname + 32 >= fnames + 256) err("includes or macros nested too deeply", 0);
    fname = fname + 32;
    f = fname;
    for (n = 0; tb[n]; n++) f[n] = tb[n];
    f[n] = 0;
    line = 1;
    bol = 1;
}

/* #line N "FILE", or # N "FILE": the operands are macro-expanded */
void pp_line(void)
{
    int t = tok, sc = str_cat, i, n;
    str_cat = 0;
    pp_mode = 1;
    next();
    if (tok != T_NUM) err("bad #line", 0);
    n = tk_val;
    next();
    if (tok == T_STR && !sc) {
        for (i = 0; strbuf[i] && i < 31; i++) fname[i] = strbuf[i];
        fname[i] = 0;
    }
    line = n - 1;
    pp_mode = 0;
    tok = t;
    str_cat = sc;
}

/* a directive: the # has been read */
void pp_direct(void)
{
    int w, v, n;
    if (!pp_word()) {
        v = pp_blank();
        pp_unget(v);
        if (v >= 0 && isdig(v)) { pp_line(); pp_eol(); }
        return;
    }
    w = pp_which();
    if (!w) err("unknown directive: ", tb);
    if (w == 1) { pp_define(); return; }
    if (w == 3) { pp_include(); return; }
    if (w == 2) {
        if (pp_word()) far_sw(intern(tb, slen(tb)) + 4, 0);
    } else if (w >= 4 && w <= 6) {
        if (w == 6) v = pp_eval();
        else {
            pp_word();
            intern(tb, slen(tb));
            v = (IDR->mac != 0) ^ (w == 5);
        }
        ifstk[if_sp] = v;
        if_sp = (if_sp + 1) & 31;
        if (!v) { pp_skip(); return; }
    } else if (w == 7 || w == 8) {
        if (!if_sp) err("#else without #if", 0);
        ifstk[if_sp - 1] = 1;
        pp_skip();
        return;
    } else if (w == 9) {
        if (!if_sp) err("#endif without #if", 0);
        if_sp--;
    } else if (w == 10) {
        n = 0;
        for (;;) {
            v = pp_c();
            if (v < 0 || v == 10 || n > 200) break;
            tb[n++] = v;
        }
        tb[n] = 0;
        err("#error", tb);
    } else if (w == 11) pp_line();
    pp_eol();
}

/* a built-in macro: __LINE__ (2) or __FILE__ (3) */
void pp_builtin(char *name, int kind)
{
    far_sw(intern(name, slen(name)) + 4, mac_top);
    far_sd(mac_top, kind);
    mac_top = mac_top + 16;
}

/* ================= the scanner ================= */

char op2[] = "++--->&&||==!=<=>=<<>>+=-=*=/=%=&=|=^=";
int op2t[] = { T_INC, T_DEC, T_ARROW, T_LAND, T_LOR, T_EQ, T_NE, T_LE, T_GE, T_SHL, T_SHR,
               T_ASG, T_ASG + 1, T_ASG + 2, T_ASG + 3, T_ASG + 4, T_ASG + 5, T_ASG + 6, T_ASG + 7 };
char *kw_names[] = { "auto", "break", "case", "char", "const", "continue", "default", "do",
    "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long",
    "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct", "switch",
    "typedef", "union", "unsigned", "void", "volatile", "while", "_Bool", 0 };

void lex_init(void)
{
    int i, a;
    for (i = 0; kw_names[i]; i++) {
        a = intern(kw_names[i], slen(kw_names[i]));
        far_read(a + 8, fw, 8);
        ((char *)fw)[4] = K_FIRST + i;
        far_write(a + 8, fw, 8);
    }
    pp_builtin("__LINE__", 2);
    pp_builtin("__FILE__", 3);
}

/* the character an escape sequence stands for (after the backslash) */
int lex_esc(void)
{
    int c = nextc(), v, n;
    if (c == 'n') return 10;
    if (c == 't') return 9;
    if (c == 'r') return 13;
    if (c == 'a') return 7;
    if (c == 'b') return 8;
    if (c == 'f') return 12;
    if (c == 'v') return 11;
    if (c == 'e') return 27;
    if (c == 'u' || c == 'U') {
        v = 0;
        for (n = c == 'u' ? 4 : 8; n; n--) {
            c = nextc() | 32;
            v = v * 16 + (isdig(c) ? c - '0' : c - 'a' + 10);
        }
        return v;
    }
    if (c == 'x') {
        v = 0;
        for (;;) {
            c = nextc();
            if (isdig(c)) n = c - '0';
            else if ((c | 32) >= 'a' && (c | 32) <= 'f') n = (c | 32) - 'a' + 10;
            else break;
            v = v * 16 + n;
        }
        unget(c);
        return v;
    }
    if (c >= '0' && c <= '7') {
        v = c - '0';
        for (n = 0; n < 2; n++) {
            c = nextc();
            if (c < '0' || c > '7') { unget(c); break; }
            v = v * 8 + c - '0';
        }
        return v;
    }
    return c;
}

long __fadd(long a, long b);
long __fsub(long a, long b);
long __fmul(long a, long b);
long __fdiv(long a, long b);
long __fcmp(long a, long b);
long __itof(long a);
long __utof(long a);
long __ftoi(long a);
long __ftou(long a);
long __f2d(long a);
long __d2f(long a);

/* the floating constant spelled in tb: a double as its 64-bit pattern (a
   float, with the suffix f, as its 32-bit pattern) */
void lex_float(void)
{
    char *s = tb;
    long m = 0, d, p;
    int e = 0, nd = 0, neg, x, k, hex = tb[0] == '0' && (tb[1] | 32) == 'x';
    if (hex) {                          /* 0x H.H p N: the digits, times a power of two */
        for (s = s + 2; *s && (*s | 32) != 'p'; s++) {
            if (*s == '.') { nd = 1; continue; }
            x = isdig(*s) ? *s - '0' : (*s | 32) - 'a' + 10;
            if (m >> 56) { if (!nd) e = e + 4; continue; }
            m = m << 4 | x;
            if (nd) e = e - 4;
        }
        nd = 18;
    }
    for (; isdig(*s); s++) {
        if (nd < 18) { m = m * 10 + *s - '0'; if (m) nd++; }
        else e++;
    }
    if (*s == '.')
        for (s++; isdig(*s); s++)
            if (nd < 18) { m = m * 10 + *s - '0'; if (m) nd++; e--; }
    if ((*s | 32) == (hex ? 'p' : 'e')) {
        s++;
        neg = 0;
        if (*s == '-') { neg = 1; s++; }
        else if (*s == '+') s++;
        x = 0;
        for (; isdig(*s); s++) if (x < 1000) x = x * 10 + *s - '0';
        e = e + (neg ? -x : x);
    }
    d = __itof(m);
    while (hex && e) {
        k = e < -1000 ? -1000 : e > 1000 ? 1000 : e;
        d = __fmul(d, (long)(k + 1023) << 52);
        e = e - k;
    }
    while (e) {
        k = e < 0 ? -e : e;
        if (k > 18) k = 18;
        for (p = 1, x = 0; x < k; x++) p = p * 10;
        if (e < 0) { d = __fdiv(d, __itof(p)); e = e + k; }
        else { d = __fmul(d, __itof(p)); e = e - k; }
        if (!(d << 1)) break;
    }
    tk_ty = Y_DOUBLE;
    if ((*s | 32) == 'f') { d = __d2f(d); tk_ty = Y_FLOAT; }
    tk_val = d;
    tok = T_NUM;
}

/* a number whose first character is c: sets tok, tk_val, tk_ty */
void lex_num(int c)
{
    int n = 0, base = 10, p, d, fl = 0, u = 0, l = 0;
    unsigned long v = 0;
    char *s = tb;
    for (;;) {
        tb[n++] = c;
        p = c;
        c = nextc();
        if (c == '.') { fl = 1; continue; }
        if (c >= 0 && isid(c)) continue;
        if ((c == '+' || c == '-') && ((p | 32) == 'p' || ((p | 32) == 'e' && (tb[1] | 32) != 'x'))) { fl = 1; continue; }
        break;
    }
    tb[n] = 0;
    unget(c);
    if (s[0] == '0') {
        if ((s[1] | 32) == 'x') { base = 16; s = s + 2; }
        else base = 8;
    }
    if (base != 16) for (n = 0; s[n]; n++) if ((s[n] | 32) == 'e') fl = 1;
    if (base == 16) for (n = 0; s[n]; n++) if ((s[n] | 32) == 'p') fl = 1;
    if (fl) {
        lex_float();
        return;
    }
    for (;; s++) {
        c = *s;
        if (isdig(c)) d = c - '0';
        else if ((c | 32) >= 'a' && (c | 32) <= 'f') d = (c | 32) - 'a' + 10;
        else break;
        if (d >= base) break;
        v = v * base + d;
    }
    for (; *s; s++) {
        if ((*s | 32) == 'u') u = 1;
        else if ((*s | 32) == 'l') l = 1;
        else err("syntax error near ", tb);
    }
    tk_val = v;
    if ((long)v < 0) tk_ty = Y_ULONG;
    else if (l) tk_ty = u ? Y_ULONG : Y_LONG;
    else if (u) tk_ty = v >> 32 ? Y_ULONG : Y_UINT;
    else if (!(v >> 31)) tk_ty = Y_INT;
    else if (base == 10 || v >> 32) tk_ty = Y_LONG;
    else tk_ty = Y_UINT;
    tok = T_NUM;
}

/* one token, unless a macro was expanded (-> 0: scan again) */
int next1(void)
{
    int c, d, i, n, wide = 0;
    for (;;) {
        c = nextc();
        if (c < 0) { tok = 0; return 1; }
        if (issp(c)) continue;
        if (c == 1) { noexp = 1; continue; }
        if (c == 10) {
            if (pp_mode) { in_pos--; tok = 0; return 1; }
            bol = 1;
            if (in_kind == 1) line++;
            continue;
        }
        if (c == '/') {
            d = nextc();
            if (d == '/') {
                do d = nextc(); while (d >= 0 && d != 10);
                unget(d);
                continue;
            }
            if (d == '*') {
                n = 0;
                for (;;) {
                    d = nextc();
                    if (d < 0) err("unexpected end of file", 0);
                    if (d == 10) line++;
                    if (d == '/' && n == '*') break;
                    n = d;
                }
                continue;
            }
            unget(d);
            break;
        }
        if (c == '#' && bol && in_kind == 1) { pp_direct(); continue; }
        break;
    }
    bol = 0;
    if (isid1(c)) {
        n = 0;
        i = pop_n;                      /* (a name its own expansion ends with is not expanded again) */
        while (c >= 0 && isid(c)) { if (n < 63) tb[n++] = c; c = nextc(); }
        tb[n] = 0;
        wide = n == 1 && tb[0] == 'L' && (c == 39 || c == '"');
        if (!wide) {
            unget(c);
            tk_val = intern(tb, n);
            d = noexp;
            noexp = 0;
            if (IDR->mac && !d && !(pop_n != i && pop_mac == IDR->mac)) {
                tk_mac = IDR->mac;
                if (pp_expand()) return 0;
            }
            if (pp_mode) { tk_val = pp_defined(); tk_ty = Y_INT; tok = T_NUM; return 1; }
            if (tb[1] == 'P' && streq(tb, "_Pragma")) {         /* _Pragma("..."): nothing */
                next();
                if (tok == '(') { next(); next(); }
                return 0;
            }
            if (IDR->kw) { tok = IDR->kw; return 1; }
            tk_sym = IDR->sym;
            tk_tag = IDR->tag;
            tok = T_ID;
            return 1;
        }
    }
    if (isdig(c)) { lex_num(c); return 1; }
    if (c == 39) {
        tk_val = 0;
        for (;;) {
            c = nextc();
            if (c < 0) err("unexpected end of file", 0);
            if (c == 39) break;
            if (c == 92) c = lex_esc();
            tk_val = wide ? c : tk_val << 8 | (char)c;
        }
        tk_ty = Y_INT;
        tok = T_NUM;
        return 1;
    }
    if (c == '"') {
        n = str_cat ? str_len : 0;
        for (;;) {
            c = nextc();
            if (c < 0 || c == 10) err("unexpected end of file", 0);
            if (c == '"') break;
            if (c == 92) c = lex_esc();
            if (n >= STRMAX - 4) err("string too long", 0);
            strbuf[n++] = c;
            if (wide) for (i = 8; i < 32; i = i + 8) strbuf[n++] = c >> i;
        }
        strbuf[n] = 0;
        str_len = n;
        str_wide = wide;
        tok = T_STR;
        return 1;
    }
    d = nextc();
    if (c == '.') {
        if (d >= 0 && isdig(d)) { unget(d); lex_num('.'); return 1; }
        if (d == '.') {
            if (nextc() != '.') err("bad character", 0);
            tok = T_ELL;
            return 1;
        }
    }
    for (i = 0; op2[i]; i = i + 2)
        if (op2[i] == c && op2[i + 1] == d) {
            tok = op2t[i >> 1];
            if (tok == T_SHL || tok == T_SHR) {
                d = nextc();
                if (d == '=') tok = tok + T_ASG + 8 - T_SHL;
                else unget(d);
            }
            return 1;
        }
    unget(d);
    tok = c;
    return 1;
}

void next(void) { while (!next1()) ; }

void skip(int t)
{
    if (tok != t) errtok("syntax error near ");
    next();
}

/* ================= rewinding the scanner ================= */

/* An array whose length its initialiser gives is read twice: once to count,
   once for real. scan_mark notes where the scanner is (tok is the token
   before the initialiser), scan_rewind takes it back there. */
int sv_sp, sv_line, sv_bol, sv_kind, sv_aux, sv_tok, sv_if;
long sv_pos, sv_end, sv_mark, sv_shift, sv_xh;
char *sv_fname;

void scan_mark(void)
{
    int i;
    far_write(A_SV, instk, NIN * 32);
    sv_sp = in_sp; sv_line = line; sv_bol = bol; sv_kind = in_kind; sv_aux = in_aux;
    sv_pos = in_pos; sv_end = in_end; sv_mark = in_mark; sv_shift = sf_shift;
    sv_xh = xh_top; sv_fname = fname; sv_tok = tok; sv_if = if_sp;
    sf_pin = in_sp ? instk[0].pos : in_pos;
    xh_hold = 1;
}

/* a macro whose expansion is being read again is busy again */
void mac_busy(int m)
{
    if (!m) return;
    far_read(m, fw, 8);
    ((char *)fw)[1] = 1;
    far_write(m, fw, 8);
}

void scan_rewind(void)
{
    int i;
    long d = sf_shift - sv_shift;
    far_read(A_SV, instk, NIN * 32);
    for (i = 0; i < sv_sp; i++) if (instk[i].kind == 2) mac_busy(instk[i].aux);
    in_sp = sv_sp; line = sv_line; bol = sv_bol; in_kind = sv_kind; in_aux = sv_aux;
    in_pos = sv_pos; in_end = sv_end; in_mark = sv_mark;
    xh_top = sv_xh; fname = sv_fname; tok = sv_tok; if_sp = sv_if;
    if (in_kind == 2) mac_busy(in_aux);
    if (in_sp) { instk[0].pos = instk[0].pos - d; instk[0].end = sf_top; }
    else { in_pos = in_pos - d; in_end = sf_top; }
    sf_pin = -1;
    xh_hold = 0;
    sw_base = -1;
}

/* ================= types ================= */

int ty_new(int kind, int size, int align, int base)
{
    struct ty *t;
    if (nty >= NTY) err("too many types", 0);
    t = &ty[nty];
    t->kind = kind; t->flags = 0; t->align = align; t->x = 0;
    t->size = size; t->base = base; t->aux = 0;
    ptrof[nty] = 0;
    return nty++;
}

int ty_ptr(int b)
{
    int t;
    if (!ptrof[b]) { t = ty_new(TK_PTR, 8, 8, b); ptrof[b] = t; }
    return ptrof[b];
}

/* an array of n elements; while the element type is not known yet (a
   declarator in parentheses), size holds n and x is 2 */
int ty_arr(int b, long n)
{
    int t = ty_new(TK_ARRAY, n * ty[b].size, ty[b].align, b);
    if (!ty[b].size && ty[b].kind == TK_VOID) { ty[t].size = n; ty[t].x = 2; }
    return t;
}

int pt_get(int i) { return far_lw(A_PT + 4 * i); }

char ty_kinds[] = { TK_VOID, TK_BOOL, TK_CHAR, TK_CHAR, TK_SHORT, TK_SHORT, TK_INT, TK_INT,
                    TK_LONG, TK_LONG, TK_FLOAT, TK_DOUBLE };
char ty_sizes[] = { 1, 1, 1, 1, 2, 2, 4, 4, 8, 8, 4, 8 };

void ty_init(void)
{
    int i;
    for (i = 0; i < 12; i++) {
        ty_new(ty_kinds[i], ty_sizes[i], ty_sizes[i], 0);
        if (i == 1 || (i < 10 && (i & 1))) ty[i].flags = TF_UNS;
    }
    ty_ptr(Y_CHAR);
    ty_ptr(Y_VOID);
    ty[ty_new(TK_FUNC, 0, 1, Y_INT)].flags = TF_OLD;
}

int tk(int t) { return ty[t].kind; }
int is_int(int t) { int k = ty[t].kind; return k >= TK_BOOL && k <= TK_LONG; }
int is_fp(int t) { int k = ty[t].kind; return k == TK_FLOAT || k == TK_DOUBLE; }
int is_ptr(int t) { return ty[t].kind == TK_PTR; }
int is_agg(int t) { int k = ty[t].kind; return k == TK_STRUCT || k == TK_UNION; }
int is_uns(int t) { return (ty[t].flags & TF_UNS) || ty[t].kind == TK_PTR; }

int promote(int t)
{
    if (is_int(t) && ty[t].size < 4) return Y_INT;
    return t;
}

/* the type both operands of an arithmetic operator are converted to */
int arith_type(int a, int b)
{
    int u;
    if (tk(a) == TK_DOUBLE || tk(b) == TK_DOUBLE) return Y_DOUBLE;
    if (tk(a) == TK_FLOAT || tk(b) == TK_FLOAT) return Y_FLOAT;
    a = promote(a);
    b = promote(b);
    if (ty[a].size == 8 || ty[b].size == 8) {
        u = (ty[a].size == 8 && is_uns(a)) || (ty[b].size == 8 && is_uns(b));
        return u ? Y_ULONG : Y_LONG;
    }
    return (is_uns(a) || is_uns(b)) ? Y_UINT : Y_INT;
}

/* a constant as the type holds it */
long cwrap(long v, int t)
{
    int s = 64 - 8 * ty[t].size;
    if (s <= 0 || ty[t].kind == TK_VOID) return v;
    if (ty[t].kind == TK_BOOL) return v != 0;
    if (ty[t].flags & TF_UNS) return (long)((unsigned long)(v << s) >> s);
    return v << s >> s;
}

/* ================= symbols ================= */

int sym_new(int id, int cls, int type)
{
    struct sym *s;
    if (nsy >= NSY) err("too many symbols", 0);
    s = &sy[nsy];
    s->id = id; s->type = type; s->prev = 0; s->aux = scope;
    s->cls = cls; s->flags = 0; s->val = 0;
    return nsy++;
}

/* a new symbol for an identifier; the one it hides comes back at scope_exit */
int sym_decl(int id, int cls, int type)
{
    int s = sym_new(id, cls, type), f = cls == SC_TAG;
    sy[s].prev = f ? id_tag(id) : id_sym(id);
    id_set(id, f, s);
    return s;
}

void scope_exit(int mark)
{
    struct sym *s;
    while (nsy > mark) {
        s = &sy[--nsy];
        if (s->cls != SC_MEMBER) id_set(s->id, s->cls == SC_TAG, s->prev);
    }
}

/* the member named id of a structure type (also inside its unnamed
   structure members): -> its symbol, mem_off = its offset */
int mem_find(int t, int id)
{
    int m, s;
    for (m = ty[t].aux; m; m = sy[m].prev) {
        if (sy[m].id == id) { mem_off = sy[m].val; return m; }
        if (!sy[m].id && is_agg(sy[m].type)) {
            s = mem_find(sy[m].type, id);
            if (s) { mem_off = mem_off + sy[m].val; return s; }
        }
    }
    return 0;
}

/* ================= registers, the frame, the value stack ================= */

void g_wrap(int x, int t);
int gv_d(struct val *v);
int mat_cmp(struct val *v);
void g_resolve(long chain, long target);

/* Code that is parsed but not compiled (the arm of a constant condition
   that is not taken, the operand of sizeof, a constant expression) must
   leave the values of live code as they are: the entries up to vlive, and
   the register mask */
struct dead { struct val *lv; int rm; };
struct val *vlive;

void dead_on(struct dead *d)
{
    d->lv = vlive;
    d->rm = rmask;
    if (!nocode) vlive = vp;
    nocode++;
}

void dead_off(struct dead *d)
{
    nocode--;
    vlive = d->lv;
    rmask = d->rm;
}

int fr_alloc(int size, int align)
{
    int a = (fr_cur + align - 1) & -align;
    fr_cur = a + size;
    if (fr_cur > fr_max) fr_max = fr_cur;
    return a;
}

void rfree(int r) { if (r < 7) rmask = rmask & ~(1 << r); }

/* what a value holds in registers goes to the frame */
void spill1(struct val *v)
{
    int s;
    if (nocode && v <= vlive) return;
    if (v->kind == VK_CMP) mat_cmp(v);
    else if (v->kind == VK_JMP) gv_d(v);
    if (v->kind != VK_REG && v->kind != VK_IND) return;
    s = fr_alloc(8, 8);
    e_i(OP_SD, ereg[v->reg], X_SP, s + sp_bias);
    rfree(v->reg);
    if (v->kind == VK_REG) { v->kind = VK_TMP; v->val = s; }
    else { v->kind = VK_SAVED; v->slot = s; }
}

void g_spill(struct val *top)
{
    struct val *v;
    for (v = vs + 1; v <= top; v++) spill1(v);
}

/* a free evaluation register; if there is none, the oldest value gives one up */
int ralloc(void)
{
    int r;
    struct val *v;
    for (;;) {
        for (r = 0; r < 6; r++)
            if (!(rmask >> r & 1)) { rmask = rmask | 1 << r; return r; }
        if (nocode) return 0;
        for (v = vs + 1; v <= vp; v++)
            if ((v->kind == VK_REG || v->kind == VK_IND || v->kind == VK_CMP) && v->reg < 6) break;
        if (v > vp) err("expression too complex", 0);
        spill1(v);
    }
}

struct val *vpush(int kind, int type, long val)
{
    if (vp >= vs + NVS - 1) err("expression too complex", 0);
    vp++;
    vp->kind = kind; vp->reg = 0; vp->flags = 0; vp->bw = 0;
    vp->type = type; vp->sym = 0; vp->val = val; vp->slot = 0; vp->boff = 0;
    return vp;
}

void vreg(int type, int r) { vpush(VK_REG, type, 0)->reg = r; }

void vfree(struct val *v)
{
    if (v->kind == VK_REG || v->kind == VK_IND) rfree(v->reg);
    else if (v->kind == VK_CMP) { rfree(v->reg); rfree(v->val); }
    else if (v->kind == VK_JMP) g_resolve(v->val, code_pc);
}

void vpop(void) { vfree(vp); vp--; }

void vswap(void)
{
    struct val t;
    t = vp[0]; vp[0] = vp[-1]; vp[-1] = t;
}

int const0(struct val *v) { return v->kind == VK_CONST && !v->sym && !v->val; }

/* ================= instructions ================= */

int fits(long v) { return v >= -32768 && v < 32768; }

void g_li(int x, long v)
{
    if (fits(v)) { e_i(OP_ADDI, x, 0, v); return; }
    if (v >= -0x80000000L && v <= 0x7fffffffL) {
        e_i(OP_LUI, x, 0, v >> 16);
        if (v & 0xffff) e_i(OP_ORI, x, x, v);
        return;
    }
    g_li(x, v >> 32);
    e_i(OP_SLLI, x, x, 16);
    if (v >> 16 & 0xffff) e_i(OP_ORI, x, x, v >> 16);
    e_i(OP_SLLI, x, x, 16);
    if (v & 0xffff) e_i(OP_ORI, x, x, v);
}

void g_addi(int xd, int xs, long v)
{
    if (fits(v)) { if (v || xd != xs) e_i(OP_ADDI, xd, xs, v); return; }
    g_li(X_TP, v);
    e_r(A_ADD, xd, xs, X_TP);
}

/* op x, off(base) */
void g_bo(int op, int x, int base, long off)
{
    int s = base == X_TP ? X_T6 : X_TP;
    if (fits(off)) { e_i(op, x, base, off); return; }
    g_li(s, off);
    e_r(A_ADD, s, s, base);
    e_i(op, x, s, 0);
}

/* the address of a symbol not placed yet into x: patched at the end */
void g_symaddr(int x, int s, long add)
{
    fix_add(code_pc, s, FK_LUI, add);
    e_i(OP_LUI, x, 0, 0);
    e_i(OP_ORI, x, x, 0);
}

/* op x, <the lvalue v> */
void g_mem(int op, int x, struct val *v)
{
    long a = v->val;
    switch (v->kind) {
    case VK_LOC:
    case VK_TMP:
        if (v->flags & VF_S0) g_bo(op, x, X_S0, a);
        else g_bo(op, x, X_SP, a + sp_bias);
        break;
    case VK_GLOB:
        if (v->sym) { fix_add(code_pc, v->sym, FK_MEM, a); e_i(op, x, 0, 0); }
        else if (a >= 0 && a < 0x8000) e_i(op, x, 0, a);
        else if (a >= 0x8000 && a < 0x10000) e_i(op, x, X_GP, a);
        else { g_li(X_TP, a); e_i(op, x, X_TP, 0); }
        break;
    case VK_IND:
        g_bo(op, x, ereg[v->reg], a);
        break;
    case VK_SAVED:
        e_i(OP_LD, X_TP, X_SP, v->slot + sp_bias);
        g_bo(op, x, X_TP, a);
        break;
    default:
        err("not an lvalue", 0);
    }
}

int ld_op(int t)
{
    int u = ty[t].flags & TF_UNS;
    switch (ty[t].size) {
    case 1: return u ? OP_LBU : OP_LB;
    case 2: return u ? OP_LHU : OP_LH;
    case 4: return u ? OP_LWU : OP_LW;
    }
    return OP_LD;
}

int st_op(int t)
{
    switch (ty[t].size) {
    case 1: return OP_SB;
    case 2: return OP_SH;
    case 4: return OP_SW;
    }
    return OP_SD;
}

/* the bits of a narrow type extended over the register */
void g_wrap(int x, int t)
{
    int s = 64 - 8 * ty[t].size, u = ty[t].flags & TF_UNS;
    if (s <= 0 || ty[t].kind == TK_BOOL) return;
    if (u && s >= 48) { e_i(OP_ANDI, x, x, s == 56 ? 255 : 0xffff); return; }
    e_i(OP_SLLI, x, x, s);
    e_i(u ? OP_SRLI : OP_SRAI, x, x, s);
}

void clean(struct val *v)
{
    if (v->kind == VK_REG && (v->flags & VF_DIRTY)) {
        g_wrap(ereg[v->reg], v->type);
        v->flags = v->flags & ~VF_DIRTY;
    }
}

/* the value of the lvalue v into the machine register x */
void g_load(int x, struct val *v)
{
    int t = v->type, k = ty[t].kind;
    if (k == TK_STRUCT || k == TK_UNION || k == TK_ARRAY || k == TK_FUNC || k == TK_VOID)
        err("not a value", 0);
    g_mem(ld_op(t), x, v);
    if (v->bw) {
        e_i(OP_SLLI, x, x, 64 - v->boff - v->bw);
        e_i((ty[t].flags & TF_UNS) ? OP_SRLI : OP_SRAI, x, x, 64 - v->bw);
    }
}

/* ---- jumps: a chain links, through their offset fields, the jumps that
   wait for one target ---- */

int lk(long pc, long chain) { return chain ? (pc - chain) >> 2 & 0xffff : 0; }

long g_jmp(long chain)
{
    long pc = code_pc;
    if (nocode) return chain;
    emit(OP_JAL << 26 | lk(pc, chain));
    return pc;
}

long g_br(int cond, int xa, int xb, long chain)
{
    long pc = code_pc;
    if (nocode) return chain;
    emit(enc(OP_BEQ + cond, xa, xb, lk(pc, chain)));
    return pc;
}

void g_jmp_to(long target) { emit(OP_JAL << 26 | ((target - code_pc) >> 2 & 0x1fffff)); }

long here(void) { lab_pc = code_pc; return code_pc; }

/* the link field of the jump at a: -> the next of its chain, or 0 */
long g_next(long a, int w)
{
    int d = w & 0xffff;
    if (d & 0x8000) d = d - 0x10000;
    return d ? a - 4 * d : 0;
}

void g_resolve(long chain, long target)
{
    int w, off;
    long n;
    if (nocode) return;
    if (chain && target == code_pc) lab_pc = code_pc;
    while (chain) {
        w = code_rd(chain);
        n = g_next(chain, w);
        off = (target - chain) >> 2;
        if ((w >> 26 & 63) == OP_JAL) w = (w & ~0x1fffff) | (off & 0x1fffff);
        else w = (w & ~0xffff) | (off & 0xffff);
        code_wr(chain, w);
        chain = n;
    }
}

/* two chains as one */
long g_join(long a, long b)
{
    long e = a, n;
    int w;
    if (nocode) return 0;
    if (!a) return b;
    if (!b) return a;
    for (;;) {
        w = code_rd(e);
        n = g_next(e, w);
        if (!n) break;
        e = n;
    }
    code_wr(e, (w & ~0xffff) | lk(e, b));
    return a;
}

/* ================= values into registers ================= */

/* a comparison as 0 or 1 */
int mat_cmp(struct val *v)
{
    int c = v->flags, a = v->reg, b = v->val, r, x, xa = ereg[a], xb = ereg[b];
    if (a < 7) { r = a; rfree(b); }
    else if (b < 7) r = b;
    else r = ralloc();
    x = ereg[r];
    if (c < 2) {
        if (a < 7 && b < 7) { e_r(A_XOR, x, xa, xb); xa = x; }
        else if (a == 7) xa = xb;
        if (c == 0) e_i(OP_SLTIU, x, xa, 1);
        else e_r(A_SLTU, x, 0, xa);
    } else {
        e_r(c < 4 ? A_SLT : A_SLTU, x, xa, xb);
        if (c & 1) e_i(OP_XORI, x, x, 1);
    }
    v->kind = VK_REG; v->reg = r; v->flags = 0; v->val = 0;
    return r;
}

/* the value into an evaluation register (its high bits may be dirty) */
int gv_d(struct val *v)
{
    int r, x, f = 0;
    switch (v->kind) {
    case VK_REG:
        return v->reg;
    case VK_CMP:
        return mat_cmp(v);
    case VK_CONST:
        r = ralloc();
        if (v->sym) g_symaddr(ereg[r], v->sym, v->val);
        else g_li(ereg[r], v->val);
        break;
    case VK_LADDR:
        r = ralloc();
        if (v->flags & VF_S0) g_addi(ereg[r], X_S0, v->val);
        else g_addi(ereg[r], X_SP, v->val + sp_bias);
        break;
    case VK_JMP:
        r = ralloc();
        x = ereg[r];
        f = (v->flags & VF_INV) != 0;
        e_i(OP_ADDI, x, 0, f);
        e_i(OP_JAL, 0, 0, 2);
        g_resolve(v->val, code_pc);
        e_i(OP_ADDI, x, 0, !f);
        f = 0;
        break;
    case VK_TMP:
        r = ralloc();
        g_mem(OP_LD, ereg[r], v);
        f = v->flags & VF_DIRTY;
        break;
    default:
        r = v->kind == VK_IND ? v->reg : ralloc();
        g_load(ereg[r], v);
    }
    v->kind = VK_REG; v->reg = r; v->flags = f; v->sym = 0; v->bw = 0; v->val = 0;
    return r;
}

int gv(struct val *v)
{
    int r = gv_d(v);
    clean(v);
    return r;
}

/* the value into the machine register x; the entry is dead afterwards */
void g_into(struct val *v, int x)
{
    switch (v->kind) {
    case VK_CONST:
        if (v->sym) g_symaddr(x, v->sym, v->val);
        else g_li(x, v->val);
        break;
    case VK_LADDR:
        if (v->flags & VF_S0) g_addi(x, X_S0, v->val);
        else g_addi(x, X_SP, v->val + sp_bias);
        break;
    case VK_TMP:
        g_mem(OP_LD, x, v);
        if (v->flags & VF_DIRTY) g_wrap(x, v->type);
        break;
    case VK_LOC: case VK_GLOB: case VK_IND: case VK_SAVED:
        g_load(x, v);
        if (v->kind == VK_IND) rfree(v->reg);
        break;
    default:
        gv(v);
        if (ereg[v->reg] != x) e_i(OP_ADDI, x, ereg[v->reg], 0);
        rfree(v->reg);
    }
    v->kind = 0;
}

/* an lvalue or a function becomes its address */
void v_addr(struct val *v)
{
    int r;
    if (v->bw) err("the address of a bit-field", 0);
    switch (v->kind) {
    case VK_LOC:
        v->kind = VK_LADDR;
        break;
    case VK_GLOB:
        v->kind = VK_CONST;
        break;
    case VK_IND:
        g_addi(ereg[v->reg], ereg[v->reg], v->val);
        v->kind = VK_REG; v->val = 0;
        break;
    case VK_SAVED:
        r = ralloc();
        e_i(OP_LD, ereg[r], X_SP, v->slot + sp_bias);
        g_addi(ereg[r], ereg[r], v->val);
        v->kind = VK_REG; v->reg = r; v->val = 0;
        break;
    default:
        err("not an lvalue", 0);
    }
}

/* an array becomes a pointer to its first element, a function a pointer to it */
void rv(void)
{
    int t = vp->type, k = ty[t].kind;
    if (k == TK_ARRAY) { v_addr(vp); vp->type = ty_ptr(ty[t].base); }
    else if (k == TK_FUNC) { v_addr(vp); vp->type = ty_ptr(t); }
    else if (vp->bw && vp->bw < 32) {   /* a narrow bit-field is an int */
        gv_d(vp);
        vp->type = Y_INT;
    }
}

/* a pointer becomes the lvalue it points to */
void v_deref(void)
{
    struct val *v = vp;
    int t = v->type;
    if (!is_ptr(t)) err("not a pointer", 0);
    if (v->kind == VK_CONST) v->kind = VK_GLOB;
    else if (v->kind == VK_LADDR) v->kind = VK_LOC;
    else { gv(v); v->kind = VK_IND; v->val = 0; }
    v->type = ty[t].base;
}

int is_lv(struct val *v)
{
    int k = v->kind;
    return k == VK_LOC || k == VK_GLOB || k == VK_IND || k == VK_SAVED;
}

/* [lvalue] -> [lvalue, its value] */
void v_dup(void)
{
    struct val *l = vp, *v;
    int r;
    if (!is_lv(l)) err("not an lvalue", 0);
    v = vpush(0, 0, 0);
    *v = *l;
    if (l->kind != VK_IND) return;
    r = ralloc();
    g_load(ereg[r], l);
    v->kind = VK_REG; v->reg = r; v->val = 0; v->bw = 0; v->flags = 0;
}

/* the address of the lvalue v into a new register; v stays */
int addr_reg(struct val *v)
{
    int r = ralloc(), x = ereg[r];
    switch (v->kind) {
    case VK_LOC:
        if (v->flags & VF_S0) g_addi(x, X_S0, v->val);
        else g_addi(x, X_SP, v->val + sp_bias);
        break;
    case VK_GLOB:
        if (v->sym) g_symaddr(x, v->sym, v->val);
        else g_li(x, v->val);
        break;
    case VK_IND:
        g_addi(x, ereg[v->reg], v->val);
        break;
    case VK_SAVED:
        e_i(OP_LD, x, X_SP, v->slot + sp_bias);
        g_addi(x, x, v->val);
        break;
    default:
        err("not an lvalue", 0);
    }
    return r;
}

/* the unit a block of a type is moved in */
int blk_unit(int t)
{
    int u = ty[t].align;
    if (u > 8) u = 8;
    while (ty[t].size % u) u = u >> 1;
    return u;
}

/* [dst lvalue, src lvalue] -> [dst lvalue]: the block is copied */
void g_copy(void)
{
    struct val *d = vp - 1, *s = vp;
    int n = ty[d->type].size, u = blk_unit(d->type), i, rd, rs, rt, lo, so;
    lo = u == 8 ? OP_LD : u == 4 ? OP_LW : u == 2 ? OP_LH : OP_LB;
    so = u == 8 ? OP_SD : u == 4 ? OP_SW : u == 2 ? OP_SH : OP_SB;
    if (!is_lv(d) || !is_lv(s)) err("not an lvalue", 0);
    rt = ralloc();
    if (n <= 8 * u) {
        for (i = 0; i < n; i = i + u) {
            s->val = s->val + i;
            g_mem(lo, ereg[rt], s);
            s->val = s->val - i;
            d->val = d->val + i;
            g_mem(so, ereg[rt], d);
            d->val = d->val - i;
        }
    } else {
        rd = addr_reg(d);
        rs = addr_reg(s);
        g_li(X_T6, n);
        e_r(A_ADD, X_T6, X_T6, ereg[rs]);
        e_i(lo, ereg[rt], ereg[rs], 0);
        e_i(so, ereg[rt], ereg[rd], 0);
        e_i(OP_ADDI, ereg[rs], ereg[rs], u);
        e_i(OP_ADDI, ereg[rd], ereg[rd], u);
        e_i(OP_BNE, ereg[rs], X_T6, -4);
        rfree(rd);
        rfree(rs);
    }
    rfree(rt);
    vpop();
}

/* the n bytes of the lvalue on top are set to zero */
void g_clear(int n)
{
    struct val *d = vp;
    int u = blk_unit(d->type), i, rd, so;
    so = u == 8 ? OP_SD : u == 4 ? OP_SW : u == 2 ? OP_SH : OP_SB;
    if (n <= 8 * u) {
        for (i = 0; i < n; i = i + u) {
            d->val = d->val + i;
            g_mem(so, 0, d);
            d->val = d->val - i;
        }
        return;
    }
    rd = addr_reg(d);
    g_li(X_T6, n);
    e_r(A_ADD, X_T6, X_T6, ereg[rd]);
    e_i(so, 0, ereg[rd], 0);
    e_i(OP_ADDI, ereg[rd], ereg[rd], u);
    e_i(OP_BNE, ereg[rd], X_T6, -2);
    rfree(rd);
}

/* ================= calls ================= */

/* the call instruction for the function entry f: a function by name, or
   else its address is in t6 */
void g_calljmp(struct val *f, int direct)
{
    long a = f->val;
    if (!direct) {
        if (paged) {                    /* below 0x10000 it is resident */
            e_i(OP_SRLI, X_TP, X_T6, 16);
            e_i(OP_BEQ, X_TP, 0, 3);
            e_i(OP_XCALL, X_RA, X_T6, 0);
            e_i(OP_JAL, 0, 0, 2);
        }
        e_i(OP_JALR, X_RA, X_T6, 0);
    } else if (f->sym) {
        if (paged) {
            g_symaddr(X_T6, f->sym, 0);
            e_i(OP_XCALL, X_RA, X_T6, 0);
        } else {
            fix_add(code_pc, f->sym, FK_JAL, 0);
            emit(OP_JAL << 26 | X_RA << 21);
        }
    } else if (!paged) emit(OP_JAL << 26 | X_RA << 21 | ((a - code_pc) >> 2 & 0x1fffff));
    else if (a < 0x10000) e_i(OP_JALR, X_RA, X_GP, a);
    else {
        g_li(X_T6, a);
        e_i(OP_XCALL, X_RA, X_T6, 0);
    }
}

/* argument i of a call into its place: a0..a7, then the stack */
void g_place(struct val *v, int i)
{
    if (i < 8) { g_into(v, X_A0 + i); return; }
    g_into(v, X_T6);
    e_i(OP_SD, X_T6, X_SP, 8 * (i - 8));
}

/* [function, n arguments] -> [result] */
void g_call(int n)
{
    struct val *f = vp - n, *v;
    int ft = f->type, rt, sret = -1, i, k, nst, direct, r;
    direct = tk(ft) == TK_FUNC && f->kind == VK_GLOB;
    if (tk(ft) == TK_PTR) ft = ty[ft].base;
    else if (!direct) v_addr(f);
    if (tk(ft) != TK_FUNC) err("not a function", 0);
    rt = ty[ft].base;
    if (is_agg(rt)) sret = fr_alloc(ty[rt].size, 8);
    g_spill(f - 1);
    if (!direct) {
        r = gv(f);
        if (r == 6) {                   /* a0 is for the first argument */
            r = ralloc();
            e_i(OP_ADDI, ereg[r], X_A0, 0);
            rfree(6);
            f->reg = r;
        }
    }
    k = sret >= 0;
    nst = n + k - 8;
    if (nst > 0) {
        e_i(OP_ADDI, X_SP, X_SP, -8 * nst);
        sp_bias = sp_bias + 8 * nst;
    }
    for (i = 0; i < n; i++) {           /* first what a0 holds: it is overwritten below */
        v = f + 1 + i;
        if ((v->kind == VK_REG || v->kind == VK_IND) && v->reg == 6) g_place(v, i + k);
    }
    for (i = 8 - k; i < n; i++) if (f[1 + i].kind) g_place(f + 1 + i, i + k);
    for (i = 0; i < n; i++) if (f[1 + i].kind) g_place(f + 1 + i, i + k);
    if (k) g_addi(X_A0, X_SP, sret + sp_bias);
    if (!direct) g_into(f, X_T6);
    g_calljmp(f, direct);
    if (nst > 0) {
        e_i(OP_ADDI, X_SP, X_SP, 8 * nst);
        sp_bias = sp_bias - 8 * nst;
    }
    vp = f - 1;
    if (k) vpush(VK_LOC, rt, sret);
    else if (tk(rt) == TK_VOID) vpush(VK_CONST, rt, 0);
    else { vreg(rt, 6); rmask = rmask | 64; }
}

char *fp_names[] = { "__fadd", "__fsub", "__fmul", "__fdiv", "__fcmp", "__itof", "__utof",
                     "__ftoi", "__ftou", "__f2d", "__d2f" };
int fp_adr[11];
#define F_ADD 0
#define F_CMP 4
#define F_ITOF 5
#define F_UTOF 6
#define F_FTOI 7
#define F_FTOU 8
#define F_F2D 9
#define F_D2F 10

long lib_lookup(int id);

/* a call of the function at address a with the n values on top; the result has type rt */
void g_calladdr(long a, int n, int rt)
{
    struct val *f;
    int i;
    vpush(0, 0, 0);
    for (i = 0; i < n; i++) vp[-i] = vp[-i - 1];
    f = vp - n;
    f->kind = VK_GLOB; f->type = Y_FUNC0; f->val = a;
    f->sym = 0; f->flags = 0; f->bw = 0;
    g_call(n);
    vp->type = rt;
}

/* a call of the library's floating-point routine k with the n values on
   top as its arguments; the result has type rt */
void fp_call(int k, int n, int rt)
{
    if (!fp_adr[k]) {
        fp_adr[k] = lib_lookup(intern(fp_names[k], slen(fp_names[k])));
        if (fp_adr[k] < 0) err("cc.lib lacks ", fp_names[k]);
    }
    g_calladdr(fp_adr[k], n, rt);
}

/* a call of the library function `name` with the n values on top */
void g_libfn(char *name, int n, int rt)
{
    long a = lib_lookup(intern(name, slen(name)));
    if (a < 0) err("cc.lib lacks ", name);
    g_calladdr(a, n, rt);
}

/* ================= conversions ================= */

void to_cmp(struct val *v)
{
    int r;
    if (v->kind == VK_CMP || v->kind == VK_JMP) return;
    r = gv(v);
    if (is_fp(v->type)) e_i(OP_SLLI, ereg[r], ereg[r], ty[v->type].size == 4 ? 33 : 1);
    v->kind = VK_CMP; v->reg = r; v->val = 7; v->flags = 1; v->type = Y_INT;
}

/* a conversion between integer and pointer types: no library call */
void icast(struct val *v, int to)
{
    int from = v->type, sf = ty[from].size, st = ty[to].size, k = v->kind, same, fit;
    v->type = to;
    if (k == VK_CONST) { if (!v->sym) v->val = cwrap(v->val, to); return; }
    if (k == VK_CMP || k == VK_JMP) return;
    if (is_lv(v)) {
        if (st <= sf && !v->bw && tk(from) != TK_BOOL) return;      /* read as the new type */
        v->type = from;
        gv_d(v);
        v->type = to;
    } else if (k == VK_LADDR || k == VK_TMP) {
        if (st == 8 && !(v->flags & VF_DIRTY)) return;
        v->type = from;
        gv(v);
        v->type = to;
    }
    if (v->flags & VF_DIRTY) {
        if (st <= sf) return;
        g_wrap(ereg[v->reg], from);
        v->flags = v->flags & ~VF_DIRTY;
    }
    same = sf == st && !is_uns(from) == !is_uns(to);
    fit = sf < st && (is_uns(from) || !is_uns(to));
    if (st < 8 && !same && !fit) v->flags = v->flags | VF_DIRTY;
}

/* the constant on top between floating and other arithmetic types */
void f_cfold(int from, int to)
{
    long v = vp->val, d;
    if (tk(from) == TK_FLOAT) d = __f2d(v);
    else if (tk(from) == TK_DOUBLE) d = v;
    else if (ty[from].size == 8 && is_uns(from)) d = __utof(v);
    else d = __itof(v);
    if (tk(to) == TK_DOUBLE) v = d;
    else if (tk(to) == TK_FLOAT) v = __d2f(d);
    else if (ty[to].size == 8 && is_uns(to)) v = __ftou(d);
    else {
        v = __ftoi(d);
        if (v < 0 && is_uns(to) && ty[to].size < 4) v = 0;
        v = cwrap(v, to);
    }
    vp->val = v;
    vp->type = to;
}

/* the value on top to type `to`; one of the two types is floating */
void f_cast(int to)
{
    int from = vp->type, kf = tk(from), kt = tk(to);
    if (kf == kt) { vp->type = to; return; }
    if (vp->kind == VK_CONST && !vp->sym) { f_cfold(from, to); return; }
    if (kf == TK_FLOAT) fp_call(F_F2D, 1, Y_DOUBLE);
    else if (kf != TK_DOUBLE) {
        if (ty[from].size == 8 && is_uns(from)) fp_call(F_UTOF, 1, Y_DOUBLE);
        else { icast(vp, Y_LONG); fp_call(F_ITOF, 1, Y_DOUBLE); }
    }
    if (kt == TK_DOUBLE) return;
    if (kt == TK_FLOAT) { fp_call(F_D2F, 1, to); return; }
    fp_call(ty[to].size == 8 && is_uns(to) ? F_FTOU : F_FTOI, 1, Y_LONG);
    if (is_uns(to) && ty[to].size < 4) {        /* below zero there is no value: 0 */
        kf = ereg[gv(vp)];
        e_i(OP_SRAI, X_TP, kf, 63);
        e_i(OP_ADDI, X_TP, X_TP, 1);
        e_r(A_MUL, kf, kf, X_TP);
    }
    icast(vp, to);
}

/* the value on top to 0 or 1 */
void to_bool(int t)
{
    struct val *v = vp;
    if (v->kind == VK_CONST) {
        if (v->sym) { v->sym = 0; v->val = 1; }
        else if (is_fp(v->type)) v->val = v->val << (ty[v->type].size == 4 ? 33 : 1) != 0;
        else v->val = v->val != 0;
    } else to_cmp(v);
    v->type = t;
}

/* the value on top converted to type `to` */
void g_cast(int to)
{
    int from = vp->type, kt = tk(to);
    if (from == to) return;
    if (kt == TK_VOID) { vpop(); vpush(VK_CONST, to, 0); return; }
    if (is_agg(to) || is_agg(from) || kt == TK_ARRAY || kt == TK_FUNC) return;
    if (kt == TK_BOOL) { if (tk(from) != TK_BOOL) to_bool(to); else vp->type = to; return; }
    if (is_fp(from) || is_fp(to)) { f_cast(to); return; }
    icast(vp, to);
}

/* ================= operators ================= */

int is_cmp(int op)
{
    return op == T_EQ || op == T_NE || op == '<' || op == '>' || op == T_LE || op == T_GE;
}

/* a op b for constants of type t */
long fold(int op, long a, long b, int t)
{
    unsigned long ua = a, ub = b;
    int u = is_uns(t);
    switch (op) {
    case '+': return a + b;
    case '-': return a - b;
    case '*': return a * b;
    case '&': return a & b;
    case '|': return a | b;
    case '^': return a ^ b;
    case T_SHL: return a << (b & 63);
    case T_SHR: return u ? (long)(ua >> (b & 63)) : a >> (b & 63);
    case '/': case '%':
        if (!b) return 0;
        if (op == '/') return u ? (long)(ua / ub) : a / b;
        return u ? (long)(ua % ub) : a % b;
    case T_EQ: return a == b;
    case T_NE: return a != b;
    case '<': return u ? ua < ub : a < b;
    case '>': return u ? ua > ub : a > b;
    case T_LE: return u ? ua <= ub : a <= b;
    case T_GE: return u ? ua >= ub : a >= b;
    }
    err("invalid operands", 0);
    return 0;
}

/* [a, b] -> the comparison, not made yet */
void g_cmp(int op, int t)
{
    struct val *a = vp - 1, *b = vp;
    int c = 0, sw = 0, ra, rb;
    switch (op) {
    case T_NE: c = 1; break;
    case '<': c = 2; break;
    case T_GE: c = 3; break;
    case '>': c = 2; sw = 1; break;
    case T_LE: c = 3; sw = 1; break;
    }
    if (c >= 2 && is_uns(t)) c = c + 2;
    ra = const0(a) ? 7 : gv(a);
    rb = const0(b) ? 7 : gv(b);
    vp--;
    a->kind = VK_CMP; a->reg = sw ? rb : ra; a->val = sw ? ra : rb;
    a->flags = c; a->type = Y_INT; a->sym = 0; a->bw = 0;
}

/* log2 of a power of two, or -1 */
int log2of(long c)
{
    int n = 0;
    if (c <= 0 || (c & (c - 1))) return -1;
    while (c > 1) { c = c >> 1; n++; }
    return n;
}

/* the immediate form of `a op c`: -> the opcode (0: none), *pc the immediate */
int imm_op(int op, long *pc, int u)
{
    long c = *pc;
    switch (op) {
    case '+': return fits(c) ? OP_ADDI : 0;
    case '-': *pc = -c; return fits(-c) ? OP_ADDI : 0;
    case '&': return c >= 0 && c < 65536 ? OP_ANDI : 0;
    case '|': return c >= 0 && c < 65536 ? OP_ORI : 0;
    case '^': return c >= 0 && c < 65536 ? OP_XORI : 0;
    case T_SHL: *pc = c & 63; return OP_SLLI;
    case T_SHR: *pc = c & 63; return u ? OP_SRLI : OP_SRAI;
    case '*': *pc = log2of(c); return *pc >= 0 ? OP_SLLI : 0;
    case '/': *pc = log2of(c); return u && *pc >= 0 ? OP_SRLI : 0;
    }
    return 0;
}

int alu_fn(int op, int u)
{
    switch (op) {
    case '+': return A_ADD;
    case '-': return A_SUB;
    case '*': return A_MUL;
    case '&': return A_AND;
    case '|': return A_OR;
    case '^': return A_XOR;
    case T_SHL: return A_SLL;
    case T_SHR: return u ? A_SRL : A_SRA;
    case '/': return u ? A_DIVU : A_DIV;
    case '%': return u ? A_REMU : A_REM;
    }
    err("invalid operands", 0);
    return 0;
}

/* [a, b] -> [a op b], both of the integer type t already */
void g_arith(int op, int t)
{
    struct val *a = vp - 1, *b = vp;
    int f = 0, ra, rb, x, u = is_uns(t), cl, dirty;
    long c;
    if (a->kind == VK_CONST && !a->sym && (op == '+' || op == '*' || op == '&' || op == '|' || op == '^')) {
        vswap();
    }
    cl = op == '/' || op == '%' || op == T_SHR;
    if (b->kind == VK_CONST && !b->sym) {
        c = b->val;
        f = imm_op(op, &c, u);
    }
    ra = cl ? gv(a) : gv_d(a);
    x = ereg[ra];
    dirty = a->flags & VF_DIRTY;
    if (f) { e_i(f, x, x, c); vp--; }
    else {
        rb = cl || op == T_SHL ? gv(b) : gv_d(b);
        dirty = dirty | (b->flags & VF_DIRTY);
        e_r(alu_fn(op, u), x, x, ereg[rb]);
        vpop();
    }
    if (op == '+' || op == '-' || op == '*' || op == T_SHL) dirty = VF_DIRTY;
    if (ty[t].size == 8) dirty = 0;
    a->flags = dirty;
    a->type = t;
}

void g_binop(int op);

int is_vm(int t) { return ty[t].kind == TK_ARRAY && ty[t].x == 3; }

/* the size of a type as a value: a constant, or the frame word of a variable array type */
void vm_size(int t)
{
    if (is_vm(t)) vpush(VK_LOC, Y_LONG, ty[t].aux);
    else vpush(VK_CONST, Y_LONG, ty[t].size);
}

/* [a, b] -> [a op b] where a pointer is involved */
void g_ptrop(int op)
{
    struct val *a = vp - 1, *b = vp;
    int t, sz, s, vm;
    if (is_cmp(op)) {
        icast(a, Y_ULONG);
        icast(b, Y_ULONG);
        if (a->kind == VK_CONST && b->kind == VK_CONST && !a->sym && !b->sym) {
            a->val = fold(op, a->val, b->val, Y_ULONG);
            a->type = Y_INT;
            vp--;
        } else g_cmp(op, Y_ULONG);
        return;
    }
    if (op != '+' && op != '-') err("invalid operands", 0);
    if (!is_ptr(a->type)) { vswap(); if (op == '-') err("invalid operands", 0); }
    t = a->type;
    sz = ty[ty[t].base].size;
    vm = is_vm(ty[t].base);
    if (!sz) sz = 1;
    if (is_ptr(b->type)) {              /* the difference of two pointers */
        icast(a, Y_LONG);
        icast(b, Y_LONG);
        g_arith('-', Y_LONG);
        if (vm) { vm_size(ty[t].base); g_arith('/', Y_LONG); return; }
        s = log2of(sz);
        if (s > 0) e_i(OP_SRAI, ereg[vp->reg], ereg[vp->reg], s);
        else if (s < 0) { vpush(VK_CONST, Y_LONG, sz); g_arith('/', Y_LONG); }
        return;
    }
    if (!is_int(b->type)) err("invalid operands", 0);
    icast(b, Y_LONG);
    if (vm) {
        vm_size(ty[t].base);
        g_arith('*', Y_LONG);
    } else if (b->kind == VK_CONST && !b->sym) {
        b->val = b->val * sz;
        if (a->kind == VK_CONST || a->kind == VK_LADDR) {
            a->val = op == '+' ? a->val + b->val : a->val - b->val;
            vp--;
            return;
        }
    } else if (sz > 1) {
        vpush(VK_CONST, Y_LONG, sz);
        g_arith('*', Y_LONG);
    }
    a->type = Y_LONG;
    if (a->kind == VK_LADDR || (a->kind == VK_CONST && a->sym)) gv(a);
    g_arith(op, Y_LONG);
    vp->type = t;
}

/* [a, b] -> [a op b] for floating operands */
void f_binop(int op)
{
    struct val *a = vp - 1, *b = vp;
    int t = arith_type(a->type, b->type), k, r;
    long v;
    if (!is_cmp(op) && op != '+' && op != '-' && op != '*' && op != '/') err("invalid operands", 0);
    k = op == '+' ? 0 : op == '-' ? 1 : op == '*' ? 2 : op == '/' ? 3 : F_CMP;
    f_cast(Y_DOUBLE);
    vswap();
    f_cast(Y_DOUBLE);
    vswap();
    if (a->kind == VK_CONST && b->kind == VK_CONST) {
        if (k == 0) v = __fadd(a->val, b->val);
        else if (k == 1) v = __fsub(a->val, b->val);
        else if (k == 2) v = __fmul(a->val, b->val);
        else if (k == 3) v = __fdiv(a->val, b->val);
        else v = __fcmp(a->val, b->val);
        vp--;
        a->val = v;
    } else fp_call(k, 2, Y_DOUBLE);
    if (k != F_CMP) { vp->type = Y_DOUBLE; f_cast(t); return; }
    vp->type = Y_LONG;                  /* -1, 0, 1, or 2: unordered */
    r = 0;
    if (op == T_LE || op == '>') r = 1;
    if (op == T_GE) { r = 2; vp->type = Y_ULONG; }
    vpush(VK_CONST, vp->type, r);
    g_binop(op == T_LE || op == T_GE ? '<' : op == '>' ? T_EQ : op);
}

/* [a, b] -> [a op b] */
void g_binop(int op)
{
    struct val *a = vp - 1, *b = vp;
    int ta = a->type, tb = b->type, t;
    if (is_ptr(ta) || is_ptr(tb)) { g_ptrop(op); return; }
    if (is_fp(ta) || is_fp(tb)) { f_binop(op); return; }
    if (!is_int(ta) || !is_int(tb)) err("invalid operands", 0);
    if (op == T_SHL || op == T_SHR) { t = promote(ta); icast(b, promote(tb)); }
    else { t = arith_type(ta, tb); icast(b, t); }
    icast(a, t);
    if (a->kind == VK_CONST && b->kind == VK_CONST && !a->sym && !b->sym) {
        a->val = fold(op, a->val, b->val, t);
        if (is_cmp(op)) a->type = Y_INT;
        else a->val = cwrap(a->val, t);
        vp--;
        return;
    }
    if (is_cmp(op)) g_cmp(op, t);
    else g_arith(op, t);
}

/* [a] -> [op a] for - ~ ! + */
void g_unop(int op)
{
    struct val *v = vp;
    int t = v->type, r, x;
    if (op == '!') {
        if (v->kind == VK_CONST) { to_bool(Y_INT); v->val = !v->val; return; }
        to_cmp(v);
        if (v->kind == VK_JMP) v->flags = v->flags ^ VF_INV;
        else v->flags = v->flags ^ 1;
        return;
    }
    if (is_fp(t)) {
        if (op == '~') err("invalid operands", 0);
        if (op == '+') return;
        if (v->kind == VK_CONST) {
            v->val = ty[t].size == 4 ? v->val ^ -0x80000000L : v->val ^ (1L << 63);
            return;
        }
        r = gv(v);
        if (ty[t].size == 4) e_i(OP_LUI, X_TP, 0, 0x8000);
        else { e_i(OP_ADDI, X_TP, 0, 1); e_i(OP_SLLI, X_TP, X_TP, 63); }
        e_r(A_XOR, ereg[r], ereg[r], X_TP);
        return;
    }
    if (!is_int(t)) err("invalid operands", 0);
    t = promote(t);
    icast(v, t);
    if (op == '+') { if (is_lv(v)) gv(v); return; }
    if (v->kind == VK_CONST && !v->sym) {
        v->val = cwrap(op == '-' ? -v->val : ~v->val, t);
        return;
    }
    r = gv_d(v);
    x = ereg[r];
    e_r(A_SUB, x, 0, x);
    if (op == '~') e_i(OP_ADDI, x, x, -1);
    if (ty[t].size < 8 && (op == '-' || is_uns(t))) v->flags = v->flags | VF_DIRTY;
}

/* [lvalue, value] -> [value]: the value, already of the lvalue's type, is stored */
void g_store(void)
{
    struct val *l = vp - 1, *v = vp;
    int t = l->type, x = 0, r, ru, w = l->bw, b = l->boff;
    if (is_agg(t)) { g_copy(); return; }
    if (!is_lv(l)) err("not an lvalue", 0);
    if (!const0(v)) x = ereg[w ? gv(v) : gv_d(v)];
    if (!w) g_mem(st_op(t), x, l);
    else {                              /* a bit-field: into its place in the storage unit */
        l->bw = 0;
        ru = ralloc();
        r = ereg[ru];
        g_mem(ld_op(t), r, l);
        g_li(X_TP, ~(((1L << w) - 1) << b));
        e_r(A_AND, r, r, X_TP);
        if (x) {
            e_i(OP_SLLI, X_TP, x, 64 - w);
            e_i(OP_SRLI, X_TP, X_TP, 64 - w - b);
            e_r(A_OR, r, r, X_TP);
        }
        g_mem(st_op(t), r, l);
        rfree(ru);
        if (x) {                        /* the value as the field holds it */
            e_i(OP_SLLI, x, x, 64 - w);
            e_i(is_uns(t) ? OP_SRLI : OP_SRAI, x, x, 64 - w);
            v->flags = 0;
        }
        if (w < 32) v->type = Y_INT;
    }
    vfree(l);
    *l = *v;
    vp--;
}

/* the jumps taken when the value on top is true (want 1) or false (want 0),
   added to a chain; the value is consumed */
long jmp_if(int want, long chain)
{
    struct val *v = vp;
    long t;
    if (v->kind == VK_CONST) {
        if ((v->sym || v->val != 0) == want) chain = g_jmp(chain);
        vp--;
        return chain;
    }
    if (v->kind == VK_JMP) {
        t = v->val;
        vp--;
        if (!(v->flags & VF_INV) == want) return g_join(t, chain);
        chain = g_jmp(chain);
        g_resolve(t, code_pc);
        return chain;
    }
    to_cmp(v);
    chain = g_br(v->flags ^ !want, ereg[v->reg], ereg[v->val], chain);
    vpop();
    return chain;
}

/* ================= variable-length arrays ================= */

/* [count] -> ; array type t gets its size, count elements, in a frame word */
void vm_set(int t)
{
    int slot = fr_alloc(8, 8), r;
    vm_size(ty[t].base);
    g_arith('*', Y_LONG);
    r = gv(vp);
    e_i(OP_SD, ereg[r], X_SP, slot + sp_bias);
    vpop();
    ty[t].x = 3; ty[t].aux = slot; ty[t].size = 0;
}

int vm_arr(int b)
{
    int t = ty_new(TK_ARRAY, 0, ty[b].align, b);
    vm_set(t);
    return t;
}

/* the storage of the variable-length array s: from malloc, its address in a frame word */
void vla_new(int s)
{
    int slot = fr_alloc(8, 8), r;
    vm_size(sy[s].type);
    g_libfn("malloc", 1, Y_VOIDP);
    r = gv(vp);
    e_i(OP_SD, ereg[r], X_SP, slot + sp_bias);
    vpop();
    sy[s].val = slot;
    sy[s].flags = SF_REF | SF_VLA;
    fn_vla = 1;
}

/* the variable-length arrays declared since symbol `from` are given back */
void vla_free(int from)
{
    int i;
    for (i = nsy - 1; i >= from; i--)
        if (sy[i].flags & SF_VLA && sy[i].cls == SC_AUTO) {
            vpush(VK_LOC, Y_VOIDP, sy[i].val);
            g_libfn("free", 1, Y_VOID);
            vpop();
        }
}

/* ================= intrinsics ================= */

/* A call of one of these names, when the program has not declared the
   name, is the one instruction (see <strata.h>). Per name: the instruction
   word without its operands; the number of arguments; where the result
   register goes (a shift; 255: no result; 254: it is left in a0); and per
   argument a shift, with 0x80 set if the argument is a constant encoded in
   the word (shift 63: a register argument the instruction finds in a0..). */
char *in_name[] = {
    "__tget", "__tput", "__tgetx", "__twait", "__tpoll", "__tany",
    "__tamo_add", "__tamo_swap", "__tamo_cas", "__tamo_and", "__tamo_or", "__cbase",
    "__clen", "__cperms", "__cvalid", "__cmov", "__cjoin", "__cshare",
    "__csplit", "__crestrict", "__cclear", "__ctake", "__cgive", "__cpoll",
    "__csend", "__csrr", "__csrw", "__svc", "__halt", "__ltag",
    "__linst",
    0 };
int in_base[] = {
    0xc0000000, 0xc0800000, 0xc1000000, 0xc4000000, 0xc8000000, 0xd8000000,
    0xcc000000, 0xcc000001, 0xcc000002, 0xcc000003, 0xcc000004, 0xd0000006,
    0xd0000007, 0xd0000008, 0xd000000e, 0xd0000000, 0xd0000002, 0xd0000003,
    0xd0000001, 0xd0000005, 0xd000000b, 0xd000000a, 0xd0000009, 0xd000000f,
    0xd4000003, 0xe0000000, 0xe4000000, 0xe8000002, 0xe8000000, 0xec000000,
    0xf0000000,
};
unsigned char in_spec[] = {       /* arguments, result, a field per argument */
    5, 255, 147, 14, 138, 5, 0, 0,
    5, 255, 147, 14, 138, 5, 0, 0,
    5, 255, 147, 14, 138, 5, 0, 0,
    1, 255, 128, 0, 0, 0, 0, 0,
    1, 21, 128, 0, 0, 0, 0, 0,
    1, 21, 16, 0, 0, 0, 0, 0,
    3, 21, 135, 16, 11, 0, 0, 0,
    3, 21, 135, 16, 11, 0, 0, 0,
    3, 21, 135, 16, 11, 0, 0, 0,
    3, 21, 135, 16, 11, 0, 0, 0,
    3, 21, 135, 16, 11, 0, 0, 0,
    1, 21, 144, 0, 0, 0, 0, 0,
    1, 21, 144, 0, 0, 0, 0, 0,
    1, 21, 144, 0, 0, 0, 0, 0,
    1, 21, 144, 0, 0, 0, 0, 0,
    2, 255, 149, 144, 0, 0, 0, 0,
    2, 255, 149, 144, 0, 0, 0, 0,
    2, 255, 149, 144, 0, 0, 0, 0,
    3, 255, 149, 144, 11, 0, 0, 0,
    3, 255, 149, 144, 11, 0, 0, 0,
    1, 255, 149, 0, 0, 0, 0, 0,
    1, 255, 149, 0, 0, 0, 0, 0,
    2, 255, 144, 11, 0, 0, 0, 0,
    0, 21, 0, 0, 0, 0, 0, 0,
    2, 255, 144, 149, 0, 0, 0, 0,
    1, 21, 128, 0, 0, 0, 0, 0,
    2, 255, 128, 16, 0, 0, 0, 0,
    6, 254, 63, 63, 63, 63, 63, 63,
    1, 255, 63, 0, 0, 0, 0, 0,
    1, 21, 16, 0, 0, 0, 0, 0,
    1, 255, 16, 0, 0, 0, 0, 0,
};

void expr(void);
void assign(void);
void cond(void);
void unary(void);
long const_expr(void);
int type_name(void);
int is_type(void);
void comp_lit(int t);

void intrinsic(int k)
{
    unsigned char *e = in_spec + 8 * k;
    struct val *base = vp;
    int w = in_base[k], na = e[0], i, a, nr = 0;
    next();
    g_spill(vp);
    for (i = 0; i < na; i++) {
        if (i) skip(',');
        a = e[2 + i];
        if (a & 0x80) { w = w | const_expr() << (a & 63); continue; }
        assign();
        rv();
        if ((a & 63) != 63) w = w | (X_A0 + nr) << a;
        nr++;
        g_spill(vp);
    }
    skip(')');
    for (i = 0; i < nr; i++) g_into(base + 1 + i, X_A0 + i);
    vp = base;
    if (e[1] < 64) w = w | X_A0 << e[1];
    emit(w);
    if (e[1] == 255) vpush(VK_CONST, Y_VOID, 0);
    else { vreg(Y_LONG, 6); rmask = rmask | 64; }
}

/* ================= expressions ================= */

#ifndef STK_MIN
#define STK_MIN 0xE400          /* the stack is 0xE000..0xFFFF */
#endif

void stk_check(void)
{
    char c;
    if ((unsigned long)&c < STK_MIN) err("nested too deeply", 0);
}

/* the type char[n], a recent one if there is one */
int str_ty(int n)
{
    int i;
    for (i = nty - 1; i > Y_FUNC0 && i > nty - 48; i--)
        if (ty[i].kind == TK_ARRAY && ty[i].base == Y_CHAR && ty[i].size == n) return i;
    return ty_arr(Y_CHAR, n);
}

/* tok is a string: it and the strings that follow it are one, in strbuf */
void str_take(void)
{
    str_cat = 1;
    next();
    while (tok == T_STR) next();
    str_cat = 0;
}

/* the str_len characters of strbuf and a zero, as an array in the data */
void str_push(void)
{
    int n = str_len + 1, i;
    long a;
    if (str_wide) {
        n = str_len + 4;
        for (i = 0; i < 4; i++) strbuf[str_len + i] = 0;
    }
    a = data_alloc(n, str_wide ? 4 : 1);
    if (!ini_dry) for (i = 0; i < n; i++) data_b(a + i, strbuf[i]);
    vpush(VK_GLOB, str_wide ? ty_arr(Y_INT, n / 4) : str_ty(n), a);
}

/* a symbol as a value */
void v_sym(int s)
{
    struct sym *p = &sy[s];
    struct val *v;
    switch (p->cls) {
    case SC_ENUM:
        vpush(VK_CONST, Y_INT, p->val);
        return;
    case SC_AUTO:
        v = vpush(VK_LOC, p->type, p->val);
        if (p->flags & SF_REF) { v->kind = VK_SAVED; v->slot = p->val; v->val = 0; }
        else if (p->flags & SF_S0) v->flags = VF_S0;
        return;
    case SC_STATIC: case SC_FUNC:
        v = vpush(VK_GLOB, p->type, p->val);
        if (!(p->flags & SF_DEF)) { v->sym = s; v->val = 0; }
        return;
    }
    err("not a value: ", id_name(p->id));
}

/* __builtin_va_arg(ap, type): the next argument word is the value, or, for
   a structure, its address; ap moves on */
void va_arg_x(void)
{
    int t;
    next();
    assign();
    skip(',');
    t = type_name();
    skip(')');
    v_dup();
    vpush(VK_CONST, Y_INT, 8);
    g_binop('+');
    g_store();
    vpush(VK_CONST, Y_INT, 8);
    g_binop('-');
    if (is_agg(t)) {
        vp->type = ty_ptr(ty_ptr(t));
        v_deref();
    } else vp->type = ty_ptr(t);
    v_deref();
}

/* __builtin_va_start(ap, last): ap = the address of the first unnamed
   argument: in a variadic function all the argument words are in a row */
void va_start_x(void)
{
    next();
    assign();
    skip(',');
    if (tok != T_ID) errtok("syntax error near ");
    next();
    skip(')');
    vpush(VK_LADDR, Y_CHARP, fn_va)->flags = VF_S0;
    g_store();
    vpop();
    vpush(VK_CONST, Y_VOID, 0);
}

void primary(void)
{
    int id, s, i;
    char *n;
    switch (tok) {
    case T_NUM:
        vpush(VK_CONST, tk_ty, tk_val);
        next();
        return;
    case T_STR:
        str_take();
        str_push();
        return;
    case T_ID:
        id = tk_val;
        s = tk_sym;
        next();
        if (s) { v_sym(s); return; }
        n = id_name(id);
        if (id == id_func && fn_sym) {
            n = id_name(sy[fn_sym].id);
            for (i = 0; n[i]; i++) strbuf[i] = n[i];
            strbuf[i] = 0;
            str_len = i;
            str_push();
            return;
        }
        if (ce_soft && tok != '(') { ce_fail = 1; vpush(VK_CONST, Y_INT, 0); return; }
        if (tok != '(') err("undeclared: ", n);
        if (streq(n, "__builtin_va_arg")) { va_arg_x(); return; }
        if (streq(n, "__builtin_va_start")) { va_start_x(); return; }
        if (n[0] == '_' && n[1] == '_')
            for (i = 0; in_name[i]; i++)
                if (streq(n, in_name[i])) { intrinsic(i); return; }
        v_sym(sym_decl(id, SC_FUNC, Y_FUNC0));
        return;
    }
    errtok("syntax error near ");
}

/* [function] (arguments) -> [result] */
void call(void)
{
    struct val *f = vp, *v;
    int n = 0, ft = f->type, np, pi, t, s, c;
    if (tk(ft) != TK_FUNC) {
        rv();
        ft = vp->type;
        if (is_ptr(ft)) ft = ty[ft].base;
    }
    if (tk(ft) != TK_FUNC) err("not a function", 0);
    np = (ty[ft].flags & TF_OLD) ? -1 : ty[ft].size;
    pi = ty[ft].aux;
    next();
    while (tok != ')') {
        assign();
        rv();
        t = vp->type;
        if (is_agg(t)) {                /* a structure: the address of a copy */
            s = fr_alloc(ty[t].size, 8);
            vpush(VK_LOC, t, s);
            vswap();
            g_copy();
            v_addr(vp);
            vp->type = ty_ptr(t);
        } else if (n < np) g_cast(pt_get(pi + n));
        else if (tk(t) == TK_FLOAT) g_cast(Y_DOUBLE);
        if (vp->kind == VK_CMP || vp->kind == VK_JMP) gv(vp);
        for (c = 0, s = rmask & 63; s; s = s >> 1) c = c + (s & 1);
        if (c >= 4) for (v = f + 1; v <= vp; v++) spill1(v);
        n++;
        if (tok != ',') break;
        next();
    }
    skip(')');
    g_call(n);
}

/* [lvalue] -> [its old value]; d is added to the lvalue */
void postinc(int d)
{
    struct val t;
    int r, r2;
    v_dup();
    r = gv(vp);
    r2 = ralloc();
    e_i(OP_ADDI, ereg[r2], ereg[r], 0);
    vreg(vp->type, r2);
    vpush(VK_CONST, Y_INT, d);
    g_binop('+');
    g_cast(vp[-2].type);
    t = vp[-1]; vp[-1] = vp[-2]; vp[-2] = t;
    g_store();
    vpop();
}

void postfix_ops(void)
{
    int m;
    for (;;) {
        switch (tok) {
        case '[':
            next(); rv();
            expr(); rv();
            g_binop('+');
            skip(']');
            v_deref();
            break;
        case '(':
            call();
            break;
        case T_ARROW:
            rv();
            v_deref();
        case '.':
            next();
            if (tok != T_ID || !is_agg(vp->type)) errtok("not a structure member: ");
            m = mem_find(vp->type, tk_val);
            if (!m) errtok("not a structure member: ");
            if (!is_lv(vp)) err("not an lvalue", 0);
            vp->val = vp->val + mem_off;
            vp->type = sy[m].type;
            vp->bw = sy[m].aux >> 8;
            vp->boff = sy[m].aux & 255;
            next();
            break;
        case T_INC: case T_DEC:
            postinc(tok == T_INC ? 1 : -1);
            next();
            break;
        default:
            return;
        }
    }
}

void sizeof_x(void)
{
    int t;
    struct dead d;
    if (tok == '(') {
        next();
        if (is_type()) { t = type_name(); skip(')'); }
        else {
            dead_on(&d);
            expr(); skip(')'); postfix_ops();
            t = vp->type;
            vpop();
            dead_off(&d);
        }
    } else {
        dead_on(&d);
        unary();
        t = vp->type;
        vpop();
        dead_off(&d);
    }
    if (is_vm(t)) vpush(VK_LOC, Y_ULONG, ty[t].aux);
    else vpush(VK_CONST, Y_ULONG, ty[t].size);
}

void unary(void)
{
    int op = tok, t;
    stk_check();
    switch (op) {
    case '-': case '~': case '!': case '+':
        next(); unary(); rv();
        g_unop(op);
        return;
    case '*':
        next(); unary(); rv();
        v_deref();
        return;
    case '&':
        next(); unary();
        t = vp->type;
        v_addr(vp);
        vp->type = ty_ptr(t);
        return;
    case T_INC: case T_DEC:
        next(); unary();
        v_dup();
        vpush(VK_CONST, Y_INT, 1);
        g_binop(op == T_INC ? '+' : '-');
        g_cast(vp[-1].type);
        g_store();
        return;
    case K_SIZEOF:
        next();
        sizeof_x();
        return;
    case '(':
        next();
        if (!is_type()) { expr(); skip(')'); postfix_ops(); return; }
        t = type_name();
        skip(')');
        if (tok == '{') { comp_lit(t); postfix_ops(); return; }
        unary(); rv();
        g_cast(t);
        return;
    }
    primary();
    postfix_ops();
}

int prec(int t)
{
    switch (t) {
    case '*': case '/': case '%': return 10;
    case '+': case '-': return 9;
    case T_SHL: case T_SHR: return 8;
    case '<': case '>': case T_LE: case T_GE: return 7;
    case T_EQ: case T_NE: return 6;
    case '&': return 5;
    case '^': return 4;
    case '|': return 3;
    case T_LAND: return 2;
    case T_LOR: return 1;
    }
    return 0;
}

void binary(int p);

/* [a] && ... or [a] || ...: the operator has been read */
void logical(int op, int q)
{
    int want = op == T_LOR, c;
    long t = 0;
    struct dead d;
    rv();
    if (vp->kind == VK_CONST) {         /* decided, or decided by the rest, at compile time */
        c = vp->sym || vp->val != 0;
        vp--;
        if (c == want) {
            dead_on(&d);
            binary(q + 1);
            vpop();
            dead_off(&d);
            vpush(VK_CONST, Y_INT, want);
        } else {
            binary(q + 1);
            rv();
            to_bool(Y_INT);
        }
        return;
    }
    g_spill(vp - 1);
    for (;;) {
        t = jmp_if(want, t);
        binary(q + 1);
        rv();
        if (tok != op) break;
        next();
    }
    t = jmp_if(want, t);
    vpush(VK_JMP, Y_INT, t)->flags = want ? 0 : VF_INV;
}

/* [a] and the binary operators of precedence p or more that follow it */
void bin_rest(int p)
{
    int op, q;
    for (;;) {
        op = tok;
        q = prec(op);
        if (!q || q < p) return;
        next();
        if (q <= 2) { logical(op, q); continue; }
        rv();
        binary(q + 1);
        rv();
        g_binop(op);
    }
}

void binary(int p)
{
    unary();
    bin_rest(p);
}

/* the value on top into register r (free, or its own) */
void g_toreg(int r)
{
    int c = gv(vp);
    if (c == r) return;
    e_i(OP_ADDI, ereg[r], ereg[c], 0);
    rfree(c);
    rmask = rmask | 1 << r;
    vp->reg = r;
}

void cond(void)
{
    long f, e, x;
    int r = -1, ta, tb, t, c, agg;
    struct val sv;
    struct dead d;
    binary(1);
    if (tok != '?') return;
    next();
    rv();
    if (vp->kind == VK_CONST) {         /* only one of the two is compiled */
        c = vp->sym || vp->val;
        vp--;
        if (!c) dead_on(&d);
        expr(); rv();
        ta = vp->type;
        if (!c) { vpop(); dead_off(&d); }
        skip(':');
        if (c) dead_on(&d);
        cond(); rv();
        tb = vp->type;
        if (c) { vpop(); dead_off(&d); }
        if ((is_int(ta) || is_fp(ta)) && (is_int(tb) || is_fp(tb))) g_cast(arith_type(ta, tb));
        return;
    }
    g_spill(vp - 1);
    f = jmp_if(0, 0);
    expr(); rv();
    ta = vp->type;
    agg = is_agg(ta);
    if (tk(ta) != TK_VOID) {
        if (agg) v_addr(vp);
        r = gv(vp);
    }
    vpop();
    e = g_jmp(0);
    skip(':');
    g_resolve(f, code_pc);
    cond(); rv();
    tb = vp->type;
    if (r < 0) {
        vpop();
        vpush(VK_CONST, Y_VOID, 0);
        g_resolve(e, code_pc);
        return;
    }
    t = ta;
    if (agg) v_addr(vp);
    else if (!is_ptr(ta) && !is_ptr(tb)) { t = arith_type(ta, tb); g_cast(t); }
    else if (!is_ptr(ta) || (is_ptr(tb) && tk(ty[ta].base) == TK_VOID)) t = tb;
    g_toreg(r);
    if (is_fp(t) && tk(ta) != tk(t)) {  /* the first value is converted on its own path */
        x = g_jmp(0);
        g_resolve(e, code_pc);
        e = 0;
        sv = *vp;
        vp--;
        vreg(ta, r);
        g_cast(t);
        g_toreg(r);
        vp--;
        vp++;
        *vp = sv;
        g_resolve(x, code_pc);
    }
    g_resolve(e, code_pc);
    if (agg) { vp->kind = VK_IND; vp->val = 0; }
    else if (is_int(t) && ty[t].size < 8 && is_uns(t) && !(is_uns(promote(ta)) && is_uns(promote(tb))))
        vp->flags = vp->flags | VF_DIRTY;
    vp->type = t;
}

char asg_ops[] = "+-*/%&|^";

void assign(void)
{
    int op;
    cond();
    if (tok == '=') {
        next();
        assign(); rv();
        g_cast(vp[-1].type);
        g_store();
    } else if (tok >= T_ASG && tok < T_ASG + 10) {
        op = tok - T_ASG;
        op = op < 8 ? asg_ops[op] : op == 8 ? T_SHL : T_SHR;
        next();
        v_dup();
        assign(); rv();
        g_binop(op);
        g_cast(vp[-1].type);
        g_store();
    }
}

void expr(void)
{
    assign();
    while (tok == ',') {
        vpop();
        next();
        assign();
    }
}

long const_expr(void)
{
    long v;
    struct dead d;
    dead_on(&d);
    cond();
    if (vp->kind != VK_CONST || vp->sym) err("constant expression expected", 0);
    v = vp->val;
    if (is_fp(vp->type)) { g_cast(Y_LONG); v = vp->val; }
    vp--;
    dead_off(&d);
    return v;
}

/* ================= declarations ================= */

int decl_spec(void);
int declarator(int t);

char kw_type[] = "10011000101110001111101101101111101";     /* the keywords that begin a declaration */

int is_type(void)
{
    if (tok == T_ID) return tk_sym && sy[tk_sym].cls == SC_TYPEDEF;
    return tok >= K_FIRST && tok <= K_BOOL && kw_type[tok - K_FIRST] == '1';
}

struct sb { long bit; int al, first, last, uni, size; };

/* a member of the structure being laid out; w >= 0: a bit-field of w bits.
   b->bit is the first free bit. A bit-field goes there unless it would then
   cross a boundary of its type's size: then it starts at that boundary. It
   is read and written through the unit of its type that holds it. */
void member_add(struct sb *b, int id, int mt, int w)
{
    int sz = ty[mt].size, a = ty[mt].align, m, off, u = sz * 8, bo = 0;
    long p = b->uni ? 0 : b->bit;
    if (w >= 0) {
        if (!is_int(mt) || w > u) err("bad bit-field", 0);
        if (!w || p / u != (p + w - 1) / u) p = (p + u - 1) / u * u;
        off = p / u * sz;
        bo = p % u;
        p = p + w;
        if (!id) a = 1;
    } else {
        if (!sz && tk(mt) != TK_ARRAY && !ty[mt].x) err("a member of incomplete type", 0);
        off = ((p + 7) / 8 + a - 1) & -a;
        p = (long)(off + sz) * 8;
    }
    if (!b->uni) b->bit = p;
    if ((p + 7) / 8 > b->size) b->size = (p + 7) / 8;
    if (a > b->al) b->al = a;
    if (w >= 0 && !id) return;          /* an unnamed bit-field only takes room */
    m = sym_new(id, SC_MEMBER, mt);
    sy[m].val = off;
    sy[m].aux = w > 0 ? bo | w << 8 : 0;
    if (b->last) sy[b->last].prev = m;
    else b->first = m;
    b->last = m;
}

/* the members of structure type t: tok is past the { */
void struct_body(int t)
{
    struct sb b;
    int bt, mt, w;
    b.bit = 0; b.al = 1; b.first = 0; b.last = 0; b.size = 0;
    b.uni = tk(t) == TK_UNION;
    while (tok != '}') {
        bt = decl_spec();
        if (bt < 0) errtok("syntax error near ");
        if (tok == ';') {               /* an unnamed structure member */
            if (is_agg(bt)) member_add(&b, 0, bt, -1);
            next();
            continue;
        }
        for (;;) {
            d_name = 0;
            mt = bt;
            w = -1;
            if (tok != ':') mt = declarator(bt);
            if (tok == ':') { next(); w = const_expr(); }
            member_add(&b, d_name, mt, w);
            if (tok != ',') break;
            next();
        }
        skip(';');
    }
    next();
    ty[t].size = (b.size + b.al - 1) & -b.al;
    ty[t].align = b.al;
    ty[t].aux = b.first;
    ty[t].x = 1;
}

/* struct or union: tok is the keyword */
int struct_spec(void)
{
    int kind = tok == K_STRUCT ? TK_STRUCT : TK_UNION, id = 0, s = 0, t;
    next();
    if (tok == T_ID) { id = tk_val; s = tk_tag; next(); }
    if (s && tk(sy[s].type) != kind) s = 0;
    if (!s || (tok == '{' && sy[s].aux != scope)) {
        t = ty_new(kind, 0, 1, 0);
        if (id) sym_decl(id, SC_TAG, t);
    } else t = sy[s].type;
    if (tok == '{') {
        if (ty[t].x) err("structure defined twice", 0);
        next();
        struct_body(t);
    }
    return t;
}

int enum_spec(void)
{
    long v = 0;
    int id;
    next();
    if (tok == T_ID) {
        if (!tk_tag) sym_decl(tk_val, SC_TAG, Y_INT);
        next();
    }
    if (tok != '{') return Y_INT;
    next();
    while (tok != '}') {
        if (tok != T_ID) errtok("syntax error near ");
        id = tk_val;
        next();
        if (tok == '=') { next(); v = const_expr(); }
        sy[sym_decl(id, SC_ENUM, Y_INT)].val = v++;
        if (tok != ',') break;
        next();
    }
    skip('}');
    return Y_INT;
}

/* declaration specifiers: -> the type, or -1 if there is none; ds_class is
   the storage class keyword, or 0 */
int decl_spec(void)
{
    int t = -1, sg = 0, sz = 0, base = 0, seen = 0, cls = 0;
    for (;;) {
        switch (tok) {
        case K_TYPEDEF: case K_EXTERN: case K_STATIC:
            cls = tok;
            break;
        case K_AUTO: case K_REGISTER: case K_CONST: case K_VOLATILE: case K_RESTRICT: case K_INLINE:
            break;
        case K_SIGNED: sg = 1; break;
        case K_UNSIGNED: sg = 2; break;
        case K_SHORT: sz = 1; break;
        case K_LONG: sz = 2; break;
        case K_VOID: case K_CHAR: case K_INT: case K_FLOAT: case K_DOUBLE: case K_BOOL:
            base = tok;
            break;
        case K_STRUCT: case K_UNION:
            t = struct_spec();
            seen = 1;
            continue;
        case K_ENUM:
            t = enum_spec();
            seen = 1;
            continue;
        case T_ID:
            if (t >= 0 || base || sg || sz || !tk_sym || sy[tk_sym].cls != SC_TYPEDEF) goto done;
            t = sy[tk_sym].type;
            break;
        default:
            goto done;
        }
        seen = 1;
        next();
    }
done:
    ds_class = cls;
    if (!seen) return -1;
    if (t >= 0) return t;
    switch (base) {
    case K_VOID: return Y_VOID;
    case K_BOOL: return Y_BOOL;
    case K_FLOAT: return Y_FLOAT;
    case K_DOUBLE: return Y_DOUBLE;
    case K_CHAR: return sg == 2 ? Y_UCHAR : Y_CHAR;
    }
    t = sz == 1 ? Y_SHORT : sz == 2 ? Y_LONG : Y_INT;
    return sg == 2 ? t + 1 : t;
}

/* the parameter list of a function type: tok is past the ( */
int func_params(int ret)
{
    int ids[16], ts[16], n = 0, t, bt, sd = d_name, sp = pn_set, i, f = 0, m0 = nsy;
    in_params++;
    if (tok == ')') f = TF_OLD;
    else if (tok == T_ID && !is_type()) {       /* an old-style list of names: int, until declared */
        f = TF_OLD;
        for (;;) {
            if (tok != T_ID || n >= 16) errtok("syntax error near ");
            ids[n] = tk_val;
            ts[n] = Y_INT;
            n++;
            next();
            if (tok != ',') break;
            next();
        }
    } else for (;;) {
        if (tok == T_ELL) { next(); f = TF_VARIADIC; break; }
        bt = decl_spec();
        if (bt < 0) errtok("syntax error near ");
        if (bt == Y_VOID && tok == ')') break;
        d_name = 0;
        pn_set = 0;
        t = declarator(bt);
        if (tk(t) == TK_ARRAY) t = ty_ptr(ty[t].base);
        else if (tk(t) == TK_FUNC) t = ty_ptr(t);
        if (n >= 16) err("too many parameters", 0);
        ids[n] = d_name;
        ts[n] = t;
        n++;
        if (tok != ',') break;
        next();
    }
    skip(')');
    in_params--;
    d_name = sd;
    pn_set = sp;
    for (i = m0; i < nsy; i++)          /* enumeration constants declared in the list end with it */
        if (sy[i].cls == SC_ENUM) { id_set(sy[i].id, 0, sy[i].prev); sy[i].cls = SC_MEMBER; }
    t = ty_new(TK_FUNC, n, 1, ret);
    ty[t].flags = f;
    ty[t].aux = npt;
    if (npt + n > NPT) err("too many types", 0);
    for (i = 0; i < n; i++) far_sw(A_PT + 4 * npt++, ts[i]);
    if (!pn_set) {
        pn_set = 1;
        for (i = 0; i < n; i++) lastpn[i] = ids[i];
    }
    return t;
}

/* the text [p0, p1) of the input, an array dimension, kept in the arena:
   -> its record (the length, the text) */
long dim_save(long p0, long p1)
{
    long a = mac_top;
    far_sd(a, p1 - p0);
    mac_top = (a + 8 + p1 - p0 + 7) & ~7;
    if (mac_top > A_MACEND - 2048) err("too many macros", 0);
    wb_open(a + 8);
    while (p0 < p1) wb_put(rb_get(p0++));
    wb_close();
    return a;
}

/* read the kept dimension a: as a trial (-> its value if it is a constant,
   else -1), or for real: its value stays on the stack */
long dim_eval(long a, int trial)
{
    int t = tok;
    long n = far_ld(a), r = -1;
    struct dead d;
    in_push(a + 8, a + 8 + n, 3, 0, 0);
    if (trial) { ce_soft = 1; ce_fail = 0; dead_on(&d); }
    next();
    expr();
    rv();
    if (!is_int(vp->type)) err("constant expression expected", 0);
    icast(vp, Y_LONG);
    if (trial) {
        if (vp->kind == VK_CONST && !vp->sym && !ce_fail) r = vp->val;
        vpop();
        dead_off(&d);
        ce_soft = 0;
    }
    if (tok) errtok("syntax error near ");
    in_pop();
    tok = t;
    return r;
}

/* the array types of a parameter that wait for the function's entry get their sizes */
void vm_inst(int t)
{
    int k = ty[t].kind, x = ty[t].x;
    if (k != TK_PTR && k != TK_ARRAY) return;
    vm_inst(ty[t].base);
    if (k != TK_ARRAY || x < 4) return;
    if (x == 4) dim_eval(ty[t].size, 0);
    else vpush(VK_CONST, Y_LONG, ty[t].size);
    vm_set(t);
}

/* [n] and (parameters) after a declarator's name */
int d_suffix(int t, int first)
{
    long n = 0, p0, sh, txt = 0;
    int d, vla = 0, pin = 0, sp0, e;
    if (tok == '(') { next(); return func_params(t); }
    if (tok != '[') return t;
    p0 = in_pos;
    sh = sf_shift;
    sp0 = in_sp;
    if (in_params && !in_sp && sf_pin < 0) { sf_pin = p0; pin = 1; }
    next();
    if (in_params) {                    /* the names in it are not declared yet: the text is kept */
        for (d = 0; tok && (d || tok != ']'); next()) {
            if (tok == '[') d++;
            if (tok == ']') d--;
        }
        if (!in_sp) p0 = p0 - (sf_shift - sh);
        if (!first && in_pos - 1 > p0) {        /* (a parameter's first dimension does not matter) */
            if (in_sp != sp0) err("an array dimension that a macro ends in", 0);
            txt = dim_save(p0, in_pos - 1);
            n = dim_eval(txt, 1);
            if (n >= 0) txt = 0;
            else n = 0;
        }
    } else if (tok != ']') {
        if (!fn_live) n = const_expr();
        else {                          /* in a function it may be a value */
            cond();
            rv();
            if (!is_int(vp->type)) err("constant expression expected", 0);
            icast(vp, Y_LONG);
            if (vp->kind == VK_CONST && !vp->sym) { n = vp->val; vp--; }
            else vla = 1;
        }
    }
    if (pin) sf_pin = -1;
    skip(']');
    t = d_suffix(t, 0);
    e = ty[t].kind == TK_ARRAY ? ty[t].x : 0;
    if (txt || e >= 4) {
        d = ty_new(TK_ARRAY, txt ? txt : n, ty[t].align, t);
        ty[d].x = txt ? 4 : 5;
        return d;
    }
    if (vla || e == 3) {
        if (!vla) vpush(VK_CONST, Y_LONG, n);
        return vm_arr(t);
    }
    return ty_arr(t, n);
}

/* a declarator on the type t: -> the declared type; d_name = the name, if any */
int declarator(int t)
{
    int ph, t2, i;
    while (tok == '*') {
        next();
        t = ty_ptr(t);
        while (tok == K_CONST || tok == K_VOLATILE || tok == K_RESTRICT) next();
    }
    if (tok == '(') {
        next();
        if (tok == ')' || is_type()) return func_params(t);
        ph = ty_new(TK_VOID, 0, 1, 0);  /* stands for what follows the parentheses */
        t2 = declarator(ph);
        skip(')');
        t = d_suffix(t, 0);
        if (t2 == ph) return t;
        ty[ph] = ty[t];
        for (i = ph + 1; i < nty; i++)
            if (ty[i].kind == TK_ARRAY && ty[i].x == 2 && ty[ty[i].base].size) {
                ty[i].size = ty[i].size * ty[ty[i].base].size;
                ty[i].align = ty[ty[i].base].align;
                ty[i].x = 0;
            }
        return t2;
    }
    if (tok == T_ID) { d_name = tk_val; next(); }
    return d_suffix(t, 1);
}

int type_name(void)
{
    int sd = d_name, sp = pn_set, t = decl_spec();
    if (t < 0) errtok("syntax error near ");
    t = declarator(t);
    d_name = sd;
    pn_set = sp;
    return t;
}

/* ================= initialisers ================= */

/* the character that follows the current token, blanks aside (0: the text
   at hand ends first) */
int peek_ch(void)
{
    long p;
    int c;
    if (in_sp == 0 && !sf_eof && in_end - in_pos < 64) src_fill();
    for (p = in_pos; p < in_end; p++) {
        c = rb_get(p);
        if (c != ' ' && c != 9) return c;
    }
    return 0;
}

void init_obj(int t, long off);

/* a comma between initialisers, read here or by an inner list */
int ini_more(void)
{
    if (ini_comma) { ini_comma = 0; return 1; }
    if (tok != ',') return 0;
    next();
    return 1;
}

/* one scalar (or a bit-field of w bits from bit b) at offset off */
void init_scalar(int t, long off, int w, int b)
{
    struct val *v;
    int braces = 0;
    long a = ini_base + off, m, u;
    if (!ini_pend) {
        while (tok == '{') { next(); braces++; }
        assign();
        rv();
        while (braces) { if (tok == ',') next(); skip('}'); braces--; }
    }
    ini_pend = 0;
    if (ini_dry) { vpop(); return; }
    g_cast(t);
    if (!ini_static) {
        v = vpush(VK_LOC, t, a);
        v->bw = w; v->boff = b;
        vswap();
        g_store();
        vpop();
        return;
    }
    v = vp;
    if (v->kind != VK_CONST) err("constant expression expected", 0);
    if (w) {
        m = ((1L << w) - 1) << b;
        for (u = 0, braces = ty[t].size; braces > 0; braces--) u = u << 8 | data_rb(a + braces - 1);
        data_put(a, (u & ~m) | (v->val << b & m), ty[t].size);
    } else {
        data_put(a, v->val, ty[t].size);
        if (v->sym) fix_add(a, v->sym, FK_DATA, v->val);
    }
    vp--;
}

/* a character array from the string in strbuf */
void init_str(int t, long off)
{
    int n = str_len + 1, sz = ty[t].size, i;
    long a;
    if (str_wide) {
        for (i = 0; i < 4; i++) strbuf[str_len + i] = 0;
        n = str_len + 4;
        if (!sz) { ini_cnt = n / 4; sz = n; }
    }
    if (!sz) { ini_cnt = n; sz = n; }
    if (ini_dry) return;
    if (ini_static) {
        for (i = 0; i < sz; i++) data_b(ini_base + off + i, i < n ? strbuf[i] : 0);
        return;
    }
    a = data_alloc(sz, 8);
    for (i = 0; i < sz; i++) data_b(a + i, i < n ? strbuf[i] : 0);
    vpush(VK_LOC, t, ini_base + off);
    vpush(VK_GLOB, t, a);
    g_copy();
    vpop();
}

/* the elements of an array or the members of a structure, with braces
   around them or (braced 0) as many as the object takes. A designator
   moves the position; when another follows it (ini_desig), the list of the
   designated element starts with that one, without braces. */
void init_list(int t, long off, int braced)
{
    int arr = tk(t) == TK_ARRAY, et = ty[t].base, m = ty[t].aux, uni = tk(t) == TK_UNION, mt;
    long i = 0, n = -1, esz = 0, top = 0;
    if (arr) {
        esz = ty[et].size;
        if (ty[t].size && esz) n = ty[t].size / esz;
    }
    for (;;) {
        if (tok == '}' && !ini_pend) break;
        if (!ini_pend && (tok == '[' || tok == '.' || ini_desig == 2)) {
            if (!braced && !ini_desig) { ini_comma = 1; break; }
            if (ini_desig != 2) {
                if (arr != (tok == '[')) err("bad designator", 0);
                next();
            }
            ini_desig = 0;
            if (arr) {
                i = const_expr();
                skip(']');
            } else {
                if (tok != T_ID) errtok("not a structure member: ");
                for (m = ty[t].aux; m; m = sy[m].prev) {
                    if (sy[m].id == tk_val) break;
                    if (!sy[m].id && is_agg(sy[m].type) && mem_find(sy[m].type, tk_val)) break;
                }
                if (!m) errtok("not a structure member: ");
                if (sy[m].id) next();
                else ini_desig = 2;             /* in an unnamed member: its list takes the name */
                if (uni && !ini_dry) {          /* another member of a union: the others are gone */
                    if (ini_static) for (i = 0; i < ty[t].size; i++) data_b(ini_base + off + i, 0);
                    else { vpush(VK_LOC, t, ini_base + off); g_clear(ty[t].size); vp--; }
                    i = 0;
                }
            }
            if (ini_desig) ;
            else if (tok == '[' || tok == '.') ini_desig = 1;
            else skip('=');
        }
        if (arr ? (n >= 0 && i >= n) || i < 0 : !m) {
            if (braced) err("too many initialisers", 0);
            break;
        }
        if (arr) { init_obj(et, off + i * esz); i++; }
        else {
            mt = sy[m].type;
            if (sy[m].aux) init_scalar(mt, off + sy[m].val, sy[m].aux >> 8, sy[m].aux & 255);
            else init_obj(mt, off + sy[m].val);
            m = uni ? 0 : sy[m].prev;
        }
        if (i > top) top = i;
        if (!braced && (arr ? n >= 0 && i >= n : !m)) break;
        if (!ini_more()) break;
    }
    if (arr && n < 0) ini_cnt = top;
}

/* the initialiser of the object of type t at offset off of what is being
   initialised (ini_base: an address of the data, or a frame offset) */
void init_obj(int t, long off)
{
    int k = tk(t), br = 0, par = 0, pre = 0;
    long i;
    if (k != TK_ARRAY && !is_agg(t)) {
        if (ini_desig) err("bad designator", 0);
        init_scalar(t, off, 0, 0);
        return;
    }
    if (ini_desig) { init_list(t, off, 0); return; }
    if (!ini_pend && tok == '{') { next(); br = 1; }
    if (k == TK_ARRAY && !ini_pend && is_int(ty[t].base)) {    /* a string, or an expression that begins like one */
        while (tok == '(' && (peek_ch() == '"' || peek_ch() == '(')) { next(); par++; }
        if (tok == T_STR) {
            str_take();
            if (ty[ty[t].base].size == (str_wide ? 4 : 1) && (tok == ',' || tok == '}' || tok == ';' || tok == ')')) {
                init_str(t, off);
                for (; par; par--) skip(')');
                if (br) { if (tok == ',') next(); skip('}'); }
                return;
            }
            str_push();
            postfix_ops();
            bin_rest(1);
            pre = 1;
        } else if (par) { expr(); pre = 1; }
        if (pre) {
            if (par) {
                for (; par; par--) skip(')');
                postfix_ops();
                bin_rest(1);
            }
            rv();
            ini_pend = 1;
        }
    }
    if (br) {
        if (ini_static && !ini_dry) for (i = 0; i < ty[t].size; i++) data_b(ini_base + off + i, 0);
        init_list(t, off, 1);
        skip('}');
        ini_comma = 0;
        return;
    }
    if (is_agg(t) && !ini_static && !ini_pend && tok != T_STR) {
        assign();
        if (!is_agg(vp->type)) rv();
        ini_pend = 1;
    }
    if (ini_pend && vp->type == t) {    /* a whole structure */
        ini_pend = 0;
        if (ini_dry) { vpop(); return; }
        vpush(VK_LOC, t, ini_base + off);
        vswap();
        g_copy();
        vpop();
        return;
    }
    init_list(t, off, 0);
}

/* tok is the = or { before the initialiser of an object of type t: an
   array of unknown length gets its length from a first reading */
int fix_len(int t)
{
    long d = data_pc, f = fix_top;
    int fc = fr_cur;
    struct dead dd;
    if (tk(t) != TK_ARRAY || ty[t].size || ini_dry) return t;
    scan_mark();
    if (tok == '=') next();
    ini_dry = 1;
    dead_on(&dd);
    ini_cnt = 0; ini_pend = 0; ini_comma = 0;
    init_obj(t, 0);
    dead_off(&dd);
    ini_dry = 0;
    data_pc = d; fix_top = f; fr_cur = fc;
    scan_rewind();
    return ty_arr(ty[t].base, ini_cnt);
}

void static_init(int t, long a)
{
    struct dead d;
    ini_static = 1; ini_base = a; ini_pend = 0; ini_comma = 0;
    dead_on(&d);
    init_obj(t, 0);
    dead_off(&d);
}

void auto_init(int t, int off)
{
    ini_static = 0; ini_base = off; ini_pend = 0; ini_comma = 0;
    if ((tk(t) == TK_ARRAY || is_agg(t)) && tok == '{') {
        vpush(VK_LOC, t, off);
        g_clear(ty[t].size);
        vp--;
    }
    init_obj(t, 0);
}

/* (type){ ... }: tok is the { */
void comp_lit(int t)
{
    int s = ini_static, p = ini_pend, c = ini_comma, o;
    long b = ini_base, a;
    ini_static = nocode != 0;
    t = fix_len(t);
    if (nocode) {
        a = data_alloc(ty[t].size, ty[t].align);
        static_init(t, a);
        vpush(VK_GLOB, t, a);
    } else {
        o = fr_alloc(ty[t].size, ty[t].align);
        fr_keep = fr_cur;
        auto_init(t, o);
        vpush(VK_LOC, t, o);
    }
    ini_static = s; ini_pend = p; ini_comma = c; ini_base = b;
}

/* an object with static storage: at file scope, or static in a block */
void static_var(int id, int t, int cls)
{
    int s = id_sym(id), init = tok == '=';
    struct sym *p;
    if (!s || sy[s].cls != SC_STATIC || sy[s].aux != scope) {
        s = sym_decl(id, SC_STATIC, t);
        sy[s].flags = SF_EXT;
    }
    p = &sy[s];
    if (init) { ini_static = 1; t = fix_len(t); next(); }
    if (ty[t].size || !ty[p->type].size) p->type = t;
    if ((init || cls != K_EXTERN) && !(p->flags & SF_DEF) && ty[t].size) {
        p->val = data_alloc(ty[t].size, ty[t].align);
        p->flags = SF_DEF;
    }
    if (init) {
        if (!(p->flags & SF_DEF)) err("initialiser for an incomplete type", 0);
        static_init(t, p->val);
    }
}

/* a function's name declared with type t -> its symbol */
int func_decl(int id, int t)
{
    int s = id_sym(id);
    if (s && sy[s].cls == SC_FUNC && sy[s].aux == scope) {
        if (ty[sy[s].type].flags & TF_OLD) sy[s].type = t;
        return s;
    }
    return sym_decl(id, SC_FUNC, t);
}

/* a declaration in a block */
void local_decl(void)
{
    int bt = decl_spec(), cls = ds_class, t, id, s;
    if (tok == ';') { next(); return; }
    for (;;) {
        d_name = 0;
        pn_set = 0;
        t = declarator(bt);
        id = d_name;
        if (!id) errtok("syntax error near ");
        if (cls == K_TYPEDEF) sym_decl(id, SC_TYPEDEF, t);
        else if (tk(t) == TK_FUNC) func_decl(id, t);
        else if (cls == K_EXTERN) {
            s = id_sym(id);
            if (!s || sy[s].cls != SC_STATIC) sy[sym_decl(id, SC_STATIC, t)].flags = SF_EXT;
        } else if (cls == K_STATIC) static_var(id, t, cls);
        else {
            s = sym_decl(id, SC_AUTO, t);
            if (is_vm(t)) vla_new(s);
            else if (tok == '=') {
                ini_static = 0;
                t = fix_len(t);
                next();
                sy[s].type = t;
                sy[s].val = fr_alloc(ty[t].size, ty[t].align);
                auto_init(t, sy[s].val);
            } else {
                if (!ty[t].size) err("an object of incomplete type: ", id_name(id));
                sy[s].val = fr_alloc(ty[t].size, ty[t].align);
            }
        }
        if (tok != ',') break;
        next();
    }
    skip(';');
}

/* ================= asm("...") ================= */

/* Strata assembly as `as` reads it, one instruction a line (a ; starts a
   comment), encoded in place with the table asm.tab of cc.lib, which
   lib/mkasm.py makes from the assembler. In a function, a label is a label
   of the function, and {name} is a C object: as a memory operand, as the
   address la loads, or, for an enumeration constant, as a number; call
   {name} calls a C function. t0-t6, tp and a0-a7 are free between two
   statements; the other registers must be left as they were. At file scope
   the labels are functions, called from C once declared there. */
int lab_find(int id);
char *ap;                       /* the text being read */
long ab[4];                     /* an instruction's record */
long as_tab;
int as_n;
char as_abi[] = "zero ra   sp   gp   tp   t0   t1   t2   s0   s1   a0   a1   a2   a3   a4   a5   "
                "a6   a7   s2   s3   s4   s5   s6   s7   s8   s9   s10  s11  t3   t4   t5   t6   ";

void as_err(char *m)
{
    char *e = ap;
    while (*e && *e != 10) e++;
    *e = 0;
    err(m, ap);
}

void as_blank(void) { while (*ap == ' ' || *ap == 9) ap++; }

/* the name at ap -> tb; its length */
int as_word(void)
{
    int n = 0;
    as_blank();
    while (*ap > 0 && (isid(*ap) || *ap == '.')) {
        if (n < 30) tb[n++] = *ap;
        ap++;
    }
    tb[n] = 0;
    return n;
}

void as_comma(void)
{
    as_blank();
    if (*ap != ',') as_err("asm: a comma expected: ");
    ap++;
}

/* a register of kind x, c or g (transfer tag) */
int as_reg(int kind)
{
    char *s = tb, *a;
    int i, n = -1, j;
    if (!as_word()) as_err("asm: a register expected: ");
    if (kind == 'x')
        for (i = 0; i < 32 && n < 0; i++) {
            a = as_abi + 5 * i;
            for (j = 0; s[j] && s[j] == a[j]; j++) ;
            if (!s[j] && a[j] == ' ') n = i;
        }
    if (n < 0) {
        if (*s != (kind == 'g' ? 't' : kind)) err("asm: not a register: ", tb);
        s = s + 1 + (kind == 'g');
        if (kind == 'g' && s[-1] != 'g') err("asm: not a register: ", tb);
        for (n = 0; isdig(*s); s++) n = n * 10 + *s - '0';
        if (*s || s[-1] == tb[0] || n > (kind == 'x' ? 31 : 15)) err("asm: not a register: ", tb);
    }
    return n;
}

/* {name}: the C symbol */
int as_sym(void)
{
    ap++;
    intern(tb, as_word());
    as_blank();
    if (*ap != '}' || !IDR->sym) err("asm: not declared: ", tb);
    ap++;
    return IDR->sym;
}

/* a number: decimal, 0x..., 'c', or {an enumeration constant} */
long as_num(void)
{
    long v = 0;
    int neg = 0, s, d;
    as_blank();
    if (*ap == '-') { neg = 1; ap++; }
    if (*ap == '{') {
        s = as_sym();
        if (sy[s].cls != SC_ENUM) err("asm: not a constant: ", tb);
        v = sy[s].val;
    } else if (*ap == 39) { v = ap[1]; ap = ap + 3; }
    else if (!isdig(*ap)) as_err("asm: a number expected: ");
    else if (ap[0] == '0' && (ap[1] | 32) == 'x')
        for (ap = ap + 2;; ap++) {
            d = *ap | 32;
            if (isdig(d)) d = d - '0';
            else if (d >= 'a' && d <= 'f') d = d - 'a' + 10;
            else break;
            v = v << 4 | d;
        }
    else for (; isdig(*ap); ap++) v = v * 10 + *ap - '0';
    return neg ? -v : v;
}

/* the label at ap, as a jump of the word w: its distance, or a link of its chain */
int as_target(int w, int mask)
{
    int i;
    if (!as_word()) as_err("asm: a label expected: ");
    i = lab_find(intern(tb, slen(tb)));
    if (lb_adr[i]) return w | ((lb_adr[i] - code_pc) >> 2 & mask);
    w = w | lk(code_pc, lb_chain[i]);
    lb_chain[i] = code_pc;
    return w;
}

/* li, la, call and (paged) ret are not in the table: -> 1 if tb was one of them */
int as_special(void)
{
    int r, s;
    if (streq(tb, "li")) {
        r = as_reg('x');
        as_comma();
        g_li(r, as_num());
        return 1;
    }
    if (streq(tb, "la") || streq(tb, "call")) {
        r = tb[0] == 'l' ? as_reg('x') : -1;
        if (r >= 0) as_comma();
        as_blank();
        if (*ap != '{') {
            if (r >= 0) as_err("asm: la takes a {name}: ");
            emit(as_target(OP_JAL << 26 | X_RA << 21, 0x1fffff));
            return 1;
        }
        s = as_sym();
        v_sym(s);
        if (r < 0) {
            if (tk(vp->type) != TK_FUNC) err("asm: not a function: ", tb);
            g_calljmp(vp, 1);
            vp--;
            return 1;
        }
        v_addr(vp);
        g_into(vp, r);
        vp--;
        return 1;
    }
    if (paged && streq(tb, "ret")) { e_i(OP_XCALL, 0, X_RA, 16); return 1; }
    return 0;
}

/* the operands of the instruction in ab, and the instruction */
void as_insn(void)
{
    char *o = (char *)ab + 16;
    int w = ((int *)ab)[3], k, kind, sh, r;
    long v;
    for (k = 0; k < 5 && o[2 * k]; k++) {
        kind = o[2 * k];
        sh = o[2 * k + 1];
        if (k) as_comma();
        switch (kind) {
        case 'x': case 'c': case 'g':
            w = w | as_reg(kind) << sh;
            break;
        case 'i':
            w = w | (as_num() & 0xffff) << sh;
            break;
        case 'k':
            w = w | (as_num() & 63) << sh;
            break;
        case 'b':
            w = as_target(w, 0xffff);
            break;
        case 'j':
            w = as_target(w, 0x1fffff);
            break;
        case 'M':
            for (;;) {
                w = w | 1 << as_reg('g');
                as_blank();
                if (*ap != ',') break;
                ap++;
            }
            break;
        case 'm':
            as_blank();
            if (*ap == '{') {           /* a C object, wherever it is */
                v_sym(as_sym());
                if (vp->kind != VK_LOC && vp->kind != VK_GLOB) err("asm: not an object in memory: ", tb);
                g_mem(w >> 26 & 63, w >> 21 & 31, vp);
                vp--;
                return;
            }
            v = *ap == '(' ? 0 : as_num();
            as_blank();
            if (*ap != '(') as_err("asm: offset(register) expected: ");
            ap++;
            r = as_reg('x');
            as_blank();
            if (*ap != ')' || !fits(v)) as_err("asm: offset(register) expected: ");
            ap++;
            w = w | r << 16 | (v & 0xffff);
            break;
        }
    }
    emit(w);
}

/* one line of the text: labels, then an instruction */
void as_line(void)
{
    int i;
    for (;;) {
        as_blank();
        if (!*ap || *ap == 10 || *ap == ';') return;
        if (!as_word()) as_err("asm: syntax error near ");
        as_blank();
        if (*ap != ':') break;
        ap++;
        i = lab_find(intern(tb, slen(tb)));
        if (lb_adr[i]) err("asm: label defined twice: ", tb);
        lb_adr[i] = here();
        g_resolve(lb_chain[i], code_pc);
        lb_chain[i] = 0;
    }
    if (as_special()) return;
    for (i = 0; i < as_n; i++) {
        far_read(as_tab + 32 * i, ab, 32);
        if (streq((char *)ab, tb)) { as_insn(); return; }
    }
    err("asm: unknown instruction: ", tb);
}

void g_fn_place(void);

/* asm ( "text" ) ; -- tok is the word asm */
void asm_block(void)
{
    int top = !fn_live, i, s;
    long d;
    next();
    skip('(');
    if (tok != T_STR) errtok("syntax error near ");
    str_take();
    skip(')');
    skip(';');
    if (!as_tab) {
        as_tab = lib_find("asm.tab");
        if (!as_tab) err("cc.lib has no asm.tab", 0);
        as_n = lib_sz / 32;
    }
    if (top) {                          /* at file scope: a piece of code of its own */
        nocode = 0;
        nlabels = 0;
        sp_bias = 0;
        if (paged && (code_pc & 4)) emit(0);
        fn_start = code_pc;
        fn_fix0 = fix_top;
        fn_sym = 0;
    }
    strbuf[str_len] = 0;
    for (ap = strbuf;; ap++) {
        as_line();
        as_blank();
        if (*ap == ';') while (*ap && *ap != 10) ap++;
        if (!*ap) break;
        if (*ap != 10) as_err("asm: syntax error near ");
    }
    if (!top) return;
    d = fn_start;
    if (paged) g_fn_place();
    d = fn_start - d;
    for (i = 0; i < nlabels; i++) {     /* its labels are functions */
        if (!lb_adr[i]) err("undefined label: ", id_name(lb_id[i]));
        s = id_sym(lb_id[i]);
        if (!s || sy[s].cls != SC_FUNC) s = sym_decl(lb_id[i], SC_FUNC, Y_FUNC0);
        sy[s].val = lb_adr[i] + d;
        sy[s].flags = sy[s].flags | SF_DEF;
    }
    nlabels = 0;
    nocode = 1;
}

/* ================= statements ================= */

void stmt(void);

/* tok is { */
void block(void)
{
    int m = nsy, f = fr_cur, k = fr_keep;
    next();
    scope++;
    while (tok != '}') {
        if (!tok) err("unexpected end of file", 0);
        if (is_type()) local_decl();
        else stmt();
    }
    next();
    scope--;
    if (fn_vla) vla_free(m);
    scope_exit(m);
    fr_cur = f;
    fr_keep = k;
}

void loop_stmt(void)
{
    long sb = brk_chain, sc = cnt_chain, st = cnt_target, top, a;
    int m = nsy, k = tok, bn = brk_nsy, cn = cnt_nsy;
    brk_nsy = nsy;
    cnt_nsy = nsy;
    brk_chain = 0;
    cnt_chain = 0;
    loop_depth++;
    next();
    if (k == K_WHILE) {
        top = here();
        cnt_target = top;
        skip('('); expr(); rv(); skip(')');
        brk_chain = jmp_if(0, 0);
        stmt();
        g_jmp_to(top);
    } else if (k == K_DO) {
        top = here();
        cnt_target = 0;
        stmt();
        if (tok != K_WHILE) errtok("syntax error near ");
        next();
        g_resolve(cnt_chain, code_pc);
        skip('('); expr(); rv(); skip(')'); skip(';');
        g_resolve(jmp_if(1, 0), top);
    } else {
        skip('(');
        scope++;
        if (is_type()) local_decl();
        else {
            if (tok != ';') { expr(); vpop(); }
            skip(';');
        }
        cnt_nsy = nsy;
        top = here();
        if (tok != ';') { expr(); rv(); brk_chain = jmp_if(0, 0); }
        skip(';');
        cnt_target = top;
        if (tok != ')') {               /* the step is compiled before the body, and jumped over */
            a = g_jmp(0);
            cnt_target = here();
            expr();
            vpop();
            g_jmp_to(top);
            g_resolve(a, code_pc);
        }
        skip(')');
        stmt();
        g_jmp_to(cnt_target);
        scope--;
        if (fn_vla) vla_free(m);
        scope_exit(m);
    }
    g_resolve(brk_chain, code_pc);
    brk_chain = sb; cnt_chain = sc; cnt_target = st;
    brk_nsy = bn; cnt_nsy = cn;
    loop_depth--;
}

/* switch: the value waits in the frame; the comparisons come after the body */
void sw_stmt(void)
{
    long sb = brk_chain, sd = cs_default, disp, v, a;
    int b0 = cs_base, slot, i, r, x, bn = brk_nsy;
    brk_nsy = nsy;
    next();
    skip('('); expr(); rv(); skip(')');
    if (!is_int(vp->type)) err("invalid operands", 0);
    icast(vp, promote(vp->type));
    r = gv(vp);
    slot = fr_alloc(8, 8);
    e_i(OP_SD, ereg[r], X_SP, slot);
    vpop();
    disp = g_jmp(0);
    cs_base = cs_top;
    cs_default = 0;
    brk_chain = 0;
    loop_depth++;
    stmt();
    brk_chain = g_jmp(brk_chain);
    g_resolve(disp, code_pc);
    r = ralloc();
    x = ereg[r];
    e_i(OP_LD, x, X_SP, slot);
    for (i = cs_base; i < cs_top; i++) {
        v = far_ld(A_CS + 16 * i);
        a = far_ld(A_CS + 16 * i + 8);
        if (v) g_li(X_TP, v);
        emit(enc(OP_BEQ, x, v ? X_TP : 0, (a - code_pc) >> 2));
    }
    rfree(r);
    if (cs_default) g_jmp_to(cs_default);
    g_resolve(brk_chain, code_pc);
    cs_top = cs_base;
    cs_base = b0; cs_default = sd; brk_chain = sb;
    brk_nsy = bn;
    loop_depth--;
}

int lab_find(int id)
{
    int i;
    for (i = 0; i < nlabels; i++) if (lb_id[i] == id) return i;
    if (nlabels >= 32) err("too many labels", 0);
    lb_id[i] = id; lb_adr[i] = 0; lb_chain[i] = 0;
    return nlabels++;
}

void ret_stmt(void)
{
    struct val *v;
    int have = 0;
    next();
    if (tok != ';') {
        expr();
        rv();
        if (is_agg(fn_ret)) {
            v = vpush(VK_SAVED, fn_ret, 0);
            v->slot = fn_sret;
            vswap();
            g_copy();
            vpop();
        } else if (tk(fn_ret) == TK_VOID) vpop();
        else {
            g_cast(fn_ret);
            have = 1;
        }
    }
    skip(';');
    if (fn_vla) {
        if (have) gv(vp);
        vla_free(fn_nsy0);
    }
    if (have) {
        g_into(vp, X_A0);
        vp--;
    }
    fn_rchain = g_jmp(fn_rchain);
}

void stmt(void)
{
    int f = fr_cur, i;
    long a, b;
    stk_check();
    switch (tok) {
    case '{':
        block();
        return;
    case ';':
        next();
        return;
    case K_IF:
        next();
        skip('('); expr(); rv(); skip(')');
        a = jmp_if(0, 0);
        stmt();
        if (tok == K_ELSE) {
            next();
            b = g_jmp(0);
            g_resolve(a, code_pc);
            stmt();
            a = b;
        }
        g_resolve(a, code_pc);
        break;
    case K_WHILE: case K_DO: case K_FOR:
        loop_stmt();
        break;
    case K_SWITCH:
        sw_stmt();
        break;
    case K_RETURN:
        ret_stmt();
        break;
    case K_BREAK:
        if (!loop_depth) err("break outside a loop or switch", 0);
        next();
        skip(';');
        if (fn_vla) vla_free(brk_nsy);
        brk_chain = g_jmp(brk_chain);
        break;
    case K_CONTINUE:
        next();
        skip(';');
        if (fn_vla) vla_free(cnt_nsy);
        if (cnt_target) g_jmp_to(cnt_target);
        else cnt_chain = g_jmp(cnt_chain);
        break;
    case K_CASE:
        next();
        a = const_expr();
        skip(':');
        if (cs_top >= 256) err("too many cases", 0);
        far_sd(A_CS + 16 * cs_top, a);
        far_sd(A_CS + 16 * cs_top + 8, here());
        cs_top++;
        if (tok != '}' && !is_type()) stmt();
        return;
    case K_DEFAULT:
        next();
        skip(':');
        cs_default = here();
        if (tok != '}' && !is_type()) stmt();
        return;
    case K_GOTO:
        next();
        if (tok != T_ID) errtok("syntax error near ");
        i = lab_find(tk_val);
        next();
        skip(';');
        if (lb_adr[i]) g_jmp_to(lb_adr[i]);
        else lb_chain[i] = g_jmp(lb_chain[i]);
        break;
    case T_ID:
        if ((tk_val == id_asm || tk_val == id_asm2) && !tk_sym && peek_ch() == '(') {
            asm_block();
            break;
        }
        if (peek_ch() == ':') {
            i = lab_find(tk_val);
            next();
            next();
            lb_adr[i] = here();
            g_resolve(lb_chain[i], code_pc);
            lb_chain[i] = 0;
            if (tok != '}' && !is_type()) stmt();
            return;
        }
    default:
        expr();
        vpop();
        skip(';');
    }
    fr_cur = f > fr_keep ? f : fr_keep;
}

/* ================= functions ================= */

void g_fn_begin(void)
{
    int i;
    nocode = 0;
    fr_cur = 0; fr_max = 0; fr_keep = 0; fn_rchain = 0; rmask = 0; sp_bias = 0;
    vp = vs;
    if (paged && (code_pc & 4)) emit(0);        /* a function starts on a word */
    fn_start = code_pc;
    fn_fix0 = fix_top;
    if (fn_s0) {                        /* all the arguments in a row: 8 i (s0) */
        e_i(OP_ADDI, X_SP, X_SP, -80);
        e_i(OP_SD, X_S0, X_SP, 0);
        for (i = 0; i < 8; i++) e_i(OP_SD, X_A0 + i, X_SP, 16 + 8 * i);
        e_i(OP_ADDI, X_S0, X_SP, 16);
    }
    fn_pro = code_pc;
    emit(0);                            /* addi sp, sp, -F and sd ra, F-8(sp), once F is known */
    emit(0);
}

/* paged model: a function that crosses a 4 KiB unit boundary moves to the
   start of the next unit; the fixups made inside it move with it */
void g_fn_place(void)
{
    long s = fn_start, e = code_pc, d, n, p, a;
    int r;
    if ((e - 4) >> 12 == s >> 12) return;
    n = e - s;
    if (n > 4096) err("function too large for a code unit: ", fn_sym ? id_name(sy[fn_sym].id) : "asm");
    cw_flush();
    n = (n + 7) & ~7;
    for (p = 0; p < n; p = p + 1024) {
        r = n - p > 1024 ? 1024 : n - p;
        far_read(A_CODE + s - code_org + p, iob, r);
        far_write(A_TMP + p, iob, r);
    }
    d = (((s >> 12) + 1) << 12) - s;
    cw_seek(s);
    for (p = 0; p < d; p = p + 4) emit(0);
    for (p = 0; p < e - s; p = p + 4) emit(far_lw(A_TMP + p));
    for (a = fn_fix0; a < fix_top; a = a + 16) {
        p = far_lw(a);
        if (p >= s && p < e) far_sw(a, p + d);
    }
    fn_start = s + d;
}

void g_fn_end(void)
{
    long c = fn_rchain;
    int f;
    if (c && c == code_pc - 4 && lab_pc < code_pc && c >= cw_base) {
        fn_rchain = g_next(c, code_rd(c));      /* a return at the very end needs no jump */
        code_pc = c;
    }
    g_resolve(fn_rchain, code_pc);
    f = (fr_max + 15) & ~7;
    if (f > 32600) err("the function's frame is too large", 0);
    e_i(OP_LD, X_RA, X_SP, f - 8);
    if (fn_s0) {
        e_i(OP_LD, X_S0, X_SP, f);
        e_i(OP_ADDI, X_SP, X_SP, f + 80);
    } else e_i(OP_ADDI, X_SP, X_SP, f);
    if (paged) e_i(OP_XCALL, 0, X_RA, 16);
    else e_i(OP_JALR, 0, X_RA, 0);
    code_wr(fn_pro, enc(OP_ADDI, X_SP, X_SP, -f));
    code_wr(fn_pro + 4, enc(OP_SD, X_RA, X_SP, f - 8));
    if (paged) g_fn_place();
    nocode = 1;
    vlive = vs;
}

/* the definition of function s of type t: tok is { */
void func_def(int s, int t)
{
    int np = ty[t].size, m = nsy, n0 = nty, p0 = npt, ids[16], i, k, pt, ps, off, slot;
    struct sym *p;
    if (sy[s].flags & SF_DEF) err("defined twice: ", id_name(sy[s].id));
    for (i = 0; i < np; i++) ids[i] = lastpn[i];
    sy[s].type = t;
    fn_sym = s;
    fn_ret = ty[t].base;
    k = is_agg(fn_ret);
    fn_s0 = (ty[t].flags & TF_VARIADIC) || np + k > 8;
    fn_va = 8 * (np + k);
    nlabels = 0;
    scope = 1;
    fn_vla = 0;
    fn_nsy0 = nsy;
    g_fn_begin();
    fn_live = 1;
    for (i = 0; i < np + k; i++) {
        if (fn_s0) off = 8 * i;
        else {
            off = fr_alloc(8, 8);
            e_i(OP_SD, X_A0 + i, X_SP, off);
        }
        pt = k && !i ? Y_VOIDP : pt_get(ty[t].aux + i - k);
        if (fn_s0 && (is_agg(pt) || (k && !i))) {       /* an address: kept where sp finds it */
            slot = fr_alloc(8, 8);
            e_i(OP_LD, X_T6, X_S0, off);
            e_i(OP_SD, X_T6, X_SP, slot);
            off = slot;
        }
        if (k && !i) { fn_sret = off; continue; }
        if (!ids[i - k]) continue;
        ps = sym_decl(ids[i - k], SC_AUTO, pt);
        p = &sy[ps];
        p->val = off;
        if (is_agg(pt)) p->flags = SF_REF;
        else if (fn_s0) p->flags = SF_S0;
    }
    for (i = 0; i < np; i++) vm_inst(pt_get(ty[t].aux + i));
    block();
    fn_live = 0;
    for (i = 0; i < nlabels; i++) if (!lb_adr[i]) err("undefined label: ", id_name(lb_id[i]));
    if (sy[s].id == id_main) e_i(OP_ADDI, X_A0, 0, 0);
    g_fn_end();
    scope = 0;
    scope_exit(m);
    sy[s].val = fn_start;
    sy[s].flags = sy[s].flags | SF_DEF;
    for (i = 0; i < n0; i++) if (ptrof[i] >= n0) ptrof[i] = 0;
    nty = n0;
    npt = p0;
}

/* the declarations of an old-style definition's parameters, up to the { */
void kr_params(int t)
{
    int bt, pt, i;
    in_params++;
    while (tok != '{') {
        bt = decl_spec();
        if (bt < 0) errtok("syntax error near ");
        for (;;) {
            d_name = 0;
            pt = declarator(bt);
            if (tk(pt) == TK_ARRAY) pt = ty_ptr(ty[pt].base);
            else if (tk(pt) == TK_FUNC) pt = ty_ptr(pt);
            else if (tk(pt) == TK_FLOAT) pt = Y_DOUBLE;
            for (i = 0; i < ty[t].size && lastpn[i] != d_name; i++) ;
            if (i == ty[t].size) err("not a parameter: ", id_name(d_name));
            far_sw(A_PT + 4 * (ty[t].aux + i), pt);
            if (tok != ',') break;
            next();
        }
        skip(';');
    }
    in_params--;
}

/* a declaration or a function definition at file scope */
void ext_decl(void)
{
    int bt, t, cls, id, s;
    if (tok == ';') { next(); return; }
    if (tok == T_ID && (tk_val == id_asm || tk_val == id_asm2) && !tk_sym) { asm_block(); return; }
    bt = decl_spec();
    cls = ds_class;
    if (bt < 0) {
        if (tok != T_ID && tok != '*' && tok != '(') errtok("syntax error near ");
        bt = Y_INT;
    }
    if (tok == ';') { next(); return; }
    for (;;) {
        d_name = 0;
        pn_set = 0;
        t = declarator(bt);
        id = d_name;
        if (!id) errtok("syntax error near ");
        if (cls == K_TYPEDEF) sym_decl(id, SC_TYPEDEF, t);
        else if (tk(t) == TK_FUNC) {
            s = func_decl(id, t);
            if ((ty[t].flags & TF_OLD) && tok != ';' && tok != ',' && tok != '{') kr_params(t);
            if (tok == '{') { func_def(s, t); return; }
        } else static_var(id, t, cls);
        if (tok != ',') break;
        next();
    }
    skip(';');
}

/* ================= the image ================= */

void far_copy(long dst, long src, long n)
{
    long p;
    int r;
    n = (n + 7) & ~7;
    for (p = 0; p < n; p = p + 1024) {
        r = n - p > 1024 ? 1024 : n - p;
        far_read(src + p, iob, r);
        far_write(dst + p, iob, r);
    }
}

long lfx[2];

/* every reference left open gets its address; the start-up words */
void link(void)
{
    long a, loc, tg, h, he, units;
    int id, s, w, m = id_sym(id_main);
    if (!m || sy[m].cls != SC_FUNC || !(sy[m].flags & SF_DEF)) err("no main function", 0);
    nocode = 0;
    for (a = A_FIX; a < fix_top; a = a + 16) {
        far_read(a, lfx, 16);
        loc = ((int *)lfx)[0];
        id = ((int *)lfx)[1];
        s = id_sym(id);
        if (s && (sy[s].cls == SC_FUNC || sy[s].cls == SC_STATIC) && (sy[s].flags & SF_DEF)) tg = sy[s].val;
        else {
            tg = lib_lookup(id);
            if (tg < 0) err("undefined: ", id_name(id));
            if (s && sy[s].cls == SC_FUNC) { sy[s].val = tg; sy[s].flags = sy[s].flags | SF_DEF; }
        }
        tg = tg + ((int *)lfx)[2];
        w = code_rd(loc);
        switch (((int *)lfx)[3]) {
        case FK_DATA:
            data_put(loc, tg, 8);
            break;
        case FK_JAL:
            code_wr(loc, (w & ~0x1fffff) | ((tg - loc) >> 2 & 0x1fffff));
            break;
        case FK_LUI:
            if (paged && tg < 0x10000 && (w >> 21 & 31) == X_T6 && code_rd(loc + 8) == enc(OP_XCALL, X_RA, X_T6, 0)) {
                code_wr(loc, enc(OP_JALR, X_RA, X_GP, tg));     /* a call of the resident library */
                code_wr(loc + 4, 0);
                code_wr(loc + 8, 0);
                break;
            }
            code_wr(loc, (w & ~0xffff) | (tg >> 16 & 0xffff));
            w = code_rd(loc + 4);
            code_wr(loc + 4, (w & ~0xffff) | (tg & 0xffff));
            break;
        case FK_MEM:
            w = w & ~0x1fffff;
            if (tg >= 0x8000) w = w | X_GP << 16;
            code_wr(loc, w | (tg & 0xffff));
            break;
        }
    }
    data_put(0, sy[m].val, 8);
    data_put(8, paged ? 12 : 0, 8);
    h = (data_pc + 7) & ~7;
    he = h + heapsz;
    if (he > 0xA000) he = 0xA000;
    data_put(16, h, 8);
    data_put(24, he, 8);
    data_pc = he;
    units = code_pc - code_org;
    if (paged && units + he + res_end > 0x8000 + 0x20000 - 256) {
        split = 1;                      /* larger than the kernel loads: the units go to OUT.u */
        data_put(32, units, 8);
    }
    if (dw_dirty) far_write(A_DATA + dw_base, dwl, 256);
    cw_flush();
}

/* a section of the image to the file: kind 0 is bytes without a header */
void put_sect(int fd, int kind, long base, long size, long src)
{
    long n = (size + 7) & ~7;
    int r;
    if (kind) {
        ((int *)iob)[0] = kind; ((int *)iob)[1] = base;
        ((int *)iob)[2] = n; ((int *)iob)[3] = 0;
        write(fd, iob, 16);
    }
    while (n) {
        r = n > 1024 ? 1024 : n;
        far_read(src, iob, r);
        if (write(fd, iob, r) < 0) err("cannot write ", out_name);
        src = src + r;
        n = n - r;
    }
}

void m_write(void)
{
    int fd, i;
    char *u = (char *)lfx;
    if (!paged && code_pc > 0x10000) err("the code does not fit the instruction store: compile with -p", 0);
    if (!split && code_pc - code_org + data_pc + res_end - (0x8000 - 80) > 0x20000)
        err("the program is larger than 128 KiB", 0);
    fd = open(out_name, 1);
    if (fd < 0) err("cannot write ", out_name);
    ((int *)iob)[0] = 0x32585453;       /* "STX2" */
    ((int *)iob)[1] = 2 + paged - split;
    write(fd, iob, 8);
    if (!paged) put_sect(fd, 1, 0x8000, code_pc - 0x8000, A_CODE);
    else {
        put_sect(fd, 1, 0x8000, res_end - 0x8000, A_RES);
        if (!split) put_sect(fd, 3, 0x10000, code_pc - 0x10000, A_CODE);
    }
    put_sect(fd, 2, 0, data_pc, A_DATA);
    close(fd);
    if (!split) return;
    u = tb;
    for (i = 0; out_name[i]; i++) u[i] = out_name[i];
    u[i] = '.'; u[i + 1] = 'u'; u[i + 2] = 0;
    fd = open(u, 1);
    if (fd < 0) err("cannot write ", u);
    put_sect(fd, 0, 0, code_pc - code_org, A_CODE);
    close(fd);
}

/* ================= the driver ================= */

/* an object-like macro defined before the program is read */
void predef(char *name, char *body)
{
    int id = intern(name, slen(name)), n = slen(body), i;
    wb_open(mac_top + 16);
    for (i = 0; i < n; i++) wb_put(body[i]);
    wb_close();
    far_sd(mac_top, (long)n << 32);
    far_sw(id + 4, mac_top);
    mac_top = (mac_top + 16 + n + 7) & ~7;
}

void usage(void)
{
    eputs("usage: cc [-o OUT] [-p] [-h KIB] FILE.c\n");
    _exit(2);
}

void options(int argc, char **argv)
{
    int i, n;
    char *a, *b;
    heapsz = 8192;
    for (i = 1; i < argc; i++) {
        a = argv[i];
        if (a[0] != '-') { src_name = a; continue; }
        if (a[1] == 'p') { paged = 1; continue; }
        if (i + 1 >= argc) usage();
        b = argv[++i];
        if (a[1] == 'o') out_name = b;
        else if (a[1] == 'h') {
            for (n = 0; isdig(*b); b++) n = n * 10 + *b - '0';
            heapsz = n << 10;
        } else usage();
    }
    if (!src_name) usage();
    if (out_name) return;
    for (a = b = src_name; *a; a++) if (*a == '/') b = a + 1;
    for (n = 0; b[n] && n < 38; n++) outbuf[n] = b[n];
    outbuf[n] = 0;
    if (n > 2 && outbuf[n - 1] == 'c' && outbuf[n - 2] == '.') outbuf[n - 2] = 0;
    out_name = outbuf;
}

/* the library: its symbols, its data at the start of the D-LS image, its
   code as the start of the program's (or, paged, as the resident part) */
void lib_load(void)
{
    long a, n, p;
    int i;
    lib_base = A_LIB;
    lib_len = m_load("/bin/cc.lib", A_LIB, A_LIBEND - A_LIB, 1);
    if (lib_len < 0) err("cannot read /bin/cc.lib", 0);
    lib_sym = lib_find("libc.sym");
    lib_nsym = lib_sz / 24;
    for (i = 0; i < 130; i++) iob[i] = 0;
    for (p = 0; p < 0xA000; p = p + 1024) far_write(A_DATA + p, iob, 1024);
    far_write(A_IDH, iob, 1024);
    far_write(A_IDH + 1024, iob, 1024);
    a = lib_find("libc.data");
    far_copy(A_DATA, a, lib_sz);
    data_pc = (lib_sz + 7) & ~7;
    a = lib_find("libc.text");
    if (!lib_sym || !a) err("bad /bin/cc.lib", 0);
    n = (lib_sz + 7) & ~7;
    res_end = 0x8000 + n;
    if (paged) {
        far_copy(A_RES, a, n);
        code_org = 0x10000;
        code_pc = 0x10000;
        cw_base = 0x10000;
    } else {
        far_copy(A_CODE, a, n);
        code_org = 0x8000;
        cw_seek(res_end);
    }
}

int main(int argc, char **argv)
{
    int i;
    options(argc, argv);
    nsy = 1; vp = vs; vlive = vs; nocode = 1;
    id_top = A_ID; mac_top = A_MAC; xh_top = A_XH; src_top = A_INC; fix_top = A_FIX;
    sw_base = -1; rb_base = -1; dw_base = -4096; sf_pin = -1;
    lib_load();
    lex_init();
    ty_init();
    id_main = intern("main", 4);
    id_func = intern("__func__", 8);
    id_asm = intern("asm", 3);
    id_asm2 = intern("__asm__", 7);
    predef("__STDC__", "1");
    predef("__STDC_VERSION__", "199901L");
    predef("__strata__", "1");
    predef("__STRATA_CC__", "1");
    predef("__STRATA_VA__", "1");
    sf_fd = open(src_name, 0);
    if (sf_fd < 0) err("cannot open ", src_name);
    in_pos = A_SRC; in_end = A_SRC; sf_top = A_SRC;
    in_kind = 1; line = 1; bol = 1;
    fname = fnames;
    for (i = 0; src_name[i] && i < 31; i++) fname[i] = src_name[i];
    fname[i] = 0;
    next();
    while (tok) ext_decl();
    close(sf_fd);
    fname = 0;
    link();
    m_write();
    return 0;
}
