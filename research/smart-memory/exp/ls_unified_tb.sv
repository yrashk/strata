// Test bench for ls_unified.sv: random traffic from a core (an instruction
// stream with jumps, loads and stores) and from a Transfer Unit (bursts of
// reads and writes, some of them over the code being run), checked against
// a plain array. Prints what each user got.
//
//   +jump=N    one transfer of control per N words taken (default 4)
//   +data=N    a load or store in one of N cycles (default 4)
//   +unit=N    the unit wants the memory in N of 100 cycles (default 60)
//   +exec=N    the core takes a word every N cycles at best (2: one
//              instruction per cycle, two per word)

module ls_unified_tb;
  localparam int AW = 14;
  localparam int HALF = 1 << (AW - 1);
  logic clk = 0, rst = 1;
  always #5 clk = !clk;

  logic          f_redir, f_take, f_valid;
  logic [AW-1:0] f_raddr, f_waddr;
  logic [63:0]   f_word;
  logic          d_en;
  logic [7:0]    d_we;
  logic [AW-1:0] d_addr;
  logic [63:0]   d_wdata, d_rdata;
  logic          u_en, u_ready, u_rvalid;
  logic [7:0]    u_we;
  logic [AW-1:0] u_addr;
  logic [63:0]   u_wdata, u_rdata;
  logic          m_en;
  logic [7:0]    m_we;
  logic [AW-1:0] m_addr;
  logic [63:0]   m_wdata, m_rdata;

  ls_unified #(.AW(AW)) dut (.*);

  // the memory, and what it should hold
  logic [63:0] mem [1 << AW];
  logic [63:0] ref_m [1 << AW];
  always_ff @(posedge clk) if (m_en) begin
    for (int i = 0; i < 8; i++) if (m_we[i]) mem[m_addr][8*i +: 8] <= m_wdata[8*i +: 8];
    m_rdata <= mem[m_addr];
  end

  int p_jump = 4, p_data = 4, p_unit = 60, p_exec = 2;
  longint cycles, words, redirs, loads, stores, u_asked, u_got, wait_f, errors;
  int      exec_cd;
  logic        d_rd_q, u_rd_q;
  logic [AW-1:0] d_a_q, u_a_q;
  logic [AW-1:0] expect_w;        // the word the stream must deliver next
  logic          u_hold;          // the unit repeats a refused request
  int            burst;
  logic [AW-1:0] burst_a;
  logic          burst_w, burst_code;

  initial begin
    void'($value$plusargs("jump=%d", p_jump));
    void'($value$plusargs("data=%d", p_data));
    void'($value$plusargs("unit=%d", p_unit));
    void'($value$plusargs("exec=%d", p_exec));
    for (int i = 0; i < (1 << AW); i++) begin
      mem[i]   = {32'(i), 32'hc0de0000 + 32'(i)};
      ref_m[i] = mem[i];
    end
    f_redir = 0; f_take = 0; d_en = 0; u_en = 0; d_we = 0; u_we = 0;
    f_raddr = 0; d_addr = 0; d_wdata = 0; u_addr = 0; u_wdata = 0;
    expect_w = 0; exec_cd = 0; burst = 0; u_hold = 0;
    repeat (4) @(posedge clk);
    rst = 0;
    repeat (400000) @(posedge clk);
    $display("jump 1/%0d data 1/%0d unit %0d%% exec %0d: cycles %0d", p_jump, p_data, p_unit, p_exec, cycles);
    $display("  stream: %0d words (%0d instructions), %0d jumps; %.3f cycles per instruction; cycles without a word %0d",
             words, 2 * words, redirs, real'(cycles) / real'(2 * words), wait_f);
    $display("  data: %0d loads, %0d stores (never refused)", loads, stores);
    $display("  unit: asked in %0d cycles, served in %0d (%.1f%%)", u_asked, u_got, 100.0 * real'(u_got) / real'(u_asked > 0 ? u_asked : 1));
    $display("  errors %0d", errors);
    $finish;
  end

  // stimulus: driven on the falling edge, checked on the rising edge
  always @(negedge clk) if (!rst) begin
    // the core: take a word when there is one and the previous one is done
    f_take  = 0;
    f_redir = 0;
    if (exec_cd > 0) exec_cd--;
    if (f_valid && exec_cd == 0) begin
      f_take  = 1;
      exec_cd = p_exec - 1;
      if ($urandom_range(p_jump - 1) == 0) begin
        f_redir = 1;                              // this word ended in a taken branch
        f_raddr = AW'($urandom_range(HALF - 1));
      end
    end
    d_en = $urandom_range(p_data - 1) == 0;
    d_we = $urandom_range(1) == 0 ? 8'h00 : 8'($urandom);
    d_addr  = AW'(HALF + HALF / 2 + $urandom_range(HALF / 2 - 1));   // the core's own data
    d_wdata = {$urandom, $urandom};
    // the unit: bursts of consecutive words; a refused request is repeated
    if (!u_hold) begin
      if (burst == 0 && int'($urandom_range(99)) < p_unit) begin
        burst      = 1 + int'($urandom_range(63));
        burst_code = $urandom_range(7) == 0;      // tgetx: into the code
        burst_w    = burst_code || $urandom_range(1) == 0;
        burst_a    = burst_code ? AW'($urandom_range(HALF - 65)) : AW'(HALF + $urandom_range(HALF / 2 - 65));
        // (the architecture stalls the fetch of code being replaced: keep
        // the burst off the word the core is about to take)
      end
      u_en = burst != 0;
      if (u_en) begin
        u_we    = burst_w ? 8'hff : 8'h00;
        u_addr  = burst_a;
        u_wdata = {$urandom, $urandom};
        burst_a = burst_a + 1;
        burst   = burst - 1;
      end
    end
  end

  always @(posedge clk) if (!rst) begin
    cycles <= cycles + 1;
    // read data of last cycle's accesses
    if (d_rd_q && d_rdata !== ref_m[d_a_q]) begin errors <= errors + 1; $display("load %h: %h, not %h", d_a_q, d_rdata, ref_m[d_a_q]); end
    if (u_rd_q != u_rvalid) begin errors <= errors + 1; $display("u_rvalid"); end
    if (u_rvalid && u_rdata !== ref_m[u_a_q]) begin errors <= errors + 1; $display("unit read %h", u_a_q); end
    d_rd_q <= d_en && d_we == 0;
    d_a_q  <= d_addr;
    u_rd_q <= u_en && u_ready && u_we == 0;
    u_a_q  <= u_addr;
    // the stream delivers the words in order, with what the memory holds now
    if (f_take) begin
      words <= words + 1;
      if (f_waddr !== expect_w || f_word !== ref_m[f_waddr]) begin
        errors <= errors + 1;
        $display("stream: word %h = %h, expected word %h = %h", f_waddr, f_word, expect_w, ref_m[expect_w]);
      end
      expect_w <= f_redir ? f_raddr : expect_w + 1;
      if (f_redir) redirs <= redirs + 1;
    end
    if (!f_valid && exec_cd == 0) wait_f <= wait_f + 1;
    // writes
    if (d_en && d_we != 0) begin
      stores <= stores + 1;
      for (int i = 0; i < 8; i++) if (d_we[i]) ref_m[d_addr][8*i +: 8] <= d_wdata[8*i +: 8];
    end
    if (d_en && d_we == 0) loads <= loads + 1;
    if (u_en) u_asked <= u_asked + 1;
    if (u_en && u_ready) begin
      u_got <= u_got + 1;
      if (u_we != 0) ref_m[u_addr] <= u_wdata;
    end
    u_hold <= u_en && !u_ready;
  end
endmodule
