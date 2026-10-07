//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: dfix
// 
// Create Date: 09/11/2026 07:54:06 PM
// Design Name: 
// Module Name: mold_framer
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

module mold_framer(
    input wire clk,
    input wire rst,
    input wire [7:0] rx_data, //36 byte
    input wire rx_ready,
    output reg [7:0] msg_data = 0,
    output reg msg_ready = 0,
    output reg msg_start = 0
);
    
    localparam GET_WAIT = 2'd0;
    localparam GET_COUNT = 2'd1;
    localparam GET_LEN  = 2'd2;
    localparam GET_TRANS  = 2'd3;
    
    reg [2:0] state = GET_WAIT;
    
    reg [5:0] offset_idx = 0;
    reg [7:0] csize_reg = 0;
    reg [15:0] msg_count_reg = 0;
    reg [15:0] msg_len_reg = 0;
    
    always @(posedge clk) begin
        msg_ready <= 1'b0;
        msg_start <= 1'b0;
        
        if (rst ) begin
            msg_data <= 0;
            offset_idx <= 0;
            csize_reg <= 0;
            msg_start <= 0;
            msg_count_reg <= 0;
            msg_len_reg <= 0;
            
            state <= GET_WAIT;
        end else if (rx_ready) begin
            offset_idx <= offset_idx + 1'b1;
            case (state)
            
                GET_WAIT: begin
                    if (offset_idx == 17) begin // Message Count offset 18, 19
                        state <= GET_COUNT;
                    end  
                end
                
                GET_COUNT: begin
                    msg_count_reg <= {msg_count_reg[7:0], rx_data};
                    
                    if (offset_idx == 19) begin // Message Count offset 18, 19
                        csize_reg <= 0;
                        state <= GET_LEN;
                    end
                end
                
                GET_LEN: begin
                    msg_len_reg <= {msg_len_reg[7:0], rx_data};
                    
                    if (csize_reg == 1) begin
                        state <= GET_TRANS;
                    end else begin
                        csize_reg <= csize_reg + 1;
                    end
                    
                end
                
                GET_TRANS: begin
                    msg_len_reg <= msg_len_reg - 1;
                    
                    msg_data <= rx_data;                   
                    msg_ready <= 1'b1;
                    
                    if (csize_reg >= 1) begin 
                        msg_start <= 1'b1;
                    end
                    
                    csize_reg <= 0;
                    
                    if (msg_len_reg == 1) begin
                        msg_count_reg <= msg_count_reg - 1;

                        msg_len_reg <= 0;
                        
                        if (msg_count_reg == 1) begin
                            offset_idx <= 0;
                            msg_count_reg <= 0;
                            
                            state <= GET_WAIT;
                        end else begin
                            state <= GET_LEN;
                        end
                    end
                end
                
                default: state = GET_WAIT;
            endcase
            
        end // rx_ready
  
    end // always

endmodule
