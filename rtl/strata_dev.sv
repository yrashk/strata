// Strata: device space (far tier T4).
//
//   0x0000  console         port 0: output stream; port 8: input stream
//   0x1000  platform table  read-only
//   0x2000  block device 0  +0x000 identify ROM, +0x100 submission stream
//                           (32-byte commands), +0x200 completion stream
//                           (16-byte entries)
//   0x3000  timer           NOW, FREQ, DEADLINE (read/write), WAIT
//   0x4000  framebuffer     PRESENT (write), VSYNC
//           controller
//   0x4100  pointer         EVENT (a waiting read; a write completes the
//                           waiting ones with 0), STATE
//   0x4200  network         TX (write: one transfer = one IPv4 packet), RX
//           interface       (read: waits for a packet), STATUS, CANCEL
//
// Device transfers move single bytes. A stream port ignores the byte index; a
// ROM or register reads byte `addr + i`. A register is latched when its byte
// 0 is read and a written value takes effect when its byte 7 is written.
// Reads that have nothing to give yet (console input with no byte, the break
// port, WAIT before the deadline, VSYNC before the next refresh, EVENT with
// no event queued) answer
// `retry` before any byte, so the bus is not held while waiting; the Transfer
// Unit asks again later.
//
// Timer: NOW counts microseconds, from the clock (CLK_MHZ cycles per tick)
// or, in simulation, from the host (sim_time_us, unless it returns -1).
// EPOCH and ZONE are the host's wall clock at NOW = 0 and its time zone
// in simulation (sim_epoch_us, sim_zone_s, read at reset); 0 otherwise.
// VSYNC completes once the refresh counter (one every FRAME_TICKS ticks)
// has moved past the value it had at the requesting core's first attempt;
// the bus tells us which master asks (`master`: core i's Transfer Unit is
// master 2i). PRESENT asks the simulator harness to show the framebuffer; on
// an FPGA it does nothing yet.
//
// Network interface: in simulation the harness keeps the packets
// (common/net.h, reached through the sim_net_* DPI calls): the bytes of a
// TX transfer go to it one by one, and the last one sends the packet. An RX
// read is retried until the harness has a packet; the first try that finds
// one makes it this core's current packet, and the read's bytes come from
// it (zeros past its end). A CANCEL write marks every RX read waiting at
// that moment (per core, like the break port's release): its next try
// completes with zeros and takes no packet. On an FPGA there is no PHY yet:
// TX bytes are dropped, RX waits until a CANCEL, STATUS reads 0 (link down).
// Pointer: in simulation the events and the state come from the harness
// (common/display.h: the window's mouse or a -P script); on an FPGA there is
// no pointer yet: STATE reads 0 (not over the display) and EVENT waits until
// a write releases it.
//
// Block device protocol (see common/platform.h): a command arrives on the
// submission stream; the buffer capability arrives through this node's
// capability inbox (node number NCORES). The engine moves the blocks between
// its storage and the far memory the capability names using its own far-bus
// port, posts a completion entry, and gives the capability back to the core
// that lent it. Having the capability is the only way it can touch that
// memory. A command is paired only with a buffer from the core that
// submitted it (each queued command and each held buffer remembers its
// core): the oldest command waits for its submitter's oldest buffer, and a
// buffer whose lender has no command queued is an orphan, given straight
// back (emu.c blk_run). So one core cannot slip a buffer under another's
// command.
//
// Per-core state (a core's waiting break / input / VSYNC / EVENT / RX read)
// is forgotten when that core takes a core-control reset (core_clr).

module strata_dev
  import strata_pkg::*;
#(
  parameter int    NCORES      = 4,
  parameter int    DISK_WORDS  = 2097152,    // 16 MiB
  parameter string DISK_INIT   = "",
  parameter string PLAT_INIT   = "",
  parameter int    UART_DIV    = 868,
  parameter int    CLK_MHZ     = 100         // clock cycles per timer tick
)(
  input  logic        clk,
  input  logic        rst,

  // far-bus target (device space)
  input  logic        start,
  input  logic [7:0]  master,                // the bus master of the transfer that starts
  input  logic        we,
  input  logic [63:0] addr,
  input  logic [23:0] beats,
  input  logic        wvalid,
  input  logic [63:0] wdata,
  output logic        wready,
  output logic        rvalid,
  output logic [63:0] rdata,
  output logic        done,
  output logic        retry,

  // far-bus master (block device DMA)
  output logic        m_req,
  output logic        m_we,
  output logic [63:0] m_addr,
  output logic        m_wvalid,
  output logic [63:0] m_wdata,
  input  logic        m_gnt,
  input  logic        m_wready,
  input  logic        m_rvalid,
  input  logic [63:0] m_rdata,
  input  logic        m_done,

  // capability inbox of the block device, and its gifts back to cores
  input  logic        in_push,
  input  cap_t        in_cap,
  input  logic [7:0]  in_from,               // the core that gives it
  output logic        in_ready,
  input  logic [NCORES-1:0] core_clr,        // these cores are being reset: forget their waiting reads
  output logic        give_valid,
  output logic [7:0]  give_dst,
  output cap_t        give_cap,
  input  logic        give_ack,

  // console on FPGA
  output logic        uart_txd,
  input  logic        uart_rxd
);
  localparam logic [63:0] BLK_SQ = DEV_BLK0 + 64'h100;
  localparam logic [63:0] BLK_CQ = DEV_BLK0 + 64'h200;
  localparam int CMDQ = 4;
  localparam int CQD  = 4;
  localparam int DAW  = $clog2(DISK_WORDS);

  // ================================================================ ROMs
  logic [7:0] plat [PLAT_LEN];
