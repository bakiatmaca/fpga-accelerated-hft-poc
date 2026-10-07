`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/07/2026 05:14:42 PM
// Design Name: 
// Module Name: axis_to_parser
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

module msg_parser #(
    parameter [15:0] THRESHOLD = 16'd1000    // price range: if it exceeds the range than send buy a signal
) (
    input wire clk,
    input wire [7:0] rx_data,
    input wire rx_ready,
    output reg msg_valid = 0,
    output reg msg_error = 0,
    output reg [7:0] msg_type = 0,
    output reg [15:0] msg_price = 0,
    output reg signal = 0
);

    localparam SYNC       = 8'hAB; // message prefix
    localparam TYPE_TRADE = 8'h54;   // 'T'

    localparam WAIT_SYNC = 3'd0;
    localparam GET_TYPE  = 3'd1;
    localparam GET_LEN   = 3'd2;
    localparam GET_PAY   = 3'd3;
    localparam GET_CSUM  = 3'd4;
    
    reg [2:0] state = WAIT_SYNC;
    reg [7:0] length = 0;
    reg [7:0] byte_idx = 0;
    reg [7:0] csum = 0;
    reg [7:0] type_reg = 0;
    reg [15:0] price_reg = 0;

    always @(posedge clk) begin

        msg_valid <= 1'b0;
        msg_error <= 1'b0;
        signal <= 1'b0;

        if (rx_ready) begin
            
            case (state)
                WAIT_SYNC: begin
                    if (rx_data == SYNC) begin
                        csum <= 8'd0;
                        state <= GET_TYPE;
                    end
                end
                GET_TYPE: begin
                    type_reg <= rx_data;
                    csum <= csum ^ rx_data;
                    state <= GET_LEN;
                end
                GET_LEN: begin
                    length <= rx_data;
                    csum <= csum ^ rx_data;
                    byte_idx <= 8'd0;
                    state <= (rx_data == 8'd0) ? GET_CSUM : GET_PAY;
                end
                GET_PAY: begin
                    csum <= csum ^ rx_data;

                    if (byte_idx == 8'd0) price_reg[15:8] <= rx_data;
                    if (byte_idx == 8'd1) price_reg[7:0]  <= rx_data;

                    if (byte_idx == length - 8'd1)
                        state <= GET_CSUM;

                    byte_idx <= byte_idx + 1'b1;
                end
                GET_CSUM: begin
                    if (rx_data == csum) begin
                        msg_valid <= 1'b1;
                        msg_type <= type_reg;
                        msg_price <= price_reg;

                        if (type_reg == TYPE_TRADE && price_reg > THRESHOLD)
                            signal <= 1'b1;
                            
                    end else begin
                        msg_error <= 1'b1;
                    end
                    state <= WAIT_SYNC;
                end
                default:  state <= WAIT_SYNC;
            endcase
        end
    end
endmodule