//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: dfix
// 
// Create Date: 09/11/2026 02:29:23 PM
// Design Name: 
// Module Name: itch_parser
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

# ITCH Add Order - No MPID ('A')

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

/*
# out

Offset	Field	Byte	İnfo
0	Magic	1	0xBB fix
1	Msg Type	1	0x01 = buy signal
2	Timestamp	6	ITCH timestamp (48-bit, big-endian)
8	Order Reference	8	ITCH order ref (big-endian)
16	Side	1	ITCH indicator ('B'/'S')
17  Shares  4   ITCH quantity 4 byte integer
21	Stock	8	ITCH stock (ASCII)
29	Price	4	ITCH Price(4), big-endian

Offset	Field	Byte	İnfo
0	Magic	1	0xBB fix
1	Msg Type	1	0x01 = buy signal
2	Timestamp	6	ITCH timestamp (48-bit, big-endian)
8	Order Reference	8	ITCH order ref (big-endian)
16	Side	1	ITCH indicator ('B'/'S')
17	Stock	8	ITCH stock (ASCII)
25	Price	4	ITCH Price(4), big-endian


*/

module itch_parser #(
    parameter [31:0] THRESHOLD_SHARES = 16'd1000,    // shares range: if it exceeds the range than send buy a signal
    parameter [31:0] THRESHOLD_PRICE = 16'd1000    // price range: if it exceeds the range than send buy a signal
)(
    input wire clk,
    input wire rst,    
    input wire [7:0] rx_data, //36 byte
    input wire rx_ready,
    input wire rx_msg_start,
    
    output reg [7:0] msg_type = 0,
    output reg [47:0] msg_timestamp = 0,
    output reg [63:0] msg_orderref  = 0,
    output reg [7:0] msg_indicator = 0,
    output reg [31:0] msg_shares = 0, // 4 byte integer
    output reg [63:0] msg_stock = 0,
    output reg [31:0] msg_price = 0, // 4 byte implied float    
    output reg signal = 0
);
    
    localparam TYPE_TRADE = 8'h41;   // 'A'

    localparam GET_TYPE = 2'd0;
    localparam GET_PARSE  = 2'd1;
    
    reg [2:0] state = GET_TYPE;  
    reg [6:0] offset_idx = 0;
    
    reg [7:0] type_reg = 0;    
    reg [47:0] timestamp_reg = 0;
    reg [63:0] orderref_reg  = 0;
    reg [7:0] indicator_reg = 0;
    reg [31:0] shares_reg = 0;
    reg [63:0] stock_reg = 0;
    reg [31:0] price_reg = 0;

    always @(posedge clk) begin
        signal <= 1'b0;
        
        if (rst) begin
            offset_idx <= 0;
            
            type_reg <= 0;
            timestamp_reg <= 0;
            orderref_reg <= 0;
            indicator_reg <= 0;
            shares_reg <= 0;
            stock_reg <= 0;
            price_reg <= 0;
            
            state <= GET_TYPE;
        end else if (rx_ready) begin
        
            case (state)
                GET_TYPE: begin
                    if (rx_data == TYPE_TRADE && rx_msg_start) begin
                        type_reg <= rx_data;
                        offset_idx <= 1;
                        
                        timestamp_reg <= 0;
                        orderref_reg <= 0;
                        indicator_reg <= 0;
                        shares_reg <= 0;
                        stock_reg <= 0;
                        price_reg <= 0;
                        
                        state <= GET_PARSE;
                    end else
                        offset_idx <= 0;
                end
                GET_PARSE: begin
                    
                    if (offset_idx >= 5 && offset_idx < 11) begin // 5-10 idx Timestamp
                        timestamp_reg <= {timestamp_reg[39:0], rx_data};
                    end
                    
                    if (offset_idx >= 11 && offset_idx < 19) begin // 11-18 idx Order Reference Number
                        orderref_reg <= {orderref_reg[55:0], rx_data};
                    end
                    
                    if (offset_idx == 19 ) begin // 19 idx Indicator
                        indicator_reg <= rx_data;
                    end
                    
                    if (offset_idx >= 20 && offset_idx < 24) begin // 20- idx Shares / quantity
                        shares_reg <= {shares_reg[23:0], rx_data};
                    end                    
                    
                    if (offset_idx >= 24 && offset_idx < 32) begin // 24-31 idx Stock
                        stock_reg <= {stock_reg[55:0], rx_data};
                    end
                    
                    if (offset_idx >= 32 && offset_idx < 36) begin // 32-35 idx Price
                        price_reg <= {price_reg[23:0], rx_data};
                    end
                    
                    offset_idx <= offset_idx + 1'b1;
                end
                               
                default:  state <= GET_TYPE;
            endcase
        end // ready

        
        if (offset_idx == 36) begin // complated parse check
            offset_idx <= 0;
            
            if (shares_reg >= THRESHOLD_SHARES 
                    && price_reg <= THRESHOLD_PRICE) begin
                msg_type <= type_reg;
                msg_timestamp <= timestamp_reg;
                msg_orderref <= orderref_reg;
                msg_indicator <= indicator_reg;
                msg_shares <= shares_reg;
                msg_stock <= stock_reg;
                msg_price <= price_reg;
                
                signal <= 1'b1; // set signal
            end
                                
            state <= GET_TYPE;
        end else if (offset_idx > 36) begin
            state <= GET_TYPE;
        end
        
    end // always
    
endmodule
