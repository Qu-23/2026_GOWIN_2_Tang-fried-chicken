// Bundled-data request/ack mailbox. The source holds its snapshot until the
// next request, long after the destination's two-stage ACK synchronizer.
module hdmi_status_cdc(input wire src_clk,src_rst_n,input wire [42:0] status,
 input wire dst_clk,dst_rst_n,request_frame,output reg [42:0] display_status);
 reg request,ack;
 (* async_reg="true" *) reg r1,r2,a1,a2;
 reg [42:0] held;
 always @(posedge src_clk or negedge src_rst_n)
 if(!src_rst_n) begin r1<=0;r2<=0;ack<=0;held<=0;end
 else begin
   r1<=request;r2<=r1;
   if(r2!=ack)begin held<=status;ack<=r2;end
 end
 always @(posedge dst_clk or negedge dst_rst_n)
 if(!dst_rst_n)begin request<=0;a1<=0;a2<=0;display_status<=0;end
 else begin
   a1<=ack;a2<=a1;
   if(a2==request) begin
     display_status<=held;
     if(request_frame)request<=~request;
   end
 end
endmodule