`ifdef SIMULATION
  initial for (int i = 0; i < PLAT_LEN; i++) plat[i] = plat_byte(i);
`else
  initial if (PLAT_INIT != "") $readmemh(PLAT_INIT, plat);
`endif

  function automatic logic [7:0] ident(input int i);
    logic [63:0] blocks;
    blocks = 64'(DISK_WORDS / 64);
    case (i)
      0: return "S";  1: return "T";  2: return "B";  3: return "D";
      4: return 8'd1;                     // version
      6: return 8'd9;                     // log2 block size
      16: return 8'd0; 17: return 8'd1;   // 256 blocks per command
      20: return 8'(CMDQ);                // queue depth
      default: return (i >= 8 && i < 16) ? blocks[8*(i-8) +: 8] : 8'd0;
    endcase
  endfunction

  // ================================================================ console
  logic       con_tx_valid, con_tx_ready, con_rx_valid, con_rx_pop;
  logic [7:0] con_tx_byte, con_rx_byte;
`ifdef SIMULATION
  // the simulator harness does the console: output always ready, input
  // fetched from the host when a read starts (it may block the host)
  logic       sim_have;
  logic [7:0] sim_ch;
  assign con_tx_ready = 1;
  assign con_rx_valid = sim_have;
  assign con_rx_byte  = sim_ch;
  assign uart_txd     = 1;
`else
  strata_uart #(.CLKS_PER_BIT(UART_DIV)) u_uart (
    .clk, .rst,
    .tx_valid(con_tx_valid), .tx_byte(con_tx_byte), .tx_ready(con_tx_ready), .txd(uart_txd),
    .rxd(uart_rxd), .rx_valid(con_rx_valid), .rx_byte(con_rx_byte), .rx_pop(con_rx_pop)
  );
`endif

  // ================================================================ block device state
  logic [63:0] disk [DISK_WORDS];
`ifdef SIMULATION
  initial for (int i = 0; i < DISK_WORDS; i++) disk[i] = disk_word(i);
`else
  initial if (DISK_INIT != "") $readmemh(DISK_INIT, disk);
`endif

  logic [7:0]  sq_buf [32];
  logic [4:0]  sq_fill;
  logic [255:0] cmdq [CMDQ];
  logic [7:0]  cmdf [CMDQ];   // the core that submitted each command
  logic [2:0]  cmd_cnt;
  logic [1:0]  cmd_head;
  cap_t        capq [CMDQ];
  logic [7:0]  capf [CMDQ];   // the core that lent each capability
  logic [2:0]  cap_cnt;
  logic [1:0]  cap_head;
  logic [127:0] cq [CQD];
  logic [3:0]  cq_cnt;
  logic [1:0]  cq_head;
  logic [3:0]  cq_byte;

  assign in_ready = cap_cnt != 3'(CMDQ);

  // ================================================================ target side
  typedef enum logic [1:0] {T_IDLE, T_RUN, T_DONE} tstate_t;
  tstate_t     ts;
  logic [63:0] t_port;
  logic [23:0] t_idx, t_n;
  logic        t_we;
  logic [7:0]  t_core;      // the core whose Transfer Unit asks (master / 2)

  logic [63:0] ra;          // byte address of the current read beat
  assign ra = t_port + 64'(t_idx);

  // ================================================================ timer
  logic [63:0] now, vnow;           // ticks since reset (vnow: counted from the clock)
  logic [7:0]  presc;               // clock cycles into the current tick
  logic [63:0] deadline, dl_wbuf;   // DEADLINE, and the bytes of a write in progress
  logic [63:0] lat_now, lat_dl, lat_wait, lat_vs;  // values latched at byte 0
  logic [63:0] frame, next_frame;   // refreshes so far; the tick of the next one
  logic [NCORES-1:0]       vs_armed; // a core's VSYNC read has been tried
  logic [NCORES-1:0][63:0] vs_from;  // ... and the refresh count it waits to pass
  logic        is_wait, is_vsync, wait_ok, vsync_ok, tmr_hit;
  logic [63:0] tmr_val;
  logic [63:0] epoch, zone;         // EPOCH and ZONE: from the host in simulation; 0 (not known) otherwise

  always_ff @(posedge clk) begin
    if (rst) begin
      vnow  <= '0;
      presc <= '0;
    end else if (presc == 8'(CLK_MHZ - 1)) begin
      presc <= '0;
      vnow  <= vnow + 1;
    end else presc <= presc + 1;
  end
`ifdef SIMULATION
  always_ff @(posedge clk) begin
    longint t;
    t = sim_time_us();
    if (rst) now <= '0;
    else now <= t < 0 ? vnow : t;
  end
