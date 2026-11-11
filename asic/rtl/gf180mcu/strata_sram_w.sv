// Strata, ASIC (GF180MCU): a single-port 256 x W RAM built from
// gf180mcu_fd_ip_sram__sram256x8m8wm1 macros (ceil(W / 8) side by side).
// Read data the cycle after the address, held until the next access.
// Used for each core's capability save table (asic/mktop.py puts it in place
// of strata_core's ctab array, which is read in S_EX and written in S_RST or
// S_CT, never in the same cycle, so the single-port SRAM is the same memory).

module strata_sram_w #(
  parameter int W = 81
)(
  input  logic         clk,
  input  logic         en,
  input  logic         we,
  input  logic [7:0]   addr,
  input  logic [W-1:0] wdata,
  output logic [W-1:0] rdata
);
  localparam int N = (W + 7) / 8;
  logic [8*N-1:0] d, q;
  assign d     = (8 * N)'(wdata);
  assign rdata = q[W-1:0];
  for (genvar b = 0; b < N; b++) begin : g_b
    gf180mcu_fd_ip_sram__sram256x8m8wm1 u_m (
      .CLK(clk), .CEN(!en), .GWEN(!we), .WEN({8{!we}}),
      .A(addr), .D(d[8*b +: 8]), .Q(q[8*b +: 8])
    );
  end
endmodule
