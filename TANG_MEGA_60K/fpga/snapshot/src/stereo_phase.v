// Audible phase-derived stereo from a mono instrument/effect mix.
// H(z)=(z^-1-g)/(1-g*z^-1), g=31/32, fc ~=502Hz at 99.335kHz.
// S=H(M)/2; L=M+S, R=M-S. Both outputs drive the DAC; HDMI observes it.
// This is algorithmic stereo, not a stereo microphone recording.
// One Q8 state, no delay RAM, multiplier or sample-rate/pitch changes.
module stereo_phase(input wire clk,rst_n,tick,
 input wire signed [15:0] mid,
 output reg signed [15:0] left,right);
 reg signed [31:0] state_q;
 // Multiply by 31/32, rounding toward zero. Unlike a simple arithmetic
 // shift feedback, zero input decays to exactly zero (no idle limit cycle).
 function signed [31:0] pole;
  input signed [31:0] value;
  reg [31:0] magnitude,scaled;
  begin
   magnitude=value[31]?-value:value;
   scaled=magnitude-((magnitude+32'd31)>>5);
   pole=value[31]?-$signed(scaled):$signed(scaled);
  end
 endfunction
 wire signed [31:0] x_q={{8{mid[15]}},mid,8'd0};
 wire signed [31:0] next_state=x_q+pole(state_q);
 wire signed [31:0] phase_q=state_q-pole(next_state);
 wire signed [31:0] side_raw=phase_q>>>9;
 wire signed [31:0] m=$signed(mid);
 wire signed [31:0] up=32'sd32767-m,dn=m+32'sd32768;
 wire signed [31:0] room=(up<dn)?up:dn;
 wire signed [31:0] side=(side_raw>room)?room:
                              (side_raw< -room)?-room:side_raw;
 wire signed [31:0] l=m+side,r=m-side;
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin state_q<=0;left<=0;right<=0;end
 else if(tick)begin state_q<=next_state;left<=l[15:0];right<=r[15:0];end
endmodule
