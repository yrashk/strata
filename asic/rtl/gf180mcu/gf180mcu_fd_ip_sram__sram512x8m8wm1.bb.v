// Black box of the GF180MCU 512 x 8 SRAM macro for synthesis (the power
// pins are connected by the PDN step from the LEF).
(* blackbox *)
module gf180mcu_fd_ip_sram__sram512x8m8wm1 (
  input        CLK,
  input        CEN,
  input        GWEN,
  input  [7:0] WEN,
  input  [8:0] A,
  input  [7:0] D,
  output [7:0] Q
);
endmodule
