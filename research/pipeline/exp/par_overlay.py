#!/usr/bin/env python3
"""Writes a copy of rtl/strata_core.sv whose two overlay-map searches are
parallel: every entry's match is computed at once, the first match is
isolated as a one-hot vector (m & -m) and the entry's fields are selected by
AND-OR, instead of the loop whose `!xm_hit && ...` / `!xm_inslot && ...`
conditions chain the 16 entries one after another. The same entry wins (the
lowest index), so the behaviour is unchanged; only the shape of the logic
differs. For timing only (research/pipeline/sta/core.sh with CORE=...).

    par_overlay.py rtl/strata_core.sv OUT.sv
"""
import sys

src = open(sys.argv[1]).read()
old_start = src.index("  always_comb begin\n    logic [16:0] dl;\n    xm_hit = 0;")
old_end = src.index("  assign xm_ils_sel = xm_ils[xm_i];")
old_sel_end = src.index("  assign xm_lk_off")
new = """  logic [NXMAP-1:0] xm_m, xm_mi, xm_h1, xm_l1;   // matches, in-slot entries, their first
  always_comb begin
    logic [16:0] dl;
    for (int i = 0; i < NXMAP; i++) begin
      xm_m[i]  = xm_v[i] && (d.flag || xm_sp[i] == xcap.space) && xk_hi_ok &&
                 ((xc_key[FW-1:0] ^ xm_far[i]) & xs_hmask) == 0;
      dl       = {1'b0, pc[15:0]} - {1'b0, xm_ils[i]};
      xm_mi[i] = xslot != 0 && xm_v[i] && !dl[16] && (dl[15:0] & xl_mask) == 0;
    end
  end
  assign xm_h1     = xm_m & (~xm_m + 1'b1);
  assign xm_l1     = xm_mi & (~xm_mi + 1'b1);
  assign xm_hit    = |xm_m;
  assign xm_inslot = |xm_mi;
  always_comb begin
    xm_i = '0;
    xm_li = '0;
    xm_ils_sel = '0;
    xm_far_lk = '0;
    xm_ils_lk = '0;
    for (int i = 0; i < NXMAP; i++) begin
      xm_i       = xm_i       | (xm_h1[i] ? XW'(i) : '0);
      xm_li      = xm_li      | (xm_l1[i] ? XW'(i) : '0);
      xm_ils_sel = xm_ils_sel | (xm_h1[i] ? xm_ils[i] : '0);
      xm_far_lk  = xm_far_lk  | (xm_l1[i] ? xm_far[i] : '0);
      xm_ils_lk  = xm_ils_lk  | (xm_l1[i] ? xm_ils[i] : '0);
    end
  end
  assign xm_target  = 64'(xm_ils_sel) + (xc_key & ~xs_hmask64);
"""
out = src[:old_start] + new + src[old_sel_end:]
open(sys.argv[2], "w").write(out)
