// Strata: one core (synthesizable).
//
// A multi-cycle implementation over block-RAM Local Stores:
//   F0  present the instruction address to the I-LS (stall on an in-flight tgetx)
//   F1  latch the instruction word
//   EX  execute; stay here while stalled
//   LD  load data returns from the D-LS
//   LT  tag-lookup sequencer (one table word per two cycles)
//   LW  second write of `linst`
//   DV  iterative division
//   AM  far atomic in flight
//
// The core owns both Local Stores: port A is its own, port B belongs to the
// Transfer Unit. Loads and stores reach only the D-LS; every far tier is
// reached through the Transfer Unit or the far-atomic port, always through a
// capability register. The emulator (emu/emu.c) is the reference semantics.

module strata_core
  import strata_pkg::*;
#(
  parameter int    COREID   = 0,
  parameter int    NCORES   = 4,
  parameter string ILS_INIT = "",
  parameter string DLS_INIT = ""
)(
  input  logic        clk,
  input  logic        rst,

  // Transfer Unit far-bus master
  output logic        tu_req,
  output logic        tu_we,
  output logic [2:0]  tu_space,
  output logic [63:0] tu_addr,
  output logic [23:0] tu_beats,
  output logic        tu_byte,
  output logic        tu_wvalid,
  output logic [63:0] tu_wdata,
  input  logic        tu_gnt,
  input  logic        tu_wready,
  input  logic        tu_rvalid,
  input  logic        tu_done,
  input  logic        tu_retry,

  // far-atomic far-bus master
  output logic        am_req,
  output logic [2:0]  am_op,
  output logic [2:0]  am_space,
  output logic [63:0] am_addr,
  output logic [63:0] am_wdata,
  output logic [63:0] am_cmp,
  input  logic        am_gnt,
  input  logic        am_done,

  input  logic [63:0] bus_rdata,

  // capability hand-over
  output logic        give_valid,
  output logic [7:0]  give_dst,
  output cap_t        give_cap,
  input  logic        give_ack,
  output logic        take_req,
  output logic        take_any,
  output logic [7:0]  take_src,
  input  logic        take_hit,
  input  cap_t        take_cap,
  input  logic [7:0]  take_from,
  output logic        take_pop,
  input  logic [15:0] poll_mask,
  input  logic [NCORES-1:0] halted_vec,

  // revocation granules: the top level walks the machine's table for cdom /
  // crevoke / cundom and broadcasts every write into each core's copy
  output logic          dom_req,       // held until dom_done
  output logic [1:0]    dom_op,        // 0 cdom, 1 crevoke, 2 cundom
  output logic          dom_t2,        // the range is in T2 (else T3)
  output logic [GW-1:0] dom_a,         // its first granule
  output logic [GW-1:0] dom_n,         // its granules
  input  logic          dom_done,      // the walk is over (one cycle)
  input  logic [15:0]   dom_gen,       // the generation it gave the range
  input  logic          gt_we,         // a table write: T2 or T3, granule, {head, generation}
  input  logic          gt_t2,
  input  logic [GW-1:0] gt_idx,
  input  logic [16:0]   gt_wd,

  input  logic        stop_req,        // a "stop" written through core control

  output logic        halted
);
  // ================================================================ state
  typedef enum logic [3:0] {S_F0, S_F1, S_EX, S_LD, S_LT, S_LW, S_DV, S_AM, S_HALT} state_t;

  state_t      state;
  logic [63:0] pc;
  logic [31:0] ir;
  logic [63:0] x [32];

  cap_t        caps [NCAPS];
  // the capability save table: contents in LUT-RAM (no reset), validity in flip-flops
  cap_t        ctab [CTAB];
  logic [CTAB-1:0] ctab_v;
  cap_t        ct_rd, ct_entry;
  logic        ct_we;
  cap_t        ct_wd;
  assign ct_rd    = ctab[d.slot];
  assign ct_entry = ctab_v[d.slot] ? ct_rd : CAP_NULL;
  always_ff @(posedge clk) if (ct_we) ctab[d.slot] <= ct_wd;

  logic        xm_v   [NXMAP];
  logic [2:0]  xm_sp  [NXMAP];
  logic [63:0] xm_far [NXMAP];
  logic [63:0] xm_ils [NXMAP];

  logic [63:0] csr_cycle, csr_instret;
  // trap state, banked by mode: the supervisor's and the user program's
  logic [63:0] s_cause, s_epc, s_tval, s_tvec, u_cause, u_epc, u_tval, u_tvec, sscratch;
  logic        user, spp_user, ipend;
  logic [5:0]  xslot;
  logic [63:0] csr_ccr, csr_ttag, csr_tdata, csr_tgeom, csr_scratch, csr_stalls;
  logic [63:0] csr_takefrom, csr_corebase, csr_corecount;
  logic [63:0] csr_cause, csr_epc, csr_tval, csr_tvec;   // the current mode's bank
  assign csr_cause = user ? u_cause : s_cause;
  assign csr_epc   = user ? u_epc   : s_epc;
  assign csr_tval  = user ? u_tval  : s_tval;
  assign csr_tvec  = user ? u_tvec  : s_tvec;

  // ---------------------------------------------------------------- revocation granules
  // This core's copy of the granule table ({head, generation} per granule;
  // LUT-RAM with three asynchronous read ports, written only by the top
  // level's broadcast). A capability can be used while valid and, if it is
  // revocable, while the granule holding its base has the generation it was
  // made under. Three capabilities are checked at once: port A the operand
  // (cs for capability instructions, the transfer / atomic / overlay one
  // otherwise), D the destination register cd, C the save-table slot.
  logic [16:0] gt3 [NG3];
  logic [16:0] gt2 [NG2];
