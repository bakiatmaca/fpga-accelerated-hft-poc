
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

module mold_chain_tb;
    reg         clk = 0, rst = 0;
    reg  [7:0]  rx_data = 0;
    reg         rx_ready = 0;
    reg         tlast = 0;

    // intermediate signals framer → parser
    wire [7:0]  msg_data;
    wire        msg_ready;

    // parser outputs
    wire [7:0]  msg_type;
    wire [31:0] msg_price;
    wire        signal;

    integer     errors = 0;
    integer     signal_count = 0;
    reg  [31:0] last_price = 0;

    // DUT 1: framer
    mold_framer framer (
        .clk(clk), .rst(rst),
        .rx_data(rx_data), .rx_ready(rx_ready),
        .s_axis_tlast(tlast),
        .msg_data(msg_data), .msg_ready(msg_ready)
    );

    // DUT 2: parser (fed by the framer's output)
    itch_parser #(.THRESHOLD(32'd1000000)) parser (
        .clk(clk), .rx_data(msg_data), .rx_ready(msg_ready),
        .msg_type(msg_type), .msg_price(msg_price), .signal(signal)
    );

    always #5 clk = ~clk;

    // Count every signal + capture the price
    always @(posedge clk) begin
        if (signal) begin
            signal_count <= signal_count + 1;
            last_price   <= msg_price;
        end
    end

    // Feed one byte (with gap), tlast on the last byte
    task feed;
        input [7:0] b;
        input       last;
        begin
            @(negedge clk); rx_data = b; rx_ready = 1'b1; tlast = last;
            @(negedge clk); rx_ready = 1'b0; tlast = 1'b0;
            @(negedge clk);
        end
    endtask

    // --- One Add Order message BODY (36 bytes), price parameterized ---
    // NOTE: the MoldUDP length prefix / header is sent SEPARATELY; this is only the body.
    task feed_add_order_body;
        input [7:0]  side;
        input [31:0] price;
        input        last;   // is this the last byte of the packet (tlast)
        begin
            feed(8'h41, 0);                              // type 'A'
            feed(8'h00,0); feed(8'h01,0);               // stock locate
            feed(8'h00,0); feed(8'h00,0);               // tracking
            feed(8'h00,0); feed(8'h00,0); feed(8'h12,0);
            feed(8'h34,0); feed(8'h56,0); feed(8'h78,0);// timestamp
            feed(8'h00,0); feed(8'h00,0); feed(8'h00,0); feed(8'h00,0);
            feed(8'h00,0); feed(8'h00,0); feed(8'h00,0); feed(8'h2A,0); // order ref
            feed(side,0);                                // buy/sell
            feed(8'h00,0); feed(8'h00,0); feed(8'h00,0); feed(8'h64,0); // shares
            feed("A",0); feed("A",0); feed("P",0); feed("L",0);
            feed(" ",0); feed(" ",0); feed(" ",0); feed(" ",0);         // stock
            feed(price[31:24],0); feed(price[23:16],0);
            feed(price[15:8],0);  feed(price[7:0], last);               // price + tlast
        end
    endtask

    // --- MoldUDP64 header (20 bytes), message_count parameterized ---
    task feed_mold_header;
        input [15:0] count;
        integer i;
        begin
            for (i=0; i<10; i=i+1) feed(8'h20, 0);      // session: 10x space
            for (i=0; i<8;  i=i+1) feed(8'h00, 0);      // sequence: 8 bytes (0)
            feed(count[15:8], 0); feed(count[7:0], 0);  // message count (2 bytes)
        end
    endtask

    initial begin
        $dumpfile("mold_chain_tb.vcd");
        $dumpvars(0, mold_chain_tb);
        #50;

        // === Test 1: single-message packet, price 1234500 > threshold → 1 signal ===
        signal_count = 0;
        feed_mold_header(16'd1);
        feed(8'h00,0); feed(8'd36,0);                   // msg length = 36
        feed_add_order_body("B", 32'd1234500, 1);       // last byte tlast
        repeat(8) @(negedge clk);
        if (signal_count==1 && last_price==32'd1234500)
            $display("[%0t] PASS: single message, 1 signal, price=1234500", $time);
        else begin $display("[%0t] FAIL t1: cnt=%0d price=%0d",
                   $time, signal_count, last_price); errors=errors+1; end

        repeat(10) @(negedge clk);

        // === Test 2: single packet with TWO messages - the real test ===
        // msg 1 price 500000 (<threshold, no signal), msg 2 2000000 (>threshold, signal)
        signal_count = 0;
        feed_mold_header(16'd2);
        feed(8'h00,0); feed(8'd36,0);                   // msg 1 length
        feed_add_order_body("B", 32'd500000, 0);        // msg 1 (no tlast)
        feed(8'h00,0); feed(8'd36,0);                   // msg 2 length
        feed_add_order_body("S", 32'd2000000, 1);       // msg 2 + tlast
        repeat(8) @(negedge clk);
        if (signal_count==1 && last_price==32'd2000000)
            $display("[%0t] PASS: two messages, correct signal (2000000), 500000 filtered out", $time);
        else begin $display("[%0t] FAIL t2: cnt=%0d price=%0d (expected cnt=1)",
                   $time, signal_count, last_price); errors=errors+1; end

        repeat(10) @(negedge clk);

        // === Test 3: back-to-back second packet - proof of GET_WAIT return / reset ===
        signal_count = 0;
        feed_mold_header(16'd1);
        feed(8'h00,0); feed(8'd36,0);
        feed_add_order_body("B", 32'd1500000, 1);
        repeat(8) @(negedge clk);
        if (signal_count==1 && last_price==32'd1500000)
            $display("[%0t] PASS: second packet clean, price=1500000", $time);
        else begin $display("[%0t] FAIL t3: cnt=%0d price=%0d",
                   $time, signal_count, last_price); errors=errors+1; end

        if (errors==0) $display("[%0t] ALL TESTS PASS", $time);
        else           $display("[%0t] %0d ERRORS", $time, errors);
        $finish;
    end
endmodule