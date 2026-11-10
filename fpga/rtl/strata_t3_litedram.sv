// Strata: system memory (T3) target backed by a LiteDRAM native user port.
//
// Speaks the strata_mem target protocol on one side (see rtl/strata_mem.sv)
// and LiteDRAM's native port on the other: a command channel (valid/ready,
// we, addr in port-width words), a write-data channel (valid/ready, data,
// byte enables) and a read-data channel (valid/ready, data).
//
// Each 8-byte beat becomes one DRAM access to the port word that contains it
// (DW = 128 on the Arty A7's DDR3: two beats per word). Atomics are a read
// followed by a write while the far bus is held, so they stay linearizable.
// Simple and correct rather than fast: one access in flight at a time.

module strata_t3_litedram #(
  parameter int DW = 128,              // LiteDRAM native port data width (>= 64)
  parameter int AW = 24                // its address width, in DW-bit words
)(
  input  logic          clk,
  input  logic          rst,

  // strata_mem target protocol
  input  logic          start,
  input  logic          we,
  input  logic          amo,
  input  logic [2:0]    amo_op,
  input  logic [63:0]   addr,
  input  logic [23:0]   beats,
  input  logic [63:0]   cmp,
  input  logic          wvalid,
  input  logic [63:0]   wdata,
  output logic          wready,
  output logic          rvalid,
  output logic [63:0]   rdata,
  output logic          done,

  // LiteDRAM native user port
  output logic          cmd_valid,
  input  logic          cmd_ready,
  output logic          cmd_we,
  output logic [AW-1:0] cmd_addr,
  output logic          wdata_valid,
  input  logic          wdata_ready,
  output logic [DW-1:0] wdata_data,
  output logic [DW/8-1:0] wdata_we,
  input  logic          rdata_valid,
  output logic          rdata_ready,
  input  logic [DW-1:0] rdata_data
);
  localparam int LANES = DW / 64;      // 8-byte lanes per port word
  localparam int LW    = LANES > 1 ? $clog2(LANES) : 1;

  typedef enum logic [2:0] {I_IDLE, I_RCMD, I_RDAT, I_WDATA, I_WCMD, I_WDAT, I_DONE} st_t;
  st_t         st;
  logic [63:0] a;              // byte address of the current beat
  logic [23:0] left;
  logic        l_we, l_amo;
  logic [2:0]  l_op;
  logic [63:0] l_cmp, l_v, wbuf, old;

  logic [LW-1:0] lane;
  assign lane = LANES > 1 ? LW'(a[3 +: LW]) : '0;

  function automatic logic [63:0] amo_new(input logic [2:0] op, input logic [63:0] o,
                                          input logic [63:0] v, input logic [63:0] c);
    case (op)
      3'd0: return o + v;
      3'd1: return v;
      3'd2: return o == c ? v : o;
      3'd3: return o & v;
      3'd4: return o | v;
      default: return o;
    endcase
  endfunction

  assign cmd_valid   = st == I_RCMD || st == I_WCMD;
  assign cmd_we      = st == I_WCMD;
  assign cmd_addr    = AW'(a >> $clog2(DW / 8));
  assign wdata_valid = st == I_WDAT;
  assign wdata_data  = {LANES{wbuf}};
  assign wdata_we    = (DW/8)'(8'hff) << (8 * lane);
  assign rdata_ready = st == I_RDAT;

  always_comb begin
    wready = st == I_WDATA;
    rvalid = 0;
    rdata  = old;
    done   = st == I_DONE;
    if (st == I_RDAT && rdata_valid && !l_amo) begin     // a read beat
      rvalid = 1;
      rdata  = rdata_data[64*lane +: 64];
      done   = left == 1;
    end
    if (st == I_WDAT && wdata_ready && l_amo) begin      // an atomic's write lands:
      rvalid = 1;                                        // return the old value
      rdata  = old;
      done   = 1;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) st <= I_IDLE;
    else begin
      case (st)
        I_IDLE: if (start) begin
          a     <= addr;
          left  <= beats;
          l_we  <= we;
          l_amo <= amo;
          l_op  <= amo_op;
          l_cmp <= cmp;
          l_v   <= wdata;
          st    <= (beats == 0 && !amo) ? I_DONE : (we && !amo) ? I_WDATA : I_RCMD;
        end
        I_RCMD:  if (cmd_ready) st <= I_RDAT;
        I_RDAT:  if (rdata_valid) begin
          if (l_amo) begin                               // atomic: read, modify, then write
            old  <= rdata_data[64*lane +: 64];
            wbuf <= amo_new(l_op, rdata_data[64*lane +: 64], l_v, l_cmp);
            st   <= I_WCMD;
          end else begin
            a    <= a + 8;
            left <= left - 1;
            st   <= left == 1 ? I_IDLE : I_RCMD;
          end
        end
        I_WDATA: if (wvalid) begin                       // take one beat from the bus
          wbuf <= wdata;
          st   <= I_WCMD;
        end
        I_WCMD:  if (cmd_ready) st <= I_WDAT;
        I_WDAT:  if (wdata_ready) begin
          if (l_amo) st <= I_IDLE;                       // done was signalled above
          else begin
            a    <= a + 8;
            left <= left - 1;
            st   <= left == 1 ? I_DONE : I_WDATA;
          end
        end
        I_DONE:  st <= I_IDLE;
        default: st <= I_IDLE;
      endcase
    end
  end
endmodule
