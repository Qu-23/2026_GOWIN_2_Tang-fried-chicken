// Independent display-only Mega60K check. No UART, Bluetooth or synth engine.
// Test L/R are deliberately generated quadrature signals, clearly labeled.
module top_hdmi_check(input wire i_clk,key0,key1,key2,
 output wire tmds_clk_p_0,tmds_clk_n_0,output wire [2:0] tmds_d_p_0,tmds_d_n_0,
 output wire hpd_en,PA_EN,HP_BCK,HP_WS,HP_DIN,output wire [3:0] LEDs,
 output wire debug_pixel_clk,debug_pll_lock);
 wire serial_clk,pixel_clk,locked;
 assign debug_pixel_clk=pixel_clk;assign debug_pll_lock=locked;
 TMDS_PLL u_tmds_pll(.clkin(i_clk),.clkout0(serial_clk),.clkout1(pixel_clk),.lock(locked));
 reg [2:0] reset_pipe=0;
 always @(posedge pixel_clk or negedge locked)
 if(!locked)reset_pipe<=0;else reset_pipe<={reset_pipe[1:0],1'b1};
 wire reset_n=reset_pipe[2];
 assign hpd_en=1;assign PA_EN=1;assign HP_BCK=0;assign HP_WS=0;assign HP_DIN=0;
 (* async_reg="true" *) reg [2:0] k1,k2;
 reg [25:0] heartbeat;
 always @(posedge pixel_clk or negedge reset_n)
 if(!reset_n)begin k1<=7;k2<=7;heartbeat<=0;end
 else begin k1<={key2,key1,key0};k2<=k1;heartbeat<=heartbeat+1'b1;end
 assign LEDs={~locked,k2[2:0]} ^ {heartbeat[25],3'd0};
 wire [24:0] keys=({25{~k2[0]}} & 25'h1) | ({25{~k2[1]}} & 25'h10) | ({25{~k2[2]}} & 25'h80);
 reg [10:0] divider;reg [5:0] phase;
 reg valid;reg signed [15:0] left,right;
 function signed [15:0] sine(input [5:0] phase);
 reg [4:0] q;reg signed [15:0] magnitude;
 begin
 q=phase[4]?(5'd16-{1'b0,phase[3:0]}):{1'b0,phase[3:0]};
 case(q)
  5'd0:magnitude=16'sd0;
  5'd1:magnitude=16'sd588;
  5'd2:magnitude=16'sd1171;
  5'd3:magnitude=16'sd1742;
  5'd4:magnitude=16'sd2296;
  5'd5:magnitude=16'sd2828;
  5'd6:magnitude=16'sd3333;
  5'd7:magnitude=16'sd3806;
  5'd8:magnitude=16'sd4243;
  5'd9:magnitude=16'sd4638;
  5'd10:magnitude=16'sd4989;
  5'd11:magnitude=16'sd5292;
  5'd12:magnitude=16'sd5543;
  5'd13:magnitude=16'sd5742;
  5'd14:magnitude=16'sd5885;
  5'd15:magnitude=16'sd5971;
  5'd16:magnitude=16'sd6000;
  default:magnitude=0;
 endcase
 sine=phase[5]?-magnitude:magnitude;
 end endfunction

 always @(posedge pixel_clk or negedge reset_n)
 if(!reset_n)begin divider<=0;phase<=0;valid<=0;left<=0;right<=0;end
 else begin
   valid<=0;
   if(divider==1475)begin
     divider<=0;valid<=1;left<=sine(phase);right<=sine(phase+6'd16);
     phase<=phase+(!k2[2]?6'd3:!k2[1]?6'd2:6'd1);
   end else divider<=divider+1'b1;
 end
 wire frame,lp,dp,fv,mono;wire [14:0] xy;wire [7:0] wa;wire [15:0] wd,missed;
 hdmi_scope scope(pixel_clk,reset_n,valid,left,right,frame,xy,wa,lp,dp,wd,fv,mono,missed);
 wire [23:0] rgb;wire hs,vs,de;
 hdmi_video #(.TEST_SOURCE(1)) video(pixel_clk,reset_n,lp,dp,wd,fv,mono,
   keys,6'd0,2'd0,8'd0,2'd0,xy,wa,frame,rgb,hs,vs,de);
 DVI_TX_Top dvi(.I_rst_n(locked),.I_serial_clk(serial_clk),.I_rgb_clk(pixel_clk),
   .I_rgb_vs(vs),.I_rgb_hs(hs),.I_rgb_de(de),.I_rgb_r(rgb[23:16]),
   .I_rgb_g(rgb[15:8]),.I_rgb_b(rgb[7:0]),.O_tmds_clk_p(tmds_clk_p_0),
   .O_tmds_clk_n(tmds_clk_n_0),.O_tmds_data_p(tmds_d_p_0),.O_tmds_data_n(tmds_d_n_0));
endmodule
