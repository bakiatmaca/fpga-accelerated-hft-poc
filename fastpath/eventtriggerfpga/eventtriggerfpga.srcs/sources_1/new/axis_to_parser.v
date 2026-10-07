//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: dfix
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

module axis_to_parser(
    input wire clk,
    input wire rst,
    input wire [7:0] s_axis_tdata,
    input wire s_axis_tvalid,
    input wire s_axis_tlast,
   
    output reg [7:0] rx_data,
    output reg rx_ready,
    output wire s_axis_tready
);
    
    assign s_axis_tready = 1'b1;

    always @(posedge clk) begin
        rx_ready <= 1'b0;
        
        if (rst) begin
            rx_ready <= 1'b0;
            rx_data <= 0; 
        end else if (s_axis_tvalid && s_axis_tready) begin
            rx_data <= s_axis_tdata;
            rx_ready <= 1'b1;
        end
    end

endmodule
