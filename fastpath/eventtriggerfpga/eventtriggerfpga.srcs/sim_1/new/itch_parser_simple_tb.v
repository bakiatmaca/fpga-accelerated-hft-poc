//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/16/2026 02:20:13 PM
// Design Name: 
// Module Name: itch_parser_simple_tb
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

module itch_parser_simple_tb;
    reg         clk = 0;
    reg  [7:0]  rx_data = 0;
    reg         rx_ready = 0;
    wire [7:0]  msg_type;
    wire [31:0] msg_price;
    wire        signal;

    integer     errors = 0;
    reg         saw_signal;
    reg  [31:0] captured_price;

    itch_parser #(.THRESHOLD(32'd1000000)) dut (
        .clk(clk), .rx_data(rx_data), .rx_ready(rx_ready),
        .msg_type(msg_type), .msg_price(msg_price), .signal(signal)
    );

    always #5 clk = ~clk;

    // Feed one byte (rx_ready for 1 cycle), then a gap
    task feed;
        input [7:0] b;
        begin
            @(negedge clk); rx_data = b; rx_ready = 1'b1;
            @(negedge clk); rx_ready = 1'b0;
            @(negedge clk);   // gap between bytes
        end
    endtask

    // capture signal and price
    always @(posedge clk) begin
        if (signal) begin
            saw_signal     <= 1'b1;
            captured_price <= msg_price;
        end
    end

    // Send a 36-byte Add Order. price is 4-byte big-endian.
    task send_add_order;
        input [7:0]  side;      // 'B' / 'S'
        input [31:0] price;     // raw Price(4)
        integer i;
        begin
            feed(8'h41);                    // 0: type 'A'
            feed(8'h00); feed(8'h01);       // 1-2: Stock Locate = 1
            feed(8'h00); feed(8'h00);       // 3-4: Tracking = 0
            // 5-10: Timestamp (6 bytes) - arbitrary but fixed
            feed(8'h00); feed(8'h00); feed(8'h12);
            feed(8'h34); feed(8'h56); feed(8'h78);
            // 11-18: Order Ref (8 bytes)
            feed(8'h00); feed(8'h00); feed(8'h00); feed(8'h00);
            feed(8'h00); feed(8'h00); feed(8'h00); feed(8'h2A);
            feed(side);                     // 19: Buy/Sell
            // 20-23: Shares = 100
            feed(8'h00); feed(8'h00); feed(8'h00); feed(8'h64);
            // 24-31: Stock "AAPL    "
            feed("A"); feed("A"); feed("P"); feed("L");
            feed(" "); feed(" "); feed(" "); feed(" ");
            // 32-35: Price (big-endian)
            feed(price[31:24]); feed(price[23:16]);
            feed(price[15:8]);  feed(price[7:0]);
        end
    endtask

    initial begin
        $dumpfile("itch_parser_simple_tb.vcd");
        $dumpvars(0, itch_parser_simple_tb);
        #50;

        // === Test 1: price 1234500 ($123.45) > threshold 1000000 → signal + correct price ===
        saw_signal = 0; captured_price = 0;
        send_add_order("B", 32'd1234500);
        repeat(6) @(negedge clk);
        if (!saw_signal) begin
            $display("[%0t] FAIL t1: no signal received", $time); errors=errors+1;
        end else if (captured_price !== 32'd1234500) begin
            $display("[%0t] FAIL t1: price=%0d, expected 1234500 (OFF-BY-ONE?)",
                     $time, captured_price); errors=errors+1;
        end else
            $display("[%0t] PASS: price=1234500 output correctly, signal received", $time);

        // === Test 2: price 500000 ($50.00) < threshold → NO signal ===
        saw_signal = 0; captured_price = 0;
        send_add_order("B", 32'd500000);
        repeat(6) @(negedge clk);
        if (saw_signal) begin
            $display("[%0t] FAIL t2: below threshold but signal received (price=%0d)",
                     $time, captured_price); errors=errors+1;
        end else
            $display("[%0t] PASS: below threshold (500000) → no signal", $time);

        // === Test 3: second message parses cleanly - proof of state/price_reg reset ===
        saw_signal = 0; captured_price = 0;
        send_add_order("S", 32'd2000000);
        repeat(6) @(negedge clk);
        if (saw_signal && captured_price === 32'd2000000)
            $display("[%0t] PASS: second message clean, price=2000000", $time);
        else begin
            $display("[%0t] FAIL t3: price=%0d, signal=%b (reset issue?)",
                     $time, captured_price, saw_signal); errors=errors+1;
        end

        if (errors==0) $display("[%0t] ALL TESTS PASS", $time);
        else           $display("[%0t] %0d ERRORS", $time, errors);
        $finish;
    end
endmodule