`else
  assign now = vnow;
`endif
`ifdef SIMULATION
  always_ff @(posedge clk) begin
    if (rst) begin
      epoch <= sim_epoch_us();
      zone  <= sim_zone_s();
    end
  end
`else
  assign epoch = '0;
  assign zone  = '0;
`endif

  always_ff @(posedge clk) begin
    if (rst) begin
      frame      <= '0;
      next_frame <= 64'(FRAME_TICKS);
    end else if (now >= next_frame) begin
      frame      <= frame + 1;
      next_frame <= next_frame + 64'(FRAME_TICKS);
    end
  end

  logic        is_con_in, is_cq, is_brk, rom_hit;
  logic        rx_brk, rx_ok;   // the received byte is a Ctrl-C / is ordinary input
  logic [3:0]  brk_cnt;        // Ctrl-C presses not yet read from the break port
  // A write to the release port completes every break read waiting at that
  // moment with 0; reads that start waiting later wait for the next Ctrl-C or
  // release. One break read per core is in flight at a time, so the state is
  // per core: brk_wait[c] = core c's break read has been tried and waits,
  // brk_rel[c] = a release came while it waited (its next try returns 0).
  logic [NCORES-1:0] brk_wait, brk_rel;
  logic        brk_rel_me;     // the current transfer's core has a release waiting
  // The release also completes console input reads waiting for their first
  // byte (in_wait / in_rel, the same way): their bytes all read 0.
  logic [NCORES-1:0] in_wait, in_rel;
  logic        in_rel_me;
  logic [7:0]  rom_b;
  // pointer: ptr_have/ptr_ev = an event fetched from the host, not yet read;
  // ptr_wait/ptr_rel per core, as for the break port (a write to EVENT
  // completes every EVENT read waiting at that moment with 0)
  logic        is_ptr_ev, ptr_st_hit, ptr_have, ptr_rel_me;
  logic [63:0] ptr_ev, lat_ptr, ptr_st, lat_pst;
  logic [NCORES-1:0] ptr_wait, ptr_rel;
  assign is_ptr_ev  = t_port == DEV_PTR_EVENT;
  assign ptr_st_hit = ra >= DEV_PTR_STATE && ra < DEV_PTR_STATE + 64'd8;
  always_comb begin
    ptr_rel_me = 0;
    for (int c = 0; c < NCORES; c++)
      if (int'(t_core) == c && ptr_rel[c]) ptr_rel_me = 1;
  end
  assign is_con_in = t_port == DEV_CON_IN;
  assign is_cq     = t_port == BLK_CQ;
  assign is_brk    = t_port == DEV_CON_BRK;
  assign is_wait   = t_port == DEV_TMR_WAIT;
  assign is_vsync  = t_port == DEV_FB_VSYNC;
  assign wait_ok   = now >= deadline;
  always_comb begin
    brk_rel_me = 0;
    in_rel_me  = 0;
    for (int c = 0; c < NCORES; c++) begin
      if (int'(t_core) == c && brk_rel[c]) brk_rel_me = 1;
      if (int'(t_core) == c && in_rel[c])  in_rel_me  = 1;
    end
  end
  always_comb begin
    vsync_ok = 0;
    for (int c = 0; c < NCORES; c++)
      if (int'(t_core) == c && vs_armed[c] && frame > vs_from[c]) vsync_ok = 1;
  end
  // timer registers other than WAIT: byte 0 reads the live value, the rest the latch
  always_comb begin
    tmr_hit = ra >= DEV_TIMER && ra < DEV_TIMER + 64'h30;
    case (ra[5:3])
      3'd0:    tmr_val = ra[2:0] == 0 ? now : lat_now;
      3'd1:    tmr_val = 64'(TMR_HZ);
      3'd2:    tmr_val = ra[2:0] == 0 ? deadline : lat_dl;
      3'd4:    tmr_val = epoch;
      3'd5:    tmr_val = zone;
      default: tmr_val = '0;                         // WAIT other than at the start of a transfer
    endcase
  end
`ifdef SIMULATION
  assign rx_brk    = 0;                               // the host reports Ctrl-C via sim_break
