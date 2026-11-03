`default_nettype none
// 1024-sample periodic Hann FFT/N of the actual DAC mono fold.
// 64 peak bands: 1..16 / 17..48 by 2 / 49..112 by 4 / 113..240 by 8.
// At 49,667 Hz: 48.503-Hz spacing, centers/ranges reach 11,640.703 Hz.
// Approximate log2(power), quarter-bit resolution: subtract log2(64),
// then 4.5 pixels per power octave, saturating at 88 (~59 dB range).
// A full-scale coherent Hann sine approaches 88; DC and bins >240 are ignored.
// read_addr -> level is synchronous (one clock). ready latches after the first
// publish of a completed frame. Unpublished banks never appear on the read port.
module hdmi_spectrum(
 input wire clk,rst_n,sample_valid,input wire signed [15:0] sample,
 input wire publish,input wire [5:0] read_addr,output reg [7:0] level,
 output reg ready,output wire [31:0] dropped_frames
);
 wire bin_valid;
 wire [8:0] bin_index;
 wire signed [17:0] bin_re,bin_im;
 wire [36:0] bin_power;
 visual_fft #(.LOGN(10),.WINDOW(1)) fft(
   .clk(clk),.rst_n(rst_n),.sample_valid(sample_valid),.sample(sample),
   .dropped_frames(dropped_frames),.bin_valid(bin_valid),.bin_index(bin_index),
   .bin_re(bin_re),.bin_im(bin_im),.bin_power(bin_power));

 reg front_bank,back_ready,frame_active;
 reg [36:0] peak;
 reg [7:0] bands[0:127];
 reg [7:0] front_level;
 wire swap=publish && back_ready;
 wire [36:0] next_peak=(bin_power>peak)?bin_power:peak;
 reg [5:0] band_address;
 reg band_end;
 // Register band peaks before logarithmic height conversion. FFT output to
 // peak selection and peak-to-log now occupy separate pixel clock periods.
 reg height_valid;
 reg [36:0] height_power;
 reg [6:0] height_address;
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin height_valid<=0;height_power<=0;height_address<=0;end
 else begin
   height_valid<=bin_valid && frame_active && bin_index>=1 && bin_index<=240 && band_end;
   if(bin_valid && frame_active && bin_index>=1 && bin_index<=240 && band_end)begin
     height_power<=next_peak;height_address<={~front_bank,band_address};
   end
 end

 always @* begin
   band_address=0;band_end=0;
   if(bin_index>=1 && bin_index<=16) begin
     band_address=6'(bin_index-1);band_end=1;
   end else if(bin_index<=48) begin
     band_address=6'(16+((bin_index-17)>>1));band_end=(bin_index[0]==0);
   end else if(bin_index<=112) begin
     band_address=6'(32+((bin_index-49)>>2));band_end=(bin_index[1:0]==0);
   end else if(bin_index<=240) begin
     band_address=6'(48+((bin_index-113)>>3));band_end=(bin_index[2:0]==0);
   end
 end
 function [7:0] power_height(input [36:0] p);
   integer k;
   reg [7:0] log_quarters,delta,height;
   begin
     log_quarters=0;
     for(k=2;k<37;k=k+1)
       if(p[k]) log_quarters=8'(k*4)+{6'd0,p[k-1],p[k-2]};
     delta=(log_quarters>24)?log_quarters-8'd24:8'd0;
     height=delta+(delta>>3);
     power_height=(height>88)?8'd88:height;
   end
 endfunction
 // Both ports and the storage deliberately have no reset, allowing block RAM.
 // Every one of the 64 back-bank addresses is written before back_ready rises.
 always @(posedge clk) begin
   if(height_valid)bands[height_address]<=power_height(height_power);
   front_level<=bands[{swap ? ~front_bank : front_bank,read_addr}];
 end
 always @* level=ready ? front_level : 8'd0;
 always @(posedge clk or negedge rst_n)
 if(!rst_n) begin
   front_bank<=0;back_ready<=0;frame_active<=0;peak<=0;ready<=0;
 end else begin
   if(swap) begin front_bank<=~front_bank;back_ready<=0;ready<=1;end
   if(bin_valid) begin
     if(bin_index==0) begin
       // Decide once for the WHOLE transform. A publish during a skipped frame
       // cannot cause a partially accumulated bank to become eligible.
       frame_active<=!back_ready;peak<=0;
     end else if(frame_active && bin_index<=240) begin
       if(band_end) peak<=0;
       else peak<=next_peak;
     end
     if(bin_index==511 && frame_active) begin back_ready<=1;frame_active<=0;end
   end
 end
endmodule
`default_nettype wire
