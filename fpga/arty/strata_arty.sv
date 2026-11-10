// Strata on the Digilent Arty A7-100T.
//
// Two Strata cores with their Local Stores in block RAM, the cluster store
// (64 KiB) and a 128 KiB disk in block RAM, the console on the USB UART, and
// system memory in the board's 256 MB DDR3 through a LiteDRAM controller
// generated from fpga/arty/litedram.yml (see fpga/README.md). The boot ROM is
// the I-LS/D-LS initial contents; the disk holds StrataOS.
//
// Status: synthesizable RTL; not yet run on hardware. The LiteDRAM port names
// follow litedram_gen's standalone core for a "native" user port; check them
// against the generated litedram_core.v.

module strata_arty (
  input  logic        CLK100MHZ,
  input  logic        ck_rst,          // active low
  output logic        uart_rxd_out,    // FPGA -> USB UART
  input  logic        uart_txd_in,     // USB UART -> FPGA
  output logic [3:0]  led,

  // DDR3 (pins as in LiteX's digilent_arty platform)
  output logic [13:0] ddram_a,
  output logic [2:0]  ddram_ba,
  output logic        ddram_ras_n,
  output logic        ddram_cas_n,
  output logic        ddram_we_n,
  output logic        ddram_cs_n,
  output logic [1:0]  ddram_dm,
  inout  wire  [15:0] ddram_dq,
  inout  wire  [1:0]  ddram_dqs_p,
  inout  wire  [1:0]  ddram_dqs_n,
  output logic        ddram_clk_p,
  output logic        ddram_clk_n,
  output logic        ddram_cke,
  output logic        ddram_odt,
  output logic        ddram_reset_n
);
  localparam int DW = 128;
  localparam int AW = 24;              // 256 MB / 16 bytes

  logic clk, user_rst, init_done, init_error;

  // ---- LiteDRAM native port
  logic          cmd_valid, cmd_ready, cmd_we;
  logic [AW-1:0] cmd_addr;
  logic          wdata_valid, wdata_ready;
  logic [DW-1:0] wdata_data;
  logic [DW/8-1:0] wdata_we;
  logic          rdata_valid, rdata_ready;
  logic [DW-1:0] rdata_data;

  litedram_core u_dram (
    .clk(CLK100MHZ), .rst(!ck_rst),
    .ddram_a, .ddram_ba, .ddram_ras_n, .ddram_cas_n, .ddram_we_n, .ddram_cs_n, .ddram_dm,
    .ddram_dq, .ddram_dqs_p, .ddram_dqs_n, .ddram_clk_p, .ddram_clk_n, .ddram_cke,
    .ddram_odt, .ddram_reset_n,
    .init_done, .init_error, .user_clk(clk), .user_rst,
    .user_port_native_0_cmd_valid(cmd_valid), .user_port_native_0_cmd_ready(cmd_ready),
    .user_port_native_0_cmd_we(cmd_we), .user_port_native_0_cmd_addr(cmd_addr),
    .user_port_native_0_wdata_valid(wdata_valid), .user_port_native_0_wdata_ready(wdata_ready),
    .user_port_native_0_wdata_we(wdata_we), .user_port_native_0_wdata_data(wdata_data),
    .user_port_native_0_rdata_valid(rdata_valid), .user_port_native_0_rdata_ready(rdata_ready),
    .user_port_native_0_rdata_data(rdata_data)
  );

  logic rst;
  assign rst = user_rst || !init_done;

  // ---- the Strata system, system memory outside
  logic        t3_start, t3_we, t3_amo, t3_wvalid, t3_wready, t3_rvalid, t3_done, halted;
  logic [2:0]  t3_op;
  logic [63:0] t3_addr, t3_cmp, t3_wdata, t3_rdata;
  logic [23:0] t3_beats;

  strata_top #(
    .NCORES(2), .T3_EXT(1), .T2_W(8192), .DISK_WORDS(16384),
    .ILS_INIT("bootrom_ils.hex"), .DLS_INIT("bootrom_dls.hex"),
    .DISK_INIT("disk.hex"), .PLAT_INIT("plat.hex"),
    .UART_DIV(100_000_000 / 115_200)
  ) u_sys (
    .clk, .rst, .all_halted(halted), .uart_txd(uart_rxd_out), .uart_rxd(uart_txd_in),
    .ext_t3_start(t3_start), .ext_t3_we(t3_we), .ext_t3_amo(t3_amo), .ext_t3_amo_op(t3_op),
    .ext_t3_addr(t3_addr), .ext_t3_beats(t3_beats), .ext_t3_cmp(t3_cmp),
    .ext_t3_wvalid(t3_wvalid), .ext_t3_wdata(t3_wdata), .ext_t3_wready(t3_wready),
    .ext_t3_rvalid(t3_rvalid), .ext_t3_rdata(t3_rdata), .ext_t3_done(t3_done)
  );

  strata_t3_litedram #(.DW(DW), .AW(AW)) u_t3 (
    .clk, .rst,
    .start(t3_start), .we(t3_we), .amo(t3_amo), .amo_op(t3_op), .addr(t3_addr),
    .beats(t3_beats), .cmp(t3_cmp), .wvalid(t3_wvalid), .wdata(t3_wdata), .wready(t3_wready),
    .rvalid(t3_rvalid), .rdata(t3_rdata), .done(t3_done),
    .cmd_valid, .cmd_ready, .cmd_we, .cmd_addr, .wdata_valid, .wdata_ready, .wdata_data,
    .wdata_we, .rdata_valid, .rdata_ready, .rdata_data
  );

  assign led = {halted, init_error, init_done, !rst};
endmodule
