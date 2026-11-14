// Properties of strata_bus (included in the module when FORMAL is defined).
//
// What is proved (for the module's NM; formal/bus.sby runs NM = 3 and 5):
//   grant      at most one master is granted, only a requesting one, only
//              while the bus is idle, and an idle bus grants at once; the
//              choice is round-robin (nobody between the pointer and the
//              granted master is asking)
//   ownership  from the grant to the end of the transaction the bus belongs
//              to that master (f_owner): every wready, rvalid, done and
//              retry goes to it and to nobody else, and the target sees the
//              command it asked for at the grant, unchanged
//   start      exactly one target is started, once, the cycle after the
//              grant; a space without a target completes at once instead
//   beats      a write beat moves at the master exactly when it moves at
//              the target, with the same data; a read beat likewise: none
//              is lost, none is made up
//   end        the target's done or retry reaches the owner in the same
//              cycle and the bus is idle (and can grant) in the next: a
//              retry gives the bus back
//   liveness   (bounded, under the fairness assumptions below) a master
//              that keeps asking is granted within NM * (F_T + 2) cycles
//
// Assumed:
//   - reset in the first cycle;
//   - nothing about the masters' or the targets' signals, for everything
//     but liveness;
//   - for liveness only (F_LIVE = 1): the master in question keeps its
//     request up until it is granted (the others may do as they like), and
//     every target ends a transaction (done or retry) within F_T cycles of
//     its start.

  parameter bit F_LIVE = 0;
  parameter int F_T    = 4;

  logic          f_past = 0;
  logic          f_rstd = 0;
  logic          f_busy = 0;      // a transaction is under way
  logic [MW-1:0] f_owner;         // its master
  // the command the owner asked for when it was granted
  logic          f_we, f_amo, f_byte;
  logic [2:0]    f_op, f_space;
  logic [63:0]   f_addr, f_cmp;
  logic [23:0]   f_beats;
  logic          f_started;       // its target has been started
  logic [7:0]    f_act;           // cycles the target has had

  // the target a space goes to (4: none)
  function automatic logic [2:0] f_route(input logic [2:0] sp);
    return sp == 3'd3 ? 3'd0 : sp == 3'd2 ? 3'd1 : sp == 3'd4 ? 3'd2 : sp == 3'd5 ? 3'd3 : 3'd4;
  endfunction
  logic [2:0] f_tgt;
  logic       f_end;              // the transaction ends this cycle
  assign f_tgt = f_route(f_space);
  assign f_end = f_busy && (m_done[f_owner] || m_retry[f_owner]);

  always_comb if (!f_past) assume (rst);

  always_ff @(posedge clk) begin
    f_past <= 1;
    if (rst) begin
      f_rstd <= 1;
      f_busy <= 0;
    end else begin
      for (int i = 0; i < NM; i++)
        if (m_gnt[i]) begin
          f_busy    <= 1;
          f_owner   <= MW'(i);
          f_we      <= m_we[i];
          f_amo     <= m_amo[i];
          f_op      <= m_amo_op[i];
          f_space   <= m_space[i];
          f_addr    <= m_addr[i];
          f_beats   <= m_beats[i];
          f_byte    <= m_byte[i];
          f_cmp     <= m_cmp[i];
          f_started <= 0;
          f_act     <= '0;
        end
      if (t_start != 0) f_started <= 1;
      if (f_busy && f_started) f_act <= f_act + 1;
      if (f_end) f_busy <= 0;
    end
  end

  // ---- grant
  always_comb begin
    if (f_rstd) begin
      assert ($onehot0(m_gnt));
      assert ((m_gnt & ~m_req) == 0);
      if (m_gnt != 0) assert (!f_busy);
      if (!f_busy) assert ((m_gnt != 0) == (m_req != 0));
      assert (32'(rr) < NM);
      // round-robin: no requester is nearer the pointer than the granted master
      for (int i = 0; i < NM; i++)
        for (int j = 0; j < NM; j++)
          if (m_gnt[i] && m_req[j])
            assert ((i + NM - int'(rr)) % NM <= (j + NM - int'(rr)) % NM);
    end
  end

  // ---- ownership, the command, the start
  always_comb begin
    if (f_rstd) begin
      assert (f_busy == (st != B_IDLE));
      if (!f_busy) begin
        assert (m_wready == 0 && m_rvalid == 0 && m_done == 0 && m_retry == 0);
        assert (t_start == 0 && !t_wvalid);
      end else begin
        assert (32'(f_owner) < NM && cur == f_owner && t_master == 8'(f_owner));
        assert (tgt == f_tgt);
        for (int i = 0; i < NM; i++)
          if (MW'(i) != f_owner)
            assert (!m_wready[i] && !m_rvalid[i] && !m_done[i] && !m_retry[i]);
        assert (t_we == f_we && t_amo == f_amo && t_amo_op == f_op && t_addr == f_addr);
        assert (t_beats == f_beats && t_byte == f_byte && t_cmp == f_cmp);
        assert (f_started == (st == B_ACT));
        // started once, the cycle after the grant, and only the routed target
        if (f_started) begin
          assert (t_start == 0 && f_tgt != 3'd4);
        end else begin
          assert (t_start == (f_tgt == 3'd4 ? 4'b0000 : 4'b0001 << f_tgt));
          // no target: complete at once, nothing else
          assert (m_done[f_owner] == (f_tgt == 3'd4));
          assert (!m_retry[f_owner] && !m_wready[f_owner] && !m_rvalid[f_owner] && !t_wvalid);
        end
        // ---- beats and the end: the owner and its target are connected
        if (f_started) begin
          assert (t_wvalid == m_wvalid[f_owner]);
          assert (t_wdata == m_wdata[f_owner]);
          assert (m_wready[f_owner] == t_wready[f_tgt[1:0]]);
          assert (m_rvalid[f_owner] == t_rvalid[f_tgt[1:0]]);
          if (m_rvalid[f_owner]) assert (m_rdata == t_rdata[f_tgt[1:0]]);
          assert (m_done[f_owner]  == t_done[f_tgt[1:0]]);
          assert (m_retry[f_owner] == t_retry[f_tgt[1:0]]);
        end
      end
    end
  end

  // the bus is idle the cycle after a transaction ends, never before
  always_ff @(posedge clk)
    if (f_past && f_rstd && !$past(rst) && $past(f_busy)) assert (f_busy == !$past(f_end));

  // ---- bounded liveness, for one master chosen by the solver
  (* anyconst *) logic [MW-1:0] f_i;
  logic [15:0] f_wait;            // cycles it has been asking without a grant
  always_comb begin
    assume (32'(f_i) < NM);
    if (F_LIVE) begin
      // the targets answer in time
      if (f_busy && f_started && f_act == 8'(F_T - 1)) assume (f_end);
    end
  end
  always_ff @(posedge clk) begin
    if (rst || !m_req[f_i] || m_gnt[f_i]) f_wait <= '0;
    else f_wait <= f_wait + 1;
    // the master keeps asking until granted
    if (F_LIVE && f_past && !$past(rst) && $past(m_req[f_i]) && !$past(m_gnt[f_i])) assume (m_req[f_i]);
  end
  always_comb
    if (F_LIVE && f_rstd) begin
      assert (!(f_busy && f_started) || f_act < 8'(F_T));
      assert (f_wait < 16'(NM * (F_T + 2)));
    end

  // ---- not vacuous
  always_comb begin
    cover (f_rstd && f_busy && f_started && m_wvalid[f_owner] && m_wready[f_owner] && f_owner == MW'(NM - 1));
    cover (f_rstd && f_busy && m_rvalid[f_owner] && f_tgt == 3'd2);
    cover (f_rstd && f_busy && m_retry[f_owner]);
    cover (f_rstd && f_busy && !f_started && m_done[f_owner]);          // no such space
    cover (f_rstd && F_LIVE && f_wait == 16'(NM * (F_T + 2) - 1));      // the bound is reached
    cover (f_rstd && m_gnt[0] && rr == MW'(1));                           // the pointer wraps
  end
  always_ff @(posedge clk)
    cover (f_past && f_rstd && !$past(rst) && $past(f_end) && $past(m_retry[f_owner]) && m_gnt != 0 && !m_gnt[$past(f_owner)]);
