// Passive observer of the actual PT8211 pins. WS=1 left, 16 bits/slot.
// All three wires use identical synchronizer depth; DIN/WS settle half a
// 1.589 MHz BCK cycle before its sampling edge (pixel clock is 73.333 MHz).
module hdmi_pcm(input wire clk,rst_n,bck,ws,din,
 output reg valid,output reg signed [15:0] left,right);
 (* async_reg="true" *) reg [2:0] bs,wsync,ds;
 reg last_ws,armed,have_left;
 reg [4:0] count;
 reg [15:0] shift,left_hold;
 wire rise=bs[1] & ~bs[2];
 wire [15:0] word_value={shift[14:0],ds[1]};
 always @(posedge clk or negedge rst_n)
 if(!rst_n) begin
   bs<=0;wsync<=0;ds<=0;valid<=0;left<=0;right<=0;
   last_ws<=0;armed<=0;have_left<=0;count<=0;shift<=0;left_hold<=0;
 end else begin
   bs<={bs[1:0],bck};wsync<={wsync[1:0],ws};ds<={ds[1:0],din};valid<=0;
   if(rise) begin
     last_ws<=wsync[1];
     if(wsync[1]!=last_ws) begin
       armed<=1;count<=1;shift<={15'd0,ds[1]};
     end else if(armed) begin
       shift<=word_value;count<=count+1'b1;
       if(count==15) begin
         armed<=0;
         if(wsync[1]) begin left_hold<=word_value;have_left<=1;end
         else if(have_left) begin left<=left_hold;right<=word_value;valid<=1;have_left<=0;end
       end
     end
   end
 end
endmodule
