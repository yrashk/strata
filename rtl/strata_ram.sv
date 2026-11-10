// Strata: true dual-port RAM with synchronous reads and byte-enable writes.
//
// The coding style is the one FPGA tools infer as block RAM (Xilinx BRAM,
// Lattice EBR, UltraRAM with a pragma). Read data appears the cycle after the
// address is presented. Port A and port B are independent.
//
// Read data is only defined for bytes that nobody writes in the same cycle:
// in simulation a read returns the old data, but block RAMs differ on what a
// read returns when the same byte is written in that cycle, above all when
// the write comes through the other port (the ECP5's EBR leaves it
// undefined). No user depends on it: the core ignores the read data of its
// own writes, and the Local Store hazard stalls (strata_tu) keep the core
// and the Transfer Unit from reading bytes the other one is writing. The
// no_rw_check attribute tells Yosys so; without it the two-writer Local
// Store cannot map to ECP5 block RAM and becomes half a million flip-flops.
//
// INIT, when not empty, names a $readmemh file used to initialise the
// contents, which is how boot ROM images get into the bitstream.

module strata_ram #(
  parameter int    WORDS = 1024,
  parameter int    AW    = $clog2(WORDS),
  parameter string INIT  = ""
)(
  input  logic          clk,

  input  logic          a_en,
  input  logic [7:0]    a_we,      // byte write enables
  input  logic [AW-1:0] a_addr,    // word address
  input  logic [63:0]   a_wdata,
  output logic [63:0]   a_rdata,

  input  logic          b_en,
  input  logic [7:0]    b_we,
  input  logic [AW-1:0] b_addr,
  input  logic [63:0]   b_wdata,
  output logic [63:0]   b_rdata
);
  (* no_rw_check *)
  logic [63:0] mem [WORDS];

  initial begin
    if (INIT != "") $readmemh(INIT, mem);
  end

  always_ff @(posedge clk) begin
    if (a_en) begin
      for (int i = 0; i < 8; i++)
        if (a_we[i]) mem[a_addr][8*i +: 8] <= a_wdata[8*i +: 8];
      a_rdata <= mem[a_addr];
    end
  end

  always_ff @(posedge clk) begin
    if (b_en) begin
      for (int i = 0; i < 8; i++)
        if (b_we[i]) mem[b_addr][8*i +: 8] <= b_wdata[8*i +: 8];
      b_rdata <= mem[b_addr];
    end
  end
endmodule
