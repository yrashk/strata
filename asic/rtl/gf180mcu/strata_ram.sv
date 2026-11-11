// Strata, ASIC (GF180MCU): a physical stand-in for rtl/strata_ram.sv, built
// from the PDK's gf180mcu_fd_ip_sram__sram512x8m8wm1 macros (512 x 8,
// single port, 0.209 mm^2 each).
//
// THIS IS NOT FUNCTIONALLY THE SAME RAM. rtl/strata_ram.sv is a true
// dual-port RAM (two independent read/write ports, as FPGA block RAM is);
// the GF180MCU macro library has only single-port SRAMs. Here the two ports
// share one port of the macros and port A wins when both are enabled in the
// same cycle (port B's access is lost), and both read-data outputs show the
// last access. A real chip would need a dual-port SRAM (about 1.5-2x the
// area per bit), two banks with a stall, or a double-pumped port. This file
// exists so the place-and-route run has the macros, their wiring and their
// timing (clock-to-Q about 5 ns, minimum cycle 6.6 ns at tt/5 V) in the right
// places; see asic/README.md.
//
// Organisation: WORDS / 512 rows of 8 macros, one macro per byte lane (the
// macro's bit write mask is driven from the byte's write enable). A row is
// selected by the top address bits; the read data goes through a row
// multiplexer selected by the registered row number of the last access.

module strata_ram #(
  parameter int    WORDS = 1024,
  parameter int    AW    = $clog2(WORDS),
  parameter string INIT  = ""                  // ignored: SRAM has no initial contents
)(
  input  logic          clk,

  input  logic          a_en,
  input  logic [7:0]    a_we,
  input  logic [AW-1:0] a_addr,
  input  logic [63:0]   a_wdata,
  output logic [63:0]   a_rdata,

  input  logic          b_en,
  input  logic [7:0]    b_we,
  input  logic [AW-1:0] b_addr,
  input  logic [63:0]   b_wdata,
  output logic [63:0]   b_rdata
);
  localparam int ROWS = WORDS / 512;
  localparam int RW   = ROWS > 1 ? $clog2(ROWS) : 1;

  // the shared port: A if it asks, else B
  logic          en;
  logic [7:0]    we;
  logic [AW-1:0] addr;
  logic [63:0]   wdata;
  assign en    = a_en | b_en;
  assign we    = a_en ? a_we : b_we;
  assign addr  = a_en ? a_addr : b_addr;
  assign wdata = a_en ? a_wdata : b_wdata;

  logic [RW-1:0] row, row_q;
  assign row = ROWS > 1 ? RW'(addr >> 9) : '0;
  always_ff @(posedge clk) if (en) row_q <= row;

  logic [63:0] q [ROWS];
  for (genvar r = 0; r < ROWS; r++) begin : g_r
    logic cen;
    assign cen = !(en && row == RW'(r));
    for (genvar b = 0; b < 8; b++) begin : g_b
      gf180mcu_fd_ip_sram__sram512x8m8wm1 u_m (
        .CLK(clk), .CEN(cen), .GWEN(!we[b]), .WEN({8{!we[b]}}),
        .A(addr[8:0]), .D(wdata[8*b +: 8]), .Q(q[r][8*b +: 8])
      );
    end
  end

  assign a_rdata = q[row_q];
  assign b_rdata = q[row_q];
endmodule
