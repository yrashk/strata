// Strata: integer ALU (multiplication is done by strata_mul over a few
// cycles, division by strata_div over many).
//
// One 65-bit adder does a + b, a - b and the comparisons: cmp (branches)
// forces a - b whatever op is, and lt / ltu are a < b signed / unsigned.
// Loads, stores and jalr decode as ALU_ADD with b = the offset, so y is
// their address.

module strata_alu
  import strata_pkg::*;
(
  input  logic [3:0]  op,
  input  logic        cmp,
  input  logic [63:0] a,
  input  logic [63:0] b,
  output logic [63:0] y,
  output logic        lt,
  output logic        ltu
);
  logic        inv;
  logic [64:0] s;
  assign inv = cmp || op != ALU_ADD;
  assign s   = {1'b0, a} + {1'b0, inv ? ~b : b} + {64'b0, inv};
  assign ltu = !s[64];                           // a - b borrowed
  assign lt  = a[63] != b[63] ? a[63] : ltu;
  always_comb begin
    unique case (op)
      ALU_ADD:   y = s[63:0];
      ALU_SUB:   y = s[63:0];
      ALU_AND:   y = a & b;
      ALU_OR:    y = a | b;
      ALU_XOR:   y = a ^ b;
      ALU_SLL:   y = a << b[5:0];
      ALU_SRL:   y = a >> b[5:0];
      ALU_SRA:   y = $signed(a) >>> b[5:0];
      ALU_SLT:   y = {63'b0, lt};
      ALU_SLTU:  y = {63'b0, ltu};
      default:   y = '0;
    endcase
  end
endmodule