`ifdef SIMULATION
  initial begin                               // all generations 0 at power-on, like the emulator
    for (int i = 0; i < NG3; i++) gt3[i] = '0;
    for (int i = 0; i < NG2; i++) gt2[i] = '0;
  end
`endif
  always_ff @(posedge clk)
    if (gt_we) begin
      if (gt_t2) gt2[G2W'(gt_idx)] <= gt_wd;
      else       gt3[G3W'(gt_idx)] <= gt_wd;
    end
  // the granule of a capability's base exists (a base past the end of its space has none)
  function automatic logic g_in(input cap_t k);
    return (k.space == SP_T3 && k.base < 64'(T3_BYTES)) || (k.space == SP_T2 && k.base < 64'(T2_BYTES));
  endfunction
  function automatic logic g_live(input cap_t k, input logic [16:0] g);
    return k.valid && (!k.rv || (g_in(k) && g[15:0] == k.gen));
  endfunction
  logic        live_a, live_cd, live_ct;   // ports A, D, C: the capability is live
  logic [16:0] g_a;                        // port A's entry (its head bit: cjoin)

  // tag-lookup sequencer
  logic [3:0]  lt_k;
  logic        lt_ph;
  logic [63:0] lt_key, lt_set, lt_ebase, lt_off, lt_victim;

`ifdef SIMULATION
  logic trace_on;
  initial trace_on = sim_trace_on() != 0;
`endif

  // ================================================================ Local Stores
  logic        ia_en;
  logic [12:0] ia_addr;
  logic [63:0] ia_rdata;
  logic        tu_ils_en;
  logic [12:0] tu_ils_addr;
  logic [63:0] tu_ils_wdata, ils_b_rdata;

  logic        da_en;
  logic [7:0]  da_we;
  logic [12:0] da_addr;
  logic [63:0] da_wdata, da_rdata;
  logic        tu_dls_en;
  logic [7:0]  tu_dls_we;
  logic [12:0] tu_dls_addr;
  logic [63:0] tu_dls_wdata, tu_dls_rdata;

  strata_ram #(.WORDS(ILS_WORDS), .INIT(ILS_INIT)) u_ils (
    .clk,
    .a_en(ia_en), .a_we(8'h00), .a_addr(ia_addr), .a_wdata(64'b0), .a_rdata(ia_rdata),
    .b_en(tu_ils_en), .b_we(tu_ils_en ? 8'hff : 8'h00), .b_addr(tu_ils_addr), .b_wdata(tu_ils_wdata),
    .b_rdata(ils_b_rdata)
  );
  strata_ram #(.WORDS(DLS_WORDS), .INIT(DLS_INIT)) u_dls (
    .clk,
    .a_en(da_en), .a_we(da_we), .a_addr(da_addr), .a_wdata(da_wdata), .a_rdata(da_rdata),
    .b_en(tu_dls_en), .b_we(tu_dls_we), .b_addr(tu_dls_addr), .b_wdata(tu_dls_wdata),
    .b_rdata(tu_dls_rdata)
  );

