// Strata: iterative 64-bit divider (one quotient bit per cycle).
//
// Replaces the combinational `/` and `%` of the first prototype, which would
// synthesise into a very deep and slow circuit. Results follow the same
// conventions as before: x/0 = all ones, x%0 = x, MIN/-1 = MIN, MIN%-1 = 0.
//
// Pulse `start` with the operands; `done` rises when `quo`/`rem` are valid
// and stays high until the next `start`.

module strata_div (
  input  logic        clk,
  input  logic        rst,
  input  logic        start,
  input  logic        is_signed,
  input  logic [63:0] a,
  input  logic [63:0] b,
  output logic        busy,
  output logic        done,
  output logic [63:0] quo,
  output logic [63:0] rem
);
  logic [63:0]  dvd, dvs, q;
  logic [64:0]  r;
  logic [6:0]   n;
  logic         neg_q, neg_r, special;
  logic [63:0]  sq, sr;

  logic [63:0] abs_a, abs_b;
  assign abs_a = is_signed && a[63] ? -a : a;
  assign abs_b = is_signed && b[63] ? -b : b;

  logic [64:0] r_sh, r_sub;
  assign r_sh  = {r[63:0], dvd[63]};
  assign r_sub = r_sh - {1'b0, dvs};

  always_ff @(posedge clk) begin
    if (rst) begin
      busy <= 0;
      done <= 0;
    end else if (start) begin
      done    <= 0;
      special <= 0;
      if (b == 0) begin
        special <= 1;
        sq      <= '1;
        sr      <= a;
        busy    <= 0;
        done    <= 1;
      end else if (is_signed && a == 64'h8000_0000_0000_0000 && b == '1) begin
        special <= 1;
        sq      <= a;
        sr      <= '0;
        busy    <= 0;
        done    <= 1;
      end else begin
        dvd   <= abs_a;
        dvs   <= abs_b;
        q     <= '0;
        r     <= '0;
        n     <= 7'd64;
        neg_q <= is_signed && (a[63] ^ b[63]);
        neg_r <= is_signed && a[63];
        busy  <= 1;
      end
    end else if (busy) begin
      if (!r_sub[64]) begin
        r <= r_sub;
        q <= {q[62:0], 1'b1};
      end else begin
        r <= r_sh;
        q <= {q[62:0], 1'b0};
      end
      dvd <= {dvd[62:0], 1'b0};
      n   <= n - 1;
      if (n == 1) begin
        busy <= 0;
        done <= 1;
      end
    end
  end

  assign quo = special ? sq : neg_q ? -q : q;
  assign rem = special ? sr : neg_r ? -r[63:0] : r[63:0];
endmodule
