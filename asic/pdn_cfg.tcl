# LibreLane's default PDN, plus a Metal3-Metal4 connection for the macro
# grid: the GF180MCU SRAM macros have their VDD / VSS pins on Metal3 (they
# block Metal1-3 only), so the core grid's Metal4 straps that cross a macro
# drop vias onto them.
source $::env(SCRIPTS_DIR)/openroad/common/pdn_cfg.tcl

add_pdn_connect \
    -grid macro \
    -layers "Metal3 $::env(PDN_VERTICAL_LAYER)"
