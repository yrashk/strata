// Properties of strata_div (included in the module when FORMAL is defined).
//
// What is proved, for every start (a restart while busy included):
//   - b == 0, and MIN / -1 when signed: the fixed results, the cycle after;
//   - otherwise, 65 cycles after start (64 while busy), with A = |a| and
//     B = |b| when signed, else a and b:
//         A = Q * B + R,  0 <= R < B,
//         quo = -Q if signed and the operands' signs differ, else Q,
//         rem = -R if signed and a is negative, else R
//     which is division truncating toward zero;
//   - done stays up, and the results unchanged, until the next start.
//
// Q * B is not a multiplication here (no solver decides a 64-bit one in
// reasonable time): f_qb is kept in step with the quotient register, bit by
// bit, f_qb' = 2 f_qb + (bit ? B : 0), which is (2 Q + bit) * B. The
// quotient register never drops a set bit (asserted), so f_qb = Q * B.
// With F_DIVREF = 1 (formal/div.sby, task ref) the results are also compared
// with Verilog's own / and %, for operands that fit in 8 bits, by bounded
// model checking.
//
// Assumed: reset in the first cycle. The operands, is_signed and start are
// unconstrained.

  parameter bit F_DIVREF = 0;

  logic         f_past = 0;       // not the first cycle
  logic         f_rstd = 0;       // the unit has been reset
  logic         f_run  = 0;       // a division was started since
  logic [63:0]  f_a, f_b;         // its operands
  logic         f_s;
  logic [127:0] f_qb;             // Q * B so far
  logic [6:0]   f_t;              // busy cycles so far

  logic [63:0]  f_A, f_B;
  logic [6:0]   f_k;
  logic         f_special;
  assign f_A = f_s && f_a[63] ? -f_a : f_a;
  assign f_B = f_s && f_b[63] ? -f_b : f_b;
  assign f_k = 7'd64 - n;         // quotient bits made
  assign f_special = f_b == 0 || (f_s && f_a == 64'h8000_0000_0000_0000 && f_b == '1);

  always_comb if (!f_past) assume (rst);

  always_ff @(posedge clk) begin
    f_past <= 1;
    if (rst) begin
      f_rstd <= 1;
      f_run  <= 0;
    end else if (start) begin
      f_run <= 1;
      f_a   <= a;
      f_b   <= b;
      f_s   <= is_signed;
      f_qb  <= '0;
      f_t   <= '0;
    end else if (busy) begin
      f_qb <= {f_qb[126:0], 1'b0} + (!r_sub[64] ? 128'(dvs) : 128'd0);
      f_t  <= f_t + 1;
    end
  end

  always_comb begin
    if (f_rstd && !F_DIVREF) begin
      assert (!(busy && done));
      if (!f_run) assert (!busy && !done);
      // once started, the unit is working or has the answer
      if (f_run) assert (busy || done);
      if (f_run) assert (special == f_special);
      if (f_run && f_special) begin
        assert (done);
        assert (quo == (f_b == 0 ? 64'hffff_ffff_ffff_ffff : f_a));
        assert (rem == (f_b == 0 ? f_a : 64'd0));
      end
      if (busy) begin
        assert (f_run && !f_special);
        assert (n >= 7'd1 && n <= 7'd64);
        assert (f_t == f_k);                              // so: at most 64 busy cycles
        assert (dvs == f_B && dvs != 0);
        assert (dvd == f_A << f_k);                       // the bits still to bring down
        assert (f_k == 7'd64 || (q >> f_k) == 0);         // no quotient bit was shifted out
        assert (r < {1'b0, dvs});
        assert (f_qb + 128'(r) == 128'(f_A >> n));        // the bits brought down so far
        assert (neg_q == (f_s && (f_a[63] ^ f_b[63])));
        assert (neg_r == (f_s && f_a[63]));
      end
      if (done && !f_special) begin
        assert (f_run && f_t == 7'd64);
        assert (f_qb + 128'(r) == 128'(f_A));             // A = Q * B + R
        assert (r < {1'b0, f_B});                         // R < B
        assert (quo == (f_s && (f_a[63] ^ f_b[63]) ? -q : q));
        assert (rem == (f_s && f_a[63] ? -r[63:0] : r[63:0]));
      end
    end
  end

  // done and the results hold until the next start
  always_ff @(posedge clk)
    if (f_past && f_rstd && !F_DIVREF && !$past(rst) && $past(done) && !$past(start)) begin
      assert (done);
      assert (quo == $past(quo) && rem == $past(rem));
    end

  // ---- against Verilog's division, for small operands (bounded)
  function automatic logic f_small(input logic [63:0] v, input logic s);
    return s ? (v[63:7] == '0 || v[63:7] == '1) : v[63:8] == '0;
  endfunction
  logic signed [9:0] f_sa, f_sb;
  assign f_sa = f_s ? 10'($signed(f_a[7:0])) : {2'b0, f_a[7:0]};
  assign f_sb = f_s ? 10'($signed(f_b[7:0])) : {2'b0, f_b[7:0]};
  // (this task only: small operands, and no restart, keep the bounded check short)
  always_comb if (F_DIVREF && start) assume (f_small(a, is_signed) && f_small(b, is_signed) && !busy);
  always_comb
    if (F_DIVREF && f_rstd && done && f_b != 0 && f_small(f_a, f_s) && f_small(f_b, f_s)) begin
      assert (quo == 64'($signed(f_sa / f_sb)));
      assert (rem == 64'($signed(f_sa % f_sb)));
    end

  // ---- not vacuous
  always_comb begin
    cover (f_rstd && done && !f_special && f_s && f_a[63] && !f_b[63] && r != 0 && q > 64'd1000);
    cover (f_rstd && done && !f_special && f_s && !f_a[63] && f_b[63] && r != 0);
    cover (f_rstd && done && !f_special && !f_s && f_a[63] && f_b[63] && q == 64'd1);
    cover (f_rstd && done && f_run && f_b == 0);
    cover (f_rstd && done && f_run && f_special && f_b != 0);
  end
  always_ff @(posedge clk)
    cover (f_past && f_rstd && !$past(rst) && $past(busy) && $past(start) && $past(f_t) > 7'd3);  // a restart
