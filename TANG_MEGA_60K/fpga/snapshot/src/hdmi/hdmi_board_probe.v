// Diagnostics run from OSCA, independently of the HDMI reference and PLL.
// J16 is the board WS2812; LEDs[] are on the optional PMOD expansion.
module hdmi_board_probe #(parameter GATE_BITS=20)(
 input wire diag_clk,ref_clk,pixel_clk,pll_lock,input wire [2:0] keys_n,
 output reg rgb=0,output reg [3:0] status=0);
 reg [9:0] ref_div=0,pixel_div=0;
 always @(posedge ref_clk)ref_div<=ref_div+1'b1;
 always @(posedge pixel_clk)pixel_div<=pixel_div+1'b1;
 (* async_reg="true" *) reg [2:0] ref_sync=0,pixel_sync=0;
 (* async_reg="true" *) reg [1:0] lock_sync=0;
 (* async_reg="true" *) reg [2:0] key_meta=7,key_sync=7;
 reg [GATE_BITS-1:0] gate=0;
 reg [15:0] ref_count=0,pixel_count=0,ref_edges=0,pixel_edges=0;
 reg measured=0;
 // Every transition of divider bit 9 represents 512 source-clock cycles.
 localparam REF_N=((1<<GATE_BITS)/512)*20/21;
 localparam PIX_N=((1<<GATE_BITS)/512)*88/63;
 reg [25:0] beat=0;
 always @(posedge diag_clk)begin
   beat<=beat+1'b1;
   ref_sync<={ref_sync[1:0],ref_div[9]};
   pixel_sync<={pixel_sync[1:0],pixel_div[9]};
   lock_sync<={lock_sync[0],pll_lock};key_meta<=keys_n;key_sync<=key_meta;
   gate<=gate+1'b1;
   if(&gate)begin
     ref_edges<=ref_count;pixel_edges<=pixel_count;
     ref_count<=0;pixel_count<=0;measured<=1;
   end else begin
     if(ref_sync[2]^ref_sync[1])ref_count<=ref_count+1'b1;
     if(pixel_sync[2]^pixel_sync[1])pixel_count<=pixel_count+1'b1;
   end
   if(!measured)status<=0;
   else if(ref_edges<2)status<=1;
   else if(ref_edges<REF_N*85/100 || ref_edges>REF_N*115/100)status<=2;
   else if(!lock_sync[1])status<=3;
   else if(pixel_edges<PIX_N*85/100 || pixel_edges>PIX_N*115/100)status<=5;
   else status<=4;
 end
 reg [23:0] color;
 always @* begin
   case(status)
     0:color=24'h040404; // initial measurement
     1:color=24'h001000; // red: reference absent
     2:color=24'h000808; // purple: reference outside expected band
     3:color=24'h101000; // yellow: PLL unlocked
     4:color=beat[25]?24'h040000:24'h100000; // green: clocks healthy
     5:color=24'h100010; // cyan: pixel clock missing or wrong
     default:color=0;
   endcase
   if(!key_sync[0])color=24'h000010; // KEY0 blue
   if(!key_sync[1])color=24'h001010; // KEY1 magenta
   if(!key_sync[2])color=24'h101010; // KEY2 white
 end
 // GRB, MSB first: 65 cycles/bit at nominal 52.5 MHz. Reset low >380 us.
 // High durations: 18 cycles (343 ns) for 0, 36 cycles (686 ns) for 1.
 reg [23:0] tx_word=0;
 reg [4:0] tx_bit=24;
 reg [14:0] tx_cycle=0;
 always @(posedge diag_clk)begin
   if(tx_bit==24)begin
     rgb<=0;
     if(tx_cycle==19999)begin tx_cycle<=0;tx_bit<=0;tx_word<=color;end
     else tx_cycle<=tx_cycle+1'b1;
   end else begin
     rgb<=tx_cycle<(tx_word[23]?36:18);
     if(tx_cycle==64)begin tx_cycle<=0;tx_bit<=tx_bit+1'b1;tx_word<={tx_word[22:0],1'b0};end
     else tx_cycle<=tx_cycle+1'b1;
   end
 end
endmodule
