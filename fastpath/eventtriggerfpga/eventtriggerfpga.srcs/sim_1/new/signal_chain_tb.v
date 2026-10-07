
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/17/2026 05:48:28 PM
// Design Name: 
// Module Name: signal_chain_tb
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

module signal_chain_tb;
    reg          clk = 0, rst = 0;
    reg          signal = 0;
    reg  [7:0]   msg_type = 0;
    reg  [47:0]  msg_timestamp = 0;
    reg  [63:0]  msg_orderref = 0;
    reg  [7:0]   msg_indicator = 0;
    reg  [63:0]  msg_stock = 0;
    reg  [31:0]  msg_price = 0;
    reg          m_axis_tready = 0;

    // signal_to_pack -> fifo
    wire [231:0] pack_tdata;
    wire         pack_tvalid;
    wire         fifo_s_tready;

    // fifo -> serializer
    wire [231:0] fifo_m_tdata;
    wire         fifo_m_tvalid;
    wire         ser_fifo_tready;

    // serializer -> tx
    wire [7:0]   tx_tdata;
    wire         tx_tvalid;
    wire         tx_tlast;

    integer errors = 0;
    reg [7:0]  captured [0:28];
    integer    cap_count;
    reg        capturing;

    // --- DUT 1: signal_to_pack ---
    signal_to_pack pack (
        .clk(clk), .rst(rst),
        .m_axis_tready(fifo_s_tready),          // FIFO fullness
        .msg_type(msg_type), .msg_timestamp(msg_timestamp),
        .msg_orderref(msg_orderref), .msg_indicator(msg_indicator),
        .msg_stock(msg_stock), .msg_price(msg_price), .signal(signal),
        .m_axis_stdata(pack_tdata),
        .m_axis_ready(),                        // unused (you have this port)
        .m_axis_tvalid(pack_tvalid),
        .m_axis_tlast()                         // last not needed for the FIFO
    );

    // --- DUT 2: axis_fifo (232-bit) ---
    axis_fifo #(
        .DEPTH(16), .DATA_WIDTH(232),
        .KEEP_ENABLE(0), .LAST_ENABLE(0),
        .ID_ENABLE(0), .DEST_ENABLE(0), .USER_ENABLE(0), .FRAME_FIFO(0)
    ) fifo (
        .clk(clk), .rst(rst),
        .s_axis_tdata(pack_tdata), .s_axis_tkeep(0),
        .s_axis_tvalid(pack_tvalid), .s_axis_tready(fifo_s_tready),
        .s_axis_tlast(1'b0), .s_axis_tid(0), .s_axis_tdest(0), .s_axis_tuser(0),
        .m_axis_tdata(fifo_m_tdata), .m_axis_tkeep(),
        .m_axis_tvalid(fifo_m_tvalid), .m_axis_tready(ser_fifo_tready),
        .m_axis_tlast(), .m_axis_tid(), .m_axis_tdest(), .m_axis_tuser(),
        .status_overflow(), .status_bad_frame(), .status_good_frame()
    );

    // --- DUT 3: serializer ---
    signal_pack_serializer ser (
        .clk(clk), .rst(rst),
        .fifo_tdata(fifo_m_tdata), .fifo_tvalid(fifo_m_tvalid),
        .fifo_tready(ser_fifo_tready),
        .m_axis_tready(m_axis_tready),
        .m_axis_tdata(tx_tdata), .m_axis_tvalid(tx_tvalid), .m_axis_tlast(tx_tlast)
    );

    always #5 clk = ~clk;

    // Byte capture
    always @(posedge clk) begin
        if (capturing && tx_tvalid && m_axis_tready) begin
            if (cap_count < 29) begin
                captured[cap_count] = tx_tdata;
                if (tx_tlast && cap_count != 28) begin
                    $display("[%0t] FAIL: tlast early (byte %0d)", $time, cap_count);
                    errors=errors+1;
                end
                if (!tx_tlast && cap_count == 28) begin
                    $display("[%0t] FAIL: no tlast on last byte", $time);
                    errors=errors+1;
                end
            end
            cap_count = cap_count + 1;
        end
    end

    task do_reset;
        begin
            capturing=0; @(negedge clk); rst=1; signal=0; m_axis_tready=0;
            repeat(4) @(negedge clk); rst=0; repeat(2) @(negedge clk);
        end
    endtask

    // Issue a signal, load the fields, pull 29 bytes from TX
    task drive_and_drain;
        input [7:0]  t;
        input [47:0] ts;
        input [63:0] oref;
        input [7:0]  side;
        input [63:0] stock;
        input [31:0] price;
        integer guard;
        begin
            cap_count=0; capturing=1; m_axis_tready=1;
            @(negedge clk);
            msg_type=t; msg_timestamp=ts; msg_orderref=oref;
            msg_indicator=side; msg_stock=stock; msg_price=price;
            signal=1;
            @(negedge clk); signal=0;
            // wait until 29 bytes come out
            guard=0;
            while (cap_count < 29 && guard < 500) begin @(negedge clk); guard=guard+1; end
            capturing=0; @(negedge clk);
        end
    endtask

    // Build the expected record (pack order: [price,stock,side,oref,ts,type,MAGIC], MAGIC at the bottom)
    task check;
        input [7:0]  t;
        input [47:0] ts;
        input [63:0] oref;
        input [7:0]  side;
        input [63:0] stock;
        input [31:0] price;
        input [127:0] label;
        reg [231:0] exp;
        integer i; reg ok;
        begin
            exp = {price, stock, side, oref, ts, t, 8'hBB};
            ok=1;
            if (cap_count != 29) begin
                $display("[%0t] FAIL %0s: %0d bytes (expected 29)", $time, label, cap_count);
                errors=errors+1; ok=0;
            end else for (i=0;i<29;i=i+1) begin
                if (captured[i] !== exp[i*8 +: 8]) begin
                    $display("[%0t] FAIL %0s: byte %0d=%02h, expected %02h",
                             $time, label, i, captured[i], exp[i*8 +: 8]);
                    errors=errors+1; ok=0;
                end
            end
            if (ok) $display("[%0t] PASS %0s (magic=byte0=%02h)", $time, label, captured[0]);
        end
    endtask

    initial begin
        $dumpfile("signal_chain_tb.vcd");
        $dumpvars(0, signal_chain_tb);

        // T1: fully populated record
        do_reset;
        drive_and_drain(8'h01, 48'h123456789ABC, 64'h1122334455667788,
                        "B", 64'h4141504C20202020, 32'd1234500);
        check(8'h01, 48'h123456789ABC, 64'h1122334455667788,
              "B", 64'h4141504C20202020, 32'd1234500, "T1");

        // T2: different record - leakage/leftover check
        do_reset;
        drive_and_drain(8'h01, 48'hAABBCCDDEEFF, 64'hDEADBEEFCAFEBABE,
                        "S", 64'h4D53465420202020, 32'd2000000);
        check(8'h01, 48'hAABBCCDDEEFF, 64'hDEADBEEFCAFEBABE,
              "S", 64'h4D53465420202020, 32'd2000000, "T2");

        if (errors==0) $display("\n[%0t] ALL TESTS PASS", $time);
        else           $display("\n[%0t] %0d ERRORS", $time, errors);
        $finish;
    end
endmodule