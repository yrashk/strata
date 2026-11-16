#!/usr/bin/env python3
"""Writes a copy of rtl/strata_core.sv for a timing experiment only: the
decoded instruction, the three integer register reads, the two capability
register reads and their granule-table lookups come from registers, loaded
in the cycle before (from the next instruction's decode), as a decode /
operand-read stage in front of execute would hold them. The machine it
describes does not run correctly (nothing stalls or forwards); it shows
what such a stage boundary does to the clock in place and route.

    reg_operands.py rtl/strata_core.sv OUT.sv
"""
import sys

s = open(sys.argv[1]).read()


def rep(a, b):
    global s
    assert s.count(a) == 1, a
    s = s.replace(a, b)


rep("""  dec_t d;
  strata_decode u_dec (.ir(ir), .d(d));""", """  dec_t d, d_c;
  strata_decode u_dec (.ir(ir), .d(d_c));
  always_ff @(posedge clk) d <= d_c;""")
rep("  assign ra = x[d.pa];\n  assign rb = x[d.pb];\n", """  always_ff @(posedge clk) begin
    ra <= x[d_c.pa];
    rb <= x[d_c.pb];
    rc <= x[d_c.pc];
  end
""")
rep("  assign rc = x[d.pc];\n", "")
rep("""  assign cap_a     = caps[a_i];""", """  logic [3:0]  a_i_c;
  logic [16:0] g_a_q, g_d_q;
  assign a_i_c = d_c.kind == K_CAP || d_c.kind == K_CAP2 ? d_c.rs1[3:0] : d_c.cs;
  always_ff @(posedge clk) begin
    cap_a  <= caps[a_i_c];
    cd_cap <= caps[d_c.rd[3:0]];
    g_a_q  <= caps[a_i_c].space == SP_T2 ? gt2[G2W'(caps[a_i_c].base >> GRAN_SHIFT)]
                                         : gt3[G3W'(caps[a_i_c].base >> GRAN_SHIFT)];
    g_d_q  <= caps[d_c.rd[3:0]].space == SP_T2 ? gt2[G2W'(caps[d_c.rd[3:0]].base >> GRAN_SHIFT)]
                                               : gt3[G3W'(caps[d_c.rd[3:0]].base >> GRAN_SHIFT)];
  end""")
rep("""  assign cd_cap    = caps[cd_i];\n""", "")
rep("""  assign g_a     = ka.space == SP_T2 ? gt2[G2W'(ka.base >> GRAN_SHIFT)] : gt3[G3W'(ka.base >> GRAN_SHIFT)];
  assign g_d     = kd.space == SP_T2 ? gt2[G2W'(kd.base >> GRAN_SHIFT)] : gt3[G3W'(kd.base >> GRAN_SHIFT)];""",
    """  assign g_a     = !(state == S_CT && !ct_save) ? g_a_q
                 : ka.space == SP_T2 ? gt2[G2W'(ka.base >> GRAN_SHIFT)] : gt3[G3W'(ka.base >> GRAN_SHIFT)];
  assign g_d     = !(state == S_CT && ct_save) ? g_d_q
                 : kd.space == SP_T2 ? gt2[G2W'(kd.base >> GRAN_SHIFT)] : gt3[G3W'(kd.base >> GRAN_SHIFT)];""")
open(sys.argv[2], "w").write(s)
