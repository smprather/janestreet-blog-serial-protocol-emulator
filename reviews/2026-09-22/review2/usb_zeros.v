`timescale 1ns/1ps
module usb_review;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg bit_en = 0;
    reg clr = 0;
    reg tx_bit = 0;
    reg rx_wire = 1;
    wire tx_wire, tx_stuffed, rx_bit, rx_bit_valid, rx_err;
    integer accepted = 0;
    integer errors = 0;
    integer stuffed = 0;
    // Review 2 fix: cfg[7] now selects the USB one-polarity stuffing rule
    // explicitly (0 = either polarity, CAN; 1 = ones only, USB). The USB
    // configuration byte is therefore 0xE3, not 0x63.
    pe_codec_mux dut (
        .clk(clk), .rst_n(rst_n), .cfg(8'hE3), .bit_en(bit_en), .clr(clr),
        .tx_bit(tx_bit), .tx_wire(tx_wire), .tx_stuffed(tx_stuffed),
        .rx_wire(rx_wire), .rx_first(1'b0), .rx_second(1'b0),
        .rx_bit(rx_bit), .rx_bit_valid(rx_bit_valid), .rx_err(rx_err)
    );
    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        for (integer i = 0; i < 8; i++) begin
            @(negedge clk);
            bit_en = 1;
            rx_wire = ~rx_wire;
            #1;
            if (rx_bit_valid) accepted++;
            if (tx_stuffed) stuffed++;
            $display("USB zero bit %0d: TX stuff=%b RX valid=%b raw=%b", i, tx_stuffed, rx_bit_valid, rx_bit);
            @(posedge clk);
            #1;
            if (rx_err) errors++;
            @(negedge clk);
            bit_en = 0;
        end
        $display("USB eight zeros: recovered=%0d want=8, errors=%0d want=0", accepted, errors);
        if (accepted != 8 || errors != 0 || stuffed != 0)
            $fatal(1, "USB must not stuff a run of zeroes");
        $finish;
    end
endmodule
