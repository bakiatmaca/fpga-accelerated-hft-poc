
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/17/2026 09:50:13 PM
// Design Name: 
// Module Name: ser_fifo_tb
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

module ser_fifo_tb;
    reg          clk = 0, rst = 0;

    // FIFO input (write) side
    reg  [231:0] fin_tdata = 0;
    reg          fin_tvalid = 0;
    wire         fin_tready;

    // FIFO -> serializer intermediate signals
    wire [231:0] f2s_tdata;
    wire         f2s_tvalid;
    wire         f2s_tready;

    // serializer -> TX
    wire [7:0]   tx_tdata;
    wire         tx_tvalid;
    wire         tx_tlast;
    reg          tx_tready = 0;

    integer errors = 0;
    reg [7:0]  captured [0:28];
    integer    cap_count;
    reg        capturing;

    // --- axis_fifo: with the parameters from fpga_core ---
    axis_fifo #(
        .DEPTH(128),
        .DATA_WIDTH(232),
        .KEEP_ENABLE(0),
        .LAST_ENABLE(0),
        .ID_ENABLE(0),
        .DEST_ENABLE(0),
        .USER_ENABLE(0),
        .FRAME_FIFO(0)
    ) fifo (
        .clk(clk), .rst(rst),
        .s_axis_tdata(fin_tdata), .s_axis_tkeep(0),
        .s_axis_tvalid(fin_tvalid), .s_axis_tready(fin_tready),
        .s_axis_tlast(1'b0), .s_axis_tid(0), .s_axis_tdest(0), .s_axis_tuser(0),
        .m_axis_tdata(f2s_tdata), .m_axis_tkeep(),
        .m_axis_tvalid(f2s_tvalid), .m_axis_tready(f2s_tready),
        .m_axis_tlast(), .m_axis_tid(), .m_axis_tdest(), .m_axis_tuser(),
        .pause_req(1'b0), .pause_ack(),
        .status_depth(), .status_depth_commit(),
        .status_overflow(), .status_bad_frame(), .status_good_frame()
    );

    // --- serializer ---
    signal_pack_serializer ser (
        .clk(clk), .rst(rst),
        .fifo_tdata(f2s_tdata), .fifo_tvalid(f2s_tvalid), .fifo_tready(f2s_tready),
        .m_axis_tdata(tx_tdata), .m_axis_tready(tx_tready),
        .m_axis_tvalid(tx_tvalid), .m_axis_tlast(tx_tlast)
    );

    always #5 clk = ~clk;

    // Byte capture
    always @(posedge clk) begin
        if (capturing && tx_tvalid && tx_tready) begin
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

    reg [231:0] rec;
    integer i;
    reg [7:0] expected;
    initial begin
        $dumpfile("ser_fifo_tb.vcd");
        $dumpvars(0, ser_fifo_tb);

        // Known record: byte i = 0xB0+i (byte0 at the bottom, your pack order)
        rec = 0;
        for (i=0;i<29;i=i+1) rec[i*8 +: 8] = 8'hB0 + i[7:0];

        // Reset
        rst = 1; capturing = 0; cap_count = 0;
        repeat(4) @(negedge clk); rst = 0; repeat(4) @(negedge clk);

        // Write ONE record into the FIFO
        @(negedge clk);
        fin_tdata = rec; fin_tvalid = 1'b1;
        @(negedge clk);
        while (fin_tready !== 1'b1) @(negedge clk);  // until the write is accepted
        fin_tvalid = 1'b0;

        // Wait for the serializer to pull the record and output the bytes
        repeat(6) @(negedge clk);

        // Drain TX (with ready delayed by a few cycles - backpressure)
        capturing = 1; cap_count = 0;
        for (i=0; i<200 && cap_count<29; i=i+1) begin
            tx_tready = (i % 3 != 0);   // intermittent delay
            @(negedge clk);
        end
        tx_tready = 0; capturing = 0;
        @(negedge clk);

        // Result
        if (cap_count != 29) begin
            $display("[%0t] FAIL: %0d bytes received, expected 29 (SERIALIZER IS NOT PULLING FROM FIFO)",
                     $time, cap_count);
            errors=errors+1;
        end else begin
            for (i=0;i<29;i=i+1) begin
                expected = rec[i*8 +: 8];
                if (captured[i] !== expected) begin
                    $display("[%0t] FAIL: byte %0d = %02h, expected %02h",
                             $time, i, captured[i], expected);
                    errors=errors+1;
                end
            end
        end

        if (errors==0) $display("\n[%0t] PASS: serializer pulled the record from FIFO, 29 bytes correct", $time);
        else           $display("\n[%0t] %0d ERRORS", $time, errors);
        $finish;
    end
endmodule