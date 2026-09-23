`timescale 1ns/1ps
module test;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, run = 0;
    wire [7:0] a;
    pe_soc #(.IMEM_FLOP(1)) dut (
        .clk(clk), .rst_n(rst_n), .host_we(1'b0), .host_imem_sel(1'b0),
        .host_addr(10'b0), .host_wdata(16'b0), .run(run), .pin_in(8'b0),
        .pin_out(), .pin_oe(), .dbg_pc(), .dbg_a(a), .dbg_timer()
    );
    initial begin
        #1; rst_n = 0;
        repeat (2) @(negedge clk);
        rst_n = 1; run = 1;
        force dut.imem_rdata = 16'h2007;
        dut.tick_cnt = 259; dut.tick_val = 7; dut.tick_flag = 0;
        @(posedge clk); #1;
        $display("RTL status oldflag=0: A=%0d flag=%0d timer=%0d", a, dut.tick_flag, dut.tick_val);
        @(negedge clk);
        dut.tick_cnt = 259; dut.tick_val = 7; dut.tick_flag = 1;
        @(posedge clk); #1;
        $display("RTL status oldflag=1: A=%0d flag=%0d timer=%0d", a, dut.tick_flag, dut.tick_val);
        @(negedge clk);
        force dut.imem_rdata = 16'h2005;
        dut.tick_cnt = 259; dut.tick_val = 7;
        @(posedge clk); #1;
        $display("RTL timer read: A=%0d timer=%0d", a, dut.tick_val);
        $finish;
    end
endmodule
