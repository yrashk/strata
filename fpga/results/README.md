# fpga/results: the last synthesis and place-and-route runs, kept

`fpga/synth.sh` takes from about 2 minutes (one core) to about 11 minutes (six
cores), so the results of the last runs are kept here rather than only in
`fpga/build/` (gitignored). Each directory is one `fpga/synth.sh FAMILY N`:

| File | What |
|---|---|
| `summary.txt` | what the script printed: the totals, latches, memories left in flip-flops |
| `stat.txt` | Yosys's cell counts |
| `synth.ys` | the Yosys script that ran |
| `yosys.log.gz` | the whole Yosys log, compressed |
| `strata.json.gz` | the netlist (Yosys JSON), compressed: `ecp5-1` and `xc7-1` now; `fpga/synth.sh` writes one for 7-series too |
| `nextpnr-*.log`, `report-*.json` | place and route with nextpnr: the log, and nextpnr's utilisation and timing report |
| `placed-*.json.gz` | the placed design nextpnr wrote (every cell with its site), what `fpga/render.py` draws |
| `die-*.png`, `die-*-1600.webp` | `fpga/render.py`'s picture of it, full size (5200×3900) and for the web |

The `.gz` and `.png` files are in Git LFS (`.gitattributes`): `git lfs pull`
fetches them after a clone. The ECP5 netlist is 158 MB uncompressed (3.7 MB
as kept); `gunzip -k` gives back what nextpnr reads.

All the runs are of the RTL after the core-size work (plans (a) and (b),
the commits after 0a4bd8a: narrow capability and overlay fields, fewer
ports, block-RAM save table, LUT-RAM registers and inboxes, multi-cycle
multiply and ltag entry address, slot-aligned xmap, NXMAP a platform
parameter), with Yosys 0.70 and sv2v from Homebrew on an arm64 Mac. The
numbers, and those of the intermediate steps, are in `fpga/README.md`.
(The `xc7-2` run committed with the end of plan (a) was in fact of this
RTL; plan (a)'s 2-core figure in `fpga/README.md` is from a run of that
commit's RTL.)

| Run | Result |
|---|---|
| `xc7-1` | 30,011 LUTs, 6,869 FF, 88 RAMB36 (+4 RAMB18), 4 DSP48E1, 173 LUT-RAM cells (was 50,606 LUTs, 12,638 FF, 30 DSP48E1) |
| `xc7-1-x8` | 29,078 LUTs, 6,495 FF (8 overlay map entries: `fpga/synth.sh xc7 1 8`) |
| `xc7-2` | 58,066 LUTs, 11,713 FF, 120 RAMB36 (+7 RAMB18), 8 DSP48E1 (was 94,130 LUTs) |
| `xc7-6` | 168,694 LUTs, 31,102 FF, 248 RAMB36 (+19 RAMB18), 24 DSP48E1 (was 290,431 LUTs, 73,775 FF) |
| `ecp5-1` | 41,219 LUT4 sites (35,473 LUT4 + 2,873 carry cells), 6,831 FF, 180 DP16KD, 4 MULT18X18D (was 80,999 LUT4 sites) |

After a change to the RTL, run `fpga/synth.sh` again and replace the
directory of each configuration it ran.
