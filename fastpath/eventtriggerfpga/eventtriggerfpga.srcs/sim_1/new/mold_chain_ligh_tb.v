
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/15/2026 05:49:55 PM
// Design Name: 
// Module Name: mold_chain_ligh_tb
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


`timescale 1ns/1ps

module mold_chain_ligh_tb;
    reg         clk = 0, rst = 0;
    reg  [7:0]  rx_data = 0;
    reg         rx_ready = 0;
    reg         tlast = 0;              // ALWAYS 0 IN THIS TEST (framer finishes by count)

    wire [7:0]  msg_data;
    wire        msg_ready;
    wire [7:0]  msg_type;
    wire [31:0] msg_price;
    wire        signal;

    integer     errors = 0;
    integer     signal_count = 0;
    reg  [31:0] last_price = 0;
    reg         clear_cap = 0;

    mold_framer framer (
        .clk(clk), .rst(rst),
        .rx_data(rx_data), .rx_ready(rx_ready), .s_axis_tlast(tlast),
        .msg_data(msg_data), .msg_ready(msg_ready)
    );
    itch_parser #(.THRESHOLD(32'd1000000)) parser (
        .clk(clk), .rx_data(msg_data), .rx_ready(msg_ready),
        .msg_type(msg_type), .msg_price(msg_price), .signal(signal)
    );

    always #5 clk = ~clk;

    // Single-driver capture (no leakage)
    always @(posedge clk) begin
        if (clear_cap) begin
            signal_count <= 0; last_price <= 0;
        end else if (signal) begin
            signal_count <= signal_count + 1; last_price <= msg_price;
        end
    end

    task feed;
        input [7:0] b;
        begin
            @(negedge clk); rx_data = b; rx_ready = 1'b1;
            @(negedge clk); rx_ready = 1'b0;
        end
    endtask

    task feed_add_order;
        input [7:0]  side;
        input [31:0] price;
        begin
            feed(8'h41);
            feed(8'h00); feed(8'h01);
            feed(8'h00); feed(8'h00);
            feed(8'h00); feed(8'h00); feed(8'h12); feed(8'h34); feed(8'h56); feed(8'h78);
            feed(8'h00); feed(8'h00); feed(8'h00); feed(8'h00);
            feed(8'h00); feed(8'h00); feed(8'h00); feed(8'h2A);
            feed(side);
            feed(8'h00); feed(8'h00); feed(8'h00); feed(8'h64);
            feed("A"); feed("A"); feed("P"); feed("L");
            feed(" "); feed(" "); feed(" "); feed(" ");
            feed(price[31:24]); feed(price[23:16]); feed(price[15:8]); feed(price[7:0]);
        end
    endtask

    task feed_header;
        input [15:0] count;
        integer i;
        begin
            for (i=0;i<10;i=i+1) feed(8'h20);
            for (i=0;i<8; i=i+1) feed(8'h00);
            feed(count[15:8]); feed(count[7:0]);
        end
    endtask

    task reset_all;
        begin
            @(negedge clk); rst = 1; clear_cap = 1;
            repeat(6) @(negedge clk);
            rst = 0; clear_cap = 0;
            repeat(4) @(negedge clk);
        end
    endtask

    initial begin
        $dumpfile("mold_chain_ligh_tb.vcd");
        $dumpvars(0, mold_chain_ligh_tb);

        // T1: single message, 1234500 > threshold
        reset_all;
        feed_header(16'd1); feed(8'h00); feed(8'd36);
        feed_add_order("B", 32'd1234500);
        repeat(20) @(negedge clk);
        if (signal_count==1 && last_price==32'd1234500)
            $display("[%0t] PASS T1: price=1234500, 1 signal", $time);
        else begin $display("[%0t] FAIL T1: cnt=%0d price=%0d (0x%08h)",
                   $time, signal_count, last_price, last_price); errors=errors+1; end

        // T2: single message, 500000 < threshold
        reset_all;
        feed_header(16'd1); feed(8'h00); feed(8'd36);
        feed_add_order("B", 32'd500000);
        repeat(20) @(negedge clk);
        if (signal_count==0)
            $display("[%0t] PASS T2: below threshold, no signal", $time);
        else begin $display("[%0t] FAIL T2: cnt=%0d price=%0d",
                   $time, signal_count, last_price); errors=errors+1; end

        // T3: single packet with two messages
        reset_all;
        feed_header(16'd2);
        feed(8'h00); feed(8'd36); feed_add_order("B", 32'd500000);
        feed(8'h00); feed(8'd36); feed_add_order("S", 32'd2000000);
        repeat(20) @(negedge clk);
        if (signal_count==1 && last_price==32'd2000000)
            $display("[%0t] PASS T3: two messages, 2000000 signal", $time);
        else begin $display("[%0t] FAIL T3: cnt=%0d price=%0d (0x%08h)",
                   $time, signal_count, last_price, last_price); errors=errors+1; end

        if (errors==0) $display("[%0t] ALL TESTS PASS", $time);
        else           $display("[%0t] %0d ERRORS", $time, errors);
        $finish;
    end
endmodule