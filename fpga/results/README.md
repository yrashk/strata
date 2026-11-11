# fpga/results: the last synthesis runs, kept

`fpga/synth.sh` takes from about 12 minutes (one core) to about an hour (six
cores), so the results of the last runs are kept here rather than only in
`fpga/build/` (gitignored). Each directory is one `fpga/synth.sh FAMILY N`:

| File | What |
|---|---|
| `summary.txt` | what the script printed: the totals, latches, memories left in flip-flops |
| `stat.txt` | Yosys's cell counts |
| `synth.ys` | the Yosys script that ran |
| `yosys.log.gz` | the whole Yosys log, compressed |
| `strata.json.gz` | the netlist (Yosys JSON), compressed: `ecp5-1` and `xc7-1` now; `fpga/synth.sh` writes one for 7-series too |

The `.gz` files are in Git LFS (`.gitattributes`): `git lfs pull` fetches
them after a clone. The ECP5 netlist is 158 MB uncompressed (3.7 MB as
kept); `gunzip -k` gives back what nextpnr reads.

`xc7-2`, `xc7-6` and `ecp5-1` are of commit 0e51b8f (2026-11-10: with the
pointer device, the console input release and the network device); `xc7-1`
is of the RTL with revocation by address (the granule table instead of the
15 revocation domains; it was 48,240 LUTs, 12,681 FF and 172 LUT-RAM cells
at 0e51b8f), and has the 7-series netlist. All with Yosys 0.70 and sv2v from
Homebrew on an arm64 Mac. The numbers are in `fpga/README.md`.

| Run | Result |
|---|---|
| `xc7-1` | 47,059 LUTs, 12,450 FF, 88 RAMB36 (+1 RAMB18), 30 DSP48E1, 214 LUT-RAM cells |
| `xc7-2` | 94,130 LUTs, 23,636 FF, 120 RAMB36, 60 DSP48E1 |
| `xc7-6` | 290,431 LUTs, 73,775 FF, 248 RAMB36, 180 DSP48E1 |
| `ecp5-1` | 80,999 LUT4 sites (61,949 LUT4 + 9,525 carry cells), 12,866 FF, 181 DP16KD, 30 MULT18X18D |

After a change to the RTL, run `fpga/synth.sh` again and replace the
directory of each configuration it ran.
