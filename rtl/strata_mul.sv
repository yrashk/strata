// Strata: 64 x 64 -> 128-bit unsigned multiplier on one 32 x 32 multiplier
// (four DSP48E1 / MULT18X18D), one partial product per cycle:
//   start (EX):  acc  = a.lo * b.lo
//   1:           acc += a.lo * b.hi << 32
//   2:           acc += a.hi * b.lo << 32   (the low half is complete: done_lo)
//   3:           acc += a.hi * b.hi << 64   (done)
// The operands must stay unchanged until done (the core waits in S_DV, so
// its registers do). done_lo / done stay high until the next start.

module strata_mul (
  input  logic         clk,
  input  logic         rst,
  input  logic         start,
  input  logic [63:0]  a,
  input  logic [63:0]  b,
  output logic         done_lo,
  output logic         done,
  output logic [127:0] prod
);
  logic [1:0]  n;            // the next partial product
  logic        busy;
  logic [31:0] ma, mb;
  logic [63:0] p;

  always_comb begin
    unique case (start ? 2'd0 : n)
      2'd0: begin ma = a[31:0];  mb = b[31:0];  end
      2'd1: begin ma = a[31:0];  mb = b[63:32]; end
      2'd2: begin ma = a[63:32]; mb = b[31:0];  end
      default: begin ma = a[63:32]; mb = b[63:32]; end
    endcase
  end
  assign p = {32'b0, ma} * {32'b0, mb};

  always_ff @(posedge clk) begin
    if (rst) begin
      busy    <= 0;
      done    <= 0;
      done_lo <= 0;
      n       <= '0;
    end else if (start) begin
      prod    <= {64'b0, p};
      n       <= 2'd1;
      busy    <= 1;
      done    <= 0;
      done_lo <= 0;
    end else if (busy) begin
      // bits 31:0 are final after the first product: one 96-bit adder above them
      prod[127:32] <= prod[127:32] + (n == 2'd3 ? {p, 32'b0} : {32'b0, p});
      n <= n + 1;
      if (n == 2'd2) done_lo <= 1;
      if (n == 2'd3) begin busy <= 0; done <= 1; end
    end
  end

`ifdef FORMAL
`include "strata_mul.svh"
`endif
endmodule
