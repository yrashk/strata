// Strata: system top level (synthesizable).
//
// NCORES cores, the far bus, system memory (T3), the cluster store (T2) and
// device space, plus the capability inboxes. Node numbers for cgive/ctake:
// cores 0..NCORES-1, block device 0 = NCORES (NCORES <= 15: 16 senders, the
// width of the cpoll / tany masks). Each core's inbox holds up to
// two gifts per sender and accepts one gift per cycle; `ctake cd, rs` takes
// the oldest from one sender, `ctake cd` the oldest from the lowest-numbered
// sender that has one.

module strata_top
  import strata_pkg::*;
#(
  parameter int    NCORES     = 4,
  parameter int    NXMAP      = NXMAP_DEF,  // overlay map entries per core (4..16)
  parameter int    DLS_KIB    = LS_DEF_KIB, // each core's D-LS and I-LS in KiB (powers of two, 4..64)
  parameter int    ILS_KIB    = LS_DEF_KIB,
  parameter int    T3_W       = T3_WORDS,
  parameter int    T3_LAT     = 20,
  parameter int    T2_W       = T2_WORDS,
  parameter int    T2_LAT     = 4,
  parameter int    DISK_WORDS = 2097152,
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
  logic [7:0]          dev_in_from;    // the core that gives it (the device pairs it with that core's command)

  logic [NCORES-1:0]       take_req, take_any, take_hit, take_pop, halted;
  logic [NCORES-1:0][7:0]  take_src, take_from;
  cap_t                    take_cap [NCORES];
  logic [NCORES-1:0][15:0] poll_mask;

  // revocation granules and core control
  logic [NCORES-1:0]          dom_req, dom_done, dom_t2, stop_req, reset_req, reset_flush;
  logic [NCORES-1:0][1:0]     dom_op;
  logic [NCORES-1:0][GW-1:0]  dom_a, dom_n;
  logic [15:0]                dom_gen;
  logic                       gt_we, gt_t2;
  logic [GW-1:0]              gt_idx;
  logic [16:0]                gt_wd;

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
    .in_push(dev_in_push), .in_cap(dev_in_cap), .in_from(dev_in_from), .in_ready(dev_in_ready),
    .core_clr(reset_flush),
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

    strata_core #(.COREID(i), .NCORES(NCORES), .NXMAP(NXMAP), .DLS_KIB(DLS_KIB), .ILS_KIB(ILS_KIB),
                  .ILS_INIT(ILS_INIT), .DLS_INIT(DLS_INIT)) u_core (
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
      .dom_req(dom_req[i]), .dom_op(dom_op[i]), .dom_t2(dom_t2[i]), .dom_a(dom_a[i]), .dom_n(dom_n[i]),
      .dom_done(dom_done[i]), .dom_gen, .gt_we, .gt_t2, .gt_idx, .gt_wd, .stop_req(stop_req[i]),
      .reset_req(reset_req[i]), .reset_flush(reset_flush[i]),
      .halted(halted[i])
    );
  end

  assign all_halted = &halted;

  // ================================================================ revocation granules
  // The machine's granule table: a {head, generation} entry per 256 KiB of T3
  // and T2. This master copy is read only by the walker below; every write
  // also goes to each core's copy (gt_we ...), which its capability checks
  // read. One operation at a time, for the lowest-numbered core that asks:
  //   cdom    [a, b): read pass (highest generation m), write pass (m + 1;
  //           head at a only), then a head at b, the unit's end
  //   crevoke / cundom [a, b): walk back from a to the head of its unit (lo),
  //           read on to the end of the unit holding b - 1 (hi), then write
  //           [lo, hi): m + 1, heads at lo, a and b
  // A walk takes one cycle per granule; the core waits in EX meanwhile.
  typedef enum logic [2:0] {W_IDLE, W_BACK, W_READ, W_WRITE, W_TAIL, W_DONE} walk_t;
  localparam int CW = NCORES > 1 ? $clog2(NCORES) : 1;
  logic [16:0]   mt3 [NG3];
  logic [16:0]   mt2 [NG2];
  walk_t         ws;
  logic [CW-1:0] w_who;
  logic [1:0]    w_op;
  logic          w_t2;
  logic [GW-1:0] w_a, w_b, w_lo, w_hi, w_k, w_end;
  logic [15:0]   w_m;
  logic [16:0]   w_e;                                 // the entry at w_k
  logic          w_any;
  logic [CW-1:0] w_first;
