
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: dfix
// 
// Create Date: 09/17/2026 12:17:27 PM
// Design Name: 
// Module Name: signal_to_pack
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

module signal_to_pack(
    input wire clk,
    input wire rst,   
    input wire m_axis_tready,

    input wire [7:0] msg_type,
    input wire [47:0] msg_timestamp,
    input wire [63:0] msg_orderref,
    input wire [7:0] msg_indicator,
    input wire [31:0] msg_shares,    
    input wire [63:0] msg_stock,    
    input wire [31:0] msg_price,
    input wire signal,

    output reg [263:0] m_axis_stdata, // 264 bit
    output reg m_axis_ready,    
    output reg m_axis_tvalid,
    output reg m_axis_tlast
);
    
    localparam MAGIC_NUM = 8'hBB;
    
    localparam IDLE = 3'd0;
    localparam SEND = 3'd1;
    reg [2:0] state = IDLE;
    reg signal_reg = 0;
    
    always @(posedge clk) begin
        if (rst) begin
            m_axis_stdata <= 0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast <= 1'b0;
            m_axis_ready <= 1'b0;
            signal_reg <= 0;
            state <= IDLE;
        end else begin
            case (state)
                IDLE: begin
                    if (signal || signal_reg) begin
                        // serilize
                        m_axis_stdata <= {MAGIC_NUM, msg_type, msg_timestamp, msg_orderref, msg_indicator, msg_shares, msg_stock, msg_price}; 
                        
                        m_axis_tvalid <= 1'b1;
                        m_axis_tlast <= 1'b1;
                        m_axis_ready <= 1'b1;
                        signal_reg <= 0;
                        
                        state <= SEND;
                    end
                end
                SEND: begin
                    if (signal && !signal_reg) begin // keep only 1 signal 
                        signal_reg <= signal;
                    end
                    
                    if (m_axis_tready && m_axis_tvalid) begin
                        m_axis_stdata <= 0;
                        m_axis_tvalid <= 1'b0;
                        m_axis_ready <= 1'b0;
                        m_axis_tlast <= 1'b0;
                        state <= IDLE;
                    end
                end       
                default: state <= IDLE;
            endcase
        end  
    end
endmodule