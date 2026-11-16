// Properties of strata_mul (included in the module when FORMAL is defined).
//
// What is proved, for every start (a restart while busy included), with
// a = ah * 2^32 + al and b = bh * 2^32 + bl:
//   - done_lo rises 3 cycles after start, and then
//         prod[63:0] = (al*bl + (al*bh + ah*bl) * 2^32) mod 2^64;
//   - done rises 4 cycles after start, and then
//         prod = al*bl + (al*bh + ah*bl) * 2^32 + ah*bh * 2^64;
//   - both stay up, and prod unchanged, until the next start.
// The right-hand sides are a * b (schoolbook multiplication on 32-bit
// digits; formal/spec/mul_lemma.sv checks that identity with smaller
// digits, a solver cannot decide it at this size).
//
// The proof does not reason about multiplication either. The unit has one
// multiplier, p = ma * mb (asserted to be just that). The properties show
// that each step gives it the right pair of halves, and record what it
// answered (f_g0..f_g3); prod is then shown to be the sum of those four
// answers at the right weights.
//
// Assumed: reset in the first cycle; the operands do not change from start
// until done (the module's stated contract; the core waits in S_DV).

  logic         f_past = 0;
  logic         f_rstd = 0;
  logic         f_run  = 0;
  logic [63:0]  f_a, f_b;
  logic [2:0]   f_t;              // cycles since start

  // the multiplier's answers for al*bl, al*bh, ah*bl, ah*bh
  logic [63:0]  f_g0, f_g1, f_g2, f_g3;
  logic [127:0] f_ll, f_lh, f_hl, f_hh;
  assign f_ll = {64'b0, f_g0};
  assign f_lh = {64'b0, f_g1};
  assign f_hl = {64'b0, f_g2};
  assign f_hh = {64'b0, f_g3};

  always_comb if (!f_past) assume (rst);
  // the operands are held while the unit works
  always_comb if (f_rstd && f_run && busy && !start) assume (a == f_a && b == f_b);

  always_ff @(posedge clk) begin
    f_past <= 1;
    if (rst) begin
      f_rstd <= 1;
      f_run  <= 0;
    end else if (start) begin
      f_run <= 1;
      f_a   <= a;
      f_b   <= b;
      f_t   <= 3'd1;
      f_g0  <= p;
    end else if (busy) begin
      f_t <= f_t + 1;
      if (n == 2'd1) f_g1 <= p;
      if (n == 2'd2) f_g2 <= p;
      if (n == 2'd3) f_g3 <= p;
    end
  end

  // the multiplier, and the halves each step gives it
  always_comb begin
    assert (p == {32'b0, ma} * {32'b0, mb});
    if (start) begin assert (ma == a[31:0] && mb == b[31:0]); end
    else if (f_rstd && busy) begin
      if (n == 2'd1) assert (ma == f_a[31:0]  && mb == f_b[63:32]);
      if (n == 2'd2) assert (ma == f_a[63:32] && mb == f_b[31:0]);
      if (n == 2'd3) assert (ma == f_a[63:32] && mb == f_b[63:32]);
    end
  end

  always_comb begin
    if (f_rstd) begin
      if (!f_run) assert (!busy && !done && !done_lo);
      if (f_run) assert (busy != done);
      if (done) assert (done_lo);
      if (busy) begin
        assert (f_run && n != 2'd0 && f_t == 3'(n));     // so: done 4 cycles after start
        assert (done_lo == (n == 2'd3));
        if (n == 2'd1) assert (prod == f_ll);
        if (n == 2'd2) assert (prod == f_ll + (f_lh << 32));
        if (n == 2'd3) assert (prod == f_ll + (f_lh << 32) + (f_hl << 32));
      end
      if (f_run && done) begin
        assert (f_t == 3'd4);
        assert (prod == f_ll + (f_lh << 32) + (f_hl << 32) + (f_hh << 64));
      end
    end
  end

  always_ff @(posedge clk)
    if (f_past && f_rstd && !$past(rst) && !$past(start)) begin
      if ($past(done))    assert (done && prod == $past(prod));
      if ($past(done_lo)) assert (done_lo && prod[63:0] == $past(prod[63:0]));
    end

  // ---- not vacuous
  always_comb begin
    cover (f_rstd && f_run && done && prod[127:64] != 0 && prod[63:0] != 0 && f_a[63] && f_b[63]);
    cover (f_rstd && f_run && done_lo && !done && prod[63:0] == 64'd15 && f_a == 64'd3);
  end
  always_ff @(posedge clk)
    cover (f_past && f_rstd && !$past(rst) && $past(busy) && $past(start) && $past(n) == 2'd2);   // a restart
