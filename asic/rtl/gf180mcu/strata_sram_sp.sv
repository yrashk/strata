// Strata, ASIC (GF180MCU): a single-port WORDS x 64 RAM built from
// gf180mcu_fd_ip_sram__sram512x8m8wm1 macros: WORDS / 512 rows of 8 (one
// macro per byte). Read data the cycle after the address, held until the
// next access. Used for T2 (asic/mkmem.py puts it in place of strata_mem's
// array, which has one read or one write per cycle, so this is the same RAM).

module strata_sram_sp #(
  parameter int WORDS = 8192,
  parameter int AW    = $clog2(WORDS)
)(
  input  logic          clk,
  input  logic          en,
  input  logic          we,
  input  logic [AW-1:0] addr,
  input  logic [63:0]   wdata,
  output logic [63:0]   rdata
);
  localparam int ROWS = WORDS / 512;
  localparam int RW   = ROWS > 1 ? $clog2(ROWS) : 1;

  logic [RW-1:0] row, row_q;
  assign row = ROWS > 1 ? RW'(addr >> 9) : '0;
  always_ff @(posedge clk) if (en && !we) row_q <= row;

  logic [63:0] q [ROWS];
  for (genvar r = 0; r < ROWS; r++) begin : g_r
    logic cen;
    assign cen = !(en && row == RW'(r));
    for (genvar b = 0; b < 8; b++) begin : g_b
      gf180mcu_fd_ip_sram__sram512x8m8wm1 u_m (
        .CLK(clk), .CEN(cen), .GWEN(!we), .WEN({8{!we}}),
        .A(addr[8:0]), .D(wdata[8*b +: 8]), .Q(q[r][8*b +: 8])
      );
    end
  end
  assign rdata = q[row_q];
endmodule
