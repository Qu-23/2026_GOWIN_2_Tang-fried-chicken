`timescale 1ns/1ps
module tb_canon_offline;
 reg clk=0,rst_n=0,rx=1,btn=0;
 always #5 clk=~clk;
 wire on,off,playing,active;wire [6:0] note;wire [7:0] vel,pos,count;
 // Speed up only the beat accumulator. UART and song storage use real RTL.
 bt_song #(.CLK_PER_BIT(14),.TICK_HZ(993)) dut(
 .clk(clk),.rst_n(rst_n),.rx(rx),.play_btn(btn),.s_on(on),.s_note(note),
 .s_vel(vel),.s_off(off),.playing(playing),.s_pos(pos),.active(active),.ncount(count));
 reg [15:0] expected[0:41-1];
 integer received=0,released=0,cycle=0,last_on=0,previous=0,delta,wanted;
 reg check_events=0;
 always @(posedge clk)begin
  cycle=cycle+1;
  if(check_events && on)begin
   if(received>=41)$fatal(1,"Extra offline note");
   if(note!==expected[received][14:8] || vel!==200)$fatal(1,"Offline note order/velocity mismatch");
   if(received>0)begin
    delta=cycle-last_on;
    wanted=(993*60*16*expected[received-1][7:0])/(72*16);
    if(delta<wanted-32 || delta>wanted+32)$fatal(1,"Beat duration mismatch: %0d expected %0d",delta,wanted);
   end
   last_on=cycle;previous=note;received=received+1;
  end
  if(check_events && off)begin
   if(on)$fatal(1,"Off/on pulse collision");
   released=released+1;
  end
 end
 task tx(input [7:0] ch);
 integer j;begin
  @(negedge clk);rx=0;repeat(14)@(negedge clk);
  for(j=0;j<8;j=j+1)begin rx=ch[j];repeat(14)@(negedge clk);end
  rx=1;repeat(14)@(negedge clk);
 end endtask
 integer f,ch,i;
 initial begin
  $readmemh("canon_expected.hex",expected);
  repeat(5)@(negedge clk);rst_n=1;repeat(5)@(negedge clk);
  f=$fopen("canon_upload.txt","r");if(!f)$fatal(1,"Missing score upload");
  ch=$fgetc(f);
  while(ch!=-1)begin tx(ch[7:0]);if(ch==10)repeat(20)@(negedge clk);ch=$fgetc(f);end
  $fclose(f);repeat(100)@(negedge clk);
  if(count!=41 || playing)$fatal(1,"Whole score not stored before playback");
  for(i=0;i<41;i=i+1)
   if(dut.mem_note[i]!==expected[i][14:8] || dut.mem_len[i]!==expected[i][6:0])$fatal(1,"Cached note mismatch");
  check_events=1;tx("P");tx(10);
  wait(playing); // From this point the UART stays idle, like a disconnected phone.
  wait(!playing);repeat(40)@(negedge clk);
  if(rx!==1 || received!=41 || released!=41)$fatal(1,"Autonomous playback incomplete: %d/%d",received,released);
  delta=cycle-last_on;
  wanted=(993*60*16*expected[41-1][7:0])/(72*16);
  if(delta<wanted-64 || delta>wanted+128)$fatal(1,"Last note duration mismatch");
  $display("AUTONOMOUS: %0d notes played/released with RX idle; accelerated beat accumulator",received);
  // P can replay the stored song; X must stop and release it.
  check_events=0;tx("P");tx(10);wait(playing);wait(on);
  tx("X");tx(10);repeat(40)@(negedge clk);
  if(playing || dut.note_on_r)$fatal(1,"X did not stop playback");
  rst_n=0;repeat(5)@(negedge clk);rst_n=1;repeat(5)@(negedge clk);
  if(count!=0 || playing)$fatal(1,"Reset did not invalidate volatile score");
  $display("PASS tb_canon_offline: actual Canon cache, timing/order, autonomous playback, replay/stop, volatile reset");$finish;
 end
 initial begin #20000000;$fatal(1,"Offline timeout");end
endmodule
