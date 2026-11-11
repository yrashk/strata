# fpga/results: the last synthesis runs, kept

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

The `.gz` files are in Git LFS (`.gitattributes`): `git lfs pull` fetches
them after a clone. The ECP5 netlist is 158 MB uncompressed (3.7 MB as
kept); `gunzip -k` gives back what nextpnr reads.

All four runs are of the RTL after the core-size work (plan (a), the
commits after 0a4bd8a: narrow capability and overlay fields, fewer ports,
block-RAM save table, LUT-RAM registers and inboxes, multi-cycle multiply
and ltag entry address), with Yosys 0.70 and sv2v from Homebrew on an arm64
Mac. The numbers, and those of the intermediate steps, are in
`fpga/README.md`.

| Run | Result |
|---|---|
| `xc7-1` | 30,530 LUTs, 6,871 FF, 88 RAMB36 (+4 RAMB18), 4 DSP48E1, 173 LUT-RAM cells (was 50,606 LUTs, 12,638 FF, 30 DSP48E1) |
| `xc7-2` | 58,066 LUTs, 11,713 FF, 120 RAMB36 (+7 RAMB18), 8 DSP48E1 (was 94,130 LUTs) |
| `xc7-6` | 172,984 LUTs, 31,104 FF, 248 RAMB36 (+19 RAMB18), 24 DSP48E1 (was 290,431 LUTs, 73,775 FF) |
| `ecp5-1` | 42,608 LUT4 sites (36,408 LUT4 + 3,100 carry cells), 6,831 FF, 180 DP16KD, 4 MULT18X18D (was 80,999 LUT4 sites) |

After a change to the RTL, run `fpga/synth.sh` again and replace the
directory of each configuration it ran.
