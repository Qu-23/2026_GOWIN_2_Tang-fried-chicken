module top_hdmi_probe(input wire i_clk,key0,key1,key2,
 output wire tmds_clk_p_0,tmds_clk_n_0,output wire [2:0] tmds_d_p_0,tmds_d_n_0,
 output wire hpd_en,PA_EN,HP_BCK,HP_WS,HP_DIN,output wire [3:0] LEDs,
 output wire WS2812);
 wire diag_clk,pixel_clk,locked;
 OSCA #(.FREQ_DIV(4)) diag_osc(.OSCOUT(diag_clk),.OSCEN(1'b1));
 top_hdmi_check u_video(.i_clk(i_clk),.key0(key0),.key1(key1),.key2(key2),
   .tmds_clk_p_0(tmds_clk_p_0),.tmds_clk_n_0(tmds_clk_n_0),
   .tmds_d_p_0(tmds_d_p_0),.tmds_d_n_0(tmds_d_n_0),.hpd_en(hpd_en),
   .PA_EN(PA_EN),.HP_BCK(HP_BCK),.HP_WS(HP_WS),.HP_DIN(HP_DIN),.LEDs(LEDs),
   .debug_pixel_clk(pixel_clk),.debug_pll_lock(locked));
 wire [3:0] status;
 hdmi_board_probe probe(diag_clk,i_clk,pixel_clk,locked,{key2,key1,key0},WS2812,status);
endmodule