`else
  assign rx_brk    = con_rx_valid && con_rx_byte == 8'd3;
`endif
  assign rx_ok     = con_rx_valid && !rx_brk;
  always_comb begin
    rom_hit = 1;
    rom_b   = 8'd0;
    if (ra >= DEV_PLAT && ra < DEV_PLAT + 64'(PLAT_LEN)) rom_b = plat[9'(ra - DEV_PLAT)];
    else if (ra >= DEV_BLK0 && ra < DEV_BLK0 + 64'(IDENT_LEN)) rom_b = ident(int'(ra - DEV_BLK0));
    else rom_hit = 0;
  end

  // ================================================================ network
  logic              is_net_rx, net_st_hit;
  logic [NCORES-1:0] net_wait, net_rel;  // core c's RX read was tried and waits / a CANCEL came meanwhile
  logic              net_rel_me;         // the current transfer's core has a CANCEL waiting
  logic              net_open;           // a packet is current (taken from the harness) ...
  logic [7:0]        net_core;           // ... for this core
  logic              net_zero;           // the current RX transfer was cancelled: it reads zeros
  logic [63:0]       net_st, lat_net;    // STATUS (refreshed every cycle), latched at byte 0
  logic [7:0]        net_b;              // byte t_idx of the current packet
  assign is_net_rx  = t_port == DEV_NET_RX;
  assign net_st_hit = ra >= DEV_NET_STATUS && ra < DEV_NET_STATUS + 64'd8;
  always_comb begin
    net_rel_me = 0;
    for (int c = 0; c < NCORES; c++)
      if (int'(t_core) == c && net_rel[c]) net_rel_me = 1;
  end
`ifdef SIMULATION
  always_comb net_b = sim_net_rx_byte(int'(t_idx));
  always_ff @(posedge clk) net_st <= rst ? '0 : sim_net_status();
`else
  assign net_b  = 8'd0;
  assign net_st = '0;
`endif

  logic cq_pop_byte, sq_push_byte;
  logic [7:0] cq_b;
  assign cq_b = cq_cnt == 0 ? 8'd0 : cq[cq_head][8*cq_byte +: 8];

  always_comb begin
    wready       = 0;
    rvalid       = 0;
    rdata        = '0;
    done         = ts == T_DONE;
    retry        = 0;
    con_tx_valid = 0;
    con_tx_byte  = wdata[7:0];
    con_rx_pop   = 0;
    cq_pop_byte  = 0;
    sq_push_byte = 0;
    if (ts == T_RUN) begin
      if (t_we) begin
        if (t_port == DEV_CONSOLE) begin
          wready       = con_tx_ready;
          con_tx_valid = wvalid;
        end else if (t_port == DEV_CON_REL || t_port == DEV_PTR_EVENT) begin
          wready       = 1;
        end else begin
          wready       = 1;
          sq_push_byte = wvalid && t_port == BLK_SQ;
        end
        done = wvalid && wready && t_idx + 1 == t_n;
      end else begin
        if (is_brk) begin                            // completes only on a release or Ctrl-C
          if (brk_rel_me) begin                      // a release came first
            rvalid = 1;
            rdata  = 64'd0;
          end else if (brk_cnt != 0) begin
            rvalid = 1;
            rdata  = 64'd3;
          end else retry = 1;
        end else if (is_wait) begin                  // completes once NOW >= DEADLINE, returning NOW
          if (t_idx == 0) begin
            if (wait_ok) begin
              rvalid = 1;
              rdata  = {56'b0, now[7:0]};
            end else retry = 1;
          end else begin
            rvalid = 1;
            rdata  = t_idx < 8 ? {56'b0, lat_wait[8*t_idx[2:0] +: 8]} : 64'd0;
          end
        end else if (is_vsync) begin                 // completes at the next refresh, returning its number
          if (t_idx == 0) begin
            if (vsync_ok) begin
              rvalid = 1;
              rdata  = {56'b0, frame[7:0]};
            end else retry = 1;
          end else begin
            rvalid = 1;
            rdata  = t_idx < 8 ? {56'b0, lat_vs[8*t_idx[2:0] +: 8]} : 64'd0;
          end
        end else if (is_net_rx) begin                // completes when a packet is there (or on a CANCEL)
          if (t_idx == 0) begin
            if (net_rel_me) begin
              rvalid = 1;
              rdata  = 64'd0;
            end else if (net_open && net_core == t_core) begin
              rvalid = 1;
              rdata  = {56'b0, net_b};
            end else retry = 1;
          end else begin
            rvalid = 1;
            rdata  = net_zero ? 64'd0 : {56'b0, net_b};
          end
        end else if (net_st_hit) begin
          rvalid = 1;
          rdata  = {56'b0, ra[2:0] == 0 ? net_st[7:0] : lat_net[8*ra[2:0] +: 8]};
        end else if (is_ptr_ev) begin                // completes on an event, or 0 on a release
          if (t_idx == 0) begin
            if (ptr_rel_me) begin
              rvalid = 1;
              rdata  = 64'd0;
            end else if (ptr_have) begin
              rvalid = 1;
              rdata  = {56'b0, ptr_ev[7:0]};
            end else retry = 1;
          end else begin
            rvalid = 1;
            rdata  = t_idx < 8 ? {56'b0, lat_ptr[8*t_idx[2:0] +: 8]} : 64'd0;
          end
        end else if (ptr_st_hit) begin               // byte 0 reads the live state, the rest the latch
          rvalid = 1;
          rdata  = {56'b0, ra[2:0] == 0 ? ptr_st[7:0] : lat_pst[8*ra[2:0] +: 8]};
        end else if (tmr_hit) begin
          rvalid = 1;
          rdata  = {56'b0, tmr_val[8*ra[2:0] +: 8]};
        end else if (is_con_in) begin
          if (in_rel_me) begin                       // released: zeros, no input taken
            rvalid = 1;
            rdata  = 64'd0;
          end else if (!rx_ok && t_idx == 0) retry = 1;
          else if (rx_ok) begin
            rvalid     = 1;
            rdata      = {56'b0, con_rx_byte};
            con_rx_pop = 1;
          end
        end else if (is_cq) begin
          rvalid      = 1;
          rdata       = {56'b0, cq_b};
          cq_pop_byte = cq_cnt != 0;
        end else begin
          rvalid = 1;
          rdata  = {56'b0, rom_hit ? rom_b : 8'd0};
        end
        done = rvalid && t_idx + 1 == t_n;
      end
    end
    if (rx_brk) con_rx_pop = 1;                       // Ctrl-C never reaches the input port
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      brk_cnt  <= '0;
      brk_rel  <= '0;
      brk_wait <= '0;
      in_rel   <= '0;
      in_wait  <= '0;
    end else begin
      // one Ctrl-C is consumed by each break read it completes; a release
      // marks every break read waiting at that moment
      logic take, add;
      take = ts == T_RUN && is_brk && !t_we && done && !brk_rel_me && brk_cnt != 0;
`ifdef SIMULATION
      add  = sim_break() != 0 && brk_cnt != 4'hf;     // the host saw a Ctrl-C
`else
      add  = rx_brk && brk_cnt != 4'hf;
`endif
      brk_cnt <= brk_cnt + 4'(add) - 4'(take);
      for (int c = 0; c < NCORES; c++) begin
        if (ts == T_RUN && is_brk && !t_we && int'(t_core) == c) begin
          brk_wait[c] <= !done;                     // tried: waits, or completes now
          if (done) brk_rel[c] <= 0;
        end
        if (ts == T_RUN && t_we && t_port == DEV_CON_REL && wvalid && brk_wait[c]) brk_rel[c] <= 1;
        if (ts == T_RUN && is_con_in && !t_we && int'(t_core) == c) begin
          if (t_idx == 0 && retry) in_wait[c] <= 1;  // waits for its first byte
          else if (rvalid) in_wait[c] <= 0;          // (bytes flow: no longer waiting)
          if (done) in_rel[c] <= 0;
        end
        if (ts == T_RUN && t_we && t_port == DEV_CON_REL && wvalid && in_wait[c]) in_rel[c] <= 1;
        if (core_clr[c]) begin
          brk_wait[c] <= 0;
          brk_rel[c]  <= 0;
          in_wait[c]  <= 0;
          in_rel[c]   <= 0;
        end
      end
    end
  end

  // network state: the current packet, CANCEL marks, the STATUS latch
  always_ff @(posedge clk) begin
    if (rst) begin
      net_open <= 0;
      net_core <= '0;
      net_zero <= 0;
      net_wait <= '0;
      net_rel  <= '0;
    end else begin
      if (ts == T_RUN && !t_we && net_st_hit && ra[2:0] == 0) lat_net <= net_st;
      if (ts == T_RUN && is_net_rx && !t_we) begin
        if (t_idx == 0 && rvalid) net_zero <= net_rel_me;
        if (rvalid && t_idx + 1 == t_n && !(t_idx == 0 ? net_rel_me : net_zero)) net_open <= 0; // the packet is used up
`ifdef SIMULATION
        if (t_idx == 0 && !net_open && !net_rel_me) begin
          int n;
          n = sim_net_rx_take();                    // the harness's next packet, if any
          if (n >= 0) begin
            net_open <= 1;
            net_core <= t_core;
          end
        end
`endif
      end
      for (int c = 0; c < NCORES; c++) begin
        if (ts == T_RUN && is_net_rx && !t_we && t_idx == 0 && int'(t_core) == c) begin
          net_wait[c] <= retry;                     // tried: waits, or completes now
          if (rvalid) net_rel[c] <= 0;
        end
        if (ts == T_RUN && t_we && t_port == DEV_NET_CANCEL && wvalid && net_wait[c]) net_rel[c] <= 1;
        if (core_clr[c]) begin
          net_wait[c] <= 0;
          net_rel[c]  <= 0;
        end
      end
    end
  end
  // pointer state: the event held for a read, releases, the latches
  always_ff @(posedge clk) begin
    if (rst) begin
      ptr_have <= 0;
      ptr_ev   <= '0;
      ptr_wait <= '0;
      ptr_rel  <= '0;
    end else begin
      if (ts == T_RUN && !t_we && is_ptr_ev && t_idx == 0 && rvalid) begin
        lat_ptr <= ptr_rel_me ? 64'd0 : ptr_ev;     // the bytes after byte 0
        if (!ptr_rel_me) ptr_have <= 0;             // the event is the reader's
      end
`ifdef SIMULATION
      else if (!ptr_have && ts == T_RUN && !t_we && is_ptr_ev && t_idx == 0) begin
        longint e;                                  // fetched while a read is being tried
        e = sim_ptr_pop();
        if (e >= 0) begin
          ptr_have <= 1;
          ptr_ev   <= e;
        end
      end
`endif
      if (ts == T_RUN && !t_we && ptr_st_hit && ra[2:0] == 0 && rvalid) lat_pst <= ptr_st;
      for (int c = 0; c < NCORES; c++) begin
        if (ts == T_RUN && is_ptr_ev && !t_we && t_idx == 0 && int'(t_core) == c) begin
          ptr_wait[c] <= !rvalid;                   // tried: waits, or completes now
          if (rvalid) ptr_rel[c] <= 0;
        end
        if (ts == T_RUN && t_we && t_port == DEV_PTR_EVENT && wvalid && ptr_wait[c]) ptr_rel[c] <= 1;
        if (core_clr[c]) begin
          ptr_wait[c] <= 0;
          ptr_rel[c]  <= 0;
        end
      end
    end
  end
`ifdef SIMULATION
  always_ff @(posedge clk) ptr_st <= sim_ptr_state(ts == T_RUN && !t_we && ptr_st_hit && ra[2:0] == 0 ? 1 : 0);
`else
  assign ptr_st = '0;
`endif

  // timer and VSYNC state: latches, DEADLINE writes, armed VSYNC reads
  logic [63:0] wa;          // byte address of the current write beat
  assign wa = t_port + 64'(t_idx);
  always_ff @(posedge clk) begin
    if (rst) begin
      deadline <= '0;
      vs_armed <= '0;
    end else if (ts == T_RUN) begin
      if (!t_we && rvalid) begin
        if (is_wait && t_idx == 0) lat_wait <= now;
        else if (is_vsync && t_idx == 0) lat_vs <= frame;
        else if (tmr_hit && ra == DEV_TMR_NOW) lat_now <= now;
        else if (tmr_hit && ra == DEV_TMR_DL) lat_dl <= deadline;
      end
      if (t_we && wvalid && wa >= DEV_TMR_DL && wa < DEV_TMR_DL + 64'd8) begin
        dl_wbuf[8*wa[2:0] +: 8] <= wdata[7:0];
        if (wa[2:0] == 3'd7) deadline <= {wdata[7:0], dl_wbuf[55:0]};
      end
      if (!t_we && is_vsync && t_idx == 0) begin
        for (int c = 0; c < NCORES; c++)
          if (int'(t_core) == c) begin
            if (rvalid) vs_armed[c] <= 0;            // done: the next read waits afresh
            else if (!vs_armed[c]) begin
              vs_armed[c] <= 1;
              vs_from[c]  <= frame;
            end
          end
      end
    end
    if (!rst)
      for (int c = 0; c < NCORES; c++) if (core_clr[c]) vs_armed[c] <= 0;
  end

`ifdef SIMULATION
  // console input from the harness: one byte at a time, fetched while a read
  // of the input port is being tried (the harness answers -1: nothing yet)
  always_ff @(posedge clk) begin
    if (rst) sim_have <= 0;
    else if (con_rx_pop) sim_have <= 0;
    else if (!sim_have && ts == T_RUN && is_con_in && !t_we && !in_rel_me) begin
      int c;
      c = sim_getc();
      if (c >= 0) begin
        sim_have <= 1;
        sim_ch   <= 8'(c);
      end
    end
  end
`endif

  always_ff @(posedge clk) begin
    if (rst) begin
      ts <= T_IDLE;
    end else begin
      case (ts)
        T_IDLE: if (start) begin
          t_port <= addr;
          t_idx  <= '0;
          t_n    <= beats;
          t_we   <= we;
          t_core <= master >> 1;
          ts     <= beats == 0 ? T_DONE : T_RUN;
        end
        T_RUN: begin
          if (retry) ts <= T_IDLE;
          else if ((t_we && wvalid && wready) || (!t_we && rvalid)) begin
            t_idx <= t_idx + 1;
            if (t_idx + 1 == t_n) ts <= T_IDLE;
`ifdef SIMULATION
            if (t_we && t_port == DEV_CONSOLE) sim_putc(wdata[7:0]);
            if (t_we && t_port == DEV_FB_PRESENT && t_idx + 1 == t_n) sim_fb_present();
            if (t_we && t_port == DEV_NET_TX) sim_net_tx(int'(t_idx), wdata[7:0], int'(t_idx + 1 == t_n));
`endif
          end
        end
        T_DONE: ts <= T_IDLE;
        default: ts <= T_IDLE;
      endcase
    end
  end

  // ================================================================ block engine
  typedef enum logic [3:0] {G_IDLE, G_CHECK, G_RDISK, G_WREQ, G_WDATA, G_WDONE,
                            G_RREQ, G_RDATA, G_POST, G_GIVE} gstate_t;
  gstate_t     gs;
  logic [255:0] cmd;
  cap_t        gcap;
  logic [7:0]  op, reply, ret_to;   // (reply: reserved; the capability goes back to ret_to, its lender)
  logic [15:0] cid;
  logic [31:0] nblk;
  logic [63:0] lba, boff, bytes;
  logic [63:0] wi, nwords;
  logic [15:0] status;
  logic [63:0] dq;           // disk word read
  logic [DAW-1:0] da;

  assign op    = cmd[7:0];
  assign reply = cmd[15:8];
  assign cid   = cmd[31:16];
  assign nblk  = cmd[63:32];
  assign lba   = cmd[127:64];
  assign boff  = cmd[191:128];
  assign bytes = 64'(nblk) << 9;
  assign da    = DAW'((lba << 6) + wi);

  logic disk_rd, disk_wr;
  always_ff @(posedge clk) begin
    if (disk_rd) dq <= disk[da];
    if (disk_wr) disk[da] <= m_rdata;
`ifdef SIMULATION
    if (disk_wr) disk_write(int'(da), longint'(m_rdata)); // the harness keeps the disk (-w)
`endif
  end

  assign m_req      = gs == G_WREQ || gs == G_RREQ;
  assign m_we       = gs == G_WREQ;
  assign m_addr     = 64'(FW'(gcap.base + boff[FW-1:0] + FW'(wi << 3)));   // inside the capability (G_CHECK)
  assign m_wvalid   = gs == G_WDATA;
  assign m_wdata    = dq;
  assign disk_rd    = gs == G_RDISK;
  assign disk_wr    = gs == G_RDATA && m_rvalid;
  assign give_valid = gs == G_GIVE;
  assign give_dst   = ret_to;
  assign give_cap   = gcap;

  always_ff @(posedge clk) begin
    if (rst) begin
      gs       <= G_IDLE;
      sq_fill  <= '0;
      cmd_cnt  <= '0;
      cmd_head <= '0;
      cap_cnt  <= '0;
      cap_head <= '0;
      cq_cnt   <= '0;
      cq_head  <= '0;
      cq_byte  <= '0;
    end else begin
      // ---- submission bytes become commands
      if (sq_push_byte) begin
        sq_buf[sq_fill] <= wdata[7:0];
        sq_fill <= sq_fill + 1;
        if (sq_fill == 5'd31 && cmd_cnt != 3'(CMDQ)) begin
          logic [255:0] c;
          for (int i = 0; i < 31; i++) c[8*i +: 8] = sq_buf[i];
          c[255:248] = wdata[7:0];
          cmdq[2'(cmd_head + cmd_cnt[1:0])] <= c;
          cmdf[2'(cmd_head + cmd_cnt[1:0])] <= t_core;
        end
      end
      // ---- capability inbox
      if (in_push && in_ready) begin
        capq[2'(cap_head + cap_cnt[1:0])] <= in_cap;
        capf[2'(cap_head + cap_cnt[1:0])] <= in_from;
      end
      // ---- completion bytes are consumed one at a time
      if (cq_pop_byte) begin
        cq_byte <= cq_byte + 1;
        if (cq_byte == 4'd15) cq_head <= cq_head + 1;
      end

      begin
        logic take_cmd, take_cap, post;
        take_cmd = 0;
        take_cap = 0;
        post     = 0;
        case (gs)
          G_IDLE: if (cap_cnt != 0 && cq_cnt != 4'(CQD)) begin
            logic       orphan, found;
            logic [1:0] k;
            orphan = 1;                    // the oldest capability's lender has no command queued?
            for (int i = 0; i < CMDQ; i++)
              if (3'(i) < cmd_cnt && cmdf[2'(cmd_head + 2'(i))] == capf[cap_head]) orphan = 0;
            found = 0;                     // the oldest capability of the oldest command's submitter
            k     = '0;
            for (int i = CMDQ - 1; i >= 0; i--)
              if (3'(i) < cap_cnt && cmd_cnt != 0 && capf[2'(cap_head + 2'(i))] == cmdf[cmd_head]) begin
                found = 1;
                k     = 2'(i);
              end
            if (orphan) begin              // a stray gift: straight back to its lender
              gcap     <= capq[cap_head];
              ret_to   <= capf[cap_head];
              take_cap = 1;
              gs       <= G_GIVE;
            end else if (found) begin
              cmd      <= cmdq[cmd_head];
              gcap     <= capq[2'(cap_head + k)];
              ret_to   <= cmdf[cmd_head];
              take_cmd = 1;
              take_cap = 1;
              for (int j = CMDQ - 1; j > 0; j--)     // close the gap: the older ones move up
                if (2'(j) <= k) begin
                  capq[2'(cap_head + 2'(j))] <= capq[2'(cap_head + 2'(j - 1))];
                  capf[2'(cap_head + 2'(j))] <= capf[2'(cap_head + 2'(j - 1))];
                end
              gs       <= G_CHECK;
            end
          end
          G_CHECK: begin
            wi     <= '0;
            nwords <= bytes >> 3;
            status <= 16'd0;
            gs     <= G_POST;
            if (op != 8'd1 && op != 8'd2 && op != 8'd3) status <= 16'd1;
            else if (op != 8'd3 && (nblk > 32'd256 || lba > 64'(DISK_WORDS / 64)
                                    || 64'(nblk) > 64'(DISK_WORDS / 64) - lba)) status <= 16'd2;
            else if (op != 8'd3 && (boff > 64'(gcap.len) || bytes > 64'(gcap.len) - boff || boff[2:0] != 0)) status <= 16'd3;
            else if (op != 8'd3 && gcap.space != SP_T2 && gcap.space != SP_T3) status <= 16'd4;
            else if (op == 8'd1 && !gcap.perms[P_W]) status <= 16'd4;
            else if (op == 8'd2 && !gcap.perms[P_R]) status <= 16'd4;
            else if (op == 8'd1 && nblk != 0) gs <= G_RDISK;
            else if (op == 8'd2 && nblk != 0) gs <= G_RREQ;
          end
          // read command: disk -> memory, one word per bus transaction
          G_RDISK: gs <= G_WREQ;
          G_WREQ:  if (m_gnt) gs <= G_WDATA;
          G_WDATA: if (m_wready) begin          // the target may finish in the same cycle
            if (m_done) begin
              wi <= wi + 1;
              gs <= wi + 1 == nwords ? G_POST : G_RDISK;
            end else gs <= G_WDONE;
          end
          G_WDONE: if (m_done) begin
            wi <= wi + 1;
            gs <= wi + 1 == nwords ? G_POST : G_RDISK;
          end
          // write command: memory -> disk
          G_RREQ:  if (m_gnt) gs <= G_RDATA;
          G_RDATA: if (m_done) begin
            wi <= wi + 1;
            gs <= wi + 1 == nwords ? G_POST : G_RREQ;
          end
          G_POST: begin
            post = 1;
            gs   <= G_GIVE;
          end
          G_GIVE: if (give_ack) gs <= G_IDLE;
          default: gs <= G_IDLE;
        endcase

        if (post) cq[2'(cq_head + cq_cnt[1:0])] <= {64'b0, (status == 0 ? nblk : 32'd0), status, cid};
        cmd_cnt <= cmd_cnt - (take_cmd ? 3'd1 : 3'd0)
                   + ((sq_push_byte && sq_fill == 5'd31 && cmd_cnt != 3'(CMDQ)) ? 3'd1 : 3'd0);
        if (take_cmd) cmd_head <= cmd_head + 1;
        cap_cnt <= cap_cnt - (take_cap ? 3'd1 : 3'd0) + ((in_push && in_ready) ? 3'd1 : 3'd0);
        if (take_cap) cap_head <= cap_head + 1;
        cq_cnt  <= cq_cnt + (post ? 4'd1 : 4'd0) - ((cq_pop_byte && cq_byte == 4'd15) ? 4'd1 : 4'd0);
      end
    end
  end

`ifdef FORMAL
`include "strata_dev.svh"
`endif
endmodule
