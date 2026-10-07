
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/17/2026 09:55:17 PM
// Design Name: 
// Module Name: pack_chain_tb
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

module pack_chain_tb;
    reg          clk = 0, rst = 0;
    reg          signal = 0;
    reg  [7:0]   msg_type = 0;
    reg  [47:0]  msg_ts = 0;
    reg  [63:0]  msg_oref = 0;
    reg  [7:0]   msg_side = 0;
    reg  [63:0]  msg_stock = 0;
    reg  [31:0]  msg_price = 0;

    // pack -> fifo
    wire [231:0] sp_tdata;
    wire         sp_tvalid;
    wire         sp_tready;

    // fifo -> serializer
    wire [231:0] sps_tdata;
    wire         sps_tvalid;
    wire         sps_tready;

    // serializer -> tx
    wire [7:0]   tx_tdata;
    wire         tx_tvalid, tx_tlast;
    reg          tx_tready = 0;

    integer errors = 0;
    reg [7:0]  captured [0:28];
    integer    cap_count;
    reg        capturing;

    signal_to_pack sig_pack (
        .clk(clk), .rst(rst),
        .m_axis_tready(sp_tready),
        .msg_type(msg_type), .msg_timestamp(msg_ts), .msg_orderref(msg_oref),
        .msg_indicator(msg_side), .msg_stock(msg_stock), .msg_price(msg_price),
        .signal(signal),
        .m_axis_stdata(sp_tdata), .m_axis_tvalid(sp_tvalid), .m_axis_tlast()
    );

    axis_fifo #(
        .DEPTH(128), .DATA_WIDTH(232), .KEEP_ENABLE(0), .LAST_ENABLE(0),
        .ID_ENABLE(0), .DEST_ENABLE(0), .USER_ENABLE(0), .FRAME_FIFO(0)
    ) signal_fifo (
        .clk(clk), .rst(rst),
        .s_axis_tdata(sp_tdata), .s_axis_tvalid(sp_tvalid), .s_axis_tready(sp_tready),
        .s_axis_tid(0), .s_axis_tdest(0), .s_axis_tuser(0), .s_axis_tkeep(0), .s_axis_tlast(0),
        .m_axis_tdata(sps_tdata), .m_axis_tvalid(sps_tvalid), .m_axis_tready(sps_tready),
        .m_axis_tid(), .m_axis_tdest(), .m_axis_tuser(), .m_axis_tkeep(), .m_axis_tlast(),
        .pause_req(1'b0), .pause_ack(),
        .status_depth(), .status_depth_commit(),
        .status_overflow(), .status_bad_frame(), .status_good_frame()
    );

    signal_pack_serializer sig_pac (
        .clk(clk), .rst(rst),
        .fifo_tdata(sps_tdata), .fifo_tvalid(sps_tvalid), .fifo_tready(sps_tready),
        .m_axis_tdata(tx_tdata), .m_axis_tready(tx_tready),
        .m_axis_tvalid(tx_tvalid), .m_axis_tlast(tx_tlast)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (capturing && tx_tvalid && tx_tready) begin
            if (cap_count < 29) captured[cap_count] = tx_tdata;
            cap_count = cap_count + 1;
        end
    end

    integer i;
    reg [7:0] exp;
    initial begin
        $dumpfile("pack_chain_tb.vcd");
        $dumpvars(0, pack_chain_tb);

        rst = 1; capturing = 0; cap_count = 0;
        repeat(4) @(negedge clk); rst = 0; repeat(4) @(negedge clk);

        // Set up the fields first (assume the parser has the fields ready BEFORE signal)
        @(negedge clk);
        msg_type = 8'h41; msg_ts = 48'h1F1ACED9F07B; msg_oref = 64'd42;
        msg_side = 8'h42; msg_stock = 64'h4141504C20202020; msg_price = 32'd1502500;

        // signal pulse (1 cycle)
        @(negedge clk); signal = 1'b1;
        @(negedge clk); signal = 1'b0;

        // wait for pack to write into the FIFO + serializer to pull it
        repeat(10) @(negedge clk);

        // Drain TX
        capturing = 1; cap_count = 0;
        for (i=0; i<200 && cap_count<29; i=i+1) begin
            tx_tready = 1'b1;
            @(negedge clk);
        end
        tx_tready = 0; capturing = 0;
        @(negedge clk);

        // Expected: {price, stock, side, oref, ts, type, MAGIC=BB}
        exp = 8'hBB;
        if (cap_count != 29) begin
            $display("[%0t] FAIL: %0d bytes (expected 29) - PACK IS NOT WRITING TO FIFO", $time, cap_count);
            errors=errors+1;
        end else begin
            // byte 0 = magic BB
            if (captured[0] !== 8'hBB) begin
                $display("byte0=%02h != BB", captured[0]); errors=errors+1; end
            // byte 1 = type 41
            if (captured[1] !== 8'h41) begin
                $display("byte1=%02h != 41", captured[1]); errors=errors+1; end
            // last 4 bytes price 0x0016ED24
            if (captured[25]!==8'h00||captured[26]!==8'h16||captured[27]!==8'hED||captured[28]!==8'h24) begin
                $display("price bytes wrong: %02h %02h %02h %02h",
                         captured[25],captured[26],captured[27],captured[28]); errors=errors+1; end
        end

        if (errors==0) $display("\n[%0t] PASS: pack->fifo->serialize full chain correct", $time);
        else           $display("\n[%0t] %0d ERRORS", $time, errors);
        $finish;
    end
endmodule