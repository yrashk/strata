// Strata: Transfer Unit.
//
// Accepts transfer commands from the core in program order and executes them
// one at a time as far-bus bursts, so one core's transfers take effect at the
// far side in issue order. Far atomics do not go through the Transfer Unit;
// the core orders them by waiting until the unit is idle first.
//
// It also tells the core which Local Store ranges are still in flight. The
// core stalls any access that overlaps one; that stall is what makes every
// transfer behave as if it completed at issue:
//   get  : D-LS range written by the unit   -> loads and stores stall
//   put  : D-LS range read by the unit      -> stores stall
//   getx : I-LS range written by the unit   -> instruction fetch stalls
//
// Memory transfers move 8-byte words (bursts of len/8 beats); device
// transfers move single bytes.
//
// A command whose D-LS range overlaps a device read still in the queue (it
// may wait for the device and be rotated behind later commands) is not
// accepted until that read completes (iss_hz).

module strata_tu
  import strata_pkg::*;
(
  input  logic        clk,
  input  logic        rst,

  // command issue (from the core's execute stage)
  input  logic        iss_valid,
  input  logic [2:0]  iss_kind,
  input  logic [3:0]  iss_tag,
  input  logic [63:0] iss_ls,
  input  logic [2:0]  iss_space,
  input  logic [63:0] iss_far,
  input  logic [63:0] iss_len,
  output logic        iss_ready,
  output logic        iss_hz,       // the command's D-LS range overlaps an in-flight device read

  // status
  output logic [15:0] tag_busy,
  output logic        idle,
  output logic        mem_idle,     // no far-memory transfer in flight (what handing over a capability waits for)

  // hazard queries
  input  logic [63:0] hz_addr,
  input  logic [63:0] hz_len,
  output logic        hz_rd_stall,
  output logic        hz_wr_stall,
  input  logic [63:0] hz_pc,
  output logic        hz_fetch_stall,

  // Local Store port B (D-LS read/write, I-LS write)
  output logic        dls_en,
  output logic [7:0]  dls_we,
  output logic [12:0] dls_addr,
  output logic [63:0] dls_wdata,
  input  logic [63:0] dls_rdata,
  output logic        ils_en,
  output logic [12:0] ils_addr,
  output logic [63:0] ils_wdata,

  // far-bus master
  output logic        b_req,
  output logic        b_we,
  output logic [2:0]  b_space,
  output logic [63:0] b_addr,
  output logic [23:0] b_beats,
  output logic        b_byte,
  output logic        b_wvalid,
  output logic [63:0] b_wdata,
  input  logic        b_gnt,
  input  logic        b_wready,
  input  logic        b_rvalid,
  input  logic [63:0] b_rdata,
  input  logic        b_done,
  input  logic        b_retry
);
  localparam int QD = 4;

  logic [QD-1:0] q_v;
  logic [2:0]    q_kind [QD];
  logic [3:0]    q_tag  [QD];
  logic [63:0]   q_ls   [QD];
  logic [2:0]    q_sp   [QD];
  logic [63:0]   q_far  [QD];
  logic [63:0]   q_len  [QD];

  logic [1:0] head, tail;
  logic [2:0] count;

  typedef enum logic [2:0] {E_IDLE, E_REQ, E_XFER, E_RETIRE, E_ROT} estate_t;
  estate_t     es;
  logic [63:0] off;          // bytes moved so far
  logic [63:0] rd_off;       // put: next LS offset to read
  logic [1:0]  pf_cnt;       // put: words waiting in the prefetch buffer
  logic        pf_inflight;  // put: a Local Store read was issued last cycle
  logic [63:0] pf_rd_o;      // put: the offset that read belongs to
  logic [63:0] pf_d [2];
  logic [63:0] pf_o [2];     // the LS offset each prefetched word belongs to

  logic [2:0]  h_kind;
  logic [63:0] h_ls, h_far, h_len;
  logic [2:0]  h_sp;
  logic        h_dev, h_put, h_getx;
  logic [63:0] step;
  assign h_kind = q_kind[head];
  assign h_ls   = q_ls[head];
  assign h_far  = q_far[head];
  assign h_len  = q_len[head];
  assign h_sp   = q_sp[head];
  assign h_dev  = h_sp == SP_DEV;
  assign h_put  = h_kind == XF_PUT;
  assign h_getx = h_kind == XF_GETX;
  assign step   = h_dev ? 64'd1 : 64'd8;

  logic do_issue, do_retire;
  assign iss_ready = count < 3'(QD) && !tag_busy[iss_tag] && es != E_ROT && !iss_hz;
  assign do_issue  = iss_valid && iss_ready;
  assign do_retire = es == E_RETIRE;
  assign idle      = count == 0;
  always_comb begin
    mem_idle = 1;     // device transfers (a break read may wait forever) do not count
    for (int i = 0; i < QD; i++) if (q_v[i] && q_sp[i] != SP_DEV) mem_idle = 0;
  end

  // ------------------------------------------------------------ hazards
  function automatic logic overlap(input logic [63:0] a, input logic [63:0] al,
                                   input logic [63:0] b, input logic [63:0] bl);
    return al != 0 && bl != 0 && a < b + bl && b < a + al;
  endfunction

  // A device read may wait (and be rotated behind later commands): a command
  // whose D-LS range overlaps one waits at issue until it completes, so the
  // two take effect in issue order. (tgetx writes the I-LS: no overlap.)
  logic iss_hz_any;
  always_comb begin
    iss_hz_any = 0;
    for (int i = 0; i < QD; i++)
      if (q_v[i] && q_sp[i] == SP_DEV && q_kind[i] == XF_GET && overlap(q_ls[i], q_len[i], iss_ls, iss_len))
        iss_hz_any = 1;
  end
  assign iss_hz = iss_hz_any && iss_kind != XF_GETX;

  always_comb begin
    hz_rd_stall    = 0;
    hz_wr_stall    = 0;
    hz_fetch_stall = 0;
    for (int i = 0; i < QD; i++) begin
      if (q_v[i]) begin
        if (q_kind[i] == XF_GETX) begin
          if (overlap(q_ls[i], q_len[i], hz_pc, 64'd4)) hz_fetch_stall = 1;
        end else if (overlap(q_ls[i], q_len[i], hz_addr, hz_len)) begin
          hz_wr_stall = 1;
          if (q_kind[i] == XF_GET) hz_rd_stall = 1;
        end
      end
    end
  end

  // ------------------------------------------------------------ bus request
  assign b_req   = es == E_REQ;
  assign b_we    = h_put;
  assign b_space = h_sp;
  assign b_addr  = h_far + off;
  assign b_beats = h_dev ? 24'(h_len - off) : 24'((h_len - off) >> 3);
  assign b_byte  = h_dev;

  // put data: the oldest prefetched word (or its byte, for a device)
  logic [63:0] pf_byte;
  logic [63:0] pf_ls0;
  assign pf_ls0   = h_ls + pf_o[0];
  assign pf_byte  = (pf_d[0] >> {pf_ls0[2:0], 3'b000}) & 64'hff;
  assign b_wvalid = es == E_XFER && h_put && pf_cnt != 0;
  assign b_wdata  = h_dev ? pf_byte : pf_d[0];

  // ------------------------------------------------------------ Local Store port B
  logic [63:0] g_ls, p_ls;
  assign g_ls = h_ls + off;      // get: where the arriving beat goes
  assign p_ls = h_ls + rd_off;   // put: the next byte/word to read

  logic pop, pf_issue;
  assign pop      = b_wvalid && b_wready;
  // keep at most two words buffered or in flight
  assign pf_issue = es == E_XFER && h_put && rd_off < h_len
                    && ({1'b0, pf_cnt} + (pf_inflight ? 3'd1 : 3'd0) - (pop ? 3'd1 : 3'd0)) < 3'd2;

  always_comb begin
    dls_en    = 0;
    dls_we    = '0;
    dls_addr  = '0;
    dls_wdata = b_rdata;
    ils_en    = 0;
    ils_addr  = g_ls[15:3];
    ils_wdata = b_rdata;
    if (es == E_XFER && !h_put && b_rvalid) begin
      if (h_getx) begin
        ils_en = 1;
      end else begin
        dls_en   = 1;
        dls_addr = g_ls[15:3];
        if (h_dev) begin
          dls_we    = 8'(1) << g_ls[2:0];
          dls_wdata = b_rdata << {g_ls[2:0], 3'b000};
        end else begin
          dls_we = 8'hff;
        end
      end
    end else if (pf_issue) begin
      dls_en   = 1;
      dls_addr = p_ls[15:3];
    end
  end

  // ------------------------------------------------------------ sequencing
  always_ff @(posedge clk) begin
    if (rst) begin
      q_v         <= '0;
      head        <= '0;
      tail        <= '0;
      count       <= '0;
      tag_busy    <= '0;
      es          <= E_IDLE;
      off         <= '0;
      rd_off      <= '0;
      pf_cnt      <= '0;
      pf_inflight <= 0;
    end else begin
      // ---- the engine works on the head of the queue
      case (es)
        E_IDLE: if (count != 0) begin
          off         <= '0;
          rd_off      <= '0;
          pf_cnt      <= '0;
          pf_inflight <= 0;
          es          <= h_len == 0 ? E_RETIRE : E_REQ;
        end
        E_REQ: if (b_gnt) es <= E_XFER;
        E_XFER: begin
          if (b_retry) begin
            // the device had no data yet: ask again, after the other queued
            // transfers if it has not started (a break read may wait forever)
            es <= off == 0 && count > 1 ? E_ROT : E_REQ;
          end else begin
            if (!h_put && b_rvalid) off <= off + step;
            if (h_put) begin
              // the prefetch buffer: pop the head when the bus takes it,
              // append the word read from the Local Store last cycle
              if (pop) begin
                pf_d[0] <= pf_d[1];
                pf_o[0] <= pf_o[1];
                off     <= off + step;
              end
              if (pf_inflight) begin
                if (pf_cnt == 0 || (pf_cnt == 1 && pop)) begin
                  pf_d[0] <= dls_rdata;
                  pf_o[0] <= pf_rd_o;
                end else begin
                  pf_d[1] <= dls_rdata;
                  pf_o[1] <= pf_rd_o;
                end
              end
              pf_cnt      <= pf_cnt + (pf_inflight ? 2'd1 : 2'd0) - (pop ? 2'd1 : 2'd0);
              pf_inflight <= pf_issue;
              if (pf_issue) begin
                pf_rd_o <= rd_off;
                rd_off  <= rd_off + step;
              end
            end
            if (b_done) es <= E_RETIRE;
          end
        end
        E_RETIRE: es <= E_IDLE;
        E_ROT: es <= E_IDLE;                      // the head moved to the tail
        default: es <= E_IDLE;
      endcase

      if (es == E_ROT) begin
        q_v[head]    <= 0;
        q_v[tail]    <= 1;
        q_kind[tail] <= q_kind[head];
        q_tag[tail]  <= q_tag[head];
        q_ls[tail]   <= q_ls[head];
        q_sp[tail]   <= q_sp[head];
        q_far[tail]  <= q_far[head];
        q_len[tail]  <= q_len[head];
        head         <= head + 1;
        tail         <= tail + 1;
      end

      // ---- queue bookkeeping
      if (do_retire) begin
        q_v[head] <= 0;
        head      <= head + 1;
      end
      if (do_issue) begin
        q_v[tail]    <= 1;
        q_kind[tail] <= iss_kind;
        q_tag[tail]  <= iss_tag;
        q_ls[tail]   <= iss_ls;
        q_sp[tail]   <= iss_space;
        q_far[tail]  <= iss_far;
        q_len[tail]  <= iss_len;
        tail         <= tail + 1;
      end
      count <= count + (do_issue ? 3'd1 : 3'd0) - (do_retire ? 3'd1 : 3'd0);
      for (int t = 0; t < NTAGS; t++) begin
        if (do_issue && iss_tag == 4'(t)) tag_busy[t] <= 1;
        else if (do_retire && q_tag[head] == 4'(t)) tag_busy[t] <= 0;
      end
    end
  end
endmodule
