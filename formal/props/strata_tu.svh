// Properties of strata_tu (included in the module when FORMAL is defined).
//
// What is proved:
//   queue      count, head, tail and the valid bits agree (the valid slots
//              are the count slots from head); every entry's derived fields
//              (its end, its non-empty flag) match its range; a tag is busy
//              exactly when one queued entry carries it, never two
//   status     idle, mem_idle, put_idle, cc_busy say what is queued; quiet
//              implies that only device reads that have been tried are left
//              and that the unit holds no bus transaction past this cycle
//   hazards    for any Local Store byte B: while a queued tget covers B, a
//              load or store query covering B stalls; while a queued tput
//              covers B, a store query stalls; while a queued tgetx covers
//              B, a fetch covering B stalls; a command whose D-LS range
//              covers a byte of a queued device read is not accepted. And
//              the other way round: no stall without such an entry.
//   writes     the unit writes the Local Stores only inside the range of
//              the command at the head of the queue, at head.ls + bytes
//              moved, with the bus's data (a device byte in its byte lane)
//   put data   every beat of a tput carries the Local Store word (or byte)
//              at head.ls + bytes moved, read after the command was issued
//              (shown for one word chosen by the solver, so for all)
//   no loss    an accepted command (A, chosen by the solver) stays in the
//              queue, unchanged, its tag busy, until it is retired; it is
//              retired only at the head and only after the bus said done
//              (or at once if it is empty); its bus request is the command
//              (space, direction, far address + bytes moved, beats left);
//              when it retires all its bytes have moved
//   order      of two accepted commands A and then B, B retires first only
//              if A was rotated behind it; only a device read that was
//              answered retry before any data, with another command
//              queued, is rotated
//   progress   the engine never waits on itself: a tput in transfer always
//              has a word buffered, arriving or being fetched; retire and
//              rotate take one cycle
//
// Assumed (the environment: the core and the far bus):
//   - reset in the first cycle; a flush only when quiet (strata_core:
//     reset_flush = S_RQ && tu_quiet)
//   - an issued command is tget, tput or tgetx; its Local Store range is
//     inside the largest store (no wrap); a transfer that is not a device
//     transfer has an 8-byte aligned address and length; a tgetx is not a
//     device transfer (strata_core's xf_fault checks all four before
//     iss_valid)
//   - the bus grants only a request, and answers (rvalid, done, retry) only
//     a granted transaction (proved for strata_bus)
//   - the target keeps to the burst: no read beat beyond the beats asked
//     for, done only with or after the last beat, retry only to a device
//     read that still has bytes to come, and not together with a beat or
//     done (strata_mem, strata_dev)
//   - a Local Store read returns, the next cycle, the word at the address
//     read (strata_ram), for the one word the put-data property watches
//
// Not proved here: liveness (a transfer completes eventually), which
// depends on the bus and the devices.

  parameter bit F_EMB = 0;        // inside strata_core: the core's side of the contract is asserted
  localparam int F_LS = 65536;    // the largest Local Store

  logic f_past = 0;
  logic f_rstd = 0;
  always_comb if (!f_past) assume (rst);
  always_ff @(posedge clk) begin
    f_past <= 1;
    if (rst) f_rstd <= 1;
  end

  // ================================================================ assumptions
  logic f_bus;                    // the unit owns a bus transaction
  always_ff @(posedge clk) begin
    if (rst || flush) f_bus <= 0;
    else if (b_gnt) f_bus <= 1;
    else if (b_done || b_retry) f_bus <= 0;
  end
  logic        f_beat;            // a beat moves this cycle
  logic [17:0] f_off_n;           // bytes moved after this cycle
  assign f_beat  = es == E_XFER && (h_put ? pop : b_rvalid);
  assign f_off_n = 18'(off) + (f_beat ? 18'(step) : 18'd0);
  // the core's side of the contract: assumed when the unit is proved alone,
  // asserted when it is inside strata_core (F_EMB)
  logic f_core_ok;
  assign f_core_ok = (!flush || quiet) &&
                     (!iss_valid || (iss_kind <= XF_GETX && 18'(iss_ls) + 18'(iss_len) <= 18'(F_LS) &&
                                     (iss_space == SP_DEV || (iss_ls[2:0] == 0 && iss_len[2:0] == 0)) &&
                                     !(iss_kind == XF_GETX && iss_space == SP_DEV)));
  always_comb begin
    if (F_EMB) begin
      if (f_rstd) assert (f_core_ok);
    end else begin
      assume (f_core_ok);
    end
    assume (!b_gnt || b_req);
    if (!f_bus) assume (!b_rvalid && !b_done && !b_retry);
    if (b_rvalid) assume (!h_put && off < h_len);
    if (b_done) assume (f_off_n == 18'(h_len));
    if (b_retry) assume (h_dev && !h_put && !b_rvalid && !b_done && off < h_len);
  end

  // ================================================================ queue
  logic [2:0]    f_nv;            // valid entries
  logic [QD-1:0] f_inq;           // slot i is one of the count slots from head
  always_comb begin
    f_nv = '0;
    for (int i = 0; i < QD; i++) begin
      f_nv     = f_nv + 3'(q_v[i]);
      f_inq[i] = {1'b0, 2'(2'(i) - head)} < count;
    end
  end
  // per tag: the valid entries that carry it are tag_busy's bit, 0 or 1
  logic [NTAGS-1:0] f_tag_ok;
  always_comb
    for (int t = 0; t < NTAGS; t++)
      f_tag_ok[t] = (3'(q_v[0] && q_tag[0] == 4'(t)) + 3'(q_v[1] && q_tag[1] == 4'(t)) +
                     3'(q_v[2] && q_tag[2] == 4'(t)) + 3'(q_v[3] && q_tag[3] == 4'(t))) == 3'(tag_busy[t]);
  always_comb begin
    if (f_rstd) begin
      assert (count <= 3'(QD));
      assert (count == f_nv);
      assert (q_v == f_inq);
      assert (tail == 2'(head + 2'(count)));
      assert (&f_tag_ok);
    end
  end
  // one entry, chosen by the solver, stands for all
  (* anyconst *) logic [1:0] f_s;
  logic [17:0] f_s_end;
  assign f_s_end = 18'(q_ls[f_s]) + 18'(q_len[f_s]);
  always_comb begin
    if (f_rstd && q_v[f_s]) begin
      // ---- status
      assert (!idle);
      if (q_sp[f_s] != SP_DEV) assert (!mem_idle);
      if (!(q_sp[f_s] == SP_DEV && q_kind[f_s] == XF_GET)) assert (!put_idle && !quiet);
      if (q_sp[f_s] == SP_CORE) assert (cc_busy);
      // quiet: this entry is a device read that waits (or is answered retry now)
      if (quiet) assert (q_w[f_s] || (f_s == head && b_retry));
    end
    if (f_rstd) begin
      assert (idle == (f_nv == 0));
      // quiet: no transaction of ours is open after this cycle
      if (quiet) assert (!b_gnt && (!f_bus || b_retry));
    end
  end
  // every entry's derived fields
  logic [QD-1:0] f_wf;
  always_comb
    for (int i = 0; i < QD; i++)
      f_wf[i] = !q_v[i] ||
                (q_kind[i] <= XF_GETX && !(q_kind[i] == XF_GETX && q_sp[i] == SP_DEV) && 18'(q_ls[i]) + 18'(q_len[i]) <= 18'(F_LS) &&
                 q_end[i] == q_ls[i] + q_len[i] && q_nz[i] == (q_len[i] != 0) &&
                 (q_sp[i] == SP_DEV || (q_ls[i][2:0] == 0 && q_len[i][2:0] == 0)));
  always_comb if (f_rstd) assert (&f_wf);
  // the status outputs are not raised without cause either
  logic f_any_mem, f_any_nonrd, f_any_cc;
  always_comb begin
    f_any_mem   = 0;
    f_any_nonrd = 0;
    f_any_cc    = 0;
    for (int i = 0; i < QD; i++) begin
      if (q_v[i] && q_sp[i] != SP_DEV) f_any_mem = 1;
      if (q_v[i] && !(q_sp[i] == SP_DEV && q_kind[i] == XF_GET)) f_any_nonrd = 1;
      if (q_v[i] && q_sp[i] == SP_CORE) f_any_cc = 1;
    end
  end
  always_comb
    if (f_rstd) begin
      assert (mem_idle == !f_any_mem);
      assert (put_idle == !f_any_nonrd);
      assert (cc_busy == f_any_cc);
    end

  // ================================================================ hazards
  // for one byte B and the entry f_s: covered means stalled
  (* anyconst *) logic [16:0] f_B;
  logic f_s_cov, f_hz_cov, f_pc_cov, f_iss_cov;
  assign f_s_cov   = q_v[f_s] && 18'(q_ls[f_s]) <= 18'(f_B) && 18'(f_B) < f_s_end;
  assign f_hz_cov  = 18'(hz_addr) <= 18'(f_B) && 18'(f_B) < 18'(hz_addr) + 18'(hz_len);
  assign f_pc_cov  = 18'(hz_pc) <= 18'(f_B) && 18'(f_B) < 18'(hz_pc) + 18'd4;
  assign f_iss_cov = 18'(iss_ls) <= 18'(f_B) && 18'(f_B) < 18'(iss_ls) + 18'(iss_len);
  always_comb begin
    if (f_rstd && f_s_cov) begin
      // (a query that wraps past the largest store's end is outside every
      // store: the core traps on it and does not look at the answer)
      if (q_kind[f_s] == XF_GET && f_hz_cov && 18'(hz_addr) + 18'(hz_len) <= 18'(F_LS))
        assert (hz_rd_stall && hz_wr_stall);
      if (q_kind[f_s] == XF_PUT && f_hz_cov && 18'(hz_addr) + 18'(hz_len) <= 18'(F_LS))
        assert (hz_wr_stall);
      if (q_kind[f_s] == XF_GETX && f_pc_cov && 18'(hz_pc) + 18'd4 <= 18'(F_LS))
        assert (hz_fetch_stall);
      if (q_sp[f_s] == SP_DEV && q_kind[f_s] == XF_GET && iss_valid && iss_kind != XF_GETX && f_iss_cov)
        assert (iss_hz && !iss_ready);
    end
  end
  // and no stall without an entry that overlaps the query
  logic f_ov_rd, f_ov_wr, f_ov_pc, f_ov_iss;
  always_comb begin
    logic [17:0] e, he, pe, ie;
    f_ov_rd  = 0;
    f_ov_wr  = 0;
    f_ov_pc  = 0;
    f_ov_iss = 0;
    he = 18'(hz_addr) + 18'(hz_len);
    pe = 18'(hz_pc) + 18'd4;
    ie = 18'(iss_ls) + 18'(iss_len);
    for (int i = 0; i < QD; i++) begin
      e = 18'(q_ls[i]) + 18'(q_len[i]);
      if (q_v[i] && q_kind[i] != XF_GETX && 18'(q_ls[i]) < he && 18'(hz_addr) < e) begin
        f_ov_wr = 1;
        if (q_kind[i] == XF_GET) f_ov_rd = 1;
      end
      if (q_v[i] && q_kind[i] == XF_GETX && 18'(q_ls[i]) < pe && 18'(hz_pc) < e) f_ov_pc = 1;
      if (q_v[i] && q_sp[i] == SP_DEV && q_kind[i] == XF_GET && 18'(q_ls[i]) < ie && 18'(iss_ls) < e) f_ov_iss = 1;
    end
  end
  always_comb
    if (f_rstd) begin
      if (hz_rd_stall) assert (f_ov_rd);
      if (hz_wr_stall) assert (f_ov_wr);
      if (hz_fetch_stall) assert (f_ov_pc);
      if (iss_hz) assert (f_ov_iss && iss_kind != XF_GETX);
    end

  // ================================================================ the engine
  logic [17:0] f_h_end;           // the head's range
  logic [LSW-1:0] f_A;            // where the next beat goes or comes from
  assign f_h_end = 18'(h_ls) + 18'(h_len);
  assign f_A     = h_ls + off;
  always_comb begin
    if (f_rstd) begin
      assert (es <= E_ROT);
      assert (f_bus == (es == E_XFER));
      if (es != E_IDLE) begin
        assert (q_v[head]);
        assert (off <= h_len);
        if (!h_dev) assert (off[2:0] == 0);
      end
      if (es == E_RETIRE) assert (off == h_len);              // all of it has moved
      // only a device read answered retry before any data is rotated, and
      // only behind another command
      if (es == E_ROT) assert (h_dev && h_kind == XF_GET && q_w[head] && off == 0 && count > 3'd1);
      if (es == E_REQ) assert (off < h_len);
      if (es == E_XFER) assert (h_len != 0);
      if (es == E_REQ && h_put) assert (off == 0 && rd_off == 0 && pf_cnt == 0 && !pf_inflight);
    end
  end

  // ---- the unit's Local Store writes
  always_comb begin
    if (f_rstd) begin
      if (!dls_en) assert (dls_we == 0);
      if (dls_en && dls_we != 0) begin
        assert (es == E_XFER && h_kind == XF_GET && b_rvalid);
        assert (dls_addr == f_A[15:3]);
        assert (18'(f_A) + 18'(step) <= f_h_end);             // inside the head's range
        if (h_dev) begin
          assert (dls_we == 8'(1) << f_A[2:0]);
          assert (8'(dls_wdata >> {f_A[2:0], 3'b000}) == b_rdata[7:0]);
        end else begin
          assert (dls_we == 8'hff && dls_wdata == b_rdata);
        end
      end
      if (ils_en) begin
        assert (es == E_XFER && h_kind == XF_GETX && b_rvalid && !h_dev);
        assert (ils_addr == f_A[15:3] && ils_wdata == b_rdata);
        assert (18'(f_A) + 18'd8 <= f_h_end);
      end
      // a Local Store read is the prefetch of a tput, inside its range
      if (dls_en && dls_we == 0) begin
        assert (es == E_XFER && h_put && dls_addr == p_ls[15:3]);
        assert (18'(p_ls) + 18'(step) <= f_h_end);
      end
    end
  end

  // ---- put data: the prefetch buffer, watched through one Local Store word
  (* anyconst *) logic [12:0] f_wa;
  (* anyconst *) logic [63:0] f_wd;
  logic        f_rd;              // a Local Store read was issued last cycle
  logic [12:0] f_rd_a;            // at this word
  always_ff @(posedge clk) begin
    f_rd   <= !rst && dls_en && dls_we == 0;
    f_rd_a <= dls_addr;
  end
  always_comb if (f_rd && f_rd_a == f_wa) assume (dls_rdata == f_wd);
  logic [LSW-1:0] f_p0, f_p1, f_pr;
  assign f_p0 = h_ls + pf_o[0];
  assign f_p1 = h_ls + pf_o[1];
  assign f_pr = h_ls + pf_rd_o;
  always_comb begin
    if (f_rstd && es == E_XFER && h_put) begin
      assert (pf_cnt <= 2'd2 && 3'(pf_cnt) + 3'(pf_inflight) <= 3'd2);
      // what is buffered or arriving is the next words in order
      assert (rd_off == off + (h_dev ? LSW'(3'(pf_cnt) + 3'(pf_inflight))
                                     : {11'b0, 3'(pf_cnt) + 3'(pf_inflight), 3'b0}));
      assert (rd_off <= h_len);
      if (pf_cnt >= 2'd1) assert (pf_o[0] == off);
      if (pf_cnt == 2'd2) assert (pf_o[1] == off + step);
      if (pf_inflight) begin
        assert (pf_rd_o == (pf_cnt == 0 ? off : pf_cnt == 2'd1 ? off + step : off + step + step));
        assert (f_rd && f_rd_a == f_pr[15:3]);
      end
      // and holds what the Local Store held
      if (pf_cnt >= 2'd1 && f_p0[15:3] == f_wa) assert (pf_d[0] == f_wd);
      if (pf_cnt == 2'd2 && f_p1[15:3] == f_wa) assert (pf_d[1] == f_wd);
      // a beat carries the word, or the byte, at head.ls + bytes moved
      if (pop && f_A[15:3] == f_wa)
        assert (b_wdata == (h_dev ? 64'(8'(f_wd >> {f_A[2:0], 3'b000})) : f_wd));
      // progress: something is buffered, arriving or being fetched
      if (off < h_len) assert (pf_cnt != 0 || pf_inflight || pf_issue);
    end
    if (f_rstd && !(es == E_XFER && h_put)) assert (!b_wvalid && !pf_issue);
  end
  // retire and rotate take one cycle; an idle engine with work starts it
  always_ff @(posedge clk)
    if (f_past && f_rstd && !$past(rst) && !$past(flush)) begin
      if ($past(es) == E_RETIRE || $past(es) == E_ROT) assert (es == E_IDLE);
      if ($past(es) == E_IDLE && $past(count) != 0) assert (es != E_IDLE);
    end

  // ================================================================ no loss, order
  // Two accepted commands are followed through the queue: A, picked at any
  // issue, and B, picked at any later issue while A is still queued.
  (* anyseq *) logic f_pickA, f_pickB;
  logic        f_tA = 0, f_tB = 0;   // followed
  logic [1:0]  f_sA, f_sB;           // the slot each is in
  logic        f_AB;                 // A is before B in the queue
  logic        f_rotA;               // A was rotated behind B
  logic        f_doneA;              // the bus said done for A
  logic [2:0]  f_kA, f_spA;
  logic [3:0]  f_tagA;
  logic [LSW-1:0] f_lsA, f_lenA;
  logic [FW-1:0]  f_farA;
  always_ff @(posedge clk) begin
    if (rst || flush) begin
      f_tA <= 0;
      f_tB <= 0;
    end else begin
      if (es == E_ROT) begin
        if (f_tA && f_sA == head) begin f_sA <= tail; f_AB <= 0; if (f_tB) f_rotA <= 1; end
        if (f_tB && f_sB == head) begin f_sB <= tail; f_AB <= 1; end
      end
      if (es == E_XFER && f_tA && f_sA == head && b_done) f_doneA <= 1;
      if (do_retire) begin
        if (f_tA && f_sA == head) f_tA <= 0;
        if (f_tB && f_sB == head) f_tB <= 0;
        // (B is followed only together with A)
        if (f_tA && f_sA == head) f_tB <= 0;
      end
      if (do_issue) begin
        if (!f_tA && !f_tB && f_pickA) begin
          f_tA    <= 1;
          f_sA    <= tail;
          f_doneA <= 0;
          f_kA    <= iss_kind;
          f_spA   <= iss_space;
          f_tagA  <= iss_tag;
          f_lsA   <= iss_ls;
          f_lenA  <= iss_len;
          f_farA  <= iss_far;
        end else if (f_tA && !f_tB && f_pickB && !(do_retire && f_sA == head)) begin
          f_tB   <= 1;
          f_sB   <= tail;
          f_AB   <= 1;
          f_rotA <= 0;
        end
      end
    end
  end
  logic f_atA;                    // A is at the head
  assign f_atA = f_tA && f_sA == head;
  always_comb begin
    if (f_rstd && f_tA) begin
      // A is still there, as issued
      assert (q_v[f_sA] && tag_busy[f_tagA]);
      assert (q_kind[f_sA] == f_kA && q_sp[f_sA] == f_spA && q_tag[f_sA] == f_tagA);
      assert (q_ls[f_sA] == f_lsA && q_len[f_sA] == f_lenA && q_far[f_sA] == f_farA);
      // its request on the bus is the command, from where it has got to
      if (f_atA && b_req) begin
        assert (b_we == (f_kA == XF_PUT) && b_space == f_spA && b_byte == (f_spA == SP_DEV));
        assert (b_addr == 64'(f_farA + FW'(off)));
        assert (b_beats == (f_spA == SP_DEV ? 24'(f_lenA - off) : 24'((f_lenA - off) >> 3)));
        assert (b_beats != 0);
      end
      // it retires only when done (an empty one at once)
      if (f_atA && do_retire) assert (f_lenA == 0 || f_doneA);
      if (f_doneA) assert (f_atA && es == E_RETIRE);
      if (f_atA && es == E_XFER && b_done) assert (!f_doneA);
    end
    if (f_rstd && f_tB) begin
      assert (f_tA && q_v[f_sB] && f_sA != f_sB);
      // the ghost order is the queue's order
      assert (f_AB == (2'(f_sA - head) < 2'(f_sB - head)));
      // B is before A only if A was rotated behind it; so B retires before
      // A only then
      assert (f_AB || f_rotA);
      if (do_retire && f_sB == head) assert (f_rotA);
      if (f_rotA) assert (f_spA == SP_DEV && f_kA == XF_GET);
    end
  end

  // ================================================================ not vacuous
  always_comb begin
    cover (f_rstd && count == 3'(QD) && es == E_ROT);
    cover (f_rstd && f_tA && f_atA && do_retire && f_kA == XF_PUT && f_spA == SP_T3 && f_lenA == LSW'(24));
    cover (f_rstd && f_tA && f_atA && do_retire && f_kA == XF_GET && f_spA == SP_DEV && f_lenA == LSW'(3) && f_lsA[2:0] == 3'd6);
    cover (f_rstd && f_tA && f_atA && do_retire && f_kA == XF_GETX && f_lenA == LSW'(16));
    cover (f_rstd && f_tB && do_retire && f_sB == head);                 // B overtakes a rotated A
    cover (f_rstd && hz_rd_stall && !hz_fetch_stall);
    cover (f_rstd && hz_wr_stall && !hz_rd_stall);
    cover (f_rstd && hz_fetch_stall);
    cover (f_rstd && iss_valid && iss_hz);
    cover (f_rstd && quiet && !idle);
    cover (f_rstd && flush && !idle);
    cover (f_rstd && es == E_XFER && h_put && pop && pf_cnt == 2'd2 && f_A[15:3] == f_wa && off == LSW'(16));
    cover (f_rstd && es == E_XFER && h_put && h_dev && pop && f_A[2:0] == 3'd5);
    cover (f_rstd && es == E_XFER && b_retry && off != 0);               // a read that waits half way
  end
