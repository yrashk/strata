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

The netlists are not kept: they are large (the ECP5 JSON is 158 MB) and
come back with `fpga/synth.sh`.

All four runs are of commit 0e51b8f (2026-11-10: with the pointer device,
the console input release and the network device), with Yosys 0.70 and
sv2v from Homebrew on an arm64 Mac. The numbers are in `fpga/README.md`.

| Run | Result |
|---|---|
| `xc7-1` | 48,240 LUTs, 12,681 FF, 88 RAMB36, 30 DSP48E1 |
| `xc7-2` | 94,130 LUTs, 23,636 FF, 120 RAMB36, 60 DSP48E1 |
| `xc7-6` | 290,431 LUTs, 73,775 FF, 248 RAMB36, 180 DSP48E1 |
| `ecp5-1` | 80,999 LUT4 sites (61,949 LUT4 + 9,525 carry cells), 12,866 FF, 181 DP16KD, 30 MULT18X18D |

After a change to the RTL, run `fpga/synth.sh` again and replace the
directory of each configuration it ran.
