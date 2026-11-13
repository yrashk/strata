// Properties of strata_top's own logic: the capability inboxes and the
// revocation granule walker (included in the module when FORMAL is defined).
//
// The cores, the devices, the memories and the bus are cut out
// (formal/top.sby): everything they drive is unconstrained except as
// assumed below. So these properties hold for any cores and devices that
// keep to the assumptions.
//
// What is proved:
//   inboxes    no queue ever holds more than SQ gifts; a gift is
//              acknowledged only if it was offered, at most one per
//              destination per cycle, the lowest-numbered sender with room
//              first, and one is acknowledged whenever one can be; an
//              acknowledged gift is stored (or pushed to the block device)
//              in that cycle, and nothing else is; a take hits only a
//              queue that holds a gift and pops only that queue; and for
//              one gift chosen by the solver (any core, any sender): it
//              comes out of its queue after exactly the gifts that were
//              ahead of it, unchanged, once. The only way a stored gift is
//              dropped is the documented one, a reset request for the
//              receiving core.
//   walker     one walk at a time, for the lowest-numbered core asking;
//              done goes to that core only, once; the table is written only
//              by a walk, inside the table; a walk ends within
//              3 * granules + 6 cycles; when it ends, every granule of the
//              range walked has the new generation, which is above every
//              generation the range had (unless the 16-bit generation wraps:
//              then w_m was 0xffff), with heads exactly where the unit
//              boundaries are (the range's start; for crevoke / cundom also
//              the capability's start and end).
//   stale done (F_STALE = 1) done is given only to the request the walk was
//              started for, even if the requesting core was reset and asks
//              again while the old walk is still running.
//
// Assumed:
//   - reset in the first cycle
//   - a core pops its inbox only when its take hit (asserted for
//     strata_core in strata_core.svh)
//   - a revocation request names a non-empty range inside its table
//     (asserted for strata_core in strata_core.svh), and keeps its operands
//     while it is up
//   - a core that asks keeps asking until done, unless a reset request for
//     it is pending (strata_core: dom_req = ... && !held)
//
// Not covered: that each core's copy of the table equals this one (the
// cores are cut out; they receive the same writes), core control.

  parameter bit F_STALE = 1;

  logic f_past = 0;
  logic f_rstd = 0;
  always_comb if (!f_past) assume (rst);
  always_ff @(posedge clk) begin
    f_past <= 1;
    if (rst) f_rstd <= 1;
  end

  // ================================================================ inboxes: arbitration
  logic [NCORES-1:0] f_arb_ok;    // per destination core
  logic [NS-1:0]     f_ack_ok;    // per sender
  logic              f_dev_ok;
  always_comb begin
    logic [7:0] n, first;
    for (int c = 0; c < NCORES; c++) begin
      n     = '0;
      first = 8'(NS);
      for (int s = 0; s < NS; s++) begin
        if (g_ack[s] && g_dst[s] == 8'(c)) n = n + 8'd1;
        if (first == 8'(NS) && g_valid[s] && g_dst[s] == 8'(c) && ib_n[c][s] < 2'(SQ)) first = 8'(s);
      end
      // exactly the first sender with room is acknowledged and stored
      f_arb_ok[c] = first == 8'(NS) ? (n == 0 && !ib_we[c])
                                    : (n == 8'd1 && g_ack[first[3:0]] && ib_we[c] && ib_ws[c] == first);
    end
    n     = '0;
    first = 8'(NS);
    for (int s = 0; s < NS; s++) begin
      if (g_ack[s] && g_dst[s] == 8'(NCORES)) n = n + 8'd1;
      if (first == 8'(NS) && g_valid[s] && g_dst[s] == 8'(NCORES)) first = 8'(s);
    end
    f_dev_ok = (first == 8'(NS) || !dev_in_ready)
               ? (n == 0 && !dev_in_push)
               : (n == 8'd1 && g_ack[first[3:0]] && dev_in_push && dev_in_from == first && dev_in_cap == g_cap[first[3:0]]);
    for (int s = 0; s < NS; s++)
      f_ack_ok[s] = !g_ack[s] || (g_valid[s] && g_dst[s] <= 8'(NCORES));
  end
  always_comb
    if (f_rstd) begin
      assert (&f_arb_ok);
      assert (f_dev_ok);
      assert (&f_ack_ok);
    end

  // ================================================================ inboxes: the queues
  for (genvar c = 0; c < NCORES; c++) begin : f_ib
    logic [NS-1:0] f_cnt_ok;
    always_comb
      for (int s = 0; s < NS; s++) f_cnt_ok[s] = ib_n[c][s] <= 2'(SQ);
    // one sender and one of its gifts, chosen by the solver
    (* anyconst *) logic [3:0] f_s;
    (* anyseq *)   logic       f_pick;
    logic           f_trk = 0;    // the gift is in the queue
    logic [1:0]     f_ahead;      // gifts of this sender that are before it
    cap_t           f_cap;
    logic           f_push, f_pop;
    logic [IBW-1:0] f_slot;
    assign f_push = ib_we[c] && ib_ws[c] == 8'(f_s);
    assign f_pop  = take_pop[c] && take_s[c] == 8'(f_s);
    assign f_slot = IBW'(32'(f_s) * SQ) + IBW'(SQW'(ib_h[c][f_s] + SQW'(f_ahead)));
    always_comb assume (32'(f_s) < NS);
    // a core pops its inbox only on a hit (strata_core: take_pop = take_req && take_hit)
    always_comb assume (!take_pop[c] || take_hit[c]);
    always_ff @(posedge clk) begin
      if (rst || reset_req[c]) f_trk <= 0;
      else begin
        if (f_trk && f_pop) begin
          if (f_ahead == 0) f_trk <= 0;
          else f_ahead <= f_ahead - 2'd1;
        end
        if (!f_trk && f_push && f_pick) begin
          f_trk   <= 1;
          f_ahead <= ib_n[c][f_s] - (f_pop ? 2'd1 : 2'd0);
          f_cap   <= g_cap[f_s];
        end
      end
    end
    always_comb begin
      if (f_rstd) begin
        assert (&f_cnt_ok);
        // a take hits only a queue that holds a gift
        if (take_hit[c]) assert (take_req[c] && 32'(take_s[c]) < NS && poll_mask[c][take_s[c][3:0]]);
        assert (poll_mask[c][f_s] == (ib_n[c][f_s] != 0));
        if (f_pop) assert (ib_n[c][f_s] != 0);
        if (f_push) assert (g_ack[f_s] && g_dst[f_s] == 8'(c) && ib_n[c][f_s] < 2'(SQ));
        if (f_trk) begin
          // the gift is where the queue will look for it, unchanged
          assert (f_ahead < ib_n[c][f_s]);
          assert (g_take[c].ram[f_slot] == f_cap);
          // and it is what a take gets when its turn has come
          if (f_pop && f_ahead == 0) assert (take_cap[c] == f_cap);
          if (take_hit[c] && take_s[c] == 8'(f_s) && f_ahead == 0) assert (take_cap[c] == f_cap);
        end
      end
    end
    // it leaves the queue only by its own take (or the receiver's reset)
    always_ff @(posedge clk)
      if (f_past && f_rstd && !$past(rst) && $past(f_trk) && !f_trk)
        assert ($past(reset_req[c]) || ($past(f_pop) && $past(f_ahead) == 0));
    always_comb begin
      cover (f_rstd && f_trk && f_pop && f_ahead == 2'd1);
      cover (f_rstd && f_trk && f_pop && f_ahead == 0 && f_s == 4'(NCORES) && f_cap.valid);
      cover (f_rstd && ib_n[c][0] == 2'(SQ) && ib_n[c][NS-1] == 2'(SQ));
    end
  end

  // ================================================================ the walker
  logic [GW:0] f_end;             // granules in the table walked
  assign f_end = {1'b0, w_end};
  // the requests are well-formed and steady
  always_comb
    for (int c = 0; c < NCORES; c++)
      if (dom_req[c]) assume (dom_n[c] != 0 && {1'b0, dom_a[c]} + {1'b0, dom_n[c]} <= (dom_t2[c] ? (GW+1)'(NG2) : (GW+1)'(NG3)));
  logic [NCORES-1:0] f_rp;        // a reset request for the core is pending
  always_ff @(posedge clk) begin
    for (int c = 0; c < NCORES; c++) begin
      if (rst || reset_flush[c]) f_rp[c] <= 0;
      if (!rst && reset_req[c]) f_rp[c] <= 1;
      if (f_past && !$past(rst) && $past(dom_req[c]) && !$past(dom_done[c])) begin
        if (!f_rp[c] && !$past(reset_req[c])) assume (dom_req[c]);
        if (dom_req[c]) assume (dom_op[c] == $past(dom_op[c]) && dom_t2[c] == $past(dom_t2[c]) &&
                                dom_a[c] == $past(dom_a[c]) && dom_n[c] == $past(dom_n[c]));
      end
    end
  end

  logic [15:0] f_wt;              // cycles this walk has taken
  logic        f_cont;            // its requester has asked all along
  always_ff @(posedge clk) begin
    if (rst || ws == W_IDLE) begin
      f_wt   <= '0;
      f_cont <= 1;
    end else begin
      f_wt <= f_wt + 1;
      if (!dom_req[w_who]) f_cont <= 0;
    end
  end

  // one granule, chosen by the solver, stands for all
  (* anyconst *) logic [GW-1:0] f_g;
  logic [16:0] f_ge;              // its entry in the table being walked
  logic        f_in;              // it is in the range being rewritten (known from W_WRITE on)
  logic [16:0] f_new;             // what the walk writes there
  assign f_ge  = w_t2 ? mt2[G2W'(f_g)] : mt3[G3W'(f_g)];
  assign f_in  = f_g >= w_lo && f_g < w_hi;
  assign f_new = {f_g == w_lo || f_g == w_a || f_g == w_b, w_m + 16'd1};
  always_comb begin
    assume ({1'b0, f_g} < (GW+1)'(NG3));
    if (f_rstd) begin
      assert (ws <= W_DONE);
      assert ($onehot0(dom_done));
      if (dom_done != 0) assert (ws == W_DONE && dom_done[w_who]);
      assert (ws == W_IDLE || w_gone == !f_cont);
      if (gt_we) assert ((ws == W_WRITE || ws == W_TAIL) && gt_t2 == w_t2 && {1'b0, gt_idx} < f_end);
      if (ws != W_IDLE) begin
        assert (32'(w_who) < NCORES);
        assert (w_a < w_b && {1'b0, w_b} <= f_end && w_lo <= w_a);
        if (w_op == 2'd0) assert (w_lo == w_a);
        assert (f_wt <= 16'(3 * NG3 + 6));
      end
      case (ws)
        W_BACK: begin
          assert (w_op != 2'd0 && w_k <= w_a && w_lo == w_a && w_m == 0);
          assert (f_wt == 16'(w_a - w_k));
        end
        W_READ: begin
          assert (w_k >= w_lo && {1'b0, w_k} <= f_end);
          if (w_op == 2'd0) assert (w_k <= w_b);
          assert (f_wt <= 16'(w_a - w_lo) + 16'd1 + 16'(w_k - w_lo));
          // w_m is the highest generation read so far
          if (f_g >= w_lo && f_g < w_k) assert (f_ge[15:0] <= w_m);
        end
        W_WRITE: begin
          assert (w_k >= w_lo && w_k < w_hi && w_b <= w_hi && {1'b0, w_hi} <= f_end);
          if (w_op == 2'd0) assert (w_hi == w_b);
          assert (f_wt <= 16'(w_a - w_lo) + 16'd2 + 16'(w_hi - w_lo) + 16'(w_k - w_lo));
          if (f_in && f_g <  w_k) assert (f_ge == f_new);
          if (f_in && f_g >= w_k) assert (f_ge[15:0] <= w_m);
        end
        W_TAIL: begin
          assert (w_op == 2'd0 && w_hi == w_b);
          assert (f_wt <= 16'(3 * NG3 + 4));
          if (f_in) assert (f_ge == f_new);
        end
        W_DONE: begin
          assert (w_b <= w_hi && {1'b0, w_hi} <= f_end);
          assert (f_wt <= 16'(3 * NG3 + 5));
          // the whole range has the new generation, heads at the unit boundaries
          if (f_in) assert (f_ge == f_new && f_ge[15:0] == dom_gen);
          // a cdom's unit ends at b
          if (w_op == 2'd0 && f_g == w_b && {1'b0, w_b} < f_end) assert (f_ge[16]);
        end
        default: ;
      endcase
      // a done that its core takes (it is asking) answers the request the
      // walk was started for: the core has asked all along
      if (F_STALE && dom_done != 0 && dom_req[w_who]) assert (f_cont);
    end
  end
  // the lowest-numbered core asking is served, with its operands
  logic [NCORES-1:0]         f_q_req, f_q_t2;       // last cycle's requests
  logic [NCORES-1:0][1:0]    f_q_op;
  logic [NCORES-1:0][GW-1:0] f_q_a, f_q_n;
  logic                      f_q_idle;
  always_ff @(posedge clk) begin
    f_q_req  <= dom_req;
    f_q_t2   <= dom_t2;
    f_q_op   <= dom_op;
    f_q_a    <= dom_a;
    f_q_n    <= dom_n;
    f_q_idle <= !rst && ws == W_IDLE;
  end
  always_comb
    if (f_past && f_rstd && f_q_idle && ws != W_IDLE) begin
      assert (f_q_req[w_who] && w_a == f_q_a[w_who] && w_b == GW'(f_q_a[w_who] + f_q_n[w_who]) &&
              w_op == f_q_op[w_who] && w_t2 == f_q_t2[w_who]);
      for (int c = 0; c < NCORES; c++)
        if (f_q_req[c]) assert (32'(w_who) <= c);
    end
  // the tables change only by gt_we
  logic [16:0] f_e3, f_e2;
  assign f_e3 = mt3[G3W'(f_g)];
  assign f_e2 = mt2[0];
  always_ff @(posedge clk)
    if (f_past && f_rstd && !$past(rst)) begin
      if (!$past(gt_we && !gt_t2 && gt_idx == f_g)) assert (f_e3 == $past(f_e3));
      if (!$past(gt_we && gt_t2)) assert (f_e2 == $past(f_e2));
    end

  always_comb begin
    cover (f_rstd && ws == W_DONE && w_op == 2'd0 && !w_t2 && w_b - w_a == GW'(3));
    cover (f_rstd && ws == W_DONE && w_op == 2'd1 && !w_t2 && w_lo < w_a && w_hi > w_b);
    cover (f_rstd && ws == W_DONE && w_t2);
    cover (f_rstd && dev_in_push);
  end
