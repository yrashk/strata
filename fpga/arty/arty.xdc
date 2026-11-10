## Strata on the Digilent Arty A7-100T: clock, reset, UART and LEDs.
## The DDR3 pins are the ones in LiteX's digilent_arty platform
## (litex-boards); copy them from there (or from LiteDRAM's generated
## constraints) rather than retyping them here.
set_property -dict {PACKAGE_PIN E3  IOSTANDARD LVCMOS33} [get_ports CLK100MHZ]
create_clock -period 10.000 -name sys_clk [get_ports CLK100MHZ]
set_property -dict {PACKAGE_PIN C2  IOSTANDARD LVCMOS33} [get_ports ck_rst]
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS33} [get_ports uart_rxd_out]
set_property -dict {PACKAGE_PIN A9  IOSTANDARD LVCMOS33} [get_ports uart_txd_in]
set_property -dict {PACKAGE_PIN H5  IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN J5  IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN T9  IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
