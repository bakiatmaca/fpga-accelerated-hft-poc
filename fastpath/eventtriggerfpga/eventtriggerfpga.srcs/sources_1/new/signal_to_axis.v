//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/08/2026 10:05:32 AM
// Design Name: 
// Module Name: signal_to_axis
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

module signal_to_axis(
    input wire clk,
    input wire rst,   
    input wire m_axis_tready,
    input wire signal,    
    //input wire [7:0] msg_type,
    //input wire [15:0] msg_price,

    output reg [7:0] m_axis_tdata,
    output reg m_axis_tvalid,
    output reg m_axis_tlast
);
    
    localparam IDLE = 3'd0;
    localparam SEND = 3'd1;
    reg [2:0] state = IDLE;
    reg signal_reg = 0;
    
    always @(posedge clk) begin
        if (rst) begin
            m_axis_tdata <= 0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast <= 1'b0;
            signal_reg <= 0;
            state <= IDLE;
        end else begin
            case (state)
                IDLE: begin
                    if (signal || signal_reg) begin
                        m_axis_tdata <= "B";
                        m_axis_tvalid <= 1'b1;
                        m_axis_tlast <= 1'b1;
                        signal_reg <= 0;
                        state <= SEND;
                    end
                end
                SEND: begin
                    if (signal && !signal_reg) begin // keep only 1 signal 
                        signal_reg <= signal;
                    end
                    
                    if (m_axis_tready && m_axis_tvalid) begin
                        m_axis_tdata <= 0;
                        m_axis_tvalid <= 1'b0;
                        m_axis_tlast <= 1'b0;
                        state <= IDLE;
                    end
                end       
                default: state <= IDLE;
            endcase
        end  
    end
endmodule