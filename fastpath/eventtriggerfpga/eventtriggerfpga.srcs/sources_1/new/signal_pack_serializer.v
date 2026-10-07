`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: dfix
// 
// Create Date: 09/17/2026 12:28:40 PM
// Design Name: 
// Module Name: signal_pack_serializer
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

module signal_pack_serializer(
    input wire clk,
    input wire rst,
    
    // fifo
    input wire [263:0] fifo_tdata, // 264 bit
    input wire fifo_tvalid,
    output reg fifo_tready,
        
    // axis
    input  wire m_axis_tready,
    
    output reg [7:0] m_axis_tdata,
    output reg m_axis_tvalid,    
    output reg m_axis_tlast
    
);

    localparam IDLE = 3'd0;
    localparam SER = 3'd1;
    
    reg [2:0] state = IDLE;
    
    reg [263:0] tdata_reg = 0;
    reg [6:0] offset_idx = 0;
    
    always @(posedge clk) begin
    
        if (rst) begin
            offset_idx <= 0;
            
            tdata_reg <= 0;
            m_axis_tdata <= 0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast <= 1'b0;
            
            fifo_tready <= 1'b1;
            
            state <= IDLE;
        end else begin
        
            case (state)
                IDLE: begin
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast <= 1'b0;
                    fifo_tready <= 1'b1;
                    
                    if (fifo_tvalid && fifo_tready) begin
                        tdata_reg <= fifo_tdata;
                        fifo_tready <= 1'b0;
                        offset_idx <= 0;
                    
                        state <= SER;
                    end    
                end
                
                SER: begin
                    if (m_axis_tready) begin
                    
                        offset_idx <= offset_idx + 1'b1;
                        m_axis_tdata <= tdata_reg[(32-offset_idx)*8 +: 8];
                        
                        m_axis_tvalid <= 1'b1;
                        
                        if (offset_idx == 32) begin // 264 bit / 8;
                            m_axis_tlast <= 1'b1;
                            state <= IDLE;
                        end else
                            m_axis_tlast <= 1'b0;
                    end
                end
                
                default: state <= IDLE;
            endcase        
        end // else rst

    end
endmodule

