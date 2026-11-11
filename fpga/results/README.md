# fpga/results: the last synthesis and place-and-route runs, kept

`fpga/synth.sh` takes from about 12 minutes (one core) to about an hour (six
cores), and `fpga/pnr.sh` (nextpnr) from minutes to hours, so the results of
the last runs are kept here rather than only in `fpga/build/` (gitignored).
Each directory is one `fpga/synth.sh FAMILY N` and what was done with it:

| File | What |
|---|---|
| `summary.txt` | what the script printed: the totals, latches, memories left in flip-flops |
| `stat.txt` | Yosys's cell counts |
| `synth.ys` | the Yosys script that ran |
| `yosys.log.gz` | the whole Yosys log, compressed |
| `strata.json.gz` | the netlist (Yosys JSON), compressed: `ecp5-1` now; `fpga/synth.sh` writes one for 7-series too from the next run on |
| `nextpnr-*.log`, `report-*.json` | place and route with nextpnr: the log, and nextpnr's utilisation and timing report |
| `placed-*.json.gz` | the placed design nextpnr wrote (every cell with its site), what `fpga/render.py` draws |
| `die-*.png`, `die-*-1600.webp` | `fpga/render.py`'s picture of it, full size (5200×3900) and for the web |

The `.gz` and `.png` files are in Git LFS (`.gitattributes`): `git lfs pull`
fetches them after a clone. The ECP5 netlist is 158 MB uncompressed (3.7 MB
as kept); `gunzip -k` gives back what nextpnr reads.

All synthesis runs are of commit 0e51b8f (2026-11-10: with the pointer
device, the console input release and the network device; `rtl/` has not
changed since), with Yosys 0.70 and sv2v from Homebrew on an arm64 Mac. The
numbers are in `fpga/README.md`.

| Run | Result |
|---|---|
| `xc7-1` | 48,240 LUTs, 12,681 FF, 88 RAMB36, 30 DSP48E1 |
| `xc7-2` | 94,130 LUTs, 23,636 FF, 120 RAMB36, 60 DSP48E1 |
| `xc7-6` | 290,431 LUTs, 73,775 FF, 248 RAMB36, 180 DSP48E1 |
| `ecp5-1` | 80,999 LUT4 sites (61,949 LUT4 + 9,525 carry cells), 12,866 FF, 181 DP16KD, 30 MULT18X18D |
| `ecp5-1-xmap12` | `NXMAP=12 fpga/synth.sh ecp5 1`, the overlay map cut to 12 entries (`strata_pkg.diff`): 74,296 LUT4 sites (58,114 + 8,091 carry cells), 12,336 FF |
| `ecp5-1-xmap4` | `NXMAP=4`, 4 entries: 63,429 LUT4 sites (52,827 + 5,301 carry cells), 11,284 FF |

Place and route (`fpga/README.md`, "Place and route"), nextpnr-ecp5 0.11.1
from the OSS CAD Suite 2026-11-10, LFE5U-85F CABGA381:

| Run | Result |
|---|---|
| `ecp5-1` | `nextpnr-heap.log`: the default placer cannot legalise 99.6% of the logic cells; `nextpnr-sa.log`: the SA placer stalls (stopped after 10 minutes); `nextpnr-static.log`: the static placer places it, estimated 9.8 MHz; `placed-static.json.gz`, `die-placed.png` |
| `ecp5-1-xmap12` | static placer, router1, 10 MHz target (`board.lpf`): **routed**, 14.46 MHz; `nextpnr.log.gz`, `report.json.gz`, `timing.txt` (the critical path, names shortened), `routed.json.gz`, `die.png`. `nextpnr-placed.log`: the earlier HeAP placement, which did not route |
| `ecp5-1-xmap4` | the same flow: **routed**, 15.51 MHz; `nextpnr.log.gz`, `timing.txt` |

After a change to the RTL, run `fpga/synth.sh` again and replace the
directory of each configuration it ran.
