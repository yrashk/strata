// Formal specification of strata_alu: every function against its definition
// (emu/emu.c alu(); the manual's integer instructions).
//
// The inputs are unconstrained: no assumptions.

module alu_spec
  import strata_pkg::*;
(
  input logic [3:0]  op,
  input logic        cmp,
  input logic [63:0] a,
  input logic [63:0] b
);
  logic [63:0] y;
  logic        lt, ltu;
  strata_alu dut (.op, .cmp, .a, .b, .y, .lt, .ltu);

  logic [63:0] ref_y;
  always_comb begin
    case (op)
      ALU_ADD:  ref_y = a + b;
      ALU_SUB:  ref_y = a - b;
      ALU_AND:  ref_y = a & b;
      ALU_OR:   ref_y = a | b;
      ALU_XOR:  ref_y = a ^ b;
      ALU_SLL:  ref_y = a << b[5:0];
      ALU_SRL:  ref_y = a >> b[5:0];
      ALU_SRA:  ref_y = 64'($signed(a) >>> b[5:0]);
      ALU_SLT:  ref_y = {63'b0, $signed(a) < $signed(b)};
      ALU_SLTU: ref_y = {63'b0, a < b};
      // multiplication and division are strata_mul's and strata_div's: the
      // ALU answers 0 and the core does not use it
      default:  ref_y = '0;
    endcase
  end

  always_comb begin
    // cmp (a branch) turns the adder into a subtractor whatever op is, so an
    // ALU_ADD result is specified only without it
    if (!(cmp && op == ALU_ADD)) assert (y == ref_y);
    if (cmp && op == ALU_ADD)    assert (y == a - b);
    // the comparison outputs are a < b whenever the adder subtracts
    if (cmp || op != ALU_ADD) begin
      assert (lt  == ($signed(a) < $signed(b)));
      assert (ltu == (a < b));
    end

    // not vacuous: each function with a non-trivial result, both comparisons either way
    cover (op == ALU_ADD  && !cmp && y == 64'h8000_0000_0000_0000 && a[63:60] == 4'h7 && b != 0);
    cover (op == ALU_SUB  && y == 64'hffff_ffff_ffff_ffff && a != 0);
    cover (op == ALU_SLL  && b[5:0] == 6'd63 && y != 0);
    cover (op == ALU_SRA  && b[5:0] == 6'd63 && y == '1);
    cover (op == ALU_SRL  && b[5:0] == 6'd63 && y == 64'd1);
    cover (op == ALU_SLT  && y == 64'd1 && a[63] && !b[63]);
    cover (op == ALU_SLTU && y == 64'd1 && !a[63] && b[63]);
    cover (cmp && lt && !ltu);
    cover (cmp && !lt && ltu);
    cover (op == ALU_DIV);
  end
endmodule
