// Polyphonic client of the shared table reader.
//
//  This file is deliberately a near-verbatim copy of `realistic_voice.v`:
//   every arithmetic expression (envelopes, brightness, vibrato, bow noise,
//   tine scaling) must stay bit-identical so that a timbre fix only has to be
//   reasoned about once and pasted in both places.  The ONLY difference is the
//   ROM read: instead of a private `periodic_interp`, both oscillators are
//   queued and handed to a shared arbiter (req/grant + tagged return), so N
//   voices can share one copy of the 288 Kbit wave tables.
//
//   Why sharing is mandatory: one voice already costs 32/118 BSRAM blocks.
//   Four copies would need 128 > 118, i.e. plain duplication cannot reach even
//   a four-note chord.
//
//   Timing: the arbiter grants at most one read per clock and the reader has a
//   fixed 3-clock latency, so a voice sees its samples ~5 clocks after the tick
//   that requested them.  The engine runs 64 clocks per sample at 99.334 kHz,
//   so 2*N requests + 3 latency clocks must fit inside 64 => N <= 30 in
//   principle, and N = 16 leaves comfortable margin.
module realistic_poly_voice #(
    parameter ROM_FILE="instruments",
    parameter integer VOICE_ID=0,
    parameter integer VW=4
)(
    input wire clk,rst_n,tick,note_on,note_off,instrument,
    input wire [4:0] note_idx,
    input wire [23:0] fcw,
    input wire [7:0] velocity,
    output reg signed [15:0] sample,
    output reg sample_valid,
    output wire busy,
    output reg [4:0] held_note,
    output wire releasing,
    // shared-reader client interface
    output wire req,
    output wire [23:0] req_phase,
    output wire [3:0] req_bank,
    output wire [7:0] req_bright,
    output wire [15:0] req_tag,
    input wire grant,
    input wire ret_valid,
    input wire signed [15:0] ret_sample,
    input wire [15:0] ret_tag
);
    localparam IDLE=3'd0, FADE=3'd1, ATTACK=3'd2, HOLD=3'd3, RELEASE=3'd4;
    reg [2:0] state;
    reg gate,inst,pend_inst;
    reg [1:0] zone,pend_zone;
    reg [23:0] freq0,freq1,pend_freq;
    reg [7:0] vel,pend_vel;
    reg [4:0] pitch_idx,pend_pitch;
    reg [15:0] vel_squared;
    reg [23:0] phase0,phase1,age,lfo;
    // Independent Q16.16 amplitude states and targets, not one envelope
    // multiplied by two fixed weights. Finite ceil tails are <1 output unit.
    reg [31:0] env0,env1;
    reg [15:0] peak0,peak1;
    reg [23:0] tone_env;
    // Declared up here: Verilog implicitly creates a 1-bit net for the first
    // mention of a name, so referencing these from the port/parameter section
    // before their declaration silently truncates them to one bit.
    wire [15:0] tine_product;
    wire [15:0] serial_vel2;
    // velocity^2 comes from the serial note-on multiplier below, not from an
    // array multiplier: it is constant for the whole life of the note.
    wire [15:0] pending_vel2=serial_vel2;
    // Register-dependent tine level. jRhodes3c peak analysis indicates
    // a weak inharmonic component (~-23 dB); larger levels emphasize beating.
    //
    // 2026-10-31: 3000-24*pitch is evaluated from the LIVE note index (not from
    // the registered pend_pitch) because the serial multiplier below starts on
    // the same clock edge as the key press, one edge before pend_pitch updates.
    wire [15:0] tine_coef_now=16'd3000-({11'd0,note_idx}<<4)-({11'd0,note_idx}<<3);

    // ---- note-on multiplier (serial) -------------------------------------
    // Two products are needed exactly once per key press and then held:
    //   vel2 = velocity^2                (16 bit)
    //   peak1 = (vel2 * tine_coef) >> 16 (16 bit)
    // As array multipliers they cost one MULTALU27X18 plus one MULT12X12 per
    // voice -- 32 voices would spend 32 whole DSP blocks on a value that never
    // changes again.  The key press arrives on the same clock as a tick and
    // the FADE->ATTACK transition can only happen on the NEXT tick, 64 clocks
    // later, so ~22 shift-add clocks (~60 LUTs) finish with 40 clocks to spare
    // and produce exactly the same integers.
    //   phase 1: 8 steps for velocity^2, phase 2: 12 steps for vel2*coef.
    reg  [1:0]  tmul_ph;       // 0 idle, 1 velocity^2, 2 tine
    reg  [4:0]  tmul_cnt;
    reg  [31:0] tmul_acc;
    // The multiplicand MUST be wider than 16 bits: the loop shifts it left once
    // per step, and a 16-bit register would drop the high bits before they ever
    // reach the accumulator (classic truncated-multiplier bug).
    reg  [31:0] tmul_a;
    reg  [15:0] tmul_b;
    reg  [11:0] tmul_coef;
    reg  [15:0] tmul_vel2;
    reg  [15:0] tmul_out;
    assign tine_product=tmul_out;
    assign serial_vel2=tmul_vel2;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            tmul_ph<=2'd0; tmul_cnt<=0; tmul_acc<=0; tmul_a<=0; tmul_b<=0;
            tmul_coef<=0; tmul_vel2<=0; tmul_out<=0;
        end else if(note_on) begin
            tmul_ph<=2'd1; tmul_cnt<=5'd8; tmul_acc<=0;
            tmul_a<={24'd0,velocity};
            tmul_b<={8'd0,velocity};
            tmul_coef<=tine_coef_now[11:0];
        end else case(tmul_ph)
            2'd1: if(tmul_cnt!=0) begin
                if(tmul_b[0]) tmul_acc<=tmul_acc+tmul_a;
                tmul_a<=tmul_a<<1; tmul_b<=tmul_b>>1;
                tmul_cnt<=tmul_cnt-1'b1;
            end else begin
                tmul_vel2<=tmul_acc[15:0];
                tmul_ph<=2'd2; tmul_cnt<=5'd12; tmul_acc<=0;
                tmul_a<={16'd0,tmul_acc[15:0]};
                tmul_b<={4'd0,tmul_coef};
            end
            2'd2: if(tmul_cnt!=0) begin
                if(tmul_b[0]) tmul_acc<=tmul_acc+tmul_a;
                tmul_a<=tmul_a<<1; tmul_b<=tmul_b>>1;
                tmul_cnt<=tmul_cnt-1'b1;
            end else begin
                tmul_out<=tmul_acc[31:16];
                tmul_ph<=2'd0;
            end
            default: ;
        endcase
    end

    // 200 = 128+64+8. Synthesising a shift-add keeps this off the DSP budget:
    // an 8-bit variable times a constant has nothing a multiplier would add.
    wire [15:0] pending_level=({8'd0,pend_vel}<<7)+({8'd0,pend_vel}<<6)
                             +({8'd0,pend_vel}<<3);
    wire [15:0] pending_second=pend_inst ? (pending_level>>4) : tine_product;
    wire [31:0] target0={peak0,16'd0},target1={peak1,16'd0};
    wire [31:0] gap0=target0-env0,gap1=target1-env1;
    // Cello attack is a straight ramp, not an exponential approach.
    // Measured (analysis/review_20261031/summary.json) real cello C4 gives
    // t50=210ms / t90=420ms -- exactly a 1:2 ratio, i.e. linear; an RC attack
    // would give 1:3.3.  target0>>15 reaches full scale in 32768 ticks = 330ms
    // at the 99.3kHz engine rate, so t50~165ms / t90~297ms.
    // Step is derived from the target, so it scales with velocity for free.
    wire [32:0] astep0={1'b0,target0[31:15]};
    wire [32:0] astep1={1'b0,target1[31:15]};
    wire [8:0] triangle=lfo[23] ? (9'd511-lfo[22:14]) : lfo[22:14];
    wire signed [9:0] tri_signed=$signed({1'b0,triangle})-10'sd255;
    // 2026-10-31: 24x10 array multiply -> 12x10.  Only the top 12 bits of freq0
    // are needed: the vibrato depth is tri/32768 of the note frequency, so the
    // truncated low bits contribute less than 1/4096 of the depth itself
    // (13.4 cents becomes 13.4 +-0.2 cents).  1 DSP -> 0.5 DSP per voice.
    wire [12:0] freq_round={1'b0,freq0[23:12]}+{12'd0,freq0[11]};
    // Same trick as the bow noise: tri_signed-255 is folded into a constant
    // subtract so the multiply itself is 12x9 unsigned (MULT12X12, 0.5 DSP).
    //   freq*tri - freq*255  ==  (freq-255)*tri  with freq as the multiplier
    wire [20:0] wob_mul ={9'd0,freq_round[11:0]}*{12'd0,triangle};
    wire [20:0] freq_wide={9'd0,freq_round[11:0]};
    wire [20:0] wob_bias=(freq_wide<<8)-freq_wide;
    // 22 bits including the sign bit: max |freq*tri| = 4095*255 < 2^20.  The
    // result MUST stay signed all the way out -- zero-extending a negative
    // intermediate turns a downward wobble into a huge positive pitch jump.
    wire signed [21:0] freq_wobble={1'b0,wob_mul}-{1'b0,wob_bias};
    wire signed [24:0] vibrato=(inst && age>24'd20000) ? (freq_wobble>>>3) : 25'sd0;
    wire [23:0] inc0=freq0+vibrato[23:0];
    wire [23:0] inc1=freq1+vibrato[23:0];

    // Tone evolves continuously after the strike, including at soft velocity.
    reg signed [10:0] bright_sum;
    reg [7:0] brightness;
    wire [8:0] ep_raw={3'd0,vel_squared[15:10]}+{1'b0,tone_env[23:16]};
    wire [7:0] ep_clamped=ep_raw>255 ? 8'd255 : ep_raw[7:0];
    // 2026-10-31: 9x8 array multiply -> 8x5 shift-add.  register_taper is
    // 256-4*pitch, so the product is just ep*(1 - pitch/64): the ceiling keeps
    // the truncation bit-identical to (ep*taper)>>8 while the multiply fits in
    // LUT logic.  0.5 DSP -> 0 DSP per voice.
    wire [12:0] taper_product={5'd0,ep_clamped}*{8'd0,pitch_idx};
    wire [7:0] taper_drop=(taper_product+13'd63)>>6;
    wire [7:0] ep_color=(ep_clamped>=taper_drop) ? (ep_clamped-taper_drop) : 8'd0;
    always @* begin
        if(inst)
            bright_sum=11'sd40+$signed({3'b0,vel[7:1]})
                       +$signed({3'b0,tone_env[23:18]})+(tri_signed>>>5);
        else
            bright_sum=$signed({3'd0,ep_color});
        if(bright_sum<0) brightness=0;
        else if(bright_sum>255) brightness=255;
        else brightness=bright_sum[7:0];
    end

    function [31:0] fall;
        input [31:0] x;
        input [2:0] rate;
        reg [32:0] bias,step;
        reg [5:0] sh;
        begin
            // 2026-10-31: the original wrote one 33-bit adder AND one fixed
            // shifter per case arm (8 arms x 2 calls = ~530 LUT/ALU per voice,
            // the single largest logic block in the voice).  The arm only picks
            // a pair (addend, shift) from  (2^sh - 1, sh), so one constant mux,
            // ONE adder and ONE variable shifter give the same integers:
            //   bias = x + (2^sh - 1);   step = bias >> sh
            case(rate)
                0: begin bias={1'b0,x}+33'd15;     sh=4;  end
                1: begin bias={1'b0,x}+33'd2047;   sh=11; end
                2: begin bias={1'b0,x}+33'd4095;   sh=12; end
                3: begin bias={1'b0,x}+33'd8191;   sh=13; end
                4: begin bias={1'b0,x}+33'd32767;  sh=15; end
                default: begin bias={1'b0,x}+33'd131071; sh=17; end
            endcase
            step=bias>>sh;
            fall=step>={1'b0,x} ? 32'd0 : x-step[31:0];
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; gate<=0; inst<=0; pend_inst<=0; zone<=0; pend_zone<=0;
            freq0<=0; freq1<=0; pend_freq<=0; vel<=0; pend_vel<=0; vel_squared<=0;
            pitch_idx<=0;pend_pitch<=0;
            phase0<=0; phase1<=0; age<=0; lfo<=0;
            env0<=0; env1<=0; peak0<=0; peak1<=0; tone_env<=0; held_note<=0;
        end else if(tick) begin
            phase0<=phase0+inc0; phase1<=phase1+inc1;
            lfo<=lfo+24'd913; // 5.41Hz at the actual engine sample rate
            if(age!=24'hffffff) age<=age+1'b1;
            // 亮度包络衰减速度决定「电钢多久变暗」。
            // 2026-10-31: 原 >>14 (tau=16384 tick=165ms) 太快 —— 实测 vel220 的
            // brightness 从 234 掉到 77 只用 300ms, 于是 100~500ms 的分析窗里
            // h2 只剩 -6.4dB, 而真实 Rhodes 同一时刻是 -1.4dB, 听起来就是
            // 「一敲就没了金属味」。真实 Rhodes 的 h2 衰减 (midi 59 实测):
            //   5ms -0.4dB / 100ms -1.4dB / 400ms -7.1dB / 1.8s -22.3dB
            // 反推 tau ~ 600ms, 取 >>16 (tau=65536 tick=660ms)。
            if(tone_env!=0) tone_env<=tone_env-((tone_env+24'd32767)>>16);
            if(note_on) begin
                // Capture new controls without changing the fading old sound.
                pend_inst<=instrument; pend_freq<=fcw; pend_vel<=velocity;
                held_note<=note_idx;
                pend_pitch<=note_idx;
                pend_zone<=(note_idx<6) ? 0 : (note_idx<12) ? 1 : (note_idx<18) ? 2 : 3;
                gate<=1; state<=FADE;
            end else begin
                if(note_off) gate<=0;
                case(state)
                    IDLE: begin env0<=0; env1<=0; end
                    FADE: begin
                        env0<=fall(env0,0); env1<=fall(env1,0);
                        if(env0<32'd65536 && env1<32'd65536) begin
                            env0<=0; env1<=0;
                            if(gate && !note_off) begin
                                inst<=pend_inst; zone<=pend_zone; vel<=pend_vel;
                                pitch_idx<=pend_pitch;
                                vel_squared<=pending_vel2;
                                freq0<=pend_freq;
                                if(pend_inst) freq1<=pend_freq+(pend_freq>>10);
                                // Electric-piano secondary phase increment is assigned below.
                                // Keep the partial weak relative to the sampled harmonic layer.
                                // (f0<<2)+(f0<<1)+(f0>>2) = 6.25x, 纯移位无乘法器。
                                else freq1<=(pend_freq<<2)+(pend_freq<<1)+(pend_freq>>2);
                                peak0<=pending_level; peak1<=pending_second;
                                phase0<=0; phase1<=pend_inst ? 24'h28a000 : 24'd0;
                                age<=0; lfo<=0; tone_env<={pending_vel2,8'd0};
                                state<=ATTACK;
                            end else state<=IDLE;
                        end
                    end
                    ATTACK: begin
                        if(!gate || note_off) state<=RELEASE;
                        else begin
                            if(inst) begin
                                env0<=(gap0<=astep0[31:0]) ? target0 : env0+astep0[31:0];
                                env1<=(gap1<=astep1[31:0]) ? target1 : env1+astep1[31:0];
                            end else begin
                                env0<=env0+((gap0+32'd63)>>6);
                                env1<=env1+((gap1+32'd31)>>5);
                            end
                            if(gap0<=(target0>>10)+32'd1) begin
                                env0<=target0; env1<=target1; state<=HOLD;
                            end
                        end
                    end
                    HOLD: begin
                        if(!gate || note_off) state<=RELEASE;
                        else if(!inst) begin
                            env0<=fall(env0,5); // fundamental tau 1.32 seconds
                            env1<=fall(env1,4); // tine tau 330ms
                            // 2026-10-31: 原 rate 3 (tau 82ms) 让音叉在 150ms 就掉到
                            // -44dB, 而 jRhodes3c 实测 v220 在 150ms 还有 -21.5dB。
                            // 音叉是 Rhodes 的共振体, 不是一次敲击, 要跟着音一起响。
                        end
                    end
                    RELEASE: begin
                        env0<=fall(env0,inst ? 3 : 2);
                        env1<=fall(env1,inst ? 3 : 2);
                        // Below one amplitude LSB both products round below
                        // one output LSB. Clear residual fractional states so
                        // a released voice is recycled without a ghost tail.
                        if(env0<32'd65536 && env1<32'd65536) begin
                            env0<=0; env1<=0; state<=IDLE;
                        end
                    end
                    default: state<=IDLE;
                endcase
            end
        end
    end
    assign busy=(state!=IDLE);
    assign releasing=(state==RELEASE);

    // Tiny generated bow excitation, not a stored attack or recording.
    reg [22:0] noise_lfsr;
    reg signed [17:0] noise_lp;
    wire signed [17:0] noise_raw={{2{noise_lfsr[15]}},noise_lfsr[15:0]};
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin noise_lfsr<=23'h51a9b3; noise_lp<=0; end
        else if(tick) begin
            noise_lfsr<={noise_lfsr[21:0],noise_lfsr[22]^noise_lfsr[17]};
            noise_lp<=noise_lp+((noise_raw-noise_lp)>>>3);
        end
    end
    // Real cello recordings sit at about -31 dBFS of bow/body noise
    // (analysis/review_20261031/summary.json). The original >>>23 gave -53 dBFS,
    // which reads as "synthetic and glassy". Kept band-limited (>>>3 low-pass)
    // so it lands as rosin texture rather than as hiss.
    // 2026-10-31: 18x16 array multiply -> 10x10.  The bow noise is a -41 dBFS
    // texture under the tone, so the low 8 bits of each operand are inaudible;
    // keeping 10 bits per side moves the multiply from MULTALU27X18 (1 DSP) to
    // MULT12X12 (0.5 DSP).  Scaling is exact:
    //   (noise_lp * env0[31:16]) >> 20  ==  ((noise_lp>>8) * (env>>6)) >> 6
    wire signed [9:0]  noise_hi=noise_lp[17:8];
    wire [9:0]         env_hi=env0[31:22];
    // A signed x signed product makes the mapper reach for MULTALU27X18; the
    // magnitude/negate form below is a plain 10x9 unsigned multiply that fits
    // MULT12X12 and yields exactly the same two's complement result.
    // Negate the complete 10-bit two's-complement value. Dropping the sign bit
    // before subtraction maps -1 to magnitude 513 instead of 1.
    wire [9:0]  noise_mag=noise_hi[9] ? (~noise_hi+10'd1) : {1'b0,noise_hi[8:0]};
    wire [18:0] noise_umag=noise_mag*env_hi;
    wire signed [19:0] noise_product=noise_hi[9] ? -$signed({1'b0,noise_umag})
                                                 :  $signed({1'b0,noise_umag});
    wire signed [31:0] noise_ext={{12{noise_product[19]}},noise_product};
    wire signed [31:0] bow=inst ? (noise_ext>>>6) : 32'sd0;

    // ---- shared-reader client -------------------------------------------
    // Two queued reads per output sample. `nleft` counts what is still to be
    // handed to the arbiter, `cur` says which oscillator the bus currently
    // presents. Requests are held high until granted, which is what lets one
    // reader serve every voice without any voice losing a sample.
    reg [1:0] nleft;
    reg cur;
    reg [23:0] hold_phase0,hold_phase1;
    reg [3:0] hold_bank0,hold_bank1;
    reg [7:0] hold_bright;
    reg [15:0] gain0,gain1;
    wire accepted=req && grant;
    assign req       =(nleft!=2'd0);
    assign req_phase = cur ? hold_phase1 : hold_phase0;
    assign req_bank  = cur ? hold_bank1  : hold_bank0;
    assign req_bright= hold_bright;
    assign req_tag   = {{(15-VW){1'b0}},VOICE_ID[VW-1:0],cur};
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            nleft<=2'd0; cur<=1'b0; hold_phase0<=0; hold_phase1<=0;
            hold_bank0<=0; hold_bank1<=0; hold_bright<=0; gain0<=0; gain1<=0;
        end else begin
            if(tick) begin
                // An idle voice must not spend arbiter slots: 2 reads/sample
                // for 16 permanently-queued voices would eat the whole 64-clock
                // budget and starve the voices that are actually sounding.
                if(state==IDLE) nleft<=2'd0;
                else begin
                    nleft<=2'd2; cur<=1'b0;
                    hold_phase0<=phase0; hold_phase1<=phase1;
                    hold_bank0<={1'b0,inst,zone};
                    hold_bank1<=inst ? {1'b0,inst,zone} : 4'd8;
                    hold_bright<=brightness;
                    gain0<=env0[31:16]; gain1<=env1[31:16];
                end
            end else if(accepted) begin
                if(nleft==2'd2) begin nleft<=2'd1; cur<=1'b1; end
                else            begin nleft<=2'd0; cur<=1'b0; end
            end
        end
    end
    wire hit=ret_valid && (ret_tag[VW:1]==VOICE_ID[VW-1:0]);
    wire [15:0] gain=ret_tag[0] ? gain1 : gain0;
    wire signed [32:0] product=$signed(ret_sample)*$signed({1'b0,gain});
    reg signed [17:0] first_sample;
    wire signed [32:0] mixed=$signed(first_sample)+(product>>>16)+$signed(bow);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin sample<=0; sample_valid<=0; first_sample<=0; end
        else begin
            sample_valid<=0;
            if(hit) begin
                if(!ret_tag[0]) first_sample<=product>>>16;
                else begin
                    sample_valid<=1;
                    if(mixed>32767) sample<=32767;
                    else if(mixed< -32768) sample<= -32768;
                    else sample<=mixed[15:0];
                end
            end
        end
    end
endmodule
