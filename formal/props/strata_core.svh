// Properties of strata_core (included in the module when FORMAL is defined).
//
// The Local Stores, the multiplier, the divider and the Transfer Unit are
// cut out (formal/core.sby): what they answer is unconstrained, so
// everything here holds whatever the memories hold, whatever the arithmetic
// units compute and whenever the Transfer Unit accepts, stalls or reports.
//
// What is proved:
//   x0         x0 reads zero in every state but the reset sequencer's first
//   shape      every capability register holds either nothing or a
//              well-formed capability (f_wf): a space that exists, its
//              range inside the space, an 8-byte aligned base (endpoints
//              excepted, whose base is a node number), 8-byte aligned
//              bounds in memory, never writable and copyable in memory, a
//              revoker exactly as cdom makes one, revocable only in memory.
//              Everything written to the save table is well-formed too.
//   contracts  what the other proofs assume of a core: a command issued to
//              the Transfer Unit is tget, tput or tgetx, its Local Store
//              range inside the configured store, its far range inside the
//              capability, aligned unless it is a device transfer, never a
//              device tgetx; the unit is flushed only when it says quiet
//              (strata_tu.svh). The inbox is popped only on a hit, and a
//              revocation request names a non-empty range inside its table
//              (strata_top.svh).
//   table copy this core's copy of the granule table holds, for every
//              granule written since reset, the last value the top level
//              wrote (with strata_top.svh: it equals the master table)
//   liveness   the core's three "live" answers equal the specification's
//              (valid, and if revocable: the granule of its base exists and
//              has the capability's generation), so a revoked capability is
//              never live; nothing goes out through a capability that is
//              not live: no transfer, no far atomic, no gift, no revocation
//              request; and an instruction that needs a live operand traps
//              with capinv (below)
//   traps      for the conditions listed in f_trap (stop, fetch fault,
//              illegal, privilege, Local Store fault, the transfer and
//              far-atomic fault chains, svc, user halt, overlay and
//              capability operand checks) the trap is taken the next cycle
//              exactly as the emulator's trap(): the right bank's epc = pc,
//              cause and tval; the mode, the previous mode, the next pc or
//              the double-fault halt
//   precision  a cycle that retires no instruction changes no architectural
//              state: no integer register, no capability register, no
//              save-table slot, no overlay entry, no control register other
//              than a trap's own, and takes nothing from the rest of the
//              machine (no transfer issued, no gift given or taken); the
//              only exceptions are the documented two-cycle ends (linst's
//              first write, a far atomic's grant). In particular a trapping
//              instruction leaves no trace but the trap.
//   privilege  in user mode: every supervisor-only instruction traps with
//              cause priv; the supervisor's state (stvec, sscratch, status,
//              corebase, corecount, the save table, the supervisor's trap
//              bank) changes only by a trap to the supervisor; no
//              revocation request leaves the core; the inbox is taken from
//              only through an endpoint (crecv); the mode becomes
//              supervisor only by such a trap
//   linearity  for any byte P of far memory: the number of registers
//              holding a capability with write access to P never grows, except
//              by the instructions that bring one in from outside the
//              registers (ctake, crecv, crestore, crestorex) or rebuild
//              authority from a revoker (crevoke, cundom). So cmov, crestr,
//              csplit, cjoin, cshare, catom, cdom, cgive, csend, csave never
//              leave a second copy. A gift accepted (give_ack) retires the
//              instruction and empties a non-copyable source; a gift taken
//              (take_pop) retires and lands in cd; a live non-copyable
//              capability is overwritten only as the instruction's source,
//              as cjoin's destination or by cclear.
//
// Assumed (the environment):
//   - reset in the first cycle
//   - a capability taken from the inbox (take_cap when take_hit) is
//     well-formed (the inboxes hold what cores and the block device gave;
//     formal/top.sby shows the inbox returns what was put in)
//   - the save table returns a well-formed capability (every write to it is
//     asserted to be one, and the reset sequencer empties all slots; the
//     table itself is not modelled word by word)
//   - the Transfer Unit does not accept a command it reports a hazard for
//     (asserted in strata_tu.svh)
//   - a granule table write is inside its table (asserted in
//     strata_top.svh)
//   Nothing is assumed about the bus data, gifts' timing, the revocation
//   walker (dom_done, dom_gen, gt_we ...), stop and reset requests, or the
//   memories' contents.
//
// Not covered: what instructions compute when they do retire (that is the
// emulator comparison's and the conformance suite's ground), the tag
// lookup sequencer, pending-range traps (C_PEND), capop conditions.

  // The proof is split by group so that each induction is small (formal/core.sby):
  // 0 everything, 1 traps, 2 precision, 3 privilege, 4 linearity; any other
  // value: only the invariants every group needs (x0, shape, liveness).
  parameter int F_GRP = 0;
  localparam bit F_G1 = F_GRP == 0 || F_GRP == 1;
  localparam bit F_G2 = F_GRP == 0 || F_GRP == 2;
  localparam bit F_G3 = F_GRP == 0 || F_GRP == 3;
  localparam bit F_G4 = F_GRP == 0 || F_GRP == 4;

  // The cover task starts in any state instead of at reset (F_FREE): from
  // reset every trace first spends 256 cycles in the reset sequencer, which
  // makes the solver very slow (one cover in half an hour). Its traces show
  // that the properties' conditions can occur together with every
  // assumption, not that the states are reachable.
  parameter bit F_FREE = 0;

  logic f_past = 0;
  logic f_rstd = 0;
  always_comb if (!f_past && !F_FREE) assume (rst);
  always_ff @(posedge clk) begin
    f_past <= 1;
    if (rst) f_rstd <= 1;
  end

  // ================================================================ x0
  always_comb
    if (f_rstd) assert ((state == S_RST && rs_i == 0) || x[0] == 64'd0);

  // ================================================================ well-formed capabilities
  function automatic logic f_wf(input cap_t k);
    logic [FW:0] e;
    logic        mem, ok;
    e   = {1'b0, k.base} + {1'b0, k.len};
    mem = k.space == SP_T2 || k.space == SP_T3;
    ok  = 1;
    case (k.space)
      SP_T3:   ok = 64'(e) <= 64'(T3_BYTES);
      SP_T2:   ok = 64'(e) <= 64'(T2_BYTES);
      SP_DEV:  ok = 64'(e) <= DEV_LEN;
      SP_CORE: ok = 64'(e) <= 64'(NCORES * 8);
      SP_EP:   ok = 64'(e) <= 64'(NCORES + 1);
      default: ok = 0;
    endcase
    if (k.space != SP_EP && k.base[2:0] != 0) ok = 0;
    if (mem && k.len[2:0] != 0) ok = 0;
    if (mem && k.perms[P_W] && k.perms[P_D]) ok = 0;
    if (k.rv && !mem) ok = 0;
    // a revoker: only V, not revocable, over whole granules of memory, and
    // carrying the permissions of the linear writable capability it was
    if (k.perms[P_V] && !(k.perms == 6'b100000 && !k.rv && mem && k.gen[15:5] == 0 && k.gen[P_W] && !k.gen[P_D] &&
                          k.base[GRAN_SHIFT-1:0] == 0 && k.len[GRAN_SHIFT-1:0] == 0)) ok = 0;
    return !k.valid || ok;
  endfunction
  logic [NCAPS-1:0] f_wf_r;
  always_comb
    for (int i = 0; i < NCAPS; i++) f_wf_r[i] = f_wf(caps[i]);
  always_comb begin
    if (take_hit) assume (f_wf(take_cap));
    assume (!(tu_iss_ready && tu_iss_hz));
    if (state == S_CT) assume (f_wf(ct_entry));
    if (f_rstd) begin
      assert (&f_wf_r);
      if (ct_we) assert (f_wf(ct_wd));
    end
  end

  // ================================================================ liveness
  // The specification's live(k), with the granule entry looked up here.
  function automatic logic f_lv(input cap_t k, input logic [16:0] g);
    return k.valid && (!k.rv || (((k.space == SP_T3 && 64'(k.base) < 64'(T3_BYTES)) ||
                                  (k.space == SP_T2 && 64'(k.base) < 64'(T2_BYTES))) && g[15:0] == k.gen));
  endfunction
  // the instruction's operands, straight from the instruction word: the
  // capability in the rs1 field, in the rd field, and the transfer /
  // atomic / overlay one
  cap_t        f_ks, f_kd, f_kx;
  logic [3:0]  f_is, f_id, f_ix;
  logic        f_ls, f_ld, f_lx;
  assign f_is = ir[19:16];
  assign f_id = ir[24:21];
  assign f_ix = d.kind == K_XFER ? ir[13:10] : d.kind == K_TAMO ? ir[10:7] : ir[3:0];
  assign f_ks = caps[f_is];
  assign f_kd = caps[f_id];
  assign f_kx = caps[f_ix];
  assign f_ls = f_lv(f_ks, f_ks.space == SP_T2 ? gt2[0] : gt3[f_ks.base[GRAN_SHIFT+G3W-1:GRAN_SHIFT]]);
  assign f_ld = f_lv(f_kd, f_kd.space == SP_T2 ? gt2[0] : gt3[f_kd.base[GRAN_SHIFT+G3W-1:GRAN_SHIFT]]);
  assign f_lx = f_lv(f_kx, f_kx.space == SP_T2 ? gt2[0] : gt3[f_kx.base[GRAN_SHIFT+G3W-1:GRAN_SHIFT]]);
  logic f_capop;                  // a capability instruction (operands in rs1 / rd)
  assign f_capop = d.kind == K_CAP || d.kind == K_CAP2;
  always_comb begin
    if (f_rstd && state == S_EX) begin
      // (for the instructions that have a capability operand)
      if (f_capop || d.kind == K_XFER || d.kind == K_TAMO || d.kind == K_XMAP || d.kind == K_XCALL)
        assert (live_a == (f_capop ? f_ls : f_lx));
      if (f_capop) assert (live_cd == f_ld);
      // nothing goes out through a capability that is not live
      if (tu_iss_valid) assert (f_lx);
      if (am_req)       assert (f_lx);
      if (give_valid)   assert (f_ls);
      if (dom_req)      assert (f_ls);
      // a revocation request names a non-empty range inside its table
      // (what strata_top's walker is proved under: strata_top.svh)
      if (dom_req) assert (dom_n != 0 && (GW+1)'(dom_a) + (GW+1)'(dom_n) <= (dom_t2 ? (GW+1)'(NG2) : (GW+1)'(NG3)));
    end
    if (f_rstd && state == S_CT) begin
      assert ((ct_save ? live_a : live_cd) == (ct_save ? f_ls : f_ld));
      assert (live_ct == f_lv(ct_entry, ct_entry.space == SP_T2 ? gt2[0] : gt3[ct_entry.base[GRAN_SHIFT+G3W-1:GRAN_SHIFT]]));
    end
    // (what strata_top's inboxes are proved under: strata_top.svh)
    if (f_rstd) assert (take_pop == (take_req && take_hit));
    // what strata_tu is proved under (strata_tu.svh, f_core_ok), and more:
    // the register values fit the unit's narrower ports, the Local Store
    // range is inside the store as configured, the far range inside the
    // capability
    if (f_rstd && tu_iss_valid) begin
      assert (ir[25:23] <= 3'd2);
      assert (ra + rc <= (ir[25:23] == 3'd2 ? 64'(ILS_SIZE) : 64'(DLS_SIZE)) && ra <= 64'(LS_MAX_BYTES) && rc <= 64'(LS_MAX_BYTES));
      assert (f_kx.space == SP_DEV || ((ra | rb | rc) & 64'd7) == 0);
      assert (!(ir[25:23] == 3'd2 && f_kx.space == SP_DEV));
      assert (f_kx.space == SP_DEV ? rb < 64'(f_kx.len) : (rb <= 64'(f_kx.len) && rc <= 64'(f_kx.len) - rb));
    end
    if (f_rstd && reset_flush) assert (tu_quiet);
    if (f_rstd && state != S_EX) assert (!tu_iss_valid && !am_req && !give_valid && !dom_req && !take_req);
  end

  // ================================================================ the granule table copy
  // For one granule of each table, chosen by the solver: once the top
  // level has written it, this core's copy holds the last value written.
  // strata_top.svh shows the same of the master table, with the same
  // definition, so the copy equals the master for every granule written
  // since reset (their contents before that are not defined: FINDINGS O2).
  (* anyconst *) logic [G3W-1:0] f_gi;
  logic        f_g3v = 0, f_g2v = 0;
  logic [16:0] f_g3s, f_g2s;
  always_ff @(posedge clk) begin
    if (f_rstd && gt_we && !gt_t2 && G3W'(gt_idx) == f_gi) begin f_g3v <= 1; f_g3s <= gt_wd; end
    if (f_rstd && gt_we && gt_t2) begin f_g2v <= 1; f_g2s <= gt_wd; end     // (T2 is one granule)
  end
  always_comb begin
    // a table write is inside its table (asserted in strata_top.svh)
    if (gt_we) assume ((GW+1)'(gt_idx) < (gt_t2 ? (GW+1)'(NG2) : (GW+1)'(NG3)));
    assert (f_rstd || (!f_g3v && !f_g2v));
    if (f_rstd && f_g3v) assert (gt3[f_gi] == f_g3s);
    if (f_rstd && f_g2v) assert (gt2[0] == f_g2s);
  end

  // ================================================================ the traps specified
  logic        f_priv;            // a supervisor-only instruction (emu.c: every C_PRIV)
  always_comb begin
    f_priv = 0;
    case (d.kind)
      K_TANY: f_priv = ra[16];
      K_CAP:  f_priv = d.cap_fn == CF_TAKE || d.cap_fn == CF_POLL || d.cap_fn == CF_SAVE || d.cap_fn == CF_RESTORE;
      K_CAP2: f_priv = d.cap_fn != C2_SEND && d.cap_fn != C2_RECV;
      K_CSRR: f_priv = ir[15:0] == 16'd23 || ir[15:0] == 16'd24;                        // sscratch, ipend
      K_CSRW: f_priv = ir[15:0] == 16'd18 || ir[15:0] == 16'd15 || ir[15:0] == 16'd16 || // status, corebase, corecount
                       (ir[15:0] >= 16'd19 && ir[15:0] <= 16'd24);                      // ucause .. ipend
      default: f_priv = 0;
    endcase
  end
  // loads and stores: the address and size, from the instruction word
  logic [63:0] f_maddr, f_msz;
  assign f_maddr = ra + {{48{ir[15]}}, ir[15:0]};
  assign f_msz   = d.kind == K_STORE ? 64'd8 >> ir[27:26]
                   : ir[31:26] == 6'h10 ? 64'd8 : ir[31:26] <= 6'h12 ? 64'd4 : ir[31:26] <= 6'h14 ? 64'd2 : 64'd1;
  // the transfer fault chain (emu.c OP_XFER): ra = ls, rb = off, rc = len
  logic [7:0]  f_xf, f_am;
  always_comb begin
    logic [5:0]  need;
    logic [63:0] limit, klen;
    need  = ir[25:23] == 3'd0 ? 6'b000001 : ir[25:23] == 3'd1 ? 6'b000010 : 6'b000100;
    limit = ir[25:23] == 3'd2 ? 64'(ILS_SIZE) : 64'(DLS_SIZE);
    klen  = 64'(f_kx.len);
    f_xf  = '0;
    if (!f_lx)                                                    f_xf = C_CAPINV;
    else if ((f_kx.perms & need) == 0)                            f_xf = C_PERM;
    else if (f_kx.space == SP_EP)                                 f_xf = C_PERM;
    else if ((f_kx.space == SP_DEV || f_kx.space == SP_CORE) && ir[25:23] == 3'd2) f_xf = C_PERM;
    else if (f_kx.space == SP_CORE && ir[25:23] != 3'd1)          f_xf = C_PERM;
    else if (f_kx.space != SP_DEV && ((ra | rb | rc) & 64'd7) != 0) f_xf = C_XALIGN;
    else if (f_kx.space == SP_DEV ? rb >= klen : (rb > klen || rc > klen - rb)) f_xf = C_BOUNDS;
    else if (ra > limit || rc > limit - ra)                       f_xf = C_LSFAULT;
    // the far-atomic chain (emu.c OP_TAMO): ra = offset
    f_am  = '0;
    if (!f_lx)                                 f_am = C_CAPINV;
    else if (!f_kx.perms[P_A])                 f_am = C_PERM;
    else if ((ra & 64'd7) != 0)                f_am = C_XALIGN;
    else if (klen < 64'd8 || ra > klen - 64'd8) f_am = C_BOUNDS;
  end

  logic        f_tv;              // this cycle must end in a trap ...
  logic [7:0]  f_tc;              // ... with this cause
  logic [63:0] f_tt;              // ... and this tval
  always_comb begin
    f_tv = 0;
    f_tc = '0;
    f_tt = '0;
    if (state == S_F0 && !rpend && !tu_cc_busy) begin
      if (user && ipend) begin f_tv = 1; f_tc = C_STOP; end
      else if (pc[1:0] != 0 || pc >= 64'(ILS_SIZE)) begin f_tv = 1; f_tc = C_IFAULT; f_tt = pc; end
    end else if (state == S_EX && !rpend) begin
      if (user && ipend) begin f_tv = 1; f_tc = C_STOP; end
      else if (d.kind == K_ILLEGAL) begin f_tv = 1; f_tc = C_ILLEGAL; f_tt = {32'b0, ir}; end
      else if (user && f_priv) begin f_tv = 1; f_tc = C_PRIV; f_tt = {32'b0, ir}; end
      else case (d.kind)
        K_LOAD, K_STORE:
          if (f_maddr > 64'(DLS_SIZE) - f_msz || (f_maddr & (f_msz - 1)) != 0) begin
            f_tv = 1; f_tc = C_LSFAULT; f_tt = f_maddr;
          end
        K_XFER: if (f_xf != 0) begin f_tv = 1; f_tc = f_xf; f_tt = f_xf == C_LSFAULT ? ra : rb; end
        K_TAMO: if (f_am != 0) begin f_tv = 1; f_tc = f_am; f_tt = ra; end
        K_SYS:
          if (ir[15:0] == 16'd2) begin
            f_tv = 1; f_tc = user ? C_SVC : C_ILLEGAL; f_tt = user ? 64'd0 : {32'b0, ir};
          end else if (ir[15:0] == 16'd0 && user && tu_idle) begin f_tv = 1; f_tc = C_HALT; end
        K_XMAP:
          if (32'(d.rd) >= NXMAP) begin f_tv = 1; f_tc = C_ILLEGAL; f_tt = {32'b0, ir}; end
          else if (!ir[4] && !f_lx) begin f_tv = 1; f_tc = C_CAPINV; f_tt = 64'(f_ix); end
          else if (!ir[4] && !f_kx.perms[P_X]) begin f_tv = 1; f_tc = C_PERM; f_tt = 64'(f_ix); end
          else if (!ir[4] && rb >= 64'(f_kx.len)) begin f_tv = 1; f_tc = C_BOUNDS; f_tt = rb; end
        K_XCALL:
          if (!ir[4] && !f_lx) begin f_tv = 1; f_tc = C_CAPINV; f_tt = 64'(f_ix); end
          else if (!ir[4] && !f_kx.perms[P_X]) begin f_tv = 1; f_tc = C_PERM; f_tt = 64'(f_ix); end
          else if (!ir[4] && ra >= 64'(f_kx.len)) begin f_tv = 1; f_tc = C_BOUNDS; f_tt = ra; end
        K_CAP:
          if ((d.cap_fn == CF_MOV || d.cap_fn == CF_RESTR || d.cap_fn == CF_SPLIT || d.cap_fn == CF_SHARE ||
               d.cap_fn == CF_ATOM || d.cap_fn == CF_BASE || d.cap_fn == CF_LEN || d.cap_fn == CF_PERMS ||
               d.cap_fn == CF_GIVE) && !f_ls) begin f_tv = 1; f_tc = C_CAPINV; f_tt = 64'(f_is); end
          else if (d.cap_fn == CF_JOIN && (!f_ls || !f_ld)) begin f_tv = 1; f_tc = C_CAPINV; f_tt = 64'(f_is); end
        K_CAP2:
          if (d.cap_fn == C2_SEND) begin
            if (!f_ld || f_kd.space != SP_EP || !f_kd.perms[P_W]) begin f_tv = 1; f_tc = C_CAPINV; f_tt = 64'(f_id); end
            else if (!f_ls) begin f_tv = 1; f_tc = C_CAPINV; f_tt = 64'(f_is); end
          end else if (d.cap_fn == C2_RECV) begin
            if (!f_ls || f_ks.space != SP_EP || !f_ks.perms[P_R]) begin f_tv = 1; f_tc = C_CAPINV; f_tt = 64'(f_is); end
          end else if (d.cap_fn == C2_DOM) begin
            if (!f_ls) begin f_tv = 1; f_tc = C_CAPINV; f_tt = 64'(f_is); end
          end else if (d.cap_fn == C2_REVOKE || d.cap_fn == C2_UNDOM) begin
            if (!(f_ls && f_ks.perms[P_V] && !f_ks.rv)) begin f_tv = 1; f_tc = C_CAPINV; f_tt = 64'(f_is); end
          end
        default: ;
      endcase
    end
  end

  // a trap, as emu.c trap() delivers it
  logic f_to_u;                   // to the program's own handler
  logic f_dbl;                    // halts the core: no supervisor handler, or it faulted at once
  assign f_to_u = user && !(f_tc == C_HALT || f_tc == C_STOP || f_tc == C_PRIV || f_tc == C_SVC ||
                            u_tvec == 0 || pc == u_tvec);
  assign f_dbl  = s_tvec == 0 || (!user && pc == s_tvec);
  logic f_step;                   // the last cycle was an ordinary one (no reset of any kind)
  logic f_okp = 0;
  always_ff @(posedge clk) f_okp <= (f_rstd || F_FREE) && !rst && !reset_flush;
  assign f_step = f_past && f_okp;
  always_ff @(posedge clk) begin
    if (F_G1 && f_step && $past(f_tv)) begin
      assert (csr_instret == $past(csr_instret));
      if ($past(f_to_u)) begin
        assert (u_epc == $past(pc) && u_cause == 64'($past(f_tc)) && u_tval == $past(f_tt));
        assert (pc == $past(u_tvec) && state == S_F0 && user);
        assert (s_epc == $past(s_epc) && s_cause == $past(s_cause) && s_tval == $past(s_tval));
        assert (spp_user == $past(spp_user));
      end else begin
        assert (s_epc == $past(pc) && s_cause == 64'($past(f_tc)) && s_tval == $past(f_tt));
        assert (!user && spp_user == $past(user));
        assert (u_epc == $past(u_epc) && u_cause == $past(u_cause) && u_tval == $past(u_tval));
        if ($past(f_dbl)) begin
          assert (state == S_HALT && pc == $past(pc));
        end else begin
          assert (state == S_F0 && pc == $past(s_tvec));
        end
      end
      // a stop is consumed by its trap (also one that arrives in the very
      // cycle the trap is taken: it merges with the one being taken, as if
      // it had arrived just before; formal/FINDINGS.md O6)
      if ($past(f_tc) == C_STOP) assert (!ipend);
    end
  end

  // ================================================================ precision
  // One register, one save-table slot and one overlay entry chosen by the
  // solver stand for all.
  (* anyconst *) logic [4:0]      f_xi;
  (* anyconst *) logic [3:0]      f_ci;
  (* anyconst *) logic [XW-1:0]   f_mi;
  logic f_ret;                    // the last cycle retired an instruction (or halted)
  logic [63:0] f_iret;
  always_ff @(posedge clk) f_iret <= csr_instret;
  assign f_ret = csr_instret != f_iret;
  always_ff @(posedge clk) begin
    if (F_G2 && f_step && !f_ret && $past(state) != S_RST) begin
      assert (x[f_xi] == $past(x[f_xi]));
      assert (caps[f_ci] == $past(caps[f_ci]));
      assert (!$past(ct_we));
      assert (xm_v[f_mi] == $past(xm_v[f_mi]) && xm_far[f_mi] == $past(xm_far[f_mi]) &&
              xm_ils[f_mi] == $past(xm_ils[f_mi]) && xm_sp[f_mi] == $past(xm_sp[f_mi]));
      assert (s_tvec == $past(s_tvec) && u_tvec == $past(u_tvec) && sscratch == $past(sscratch));
      assert (xslot == $past(xslot) && csr_ccr == $past(csr_ccr) && csr_ttag == $past(csr_ttag));
      assert (csr_tdata == $past(csr_tdata) && csr_tgeom == $past(csr_tgeom) && csr_scratch == $past(csr_scratch));
      assert (csr_corebase == $past(csr_corebase) && csr_corecount == $past(csr_corecount));
      assert (csr_takefrom == $past(csr_takefrom));
      // nothing was taken from, or handed to, the rest of the machine
      assert (!$past(tu_iss_valid && tu_iss_ready));
      assert (!$past(give_valid && give_ack));
      assert (!$past(take_pop));
      // the Local Store is written only by a store that retires, or by
      // linst's first write (it retires two cycles later, come what may)
      if ($past(da_we) != 0) assert ($past(state) == S_LW && state == S_LW);
      // pc moves only by a trap; the mode only to supervisor
      if (pc != $past(pc)) assert (pc == $past(s_tvec) || pc == $past(u_tvec));
      if (pc != $past(pc)) assert ((s_epc == $past(pc) && !user) || (u_epc == $past(pc) && user && $past(user)));
      assert (!user || $past(user));
      // the trap banks change only by a trap at this pc
      if (s_epc != $past(s_epc)) assert (s_epc == $past(pc) && !user);
      if (u_epc != $past(u_epc)) assert (u_epc == $past(pc) && $past(user));
    end
    // a far atomic granted is completed (it cannot be taken back)
    if (F_G2 && f_step && $past(am_req && am_gnt)) assert (state == S_AM);
    // a gift accepted retires the instruction and empties a linear source;
    // a gift taken retires and is in cd
    if (F_G2 && f_step && $past(give_valid && give_ack)) begin
      assert (f_ret && state == S_F0);
      if (!$past(f_ks.perms[P_D])) assert (caps[$past(f_is)] == CAP_NULL);
    end
    if (F_G2 && f_step && $past(take_pop)) begin
      assert (f_ret && state == S_F0);
      assert (caps[$past(f_id)] == $past(take_cap));
    end
    // a transfer issued is retired
    if (F_G2 && f_step && $past(tu_iss_valid && tu_iss_ready)) assert (f_ret && state == S_F0);
  end

  // ================================================================ privilege
  always_ff @(posedge clk) begin
    if (F_G3 && f_step && $past(user)) begin
      // supervisor state changes only by a trap to the supervisor
      assert (s_tvec == $past(s_tvec) && sscratch == $past(sscratch));
      assert (csr_corebase == $past(csr_corebase) && csr_corecount == $past(csr_corecount));
      assert (!$past(ct_we) && !$past(dom_req));
      if (!user) begin
        assert (s_epc == $past(pc) && spp_user && !f_ret);
        assert (s_cause >= 64'd1 && s_cause <= 64'd14);
        assert (state == S_HALT ? $past(s_tvec) == 0 : (pc == $past(s_tvec) && state == S_F0));
      end else begin
        assert (s_epc == $past(s_epc) && s_cause == $past(s_cause) && s_tval == $past(s_tval));
        assert (spp_user == $past(spp_user));
        assert (state != S_HALT && state != S_CT);
      end
      // a stop request is not lost, and not cleared by the program
      if ($past(ipend) && user) assert (ipend);
      // the inbox: only through an endpoint
      if ($past(take_pop)) assert ($past(d.kind) == K_CAP2 && $past(d.cap_fn) == C2_RECV);
    end
  end
  always_comb if (f_rstd && user) assert (state != S_CT && state != S_HALT && state != S_RST);
  // S_CT is the second cycle of a save-table instruction, in the supervisor, its slot in range
  always_comb
    if (f_rstd && state == S_CT)
      assert (!user && !ct_oor &&
              ((d.kind == K_CAP && (d.cap_fn == CF_SAVE || d.cap_fn == CF_RESTORE)) ||
               (d.kind == K_CAP2 && (d.cap_fn == C2_SAVEX || d.cap_fn == C2_RESTOREX))));

  // ================================================================ linearity
  (* anyconst *) logic [2:0]    f_psp;   // the far byte P: its space
  (* anyconst *) logic [FW-1:0] f_pad;   // and its address
  // write access to the memory byte at address a of space sp. (Exclusive
  // access is W's property, not "not copyable"'s: crestr may take D away
  // from a copy, which makes a second non-copyable capability, but it
  // cannot add W, and W never comes with D in memory: f_wf.)
  function automatic logic f_holds(input cap_t k, input logic [2:0] sp, input logic [FW-1:0] a);
    return k.valid && k.perms[P_W] && (k.space == SP_T2 || k.space == SP_T3) && k.space == sp &&
           k.base <= a && {1'b0, a} < {1'b0, k.base} + {1'b0, k.len};
  endfunction
  // An instruction writes at most its two capability operands (shown: any
  // other register is unchanged), so the count over all registers grows
  // exactly when the count over those two does.
  logic [1:0] f_np;               // of the instruction's operands: how many hold write access to P
  assign f_np = f_is == f_id ? {1'b0, f_holds(f_ks, f_psp, f_pad)}
                             : 2'(f_holds(f_ks, f_psp, f_pad)) + 2'(f_holds(f_kd, f_psp, f_pad));
  logic [3:0] f_qs, f_qd;         // last cycle's operands
  logic [1:0] f_qnp;              // and their count then
  logic       f_qcap, f_qbr;
  always_ff @(posedge clk) begin
    f_qs   <= f_is;
    f_qd   <= f_id;
    f_qnp  <= f_np;
    f_qcap <= f_capop && (state == S_EX || state == S_CT);
    f_qbr  <= f_brings;
  end
  logic [1:0] f_np_now;           // the same two registers now
  assign f_np_now = f_qs == f_qd ? {1'b0, f_holds(caps[f_qs], f_psp, f_pad)}
                                 : 2'(f_holds(caps[f_qs], f_psp, f_pad)) + 2'(f_holds(caps[f_qd], f_psp, f_pad));
  logic f_brings;                 // the instruction brings a capability into the registers
  assign f_brings = (d.kind == K_CAP && (d.cap_fn == CF_TAKE || d.cap_fn == CF_RESTORE)) ||
                    (d.kind == K_CAP2 && (d.cap_fn == C2_RECV || d.cap_fn == C2_RESTOREX ||
                                          d.cap_fn == C2_REVOKE || d.cap_fn == C2_UNDOM));
  logic f_lin_live;               // register f_ci holds a live non-copyable capability
  assign f_lin_live = !caps[f_ci].perms[P_D] &&
                      f_lv(caps[f_ci], caps[f_ci].space == SP_T2 ? gt2[0] : gt3[caps[f_ci].base[GRAN_SHIFT+G3W-1:GRAN_SHIFT]]);
  always_ff @(posedge clk) begin
    if (F_G4 && f_step && $past(state) != S_RST) begin
      if (!(f_qcap && (f_ci == f_qs || f_ci == f_qd))) assert (caps[f_ci] == $past(caps[f_ci]));
      if (!f_qbr) assert (f_np_now <= f_qnp);
      if ($past(f_lin_live) && caps[f_ci] != $past(caps[f_ci]))
        assert ($past(f_capop) && (f_ci == $past(f_is) ||
                (f_ci == $past(f_id) && $past(d.kind) == K_CAP && ($past(d.cap_fn) == CF_JOIN || $past(d.cap_fn) == CF_CLEAR))));
    end
    // csave: the slot gets the capability and a non-copyable source is
    // emptied; crestore: a non-copyable entry leaves its slot
    if (F_G4 && f_step && $past(state) == S_CT && f_ret) begin
      if ($past(ct_save)) begin
        assert ($past(ct_we) && $past(ct_wd) == $past(f_ks));
        if (!$past(f_ks.perms[P_D])) assert (caps[$past(f_is)] == CAP_NULL);
      end else begin
        assert (caps[$past(f_id)] == $past(ct_entry));
        assert ($past(ct_we) == !$past(ct_entry.perms[P_D]));
        if ($past(ct_we)) assert ($past(ct_wd) == CAP_NULL);
      end
    end
  end

  // ================================================================ not vacuous
  always_ff @(posedge clk) begin
    // (from any state: F_FREE)
    cover (!F_FREE || (f_step && $past(f_tv) && $past(f_tc) == C_ILLEGAL && state == S_F0));
    cover (!F_FREE || (f_step && $past(f_tv) && $past(f_tc) == C_IFAULT && state == S_HALT));
    cover (!F_FREE || (f_step && $past(f_tv) && $past(f_tc) == C_PRIV && $past(f_dbl)));
    cover (!F_FREE || (f_step && $past(f_tv) && $past(f_tc) == C_STOP && $past(state) == S_EX));
    cover (!F_FREE || (f_step && $past(f_tv) && $past(f_to_u) && $past(f_tc) == C_CAPINV));
    cover (!F_FREE || (f_step && $past(f_tv) && $past(f_tc) == C_PERM && $past(d.kind) == K_XFER));
    cover (!F_FREE || (f_step && $past(state) == S_EX && $past(d.kind) == K_CAP && $past(d.cap_fn) == CF_SPLIT && f_ret && f_qnp == 2'd1));
    cover (!F_FREE || (f_step && $past(state) == S_EX && $past(d.kind) == K_CAP2 && $past(d.cap_fn) == C2_DOM && f_ret));
    cover (!F_FREE || (f_step && $past(state) == S_EX && $past(d.kind) == K_XFER && f_ret));
    cover (!F_FREE || (f_step && $past(give_valid && give_ack) && !$past(f_ks.perms[P_D])));
    cover (!F_FREE || (f_step && $past(take_pop) && $past(user)));
    cover (!F_FREE || (f_step && $past(state) == S_CT && f_ret && !$past(ct_save)));
    cover (!F_FREE || (f_step && $past(user) && !user && state == S_F0));
  end
