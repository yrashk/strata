// Strata: the far bus, a burst interconnect between the masters (every
// core's Transfer Unit and far-atomic unit, and the block device's DMA engine)
// and the far targets (system memory T3, cluster store T2, device space).
//
// One transaction is in flight at a time, system wide: that is what makes
// far atomics trivially linearizable and keeps one core's transfers in issue
// order at the target. A transaction is a burst:
//
//   master -> bus  req (held until gnt), we, amo, amo_op, space, addr,
//                  beats (8-byte words, or bytes when byte_mode), cmp
//   bus -> master  gnt (one cycle: the request was taken)
//   write data     master drives wvalid/wdata, the bus drives wready; a beat
//                  moves when both are high
//   read data      the bus drives rvalid/rdata once per beat; masters always
//                  accept (an atomic returns the old value as one read beat)
//   end            done (one cycle) when the burst is complete, or retry
//                  (one cycle, before any data) when a device has nothing to
//                  give yet; the master asks again later, freeing the bus

module strata_bus
  import strata_pkg::*;
#(
  parameter int NM = 3
)(
  input  logic                clk,
  input  logic                rst,

  // masters
  input  logic [NM-1:0]       m_req,
  input  logic [NM-1:0]       m_we,
  input  logic [NM-1:0]       m_amo,
  input  logic [NM-1:0][2:0]  m_amo_op,
  input  logic [NM-1:0][2:0]  m_space,
  input  logic [NM-1:0][63:0] m_addr,
  input  logic [NM-1:0][23:0] m_beats,
  input  logic [NM-1:0]       m_byte,
  input  logic [NM-1:0][63:0] m_cmp,
  input  logic [NM-1:0]       m_wvalid,
  input  logic [NM-1:0][63:0] m_wdata,
  output logic [NM-1:0]       m_gnt,
  output logic [NM-1:0]       m_wready,
  output logic [NM-1:0]       m_rvalid,
  output logic [63:0]         m_rdata,     // shared: only the active master looks
  output logic [NM-1:0]       m_done,
  output logic [NM-1:0]       m_retry,

  // targets: 0 = T3, 1 = T2, 2 = devices, 3 = core control
  output logic [3:0]          t_start,
  output logic [7:0]          t_master,    // the master of the current transaction
  output logic                t_we,
  output logic                t_amo,
  output logic [2:0]          t_amo_op,
  output logic [63:0]         t_addr,
  output logic [23:0]         t_beats,
  output logic                t_byte,
  output logic [63:0]         t_cmp,
  output logic                t_wvalid,
  output logic [63:0]         t_wdata,
  input  logic [3:0]          t_wready,
  input  logic [3:0]          t_rvalid,
  input  logic [3:0][63:0]    t_rdata,
  input  logic [3:0]          t_done,
  input  logic [3:0]          t_retry
);
  localparam int MW = NM > 1 ? $clog2(NM) : 1;

  typedef enum logic [1:0] {B_IDLE, B_START, B_ACT} bstate_t;
  bstate_t      st;
  logic [MW-1:0] cur, rr;
  logic [2:0]   tgt;          // 0 T3, 1 T2, 2 DEV, 3 core control, 4 none
  logic         l_we, l_amo, l_byte;
  logic [2:0]   l_op;
  logic [63:0]  l_addr, l_cmp;
  logic [23:0]  l_beats;

  // round-robin choice among requesting masters
  logic          any;
  logic [MW-1:0] pick;
  always_comb begin
    any  = 0;
    pick = '0;
    for (int k = 0; k < NM; k++) begin
      int i;
      i = (int'(rr) + k) % NM;
      if (!any && m_req[i]) begin
        any  = 1;
        pick = MW'(i);
      end
    end
  end

  function automatic logic [2:0] route(input logic [2:0] sp);
    case (sp)
      SP_T3:   return 3'd0;
      SP_T2:   return 3'd1;
      SP_DEV:  return 3'd2;
      SP_CORE: return 3'd3;
      default: return 3'd4;
    endcase
  endfunction

  always_ff @(posedge clk) begin
    if (rst) begin
      st <= B_IDLE;
      rr <= '0;
      cur <= '0;
      tgt <= 3'd4;
    end else begin
      case (st)
        B_IDLE: if (any) begin
          cur     <= pick;
          rr      <= MW'((int'(pick) + 1) % NM);
          tgt     <= route(m_space[pick]);
          l_we    <= m_we[pick];
          l_amo   <= m_amo[pick];
          l_op    <= m_amo_op[pick];
          l_addr  <= m_addr[pick];
          l_beats <= m_beats[pick];
          l_byte  <= m_byte[pick];
          l_cmp   <= m_cmp[pick];
          st      <= B_START;
        end
        B_START: st <= tgt == 3'd4 ? B_IDLE : B_ACT;
        B_ACT: if (t_done[tgt[1:0]] || t_retry[tgt[1:0]]) st <= B_IDLE;
        default: st <= B_IDLE;
      endcase
    end
  end

  always_comb begin
    m_gnt = '0;
    if (st == B_IDLE && any) m_gnt[pick] = 1;
  end

  assign t_start  = st == B_START && tgt != 3'd4 ? 4'(1 << tgt) : 4'b0000;
  assign t_master = 8'(cur);
  assign t_we     = l_we;
  assign t_amo    = l_amo;
  assign t_amo_op = l_op;
  assign t_addr   = l_addr;
  assign t_beats  = l_beats;
  assign t_byte   = l_byte;
  assign t_cmp    = l_cmp;
  assign t_wvalid = st == B_ACT && m_wvalid[cur];
  assign t_wdata  = m_wdata[cur];
  assign m_rdata  = tgt == 3'd4 ? '0 : t_rdata[tgt[1:0]];

  always_comb begin
    m_wready = '0;
    m_rvalid = '0;
    m_done   = '0;
    m_retry  = '0;
    if (st == B_START && tgt == 3'd4) m_done[cur] = 1;   // no such space: complete at once
    if (st == B_ACT) begin
      m_wready[cur] = t_wready[tgt[1:0]];
      m_rvalid[cur] = t_rvalid[tgt[1:0]];
      m_done[cur]   = t_done[tgt[1:0]];
      m_retry[cur]  = t_retry[tgt[1:0]];
    end
  end

`ifdef FORMAL
`include "strata_bus.svh"
`endif
endmodule

