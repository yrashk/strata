// Properties of strata_dev as a far-bus target (included in the module when
// FORMAL is defined): the burst protocol strata_tu.svh assumes of the
// device space, whatever port is addressed and whatever the devices'
// state.
//
// What is proved, for every transaction (from start to done or retry):
//   burst      a read gives at most `beats` read beats and a write takes at
//              most `beats` write beats; done comes with the last beat and
//              only then (an empty burst: the next cycle, without a beat);
//              no beat, done or retry outside a transaction; no read beat
//              in a write, wready only in a write
//   retry      only in a read, never with a beat or with done, and only
//              before the first beat (unless the transaction's core was
//              reset under it, which strata_core does not do: it is reset
//              only when its Transfer Unit is quiet); it ends the
//              transaction
//   wake       a core's wake line is raised only for a core that has a
//              read waiting (one that was answered retry); and it is
//              raised, the next cycle, whenever a core's waiting read on
//              the break port, the console input, WAIT, VSYNC, EVENT or RX
//              would complete if tried now
//
// Assumed (the bus: proved for strata_bus):
//   - reset in the first cycle
//   - a transaction is started only when none is under way
// Everything else (the UART's pins, gifts, core resets, the block device's
// own bus master) is unconstrained.
//
// Not covered: what each port returns or does, the block device's command
// engine and its DMA master.

  logic f_past = 0;
  logic f_rstd = 0;
  always_comb if (!f_past) assume (rst);
  always_ff @(posedge clk) begin
    f_past <= 1;
    if (rst) f_rstd <= 1;
  end

  logic        f_busy = 0;        // a transaction is under way
  logic        f_we;
  logic [23:0] f_beats, f_n;      // beats asked for, beats so far
  logic        f_beat;            // a beat moves this cycle
  assign f_beat = rvalid || (wvalid && wready);
  always_comb if (start) assume (!f_busy);
  logic        f_clr;             // the transaction's core was reset during it (strata_core does not:
                                  // it resets only when its Transfer Unit is quiet)
  always_ff @(posedge clk) begin
    if (rst) f_busy <= 0;
    else if (start) begin
      f_busy  <= 1;
      f_we    <= we;
      f_beats <= beats;
      f_n     <= '0;
      f_clr   <= 0;
    end else if (f_busy) begin
      if (core_clr[t_core[$clog2(NCORES)-1:0]] && 32'(t_core) < NCORES) f_clr <= 1;
      if (f_beat) f_n <= f_n + 1;
      if (done || retry) f_busy <= 0;
    end
  end

  always_comb begin
    if (f_rstd) begin
      assert (f_busy == (ts != T_IDLE));
      if (!f_busy) assert (!rvalid && !done && !retry && !wready);
      if (f_busy) begin
        assert (t_we == f_we && t_n == f_beats && t_idx == f_n && f_n <= f_beats);
        assert ((ts == T_DONE) == (f_beats == 0));
        if (ts == T_RUN) assert (f_n < f_beats);
        if (rvalid) assert (!f_we);
        if (wready) assert (f_we);
        if (f_beat) assert (f_n < f_beats);
        assert (done == (f_beats == 0 ? 1'b1 : (f_beat && f_n + 24'd1 == f_beats)));
        if (retry) assert (!f_we && !rvalid && !done && f_n < f_beats);
        // before any data (the far bus's rule), unless the core was reset under its own transaction
        if (retry) assert (f_n == 0 || f_clr);
      end
    end
  end

  // ---- wake
  logic [NCORES-1:0] f_waits, f_now;   // per core: a read waits; one would complete now
  always_comb
    for (int c = 0; c < NCORES; c++) begin
      f_waits[c] = brk_wait[c] || in_wait[c] || tw_wait[c] || vs_armed[c] || ptr_wait[c] || net_wait[c];
      // each port's completion condition as the read path (above) tests it
      // for this core, with the per-core state of the read that waits
      f_now[c] = (brk_wait[c] && (brk_rel[c] || brk_cnt != 0)) ||
                 (in_wait[c] && (in_rel[c] || rx_ok)) ||
                 (tw_wait[c] && now >= deadline) ||
                 (vs_armed[c] && frame > vs_from[c]) ||
                 (ptr_wait[c] && (ptr_rel[c] || ptr_have)) ||
                 (net_wait[c] && (net_rel[c] || (net_open && 32'(net_core) == c)));
    end
  always_ff @(posedge clk)
    if (f_past && f_rstd && !$past(rst))
      for (int c = 0; c < NCORES; c++) begin
        if (wake[c]) assert ($past(f_waits[c]));
        if ($past(f_now[c])) assert (wake[c]);
      end

  // ---- not vacuous
  always_comb begin
    cover (f_rstd && f_busy && done && !f_we && f_beats == 24'd3);
    cover (f_rstd && f_busy && done && f_we && f_beats == 24'd2);
    cover (f_rstd && f_busy && retry);
    cover (f_rstd && f_busy && retry && f_n != 0);    // (only with a core reset under the transaction)
    cover (f_rstd && wake[0] && brk_wait[0]);
    cover (f_rstd && wake[1] && tw_wait[1]);
  end
