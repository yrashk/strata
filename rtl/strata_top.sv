// Strata: system top level (synthesizable).
//
// NCORES cores, the far bus, system memory (T3), the cluster store (T2) and
// device space, plus the capability inboxes. Node numbers for cgive/ctake:
// cores 0..NCORES-1, block device 0 = NCORES (NCORES <= 15: 16 senders, the
// width of the cpoll / tany masks). Each core's inbox holds up to
// two gifts per sender; `ctake cd, rs` takes the oldest from one sender,
// `ctake cd` the oldest from the lowest-numbered sender that has one.

module strata_top
  import strata_pkg::*;
#(
  parameter int    NCORES     = 4,
  parameter int    T3_W       = T3_WORDS,
  parameter int    T3_LAT     = 20,
  parameter int    T2_W       = T2_WORDS,
  parameter int    T2_LAT     = 4,
  parameter int    DISK_WORDS = 524288,
  parameter string ILS_INIT   = "",
  parameter string DLS_INIT   = "",
  parameter string DISK_INIT  = "",
  parameter string PLAT_INIT  = "",
  parameter int    UART_DIV   = 868,
  parameter int    CLK_MHZ    = 100,    // clock frequency: cycles per timer tick (1 us)
  parameter bit    T3_EXT     = 0       // 1: system memory is outside (the ext_t3 port, e.g. DRAM)
)(
  input  logic clk,
  input  logic rst,
  output logic all_halted,
  output logic uart_txd,
  input  logic uart_rxd,

  // system memory target port, used when T3_EXT (see strata_mem for the protocol)
  output logic        ext_t3_start,
  output logic        ext_t3_we,
  output logic        ext_t3_amo,
  output logic [2:0]  ext_t3_amo_op,
  output logic [63:0] ext_t3_addr,
  output logic [23:0] ext_t3_beats,
  output logic [63:0] ext_t3_cmp,
  output logic        ext_t3_wvalid,
  output logic [63:0] ext_t3_wdata,
  input  logic        ext_t3_wready,
  input  logic        ext_t3_rvalid,
  input  logic [63:0] ext_t3_rdata,
  input  logic        ext_t3_done
);
  localparam int NM = 2 * NCORES + 1;   // TU of core i = 2i, atomics of core i = 2i+1, disk DMA = 2N
  localparam int NS = NCORES + 1;       // gift senders / receivers: the cores and the disk

  // ================================================================ far bus
  logic [NM-1:0]       m_req, m_we, m_amo, m_byte, m_wvalid, m_gnt, m_wready, m_rvalid, m_done, m_retry;
  logic [NM-1:0][2:0]  m_op, m_space;
  logic [NM-1:0][63:0] m_addr, m_cmp, m_wdata;
  logic [NM-1:0][23:0] m_beats;
  logic [63:0]         m_rdata;

  logic [3:0]          t_start, t_wready, t_rvalid, t_done, t_retry;
  logic [7:0]          t_master;
  logic                t_we, t_amo, t_byte, t_wvalid;
  logic [2:0]          t_op;
  logic [63:0]         t_addr, t_cmp, t_wdata;
  logic [23:0]         t_beats;
  logic [3:0][63:0]    t_rdata;

  strata_bus #(.NM(NM)) u_bus (
    .clk, .rst,
    .m_req, .m_we, .m_amo, .m_amo_op(m_op), .m_space, .m_addr, .m_beats, .m_byte, .m_cmp,
    .m_wvalid, .m_wdata, .m_gnt, .m_wready, .m_rvalid, .m_rdata, .m_done, .m_retry,
    .t_start, .t_master, .t_we, .t_amo, .t_amo_op(t_op), .t_addr, .t_beats, .t_byte, .t_cmp,
    .t_wvalid, .t_wdata, .t_wready, .t_rvalid, .t_rdata, .t_done, .t_retry
  );

  assign ext_t3_start  = T3_EXT && t_start[0];
  assign ext_t3_we     = t_we;
  assign ext_t3_amo    = t_amo;
  assign ext_t3_amo_op = t_op;
  assign ext_t3_addr   = t_addr;
  assign ext_t3_beats  = t_beats;
  assign ext_t3_cmp    = t_cmp;
  assign ext_t3_wvalid = t_wvalid;
  assign ext_t3_wdata  = t_wdata;
  if (T3_EXT) begin : g_t3_ext
    assign t_wready[0] = ext_t3_wready;
    assign t_rvalid[0] = ext_t3_rvalid;
    assign t_rdata[0]  = ext_t3_rdata;
    assign t_done[0]   = ext_t3_done;
  end else begin : g_t3_int
    strata_mem #(.WORDS(T3_W), .LAT(T3_LAT), .KIND(3)) u_t3 (
      .clk, .rst, .start(t_start[0]), .we(t_we), .amo(t_amo), .amo_op(t_op), .addr(t_addr),
      .beats(t_beats), .cmp(t_cmp), .wvalid(t_wvalid), .wdata(t_wdata), .wready(t_wready[0]),
      .rvalid(t_rvalid[0]), .rdata(t_rdata[0]), .done(t_done[0])
    );
  end
  assign t_retry[0] = 0;

  strata_mem #(.WORDS(T2_W), .LAT(T2_LAT), .KIND(4)) u_t2 (
    .clk, .rst, .start(t_start[1]), .we(t_we), .amo(t_amo), .amo_op(t_op), .addr(t_addr),
    .beats(t_beats), .cmp(t_cmp), .wvalid(t_wvalid), .wdata(t_wdata), .wready(t_wready[1]),
    .rvalid(t_rvalid[1]), .rdata(t_rdata[1]), .done(t_done[1])
  );
  assign t_retry[1] = 0;

  // ================================================================ gifts
  logic [NS-1:0]       g_valid, g_ack;
  logic [NS-1:0][7:0]  g_dst;
  cap_t                g_cap [NS];
  logic                dev_in_ready, dev_in_push;
  cap_t                dev_in_cap;

  logic [NCORES-1:0]       take_req, take_any, take_hit, take_pop, halted;
  logic [NCORES-1:0][7:0]  take_src, take_from;
  cap_t                    take_cap [NCORES];
  logic [NCORES-1:0][15:0] poll_mask;

  // revocation domains and core control
  logic [NDOMS-1:0]        dom_alive;
  logic [NDOMS-1:0][15:0]  dom_gen;
  cap_t                    dom_reg [NDOMS];
  logic [NCORES-1:0]       dom_req, dom_grant, stop_req;
  logic [NCORES-1:0][1:0]  dom_op;
  logic [NCORES-1:0][3:0]  dom_idx;
  cap_t                    dom_region [NCORES];
  logic [3:0]              dom_free, dom_sel_idx;
  logic [15:0]             dom_new_gen;
  cap_t                    dom_stored;

  strata_dev #(.NCORES(NCORES), .DISK_WORDS(DISK_WORDS), .DISK_INIT(DISK_INIT),
                .PLAT_INIT(PLAT_INIT), .UART_DIV(UART_DIV), .CLK_MHZ(CLK_MHZ)) u_dev (
    .clk, .rst,
    .start(t_start[2]), .master(t_master), .we(t_we), .addr(t_addr), .beats(t_beats), .wvalid(t_wvalid),
    .wdata(t_wdata), .wready(t_wready[2]), .rvalid(t_rvalid[2]), .rdata(t_rdata[2]),
    .done(t_done[2]), .retry(t_retry[2]),
    .m_req(m_req[2*NCORES]), .m_we(m_we[2*NCORES]), .m_addr(m_addr[2*NCORES]),
    .m_wvalid(m_wvalid[2*NCORES]), .m_wdata(m_wdata[2*NCORES]), .m_gnt(m_gnt[2*NCORES]),
    .m_wready(m_wready[2*NCORES]), .m_rvalid(m_rvalid[2*NCORES]), .m_rdata(m_rdata),
    .m_done(m_done[2*NCORES]),
    .in_push(dev_in_push), .in_cap(dev_in_cap), .in_ready(dev_in_ready),
    .give_valid(g_valid[NCORES]), .give_dst(g_dst[NCORES]), .give_cap(g_cap[NCORES]),
    .give_ack(g_ack[NCORES]),
    .uart_txd, .uart_rxd
  );
  assign m_amo[2*NCORES]   = 0;
  assign m_op[2*NCORES]    = '0;
  assign m_space[2*NCORES] = SP_T3;
  assign m_beats[2*NCORES] = 24'd1;
  assign m_byte[2*NCORES]  = 0;
  assign m_cmp[2*NCORES]   = '0;

  // ================================================================ cores
  for (genvar i = 0; i < NCORES; i++) begin : g_core
    assign m_amo[2*i]      = 0;
    assign m_op[2*i]       = '0;
    assign m_cmp[2*i]      = '0;
    assign m_amo[2*i+1]    = 1;
    assign m_we[2*i+1]     = 0;
    assign m_byte[2*i+1]   = 0;
    assign m_beats[2*i+1]  = 24'd1;
    assign m_wvalid[2*i+1] = 0;

    strata_core #(.COREID(i), .NCORES(NCORES), .ILS_INIT(ILS_INIT), .DLS_INIT(DLS_INIT)) u_core (
      .clk, .rst,
      .tu_req(m_req[2*i]), .tu_we(m_we[2*i]), .tu_space(m_space[2*i]), .tu_addr(m_addr[2*i]),
      .tu_beats(m_beats[2*i]), .tu_byte(m_byte[2*i]), .tu_wvalid(m_wvalid[2*i]),
      .tu_wdata(m_wdata[2*i]), .tu_gnt(m_gnt[2*i]), .tu_wready(m_wready[2*i]),
      .tu_rvalid(m_rvalid[2*i]), .tu_done(m_done[2*i]), .tu_retry(m_retry[2*i]),
      .am_req(m_req[2*i+1]), .am_op(m_op[2*i+1]), .am_space(m_space[2*i+1]),
      .am_addr(m_addr[2*i+1]), .am_wdata(m_wdata[2*i+1]), .am_cmp(m_cmp[2*i+1]),
      .am_gnt(m_gnt[2*i+1]), .am_done(m_done[2*i+1]),
      .bus_rdata(m_rdata),
      .give_valid(g_valid[i]), .give_dst(g_dst[i]), .give_cap(g_cap[i]), .give_ack(g_ack[i]),
      .take_req(take_req[i]), .take_any(take_any[i]), .take_src(take_src[i]),
      .take_hit(take_hit[i]), .take_cap(take_cap[i]), .take_from(take_from[i]),
      .take_pop(take_pop[i]), .poll_mask(poll_mask[i]), .halted_vec(halted),
      .dom_alive, .dom_gen, .dom_req(dom_req[i]), .dom_op(dom_op[i]), .dom_idx(dom_idx[i]),
      .dom_region(dom_region[i]), .dom_grant(dom_grant[i]),
      .dom_new_idx(dom_op[i] == 2'd0 ? dom_free : dom_idx[i]), .dom_new_gen(dom_new_gen),
      .dom_stored(dom_stored), .stop_req(stop_req[i]),
      .halted(halted[i])
    );
  end

  assign all_halted = &halted;

  // ================================================================ revocation domains
  // One table for the whole machine. Each cycle the lowest-numbered core that
  // asks is granted: allocate (the lowest free domain), revoke (bump the
  // generation: every capability made earlier stops working) or dissolve
  // (revoke and free the domain).
  localparam int CW = NCORES > 1 ? $clog2(NCORES) : 1;
  logic          dom_any;
  logic [CW-1:0] dom_who;
  always_comb begin
    dom_free = 4'd0;
    for (int k = NDOMS - 1; k >= 1; k--)
      if (!dom_alive[k]) dom_free = 4'(k);
    dom_grant = '0;
    dom_any   = 0;
    dom_who   = '0;
    for (int c = NCORES - 1; c >= 0; c--)
      if (dom_req[c]) begin dom_any = 1; dom_who = CW'(c); end
    dom_sel_idx = '0;
    dom_new_gen = '0;
    dom_stored  = CAP_NULL;
    if (dom_any) begin
      dom_grant[dom_who] = 1;
      dom_sel_idx = dom_op[dom_who] == 2'd0 ? dom_free : dom_idx[dom_who];
      dom_new_gen = dom_gen[dom_sel_idx] + 16'd1;
      dom_stored  = dom_reg[dom_sel_idx];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      dom_alive <= '0;
      for (int k = 0; k < NDOMS; k++) dom_gen[k] <= '0;
    end else if (dom_any && dom_sel_idx != 0) begin
      dom_gen[dom_sel_idx] <= dom_new_gen;
      case (dom_op[dom_who])
        2'd0: begin
          dom_alive[dom_sel_idx] <= 1;
          dom_reg[dom_sel_idx]   <= dom_region[dom_who];
        end
        2'd2: dom_alive[dom_sel_idx] <= 0;
        default: ;
      endcase
    end
  end

  // ================================================================ core control
  // A far-bus target: a written word with bit 0 set asks core (address / 8)
  // to stop. Reads return zeros.
  logic        cc_busy, cc_we;
  logic [63:0] cc_addr;
  logic [23:0] cc_left;
  always_comb begin
    stop_req     = '0;
    t_wready[3]  = cc_busy && cc_we;
    t_rvalid[3]  = cc_busy && !cc_we;
    t_rdata[3]   = '0;
    t_retry[3]   = 0;
    t_done[3]    = cc_busy && cc_left == 1 && (cc_we ? t_wvalid : 1'b1);
    for (int c = 0; c < NCORES; c++)
      if (cc_busy && cc_we && t_wvalid && t_wdata[0] && cc_addr[63:3] == 61'(c)) stop_req[c] = 1;
  end
  always_ff @(posedge clk) begin
    if (rst) cc_busy <= 0;
    else if (t_start[3]) begin
      cc_busy <= t_beats != 0;
      cc_we   <= t_we;
      cc_addr <= t_addr;
      cc_left <= t_beats;
    end else if (cc_busy && (!cc_we || t_wvalid)) begin
      cc_addr <= cc_addr + 8;
      cc_left <= cc_left - 1;
      if (cc_left == 1) cc_busy <= 0;
    end
  end

  // ================================================================ inboxes
  // Each core's inbox keeps a small queue per sender (SQ deep), so a sender
  // can never fill the inbox and block a gift that `ctake cd, rs` waits for.
  localparam int SQ = 2;
  cap_t       ib_cap [NCORES][NS][SQ];
  logic [1:0] ib_n   [NCORES][NS];

  // gifts: every sender with room in its queue at the destination is accepted;
  // the block device's single queue takes the lowest-numbered sender
  always_comb begin
    g_ack       = '0;
    dev_in_push = 0;
    dev_in_cap  = CAP_NULL;
    for (int s = 0; s < NS; s++)
      for (int c = 0; c < NCORES; c++)
        if (g_valid[s] && int'(g_dst[s]) == c && ib_n[c][s] < 2'(SQ)) g_ack[s] = 1;
    for (int s = 0; s < NS; s++)
      if (!dev_in_push && dev_in_ready && g_valid[s] && int'(g_dst[s]) == NCORES) begin
        g_ack[s]    = 1;
        dev_in_push = 1;
        dev_in_cap  = g_cap[s];
      end
  end

  // take: from the named sender, or else the lowest-numbered one with a gift
  function automatic logic [7:0] lowest(input logic [NS-1:0] v);
    logic [7:0] r;
    r = 8'(NS);
    for (int k = 0; k < NS; k++)
      if (v[k] && r == 8'(NS)) r = 8'(k);
    return r;
  endfunction

  logic [NCORES-1:0][7:0] take_s;
  for (genvar c = 0; c < NCORES; c++) begin : g_take
    logic [NS-1:0] nz;
    for (genvar s = 0; s < NS; s++) begin : g_nz
      assign nz[s] = ib_n[c][s] != 0;
    end
    assign poll_mask[c] = 16'(nz);
    assign take_s[c]    = take_any[c] ? lowest(nz) : take_src[c];
    assign take_from[c] = take_s[c];
    always_comb begin
      take_hit[c] = 0;
      take_cap[c] = CAP_NULL;
      for (int s = 0; s < NS; s++)
        if (take_s[c] == 8'(s) && nz[s]) begin
          take_hit[c] = take_req[c];
          take_cap[c] = ib_cap[c][s][0];
        end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int c = 0; c < NCORES; c++)
        for (int s = 0; s < NS; s++) ib_n[c][s] <= '0;
    end else begin
      for (int c = 0; c < NCORES; c++)
        for (int s = 0; s < NS; s++) begin
          logic       pop, push;
          logic [1:0] n;
          pop  = take_pop[c] && int'(take_s[c]) == s;
          push = g_valid[s] && int'(g_dst[s]) == c && ib_n[c][s] < 2'(SQ);
          n    = ib_n[c][s];
          if (pop) begin
            for (int k = 0; k < SQ - 1; k++) ib_cap[c][s][k] <= ib_cap[c][s][k+1];
            n = n - 1;
          end
          if (push) ib_cap[c][s][n[0]] <= g_cap[s];        // n is 0 or 1 here
          ib_n[c][s] <= n + (push ? 2'd1 : 2'd0);
        end
    end
  end
endmodule
