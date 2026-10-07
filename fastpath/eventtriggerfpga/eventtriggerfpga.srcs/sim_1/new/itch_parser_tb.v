
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/11/2026 07:18:50 PM
// Design Name: 
// Module Name: itch_parser_tb
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

module itch_parser_tb;
    reg         clk = 0;
    reg  [7:0]  rx_data = 0;
    reg         rx_ready = 0;

    wire [7:0]  msg_type;
    wire [47:0] msg_timestamp;
    wire [63:0] msg_orderref;
    wire [7:0]  msg_indicator;
    wire [63:0] msg_stock;
    wire [31:0] msg_price;
    wire        signal;

    integer errors = 0;
    reg     saw_signal;
    // capture all fields at the moment of signal
    reg [7:0]  cap_type;
    reg [47:0] cap_ts;
    reg [63:0] cap_oref;
    reg [7:0]  cap_side;
    reg [63:0] cap_stock;
    reg [31:0] cap_price;

    itch_parser #(.THRESHOLD(32'd1000000)) dut (
        .clk(clk), .rx_data(rx_data), .rx_ready(rx_ready),
        .msg_type(msg_type), .msg_timestamp(msg_timestamp),
        .msg_orderref(msg_orderref), .msg_indicator(msg_indicator),
        .msg_stock(msg_stock), .msg_price(msg_price), .signal(signal)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (signal) begin
            saw_signal <= 1'b1;
            cap_type   <= msg_type;   cap_ts    <= msg_timestamp;
            cap_oref   <= msg_orderref; cap_side <= msg_indicator;
            cap_stock  <= msg_stock;  cap_price <= msg_price;
        end
    end

    task feed;
        input [7:0] b;
        begin
            @(negedge clk); rx_data = b; rx_ready = 1'b1;
            @(negedge clk); rx_ready = 1'b0;
            @(negedge clk);
        end
    endtask

    // Real ITCH Add Order (submillisecond.com example), price parameterized
    task send_real_add_order;
        input [31:0] price;
        begin
            feed(8'h41);                                   // type 'A'
            feed(8'h04); feed(8'hD2);                      // stock locate 1234
            feed(8'h00); feed(8'h00);                      // tracking
            feed(8'h1F); feed(8'h1A); feed(8'hCE);
            feed(8'hD9); feed(8'hF0); feed(8'h7B);         // timestamp 1f1aced9f07b
            feed(8'h00); feed(8'h00); feed(8'h00); feed(8'h00);
            feed(8'h00); feed(8'h00); feed(8'h00); feed(8'h2A); // order ref 42
            feed(8'h42);                                   // side 'B'
            feed(8'h00); feed(8'h00); feed(8'h00); feed(8'h64); // shares 100
            feed(8'h41); feed(8'h41); feed(8'h50); feed(8'h4C);
            feed(8'h20); feed(8'h20); feed(8'h20); feed(8'h20); // stock "AAPL    "
            feed(price[31:24]); feed(price[23:16]);
            feed(price[15:8]);  feed(price[7:0]);          // price
        end
    endtask

    task check_all;
        input [127:0] label;
        reg ok;
        begin
            ok = 1;
            if (!saw_signal) begin
                $display("[%0t] FAIL %0s: no signal received", $time, label);
                errors=errors+1; ok=0;
            end else begin
                if (cap_type  !== 8'h41)              begin $display("  type=%02h != 41", cap_type); errors=errors+1; ok=0; end
                if (cap_ts    !== 48'h1F1ACED9F07B)   begin $display("  ts=%012h != 1f1aced9f07b", cap_ts); errors=errors+1; ok=0; end
                if (cap_oref  !== 64'd42)             begin $display("  oref=%0d != 42", cap_oref); errors=errors+1; ok=0; end
                if (cap_side  !== 8'h42)              begin $display("  side=%02h != 42 (B)", cap_side); errors=errors+1; ok=0; end
                if (cap_stock !== 64'h4141504C20202020) begin $display("  stock=%016h != AAPL", cap_stock); errors=errors+1; ok=0; end
                if (cap_price !== 32'd1502500)        begin $display("  price=%0d != 1502500", cap_price); errors=errors+1; ok=0; end
            end
            if (ok) $display("[%0t] PASS %0s: all fields correct", $time, label);
        end
    endtask

    initial begin
        $dumpfile("itch_parser_tb.vcd");
        $dumpvars(0, itch_parser_tb);
        #50;

        // T1: real Add Order, price 0x0016ed24 = 1502500 > threshold
        saw_signal = 0;
        send_real_add_order(32'h0016ED24);
        repeat(6) @(negedge clk);
        check_all("T1-real-add-order");

        // T2: same message but price below threshold (500000) → NO signal
        saw_signal = 0;
        send_real_add_order(32'd500000);
        repeat(6) @(negedge clk);
        if (!saw_signal) $display("[%0t] PASS T2: below threshold, no signal", $time);
        else begin $display("[%0t] FAIL T2: below threshold but signal received", $time); errors=errors+1; end

        // T3: second real message (leftover/reset check)
        saw_signal = 0;
        send_real_add_order(32'h0016ED24);
        repeat(6) @(negedge clk);
        check_all("T3-second-message");

        if (errors==0) $display("\n[%0t] ALL TESTS PASS", $time);
        else           $display("\n[%0t] %0d ERRORS", $time, errors);
        $finish;
    end
endmodule