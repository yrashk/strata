// Experiment (research/smart-memory): one single-port memory for both Local
// Stores, with the instruction stream generated at the memory.
//
// Today a core has two true dual-port memories: the I-LS (port A: the fetch,
// port B: tgetx) and the D-LS (port A: loads and stores, port B: tget /
// tput). The core is multi-cycle and never uses both of its ports in one
// cycle, and the Transfer Unit moves at most one word per cycle, so one
// single-port memory can serve all four users if they take turns. This
// module is that turn-taking, in front of a plain single-port synchronous
// RAM (m_*: address in, data out the cycle after, as rtl/strata_ram.sv).
//
// The address is a word number in the one memory; where the instruction
// part ends and the data part begins is the user's business (a split
// register in the core: both stores' bounds checks already exist).
//
//   d_*   the core's data port. It always gets the memory in the cycle it
//         asks (loads and stores keep their timing).
//   f_*   the instruction stream. The core says where to start (f_redir,
//         f_raddr: a jump, a taken branch, a trap) and then takes words in
//         order (f_take when f_valid). The module keeps up to two words and
//         reads the following ones by itself whenever the memory is free:
//         the incrementer is here, not in the core. A word is 64 bits = two
//         instructions, so sequential code needs one read per two
//         instructions and no fetch cycles of its own.
//   u_*   the Transfer Unit's port. u_ready low: not this cycle, ask again.
//         A write into the words the stream holds or is reading (tgetx over
//         code about to run) empties the stream, which then reads them again.
//
// Priority: data > the stream when the core has nothing to execute > the
// unit > reading ahead.

module ls_unified #(
  parameter int AW = 14               // 2^AW words (14: 128 KiB)
)(
  input  logic          clk,
  input  logic          rst,

  input  logic          f_redir,
  input  logic [AW-1:0] f_raddr,
  input  logic          f_take,
  output logic          f_valid,
  output logic [63:0]   f_word,
  output logic [AW-1:0] f_waddr,

  input  logic          d_en,
  input  logic [7:0]    d_we,
  input  logic [AW-1:0] d_addr,
  input  logic [63:0]   d_wdata,
  output logic [63:0]   d_rdata,

  input  logic          u_en,
  input  logic [7:0]    u_we,
  input  logic [AW-1:0] u_addr,
  input  logic [63:0]   u_wdata,
  output logic          u_ready,
  output logic          u_rvalid,
  output logic [63:0]   u_rdata,

  output logic          m_en,
  output logic [7:0]    m_we,
  output logic [AW-1:0] m_addr,
  output logic [63:0]   m_wdata,
  input  logic [63:0]   m_rdata
);
  // the stream: words head .. head + cnt - 1 are held, word `nxt` is read next
  logic [63:0]   q_d [2];
  logic [1:0]    cnt;
  logic [AW-1:0] head, nxt;
  logic          infl;                // a stream read was issued last cycle
  logic          kill;                // ... and its word is no longer wanted

  logic hungry, room, f_go, u_go, u_hit, restart;
  logic [1:0] cnt_t;                  // words held after this cycle's take
  assign cnt_t   = cnt - (f_take && f_valid ? 2'd1 : 2'd0);
  assign hungry  = cnt == 0 && !(infl && !kill);
  assign room    = {1'b0, cnt_t} + (infl && !kill ? 3'd1 : 3'd0) < 3'd2;
  // the unit writes a word the stream holds, is reading or reads next
  assign u_hit   = u_go && u_we != 0 && (u_addr - head) <= AW'(cnt) + (infl && !kill ? AW'(1) : AW'(0));
  assign restart = f_redir || u_hit;

  always_comb begin
    f_go = 0;
    u_go = 0;
    if (d_en) ;
    else if (hungry && !f_redir) f_go = 1;
    else if (u_en) u_go = 1;
    else if (room && !f_redir) f_go = 1;
  end
  assign u_ready = u_go;

  always_comb begin
    m_en    = d_en || f_go || u_go;
    m_we    = d_en ? d_we : u_go ? u_we : 8'h00;
    m_addr  = d_en ? d_addr : u_go ? u_addr : nxt;
    m_wdata = d_en ? d_wdata : u_wdata;
  end

  assign d_rdata = m_rdata;
  assign u_rdata = m_rdata;
  assign f_valid = cnt != 0;
  assign f_word  = q_d[0];
  assign f_waddr = head;

  always_ff @(posedge clk) begin
    if (rst) begin
      cnt      <= '0;
      head     <= '0;
      nxt      <= '0;
      infl     <= 0;
      kill     <= 0;
      u_rvalid <= 0;
    end else begin
      u_rvalid <= u_go && u_we == 0;
      infl     <= f_go;
      kill     <= 0;
      if (restart) begin
        // a new course (or the words were overwritten): forget everything,
        // also the read under way and the one issued this cycle
        cnt  <= '0;
        head <= f_redir ? f_raddr : head + (f_take && f_valid ? AW'(1) : AW'(0));
        nxt  <= f_redir ? f_raddr : head + (f_take && f_valid ? AW'(1) : AW'(0));
        kill <= 1;
      end else begin
        if (f_take && f_valid) begin
          q_d[0] <= q_d[1];
          head   <= head + 1;
        end
        if (infl && !kill) begin
          if (cnt_t == 0) q_d[0] <= m_rdata; else q_d[1] <= m_rdata;
        end
        cnt <= cnt_t + (infl && !kill ? 2'd1 : 2'd0);
        if (f_go) nxt <= nxt + 1;
      end
    end
  end
endmodule
