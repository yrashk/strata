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

  // ---- not vacuous
  always_comb begin
    cover (f_rstd && f_busy && done && !f_we && f_beats == 24'd3);
    cover (f_rstd && f_busy && done && f_we && f_beats == 24'd2);
    cover (f_rstd && f_busy && retry);
    cover (f_rstd && f_busy && retry && f_n != 0);    // (only with a core reset under the transaction)
  end
