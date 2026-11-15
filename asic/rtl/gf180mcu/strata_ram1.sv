// Strata, ASIC (GF180MCU): rtl/strata_ram1.sv, the single-port memory that
// holds both Local Stores of a core built with LS_1P = 1, from SRAM macros.
// Unlike strata_ram.sv beside it this IS the same RAM as the RTL's: one
// access per cycle, read data the cycle after, held until the next access.
//
// The macro is the PDK's gf180mcu_fd_ip_sram__sram512x8m8wm1 (512 x 8) or,
// with ASIC_SRAM_OCD defined (asic/run.sh: ASIC_SRAM=ocd1024),
// gf180mcu_ocd_ip_sram__sram1024x8m8wm1 (1024 x 8, 3.3 V devices,
// 301.30 x 515.81 um: 19 um^2 per bit against 51; the same pins).
//
// Organisation: WORDS / (the macro's words) rows of 8 macros, one macro per
// byte lane; a row is selected by the top address bits, and the read data
// goes through a row multiplexer selected by the registered row number of
// the last access. INIT_LO / INIT_HI are ignored: SRAM has no initial
// contents (a reset request loads the boot ROM).

module strata_ram1 #(
  parameter int    WORDS   = 2048,
  parameter int    AW      = $clog2(WORDS),
  parameter int    SPLIT   = WORDS / 2,
  parameter string INIT_LO = "",
  parameter string INIT_HI = ""
)(
  input  logic          clk,
  input  logic          en,
  input  logic [7:0]    we,
  input  logic [AW-1:0] addr,
  input  logic [63:0]   wdata,
  output logic [63:0]   rdata
);
`ifdef ASIC_SRAM_OCD
  localparam int MA = 10;
`else
  localparam int MA = 9;
`endif
  localparam int ROWS = WORDS >> MA;
  localparam int RW   = ROWS > 1 ? $clog2(ROWS) : 1;

  logic [RW-1:0] row, row_q;
  assign row = ROWS > 1 ? RW'(addr >> MA) : '0;
  always_ff @(posedge clk) if (en) row_q <= row;

  logic [63:0] q [ROWS];
  for (genvar r = 0; r < ROWS; r++) begin : g_r
    logic cen;
    assign cen = !(en && row == RW'(r));
    for (genvar b = 0; b < 8; b++) begin : g_b
`ifdef ASIC_SRAM_OCD
      gf180mcu_ocd_ip_sram__sram1024x8m8wm1 u_m (
`else
      gf180mcu_fd_ip_sram__sram512x8m8wm1 u_m (
`endif
        .CLK(clk), .CEN(cen), .GWEN(!we[b]), .WEN({8{!we[b]}}),
        .A(addr[MA-1:0]), .D(wdata[8*b +: 8]), .Q(q[r][8*b +: 8])
      );
    end
  end
  assign rdata = q[row_q];
endmodule
