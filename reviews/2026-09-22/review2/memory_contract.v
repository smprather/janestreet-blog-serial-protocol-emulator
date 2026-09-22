`timescale 1ns/1ps
module review_memory_hold;
reg clk=0,we=0;
reg [10:0] wa=0,ra=0;
reg [7:0] wd=0;
wire [7:0] fm,ff;
wire [15:0] im,ifl;
pe_fbuf #(.FLOP(0)) m(.clk(clk),.we(we),.waddr(wa),.wdata(wd),.raddr(ra),.rdata(fm));
pe_fbuf #(.FLOP(1)) f(.clk(clk),.we(we),.waddr(wa),.wdata(wd),.raddr(ra),.rdata(ff));
pe_imem #(.FLOP(0)) mi(.clk(clk),.host_we(we),.host_addr(wa[9:0]),.host_wdata({8'h00,wd}),.imem_addr(ra[9:0]),.imem_rdata(im));
pe_imem #(.FLOP(1)) fi(.clk(clk),.host_we(we),.host_addr(wa[9:0]),.host_wdata({8'h00,wd}),.imem_addr(ra[9:0]),.imem_rdata(ifl));
always #5 clk=~clk;
initial begin
    @(negedge clk);we=1;wa=0;wd=8'h11;
    @(negedge clk);wa=2;wd=8'h22;
    @(negedge clk);we=0;ra=0;
    @(negedge clk);
    $display("initial fbuf macro=%h flop=%h imem macro=%h flop=%h",fm,ff,im,ifl);
    we=1;wa=4;wd=8'h33;ra=2;
    @(negedge clk);
    $display("write fbuf macro=%h flop=%h imem macro=%h flop=%h",fm,ff,im,ifl);
    if (fm !== ff || im !== ifl) $fatal(1, "macro and fallback outputs diverged");
    $finish;
end
endmodule
