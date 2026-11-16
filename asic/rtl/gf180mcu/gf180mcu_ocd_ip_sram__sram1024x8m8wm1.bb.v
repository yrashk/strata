// Black box of the 1024 x 8 SRAM macro of gf180mcu_ocd_ip_sram (the 3.3 V
// rework of the PDK's macros: https://github.com/RTimothyEdwards/gf180mcu_ocd_ip_sram)
// for synthesis; the pins are those of its LEF.
(* blackbox *)
module gf180mcu_ocd_ip_sram__sram1024x8m8wm1 (
  input        CLK,
  input        CEN,
  input        GWEN,
  input  [7:0] WEN,
  input  [9:0] A,
  input  [7:0] D,
  output [7:0] Q
);
endmodule
