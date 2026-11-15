// Strata: single-port RAM with a synchronous read and byte-enable writes.
//
// One access per cycle: a write of the enabled bytes, or a read whose data
// appears the cycle after (a write leaves the read data undefined for the
// bytes it writes; in simulation it returns the old word). This is what an
// SRAM compiler's dense macro is, and what strata_core uses for both Local
// Stores when LS_1P = 1: the I-LS in words 0 .. SPLIT - 1 and the D-LS above.
//
// INIT_LO / INIT_HI, when not empty, name $readmemh files for the words
// below and from SPLIT (the two stores' boot images).

module strata_ram1 #(
  parameter int    WORDS   = 2048,
  parameter int    AW      = $clog2(WORDS),
  parameter int    SPLIT   = WORDS / 2,
  parameter string INIT_LO = "",
  parameter string INIT_HI = ""
)(
  input  logic          clk,
  input  logic          en,
  input  logic [7:0]    we,        // byte write enables
  input  logic [AW-1:0] addr,      // word address
  input  logic [63:0]   wdata,
  output logic [63:0]   rdata
);
  logic [63:0] mem [WORDS];

  initial begin
    if (INIT_LO != "") $readmemh(INIT_LO, mem, 0, SPLIT - 1);
    if (INIT_HI != "") $readmemh(INIT_HI, mem, SPLIT, WORDS - 1);
  end

  always_ff @(posedge clk) begin
    if (en) begin
      for (int i = 0; i < 8; i++)
        if (we[i]) mem[addr][8*i +: 8] <= wdata[8*i +: 8];
      rdata <= mem[addr];
    end
  end
endmodule
