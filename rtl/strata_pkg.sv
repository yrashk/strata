// Strata prototype: shared definitions.
//
// Architectural constants, opcode map, capability format and trap causes.
// The assembler (asm/isa.h) mirrors this file; keep the two in step.

package strata_pkg;

  // ---------------------------------------------------------------- sizes
  localparam int DLS_BYTES = 65536;    // data Local Store (T1d)
  localparam int ILS_BYTES = 65536;    // instruction Local Store (T1i)
  localparam int T2_BYTES  = 262144;   // cluster store
  localparam int T3_BYTES  = 67108864; // system memory (64 MiB; the framebuffer window is the top 16 MiB)

  localparam int DLS_WORDS = DLS_BYTES / 8;
  localparam int ILS_WORDS = ILS_BYTES / 8;
  localparam int T2_WORDS  = T2_BYTES / 8;
  localparam int T3_WORDS  = T3_BYTES / 8;

  localparam int NTAGS     = 16;
  localparam int NCAPS     = 16;
  localparam int CTAB      = 256;      // capability save table entries (common/platform.h CTAB_DEF)
  localparam int CTW       = $clog2(CTAB); // a slot number
  localparam int NXMAP     = 16;       // overlay map entries
  localparam int GRAN_SHIFT = 18;      // revocation granules of T2 and T3: 256 KiB
  localparam int NG3       = T3_BYTES >> GRAN_SHIFT;   // T3 granules
  localparam int NG2       = T2_BYTES >> GRAN_SHIFT;   // T2 granules
  localparam int GW        = $clog2(NG3 + 1);          // a granule index, up to NG3 (one past the end)
  localparam int G3W       = $clog2(NG3);              // an index into T3's granules
  localparam int G2W       = NG2 > 1 ? $clog2(NG2) : 1; // ... into T2's

  // ---------------------------------------------------------------- spaces
  localparam logic [2:0] SP_NONE = 3'd0;
  localparam logic [2:0] SP_T2   = 3'd2;
  localparam logic [2:0] SP_T3   = 3'd3;
  localparam logic [2:0] SP_DEV  = 3'd4;
  localparam logic [2:0] SP_CORE = 3'd5;   // core control: a word with bit 0 set stops that core
  localparam logic [2:0] SP_EP   = 3'd6;   // endpoint: names a node for csend / crecv

  // ---------------------------------------------------------------- perms
  localparam int P_R = 0;   // transfer far -> LS
  localparam int P_W = 1;   // transfer LS -> far; implies linear
  localparam int P_X = 2;   // transfer far -> I-LS, overlay map
  localparam int P_A = 3;   // far atomics only
  localparam int P_D = 4;   // duplicable (never together with W)
  localparam int P_V = 5;   // revoker: crevoke / cundom over its range

  typedef struct packed {
    logic        valid;
    logic [2:0]  space;
    logic [5:0]  perms;
    logic [63:0] base;
    logic [63:0] len;
    logic        rv;             // revocable: live while its granule's generation is gen
    logic [15:0] gen;            // revocable: the generation of its base's granule when made;
                                 // a revoker (V): the permissions crevoke / cundom give
  } cap_t;

  localparam cap_t CAP_NULL = '0;

  // ---------------------------------------------------------------- opcodes
  localparam logic [5:0] OP_ALU    = 6'h00;
  localparam logic [5:0] OP_ADDI   = 6'h01;
  localparam logic [5:0] OP_ANDI   = 6'h02;
  localparam logic [5:0] OP_ORI    = 6'h03;
  localparam logic [5:0] OP_XORI   = 6'h04;
  localparam logic [5:0] OP_SLLI   = 6'h05;
  localparam logic [5:0] OP_SRLI   = 6'h06;
  localparam logic [5:0] OP_SRAI   = 6'h07;
  localparam logic [5:0] OP_SLTI   = 6'h08;
  localparam logic [5:0] OP_SLTIU  = 6'h09;
  localparam logic [5:0] OP_LUI    = 6'h0A;

  localparam logic [5:0] OP_LD     = 6'h10;
  localparam logic [5:0] OP_LW     = 6'h11;
  localparam logic [5:0] OP_LWU    = 6'h12;
  localparam logic [5:0] OP_LH     = 6'h13;
  localparam logic [5:0] OP_LHU    = 6'h14;
  localparam logic [5:0] OP_LB     = 6'h15;
  localparam logic [5:0] OP_LBU    = 6'h16;
  localparam logic [5:0] OP_SD     = 6'h18;
  localparam logic [5:0] OP_SW     = 6'h19;
  localparam logic [5:0] OP_SH     = 6'h1A;
  localparam logic [5:0] OP_SB     = 6'h1B;

  localparam logic [5:0] OP_BEQ    = 6'h20;
  localparam logic [5:0] OP_BNE    = 6'h21;
  localparam logic [5:0] OP_BLT    = 6'h22;
  localparam logic [5:0] OP_BGE    = 6'h23;
  localparam logic [5:0] OP_BLTU   = 6'h24;
  localparam logic [5:0] OP_BGEU   = 6'h25;
  localparam logic [5:0] OP_JAL    = 6'h28;
  localparam logic [5:0] OP_JALR   = 6'h29;

  localparam logic [5:0] OP_XFER   = 6'h30;  // tget / tput / tgetx
  localparam logic [5:0] OP_TWAIT  = 6'h31;
  localparam logic [5:0] OP_TPOLL  = 6'h32;
  localparam logic [5:0] OP_TAMO   = 6'h33;
  localparam logic [5:0] OP_CAP    = 6'h34;

  localparam logic [5:0] OP_CSRR   = 6'h38;
  localparam logic [5:0] OP_CSRW   = 6'h39;
  localparam logic [5:0] OP_SYS    = 6'h3A;
  localparam logic [5:0] OP_LTAG   = 6'h3B;
  localparam logic [5:0] OP_LINST  = 6'h3C;
  localparam logic [5:0] OP_XMAP   = 6'h3D;
  localparam logic [5:0] OP_XCALL  = 6'h3E;
  localparam logic [5:0] OP_CAP2   = 6'h35;
  localparam logic [5:0] OP_TANY   = 6'h36;

  // second capability group (OP_CAP2, funct[3:0])
  localparam logic [3:0] C2_DOM = 4'd0, C2_REVOKE = 4'd1, C2_UNDOM = 4'd2, C2_SEND = 4'd3,
                         C2_RECV = 4'd4, C2_MKEP = 4'd5, C2_SAVEX = 4'd6, C2_RESTOREX = 4'd7;

  // ALU funct (OP_ALU, funct[5:0])
  localparam logic [3:0] ALU_ADD = 4'd0,  ALU_SUB  = 4'd1,  ALU_AND  = 4'd2,  ALU_OR   = 4'd3;
  localparam logic [3:0] ALU_XOR = 4'd4,  ALU_SLL  = 4'd5,  ALU_SRL  = 4'd6,  ALU_SRA  = 4'd7;
  localparam logic [3:0] ALU_SLT = 4'd8,  ALU_SLTU = 4'd9,  ALU_MUL  = 4'd10, ALU_MULHU= 4'd11;
  localparam logic [3:0] ALU_DIVU= 4'd12, ALU_REMU = 4'd13, ALU_DIV  = 4'd14, ALU_REM  = 4'd15;

  // transfer sub-ops (OP_XFER, ir[25:23])
  localparam logic [2:0] XF_GET  = 3'd0;
  localparam logic [2:0] XF_PUT  = 3'd1;
  localparam logic [2:0] XF_GETX = 3'd2;

  // far atomic ops (OP_TAMO, funct[2:0])
  localparam logic [2:0] AMO_ADD = 3'd0, AMO_SWAP = 3'd1, AMO_CAS = 3'd2, AMO_AND = 3'd3, AMO_OR = 3'd4;

  // capability functions (OP_CAP, funct[3:0])
  localparam logic [3:0] CF_MOV   = 4'd0,  CF_SPLIT = 4'd1,  CF_JOIN  = 4'd2,  CF_SHARE   = 4'd3;
  localparam logic [3:0] CF_ATOM  = 4'd4,  CF_RESTR = 4'd5,  CF_BASE  = 4'd6,  CF_LEN     = 4'd7;
  localparam logic [3:0] CF_PERMS = 4'd8,  CF_GIVE  = 4'd9,  CF_TAKE  = 4'd10, CF_CLEAR   = 4'd11;
  localparam logic [3:0] CF_SAVE  = 4'd12, CF_RESTORE = 4'd13, CF_VALID = 4'd14, CF_POLL = 4'd15;

  // system functions (OP_SYS, imm16)
  localparam logic [15:0] SYS_HALT = 16'd0, SYS_ERET = 16'd1, SYS_SVC = 16'd2;

  // CSRs
  localparam logic [15:0] CSR_CYCLE = 16'd0,  CSR_INSTRET = 16'd1, CSR_CAUSE = 16'd2,  CSR_EPC   = 16'd3;
  localparam logic [15:0] CSR_TVAL  = 16'd4,  CSR_TVEC    = 16'd5, CSR_CCR   = 16'd6,  CSR_COREID= 16'd7;
  localparam logic [15:0] CSR_TTAG  = 16'd8,  CSR_TDATA   = 16'd9, CSR_TGEOM = 16'd10, CSR_NCORES= 16'd11;
  localparam logic [15:0] CSR_SCRATCH = 16'd12, CSR_STALLS = 16'd13, CSR_TAKEFROM = 16'd14;
  localparam logic [15:0] CSR_COREBASE = 16'd15, CSR_CORECOUNT = 16'd16;
  localparam logic [15:0] CSR_STATUS = 16'd18, CSR_UCAUSE = 16'd19, CSR_UEPC = 16'd20, CSR_UTVAL = 16'd21;
  localparam logic [15:0] CSR_UTVEC = 16'd22, CSR_SSCRATCH = 16'd23, CSR_IPEND = 16'd24, CSR_XSLOT = 16'd25;

  // ---------------------------------------------------------------- causes
  localparam logic [7:0] C_ILLEGAL = 8'd1;   // undefined encoding
  localparam logic [7:0] C_LSFAULT = 8'd2;   // LS address out of range / misaligned
  localparam logic [7:0] C_CAPINV  = 8'd3;   // capability register not valid
  localparam logic [7:0] C_PERM    = 8'd4;   // capability lacks permission
  localparam logic [7:0] C_BOUNDS  = 8'd5;   // far range outside the segment
  localparam logic [7:0] C_XALIGN  = 8'd6;   // transfer misaligned
  localparam logic [7:0] C_IFAULT  = 8'd7;   // fetch outside I-LS
  localparam logic [7:0] C_XMISS   = 8'd8;   // xcall target not mapped
  localparam logic [7:0] C_PEND    = 8'd9;   // touched an in-flight LS range with CCR.PTRAP set
  localparam logic [7:0] C_CAPOP   = 8'd10;  // capability operation preconditions failed
  localparam logic [7:0] C_PRIV    = 8'd11;  // supervisor-only operation in user mode
  localparam logic [7:0] C_HALT    = 8'd12;  // a user-mode halt, delivered to the supervisor
  localparam logic [7:0] C_STOP    = 8'd13;  // stopped through the core-control capability
  localparam logic [7:0] C_SVC     = 8'd14;  // svc in user mode: a request to the supervisor

  // ---------------------------------------------------------------- decoded instruction
  typedef enum logic [4:0] {
    K_ILLEGAL, K_ALU, K_ALUI, K_LUI, K_LOAD, K_STORE, K_BRANCH, K_JAL, K_JALR,
    K_XFER, K_TWAIT, K_TPOLL, K_TAMO, K_CAP, K_CSRR, K_CSRW, K_SYS,
    K_LTAG, K_LINST, K_XMAP, K_XCALL, K_CAP2, K_TANY
  } kind_t;

  typedef struct packed {
    kind_t       kind;
    logic [3:0]  alu_op;
    logic [4:0]  rd, rs1, rs2;   // integer register fields (or cap indices for K_CAP)
    logic [63:0] imm;            // sign/zero-extended immediate, branch offsets in bytes
    logic [1:0]  msize;          // log2 access size for loads/stores
    logic        msigned;
    logic [2:0]  br_op;          // opcode[2:0] of branches
    logic [2:0]  xf_sub;         // transfer kind
    logic [3:0]  tag;            // transfer tag
    logic [4:0]  rl, ro, rn;     // transfer LS address / far offset / length registers
    logic [3:0]  cs;             // capability operand of transfers, atomics, overlays
    logic [2:0]  amo_op;
    logic [3:0]  cap_fn;
    logic [5:0]  slot;           // capability table slot
    logic        flag;           // xunmap
    logic [15:0] imm16;
    logic        writes_rd;
    logic [4:0]  pa, pb, pc;     // register-file read ports: rs1/rl, rs2/ro, rd/rn
  } dec_t;

  // ---------------------------------------------------------------- device space
  localparam logic [63:0] DEV_CONSOLE = 64'h0000;  // output port 0, input port 8
  localparam logic [63:0] DEV_CON_IN  = 64'h0008;
  localparam logic [63:0] DEV_CON_BRK = 64'h0010;  // read: completes on Ctrl-C
  localparam logic [63:0] DEV_CON_REL = 64'h0018;  // write: completes a pending break read with 0
  localparam logic [63:0] DEV_PLAT    = 64'h1000;  // platform table ROM
  localparam logic [63:0] DEV_BLK0    = 64'h2000;  // block device 0 window
  localparam logic [63:0] DEV_TIMER   = 64'h3000;  // timer: NOW, FREQ, DEADLINE, WAIT
  localparam logic [63:0] DEV_TMR_NOW = 64'h3000;
  localparam logic [63:0] DEV_TMR_FREQ= 64'h3008;
  localparam logic [63:0] DEV_TMR_DL  = 64'h3010;
  localparam logic [63:0] DEV_TMR_WAIT= 64'h3018;
  localparam logic [63:0] DEV_FB_PRESENT = 64'h4000;  // framebuffer controller: PRESENT, VSYNC
  localparam logic [63:0] DEV_FB_VSYNC   = 64'h4008;
  localparam logic [63:0] DEV_PTR_EVENT  = 64'h4100;  // pointer: EVENT (waiting read; a write releases), STATE
  localparam logic [63:0] DEV_PTR_STATE  = 64'h4108;
  localparam logic [63:0] DEV_NET_TX     = 64'h4200;  // network: TX (one transfer = one packet)
  localparam logic [63:0] DEV_NET_RX     = 64'h4208;  // RX (waits for a packet)
  localparam logic [63:0] DEV_NET_STATUS = 64'h4210;  // STATUS (latched at byte 0)
  localparam logic [63:0] DEV_NET_CANCEL = 64'h4218;  // CANCEL (completes waiting RX reads with zeros)
  localparam logic [63:0] DEV_LEN     = 64'h5000;
  localparam int          PLAT_LEN    = 320;        // 32 + 32 x 9 entries (common/platform.h)
  localparam longint      TMR_HZ      = 1000000;    // timer ticks per second (1 tick = 1 us)
  localparam longint      FRAME_TICKS = 16667;      // one 60 Hz display refresh, in ticks
  localparam int          IDENT_LEN   = 64;

