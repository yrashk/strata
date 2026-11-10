// Strata prototype: instruction decoder.
//
// Purely combinational. Splits a 32-bit instruction word into the fields
// named by its format and flags undefined encodings as K_ILLEGAL.
//
//   R   op[31:26] rd[25:21] rs1[20:16] rs2[15:11] funct[10:0]
//   I   op        rd        rs1        imm16[15:0]
//   S   op        rs2(data) rs1(base)  imm16
//   B   op        rs1       rs2        off16 (words)
//   J   op        rd        off21[20:0] (words)
//   X   op        sub[25:23] tag[22:19] rl[18:14] cs[13:10] ro[9:5] rn[4:0]

module strata_decode
  import strata_pkg::*;
(
  input  logic [31:0] ir,
  output dec_t        d
);
  logic [5:0]  op;
  logic [15:0] imm16;
  logic [10:0] funct;
  logic [63:0] simm, zimm;

  assign op    = ir[31:26];
  assign imm16 = ir[15:0];
  assign funct = ir[10:0];
  assign simm  = {{48{imm16[15]}}, imm16};
  assign zimm  = {48'b0, imm16};

  // capability functions that name a capability in rd / rs1
  function automatic logic cap_rd(input logic [3:0] fn);
    return fn inside {CF_MOV, CF_SPLIT, CF_JOIN, CF_SHARE, CF_ATOM, CF_RESTR, CF_TAKE, CF_CLEAR, CF_RESTORE};
  endfunction
  function automatic logic cap_rs1(input logic [3:0] fn);
    return fn inside {CF_MOV, CF_SPLIT, CF_JOIN, CF_SHARE, CF_ATOM, CF_RESTR, CF_BASE, CF_LEN,
                      CF_PERMS, CF_VALID, CF_GIVE, CF_SAVE};
  endfunction

  always_comb begin
    d          = '0;
    d.kind     = K_ILLEGAL;
    d.rd       = ir[25:21];
    d.rs1      = ir[20:16];
    d.rs2      = ir[15:11];
    d.imm16    = imm16;
    d.br_op    = op[2:0];
    d.xf_sub   = ir[25:23];
    d.tag      = ir[22:19];
    d.rl       = ir[18:14];
    d.ro       = ir[9:5];
    d.rn       = ir[4:0];
    d.cap_fn   = funct[3:0];
    d.slot     = funct[10:5];
    d.flag     = funct[4];

    unique case (op)
      OP_ALU: begin
        d.kind = funct[10:4] == 0 ? K_ALU : K_ILLEGAL;
        d.alu_op = funct[3:0];
      end
      OP_ADDI:  begin d.kind = K_ALUI; d.alu_op = ALU_ADD;  d.imm = simm; end
      OP_SLTI:  begin d.kind = K_ALUI; d.alu_op = ALU_SLT;  d.imm = simm; end
      OP_SLTIU: begin d.kind = K_ALUI; d.alu_op = ALU_SLTU; d.imm = simm; end
      OP_ANDI:  begin d.kind = K_ALUI; d.alu_op = ALU_AND;  d.imm = zimm; end
      OP_ORI:   begin d.kind = K_ALUI; d.alu_op = ALU_OR;   d.imm = zimm; end
      OP_XORI:  begin d.kind = K_ALUI; d.alu_op = ALU_XOR;  d.imm = zimm; end
      OP_SLLI:  begin d.kind = K_ALUI; d.alu_op = ALU_SLL;  d.imm = {58'b0, imm16[5:0]}; end
      OP_SRLI:  begin d.kind = K_ALUI; d.alu_op = ALU_SRL;  d.imm = {58'b0, imm16[5:0]}; end
      OP_SRAI:  begin d.kind = K_ALUI; d.alu_op = ALU_SRA;  d.imm = {58'b0, imm16[5:0]}; end
      OP_LUI:   begin d.kind = K_LUI;  d.imm = simm << 16; end

      OP_LD:  begin d.kind = K_LOAD; d.msize = 2'd3; d.imm = simm; end
      OP_LW:  begin d.kind = K_LOAD; d.msize = 2'd2; d.msigned = 1; d.imm = simm; end
      OP_LWU: begin d.kind = K_LOAD; d.msize = 2'd2; d.imm = simm; end
      OP_LH:  begin d.kind = K_LOAD; d.msize = 2'd1; d.msigned = 1; d.imm = simm; end
      OP_LHU: begin d.kind = K_LOAD; d.msize = 2'd1; d.imm = simm; end
      OP_LB:  begin d.kind = K_LOAD; d.msize = 2'd0; d.msigned = 1; d.imm = simm; end
      OP_LBU: begin d.kind = K_LOAD; d.msize = 2'd0; d.imm = simm; end

      OP_SD, OP_SW, OP_SH, OP_SB: begin
        d.kind  = K_STORE;
        d.rs2   = ir[25:21];
        d.rs1   = ir[20:16];
        d.msize = op == OP_SD ? 2'd3 : op == OP_SW ? 2'd2 : op == OP_SH ? 2'd1 : 2'd0;
        d.imm   = simm;
      end

      OP_BEQ, OP_BNE, OP_BLT, OP_BGE, OP_BLTU, OP_BGEU: begin
        d.kind = K_BRANCH;
        d.rs1  = ir[25:21];
        d.rs2  = ir[20:16];
        d.imm  = simm << 2;
      end
      OP_JAL:  begin d.kind = K_JAL;  d.imm = {{41{ir[20]}}, ir[20:0], 2'b00}; end
      OP_JALR: begin d.kind = K_JALR; d.imm = simm; end

      OP_XFER: begin
        d.kind = ir[25:23] <= XF_GETX ? K_XFER : K_ILLEGAL;
        d.cs   = ir[13:10];
      end
      OP_TWAIT: d.kind = K_TWAIT;
      OP_TPOLL: d.kind = K_TPOLL;
      OP_TAMO: begin
        d.kind   = (funct[2:0] <= AMO_OR && funct[6:3] == 0) ? K_TAMO : K_ILLEGAL;
        d.amo_op = funct[2:0];
        d.cs     = funct[10:7];
      end
      OP_CAP: begin
        d.kind = (!(cap_rd(funct[3:0]) && ir[25])
                  && !(cap_rs1(funct[3:0]) && ir[20])) ? K_CAP : K_ILLEGAL;
      end

      OP_CSRR: d.kind = K_CSRR;
      OP_CSRW: d.kind = K_CSRW;
      OP_SYS:  d.kind = imm16 <= SYS_SVC ? K_SYS : K_ILLEGAL;
      OP_LTAG:  d.kind = K_LTAG;
      OP_LINST: d.kind = K_LINST;
      OP_XMAP: begin
        d.kind = ir[25] == 0 ? K_XMAP : K_ILLEGAL;
        d.cs   = funct[3:0];
      end
      OP_CAP2: begin
        d.kind = (funct[3:0] <= C2_MKEP && !ir[25] && !ir[20]) ? K_CAP2 : K_ILLEGAL;
      end
      OP_TANY: d.kind = K_TANY;
      OP_XCALL: begin
        d.kind = K_XCALL;
        d.cs   = funct[3:0];
      end
      default: d.kind = K_ILLEGAL;
    endcase

    d.writes_rd = d.kind inside {K_ALU, K_ALUI, K_LUI, K_LOAD, K_JAL, K_JALR, K_TPOLL, K_TANY,
                                 K_TAMO, K_CSRR, K_LTAG, K_XCALL}
                  || (d.kind == K_CAP && d.cap_fn inside {CF_BASE, CF_LEN, CF_PERMS, CF_VALID, CF_POLL});

    // register-file read ports: transfers read rl/ro/rn, everything else rs1/rs2/rd
    d.pa = d.kind == K_XFER ? d.rl : d.rs1;
    d.pb = d.kind == K_XFER ? d.ro : d.rs2;
    d.pc = d.kind == K_XFER ? d.rn : d.rd;
  end
endmodule