`ifdef SIMULATION
  initial begin
    for (int i = 0; i < NG3; i++) mt3[i] = '0;
    for (int i = 0; i < NG2; i++) mt2[i] = '0;
  end
`endif
  assign w_end = w_t2 ? GW'(NG2) : GW'(NG3);
  assign w_e   = w_k >= w_end ? 17'b0 : w_t2 ? mt2[G2W'(w_k)] : mt3[G3W'(w_k)];
  always_comb begin
    w_any   = 0;
    w_first = '0;
    for (int c = NCORES - 1; c >= 0; c--)
      if (dom_req[c]) begin w_any = 1; w_first = CW'(c); end
    dom_done = '0;
    if (ws == W_DONE) dom_done[w_who] = 1;
    gt_we  = ws == W_WRITE || (ws == W_TAIL && w_hi < w_end);
    gt_t2  = w_t2;
    gt_idx = ws == W_TAIL ? w_hi : w_k;
    gt_wd  = ws == W_TAIL ? {1'b1, w_e[15:0]}
             : {w_k == w_lo || w_k == w_a || w_k == w_b, w_m + 16'd1};
  end
  assign dom_gen = w_m + 16'd1;

  always_ff @(posedge clk) begin
    if (gt_we) begin
      if (gt_t2) mt2[G2W'(gt_idx)] <= gt_wd;
      else       mt3[G3W'(gt_idx)] <= gt_wd;
    end
    if (rst) ws <= W_IDLE;
    else case (ws)
      W_IDLE: if (w_any) begin
        w_who <= w_first;
        w_op  <= dom_op[w_first];
        w_t2  <= dom_t2[w_first];
        w_a   <= dom_a[w_first];
        w_b   <= dom_a[w_first] + dom_n[w_first];
        w_k   <= dom_a[w_first];
        w_lo  <= dom_a[w_first];
        w_m   <= '0;
        ws    <= dom_op[w_first] == 2'd0 ? W_READ : W_BACK;
      end
      W_BACK: if (w_e[16] || w_k == 0) begin       // the head of the unit holding a
        w_lo <= w_k;
        ws   <= W_READ;
      end else w_k <= w_k - 1;
      W_READ: if (w_op == 2'd0 ? w_k == w_b : w_k >= w_b && (w_k >= w_end || w_e[16])) begin
        w_hi <= w_k;
        w_k  <= w_lo;
        ws   <= W_WRITE;
      end else begin
        if (w_e[15:0] > w_m) w_m <= w_e[15:0];
        w_k <= w_k + 1;
      end
      W_WRITE: begin
        w_k <= w_k + 1;
        if (w_k + 1 == w_hi) ws <= w_op == 2'd0 ? W_TAIL : W_DONE;
      end
      W_TAIL: ws <= W_DONE;                         // cdom: the unit ends at b
      W_DONE: ws <= W_IDLE;
      default: ws <= W_IDLE;
    endcase
  end

  // ================================================================ core control
  // A far-bus target: a written word with bit 0 set asks core (address / 8)
  // to stop, with bit 1 set to restart (a reset request: the core's inbox is
  // emptied now, so a gift made after the request reaches the restarted
  // core; the core takes the request itself, see strata_core). Reads return
  // zeros.
  logic        cc_busy, cc_we;
  logic [63:0] cc_addr;
  logic [23:0] cc_left;
  always_comb begin
    stop_req     = '0;
    reset_req    = '0;
    t_wready[3]  = cc_busy && cc_we;
    t_rvalid[3]  = cc_busy && !cc_we;
    t_rdata[3]   = '0;
    t_retry[3]   = 0;
    t_done[3]    = cc_busy && cc_left == 1 && (cc_we ? t_wvalid : 1'b1);
    for (int c = 0; c < NCORES; c++)
      if (cc_busy && cc_we && t_wvalid && cc_addr[63:3] == 61'(c)) begin
        if (t_wdata[0]) stop_req[c] = 1;
        if (t_wdata[1]) reset_req[c] = 1;
      end
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
  // The queues of one core share one small RAM (entry s * SQ + k: sender s's
  // k-th slot) with one write port and an asynchronous read port, plus a
  // head and a count per sender: a core takes at most one gift per cycle
  // (the lowest-numbered sender with room; the others wait a cycle).
  localparam int SQ  = 2;
  localparam int SQW = $clog2(SQ);
  localparam int IBW = $clog2(NS * SQ);
  logic [SQW-1:0] ib_h [NCORES][NS];   // the oldest gift's slot
  logic [1:0]     ib_n [NCORES][NS];   // gifts held
  logic [NCORES-1:0]         ib_we;
  logic [NCORES-1:0][7:0]    ib_ws;    // the sender written

  // gifts: per destination core, the lowest-numbered sender with room in its
  // queue there is accepted; the block device's single queue likewise
  always_comb begin
    g_ack       = '0;
    dev_in_push = 0;
    dev_in_cap  = CAP_NULL;
    dev_in_from = '0;
    ib_we       = '0;
    ib_ws       = '0;
    for (int c = 0; c < NCORES; c++)
      for (int s = 0; s < NS; s++)
        if (!ib_we[c] && g_valid[s] && int'(g_dst[s]) == c && ib_n[c][s] < 2'(SQ)) begin
          g_ack[s] = 1;
          ib_we[c] = 1;
          ib_ws[c] = 8'(s);
        end
    for (int s = 0; s < NS; s++)
      if (!dev_in_push && dev_in_ready && g_valid[s] && int'(g_dst[s]) == NCORES) begin
        g_ack[s]    = 1;
        dev_in_push = 1;
        dev_in_cap  = g_cap[s];
        dev_in_from = 8'(s);
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
    cap_t           ram [NS * SQ];
    logic [NS-1:0]  nz;
    logic [IBW-1:0] wa, ra;
    cap_t           wd;
    for (genvar s = 0; s < NS; s++) begin : g_nz
      assign nz[s] = ib_n[c][s] != 0;
    end
    assign poll_mask[c] = 16'(nz);
    assign take_s[c]    = take_any[c] ? lowest(nz) : take_src[c];
    assign take_from[c] = take_s[c];
    always_comb begin
      logic [SQW-1:0] h, k;
      take_hit[c] = 0;
      ra = '0;
      h  = '0;
      k  = '0;
      wd = CAP_NULL;
      wa = '0;
      for (int s = 0; s < NS; s++) begin
        if (take_s[c] == 8'(s) && nz[s]) begin
          take_hit[c] = take_req[c];
          h  = ib_h[c][s];
          ra = IBW'(s * SQ) + IBW'(h);
        end
        if (ib_ws[c] == 8'(s)) begin
          k  = SQW'(ib_h[c][s] + SQW'(ib_n[c][s]));       // the tail
          wa = IBW'(s * SQ) + IBW'(k);
          wd = g_cap[s];
        end
      end
    end
    assign take_cap[c] = ram[ra];
    always_ff @(posedge clk) if (ib_we[c]) ram[wa] <= wd;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int c = 0; c < NCORES; c++)
        for (int s = 0; s < NS; s++) begin
          ib_n[c][s] <= '0;
          ib_h[c][s] <= '0;
        end
    end else begin
      for (int c = 0; c < NCORES; c++)
        for (int s = 0; s < NS; s++) begin
          logic pop, push;
          pop  = take_pop[c] && int'(take_s[c]) == s;
          push = ib_we[c] && int'(ib_ws[c]) == s;
          if (pop) ib_h[c][s] <= ib_h[c][s] + SQW'(1);
          ib_n[c][s] <= ib_n[c][s] + (push ? 2'd1 : 2'd0) - (pop ? 2'd1 : 2'd0);
          if (reset_req[c]) ib_n[c][s] <= '0;              // a reset request empties the inbox
        end
    end
  end
endmodule
