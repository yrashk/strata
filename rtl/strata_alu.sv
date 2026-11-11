// Strata: integer ALU (multiplication is done by strata_mul over a few
// cycles, division by strata_div over many).

module strata_alu
  import strata_pkg::*;
(
  input  logic [3:0]  op,
  input  logic [63:0] a,
  input  logic [63:0] b,
  output logic [63:0] y
);
  always_comb begin
    unique case (op)
      ALU_ADD:   y = a + b;
      ALU_SUB:   y = a - b;
      ALU_AND:   y = a & b;
      ALU_OR:    y = a | b;
      ALU_XOR:   y = a ^ b;
      ALU_SLL:   y = a << b[5:0];
      ALU_SRL:   y = a >> b[5:0];
      ALU_SRA:   y = $signed(a) >>> b[5:0];
      ALU_SLT:   y = {63'b0, $signed(a) < $signed(b)};
      ALU_SLTU:  y = {63'b0, a < b};
      default:   y = '0;
    endcase
  end
endmodule
