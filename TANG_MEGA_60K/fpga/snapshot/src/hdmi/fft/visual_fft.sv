`default_nettype none
// Real PCM, radix-2 DIT, bit-reversed load, natural-order spectrum.
// 18-bit signed data, Q1.15 coefficients; divide by2 EACH stage (FFT/N).
// One time-multiplexed butterfly, synchronous RAM reads, serialized writes.
module visual_fft #(parameter LOGN=11,parameter WINDOW=1)(
 input wire clk,rst_n,sample_valid,input wire signed [15:0] sample,
 output wire [31:0] dropped_frames,
 output reg bin_valid,output reg [LOGN-2:0] bin_index,
 output reg signed [17:0] bin_re,bin_im,output reg [36:0] bin_power
);
 localparam N=1<<LOGN;
 localparam integer OUT_LAST_INT=N/2-1;
 localparam [LOGN-1:0] OUT_LAST=OUT_LAST_INT[LOGN-1:0];
 wire pending;reg release_frame;
 reg [LOGN-1:0] input_addr;wire [15:0] input_data;
 visual_frame_store #(.AW(LOGN),.W(16)) capture(
 .wr_clk(clk),.wr_rst_n(rst_n),.wr_valid(sample_valid),.wr_data(sample),
 .dropped_frames(dropped_frames),.rd_clk(clk),.rd_rst_n(rst_n),
 .rd_addr(input_addr),.rd_data(input_data),.pending(pending),.release_frame(release_frame));
 reg signed [17:0] re_mem[0:N-1],im_mem[0:N-1];
 reg [3:0] state;
 localparam IDLE=0,LOAD_ADDR=1,LOAD_WAIT=2,LOAD_WRITE=3,
 READ_A=4,READ_B=5,MULTIPLY=6,WRITE_A=7,WRITE_B=8,OUT_READ=9,OUT_SEND=10;
 reg [LOGN-1:0] j,base,oa;
 reg [LOGN:0] half_size;
 reg [3:0] stage;
 wire [LOGN-1:0] addr_a=base+j;
 wire [LOGN-1:0] addr_b=addr_a+half_size[LOGN-1:0];
 wire [LOGN-1:0] tw_index=j<<(LOGN-stage);
 wire [11:0] coeff_addr={tw_index,{(12-LOGN){1'b0}}};
 wire signed [15:0] cr,ci,window_cos,unused_sin;
 visual_twiddle_rom tw(clk,coeff_addr,cr,ci);
 visual_twiddle_rom win(clk,{input_addr,{(12-LOGN){1'b0}}},window_cos,unused_sin);
 wire signed [16:0] hann=(17'sd32767-{{1{window_cos[15]}},window_cos})>>>1;
 wire signed [32:0] window_product=$signed(input_data)*hann;
 wire signed [17:0] window_sample=18'(window_product>>>15);
 reg signed [17:0] ar,ai,br,bi;
 reg signed [35:0] tr,ti;
 wire signed [36:0] a_scaled_r=$signed(ar)*37'sd32768;
 wire signed [36:0] a_scaled_i=$signed(ai)*37'sd32768;
 wire signed [36:0] sum_r=a_scaled_r+{{1{tr[35]}},tr};
 wire signed [36:0] sum_i=a_scaled_i+{{1{ti[35]}},ti};
 wire signed [36:0] diff_r=a_scaled_r-{{1{tr[35]}},tr};
 wire signed [36:0] diff_i=a_scaled_i-{{1{ti[35]}},ti};
 wire [35:0] power_r=$signed(ar)*$signed(ar);
 wire [35:0] power_i=$signed(ai)*$signed(ai);
 function [LOGN-1:0] reverse_bits;
 input [LOGN-1:0] x;integer k;
 begin for(k=0;k<LOGN;k=k+1) reverse_bits[k]=x[LOGN-1-k];end
 endfunction
 // RAM datapath intentionally has NO asynchronous reset. Only control resets;
 // all samples are loaded before use, preserving block RAM inference.
 wire [LOGN-1:0] read_a_addr=(state==OUT_READ)?oa:addr_a;
 wire [LOGN-1:0] write_addr=(state==LOAD_WRITE)?reverse_bits(input_addr):
                                  ((state==WRITE_A)?addr_a:addr_b);
 wire signed [17:0] loaded_sample=WINDOW ? window_sample : {{2{input_data[15]}},input_data};
 wire signed [17:0] write_re=(state==LOAD_WRITE)?loaded_sample:
                            ((state==WRITE_A)?18'(sum_r>>>16):18'(diff_r>>>16));
 wire signed [17:0] write_im=(state==LOAD_WRITE)?18'sd0:
                            ((state==WRITE_A)?18'(sum_i>>>16):18'(diff_i>>>16));
 always @(posedge clk)begin
   if(state==READ_A || state==OUT_READ)begin ar<=re_mem[read_a_addr];ai<=im_mem[read_a_addr];end
   if(state==READ_B)begin br<=re_mem[addr_b];bi<=im_mem[addr_b];end
   if(state==MULTIPLY)begin
     tr<=$signed(br)*$signed(cr)-$signed(bi)*$signed(ci);
     ti<=$signed(br)*$signed(ci)+$signed(bi)*$signed(cr);
   end
   if(state==LOAD_WRITE || state==WRITE_A || state==WRITE_B)begin
     re_mem[write_addr]<=write_re;im_mem[write_addr]<=write_im;
   end
 end
`ifndef SYNTHESIS
 initial if(LOGN<4 || LOGN>12) $fatal(1,"visual_fft LOGN must be4..12");
`endif
 always @(posedge clk or negedge rst_n)
 if(!rst_n) begin
   state<=IDLE;input_addr<=0;j<=0;base<=0;oa<=0;half_size<=1;stage<=1;
   release_frame<=0;bin_valid<=0;bin_index<=0;bin_re<=0;bin_im<=0;bin_power<=0;
 end else begin
   release_frame<=0;bin_valid<=0;
   case(state)
   IDLE: if(pending) begin input_addr<=0;state<=LOAD_ADDR;end
   LOAD_ADDR:state<=LOAD_WAIT;
   LOAD_WAIT:state<=LOAD_WRITE;
   LOAD_WRITE:begin
     if(&input_addr) begin release_frame<=1;stage<=1;half_size<=1;j<=0;base<=0;state<=READ_A;end
     else begin input_addr<=input_addr+1'b1;state<=LOAD_ADDR;end
   end
   READ_A:state<=READ_B;
   READ_B:state<=MULTIPLY;
   MULTIPLY:state<=WRITE_A;
   WRITE_A:state<=WRITE_B;
   WRITE_B:begin
     state<=READ_A;
     if({1'b0,j}+1'b1<half_size) j<=j+1'b1;
     else begin
       j<=0;
       if({1'b0,base}+(half_size<<1)<N) base<=base+{half_size[LOGN-2:0],1'b0};
       else begin
         base<=0;
         if(stage==LOGN) begin oa<=0;state<=OUT_READ;end
         else begin stage<=stage+1'b1;half_size<=half_size<<1;end
       end
     end
   end
   OUT_READ:state<=OUT_SEND;
   OUT_SEND:begin
     bin_valid<=1;bin_index<=oa[LOGN-2:0];bin_re<=ar;bin_im<=ai;
     bin_power<={1'b0,power_r}+{1'b0,power_i};
     if(oa==OUT_LAST) state<=IDLE;
     else begin oa<=oa+1'b1;state<=OUT_READ;end
   end
   default:state<=IDLE;
   endcase
 end
endmodule
`default_nettype wire
