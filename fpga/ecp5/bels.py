# Writes the positions of the ECP5's hard blocks (block RAM, multipliers,
# I/O, PLLs) for fpga/render.py: nextpnr's own chip database, through its
# Python interface.
#
#   nextpnr-ecp5 --85k --package CABGA381 --run fpga/ecp5/bels.py
#
# writes fpga/ecp5/lfe5u-85f-bels.json: the hard blocks by type, and under
# "PLC" the logic tiles (those with slices) as "X/Y".
import json
keep = ("DP16KD", "MULT18X18D", "ALU54B", "TRELLIS_IO", "EHXPLLL", "DCCA", "DCUA")
out = {}
plc = set()
for b in ctx.getBels():
    t = ctx.getBelType(b)
    if t == "TRELLIS_COMB":
        plc.add("/".join(str(b).split("/")[:2]))
    if t in keep:
        out.setdefault(t, []).append(str(b))
out["PLC"] = list(plc)
for v in out.values():
    v.sort()
path = "fpga/ecp5/lfe5u-85f-bels.json"   # run from the repository root
json.dump(out, open(path, "w"), indent=0)
print(path, {k: len(v) for k, v in out.items()})
