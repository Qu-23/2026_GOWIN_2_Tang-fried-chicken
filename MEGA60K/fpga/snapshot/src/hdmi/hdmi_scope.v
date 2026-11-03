// Five BSRAM target: two double-buffered 128x128 bitmaps (4) and
// a double-buffered 256x16 waveform (1). No audio backpressure.
// Both axes share full-scale x1 display gain; audio itself is untouched.
module hdmi_scope(input wire clk,rst_n,valid,
 input wire signed [15:0] left,right,input wire publish,
 input wire [14:0] xy_addr,input wire [7:0] wave_addr,
 output reg lr_pixel,delay_pixel,output reg [15:0] wave_data,
 output reg front_valid,output reg mono,output reg [15:0] missed);
 localparam CLEAR=0,WAIT_SAMPLE=1,DRAW_LR=2,DRAW_DELAY=3,HOLD=4;
 reg [2:0] state;
 reg front;
 reg [13:0] clear_addr;
 reg [7:0] index;
 reg lr_ram[0:32767];
 reg delay_ram[0:32767];
 reg [15:0] waves[0:511];
 reg signed [7:0] history[0:7];
 reg capture_mono;
 reg [6:0] prev_x,prev_r,prev_d,target_x,target_r,target_d;
 reg [6:0] x,y,tx,ty;
 reg [7:0] dx,dy;
 reg sx,sy;
 reg signed [9:0] err;
 wire signed [10:0] e2=$signed(err)*2;
 wire step_x=e2> -$signed({3'd0,dy});
 wire step_y=e2<  $signed({3'd0,dx});
 wire signed [10:0] next_err=$signed(err)+(step_y?$signed({3'd0,dx}):11'sd0)
                                          -(step_x?$signed({3'd0,dy}):11'sd0);
 function [7:0] quant;
   input signed [15:0] sample;
   begin
     quant=sample>>>8;
   end
 endfunction
 wire [7:0] ql=quant(left),qr=quant(right);
 wire [6:0] new_x={~ql[7],ql[6:1]};
 wire [6:0] new_r=7'd127-{~qr[7],qr[6:1]};
 wire [6:0] new_d=7'd127-{~history[7][7],history[7][6:1]};
 wire signed [16:0] diff=$signed({left[15],left})-$signed({right[15],right});
 wire equal_lr=diff>= -2 && diff<=2;
 wire capture=(state==WAIT_SAMPLE)&&valid;
 // Dedicated synchronous read ports; no reset on memories/read registers.
 always @(posedge clk) begin
   lr_pixel<=lr_ram[{front,xy_addr[13:0]}];
   delay_pixel<=delay_ram[{front,xy_addr[13:0]}];
   wave_data<=waves[{front,wave_addr}];
   if(state==CLEAR) begin
     lr_ram[{~front,clear_addr}]<=0;delay_ram[{~front,clear_addr}]<=0;
   end else begin
     if(state==DRAW_LR) lr_ram[{~front,y,x}]<=1;
     if(state==DRAW_DELAY) delay_ram[{~front,y,x}]<=1;
   end
   if(capture) waves[{~front,index}]<={ql,qr};
 end
 integer k;
 always @(posedge clk or negedge rst_n)
 if(!rst_n) begin
   state<=CLEAR;front<=0;front_valid<=0;mono<=1;missed<=0;
   clear_addr<=0;index<=0;capture_mono<=1;
   x<=0;y<=0;tx<=0;ty<=0;dx<=0;dy<=0;sx<=0;sy<=0;err<=0;
   prev_x<=0;prev_r<=0;prev_d<=0;target_x<=0;target_r<=0;target_d<=0;
   for(k=0;k<8;k=k+1) history[k]<=0;
 end else begin
   if(valid) begin
     history[0]<=ql;
     for(k=1;k<8;k=k+1) history[k]<=history[k-1];
     if(state==DRAW_LR || state==DRAW_DELAY) missed<=missed+1'b1;
   end
   case(state)
   CLEAR: begin
     clear_addr<=clear_addr+1'b1;
     if(&clear_addr) begin state<=WAIT_SAMPLE;index<=0;capture_mono<=1;end
   end
   WAIT_SAMPLE: if(valid) begin
     capture_mono<=capture_mono && equal_lr;
     target_x<=new_x;target_r<=new_r;target_d<=new_d;
     tx<=new_x;ty<=new_r;
     if(index==0) begin
       prev_x<=new_x;prev_r<=new_r;prev_d<=new_d;
       x<=new_x;y<=new_r;dx<=0;dy<=0;err<=0;sx<=1;sy<=1;
     end else begin
       x<=prev_x;y<=prev_r;
       dx<=(new_x>prev_x)?new_x-prev_x:prev_x-new_x;
       dy<=(new_r>prev_r)?new_r-prev_r:prev_r-new_r;
       sx<=new_x>prev_x;sy<=new_r>prev_r;
       err<=$signed({3'd0,((new_x>prev_x)?new_x-prev_x:prev_x-new_x)})
            -$signed({3'd0,((new_r>prev_r)?new_r-prev_r:prev_r-new_r)});
     end
     state<=DRAW_LR;
   end
   DRAW_LR: begin
     if(x==tx && y==ty) begin
       x<=prev_x;y<=prev_d;tx<=target_x;ty<=target_d;
       dx<=(target_x>prev_x)?target_x-prev_x:prev_x-target_x;
       dy<=(target_d>prev_d)?target_d-prev_d:prev_d-target_d;
       sx<=target_x>prev_x;sy<=target_d>prev_d;
       err<=$signed({3'd0,((target_x>prev_x)?target_x-prev_x:prev_x-target_x)})
            -$signed({3'd0,((target_d>prev_d)?target_d-prev_d:prev_d-target_d)});
       state<=DRAW_DELAY;
     end else begin
       err<=next_err;
       if(step_x) x<=sx?x+1'b1:x-1'b1;
       if(step_y) y<=sy?y+1'b1:y-1'b1;
     end
   end
   DRAW_DELAY: begin
     if(x==tx && y==ty) begin
       prev_x<=target_x;prev_r<=target_r;prev_d<=target_d;
       index<=index+1'b1;
       if(&index) state<=HOLD;else state<=WAIT_SAMPLE;
     end else begin
       err<=next_err;
       if(step_x) x<=sx?x+1'b1:x-1'b1;
       if(step_y) y<=sy?y+1'b1:y-1'b1;
     end
   end
   HOLD: if(publish) begin
     front<=~front;front_valid<=1;mono<=capture_mono;
     state<=CLEAR;clear_addr<=0;
   end
   default:state<=CLEAR;
   endcase
 end
endmodule
