// Strata: a cycle profiler for one core (simulation only, research/smart-memory).
//
// Bound into every strata_core (the `bind` at the end; rtl/ is not changed).
// It counts, per core, where the cycles go and what touches the Local
// Stores, and prints one block of `key value` lines per core when the
// simulation ends (prefix "PROF <core>"). research/smart-memory/prof/report.py
// turns the blocks into tables.

module ls_prof
  import strata_pkg::*;
#(
  parameter int COREID = 0,
  parameter int DLS_WORDS = 8192,
  parameter int ILS_WORDS = 8192
)(
  input logic        clk,
  input logic        rst,
  input logic [3:0]  state,
  input dec_t        d,
  input logic        user,
  input logic [63:0] csr_instret,
  input logic [63:0] pc,
  input logic [63:0] maddr,
  input logic        mok,
  // Local Store ports
  input logic        ia_en,
  input logic [12:0] ia_addr,
  input logic        da_en,
  input logic [7:0]  da_we,
  input logic [12:0] da_addr,
  input logic        dls_b_en,
  input logic [7:0]  dls_b_we,
  input logic        ils_b_en,
  input logic        rl_v,
  // hazards and the Transfer Unit
  input logic        hz_rd_stall,
  input logic        hz_wr_stall,
  input logic        hz_fetch_stall,
  input logic        tu_cc_busy,
  input logic        tu_do_issue,
  input logic [2:0]  tu_iss_kind,
  input logic [2:0]  tu_iss_space,
  input logic [LSW-1:0] tu_iss_len,
  input logic [2:0]  tu_es,
  input logic        tu_idle,
  input logic        tu_b_rvalid,
  input logic        tu_pop
);
  // the core's states (strata_core's state_t)
  localparam logic [3:0] S_RST = 0, S_F0 = 1, S_F1 = 2, S_EX = 3, S_CT = 4, S_LD = 5, S_LG = 6, S_LT = 7,
                         S_LW = 8, S_DV = 9, S_AM = 10, S_HALT = 11, S_RQ = 12;
  localparam int NK = 23;

  longint n_state [16];
  longint n_ex_kind [NK];      // S_EX cycles by instruction kind (the last of them retires or traps)
  longint n_ret_kind [NK];     // instructions retired by kind
  longint n_ret_user, n_ret_sup;
  longint n_cyc_user, n_cyc_sup;           // cycles that are not S_HALT / S_RST
  longint n_f0_stall;                      // S_F0 cycles that did not go on to S_F1
  longint n_hz_rd, n_hz_wr;                // S_EX cycles a load / store waited for the Transfer Unit
  // Local Store port activity
  longint n_ia, n_da_rd, n_da_wr, n_db_rd, n_db_wr, n_ib_wr;
  longint n_d_both, n_i_both;              // both ports of a store used in the same cycle
  longint n_d_any, n_i_any;                // a store used at all
  longint n_lt_rd, n_lt_wr;                // of port A: the tag-lookup sequencer's
  // what one single-port memory holding both stores would see
  longint n_u_any, n_u_conf;               // used at all; the core and the unit in the same cycle
  longint n_ia_same;                       // fetches of the 64-bit word fetched last (its other instruction)
  logic [12:0] ia_last;
  logic        ia_last_v;
  // Transfer Unit
  longint n_tu_es [8];
  longint n_tu_busy;                       // cycles with a transfer queued or under way
  longint n_iss [4][8];                    // commands by kind, space
  longint n_iss_bytes [4][8];
  longint n_iss_sup [4], n_iss_sup_bytes [4];
  longint n_beat_get, n_beat_put;
  // instruction pairs (for memory-operand instructions)
  logic [4:0]  last_kind, last_rd, last2_kind;
  logic [63:0] last_maddr, last2_maddr;
  logic [4:0]  last_alu_rd;
  longint n_ld_use;            // a load whose result the next instruction (ALU, immediate, branch) reads
  longint n_ld_op_st;          // load; ALU; store to the same address
  longint n_ld_sp, n_st_sp;    // loads / stores relative to sp or gp (x2, x3)
  longint n_ld8, n_st8;        // 64-bit ones
  // where the accesses fall: 1 KiB bins
  longint h_d [64];
  longint h_i [64];

  logic [63:0] ir_q;
  logic        retired;
  assign retired = csr_instret != ir_q;

  always_ff @(posedge clk) begin
    ir_q <= csr_instret;
    if (!rst) begin
      n_state[state] <= n_state[state] + 1;
      if (state != S_HALT && state != S_RST) begin
        if (user) n_cyc_user <= n_cyc_user + 1; else n_cyc_sup <= n_cyc_sup + 1;
      end
      if (state == S_EX && int'(d.kind) < NK) n_ex_kind[d.kind] <= n_ex_kind[d.kind] + 1;
      if (state == S_F0 && (hz_fetch_stall || tu_cc_busy)) n_f0_stall <= n_f0_stall + 1;
      if (state == S_EX && d.kind == K_LOAD && mok && hz_rd_stall) n_hz_rd <= n_hz_rd + 1;
      if (state == S_EX && d.kind == K_STORE && mok && hz_wr_stall) n_hz_wr <= n_hz_wr + 1;

      // ports
      if (ia_en) begin n_ia <= n_ia + 1; h_i[ia_addr[12:7]] <= h_i[ia_addr[12:7]] + 1; end
      if (da_en) begin
        if (da_we != 0) n_da_wr <= n_da_wr + 1; else n_da_rd <= n_da_rd + 1;
        h_d[da_addr[12:7]] <= h_d[da_addr[12:7]] + 1;
        if (state == S_LT) n_lt_rd <= n_lt_rd + 1;
        if (state == S_LW) n_lt_wr <= n_lt_wr + 1;
      end
      if (dls_b_en && !rl_v) begin
        if (dls_b_we != 0) n_db_wr <= n_db_wr + 1; else n_db_rd <= n_db_rd + 1;
      end
      if (ils_b_en && !rl_v) n_ib_wr <= n_ib_wr + 1;
      if (da_en && dls_b_en && !rl_v) n_d_both <= n_d_both + 1;
      if (ia_en && ils_b_en && !rl_v) n_i_both <= n_i_both + 1;
      if (da_en || (dls_b_en && !rl_v)) n_d_any <= n_d_any + 1;
      if (ia_en || (ils_b_en && !rl_v)) n_i_any <= n_i_any + 1;
      if (ia_en || da_en || ((dls_b_en || ils_b_en) && !rl_v)) n_u_any <= n_u_any + 1;
      if ((ia_en || da_en) && (dls_b_en || ils_b_en) && !rl_v) n_u_conf <= n_u_conf + 1;
      if (ia_en) begin
        if (ia_last_v && ia_last == ia_addr) n_ia_same <= n_ia_same + 1;
        ia_last   <= ia_addr;
        ia_last_v <= 1;
      end
      if (ils_b_en) ia_last_v <= 0;

      // Transfer Unit
      n_tu_es[tu_es] <= n_tu_es[tu_es] + 1;
      if (!tu_idle) n_tu_busy <= n_tu_busy + 1;
      if (tu_do_issue && tu_iss_kind < 3) begin
        n_iss[tu_iss_kind[1:0]][tu_iss_space]       <= n_iss[tu_iss_kind[1:0]][tu_iss_space] + 1;
        n_iss_bytes[tu_iss_kind[1:0]][tu_iss_space] <= n_iss_bytes[tu_iss_kind[1:0]][tu_iss_space] + longint'(tu_iss_len);
        if (!user) begin
          n_iss_sup[tu_iss_kind[1:0]]       <= n_iss_sup[tu_iss_kind[1:0]] + 1;
          n_iss_sup_bytes[tu_iss_kind[1:0]] <= n_iss_sup_bytes[tu_iss_kind[1:0]] + longint'(tu_iss_len);
        end
      end
      if (tu_es == 3'd2 && tu_b_rvalid) n_beat_get <= n_beat_get + 1;
      if (tu_pop) n_beat_put <= n_beat_put + 1;

      // retired instructions (dq: the instruction of the cycle before, the one that retired;
      // with STREAM the next one may already be in ir)
      if (retired && int'(dq.kind) < NK) begin
        n_ret_kind[dq.kind] <= n_ret_kind[dq.kind] + 1;
        if (user) n_ret_user <= n_ret_user + 1; else n_ret_sup <= n_ret_sup + 1;
        if (last_kind == 5'(K_LOAD) && last_rd != 0 &&
            (((dq.kind == K_ALU || dq.kind == K_BRANCH) && (dq.rs1 == last_rd || dq.rs2 == last_rd)) ||
             (dq.kind == K_ALUI && dq.rs1 == last_rd)))
          n_ld_use <= n_ld_use + 1;
        if (dq.kind == K_STORE && (last_kind == 5'(K_ALU) || last_kind == 5'(K_ALUI)) && last2_kind == 5'(K_LOAD) &&
            last2_maddr == maddr_q && dq.rs2 == last_alu_rd)
          n_ld_op_st <= n_ld_op_st + 1;
        if (dq.kind == K_LOAD) begin
          if (dq.rs1 == 5'd2 || dq.rs1 == 5'd3) n_ld_sp <= n_ld_sp + 1;
          if (dq.msize == 2'd3) n_ld8 <= n_ld8 + 1;
        end
        if (dq.kind == K_STORE) begin
          if (dq.rs1 == 5'd2 || dq.rs1 == 5'd3) n_st_sp <= n_st_sp + 1;
          if (dq.msize == 2'd3) n_st8 <= n_st8 + 1;
        end
        last2_kind  <= last_kind;
        last2_maddr <= last_maddr;
        last_kind   <= 5'(dq.kind);
        last_rd     <= dq.rd;
        last_alu_rd <= dq.rd;
        last_maddr  <= ex_maddr;
      end
    end
  end

  // the address of a load / store is ra + imm in S_EX; a load retires in S_LD
  // (ra may have been its own rd), so keep the address seen in S_EX
  logic [63:0] ex_maddr, maddr_q;
  dec_t        dq;
  always_ff @(posedge clk) if (state == S_EX) ex_maddr <= maddr;
  // a store retires in S_EX: its address is the maddr of the cycle before
  always_ff @(posedge clk) begin
    dq      <= d;
    maddr_q <= maddr;
  end

  function automatic string kname(input int k);
    case (k)
      0: return "illegal"; 1: return "alu"; 2: return "alui"; 3: return "lui"; 4: return "load";
      5: return "store"; 6: return "branch"; 7: return "jal"; 8: return "jalr"; 9: return "xfer";
      10: return "twait"; 11: return "tpoll"; 12: return "tamo"; 13: return "cap"; 14: return "csrr";
      15: return "csrw"; 16: return "sys"; 17: return "ltag"; 18: return "linst"; 19: return "xmap";
      20: return "xcall"; 21: return "cap2"; 22: return "tany";
      default: return "?";
    endcase
  endfunction

  final begin
    static string xk [3] = '{"get", "put", "getx"};
    $display("PROF %0d words %0d %0d", COREID, DLS_WORDS, ILS_WORDS);
    for (int i = 0; i < 13; i++) $display("PROF %0d state %0d %0d", COREID, i, n_state[i]);
    for (int i = 0; i < NK; i++)
      if (n_ex_kind[i] != 0) $display("PROF %0d kind %s %0d %0d", COREID, kname(i), n_ex_kind[i], n_ret_kind[i]);
    $display("PROF %0d mode %0d %0d %0d %0d", COREID, n_cyc_user, n_cyc_sup, n_ret_user, n_ret_sup);
    $display("PROF %0d stall %0d %0d %0d", COREID, n_f0_stall, n_hz_rd, n_hz_wr);
    $display("PROF %0d ports %0d %0d %0d %0d %0d %0d", COREID, n_ia, n_da_rd, n_da_wr, n_db_rd, n_db_wr, n_ib_wr);
    $display("PROF %0d share %0d %0d %0d %0d %0d %0d", COREID, n_d_both, n_i_both, n_d_any, n_i_any, n_lt_rd, n_lt_wr);
    $display("PROF %0d unified %0d %0d %0d", COREID, n_u_any, n_u_conf, n_ia_same);
    for (int i = 0; i < 5; i++) $display("PROF %0d tues %0d %0d", COREID, i, n_tu_es[i]);
    $display("PROF %0d tubusy %0d %0d %0d", COREID, n_tu_busy, n_beat_get, n_beat_put);
    for (int k = 0; k < 3; k++) begin
      for (int s = 0; s < 8; s++)
        if (n_iss[k][s] != 0) $display("PROF %0d iss %s %0d %0d %0d", COREID, xk[k], s, n_iss[k][s], n_iss_bytes[k][s]);
      $display("PROF %0d isssup %s %0d %0d", COREID, xk[k], n_iss_sup[k], n_iss_sup_bytes[k]);
    end
    $display("PROF %0d pairs %0d %0d %0d %0d %0d %0d", COREID, n_ld_use, n_ld_op_st, n_ld_sp, n_st_sp, n_ld8, n_st8);
    for (int i = 0; i < 64; i++)
      if (h_d[i] != 0 || h_i[i] != 0) $display("PROF %0d hist %0d %0d %0d", COREID, i, h_d[i], h_i[i]);
  end
endmodule

bind strata_core ls_prof #(.COREID(COREID), .DLS_WORDS(DLS_WORDS), .ILS_WORDS(ILS_WORDS)) u_ls_prof (
  .clk, .rst, .state(state), .d, .user, .csr_instret, .pc, .maddr, .mok,
  .ia_en, .ia_addr, .da_en, .da_we, .da_addr,
  .dls_b_en(tu_dls_en), .dls_b_we(tu_dls_we), .ils_b_en(tu_ils_en), .rl_v,
  .hz_rd_stall, .hz_wr_stall, .hz_fetch_stall, .tu_cc_busy,
  .tu_do_issue(u_tu.do_issue), .tu_iss_kind(d.xf_sub), .tu_iss_space(xcap.space), .tu_iss_len(LSW'(rc)),
  .tu_es(u_tu.es), .tu_idle, .tu_b_rvalid(tu_rvalid), .tu_pop(u_tu.pop)
);
