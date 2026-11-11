"""Which part of the Strata design a netlist cell belongs to.

The ECP5 netlist is flat: the module boundaries are gone, and only names are
left. Yosys names every mapped cell after a nearby named signal (`autoname`):
a flip-flop of the overlay map is `g_core[0].u_core.xm_far[3]_TRELLIS_FF_Q_7`,
the LUT that computes its next value `..._TRELLIS_FF_Q_7_DI_LUT4_Z`, and a
LUT seven hops away `g_core[0].u_core.xm_v[13]_LUT4_A_Z_CCU2C_S1_..._LUT4_Z`.
The signal before the first `_LUT4`, `_CCU2C`, ... is the cell's home here.

So flip-flops, block RAM, LUT-RAM and multipliers (named after the register
or array they are) are exact; logic belongs to the nearest named signal it
computes or consumes, which is a good guess but not a module boundary: the
totals per group agree with what removing overlay map entries and
capability registers measures (fpga/README.md) to a few percent. Cells
nextpnr made itself (`$nextpnr_...`), and logic more than six hops from a
signal outside the core, take the group of the nearest placed-by-name cell
in the netlist graph.

Used by fpga/render.py.
"""
import re
from collections import deque

# (key, label, colour). The order is the legend's.
GROUPS = [
    ("xmap", "Overlay map", "#ff9f1c"),
    ("exec", "Execute, registers, CSRs", "#4de1ff"),
    ("caps", "Capabilities and revocation", "#ff5fa2"),
    ("tu",   "Transfer Unit", "#7ef05a"),
    ("alu",  "ALU, multiplier, divider, decode", "#b38cff"),
    ("ls",   "Local Stores (block RAM)", "#2f6bff"),
    ("mem",  "Bus, T2, T3, disk", "#fff27a"),
    ("dev",  "Devices and core control", "#d63a3a"),
]
GROUP_INDEX = {k: i for i, (k, _, _) in enumerate(GROUPS)}

_PRIMS = (r"TRELLIS_FF|TRELLIS_DPR16X4|TRELLIS_COMB|TRELLIS_RAMW|LUT4|CCU2C|PFUMX|"
          r"L6MUX21|DP16KD|MULT18X18D|ALU54B")
_CUT = re.compile(r"_(" + _PRIMS + r")(_|\$|$)")
_HOP = re.compile(r"_(" + _PRIMS + r")(?=_|\$|$)")
_CORE = re.compile(r"^g_core\[(\d+)\]\.u_core\.")
EXACT = ("TRELLIS_FF", "DP16KD", "MULT18X18D", "ALU54B", "TRELLIS_DPR16X4", "TRELLIS_RAMW")


def base(name):
    """The signal a cell is named after: `g_core[0].u_core.xm_v[13]`."""
    return _CUT.split(name)[0]


def hops(name):
    return len(_HOP.findall(name))


def group(name, ctype=""):
    """The GROUPS key for a name (and cell type: the multipliers are all the ALU's)."""
    if ctype in ("MULT18X18D", "ALU54B"):
        return "alu"
    b = base(name)
    m = _CORE.match(b)
    if m:
        r = b[m.end():]
        if r.startswith("xm_"):
            return "xmap"
        # the capability file, the save table, the checks, the granule
        # table copy (gt2, gt3) and its lookups, hand-over, revocation requests
        if r.startswith(("caps", "ctab", "ct_", "dom_", "give_", "take_", "cd_", "cs_",
                         "gt2", "gt3", "gt_", "g_a", "g_d", "g_c", "live_", "ka", "cap_", "xcap")):
            return "caps"
        if r.startswith("u_tu."):
            return "tu"
        if r.startswith(("u_alu", "u_mul", "u_div", "alu_", "mul", "u_dec", "ir")) or r == "d" or r.startswith(("d.", "d_")):
            return "alu"
        if r.startswith(("u_ils", "u_dls")):
            if ctype in ("DP16KD", "PDPW16KD"):
                return "ls"
            # logic feeding a Local Store port: port A is the core's, B the TU's
            return "tu" if re.match(r"u_[id]ls\.mem\.[\d.]+_(DIB|ADB|CEB|WEB)", r) else "exec"
        return "exec"
    # the inboxes, gifts, and revocation: the granule tables (mt2, mt3),
    # their walker (w_*) and broadcast (gt_*), the requests (dom_*)
    if b.startswith(("ib_", "g_take", "dom_", "g_valid", "g_cap", "g_dst", "g_ack", "take_", "give_",
                     "gt_", "mt2", "mt3", "w_")):
        return "caps"
    if b.startswith(("u_bus", "ext_t3", "u_t2", "g_t3_int", "m_", "t_", "u_dev.disk")):
        return "mem"
    return "dev"


def trusted(name, ctype):
    """Whether a cell's own name places it: not for nextpnr's cells, and not
    for logic many hops from a signal outside the core (such chains run
    from the bus or the domain table back into the core's datapath)."""
    if name.startswith("$"):
        return False
    if name.startswith("all_halted") and ctype not in EXACT:
        return False                  # a top-level output: every core's state leads there
    return ctype in EXACT or name.startswith("g_core[") or hops(name) <= 6


def assign(top, max_fanout=64):
    """{cell name: GROUPS index} for a Yosys or nextpnr JSON module."""
    cells = top["cells"]
    names = list(cells)
    idx = {n: i for i, n in enumerate(names)}
    lab = [-1] * len(names)
    net_cells = {}
    for i, n in enumerate(names):
        c = cells[n]
        for bits in c.get("connections", {}).values():
            for b in bits:
                if isinstance(b, int):
                    net_cells.setdefault(b, []).append(i)
        if trusted(n, c["type"]):
            lab[i] = GROUP_INDEX[group(n, c["type"])]
    adj = [[] for _ in names]
    for b, cs in net_cells.items():
        if len(cs) > max_fanout:
            continue
        for i in cs:
            adj[i].append(b)
    q = deque(i for i in range(len(names)) if lab[i] >= 0)
    while q:
        i = q.popleft()
        for b in adj[i]:
            cs = net_cells[b]
            for j in cs:
                if lab[j] < 0:
                    lab[j] = lab[i]
                    q.append(j)
    # anything unreachable: by its own name
    for i, n in enumerate(names):
        if lab[i] < 0:
            lab[i] = GROUP_INDEX[group(n, cells[n]["type"])]
    return {n: lab[i] for i, n in enumerate(names)}
