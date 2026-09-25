// tb_pe_swd.v — Serial Wire Debug line framing around pe_serdes.
//
// SWDP: request = 8 bits MSB-first; ACK = 3 bits; data = 32 bits
// MSB-first (parity handled by the core, not the SERDES — it rides in
// the 33rd bit position on the wire, outside the SERDES word). One-bit
// turnaround (line released) between fields.

`timescale 1ns / 1ps

module tb_pe_swd;

  localparam int MAXLEN = 32;
  localparam int LENW = $clog2(MAXLEN + 1);
  localparam int H = 8;  // clk cycles per SWD bit

  logic              clk, rst_n;
  logic              cfg_lsb_first, bit_en;
  logic              tx_load, tx_ser, tx_busy, tx_done;
  logic [MAXLEN-1:0] tx_data;
  logic [LENW-1:0]   tx_len;
  logic              rx_ser, rx_start, rx_busy, rx_valid;
  logic [MAXLEN-1:0] rx_data;
  logic [LENW-1:0]   rx_len;
  logic              swdio;
  logic              host_drives;

  pe_serdes #(.MAXLEN(MAXLEN)) dut (.*, .tx_bit_en(bit_en), .rx_bit_en(bit_en));

  initial clk = 0;
  always #5 clk = ~clk;

  integer errors = 0;

  // Sticky event flags for the single-cycle pulses.
  logic tx_done_seen, rx_valid_seen;
  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin tx_done_seen <= 0; rx_valid_seen <= 0; end
    else begin
      if (tx_done)  tx_done_seen  <= 1'b1;
      if (rx_valid) rx_valid_seen <= 1'b1;
    end

  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  task automatic bit_cell();
    repeat (H) @(posedge clk); #1;
  endtask

  function automatic bit parity32(input [31:0] d);
    return ^d;
  endfunction

  // Host -> target request (8b MSB-first via SERDES).
  task automatic send_req(input [7:0] req);
    @(posedge clk); #1;
    host_drives = 1'b1;
    cfg_lsb_first = 1'b0;  // SWD: MSB first
    tx_data = req; tx_len = 8; tx_load = 1'b1;
    tx_done_seen = 1'b0;
    @(posedge clk); #1; tx_load = 1'b0;
    for (int k = 0; k < 8; k++) begin
      swdio = tx_ser;
      check(swdio === req[7-k], $sformatf("swd req: bit %0d", k));
      bit_cell();
      bit_en = 1'b1; @(posedge clk); #1; bit_en = 1'b0;
    end
    repeat (2) @(posedge clk); #1;
    check(tx_done_seen === 1'b1, "swd req: tx_done");
    host_drives = 1'b0; swdio = 1'b1; bit_cell();  // turnaround
  endtask

  // Target -> host field (3b ACK or 32b data) via SERDES rx. Parity bit
  // rides on the wire after the word but is not part of the SERDES field.
  task automatic recv_field(input [MAXLEN-1:0] field, input int n,
                            input bit par, input string tag);
    @(posedge clk); #1;
    cfg_lsb_first = 1'b0;
    rx_len = LENW'(n); rx_start = 1'b1;
    rx_valid_seen = 1'b0;
    @(posedge clk); #1; rx_start = 1'b0;
    for (int k = 0; k < n; k++) begin
      swdio = field[n-1-k];  // MSB-first on the wire
      rx_ser = swdio;
      bit_cell();
      bit_en = 1'b1; @(posedge clk); #1; bit_en = 1'b0;
    end
    if (par !== 1'bx) begin  // trailing parity bit on the wire (n==32)
      swdio = par;
      bit_cell();
    end
    repeat (2) @(posedge clk); #1;
    check(rx_valid_seen === 1'b1, {tag, ": rx_valid"});
  endtask

  // Full read transaction: request, ACK=OK(100), 32b data + parity, turn.
  task automatic rd_txn(input [7:0] req, input [31:0] data);
    send_req(req);
    recv_field(3'b100, 3, 1'bx, "swd ack");
    check(rx_data[2:0] === 3'b100, "swd ack: OK code");
    recv_field(data, 32, parity32(data), "swd data");
    check(rx_data[31:0] === data, "swd data: payload");
    host_drives = 1'b0; swdio = 1'b1; bit_cell();  // turnaround
    host_drives = 1'b1;
  endtask

  initial begin
    $dumpfile("tb_pe_swd.vcd");
    $dumpvars(0, tb_pe_swd);
    rst_n = 0; swdio = 1; host_drives = 1; bit_en = 0;
    cfg_lsb_first = 0; tx_load = 0; tx_data = 0; tx_len = 0;
    rx_ser = 0; rx_start = 0; rx_len = 0;
    repeat (3) @(posedge clk); #1; rst_n = 1;
    @(posedge clk); #1;

    rd_txn(8'hA5, 32'h12345678);
    rd_txn(8'h8D, 32'hDEADBEEF);
    rd_txn(8'hA9, 32'h00000000);
    rd_txn(8'hBD, 32'hFFFFFFFF);

    if (errors == 0) $display("PASS: tb_pe_swd");
    else $display("FAILURES: %0d", errors);
    $finish;
  end

endmodule
