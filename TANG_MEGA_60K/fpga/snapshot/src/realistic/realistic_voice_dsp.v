// One voice's worth of arithmetic, as a pure combinational function of its
// state word.  This is the module that used to live inside every
// `realistic_poly_voice`: it is instantiated exactly ONCE and swept over the
// state RAM, so 32 voices cost one datapath instead of 32.
//
// Everything here must stay bit-identical to `realistic_poly_voice.v`; the only
// structural change is that the registers became `st_in` / `st_out` ports.
//
// State word layout (360 bits, 10 x 36-bit BSRAM lanes, 32 entries):
//   [2:0]     state          IDLE/FADE/ATTACK/HOLD/RELEASE
//   [3]       gate
//   [4]       inst           0 = electric piano, 1 = cello
//   [6:5]     zone           0..3, table bank selector
//   [14:7]    vel
//   [19:15]   pitch_idx
//   [23:20]   spare
//   [47:24]   freq0
//   [71:48]   freq1
//   [95:72]   phase0
//   [119:96]  phase1
//   [151:120] env0
//   [183:152] env1
//   [199:184] peak0
//   [215:200] peak1
//   [239:216] tone_env
//   [263:240] age
//   [287:264] lfo
//   [303:288] vel_squared
//   [327:304] pend_freq     fcw captured at note-on, applied at ATTACK
//   [335:328] pend_vel
//   [340:336] pend_pitch
//   [342:341] pend_zone
//   [343]     pend_inst
//   [348:344] held_note
//   [359:358] vib            vibrato depth 0..3, latched at note-on
//   [357:349] spare
module realistic_voice_dsp #(
    parameter integer VW=5
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        tick,
    input  wire [359:0] st_in,
    // global bow-excitation state (identical in every voice, so shared)
    input  wire signed [17:0] noise_lp,
    output wire [359:0] st_out,
    output wire        active,
    output wire        req0_valid,
    output wire [23:0] req0_phase,
    output wire [3:0]  req0_bank,
    output wire [7:0]  req0_bright,
    output wire        req1_valid,
    output wire [23:0] req1_phase,
    output wire [3:0]  req1_bank,
    output wire [15:0] gain0,
    output wire [15:0] gain1,
    output wire [4:0]  held_note_o,
    output wire [2:0]  state_o,
    output wire signed [31:0] bow_o
);
    localparam IDLE=3'd0, FADE=3'd1, ATTACK=3'd2, HOLD=3'd3, RELEASE=3'd4;

    // ---- unpack ---------------------------------------------------------
    wire [2:0]  s_state     = st_in[2:0];
    wire        s_gate      = st_in[3];
    wire        s_inst      = st_in[4];
    wire [1:0]  s_zone      = st_in[6:5];
    wire [7:0]  s_vel       = st_in[14:7];
    wire [4:0]  s_pitch     = st_in[19:15];
    wire [23:0] s_freq0     = st_in[47:24];
    wire [1:0]  s_vib       = st_in[359:358];
    wire [23:0] s_freq1     = st_in[71:48];
    wire [23:0] s_phase0    = st_in[95:72];
    wire [23:0] s_phase1    = st_in[119:96];
    wire [31:0] s_env0      = st_in[151:120];
    wire [31:0] s_env1      = st_in[183:152];
    wire [15:0] s_peak0     = st_in[199:184];
    wire [15:0] s_peak1     = st_in[215:200];
    wire [23:0] s_tone      = st_in[239:216];
    wire [23:0] s_age       = st_in[263:240];
    wire [23:0] s_lfo       = st_in[287:264];
    wire [15:0] s_velsq     = st_in[303:288];
    wire [23:0] s_pfreq     = st_in[327:304];
    wire [7:0]  s_pvel      = st_in[335:328];
    wire [4:0]  s_ppitch    = st_in[340:336];
    wire [1:0]  s_pzone     = st_in[342:341];
    wire        s_pinst     = st_in[343];
    wire [4:0]  s_note      = st_in[348:344];

    // ---- modulation (identical maths to realistic_poly_voice) -----------
    wire [8:0] triangle = s_lfo[23] ? (9'd511-s_lfo[22:14]) : s_lfo[22:14];
    wire signed [9:0] tri_signed = $signed({1'b0,triangle})-10'sd255;
    wire [12:0] freq_round = {1'b0,s_freq0[23:12]}+{12'd0,s_freq0[11]};
    wire [20:0] wob_mul  = {9'd0,freq_round[11:0]}*{12'd0,triangle};
    wire [20:0] freq_wide= {9'd0,freq_round[11:0]};
    wire [20:0] wob_bias = (freq_wide<<8)-freq_wide;
    // 22 bits including the sign bit: max |freq*tri| = 4095*255 < 2^20.  The
    // result MUST stay signed all the way out -- zero-extending a negative
    // intermediate turns a downward wobble into a huge positive pitch jump.
    wire signed [21:0] freq_wobble = {1'b0,wob_mul}-{1'b0,wob_bias};
    // Vibrato depth is per note: the electric piano only wobbles when the
    // player asks for it, the cello keeps its bow vibrato as a floor (2).
    wire [1:0] vib_eff = (s_vib > (s_inst ? 2'd2 : 2'd0)) ? s_vib
                                                          : (s_inst ? 2'd2 : 2'd0);
    // 2026-11-01: depth was 1/16, 1/8, 1/4 of freq_wobble = +-6.7 / 13.4 / 26.9
    // cents, which is about 20% shallower than the additive engine's
    // +-8.3 / 16.6 / 32.9 and was reported as "vibrato is less obvious than
    // before". Each step now adds a second partial (1/64, 1/32, 1/16) so the
    // three depths land on 8.4 / 16.8 / 33.5 cents.
    wire signed [21:0] wob_scaled = (vib_eff==2'd0) ? 22'sd0 :
                                    (vib_eff==2'd1) ? ((freq_wobble>>>4)+(freq_wobble>>>6)) :
                                    (vib_eff==2'd2) ? ((freq_wobble>>>3)+(freq_wobble>>>5)) :
                                                      ((freq_wobble>>>2)+(freq_wobble>>>4));
    // 201 ms (20000 samples) of dead time made the effect feel like it never
    // arrived. 20 ms is enough to hide the onset transient.
    wire signed [24:0] vibrato = (s_age>24'd2000) ? $signed(wob_scaled) : 25'sd0;
    wire [23:0] inc0 = s_freq0+vibrato[23:0];
    wire [23:0] inc1 = s_freq1+vibrato[23:0];

    // ---- portamento ------------------------------------------------------
    // glide_sel (0..3) arrives in state bits [350:349]. The start frequency is
    // simply the freq0 this voice was already running -- the note-on word
    // carries freq0 over from the previous note, so no extra state is needed.
    // Shift 12/13/14 samples = 41 / 82 / 166 ms time constants at 99.33 kHz.
    wire [1:0]  s_gk     = st_in[350:349];
    wire        g_active = (s_gk!=2'd0) && (s_freq0!=24'd0) && (s_freq0!=s_pfreq);
    wire signed [24:0] gdiff = $signed({1'b0,s_pfreq})-{1'b0,s_freq0};
    wire [24:0] gstep = (gdiff[24] ? (~gdiff+25'd1) : gdiff) >>> ({21'd0,s_gk}+25'd11);
    wire signed [24:0] gnext = $signed({1'b0,s_freq0})
                             + (gdiff[24] ? -$signed(gstep) : $signed(gstep));
    // Snap only when the ramp OVERSHOOTS the target.  The comparison direction
    // depends on which way we are travelling -- an upward glide sits below the
    // target for its whole life, so a bare "< target" test snapped to the
    // target on the very first sample and killed the portamento.
    wire [23:0] gnext_c = gdiff[24] ? ((gnext[24] || gnext[23:0] <= s_pfreq) ? s_pfreq : gnext[23:0])
                                    : ((gnext[24] || gnext[23:0] >= s_pfreq) ? s_pfreq : gnext[23:0]);

    // ---- brightness ------------------------------------------------------
    wire [8:0] ep_raw = {3'd0,s_velsq[15:10]}+{1'b0,s_tone[23:16]};
    wire [7:0] ep_clamped = ep_raw>255 ? 8'd255 : ep_raw[7:0];
    wire [12:0] taper_product = {5'd0,ep_clamped}*{8'd0,s_pitch};
    wire [7:0]  taper_drop = (taper_product+13'd63)>>6;
    wire [7:0]  ep_color = (ep_clamped>=taper_drop) ? (ep_clamped-taper_drop) : 8'd0;
    reg  signed [10:0] bright_sum;
    reg  [7:0] brightness;
    always @* begin
        if(s_inst)
            bright_sum = 11'sd40+$signed({3'b0,s_vel[7:1]})
                        +$signed({3'b0,s_tone[23:18]})+(tri_signed>>>5);
        else
            bright_sum = $signed({3'd0,ep_color});
        if(bright_sum<0) brightness=0;
        else if(bright_sum>255) brightness=255;
        else brightness=bright_sum[7:0];
    end

    // ---- envelope decay --------------------------------------------------
    function [31:0] fall;
        input [31:0] x;
        input [2:0] rate;
        reg [32:0] bias,step;
        reg [5:0] sh;
        begin
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

    // ---- attack / release geometry --------------------------------------
    wire [31:0] target0 = {s_peak0,16'd0};
    wire [31:0] target1 = {s_peak1,16'd0};
    wire [31:0] gap0 = target0-s_env0;
    wire [31:0] gap1 = target1-s_env1;
    // Smooth bowed onset: 4096 audio ticks (~41 ms at 99.3 kHz).
    // The former 32768-tick ramp (~330 ms) obscured the beat in duets.
    wire [32:0] astep0 = {1'b0,target0[31:12]};
    wire [32:0] astep1 = {1'b0,target1[31:12]};

    // ---- note-on values computed at the FADE -> ATTACK edge --------------
    // jRhodes3c peak analysis places a weak inharmonic partial near 6.70*f0.
    // The shift/add ratio 6.6875 approximates that partial.
    // The former 6.25 ratio lies close to the wavetable's sixth harmonic.
    function [23:0] ratio1;
        input [23:0] f;
        input        inst;
        begin
            ratio1 = inst ? (f+(f>>10))
                          : ((f<<2)+(f<<1)+(f>>1)+(f>>3)+(f>>4));
        end
    endfunction
    wire [15:0] vel_sq_new  = {8'd0,s_pvel}*{8'd0,s_pvel};
    // tine level halved: the real partial is -23 dB below the fundamental, the
    // old value worked out to -17.8 dB.
    wire [15:0] tine_coef   = 16'd1500-({11'd0,s_ppitch}<<3)-({11'd0,s_ppitch}<<2);
    wire [27:0] peak1_prod  = vel_sq_new*{4'd0,tine_coef[11:0]};
    wire [15:0] peak1_new   = peak1_prod[27:16];
    wire [15:0] peak0_new   = ({8'd0,s_pvel}<<7)+({8'd0,s_pvel}<<6)+({8'd0,s_pvel}<<3);
    wire [23:0] freq1_new   = ratio1(s_pfreq, s_pinst);

    // ---- bow noise -------------------------------------------------------
    wire signed [9:0]  noise_hi = noise_lp[17:8];
    wire [9:0]         env_hi   = s_env0[31:22];
    wire [9:0]         noise_mag = noise_hi[9] ? (~noise_hi+10'd1) : {1'b0,noise_hi[8:0]};
    wire [18:0]        noise_umag = noise_mag*env_hi;
    wire signed [19:0] noise_product = noise_hi[9] ? -$signed({1'b0,noise_umag})
                                                   :  $signed({1'b0,noise_umag});
    wire signed [31:0] noise_ext = {{12{noise_product[19]}},noise_product};
    wire signed [31:0] bow = s_inst ? (noise_ext>>>6) : 32'sd0;

    // ---- next state ------------------------------------------------------
    reg [2:0]  n_state;
    reg        n_gate, n_inst, n_pinst;
    reg [1:0]  n_zone, n_pzone;
    reg [1:0]  n_vib, n_gk;
    reg [23:0] n_freq0, n_freq1, n_phase0, n_phase1, n_tone, n_age, n_lfo, n_pfreq;
    reg [31:0] n_env0, n_env1;
    reg [15:0] n_peak0, n_peak1, n_velsq;
    reg [7:0]  n_vel, n_pvel;
    reg [4:0]  n_pitch, n_ppitch, n_note;

    always @* begin
        // hold by default: a voice that is not ticked keeps every field
        n_state=s_state; n_gate=s_gate; n_inst=s_inst; n_pinst=s_pinst;
        n_vib=s_vib;     n_gk=s_gk;
        n_zone=s_zone;   n_pzone=s_pzone;
        n_freq0=s_freq0; n_freq1=s_freq1; n_phase0=s_phase0; n_phase1=s_phase1;
        n_env0=s_env0;   n_env1=s_env1;   n_peak0=s_peak0;   n_peak1=s_peak1;
        n_tone=s_tone;   n_age=s_age;     n_lfo=s_lfo;       n_velsq=s_velsq;
        n_vel=s_vel;     n_pitch=s_pitch; n_note=s_note;
        n_pfreq=s_pfreq; n_pvel=s_pvel;   n_ppitch=s_ppitch;
        if(tick) begin
            n_phase0 = s_phase0+inc0;
            n_phase1 = s_phase1+inc1;
            n_lfo    = s_lfo+24'd913;      // 5.41 Hz at the engine rate
            if(s_age!=24'hffffff) n_age = s_age+1'b1;
            if(s_tone!=0) n_tone = s_tone-((s_tone+24'd32767)>>16);
            begin
                case(s_state)
                    IDLE: begin n_env0=0; n_env1=0; end
                    FADE: begin
                        n_env0 = fall(s_env0,0);
                        n_env1 = fall(s_env1,0);
                        if(s_env0<32'd65536 && s_env1<32'd65536) begin
                            n_env0 = 0;
                            n_env1 = 0;
                            if(s_gate) begin
                                n_inst   = s_pinst;
                                n_zone   = s_pzone;
                                n_vel    = s_pvel;
                                n_pitch  = s_ppitch;
                                n_velsq  = vel_sq_new;
                                n_freq0  = g_active ? s_freq0 : s_pfreq;
                                n_freq1  = g_active ? ratio1(s_freq0,s_pinst) : freq1_new;
                                n_peak0  = peak0_new;
                                n_peak1  = peak1_new;
                                n_phase0 = 0;
                                n_phase1 = s_pinst ? 24'h28a000 : 24'd0;
                                n_age    = 0;
                                n_lfo    = 0;
                                n_tone   = {vel_sq_new,8'd0};
                                n_state  = ATTACK;
                            end else n_state = IDLE;
                        end
                    end
                    ATTACK: begin
                        if(!s_gate) n_state = RELEASE;
                        else begin
                            if(s_inst) begin
                                n_env0 = (gap0<=astep0[31:0]) ? target0 : s_env0+astep0[31:0];
                                n_env1 = (gap1<=astep1[31:0]) ? target1 : s_env1+astep1[31:0];
                            end else begin
                                n_env0 = s_env0+((gap0+32'd63)>>6);
                                n_env1 = s_env1+((gap1+32'd31)>>5);
                            end
                            if(gap0<=(target0>>10)+32'd1) begin
                                n_env0=target0; n_env1=target1; n_state=HOLD;
                            end
                        end
                    end
                    HOLD: begin
                        if(!s_gate) n_state = RELEASE;
                        else if(!s_inst) begin
                            n_env0 = fall(s_env0,5);   // fundamental tau 1.32 s
                            n_env1 = fall(s_env1,4);   // tine tau 330 ms
                        end
                    end
                    RELEASE: begin
                        n_env0 = fall(s_env0,s_inst ? 3 : 2);
                        n_env1 = fall(s_env1,s_inst ? 3 : 2);
                        if(s_env0<32'd65536 && s_env1<32'd65536) begin
                            n_env0=0; n_env1=0; n_state=IDLE;
                        end
                    end
                    default: n_state = IDLE;
                endcase
                // glide ramp: runs on every tick while the voice is sounding.
                // It must NOT run on the FADE -> ATTACK tick (start point) --
                // s_state is still FADE there, so this branch is skipped.
                if(n_gk!=2'd0 && (s_state==ATTACK || s_state==HOLD)) begin
                    n_freq0 = gnext_c;
                    n_freq1 = ratio1(gnext_c, s_inst);
                end
            end
        end
    end

    assign st_out = {n_vib, 7'd0, n_gk, n_note, n_pinst, n_pzone, n_ppitch, n_pvel, n_pfreq,
                     n_velsq, n_lfo, n_age, n_tone, n_peak1, n_peak0,
                     n_env1, n_env0, n_phase1, n_phase0, n_freq1, n_freq0,
                     4'd0, n_pitch, n_vel, n_zone, n_inst, n_gate, n_state};

    // Reads are issued for the CURRENT phase (pre-increment), exactly like the
    // per-voice module which latched hold_phase in the same tick that advanced
    // the accumulator.
    assign active    = (s_state!=IDLE);
    assign req0_valid= active;
    assign req0_phase= s_phase0;
    assign req0_bank = {1'b0,s_inst,s_zone};
    assign req0_bright = brightness;
    assign req1_valid= active;
    assign req1_phase= s_phase1;
    assign req1_bank = s_inst ? {1'b0,s_inst,s_zone} : 4'd8;
    assign gain0     = s_env0[31:16];
    assign gain1     = s_env1[31:16];
    assign held_note_o = s_note;
    assign state_o   = s_state;

    // The mixer adds the bow excitation once per active voice, in parallel with
    // the table-return products (addition is associative, so the sum is
    // identical to the per-voice `first + product + bow` of the old module).
    assign bow_o = bow;
endmodule
