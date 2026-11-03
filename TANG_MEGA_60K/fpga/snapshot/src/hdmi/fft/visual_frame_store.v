`default_nettype none
// Two-bank stable snapshot mailbox. Reader must finish copying before release.
// A slow consumer drops WHOLE snapshots, never stalls the source/audio path.
module visual_frame_store #(parameter AW=9, W=16)(
 input wire wr_clk,wr_rst_n,wr_valid,input wire [W-1:0] wr_data,
 output reg [31:0] dropped_frames,
 input wire rd_clk,rd_rst_n,input wire [AW-1:0] rd_addr,
 output reg [W-1:0] rd_data,output wire pending,input wire release_frame
);
 reg [W-1:0] ram [0:(2<<AW)-1];
 reg [AW-1:0] wp;
 reg request,ack;
 (* async_reg="true" *) reg ack1,ack2,req1,req2;
 assign pending=(req2!=ack);
 always @(posedge wr_clk or negedge wr_rst_n)
 if(!wr_rst_n) begin wp<=0;request<=0;ack1<=0;ack2<=0;dropped_frames<=0;end
 else begin
   ack1<=ack;ack2<=ack1;
   if(wr_valid) begin
     wp<=wp+1'b1;
     if(&wp) begin
       if(request==ack2) request<=~request;
       else dropped_frames<=dropped_frames+1'b1;
     end
   end
 end
 always @(posedge wr_clk)
 if(wr_valid)ram[{request,wp}]<=wr_data;
 always @(posedge rd_clk or negedge rd_rst_n)
 if(!rd_rst_n) begin req1<=0;req2<=0;ack<=0;end
 else begin
   req1<=request;req2<=req1;
   if(release_frame && pending) ack<=req2;
 end
 // No reset on the RAM or read port: allows block RAM inference.
 always @(posedge rd_clk) rd_data<=ram[{~req2,rd_addr}];
endmodule
`default_nettype wire
