`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/07/2026 06:58:58 PM
// Design Name: 
// Module Name: axis_parser_tb
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

module axis_to_parser_tb;
    reg         clk = 0, rst = 0;
    reg  [7:0]  s_axis_tdata = 0;
    reg         s_axis_tvalid = 0;
    reg         s_axis_tlast = 0;
    wire        s_axis_tready;

    // intermediate signals between adapter → parser
    wire [7:0]  rx_data;
    wire        rx_ready;

    // parser outputs
    wire        msg_valid, msg_error, signal;
    wire [7:0]  msg_type;
    wire [15:0] msg_price;

    integer     errors = 0;
    reg         saw_valid, saw_error, saw_signal;

    // DUT 1: adapter
    axis_to_parser adapter (
        .clk(clk), .rst(rst),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tready(s_axis_tready),
        .rx_data(rx_data),
        .rx_ready(rx_ready)
    );

    // DUT 2: parser (your msg_parser - adjust the port names to match yours)
    msg_parser #(.THRESHOLD(16'd1000)) parser (
        .clk(clk), .rx_data(rx_data), .rx_ready(rx_ready),
        .msg_valid(msg_valid), .msg_error(msg_error),
        .msg_type(msg_type), .msg_price(msg_price), .signal(signal)
    );

    always #5 clk = ~clk;

    // Send one byte via AXI-Stream: raise tvalid for 1 cycle
    // (since tready is always 1, the transfer happens in that cycle)
    task axis_send;
        input [7:0] b;
        input       last;
        begin
            @(negedge clk);
            s_axis_tdata  = b;
            s_axis_tvalid = 1'b1;
            s_axis_tlast  = last;
            @(negedge clk);
            s_axis_tvalid = 1'b0;
            s_axis_tlast  = 1'b0;
            // a gap between bytes (in real UDP they may be back-to-back,
            // but let's also test the parser's tolerance to gaps)
            @(negedge clk);
        end
    endtask

    // Capture the strobes
    always @(posedge clk) begin
        if (msg_valid) saw_valid  <= 1'b1;
        if (msg_error) saw_error  <= 1'b1;
        if (signal)    saw_signal <= 1'b1;
    end
    task clear;
        begin @(negedge clk); saw_valid=0; saw_error=0; saw_signal=0; end
    endtask

    // Send a complete message (SYNC, TYPE, LEN, price_hi, price_lo, csum)
    task send_trade;
        input [15:0] price;
        reg [7:0] hi, lo, csum;
        begin
            hi = price[15:8]; lo = price[7:0];
            csum = 8'h54 ^ 8'h02 ^ hi ^ lo;
            axis_send(8'hAB, 0);          // SYNC
            axis_send(8'h54, 0);          // TYPE = 'T'
            axis_send(8'h02, 0);          // LEN = 2
            axis_send(hi,    0);          // price hi
            axis_send(lo,    0);          // price lo
            axis_send(csum,  1);          // checksum + tlast (end of packet)
        end
    endtask

    initial begin
        $dumpfile("axis_to_parser_tb.vcd");
        $dumpvars(0, axis_to_parser_tb);

        // Reset
        rst = 1; repeat(4) @(negedge clk); rst = 0;
        repeat(2) @(negedge clk);

        // Test 1: TRADE 1500 > 1000 → signal
        clear; send_trade(16'd1500);
        repeat(4) @(negedge clk);
        if (saw_valid && saw_signal && msg_price==16'd1500)
            $display("[%0t] PASS: TRADE 1500 → signal", $time);
        else begin $display("[%0t] FAIL t1: v=%b s=%b p=%0d",
                   $time, saw_valid, saw_signal, msg_price); errors=errors+1; end

        // Test 2: TRADE 500 < 1000 → NO signal
        clear; send_trade(16'd500);
        repeat(4) @(negedge clk);
        if (saw_valid && !saw_signal && msg_price==16'd500)
            $display("[%0t] PASS: TRADE 500 → NO signal", $time);
        else begin $display("[%0t] FAIL t2: v=%b s=%b p=%0d",
                   $time, saw_valid, saw_signal, msg_price); errors=errors+1; end

        // Test 3: corrupt checksum → error, NO signal
        clear;
        axis_send(8'hAB,0); axis_send(8'h54,0); axis_send(8'h02,0);
        axis_send(8'h05,0); axis_send(8'hDC,0); axis_send(8'h00,1); // wrong csum
        repeat(4) @(negedge clk);
        if (saw_error && !saw_valid && !saw_signal)
            $display("[%0t] PASS: corrupt checksum → rejected", $time);
        else begin $display("[%0t] FAIL t3: e=%b v=%b s=%b",
                   $time, saw_error, saw_valid, saw_signal); errors=errors+1; end

        // Test 4: garbage bytes + valid message → framing
        clear;
        axis_send(8'h11,0); axis_send(8'h22,0); axis_send(8'h33,0); // garbage
        send_trade(16'd2000);
        repeat(4) @(negedge clk);
        if (saw_valid && saw_signal)
            $display("[%0t] PASS: garbage skipped, message decoded", $time);
        else begin $display("[%0t] FAIL t4: v=%b s=%b",
                   $time, saw_valid, saw_signal); errors=errors+1; end

        if (errors==0) $display("[%0t] ALL TESTS PASS", $time);
        else           $display("[%0t] %0d ERRORS", $time, errors);
        $finish;
    end
endmodule
