#!/usr/bin/env python3
"""Makes the ASIC versions of three RTL files, without changing them.

    asic/mktop.py core rtl/strata_core.sv                  > strata_core.sv
    asic/mktop.py top  rtl/strata_top.sv rtl/strata_dev.sv > strata_asic_top.sv
    asic/mktop.py mem  rtl/strata_mem.sv                   > strata_mem.sv

core: strata_core with its capability save table (ctab, 256 capabilities)
in SRAM macros (strata_sram_w, asic/rtl/gf180mcu/strata_sram_w.sv) instead
of an array: as on the FPGA, where it is block RAM. The table is read in S_EX
(registered, into ct_entry) and written in S_RST or S_CT, never both in one
cycle, so the single-port SRAM is the same memory. As flip-flops it was
20,736 of them plus a 256-way multiplexer, and OpenROAD's design repair ran
for hours on it.

top: module strata_asic_top is strata_top with system memory outside
(T3_EXT = 1), a 64 KiB T2 (as fpga/synth.sh) and the device block
(strata_dev: console, timer, disk, platform table) outside too: its
instance is removed and every port of it becomes a pin of the chip, named
devp_<port> (an output of the device block is an input pin, and so on).

mem: strata_mem with its array replaced by strata_sram_sp (SRAM macros,
asic/rtl/gf180mcu/strata_sram_sp.sv). The array has one synchronous read
port and one write port that are never used in the same cycle, so the
single-port SRAM is the same memory.
"""
import re
import sys


def ports(dev_src):
    """strata_dev's ports: name -> (direction, type)."""
    start = dev_src.index(")(", dev_src.index("module strata_dev")) + 2
    header = dev_src[start: dev_src.index(");", start)]
    out = {}
    for m in re.finditer(r"^\s*(input|output)\s+(.*?)\s*(\w+)\s*,?\s*(//.*)?$", header, re.M):
        out[m.group(3)] = (m.group(1), m.group(2))
    return out


def top(top_src, dev_src):
    dp = ports(dev_src)
    s = top_src.replace("module strata_top", "module strata_asic_top", 1)
    s = re.sub(r"(parameter bit\s+T3_EXT\s+=\s*)0", r"\g<1>1", s, count=1)
    s = re.sub(r"(parameter int\s+T2_W\s+=\s*)T2_WORDS", r"\g<1>8192", s, count=1)
    m = re.search(r"\n\s*strata_dev\s*#\(.*?\)\s*u_dev\s*\((.*?)\);\n", s, re.S)
    if not m:
        sys.exit("mktop: no strata_dev instance in strata_top")
    pins, assigns = [], []
    for c in re.finditer(r"\.(\w+)(?:\(([^()]*(?:\([^()]*\)[^()]*)*)\))?", m.group(1)):
        name, expr = c.group(1), c.group(2) or c.group(1)
        if name in ("clk", "rst"):
            continue
        d, t = dp[name]
        pin = f"devp_{name}"
        if d == "output":                    # the device drives it: a chip input
            pins.append(f"  input  {t} {pin}")
            assigns.append(f"  assign {expr} = {pin};")
        else:
            pins.append(f"  output {t} {pin}")
            assigns.append(f"  assign {pin} = {expr};")
    body = ("\n  // the device block (strata_dev) is off-chip: asic/mktop.py\n"
            + "\n".join(assigns) + "\n")
    s = s[:m.start()] + body + s[m.end():]
    # the new pins, after the last one of the port list
    end = s.index("\n);", s.index("module strata_asic_top"))
    s = s[:end] + ",\n\n  // device block pins (asic/mktop.py)\n" + ",\n".join(pins) + s[end:]
    return s


def core(src):
    s = src
    decl = "  cap_t        ctab [CTAB];\n"
    old = ("  always_ff @(posedge clk) begin\n"
           "    if (ct_we) ctab[ct_wa] <= ct_wd;\n"
           "    if (state == S_EX) ct_entry <= ctab[ct_i];       // S_CT's entry\n"
           "  end\n")
    if decl not in s or old not in s:
        sys.exit("mktop: strata_core's save table is not as expected")
    s = s.replace(decl, "", 1)
    s = s.replace(old, "  // the save table: SRAM macros (asic/mktop.py)\n"
                       "  strata_sram_w #(.W($bits(cap_t))) u_ctab (\n"
                       "    .clk, .en(ct_we || state == S_EX), .we(ct_we), .addr(ct_we ? ct_wa : ct_i),\n"
                       "    .wdata(ct_wd), .rdata(ct_entry)\n  );\n", 1)
    return s


def mem(mem_src):
    s = mem_src
    s = s.replace("  logic [63:0] mem [WORDS];\n", "", 1)
    s = re.sub(r"`else\n\s*initial if \(INIT != \"\"\) \$readmemh\(INIT, mem\);\n", "", s, count=1)
    old = re.search(r"  always_ff @\(posedge clk\) begin\n\s*if \(rd_en\) q <= mem\[rd_a\];\n"
                    r"\s*if \(wr_en\) mem\[wr_a\] <= wr_d;\n\s*end\n", s)
    if not old or "`ifdef SIMULATION\n  initial for" not in s:
        sys.exit("mktop: strata_mem's array is not as expected")
    new = ("  // the array: SRAM macros (asic/mktop.py)\n"
           "  strata_sram_sp #(.WORDS(WORDS)) u_sram (\n"
           "    .clk, .en(rd_en || wr_en), .we(wr_en), .addr(wr_en ? wr_a : rd_a),\n"
           "    .wdata(wr_d), .rdata(q)\n  );\n")
    s = s[:old.start()] + new + s[old.end():]
    # the simulation-only block that reads the array (never in synthesis)
    s = re.sub(r"`ifdef SIMULATION\n  initial for.*?`endif\n", "", s, count=1, flags=re.S)
    return s


if __name__ == "__main__":
    if sys.argv[1] == "core":
        print(core(open(sys.argv[2]).read()), end="")
    elif sys.argv[1] == "top":
        print(top(open(sys.argv[2]).read(), open(sys.argv[3]).read()), end="")
    elif sys.argv[1] == "mem":
        print(mem(open(sys.argv[2]).read()), end="")
    else:
        sys.exit("usage: mktop.py core STRATA_CORE | top STRATA_TOP STRATA_DEV | mem STRATA_MEM")
