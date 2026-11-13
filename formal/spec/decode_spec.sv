// Formal specification of strata_decode.
//
// The rules are the emulator's (emu/emu.c step(): which encodings trap
// with C_ILLEGAL before anything else is looked at) and the formats of
// asm/isa.h. Written from those, not from the decoder: the opcode numbers
// are spelled out here so that a wrong constant in strata_pkg shows.
//
// The instruction word is unconstrained: no assumptions.
//
// Not specified: d.writes_rd (the core does not use it), and the checks the
// core makes itself because they need machine state (xmap's entry number
// against NXMAP, svc in the supervisor).

module decode_spec
  import strata_pkg::*;
(
  input logic [31:0] ir
);
  dec_t d;
  strata_decode dut (.ir, .d);

  logic [5:0]  op;
  logic [4:0]  f_rd, f_rs1, f_rs2;
  logic [10:0] funct;
  logic [15:0] imm16;
  logic [63:0] simm, zimm;
  assign op    = ir[31:26];
  assign f_rd  = ir[25:21];
  assign f_rs1 = ir[20:16];
  assign f_rs2 = ir[15:11];
  assign funct = ir[10:0];
  assign imm16 = ir[15:0];
  assign simm  = {{48{ir[15]}}, ir[15:0]};
  assign zimm  = {48'b0, ir[15:0]};

  // ---- the instruction classes, by opcode number (asm/isa.h)
  logic is_alu, is_alui, is_lui, is_load, is_store, is_branch, is_jal, is_jalr, is_xfer, is_twait,
        is_tpoll, is_tamo, is_cap, is_cap2, is_tany, is_csrr, is_csrw, is_sys, is_ltag, is_linst,
        is_xmap, is_xcall;
  assign is_alu    = op == 6'h00;
  assign is_alui   = op >= 6'h01 && op <= 6'h09;
  assign is_lui    = op == 6'h0a;
  assign is_load   = op >= 6'h10 && op <= 6'h16;
  assign is_store  = op >= 6'h18 && op <= 6'h1b;
  assign is_branch = op >= 6'h20 && op <= 6'h25;
  assign is_jal    = op == 6'h28;
  assign is_jalr   = op == 6'h29;
  assign is_xfer   = op == 6'h30;
  assign is_twait  = op == 6'h31;
  assign is_tpoll  = op == 6'h32;
  assign is_tamo   = op == 6'h33;
  assign is_cap    = op == 6'h34;
  assign is_cap2   = op == 6'h35;
  assign is_tany   = op == 6'h36;
  assign is_csrr   = op == 6'h38;
  assign is_csrw   = op == 6'h39;
  assign is_sys    = op == 6'h3a;
  assign is_ltag   = op == 6'h3b;
  assign is_linst  = op == 6'h3c;
  assign is_xmap   = op == 6'h3d;
  assign is_xcall  = op == 6'h3e;

  // ---- which encodings are defined (emu.c: every `trap(c, C_ILLEGAL, ir)`
  // that depends on the instruction word alone)
  logic [3:0] fn;
  logic       cap_names_rd, cap_names_rs1, legal;
  assign fn = funct[3:0];
  // capability functions whose rd / rs1 field names a capability register
  // (0..15): mov split join share atom restr take clear restore / mov split
  // join share atom restr base len perms valid give save
  assign cap_names_rd  = fn == 4'd0 || fn == 4'd1 || fn == 4'd2 || fn == 4'd3 || fn == 4'd4 ||
                         fn == 4'd5 || fn == 4'd10 || fn == 4'd11 || fn == 4'd13;
  assign cap_names_rs1 = fn == 4'd0 || fn == 4'd1 || fn == 4'd2 || fn == 4'd3 || fn == 4'd4 ||
                         fn == 4'd5 || fn == 4'd6 || fn == 4'd7 || fn == 4'd8 || fn == 4'd14 ||
                         fn == 4'd9 || fn == 4'd12;
  always_comb begin
    legal = 0;
    if (is_alu)    legal = funct[10:4] == 0;
    if (is_alui || is_lui || is_load || is_store || is_branch || is_jal || is_jalr) legal = 1;
    if (is_xfer)   legal = ir[25:23] <= 3'd2;                      // tget, tput, tgetx
    if (is_twait || is_tpoll || is_tany) legal = 1;
    if (is_tamo)   legal = funct[2:0] <= 3'd4 && funct[6:3] == 0;  // add swap cas and or
    if (is_cap)    legal = !(cap_names_rd && f_rd[4]) && !(cap_names_rs1 && f_rs1[4]);
    if (is_cap2)   legal = !f_rd[4] && !f_rs1[4] && fn <= 4'd7;
    if (is_csrr || is_csrw || is_ltag || is_linst || is_xcall) legal = 1;
    if (is_sys)    legal = imm16 <= 16'd2;                         // halt, eret, svc
    if (is_xmap)   legal = !f_rd[4];                               // at most 16 map entries
  end

  always_comb begin
    // ---- legality, and the kind of every legal instruction
    assert ((d.kind == K_ILLEGAL) == !legal);
    if (legal) begin
      assert ((d.kind == K_ALU)    == is_alu);
      assert ((d.kind == K_ALUI)   == is_alui);
      assert ((d.kind == K_LUI)    == is_lui);
      assert ((d.kind == K_LOAD)   == is_load);
      assert ((d.kind == K_STORE)  == is_store);
      assert ((d.kind == K_BRANCH) == is_branch);
      assert ((d.kind == K_JAL)    == is_jal);
      assert ((d.kind == K_JALR)   == is_jalr);
      assert ((d.kind == K_XFER)   == is_xfer);
      assert ((d.kind == K_TWAIT)  == is_twait);
      assert ((d.kind == K_TPOLL)  == is_tpoll);
      assert ((d.kind == K_TAMO)   == is_tamo);
      assert ((d.kind == K_CAP)    == is_cap);
      assert ((d.kind == K_CAP2)   == is_cap2);
      assert ((d.kind == K_TANY)   == is_tany);
      assert ((d.kind == K_CSRR)   == is_csrr);
      assert ((d.kind == K_CSRW)   == is_csrw);
      assert ((d.kind == K_SYS)    == is_sys);
      assert ((d.kind == K_LTAG)   == is_ltag);
      assert ((d.kind == K_LINST)  == is_linst);
      assert ((d.kind == K_XMAP)   == is_xmap);
      assert ((d.kind == K_XCALL)  == is_xcall);
    end
    // the kind is always one of the enumeration's values
    assert (d.kind <= K_TANY);

    // ---- operands, per class
    if (is_alu && legal) begin
      assert (d.alu_op == funct[3:0]);
      assert (d.rd == f_rd && d.rs1 == f_rs1 && d.rs2 == f_rs2);
    end
    if (is_alui) begin
      assert (d.rd == f_rd && d.rs1 == f_rs1);
      case (op)
        6'h01: assert (d.alu_op == 4'd0 && d.imm == simm);                    // addi
        6'h02: assert (d.alu_op == 4'd2 && d.imm == zimm);                    // andi
        6'h03: assert (d.alu_op == 4'd3 && d.imm == zimm);                    // ori
        6'h04: assert (d.alu_op == 4'd4 && d.imm == zimm);                    // xori
        6'h05: assert (d.alu_op == 4'd5 && d.imm == {58'b0, ir[5:0]});        // slli
        6'h06: assert (d.alu_op == 4'd6 && d.imm == {58'b0, ir[5:0]});        // srli
        6'h07: assert (d.alu_op == 4'd7 && d.imm == {58'b0, ir[5:0]});        // srai
        6'h08: assert (d.alu_op == 4'd8 && d.imm == simm);                    // slti
        default: assert (d.alu_op == 4'd9 && d.imm == simm);                  // sltiu
      endcase
    end
    if (is_lui) assert (d.rd == f_rd && d.imm == {{32{ir[15]}}, ir[15:0], 16'b0});
    if (is_load) begin
      assert (d.rd == f_rd && d.rs1 == f_rs1 && d.imm == simm);
      // the address is formed by the ALU: it must add
      assert (d.alu_op == 4'd0);
      case (op)
        6'h10: assert (d.msize == 2'd3);                                      // ld
        6'h11: assert (d.msize == 2'd2 && d.msigned);                         // lw
        6'h12: assert (d.msize == 2'd2 && !d.msigned);                        // lwu
        6'h13: assert (d.msize == 2'd1 && d.msigned);                         // lh
        6'h14: assert (d.msize == 2'd1 && !d.msigned);                        // lhu
        6'h15: assert (d.msize == 2'd0 && d.msigned);                         // lb
        default: assert (d.msize == 2'd0 && !d.msigned);                      // lbu
      endcase
    end
    if (is_store) begin
      // S format: the data register is in the rd field, the base in rs1
      assert (d.rs1 == f_rs1 && d.rs2 == f_rd && d.imm == simm && d.alu_op == 4'd0);
      assert (d.msize == 2'd3 - op[1:0]);                                     // sd sw sh sb
    end
    if (is_branch) begin
      // B format: the compared registers are in the rd and rs1 fields
      assert (d.rs1 == f_rd && d.rs2 == f_rs1);
      assert (d.imm == {{46{ir[15]}}, ir[15:0], 2'b00});
      assert (d.br_op == op[2:0]);
    end
    if (is_jal)  assert (d.rd == f_rd && d.imm == {{41{ir[20]}}, ir[20:0], 2'b00});
    if (is_jalr) assert (d.rd == f_rd && d.rs1 == f_rs1 && d.imm == simm && d.alu_op == 4'd0);
    if (is_xfer && legal) begin
      assert (d.xf_sub == ir[25:23] && d.tag == ir[22:19] && d.rl == ir[18:14] && d.cs == ir[13:10]);
      assert (d.ro == ir[9:5] && d.rn == ir[4:0]);
    end
    if (is_twait || is_tpoll || is_csrr || is_csrw || is_sys) assert (d.imm16 == imm16);
    if (is_tpoll || is_csrr) assert (d.rd == f_rd);
    if (is_csrw || is_tany)  assert (d.rs1 == f_rs1);
    if (is_tany) assert (d.rd == f_rd);
    if (is_tamo && legal) begin
      assert (d.amo_op == funct[2:0] && d.cs == funct[10:7]);
      assert (d.rd == f_rd && d.rs1 == f_rs1 && d.rs2 == f_rs2);
    end
    if ((is_cap || is_cap2) && legal) begin
      assert (d.cap_fn == fn && d.slot == funct[10:5] && d.flag == funct[4]);
      assert (d.rd == f_rd && d.rs1 == f_rs1 && d.rs2 == f_rs2);
    end
    if (is_ltag)  assert (d.rd == f_rd && d.rs1 == f_rs1);
    if (is_linst) assert (d.rs1 == f_rs1);
    if (is_xmap && legal) assert (d.rd == f_rd && d.rs1 == f_rs1 && d.rs2 == f_rs2 && d.cs == fn && d.flag == funct[4]);
    if (is_xcall) assert (d.rd == f_rd && d.rs1 == f_rs1 && d.cs == fn && d.flag == funct[4]);

    // ---- the register-file read ports: a transfer reads its three
    // registers, everything else rs1, rs2 and (as a third operand) rd
    if (legal) begin
      assert (d.pa == (is_xfer ? ir[18:14] : d.rs1));
      assert (d.pb == (is_xfer ? ir[9:5]   : d.rs2));
      assert (d.pc == (is_xfer ? ir[4:0]   : d.rd));
    end

    // ---- not vacuous: every kind is produced, and every way of being illegal
    cover (d.kind == K_ALU);    cover (d.kind == K_ALUI);  cover (d.kind == K_LUI);
    cover (d.kind == K_LOAD);   cover (d.kind == K_STORE); cover (d.kind == K_BRANCH);
    cover (d.kind == K_JAL);    cover (d.kind == K_JALR);  cover (d.kind == K_XFER);
    cover (d.kind == K_TWAIT);  cover (d.kind == K_TPOLL); cover (d.kind == K_TAMO);
    cover (d.kind == K_CAP);    cover (d.kind == K_CSRR);  cover (d.kind == K_CSRW);
    cover (d.kind == K_SYS);    cover (d.kind == K_LTAG);  cover (d.kind == K_LINST);
    cover (d.kind == K_XMAP);   cover (d.kind == K_XCALL); cover (d.kind == K_CAP2);
    cover (d.kind == K_TANY);
    cover (d.kind == K_ILLEGAL && is_alu);
    cover (d.kind == K_ILLEGAL && is_xfer);
    cover (d.kind == K_ILLEGAL && is_tamo);
    cover (d.kind == K_ILLEGAL && is_cap && f_rd[4]);
    cover (d.kind == K_ILLEGAL && is_cap && f_rs1[4]);
    cover (d.kind == K_CAP && f_rd[4]);       // an integer rd above 15 (cbase ...)
    cover (d.kind == K_ILLEGAL && is_cap2);
    cover (d.kind == K_ILLEGAL && is_sys);
    cover (d.kind == K_ILLEGAL && is_xmap);
    cover (d.kind == K_ILLEGAL && op == 6'h3f);
  end
endmodule
