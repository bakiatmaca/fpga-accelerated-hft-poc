//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/16/2026 02:16:58 PM
// Design Name: 
// Module Name: itch_parser_simple
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

/*

#Add Order - No MPID ('A')

Offset  Field                	Byte    Info
0       Message Type            1     	'A' (0x41)
1       Stock Locate            2	    integer
3       Tracking Number         2	    integer
5       Timestamp               6       nanoseconds since midnight (48-bit!)
11      Order Reference Number	8       integer
19      Buy/Sell Indicator      1	    'B' (0x42) / 'S' (0x53)
20      Shares                  4    	integer
24      Stock                   8    	ASCII (ex. "AAPL ")
32      Price                   4    	Price(4): 4 implied float, integer

*/

module itch_parser_simple #(
    parameter [31:0] THRESHOLD = 16'd1000    // price range: if it exceeds the range than send buy a signal
)(
    input wire clk,
    input wire [7:0] rx_data, //36 byte
    input wire rx_ready,
    output reg [7:0] msg_type = 0,
    output reg [31:0] msg_price = 0, // 4 byte implied float
    output reg signal = 0
);
    
    localparam TYPE_TRADE = 8'h41;   // 'A'

    localparam GET_TYPE = 2'd0;
    localparam GET_PARSE  = 2'd1;
    
    reg [2:0] state = GET_TYPE;  
    reg [5:0] offset_idx = 0;
    
    reg [7:0] type_reg = 0;
    reg [47:0] timestamp_reg = 0;
    reg [7:0] indicator_reg = 0;
    reg [63:0] stock_reg = 0;
    reg [31:0] price_reg = 0;

    always @(posedge clk) begin
        signal <= 1'b0;

        if (rx_ready) begin
            offset_idx <= offset_idx + 1'b1;
                        
            case (state)
                GET_TYPE: begin
                    if (rx_data == TYPE_TRADE) begin
                        type_reg <= rx_data;
                        offset_idx <= 5'b00001;
                        state <= GET_PARSE;
                    end else
                        offset_idx <= 0;
                end
                GET_PARSE: begin

                    if (offset_idx >= 5 && offset_idx < 11) begin // 5-10 idx Timestamp
                        timestamp_reg <= {timestamp_reg[39:0], rx_data};
                    end
                    
                    if (offset_idx == 19 ) begin // 19 idx Indicator
                        indicator_reg <= rx_data;
                    end
                    
                    if (offset_idx >= 24 && offset_idx < 32) begin // 24-31 idx Stock
                        stock_reg <= {stock_reg[55:0], rx_data};
                    end
                    
                    if (offset_idx >= 32 && offset_idx < 36) begin // 32-35 idx Price
                        price_reg <= {price_reg[23:0], rx_data};
                    end
                end
                               
                default:  state <= GET_TYPE;
            endcase
        end // ready
        
        if (offset_idx == 36) begin // complated parse check
            offset_idx <= 0;
            msg_type <= type_reg;
            msg_price <= price_reg;

            if (price_reg > THRESHOLD)
                signal <= 1'b1;
                                
            state <= GET_TYPE;
        end else if (offset_idx > 36) begin
            state <= GET_TYPE;
        end
        
    end // always
    
endmodule


