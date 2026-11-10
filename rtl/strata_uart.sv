// Strata: 8N1 UART with small receive FIFO, used as the console on FPGA.
//
// tx_valid/tx_ready hand a byte to the transmitter; rx_valid/rx_pop expose
// the oldest received byte. CLKS_PER_BIT = clock frequency / baud rate.

module strata_uart #(
  parameter int CLKS_PER_BIT = 868,   // 100 MHz / 115200
  parameter int RXDEPTH      = 16
)(
  input  logic       clk,
  input  logic       rst,
  // transmit
  input  logic       tx_valid,
  input  logic [7:0] tx_byte,
  output logic       tx_ready,
  output logic       txd,
  // receive
  input  logic       rxd,
  output logic       rx_valid,
  output logic [7:0] rx_byte,
  input  logic       rx_pop
);
  localparam int CW = $clog2(CLKS_PER_BIT + 1);

  // ------------------------------------------------------------ transmitter
  logic [9:0]    tx_shift;
  logic [3:0]    tx_bits;
  logic [CW-1:0] tx_cnt;

  assign tx_ready = tx_bits == 0;

  always_ff @(posedge clk) begin
    if (rst) begin
      txd     <= 1;
      tx_bits <= 0;
      tx_cnt  <= '0;
    end else if (tx_bits == 0) begin
      if (tx_valid) begin
        tx_shift <= {1'b1, tx_byte, 1'b0};   // stop, data (LSB first), start
        tx_bits  <= 4'd10;
        tx_cnt   <= '0;
      end
    end else if (tx_cnt == CW'(CLKS_PER_BIT - 1)) begin
      txd      <= tx_shift[0];
      tx_shift <= {1'b1, tx_shift[9:1]};
      tx_bits  <= tx_bits - 1;
      tx_cnt   <= '0;
    end else begin
      if (tx_cnt == 0) txd <= tx_shift[0];
      tx_cnt <= tx_cnt + 1;
    end
  end

  // ------------------------------------------------------------ receiver
  logic [1:0]    rx_sync;
  logic          rx_busy;
  logic [3:0]    rx_bits;
  logic [CW-1:0] rx_cnt;
  logic [7:0]    rx_shift;

  logic [7:0]    fifo [RXDEPTH];
  logic [$clog2(RXDEPTH):0] f_cnt;
  logic [$clog2(RXDEPTH)-1:0] f_head;
  logic          push;

  assign rx_valid = f_cnt != 0;
  assign rx_byte  = fifo[f_head];

  always_ff @(posedge clk) begin
    if (rst) begin
      rx_sync <= 2'b11;
      rx_busy <= 0;
      push    <= 0;
    end else begin
      rx_sync <= {rx_sync[0], rxd};
      push    <= 0;
      if (!rx_busy) begin
        if (!rx_sync[1]) begin               // start bit edge
          rx_busy <= 1;
          rx_bits <= 4'd9;
          rx_cnt  <= CW'(CLKS_PER_BIT / 2);  // sample mid-bit
        end
      end else if (rx_cnt == CW'(CLKS_PER_BIT - 1)) begin
        rx_cnt <= '0;
        if (rx_bits == 0) begin
          rx_busy <= 0;
          push    <= rx_sync[1];             // valid stop bit
        end else begin
          if (rx_bits != 9) rx_shift <= {rx_sync[1], rx_shift[7:1]};
          rx_bits <= rx_bits - 1;
        end
      end else begin
        rx_cnt <= rx_cnt + 1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      f_cnt  <= '0;
      f_head <= '0;
    end else begin
      if (push && f_cnt != ($clog2(RXDEPTH)+1)'(RXDEPTH)) fifo[f_head + f_cnt[$clog2(RXDEPTH)-1:0]] <= rx_shift;
      if (rx_pop && f_cnt != 0) f_head <= f_head + 1;
      f_cnt <= f_cnt + ((push && f_cnt != ($clog2(RXDEPTH)+1)'(RXDEPTH)) ? 1 : 0) - ((rx_pop && f_cnt != 0) ? 1 : 0);
    end
  end
endmodule
