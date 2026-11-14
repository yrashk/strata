// The identity strata_mul's proof takes as given: schoolbook multiplication
// on two digits of H bits,
//     a * b = al*bl + (al*bh + ah*bl) * 2^H + ah*bh * 2^2H.
// strata_mul uses H = 32; a solver cannot decide that size, so the lemma is
// checked for the H formal/mul_lemma.sby sets (the algebra does not depend
// on H).

module mul_lemma #(
  parameter int H = 8
)(
  input logic [2*H-1:0] a,
  input logic [2*H-1:0] b
);
  logic [4*H-1:0] full, ll, lh, hl, hh;
  assign full = (4*H)'(a) * (4*H)'(b);
  assign ll   = (4*H)'(a[H-1:0])   * (4*H)'(b[H-1:0]);
  assign lh   = (4*H)'(a[H-1:0])   * (4*H)'(b[2*H-1:H]);
  assign hl   = (4*H)'(a[2*H-1:H]) * (4*H)'(b[H-1:0]);
  assign hh   = (4*H)'(a[2*H-1:H]) * (4*H)'(b[2*H-1:H]);
  always_comb begin
    assert (full == ll + (lh << H) + (hl << H) + (hh << (2 * H)));
    cover (full[4*H-1] && ll != 0 && lh != 0 && hl != 0);
  end
endmodule
