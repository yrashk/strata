// -----------------------------------------------------------------------------
// strata_mem: a far memory target (block RAM on FPGA, a plain array in
// simulation) with a fixed start-up latency per burst, then one beat per cycle.
// Atomics are a read-modify-write of one word.

module strata_mem
  import strata_pkg::*;
#(
  parameter int    WORDS = 32768,
  parameter int    LAT   = 8,
  parameter int    KIND  = 3,        // image section kind used to initialise it in simulation
  parameter string INIT  = ""
)(
  input  logic        clk,
  input  logic        rst,
  input  logic        start,
  input  logic        we,
  input  logic        amo,
  input  logic [2:0]  amo_op,
  input  logic [63:0] addr,
  input  logic [23:0] beats,
  input  logic [63:0] cmp,
  input  logic        wvalid,
  input  logic [63:0] wdata,
  output logic        wready,
  output logic        rvalid,
  output logic [63:0] rdata,
  output logic        done
);
  localparam int AW = $clog2(WORDS);

  logic [63:0] mem [WORDS];

`ifdef SIMULATION
  initial for (int i = 0; i < WORDS; i++) mem[i] = img_word(KIND, i);
  // lets the harness read memory (the framebuffer on PRESENT); call it in
  // the scope of the instance
  export "DPI-C" function sim_mem_word;
  function longint sim_mem_word(input int widx);
    return mem[AW'(widx)];
  endfunction
`else
  initial if (INIT != "") $readmemh(INIT, mem);
`endif

  typedef enum logic [2:0] {M_IDLE, M_LAT, M_RD, M_WR, M_AMO1, M_AMO2, M_DONE} mstate_t;
  mstate_t      st;
  logic [7:0]   lat;
  logic [AW-1:0] a;
  logic [23:0]  left, out_left;
  logic         l_we, l_amo;
  logic [2:0]   l_op;
  logic [63:0]  l_cmp, l_wd, q;
  logic         rd_en, wr_en, q_valid;
  logic [AW-1:0] rd_a, wr_a;
  logic [63:0]  wr_d;

  // the array: one synchronous read port, one write port
  always_ff @(posedge clk) begin
    if (rd_en) q <= mem[rd_a];
    if (wr_en) mem[wr_a] <= wr_d;
  end

`ifdef SIMULATION
  // live scanout: tell the harness when system memory (KIND 3) is written
  // inside the framebuffer window [0x3000000, 0x4000000)
  localparam logic [31:0] FB_W0 = 32'h3000000 / 8, FB_W1 = 32'h4000000 / 8;
  logic [31:0] wr_w;
  assign wr_w = 32'(wr_a);
  always_ff @(posedge clk)
    if (KIND == 3 && wr_en && wr_w >= FB_W0 && wr_w < FB_W1) sim_fb_write(int'(wr_w));
`endif

  function automatic logic [63:0] amo_new(input logic [2:0] op, input logic [63:0] old,
                                          input logic [63:0] v, input logic [63:0] c);
    case (op)
      AMO_ADD:  return old + v;
      AMO_SWAP: return v;
      AMO_CAS:  return old == c ? v : old;
      AMO_AND:  return old & v;
      AMO_OR:   return old | v;
      default:  return old;
    endcase
  endfunction

  always_comb begin
    rd_en  = 0;
    rd_a   = a;
    wr_en  = 0;
    wr_a   = a;
    wr_d   = wdata;
    wready = st == M_WR;
    rvalid = 0;
    rdata  = q;
    done   = st == M_DONE;
    case (st)
      M_RD: begin
        rd_en  = left != 0;
        rvalid = q_valid;
        done   = q_valid && out_left == 1;
      end
      M_WR: begin
        wr_en = wvalid;
        done  = wvalid && left == 1;
      end
      M_AMO1: rd_en = 1;
      M_AMO2: begin
        wr_en  = 1;
        wr_d   = amo_new(l_op, q, l_wd, l_cmp);
        rvalid = 1;
        done   = 1;
      end
      default: ;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      st      <= M_IDLE;
      q_valid <= 0;
    end else begin
      case (st)
        M_IDLE: if (start) begin
          a        <= addr[AW+2:3];
          left     <= beats;
          out_left <= beats;
          l_we     <= we;
          l_amo    <= amo;
          l_op     <= amo_op;
          l_cmp    <= cmp;
          l_wd     <= wdata;
          lat      <= 8'(LAT);
          q_valid  <= 0;
          st       <= beats == 0 && !amo ? M_DONE : M_LAT;
        end
        M_LAT: if (lat == 0) st <= l_amo ? M_AMO1 : l_we ? M_WR : M_RD;
               else lat <= lat - 1;
        M_RD: begin
          q_valid <= left != 0;
          if (left != 0) begin
            a    <= a + 1;
            left <= left - 1;
          end
          if (q_valid) begin
            out_left <= out_left - 1;
            if (out_left == 1) st <= M_IDLE;
          end
        end
        M_WR: if (wvalid) begin
          a    <= a + 1;
          left <= left - 1;
          if (left == 1) st <= M_IDLE;
        end
        M_AMO1: st <= M_AMO2;
        M_AMO2: st <= M_IDLE;
        M_DONE: st <= M_IDLE;
        default: st <= M_IDLE;
      endcase
    end
  end

`ifdef FORMAL
`include "strata_mem.svh"
`endif
endmodule
