
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/17/2026 04:31:29 PM
// Design Name: 
// Module Name: signal_pack_serializer_tb
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

module signal_pack_serializer_tb;
    reg          clk = 0, rst = 0;
    reg  [231:0] fifo_tdata = 0;
    reg          fifo_tvalid = 0;
    wire         fifo_ready;
    reg          m_axis_tready = 0;
    wire [7:0]   m_axis_tdata;
    wire         m_axis_tvalid;
    wire         m_axis_tlast;

    integer errors = 0;
    integer idx;
    reg [7:0]  captured [0:28];
    integer    cap_count;
    reg        capturing;          // is capture active (after the record is received)

    signal_pack_serializer dut (
        .clk(clk), .rst(rst),
        .fifo_tdata(fifo_tdata), .fifo_tvalid(fifo_tvalid), .fifo_ready(fifo_ready),
        .m_axis_tready(m_axis_tready),
        .m_axis_tdata(m_axis_tdata), .m_axis_tvalid(m_axis_tvalid), .m_axis_tlast(m_axis_tlast)
    );

    always #5 clk = ~clk;

    // --- Byte capture: ONLY while capturing=1 and on an actual transfer ---
    always @(posedge clk) begin
        if (capturing && m_axis_tvalid && m_axis_tready) begin
            if (cap_count < 29) begin
                captured[cap_count] = m_axis_tdata;
                // tlast should be on the last byte (28) only
                if (m_axis_tlast && cap_count != 28) begin
                    $display("[%0t] FAIL: tlast early (byte %0d)", $time, cap_count);
                    errors = errors + 1;
                end
                if (!m_axis_tlast && cap_count == 28) begin
                    $display("[%0t] FAIL: no tlast on last byte", $time);
                    errors = errors + 1;
                end
            end
            cap_count = cap_count + 1;
        end
    end

    // --- AXI-Stream spec check: tvalid=1 & tready=0 -> in the next cycle
    //     tvalid must not drop, tdata must not change ---
    reg        prev_tvalid, prev_tready;
    reg  [7:0] prev_tdata;
    always @(posedge clk) begin
        prev_tvalid <= m_axis_tvalid;
        prev_tready <= m_axis_tready;
        prev_tdata  <= m_axis_tdata;
        if (capturing && prev_tvalid && !prev_tready) begin
            if (!m_axis_tvalid) begin
                $display("[%0t] FAIL: tvalid dropped (while waiting for tready) - SPEC VIOLATION", $time);
                errors = errors + 1;
            end
            if (m_axis_tdata !== prev_tdata) begin
                $display("[%0t] FAIL: tdata changed (while waiting for tready) - SPEC VIOLATION", $time);
                errors = errors + 1;
            end
        end
    end

    // --- Clean reset (at the start of each test) ---
    task do_reset;
        begin
            capturing = 0;
            @(negedge clk); rst = 1; m_axis_tready = 0; fifo_tvalid = 0;
            repeat(4) @(negedge clk);
            rst = 0;
            repeat(2) @(negedge clk);
        end
    endtask

    // --- Present the record, wait until the serializer takes it, then pull 29 bytes ---
    task load_and_drain;
        input [231:0] rec;
        input integer pattern;   // 0=always ready, 1=intermittent delay, 2=delay on last byte
        integer guard;
        begin
            cap_count = 0;

            // Present the record via the FIFO interface
            @(negedge clk); fifo_tdata = rec; fifo_tvalid = 1'b1;

            // Let the serializer take the record: wait until fifo_ready goes 0
            guard = 0;
            while (fifo_ready !== 1'b0 && guard < 50) begin
                @(negedge clk); guard = guard + 1;
            end
            fifo_tvalid = 1'b0;

            // NOW start capturing - record received, the first byte is coming
            capturing = 1;

            // Drive tready according to the pattern until 29 bytes are pulled
            guard = 0;
            while (cap_count < 29 && guard < 500) begin
                case (pattern)
                    0: m_axis_tready = 1'b1;
                    1: m_axis_tready = (guard[1:0] != 0);        // 0 intermittently
                    2: m_axis_tready = (cap_count == 28) ? guard[2] : 1'b1; // delay on last byte
                    default: m_axis_tready = 1'b1;
                endcase
                @(negedge clk);
                guard = guard + 1;
            end

            m_axis_tready = 1'b0;
            capturing = 0;
            @(negedge clk);
        end
    endtask

    task check_record;
        input [231:0] rec;
        input [127:0] label;
        integer i;
        reg [7:0] expected;
        reg ok;
        begin
            ok = 1;
            if (cap_count != 29) begin
                $display("[%0t] FAIL %0s: %0d bytes received, expected 29",
                         $time, label, cap_count);
                errors = errors + 1; ok = 0;
            end else begin
                for (i = 0; i < 29; i = i + 1) begin
                    expected = rec[i*8 +: 8];
                    if (captured[i] !== expected) begin
                        $display("[%0t] FAIL %0s: byte %0d = %02h, expected %02h",
                                 $time, label, i, captured[i], expected);
                        errors = errors + 1; ok = 0;
                    end
                end
            end
            if (ok) $display("[%0t] PASS %0s", $time, label);
        end
    endtask

    reg [231:0] rec1, rec2;
    initial begin
        $dumpfile("signal_pack_serializer_tb.vcd");
        $dumpvars(0, signal_pack_serializer_tb);

        rec1 = 0; rec2 = 0;
        for (idx = 0; idx < 29; idx = idx + 1) begin
            rec1[idx*8 +: 8] = 8'hA0 + idx[7:0];
            rec2[idx*8 +: 8] = 8'h10 + idx[7:0];
        end

        // T1: always ready
        do_reset;
        load_and_drain(rec1, 0);
        check_record(rec1, "T1-always-ready");

        // T2: intermittent backpressure
        do_reset;
        load_and_drain(rec2, 1);
        check_record(rec2, "T2-mid-delay");

        // T3: backpressure on the LAST BYTE (Bug 1 referee)
        do_reset;
        load_and_drain(rec1, 2);
        check_record(rec1, "T3-last-byte-delay");

        if (errors == 0) $display("\n[%0t] ALL TESTS PASS", $time);
        else             $display("\n[%0t] %0d ERRORS", $time, errors);
        $finish;
    end
endmodule