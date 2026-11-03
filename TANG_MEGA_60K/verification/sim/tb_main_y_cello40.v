`timescale 1ns/1ps
// Main_Y UART/text/song -> renderer -> audible stereo -> DAC -> HDMI capture.
module tb_main_y_cello40;
 reg rx=1,bt=1;reg[2:0] keys=7;
 wire b,w,d,pa,rgb_led,bt_tx,mc,mrst;wire[3:0] leds;wire[42:0] status;
 top #(.N_VOICES(32),.USE_LSBJ(1),.KEY_WAVE(0),.EP_SEL(0),.PLUCK_SEL(1),
 .UNISON(0),.PA_GATE(0),.TEST_MODE(0),.FX_ON(1),.BT_ON(1),.GLIDE(1),
 .KEY_IN(1),.DAC_SHIFT(0),.ENGINE_REAL(1),.BT_SONG(1)) dut(
 .key0(keys[0]),.key1(keys[1]),.key2(keys[2]),.uart_rx(rx),.uart_bt(bt),
 .uart_bt_tx(bt_tx),.HP_BCK(b),.HP_WS(w),.HP_DIN(d),.PA_EN(pa),.LEDs(leds),
 .WS2812(rgb_led),.monitor_clk(mc),.monitor_reset_n(mrst),.monitor_status(status));
 reg pixel=0;always #6.8181818 pixel=~pixel;
 reg[2:0] pr=0;always @(posedge pixel)pr<={pr[1:0],mrst};
 wire valid;wire signed[15:0] l,r;
 hdmi_pcm pcm(pixel,pr[2],b,w,d,valid,l,r);
 wire frame,lp,dp,fv,mono;wire[14:0] xy;wire[7:0] wa;
 wire[15:0] wd,missed;wire[42:0] vs_status;wire[23:0] rgb;wire hs,vs,de;
 wire[5:0] sa;wire[7:0] sl;wire sr;wire[31:0] dropped;
 wire signed[16:0] pcm_sum=$signed({l[15],l})+$signed({r[15],r});
 hdmi_scope scope(pixel,pr[2],valid,l,r,frame,xy,wa,lp,dp,wd,fv,mono,missed);
 hdmi_status_cdc status_cdc(mc,mrst,status,pixel,pr[2],frame,vs_status);
 hdmi_spectrum spectrum(pixel,pr[2],valid,pcm_sum[16:1],frame,sa,sl,sr,dropped);
 hdmi_video video(pixel,pr[2],lp,dp,wd,fv,mono,vs_status[24:0],vs_status[30:25],
 vs_status[32:31],vs_status[40:33],vs_status[42:41],xy,wa,frame,rgb,hs,vs,de,sa,sl,sr);
 integer fd,af,frames=0,samples=0,stereo=0,events=0,tx_edges=0,fftbins=0,folds=0;
 integer stage=-1,k,word_count=0,bits=0,pair_count=0,decoded=0;
 reg last_ws=0,armed=0,old_tx=1;reg[15:0] shift=0,decoded_l=0;
 reg[31:0] pair_queue[0:32767];integer written=0,read=0;
 // Expected DAC pairs captured at its actual atomic load boundary.
 always @(posedge b)if(mrst)begin
  if(dut.g_tx_lsbj.u_audio_drive_0.b_cnt==31)begin
   pair_queue[written]={dut.dac_l,dut.dac_r};written=written+1;
  end
 end
 // Each HDMI sample must equal the queued source pair, with no fake XY data.
 always @(posedge pixel)if(valid)begin
  if((^{l,r})===1'bx)$fatal(1,"Undefined DAC capture");
  pair_count=pair_count+1;
  if(pair_count>1)begin
   if({l,r}!==pair_queue[read])$fatal(1,"HDMI != actual coherent DAC source pair");
   read=read+1;
  end
  samples=samples+1;if(l!=r)stereo=stereo+1;
  $fwrite(af,"%d,%d,%d\n",stage,l,r);
 end
 always @(posedge mc)if(dut.ev_on||dut.ev_off)events=events+1;
 always @(posedge mc)begin if(bt_tx!=old_tx)tx_edges=tx_edges+1;old_tx=bt_tx;end
 always @(negedge dut.clk_6m_w)if(mrst && dut.eng_tick1)begin
  // Outputs are registered from fx_l at the previous sample enable.
  folds=folds+1;
 end
 always @(posedge pixel)if(spectrum.fft.bin_valid)fftbins=fftbins+1;
 reg last_frame=0;integer px=0;
 always @(posedge pixel)begin
  last_frame<=frame;
  if(frame && !last_frame)frames=frames+1;
  if(de && frames==2)begin $fwrite(fd,"%c%c%c",rgb[23:16],rgb[15:8],rgb[7:0]);px=px+1;end
 end
 task held(input integer want_ep,input integer want_cello);
 integer v,ep,cello;
 begin
  ep=0;cello=0;
  for(v=0;v<32;v=v+1)if(dut.g_eng_real.u_eng.g_ram.u_poly.smem[v][3])begin
   if(dut.g_eng_real.u_eng.g_ram.u_poly.smem[v][343])cello=cello+1;else ep=ep+1;
  end
  if(ep!=want_ep || cello!=want_cello)$fatal(1,"UART unison routing EP=%d cello=%d expected=%d/%d",ep,cello,want_ep,want_cello);
 end endtask
 task tx(input[7:0] value,input channel);
 integer i;begin
  if(channel)bt=0;else rx=0;#8680;
  for(i=0;i<8;i=i+1)begin if(channel)bt=value[i];else rx=value[i];#8680;end
  if(channel)bt=1;else rx=1;#8680;
 end endtask
 task packet(input[7:0] c,n,v,input channel);
 begin tx(8'ha5,channel);tx(c,channel);tx(n,channel);tx(v,channel);#100000;end endtask
 task line(input[255:0] s);
 integer i;reg[7:0] ch;begin
  for(i=31;i>=0;i=i-1)begin ch=s[i*8+:8];if(ch)tx(ch,1);end
  tx(10,1);#100000;
 end endtask
 initial begin
  fd=$fopen("main_y_hdmi.ppm","wb");$fwrite(fd,"P6\n1280 720\n255\n");
  af=$fopen("actual_dac.csv","w");#4000000;
  stage=0;packet(8'h80,64,200,1);#50000000;
  if(!status[4]||status[32:31]!=0)$fatal(1,"BT EP monitor");
  packet(8'h00,64,0,1);#10000000;
  stage=1;packet(8'h83,64,200,1);#65000000;
  if(!status[4]||status[32:31]!=3)$fatal(1,"BT cello monitor");
  packet(8'h03,64,0,1);#10000000;
  // Same-pitch EP + cello, with USB and BT sharing the same voice engine.
  stage=5;packet(8'h80,64,180,1);packet(8'h8b,64,150,1);#1000000;held(1,1);
  packet(8'h00,64,0,1);#1000000;held(0,1);
  packet(8'h80,64,180,0);#1000000;held(1,1);
  packet(8'h0b,64,0,1);#1000000;held(1,0);
  packet(8'h00,64,0,0);#1000000;held(0,0);
  // Legacy N/O has no instrument field: off sweeps must not select cello,
  // and intervening binary notes must not retarget a text note's release.
  packet(8'h80,80,150,1);packet(8'h00,80,0,1);
  packet(8'h0b,65,0,1);line("N60,180");#1000000;held(1,0);
  packet(8'h8b,67,140,1);#1000000;held(1,1);
  line("O60");#1000000;held(0,1);
  packet(8'h0b,67,0,1);#1000000;held(0,0);
  // A song keeps its chosen timbre for the complete sequence, even while
  // binary cello traffic changes the next legacy instrument selection.
  packet(8'h80,80,150,1);packet(8'h00,80,0,1);
  line("S240");line("K60,0.1");line("K64,0.1");line("P");#8000000;held(1,0);
  packet(8'h8b,67,140,1);#30000000;held(1,1);
  line("X");#1000000;held(0,1);
  packet(8'h0b,67,0,1);#1000000;held(0,0);
  // Binary note 80 must not start song playback; text notes still work.
  packet(8'h80,80,13,1);packet(8'h00,80,0,1);
  if(dut.g_bt_on.g_song.u_bt_song.playing)$fatal(1,"Binary P conflict");
  line("N60,180");#1000000;if(!status[0])$fatal(1,"Text N60 missing");
  line("O60");#1000000;if(status[0])$fatal(1,"Text O60 missing");
  stage=2;packet(8'h80,67,200,0);#1000000;
  if(!status[7])$fatal(1,"USB binary note missing");
  packet(8'h00,67,0,0);
  stage=3;line("S240");line("K60,0.1");line("K64,0.1");line("P");#8000000;
  if(!dut.g_bt_on.g_song.u_bt_song.playing || dut.g_bt_on.so_ncount!=2)$fatal(1,"Offline score missing");
  #70000000;line("X");#1000000;
  if(dut.g_bt_on.g_song.u_bt_song.playing)$fatal(1,"Offline score stop missing");
  stage=4;packet(8'h40,8'h19,20,1);packet(8'h80,60,220,1);#12000000;
  packet(8'h40,8'h1a,20,1);#10000000;packet(8'h40,8'h1b,0,1);#10000000;
  packet(8'h40,8'h10,0,1);packet(8'h00,60,0,1);#2000000;
  $fclose(fd);$fclose(af);
  if(samples<10000||stereo<5000||tx_edges<20||fftbins<1000||!fv||missed||dropped||!sr||px!=921600)
   $fatal(1,"Coverage samples=%d stereo=%d TXedges=%d FFTbins=%d missed=%d drop=%d pixels=%d",samples,stereo,tx_edges,fftbins,missed,dropped,px);
  $display("PASS tb_main_y_cello40 samples=%d stereo=%d events=%d TXedges=%d FFTbins=%d pixels=%d",samples,stereo,events,tx_edges,fftbins,px);$finish;
 end
 initial begin #600000000;$fatal(1,"Integration timeout");end
endmodule
module Gowin_OSC(output reg oscout=0,input oscen);always #9.523809524 oscout=~oscout;endmodule
module Gowin_PLL(output reg clkout0=0,input clkin);always #78.648233487 clkout0=~clkout0;endmodule
module Gowin_CLKDIV(output wire clkout,input hclkin,resetn);
 reg[1:0] divide=0;always @(posedge hclkin or negedge resetn)if(!resetn)divide<=0;else divide<=divide+1'b1;
 assign clkout=divide[1];endmodule
