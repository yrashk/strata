// Properties of strata_mem as a far-bus target (included in the module when
// FORMAL is defined). These are what strata_tu.svh assumes of a memory
// target, and what a far atomic needs.
//
// What is proved, for every transaction (from start to done):
//   burst      a read gives exactly `beats` read beats and done with the
//              last one; a write takes exactly `beats` write beats and is
//              done with the last one; an empty burst is done the next
//              cycle without a beat; an atomic gives one read beat, with
//              done. No beat and no done outside a transaction, no read
//              beat in a write, wready only in a write.
//   time       a read is done LAT + 2 + beats cycles after start, an atomic
//              LAT + 3 (a write takes as long as the master's data does)
//   data       (for one word W of the memory, chosen by the solver, so for
//              all) read beat n returns the word at addr / 8 + n as it is;
//              write beat n replaces the word at addr / 8 + n with its
//              data; an atomic returns the old word and stores
//              add / swap / cas / and / or of it; nothing else changes W
//
// Assumed (the bus: proved for strata_bus):
//   - reset in the first cycle
//   - a transaction is started only when none is under way
// The address is taken modulo the memory's size (capabilities keep every
// far address inside its space; not checked here).

  logic f_past = 0;
  logic f_rstd = 0;
  always_comb if (!f_past) assume (rst);
  always_ff @(posedge clk) begin
    f_past <= 1;
    if (rst) f_rstd <= 1;
  end

  logic          f_busy = 0;      // a transaction is under way
  logic          f_we, f_amo;
  logic [2:0]    f_op;
  logic [23:0]   f_beats;
  logic [AW-1:0] f_base;          // its first word
  logic [63:0]   f_cmp, f_wd;
  logic [23:0]   f_n;             // beats so far
  logic [31:0]   f_t;             // cycles since start
  logic          f_beat;          // a beat moves this cycle
  assign f_beat = rvalid || (wvalid && wready);
  always_comb if (start) assume (!f_busy);
  always_ff @(posedge clk) begin
    if (rst) f_busy <= 0;
    else if (start) begin
      f_busy  <= 1;
      f_we    <= we;
      f_amo   <= amo;
      f_op    <= amo_op;
      f_beats <= beats;
      f_base  <= addr[AW+2:3];
      f_cmp   <= cmp;
      f_wd    <= wdata;
      f_n     <= '0;
      f_t     <= '0;
    end else if (f_busy) begin
      f_t <= f_t + 1;
      if (f_beat) f_n <= f_n + 1;
      if (done) f_busy <= 0;
    end
  end

  // one word of the memory
  (* anyconst *) logic [AW-1:0] f_w;
  logic [63:0] f_m;
  assign f_m = mem[f_w];
  logic [AW-1:0] f_idx;           // the word this cycle's beat is about
  assign f_idx = f_base + AW'(f_n);
  // the specification's atomic result
  logic [63:0] f_amo_new;
  always_comb begin
    case (f_op)
      3'd0:    f_amo_new = f_m + f_wd;
      3'd1:    f_amo_new = f_wd;
      3'd2:    f_amo_new = f_m == f_cmp ? f_wd : f_m;
      3'd3:    f_amo_new = f_m & f_wd;
      3'd4:    f_amo_new = f_m | f_wd;
      default: f_amo_new = f_m;
    endcase
  end

  always_comb begin
    if (f_rstd) begin
      assert (st <= M_DONE);
      assert (f_busy == (st != M_IDLE));
      if (!f_busy) assert (!rvalid && !done && !wready);
      if (f_busy) begin
        assert (l_we == f_we && l_amo == f_amo && l_op == f_op && l_cmp == f_cmp && l_wd == f_wd);
        if (wready) assert (f_we && !f_amo);
        if (rvalid) assert (!f_we || f_amo);
        // done comes with the last beat, and only then
        if (f_amo) begin
          assert (f_n == 0 && done == rvalid);
        end else begin
          assert (f_n <= f_beats);
          assert (done == (f_beats == 0 ? st == M_DONE : (f_beat && f_n + 24'd1 == f_beats)));
          if (f_beat) assert (f_n < f_beats);
        end
        // the engine's counters against the beats counted here
        case (st)
          M_LAT:  assert (f_n == 0 && f_t + 32'(lat) == 32'(LAT) && a == f_base && left == f_beats && out_left == f_beats && !q_valid && (f_amo || f_beats != 0));
          M_RD:   begin
            assert (!f_we && !f_amo && f_beats != 0 && out_left == f_beats - f_n && out_left != 0);
            assert (out_left == left + 24'(q_valid) && a == AW'(f_base + AW'(f_beats - left)));
            assert (f_t == 32'(LAT) + 32'd1 + 32'(f_beats - left));
          end
          M_WR:   assert (f_we && !f_amo && f_beats != 0 && left == f_beats - f_n && left != 0 && a == f_idx);
          M_AMO1: assert (f_amo && a == f_base && f_t == 32'(LAT) + 32'd1);
          M_AMO2: assert (f_amo && a == f_base && f_t == 32'(LAT) + 32'd2);
          M_DONE: assert (!f_amo && f_beats == 0 && f_t == 0);
          default: ;
        endcase
        // ---- data
        if (st == M_RD && q_valid && f_idx == f_w) assert (rdata == f_m);
        if (st == M_AMO2 && f_base == f_w) assert (rdata == f_m && wr_en && wr_a == f_w && wr_d == f_amo_new);
      end
    end
  end
  // the word changes only by a write beat or an atomic that names it
  always_ff @(posedge clk)
    if (f_past && f_rstd && !$past(rst)) begin
      if ($past(f_busy) && $past(wvalid && wready) && $past(f_idx) == f_w) begin
        assert (f_m == $past(wdata));
      end else if ($past(f_busy) && $past(st) == M_AMO2 && $past(f_base) == f_w) begin
        assert (f_m == $past(f_amo_new));
      end else begin
        assert (f_m == $past(f_m));
      end
    end

  // ---- not vacuous
  always_comb begin
    cover (f_rstd && f_busy && done && !f_we && !f_amo && f_beats == 24'd3 && f_idx == f_w && f_m != 0);
    cover (f_rstd && f_busy && done && f_we && f_beats == 24'd2);
    cover (f_rstd && f_busy && done && f_amo && f_op == 3'd2 && f_base == f_w && f_m == f_cmp && f_wd != f_m);
    cover (f_rstd && f_busy && done && f_beats == 0 && !f_amo);
  end
