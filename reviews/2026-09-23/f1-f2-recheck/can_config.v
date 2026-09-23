`timescale 1ns/1ps
module verify_can_config;
    parameter [7:0] CFG = 8'h05;
    reg clk = 0, rst_n = 0, bit_en = 0;
    always #5 clk = ~clk;
    wire tx_wire, tx_stuffed, rx_bit, rx_bit_valid, rx_err;
    pe_codec_mux dut (
        .clk(clk), .rst_n(rst_n), .cfg(CFG), .bit_en(bit_en), .clr(1'b0),
        .tx_bit(1'b1), .tx_wire(tx_wire), .tx_stuffed(tx_stuffed),
        .rx_wire(1'b1), .rx_first(1'b0), .rx_second(1'b0),
        .rx_bit(rx_bit), .rx_bit_valid(rx_bit_valid), .rx_err(rx_err)
    );
    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        @(negedge clk);
        bit_en = 1;
        @(posedge clk); #1;
        $display("CAN cfg=%h: TX=%b RX=%b valid=%b error=%b; expected TX=1 RX=1 valid=1 error=0",
                 CFG, tx_wire, rx_bit, rx_bit_valid, rx_err);
        if (tx_wire !== 1'b1 || rx_bit !== 1'b1 || rx_bit_valid !== 1'b1 || rx_err !== 1'b0)
            $fatal(1, "documented CAN configuration enables incorrect codec stages");
        $finish;
    end
endmodule
