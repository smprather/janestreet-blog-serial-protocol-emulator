`timescale 1ns/1ps
module review_cpu_stop;
reg clk=0, rst_n=0, run=0;
wire [9:0] addr;
reg [15:0] rdata;
reg [15:0] mem[0:1023];
wire [7:0] a,pc;
pe_cpu #(.IMEM_WORDS(1024)) dut(.clk(clk),.rst_n(rst_n),.run(run),.imem_addr(addr),.imem_rdata(rdata),.dmem_rdata(8'h00),.io_rdata(8'h00),.dbg_a(a),.dbg_pc(pc));
always #5 clk=~clk;
always @(posedge clk) rdata<=mem[addr];
initial begin
    mem[0]=16'h0055; mem[1]=16'h00aa; mem[2]=16'h4002;
    repeat(3) @(negedge clk);
    rst_n=1;run=1;
    repeat(2) @(negedge clk);
    $display("before stop pc=%0d a=%h",pc,a);
    run=0;
    @(negedge clk);
    $display("stopped pc=%0d fetched=%h",pc,rdata);
    run=1;
    @(negedge clk);
    $display("resumed pc=%0d a=%h expected a=55",pc,a);
    if (a !== 8'h55) $fatal(1, "restart skipped instruction zero");
    $finish;
end
endmodule
