// Mega60K only: audio retains the existing internal oscillator and audio PLL.
// Video uses the board's independent external 50MHz clock on V22.
module top_hdmi(input wire i_clk,key0,key1,key2,uart_rx,uart_bt,
 output wire uart_bt_tx,HP_BCK,HP_WS,HP_DIN,PA_EN,
 output wire [3:0] LEDs,output wire WS2812,
 output wire tmds_clk_p_0,tmds_clk_n_0,
 output wire [2:0] tmds_d_p_0,tmds_d_n_0,output wire hpd_en);
 wire monitor_clk,monitor_reset_n;
 wire [42:0] monitor_status;
 top #(.N_VOICES(32),.USE_LSBJ(1),.KEY_WAVE(0),.EP_SEL(0),.PLUCK_SEL(1),
   .UNISON(0),.PA_GATE(0),.TEST_MODE(0),.FX_ON(1),.BT_ON(1),.GLIDE(1),
   .KEY_IN(1),.DAC_SHIFT(0),.ENGINE_REAL(1),.BT_SONG(1)) u_top(
   .key0(key0),.key1(key1),.key2(key2),.uart_rx(uart_rx),.uart_bt(uart_bt),.uart_bt_tx(uart_bt_tx),
   .HP_BCK(HP_BCK),.HP_WS(HP_WS),.HP_DIN(HP_DIN),
   .PA_EN(PA_EN),.LEDs(LEDs),.WS2812(WS2812),
   .monitor_clk(monitor_clk),.monitor_reset_n(monitor_reset_n),.monitor_status(monitor_status));
 wire serial_clk,pixel_clk,locked;
 // Main_Y Bluetooth TX carries heartbeat and event feedback.
 TMDS_PLL u_tmds_pll(.clkin(i_clk),.clkout0(serial_clk),.clkout1(pixel_clk),.lock(locked));
 // Independent video reset: audio keys remain musical keys, never reset HDMI.
 reg [2:0] reset_pipe=0;
 always @(posedge pixel_clk or negedge locked)
 if(!locked)reset_pipe<=0;else reset_pipe<={reset_pipe[1:0],1'b1};
 wire reset_n=reset_pipe[2];
 assign hpd_en=1;
 wire pcm_valid;wire signed [15:0] pcm_l,pcm_r;
 hdmi_pcm pcm(pixel_clk,reset_n,HP_BCK,HP_WS,HP_DIN,pcm_valid,pcm_l,pcm_r);
 wire frame;wire [14:0] xy_addr;wire [7:0] wave_addr;
 wire lr_pixel,delay_pixel,front_valid,mono;
 wire [15:0] wave_data,missed;
 hdmi_scope scope(pixel_clk,reset_n,pcm_valid,pcm_l,pcm_r,frame,xy_addr,wave_addr,
                  lr_pixel,delay_pixel,wave_data,front_valid,mono,missed);
 wire [42:0] display_status;
 hdmi_status_cdc status_cdc(monitor_clk,monitor_reset_n,monitor_status,
                          pixel_clk,reset_n,frame,display_status);
 wire [23:0] rgb;wire hs,vs,de;
 wire [5:0] spectrum_addr;
 wire [7:0] spectrum_level;
 wire spectrum_ready;
 wire [31:0] spectrum_dropped;
 wire signed [16:0] pcm_sum=$signed({pcm_l[15],pcm_l})+$signed({pcm_r[15],pcm_r});
 wire signed [15:0] pcm_mid=pcm_sum[16:1];
 hdmi_spectrum spectrum(.clk(pixel_clk),.rst_n(reset_n),.sample_valid(pcm_valid),
   .sample(pcm_mid),.publish(frame),.read_addr(spectrum_addr),.level(spectrum_level),
   .ready(spectrum_ready),.dropped_frames(spectrum_dropped));
 hdmi_video video(pixel_clk,reset_n,lr_pixel,delay_pixel,wave_data,front_valid,mono,
                 display_status[24:0],display_status[30:25],display_status[32:31],
                 display_status[40:33],display_status[42:41],xy_addr,wave_addr,frame,rgb,hs,vs,de,
                 spectrum_addr,spectrum_level,spectrum_ready);
 DVI_TX_Top dvi(.I_rst_n(locked),.I_serial_clk(serial_clk),.I_rgb_clk(pixel_clk),
   .I_rgb_vs(vs),.I_rgb_hs(hs),.I_rgb_de(de),.I_rgb_r(rgb[23:16]),
   .I_rgb_g(rgb[15:8]),.I_rgb_b(rgb[7:0]),.O_tmds_clk_p(tmds_clk_p_0),
   .O_tmds_clk_n(tmds_clk_n_0),.O_tmds_data_p(tmds_d_p_0),.O_tmds_data_n(tmds_d_n_0));
endmodule
