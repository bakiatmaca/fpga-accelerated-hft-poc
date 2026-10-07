
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/08/2026 12:52:10 PM
// Design Name: 
// Module Name: signal_to_axis_tb
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

module signal_to_axis_tb;
    reg        clk = 0, rst = 0;
    reg        signal = 0;
    reg        m_axis_tready = 0;
    wire [7:0] m_axis_tdata;
    wire       m_axis_tvalid;
    wire       m_axis_tlast;

    integer    errors = 0;
    reg [7:0]  captured;
    reg        got_transfer;

    signal_to_axis dut (
        .clk(clk), .rst(rst),
        .signal(signal),
        .m_axis_tready(m_axis_tready),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tlast(m_axis_tlast)
    );

    always #5 clk = ~clk;

    // Capture the transfer: in the cycle where tvalid && tready, are 'B' and tlast correct?
    always @(posedge clk) begin
        if (m_axis_tvalid && m_axis_tready) begin
            captured     <= m_axis_tdata;
            got_transfer <= 1'b1;
            if (m_axis_tdata !== "B") begin
                $display("[%0t] FAIL: tdata=%h, expected 'B'", $time, m_axis_tdata);
                errors = errors + 1;
            end
            if (m_axis_tlast !== 1'b1) begin
                $display("[%0t] FAIL: tlast=%b, expected 1", $time, m_axis_tlast);
                errors = errors + 1;
            end
        end
    end

    // Generate a signal pulse (1 cycle)
    task pulse_signal;
        begin
            @(negedge clk); signal = 1'b1;
            @(negedge clk); signal = 1'b0;
        end
    endtask

    initial begin
        $dumpfile("signal_to_axis_tb.vcd");
        $dumpvars(0, signal_to_axis_tb);

        rst = 1; repeat(4) @(negedge clk); rst = 0;
        repeat(2) @(negedge clk);

        // === Test 1: tready 1 IMMEDIATELY (normal, no backpressure) ===
        got_transfer = 0; m_axis_tready = 1'b1;
        pulse_signal;
        repeat(6) @(negedge clk);
        if (got_transfer) $display("[%0t] PASS: normal send, 'B' transmitted", $time);
        else begin $display("[%0t] FAIL t1: no transfer occurred", $time); errors=errors+1; end

        // === Test 2: DELAYED tready (backpressure - hold-and-wait test) ===
        got_transfer = 0; m_axis_tready = 1'b0;   // receiver NOT READY
        pulse_signal;
        // hold tready=0 for a few cycles: dut must hold 'B', tvalid must not drop
        repeat(5) @(negedge clk);
        if (m_axis_tvalid !== 1'b1) begin
            $display("[%0t] FAIL t2: tvalid dropped while waiting for tready!", $time);
            errors = errors + 1;
        end
        if (m_axis_tdata !== "B") begin
            $display("[%0t] FAIL t2: tdata changed while waiting for tready!", $time);
            errors = errors + 1;
        end
        m_axis_tready = 1'b1;                      // now the receiver is ready
        repeat(4) @(negedge clk);
        if (got_transfer) $display("[%0t] PASS: 'B' held and transmitted under backpressure", $time);
        else begin $display("[%0t] FAIL t2: no transfer occurred", $time); errors=errors+1; end

        // === Test 3: two consecutive signals (spaced apart) ===
        got_transfer = 0; m_axis_tready = 1'b1;
        pulse_signal;
        repeat(4) @(negedge clk);
        if (got_transfer) $display("[%0t] PASS: second signal also transmitted", $time);
        else begin $display("[%0t] FAIL t3: no transfer occurred", $time); errors=errors+1; end

        if (errors==0) $display("[%0t] ALL TESTS PASS", $time);
        else           $display("[%0t] %0d ERRORS", $time, errors);
        $finish;
    end
endmodule