`ifdef SIMULATION
  // ---------------------------------------------------------------- simulator hooks
  import "DPI-C" function longint img_word(input int kind, input int widx);
  import "DPI-C" function void sim_putc(input byte c);
  import "DPI-C" function int sim_getc();
  import "DPI-C" function int sim_break();
  import "DPI-C" function longint sim_ptr_pop();    // the next pointer event, or -1: none yet
  import "DPI-C" function longint sim_ptr_state(input int touch); // STATE now (touch: the guest read it)
  import "DPI-C" function byte plat_byte(input int idx);
  import "DPI-C" function byte ident_byte(input int idx);
  import "DPI-C" function longint disk_word(input int widx);
  import "DPI-C" function void disk_write(input int widx, input longint v);
  import "DPI-C" function void sim_halt(input int core, input longint code, input longint cycles,
                                        input longint instret, input longint stalls);
  import "DPI-C" function void sim_fault(input int core, input int cause, input longint pc,
                                         input longint tval, input int dbl);
  import "DPI-C" function int sim_trace_on();
  import "DPI-C" function longint sim_time_us();    // host microseconds, or -1: count cycles
  import "DPI-C" function void sim_fb_present();    // PRESENT: the harness reads the framebuffer
  import "DPI-C" function void sim_fb_write(input int widx); // a system-memory word in the framebuffer window was written (live scanout)
  import "DPI-C" function void sim_trace(input int core, input longint pc, input int ir);
  import "DPI-C" function void sim_net_tx(input int idx, input byte b, input int last); // a TX byte; last: the packet is complete
  import "DPI-C" function int sim_net_rx_take();    // the next packet becomes the current one: its length, or -1 if none
  import "DPI-C" function byte sim_net_rx_byte(input int idx); // byte idx of the current packet (0 past its end)
  import "DPI-C" function longint sim_net_status(); // the STATUS register
`endif

endpackage