`ifdef SIMULATION
  // load the program image into both Local Stores
  initial begin
    for (int i = 0; i < ILS_WORDS; i++) u_ils.mem[i] = img_word(1, i);
    for (int i = 0; i < DLS_WORDS; i++) u_dls.mem[i] = img_word(2, i);
  end
`endif

  // ================================================================ decode, registers
  dec_t d;
  strata_decode u_dec (.ir(ir), .d(d));

  logic [63:0] ra, rb, rc;          // the three register read ports
  assign ra = x[d.pa];
  assign rb = x[d.pb];
  assign rc = x[d.pc];

  // ================================================================ ALU, divider
  logic [63:0] alu_y;
  strata_alu u_alu (.op(d.alu_op), .a(ra), .b(d.kind == K_ALU ? rb : d.imm), .y(alu_y));

  logic        is_div, div_start, div_busy, div_done;
  logic [63:0] div_q, div_r;
  assign is_div = d.kind == K_ALU && d.alu_op inside {ALU_DIVU, ALU_REMU, ALU_DIV, ALU_REM};
  strata_div u_div (
    .clk, .rst, .start(div_start), .is_signed(d.alu_op == ALU_DIV || d.alu_op == ALU_REM),
    .a(ra), .b(rb), .busy(div_busy), .done(div_done), .quo(div_q), .rem(div_r)
  );

  // ================================================================ loads / stores
  logic [63:0] maddr, msz, mshift, mload;
  logic        mok;
  logic [7:0]  mmask;
  assign maddr  = ra + d.imm;
  assign msz    = 64'd1 << d.msize;
  assign mok    = maddr <= 64'(DLS_BYTES) - msz && (maddr & (msz - 1)) == 0;
  assign mshift = {58'b0, maddr[2:0], 3'b000};
  always_comb begin
    case (d.msize)
      2'd0: mmask = 8'b0000_0001 << maddr[2:0];
      2'd1: mmask = 8'b0000_0011 << maddr[2:0];
      2'd2: mmask = 8'b0000_1111 << maddr[2:0];
      default: mmask = 8'hff;
    endcase
  end
  always_comb begin
    logic [63:0] raw;
    raw = da_rdata >> mshift;
    case (d.msize)
      2'd0: mload = d.msigned ? {{56{raw[7]}},  raw[7:0]}  : {56'b0, raw[7:0]};
      2'd1: mload = d.msigned ? {{48{raw[15]}}, raw[15:0]} : {48'b0, raw[15:0]};
      2'd2: mload = d.msigned ? {{32{raw[31]}}, raw[31:0]} : {32'b0, raw[31:0]};
      default: mload = raw;
    endcase
  end

  // ================================================================ branches
  logic br_taken;
  always_comb begin
    case (d.br_op)
      3'd0: br_taken = ra == rb;
      3'd1: br_taken = ra != rb;
      3'd2: br_taken = $signed(ra) <  $signed(rb);
      3'd3: br_taken = $signed(ra) >= $signed(rb);
      3'd4: br_taken = ra <  rb;
      3'd5: br_taken = ra >= rb;
      default: br_taken = 0;
    endcase
  end

  // ================================================================ transfers
  cap_t        xcap;
  logic [7:0]  xf_fault;
  logic [63:0] xf_tval;
  assign xcap = caps[d.cs];
  // transfer operands: ra = LS address, rb = far offset, rc = length
  always_comb begin
    logic [5:0]  need;
    logic [63:0] limit;
    need  = d.xf_sub == XF_GET ? 6'(1 << P_R) : d.xf_sub == XF_PUT ? 6'(1 << P_W) : 6'(1 << P_X);
    limit = d.xf_sub == XF_GETX ? 64'(ILS_BYTES) : 64'(DLS_BYTES);
    xf_fault = '0;
    xf_tval  = rb;
    if (!live_a)                                         xf_fault = C_CAPINV;
    else if ((xcap.perms & need) == 0)                       xf_fault = C_PERM;
    else if (xcap.space == SP_EP)                            xf_fault = C_PERM;
    else if ((xcap.space == SP_DEV || xcap.space == SP_CORE) && d.xf_sub == XF_GETX) xf_fault = C_PERM;
    else if (xcap.space == SP_CORE && d.xf_sub != XF_PUT)    xf_fault = C_PERM;
    else if (xcap.space != SP_DEV && ((ra | rb | rc) & 7) != 0) xf_fault = C_XALIGN;
    else if (xcap.space == SP_DEV ? rb >= xcap.len
             : (rb > xcap.len || rc > xcap.len - rb))        xf_fault = C_BOUNDS;
    else if (ra > limit || rc > limit - ra) begin            xf_fault = C_LSFAULT; xf_tval = ra; end
  end

  // ================================================================ far atomics
  logic [7:0] amo_fault;
  always_comb begin
    amo_fault = '0;
    if (!live_a)                               amo_fault = C_CAPINV;
    else if (!xcap.perms[P_A])                     amo_fault = C_PERM;
    else if (ra[2:0] != 0)                         amo_fault = C_XALIGN;
    else if (xcap.len < 8 || ra > xcap.len - 8)    amo_fault = C_BOUNDS;
  end

  // ================================================================ Transfer Unit
  logic        tu_iss_valid, tu_iss_ready, tu_iss_hz, tu_idle, tu_mem_idle;
  logic [15:0] tag_busy;
  logic [63:0] hz_addr, hz_len;
  logic        hz_rd_stall, hz_wr_stall, hz_fetch_stall;

  assign tu_iss_valid = state == S_EX && d.kind == K_XFER && xf_fault == 0;

  // tag-lookup geometry (computed from the current instruction's register)
  logic [5:0]  lt_lsh, lt_lsets;
  logic [3:0]  lt_ways;
  logic [63:0] lt_line, lt_set_c, lt_ebase_c, lt_span;
  logic        lt_ok;
  assign lt_lsh     = csr_tgeom[5:0];
  assign lt_lsets   = csr_tgeom[11:6];
  assign lt_ways    = csr_tgeom[15:12];
  assign lt_line    = ra >> lt_lsh;
  assign lt_set_c   = lt_line & ((64'd1 << lt_lsets) - 1);
  assign lt_span    = (64'(lt_ways) + 1) * 8;
  assign lt_ebase_c = csr_ttag + lt_set_c * lt_span;
  assign lt_ok      = lt_ways != 0 && lt_ebase_c[2:0] == 0 && lt_ebase_c <= 64'(DLS_BYTES) - lt_span;

  always_comb begin
    hz_addr = '0;
    hz_len  = '0;
    if (state == S_EX && (d.kind == K_LOAD || d.kind == K_STORE)) begin
      hz_addr = maddr;
      hz_len  = msz;
    end else if (state == S_EX && (d.kind == K_LTAG || d.kind == K_LINST)) begin
      hz_addr = lt_ebase_c;
      hz_len  = lt_span;
    end
  end

  strata_tu u_tu (
    .clk, .rst,
    .iss_valid(tu_iss_valid), .iss_kind(d.xf_sub), .iss_tag(d.tag), .iss_ls(ra),
    .iss_space(xcap.space), .iss_far(xcap.base + rb), .iss_len(rc), .iss_ready(tu_iss_ready),
    .iss_hz(tu_iss_hz),
    .tag_busy, .idle(tu_idle), .mem_idle(tu_mem_idle),
    .hz_addr, .hz_len, .hz_rd_stall, .hz_wr_stall, .hz_pc(pc), .hz_fetch_stall,
    .dls_en(tu_dls_en), .dls_we(tu_dls_we), .dls_addr(tu_dls_addr), .dls_wdata(tu_dls_wdata),
    .dls_rdata(tu_dls_rdata),
    .ils_en(tu_ils_en), .ils_addr(tu_ils_addr), .ils_wdata(tu_ils_wdata),
    .b_req(tu_req), .b_we(tu_we), .b_space(tu_space), .b_addr(tu_addr), .b_beats(tu_beats),
    .b_byte(tu_byte), .b_wvalid(tu_wvalid), .b_wdata(tu_wdata), .b_gnt(tu_gnt),
    .b_wready(tu_wready), .b_rvalid(tu_rvalid), .b_rdata(bus_rdata), .b_done(tu_done),
    .b_retry(tu_retry)
  );

  // ================================================================ capability helpers
  cap_t       cs_cap, cd_cap;
  logic [3:0] cd_i, cs_i;
  logic       cs_linear, cd_ok;
  assign cd_i      = d.rd[3:0];
  assign cs_i      = d.rs1[3:0];
  assign cs_cap    = caps[cs_i];
  assign cd_cap    = caps[cd_i];
  assign cs_linear = !cs_cap.perms[P_D];
  // a destination may be overwritten only when it is empty or copyable
  assign cd_ok     = !live_cd || cd_cap.perms[P_D];

  // the three granule-table lookups
  cap_t        ka;
  logic [16:0] g_d, g_c;
  assign ka      = d.kind == K_CAP || d.kind == K_CAP2 ? cs_cap : xcap;
  assign g_a     = ka.space == SP_T2 ? gt2[G2W'(ka.base >> GRAN_SHIFT)] : gt3[G3W'(ka.base >> GRAN_SHIFT)];
  assign g_d     = cd_cap.space == SP_T2 ? gt2[G2W'(cd_cap.base >> GRAN_SHIFT)]
                                         : gt3[G3W'(cd_cap.base >> GRAN_SHIFT)];
  assign g_c     = ct_entry.space == SP_T2 ? gt2[G2W'(ct_entry.base >> GRAN_SHIFT)]
                                           : gt3[G3W'(ct_entry.base >> GRAN_SHIFT)];
  assign live_a  = g_live(ka, g_a);
  assign live_cd = g_live(cd_cap, g_d);
  assign live_ct = g_live(ct_entry, g_c);

  logic [63:0] give_node;
  logic        give_bad;
  // cgive names a node relative to the core window; csend names it through an endpoint
  cap_t        ep_cap;
  logic        is_send, is_recv;
  assign ep_cap    = d.kind == K_CAP2 && d.cap_fn == C2_SEND ? caps[d.rd[3:0]] : caps[d.rs1[3:0]];
  assign is_send   = state == S_EX && d.kind == K_CAP2 && d.cap_fn == C2_SEND;
  assign is_recv   = state == S_EX && d.kind == K_CAP2 && d.cap_fn == C2_RECV;
  assign give_node = is_send ? ep_cap.base : rb + csr_corebase;
  logic        dst_halted;
  always_comb begin
    dst_halted = 0;
    for (int i = 0; i < NCORES; i++) if (give_node == 64'(i)) dst_halted = halted_vec[i];
  end
  assign give_bad  = is_send ? (give_node > 64'(NCORES) || dst_halted)
                     : ((user && csr_corecount == 0) || (csr_corecount != 0 && rb >= csr_corecount)
                        || give_node > 64'(NCORES) || dst_halted);

  // csend's capability operand is in the rs1 field (cs), its endpoint in rd
  assign give_valid = ((state == S_EX && d.kind == K_CAP && d.cap_fn == CF_GIVE) ||
                       (is_send && ep_cap.valid && ep_cap.space == SP_EP && ep_cap.perms[P_W])) &&
                      live_a && !give_bad && tu_mem_idle;
  assign give_dst   = give_node[7:0];
  assign give_cap   = cs_cap;
  // a time-shared user process (corecount 0) has no access to the core's inbox
  logic        inbox_priv;
  assign inbox_priv = user;                 // user mode: the inbox is the kernel's (it emulates ctake)
  assign take_req   = ((state == S_EX && d.kind == K_CAP && d.cap_fn == CF_TAKE && !inbox_priv) ||
                       (is_recv && ep_cap.valid && ep_cap.space == SP_EP && ep_cap.perms[P_R])) && cd_ok;
  assign take_any   = !is_recv && !d.flag;
  assign take_src   = is_recv ? ep_cap.base[7:0] : 8'(rb + csr_corebase);
  assign take_pop   = take_req && take_hit;

  // ================================================================ overlay map lookup
  // With xslot = 0 a map entry matches one far address exactly; with
  // xslot = n it covers a 2^n-byte slot. xret looks up a far return link
  // (bit 63 set) the same way, in any space.
  logic        xm_hit, xm_inslot;
  logic [63:0] xm_target, xc_key, sl, xm_link;
  assign sl     = xslot != 0 ? 64'd1 << xslot : 64'd1;
  assign xc_key = d.flag ? {1'b0, ra[62:0]} : xcap.base + ra;
  always_comb begin
    xm_hit    = 0;
    xm_target = '0;
    for (int i = 0; i < NXMAP; i++)
      if (!xm_hit && xm_v[i] && (d.flag || xm_sp[i] == xcap.space) &&
          xc_key >= xm_far[i] && xc_key < xm_far[i] + sl) begin
        xm_hit    = 1;
        xm_target = xm_ils[i] + (xc_key - xm_far[i]);
      end
    // the link an xcall leaves: a far address when called from inside a mapped unit
    xm_inslot = 0;
    xm_link   = pc + 4;
    for (int i = 0; i < NXMAP; i++)
      if (xslot != 0 && !xm_inslot && xm_v[i] && pc >= xm_ils[i] && pc < xm_ils[i] + sl) begin
        xm_inslot = 1;
        xm_link   = 64'h8000_0000_0000_0000 | (xm_far[i] + (pc + 4 - xm_ils[i]));
      end
  end

  // ================================================================ far-atomic port
  assign am_req   = state == S_EX && d.kind == K_TAMO && amo_fault == 0 && tu_mem_idle;
  assign am_op    = d.amo_op;
  assign am_space = xcap.space;
  assign am_addr  = xcap.base + ra;
  assign am_wdata = rb;
  assign am_cmp   = rc;

  // ================================================================ CSR read
  logic [63:0] csr_rv;
  always_comb begin
    case (d.imm16)
      CSR_CYCLE:     csr_rv = csr_cycle;
      CSR_INSTRET:   csr_rv = csr_instret;
      CSR_CAUSE:     csr_rv = csr_cause;
      CSR_EPC:       csr_rv = csr_epc;
      CSR_STATUS:    csr_rv = {62'b0, !spp_user, !user};
      CSR_UCAUSE:    csr_rv = u_cause;
      CSR_UEPC:      csr_rv = u_epc;
      CSR_UTVAL:     csr_rv = u_tval;
      CSR_UTVEC:     csr_rv = u_tvec;
      CSR_SSCRATCH:  csr_rv = sscratch;
      CSR_IPEND:     csr_rv = {63'b0, ipend};
      CSR_XSLOT:     csr_rv = {58'b0, xslot};
      CSR_TVAL:      csr_rv = csr_tval;
      CSR_TVEC:      csr_rv = csr_tvec;
      CSR_CCR:       csr_rv = csr_ccr;
      CSR_COREID:    csr_rv = 64'(COREID) - csr_corebase;
      CSR_TTAG:      csr_rv = csr_ttag;
      CSR_TDATA:     csr_rv = csr_tdata;
      CSR_TGEOM:     csr_rv = csr_tgeom;
      CSR_NCORES:    csr_rv = csr_corecount != 0 ? csr_corecount : 64'(NCORES);
      CSR_SCRATCH:   csr_rv = csr_scratch;
      CSR_STALLS:    csr_rv = csr_stalls;
      CSR_TAKEFROM:  csr_rv = csr_takefrom;
      CSR_COREBASE:  csr_rv = csr_corebase;
      CSR_CORECOUNT: csr_rv = csr_corecount;
      default:       csr_rv = '0;
    endcase
  end

  assign halted = state == S_HALT;

  // revocation requests (supervisor only; validity checked in EX)
  logic c2_ok, revoker_ok, dom_src_ok;
  assign revoker_ok = live_a && cs_cap.perms[P_V] && !cs_cap.rv;
  // cdom: a live, linear, writable, non-revocable T2 / T3 capability for whole granules
  assign dom_src_ok = live_a && cs_cap.perms[P_W] && !cs_cap.perms[P_D] && !cs_cap.rv &&
                      (cs_cap.space == SP_T2 || cs_cap.space == SP_T3) && cs_cap.len != 0 &&
                      cs_cap.base[GRAN_SHIFT-1:0] == 0 && cs_cap.len[GRAN_SHIFT-1:0] == 0;
  assign c2_ok      = state == S_EX && d.kind == K_CAP2 && !user && cd_i != cs_i && cd_ok &&
                      ((d.cap_fn == C2_DOM && dom_src_ok) ||
                       ((d.cap_fn == C2_REVOKE || d.cap_fn == C2_UNDOM) && revoker_ok && cs_cap.len != 0));
  assign dom_req    = c2_ok;
  assign dom_op     = d.cap_fn == C2_DOM ? 2'd0 : d.cap_fn == C2_REVOKE ? 2'd1 : 2'd2;
  assign dom_t2     = cs_cap.space == SP_T2;
  assign dom_a      = GW'(cs_cap.base >> GRAN_SHIFT);
  assign dom_n      = GW'(cs_cap.len >> GRAN_SHIFT);

  // ================================================================ Local Store port A
  logic        lt_rd;
  logic [63:0] lt_rd_a, va, ca, nv;
  assign lt_rd_a = lt_ebase + 64'(lt_k) * 8;
  assign va      = lt_ebase + lt_victim * 8;                         // the victim's tag word
  assign ca      = lt_ebase + 64'(lt_ways) * 8;                      // the set's counter word
  assign nv      = lt_victim + 1 == 64'(lt_ways) ? 64'd0 : lt_victim + 1;
  always_comb begin
    ia_en    = state == S_F0 && pc[1:0] == 0 && pc < 64'(ILS_BYTES) && !hz_fetch_stall;
    ia_addr  = pc[15:3];
    da_en    = 0;
    da_we    = '0;
    da_addr  = maddr[15:3];
    da_wdata = rb << mshift;
    lt_rd    = state == S_LT && !lt_ph;
    if (state == S_EX && d.kind == K_LOAD && mok && !hz_rd_stall) begin
      da_en = 1;                                         // read; data arrives in LD
    end else if (state == S_EX && d.kind == K_STORE && mok && !hz_wr_stall) begin
      da_en = 1;
      da_we = mmask;
    end else if (lt_rd) begin
      da_en   = 1;
      da_addr = lt_rd_a[15:3];
    end else if (state == S_LW && lt_ph) begin           // linst, first: the victim's tag
      da_en    = 1;
      da_we    = 8'hff;
      da_addr  = va[15:3];
      da_wdata = lt_key;
    end else if (state == S_LW) begin                    // then: the replacement counter
      da_en    = 1;
      da_we    = 8'hff;
      da_addr  = ca[15:3];
      da_wdata = nv;
    end
  end
  assign div_start = state == S_EX && is_div;
  // capability-table write: csave stores the source capability
  assign ct_we = state == S_EX && d.kind == K_CAP && d.cap_fn == CF_SAVE && !user && live_a
                 && !(live_ct && !ct_entry.perms[P_D]);
  assign ct_wd = cs_cap;

  // ================================================================ sequential
  task automatic retire(input logic [63:0] next_pc);
    pc          <= next_pc;
    csr_instret <= csr_instret + 1;
    state       <= S_F0;
  endtask

  task automatic wr(input logic [4:0] r, input logic [63:0] v);
    if (r != 0) x[r] <= v;
  endtask

  // A trap in user mode goes to the program's own handler when it installed
  // one and the cause is its business; halts, stops, privilege violations and
  // anything without a user handler go to the supervisor.
  task automatic trap(input logic [7:0] cause, input logic [63:0] tval);
    logic dbl;
    if (user && !(cause == C_HALT || cause == C_STOP || cause == C_PRIV || cause == C_SVC || u_tvec == 0 || pc == u_tvec)) begin
      u_epc   <= pc;
      u_cause <= 64'(cause);
      u_tval  <= tval;
      pc      <= u_tvec;
      state   <= S_F0;
    end else begin
      dbl = !user && s_tvec != 0 && pc == s_tvec;        // the handler's first instruction faulted
      s_epc    <= pc;
      s_cause  <= 64'(cause);
      s_tval   <= tval;
      spp_user <= user;
      user     <= 0;
      if (s_tvec == 0 || dbl) begin
`ifdef SIMULATION
        sim_fault(COREID, int'(cause), pc, tval, dbl ? 1 : 0);
`endif
        state <= S_HALT;
      end else begin
        pc    <= s_tvec;
        state <= S_F0;
      end
    end
  endtask

  task automatic stall();
    csr_stalls <= csr_stalls + 1;
  endtask

  task automatic pending(input logic [63:0] a);
    if (csr_ccr[0]) trap(C_PEND, a);
    else stall();
  endtask

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= S_F0;
      pc    <= '0;
      ir    <= '0;
      for (int i = 0; i < 32; i++) x[i] <= '0;
      for (int i = 0; i < NCAPS; i++) caps[i] <= CAP_NULL;
      ctab_v <= '0;
      for (int i = 0; i < NXMAP; i++) xm_v[i] <= 0;
      // reset capabilities: core 0 owns all memory and the device root;
      // every core may write the console
      if (COREID == 0) begin
        caps[0] <= '{valid: 1, space: SP_T3,   perms: 6'b000111, base: 0, len: 64'(T3_BYTES), rv: 0, gen: 0};
        caps[1] <= '{valid: 1, space: SP_T2,   perms: 6'b000111, base: 0, len: 64'(T2_BYTES), rv: 0, gen: 0};
        caps[3] <= '{valid: 1, space: SP_DEV,  perms: 6'b010011, base: 0, len: DEV_LEN, rv: 0, gen: 0};
        caps[4] <= '{valid: 1, space: SP_CORE, perms: 6'b010010, base: 0, len: 64'(NCORES * 8), rv: 0, gen: 0};
      end
      caps[2] <= '{valid: 1, space: SP_DEV, perms: 6'b010010, base: 0, len: 64'd1, rv: 0, gen: 0};
      csr_cycle     <= '0;
      csr_instret   <= '0;
      s_cause       <= '0;
      s_epc         <= '0;
      s_tval        <= '0;
      s_tvec        <= '0;
      u_cause       <= '0;
      u_epc         <= '0;
      u_tval        <= '0;
      u_tvec        <= '0;
      sscratch      <= '0;
      user          <= 0;
      spp_user      <= 0;
      ipend         <= 0;
      xslot         <= '0;
      csr_ccr       <= '0;
      csr_ttag      <= '0;
      csr_tdata     <= '0;
      csr_tgeom     <= '0;
      csr_scratch   <= '0;
      csr_stalls    <= '0;
      csr_takefrom  <= '0;
      csr_corebase  <= '0;
      csr_corecount <= '0;
      lt_k          <= '0;
      lt_ph         <= 0;
    end else begin
      csr_cycle <= csr_cycle + 1;
      if (stop_req) ipend <= 1;                          // core control asked us to stop

      case (state)
        // ------------------------------------------------------------ fetch
        S_F0: begin
          if (user && ipend) begin ipend <= 0; trap(C_STOP, 64'd0); end
          else if (pc[1:0] != 0 || pc >= 64'(ILS_BYTES)) trap(C_IFAULT, pc);
          else if (hz_fetch_stall) stall();
          else state <= S_F1;
        end
        S_F1: begin
          ir    <= pc[2] ? ia_rdata[63:32] : ia_rdata[31:0];
          state <= S_EX;
`ifdef SIMULATION
          if (trace_on) sim_trace(COREID, pc, pc[2] ? ia_rdata[63:32] : ia_rdata[31:0]);
`endif
        end

        // ------------------------------------------------------------ execute
        S_EX: begin
          // a stop is taken at instruction boundaries, also while an instruction waits
          if (user && ipend) begin ipend <= 0; trap(C_STOP, 64'd0); end
          else case (d.kind)
            K_ILLEGAL: trap(C_ILLEGAL, {32'b0, ir});

            K_ALU, K_ALUI: begin
              if (is_div) begin
                state <= S_DV;                           // the divider starts this cycle
              end else begin
                wr(d.rd, alu_y);
                retire(pc + 4);
              end
            end
            K_LUI: begin wr(d.rd, d.imm); retire(pc + 4); end

            K_LOAD: begin
              if (!mok) trap(C_LSFAULT, maddr);
              else if (hz_rd_stall) pending(maddr);
              else state <= S_LD;
            end
            K_STORE: begin
              if (!mok) trap(C_LSFAULT, maddr);
              else if (hz_wr_stall) pending(maddr);
              else retire(pc + 4);                       // the write happened this cycle
            end

            K_BRANCH: retire(br_taken ? pc + d.imm : pc + 4);
            K_JAL:    begin wr(d.rd, pc + 4); retire(pc + d.imm); end
            K_JALR:   begin wr(d.rd, pc + 4); retire((ra + d.imm) & ~64'd3); end

            K_XFER: begin
              if (xf_fault != 0) trap(xf_fault, xf_tval);
              else if (tu_iss_hz) pending(ra);           // waits for an in-flight device read
              else if (tu_iss_ready) begin
                if (d.xf_sub == XF_GETX)                 // code being replaced: forget overlay
                  for (int i = 0; i < NXMAP; i++)        // mappings that point into it
                    if (xm_ils[i] < ra + rc && ra < xm_ils[i] + (xslot != 0 ? sl : 64'd4)) xm_v[i] <= 0;
                retire(pc + 4);
              end else stall();
            end

            K_TWAIT: if ((tag_busy & d.imm16) != 0) stall(); else retire(pc + 4);
            K_TPOLL: begin wr(d.rd, {48'b0, tag_busy & d.imm16}); retire(pc + 4); end
            K_TANY: begin                                // wait for any of: tags idle, a gift
              logic [16:0] ready;
              ready = {ra[16] && poll_mask != 0, ~tag_busy & ra[15:0]};
              if (ra[16] && inbox_priv) trap(C_PRIV, {32'b0, ir});
              else if (ra[16:0] != 0 && ready == 0) stall();
              else begin wr(d.rd, {47'b0, ready}); retire(pc + 4); end
            end

            K_TAMO: begin
              if (amo_fault != 0) trap(amo_fault, ra);
              else if (am_gnt) state <= S_AM;
              else stall();                              // waits for our transfers, then the bus
            end

            K_CAP: begin
              case (d.cap_fn)
                CF_MOV, CF_RESTR: begin
                  if (!live_a) trap(C_CAPINV, 64'(cs_i));
                  else if (cd_i != cs_i && !cd_ok) trap(C_CAPOP, 64'(cd_i));
                  else begin
                    caps[cd_i] <= d.cap_fn == CF_MOV ? cs_cap
                                  : '{valid: 1, space: cs_cap.space, perms: cs_cap.perms & rb[5:0],
                                      base: cs_cap.base, len: cs_cap.len, rv: cs_cap.rv, gen: cs_cap.gen};
                    if (cd_i != cs_i && cs_linear) caps[cs_i] <= CAP_NULL;
                    retire(pc + 4);
                  end
                end
                CF_SPLIT: begin
                  if (!live_a) trap(C_CAPINV, 64'(cs_i));
                  else if (cd_i == cs_i || rb > cs_cap.len || rb[2:0] != 0 || !cd_ok   // 8-aligned;
                           || (cs_cap.perms[P_V] && rb[GRAN_SHIFT-1:0] != 0)) trap(C_CAPOP, rb); // a revoker: granules
                  else begin
                    caps[cd_i] <= '{valid: 1, space: cs_cap.space, perms: cs_cap.perms,
                                    base: cs_cap.base + rb, len: cs_cap.len - rb,
                                    rv: cs_cap.rv, gen: cs_cap.gen};
                    caps[cs_i].len <= rb;
                    retire(pc + 4);
                  end
                end
                CF_JOIN: begin
                  if (!live_a || !live_cd) trap(C_CAPINV, 64'(cs_i));
                  else if (cd_i == cs_i || cd_cap.space != cs_cap.space || cd_cap.perms != cs_cap.perms
                           || cd_cap.rv != cs_cap.rv || cd_cap.gen != cs_cap.gen
                           || cd_cap.base + cd_cap.len != cs_cap.base
                           // never across units: not where one begins (a HEAD granule boundary)
                           || (cs_cap.rv && cs_cap.base[GRAN_SHIFT-1:0] == 0 && g_a[16])) trap(C_CAPOP, 64'(cs_i));
                  else begin
                    caps[cd_i].len <= cd_cap.len + cs_cap.len;
                    caps[cs_i]     <= CAP_NULL;
                    retire(pc + 4);
                  end
                end
                CF_SHARE: begin
                  if (!live_a) trap(C_CAPINV, 64'(cs_i));
                  else if ((cs_cap.perms & 6'b000101) == 0) trap(C_PERM, 64'(cs_i));
                  else if (cd_i != cs_i && !cd_ok) trap(C_CAPOP, 64'(cd_i));
                  else if (!tu_mem_idle) stall();
                  else begin
                    caps[cd_i] <= '{valid: 1, space: cs_cap.space,
                                    perms: (cs_cap.perms & 6'b000101) | 6'b010000,
                                    base: cs_cap.base, len: cs_cap.len, rv: cs_cap.rv, gen: cs_cap.gen};
                    if (cd_i != cs_i && cs_linear) caps[cs_i] <= CAP_NULL;
                    retire(pc + 4);
                  end
                end
                CF_ATOM: begin
                  if (!live_a) trap(C_CAPINV, 64'(cs_i));
                  else if (!cs_cap.perms[P_W] || (cs_cap.space != SP_T2 && cs_cap.space != SP_T3)) trap(C_PERM, 64'(cs_i));
                  else if (cd_i != cs_i && !cd_ok) trap(C_CAPOP, 64'(cd_i));
                  else if (!tu_mem_idle) stall();
                  else begin
                    caps[cd_i] <= '{valid: 1, space: cs_cap.space, perms: 6'b011000,
                                    base: cs_cap.base, len: cs_cap.len, rv: cs_cap.rv, gen: cs_cap.gen};
                    if (cd_i != cs_i) caps[cs_i] <= CAP_NULL;
                    retire(pc + 4);
                  end
                end
                CF_BASE, CF_LEN, CF_PERMS: begin
                  if (!live_a) trap(C_CAPINV, 64'(cs_i));
                  else begin
                    wr(d.rd, d.cap_fn == CF_BASE ? cs_cap.base
                           : d.cap_fn == CF_LEN ? cs_cap.len
                           : {53'b0, cs_cap.space, 2'b0, cs_cap.perms});
                    retire(pc + 4);
                  end
                end
                CF_VALID: begin wr(d.rd, {63'b0, live_a}); retire(pc + 4); end
                CF_GIVE: begin
                  if (!live_a) trap(C_CAPINV, 64'(cs_i));
                  // outside the core window: tval = the window-relative number
                  else if ((user && csr_corecount == 0) || (csr_corecount != 0 && rb >= csr_corecount))
                    trap(C_CAPOP, rb);
                  else if (give_bad) trap(C_CAPOP, give_node);
                  else if (give_valid && give_ack) begin
                    if (cs_linear) caps[cs_i] <= CAP_NULL;
                    retire(pc + 4);
                  end else stall();
                end
                CF_TAKE: begin
                  if (inbox_priv) trap(C_PRIV, {32'b0, ir});
                  else if (!cd_ok) trap(C_CAPOP, 64'(cd_i));
                  else if (take_hit) begin
                    caps[cd_i]   <= take_cap;
                    csr_takefrom <= 64'(take_from) - csr_corebase;
                    retire(pc + 4);
                  end else stall();
                end
                CF_CLEAR: begin caps[cd_i] <= CAP_NULL; retire(pc + 4); end
                CF_SAVE: begin
                  if (user) trap(C_PRIV, {32'b0, ir});     // the save table is the supervisor's
                  else if (!live_a) trap(C_CAPINV, 64'(cs_i));
                  else if (live_ct && !ct_entry.perms[P_D]) trap(C_CAPOP, 64'(d.slot));
                  else begin
                    ctab_v[d.slot] <= 1;                 // (the data is written by ct_we below)
                    if (cs_linear) caps[cs_i] <= CAP_NULL;
                    retire(pc + 4);
                  end
                end
                CF_RESTORE: begin
                  if (user) trap(C_PRIV, {32'b0, ir});
                  else if (!live_ct) trap(C_CAPINV, 64'(d.slot));
                  else if (!cd_ok) trap(C_CAPOP, 64'(cd_i));
                  else begin
                    caps[cd_i] <= ct_entry;
                    if (!ct_entry.perms[P_D]) ctab_v[d.slot] <= 0;
                    retire(pc + 4);
                  end
                end
                CF_POLL: if (inbox_priv) trap(C_PRIV, {32'b0, ir});
                         else begin wr(d.rd, {48'b0, poll_mask >> csr_corebase[3:0]}); retire(pc + 4); end
                default: trap(C_ILLEGAL, {32'b0, ir});
              endcase
            end

            K_CSRR: if (user && (d.imm16 == CSR_SSCRATCH || d.imm16 == CSR_IPEND)) trap(C_PRIV, {32'b0, ir});
                    else begin wr(d.rd, csr_rv); retire(pc + 4); end
            K_CSRW: if (user && (d.imm16 == CSR_STATUS || d.imm16 == CSR_COREBASE || d.imm16 == CSR_CORECOUNT ||
                                 (d.imm16 >= CSR_UCAUSE && d.imm16 <= CSR_IPEND))) trap(C_PRIV, {32'b0, ir});
            else begin
              case (d.imm16)
                CSR_CAUSE:     if (user) u_cause <= ra; else s_cause <= ra;
                CSR_EPC:       if (user) u_epc   <= ra; else s_epc   <= ra;
                CSR_TVAL:      if (user) u_tval  <= ra; else s_tval  <= ra;
                CSR_TVEC:      if (user) u_tvec  <= ra; else s_tvec  <= ra;
                CSR_STATUS:    spp_user <= !ra[1];
                CSR_UCAUSE:    u_cause  <= ra;
                CSR_UEPC:      u_epc    <= ra;
                CSR_UTVAL:     u_tval   <= ra;
                CSR_UTVEC:     u_tvec   <= ra;
                CSR_SSCRATCH:  sscratch <= ra;
                CSR_IPEND:     ipend    <= ra[0];
                CSR_XSLOT:     xslot    <= ra[5:0];
                CSR_CCR:       csr_ccr       <= ra;
                CSR_TTAG:      csr_ttag      <= ra;
                CSR_TDATA:     csr_tdata     <= ra;
                CSR_TGEOM:     csr_tgeom     <= ra;
                CSR_SCRATCH:   csr_scratch   <= ra;
                CSR_COREBASE:  csr_corebase  <= ra;
                CSR_CORECOUNT: csr_corecount <= ra;
                default: ;
              endcase
              retire(pc + 4);
            end

            K_SYS: begin
              if (d.imm16 == SYS_SVC) begin             // a request to the supervisor
                if (user) trap(C_SVC, 64'd0);
                else trap(C_ILLEGAL, {32'b0, ir});
              end else if (d.imm16 == SYS_HALT) begin
                if (!tu_idle) stall();                   // halting drains our transfers first
                else if (user) trap(C_HALT, 64'd0);      // a program's halt goes to its supervisor
                else begin
`ifdef SIMULATION
                  sim_halt(COREID, x[10], csr_cycle, csr_instret + 1, csr_stalls);
`endif
                  csr_instret <= csr_instret + 1;
                  state <= S_HALT;
                end
              end else if (user) retire(u_epc);          // eret in a user handler
              else begin                                 // eret in the supervisor: back to
                user <= spp_user;                        //   the mode the trap came from
                retire(s_epc);
              end
            end

            K_LTAG, K_LINST: begin
              if (!lt_ok) trap(C_LSFAULT, lt_ebase_c);
              else if (d.kind == K_LTAG ? hz_rd_stall : hz_wr_stall) pending(lt_ebase_c);
              else begin
                lt_key   <= (lt_line << 1) | 64'd1;
                lt_set   <= lt_set_c;
                lt_ebase <= lt_ebase_c;
                lt_off   <= ra & ((64'd1 << lt_lsh) - 1);
                lt_k     <= d.kind == K_LTAG ? 4'd0 : lt_ways;
                lt_ph    <= 0;
                state    <= S_LT;
              end
            end

            K_XMAP: begin
              if (d.rd[4]) trap(C_ILLEGAL, {32'b0, ir});
              else if (d.flag) begin xm_v[d.rd[3:0]] <= 0; retire(pc + 4); end
              else if (!live_a) trap(C_CAPINV, 64'(d.cs));
              else if (!xcap.perms[P_X]) trap(C_PERM, 64'(d.cs));
              else if (rb >= xcap.len) trap(C_BOUNDS, rb);
              else if (ra[1:0] != 0 || ra >= 64'(ILS_BYTES)) trap(C_LSFAULT, ra);
              else begin
                xm_v[d.rd[3:0]]   <= 1;
                xm_sp[d.rd[3:0]]  <= xcap.space;
                xm_far[d.rd[3:0]] <= xcap.base + rb;
                xm_ils[d.rd[3:0]] <= ra;
                retire(pc + 4);
              end
            end

            K_XCALL: begin
              if (d.flag) begin                          // xret rs1
                if (!ra[63]) retire({ra[63:2], 2'b00}); // an ordinary return address
                else if (!xm_hit) trap(C_XMISS, ra);     // the caller was evicted: page it back in
                else retire(xm_target);
              end
              else if (!live_a) trap(C_CAPINV, 64'(d.cs));
              else if (!xcap.perms[P_X]) trap(C_PERM, 64'(d.cs));
              else if (ra >= xcap.len) trap(C_BOUNDS, ra);
              else if (!xm_hit) trap(C_XMISS, xc_key);
              else begin wr(d.rd, xm_link); retire(xm_target); end
            end

            K_CAP2: begin
              unique case (d.cap_fn)
                C2_SEND: begin                           // csend cs, ce
                  if (!ep_cap.valid || ep_cap.space != SP_EP || !ep_cap.perms[P_W]) trap(C_CAPINV, 64'(d.rd[3:0]));
                  else if (!live_a) trap(C_CAPINV, 64'(cs_i));
                  else if (give_bad) trap(C_CAPOP, give_node);
                  else if (give_valid && give_ack) begin
                    if (cs_linear) caps[cs_i] <= CAP_NULL;
                    retire(pc + 4);
                  end else stall();
                end
                C2_RECV: begin                           // crecv cd, ce
                  if (!ep_cap.valid || ep_cap.space != SP_EP || !ep_cap.perms[P_R]) trap(C_CAPINV, 64'(cs_i));
                  else if (!cd_ok) trap(C_CAPOP, 64'(cd_i));
                  else if (take_hit) begin
                    caps[cd_i]   <= take_cap;
                    csr_takefrom <= 64'(take_from) - csr_corebase;
                    retire(pc + 4);
                  end else stall();
                end
                C2_MKEP: begin                           // cmkep cd, rx
                  if (user) trap(C_PRIV, {32'b0, ir});
                  else if (!cd_ok) trap(C_CAPOP, 64'(cd_i));
                  else if (rb > 64'(NCORES)) trap(C_CAPOP, rb);
                  else begin
                    caps[cd_i] <= '{valid: 1, space: SP_EP, perms: 6'b010011, base: rb, len: 64'd1, rv: 0, gen: 0};
                    retire(pc + 4);
                  end
                end
                default: begin                           // cdom / crevoke / cundom
                  if (user) trap(C_PRIV, {32'b0, ir});
                  else if (d.cap_fn == C2_DOM && !live_a) trap(C_CAPINV, 64'(cs_i));
                  else if (d.cap_fn == C2_DOM && !c2_ok) trap(C_CAPOP, 64'(cs_i));
                  else if (d.cap_fn != C2_DOM && !revoker_ok) trap(C_CAPINV, 64'(cs_i));
                  else if (cd_i == cs_i || !cd_ok) trap(C_CAPOP, 64'(cd_i));
                  else if (!c2_ok) trap(C_CAPOP, 64'(cs_i));          // an empty revoker
                  else if (dom_done) begin
                    if (d.cap_fn == C2_DOM) begin
                      caps[cd_i] <= '{valid: 1, space: cs_cap.space, perms: cs_cap.perms, base: cs_cap.base,
                                      len: cs_cap.len, rv: 1, gen: dom_gen};
                      caps[cs_i] <= '{valid: 1, space: cs_cap.space, perms: 6'b100000, base: cs_cap.base,
                                      len: cs_cap.len, rv: 0, gen: {10'b0, cs_cap.perms}};
                    end else if (d.cap_fn == C2_REVOKE) begin
                      caps[cd_i] <= '{valid: 1, space: cs_cap.space, perms: cs_cap.gen[5:0],
                                      base: cs_cap.base, len: cs_cap.len, rv: 1, gen: dom_gen};
                    end else begin
                      caps[cd_i] <= '{valid: 1, space: cs_cap.space, perms: cs_cap.gen[5:0],
                                      base: cs_cap.base, len: cs_cap.len, rv: 0, gen: 16'd0};
                      caps[cs_i] <= CAP_NULL;
                    end
                    retire(pc + 4);
                  end else stall();                      // the top level is walking the table
                end
              endcase
            end

            default: trap(C_ILLEGAL, {32'b0, ir});
          endcase
        end

        // ------------------------------------------------------------ load data
        S_LD: begin wr(d.rd, mload); retire(pc + 4); end

        // ------------------------------------------------------------ division
        S_DV: if (div_done) begin
          wr(d.rd, (d.alu_op == ALU_REMU || d.alu_op == ALU_REM) ? div_r : div_q);
          retire(pc + 4);
        end

        // ------------------------------------------------------------ far atomic
        S_AM: if (am_done) begin wr(d.rd, bus_rdata); retire(pc + 4); end

        // ------------------------------------------------------------ tag lookup
        S_LT: begin
          if (!lt_ph) lt_ph <= 1;                        // the read was issued; data next cycle
          else begin
            lt_ph <= 0;
            if (d.kind == K_LTAG && lt_k < lt_ways) begin
              if (da_rdata == lt_key) begin
                wr(d.rd, csr_tdata + ((lt_set * 64'(lt_ways) + 64'(lt_k)) << lt_lsh) + lt_off);
                retire(pc + 4);
              end else lt_k <= lt_k + 1;
            end else begin
              // da_rdata is the set's replacement counter: it names the victim way
              logic [63:0] victim;
              victim = da_rdata < 64'(lt_ways) ? da_rdata : 64'd0;
              if (d.kind == K_LTAG) begin
                wr(d.rd, (csr_tdata + ((lt_set * 64'(lt_ways) + victim) << lt_lsh)) | 64'h8000_0000_0000_0000);
                retire(pc + 4);
              end else begin
                lt_victim <= victim;
                lt_ph     <= 1;                          // stay: write the tag next cycle
                state     <= S_LW;
              end
            end
          end
        end
        S_LW: begin
          if (lt_ph) lt_ph <= 0;                         // the victim's tag is written this cycle
          else retire(pc + 4);                           // and the counter this one
        end

        S_HALT: ;
        default: state <= S_F0;
      endcase
    end
  end
endmodule
