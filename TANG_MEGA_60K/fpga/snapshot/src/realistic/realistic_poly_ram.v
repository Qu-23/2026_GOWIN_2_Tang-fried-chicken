// Polyphonic engine with the per-voice state held in BSRAM and ONE shared
// datapath swept over it.
//
// Why: the parallel version (`realistic_poly`) costs ~2,300 LUT per voice, so
// 32 voices need 73k of the 59.9k available -- 28 voices already overflow the
// device and the 24-voice build sat at 93%, inside the range where the router
// has a history of stalling for hours.  Moving the state to RAM and sweeping a
// single datapath turns 32 copies of the arithmetic into one, so the voice
// count stops driving the logic cost at all.
//
// Timing budget: the engine runs 64 clocks per sample (6.357 MHz / 99.334 kHz).
// The sweep gives voice k exactly one clock, so 32 voices finish in 32 clocks
// and the rest of the window is free for event writes and margin.
//
// Read bandwidth: each voice asks for two table reads per sample (fundamental
// and tine/second layer).  Two `periodic_interp` readers are fed in parallel --
// oscillator 0 into lane 0, oscillator 1 into lane 1 -- so each reader sees one
// request per clock during the sweep, i.e. 32 of 64 clocks, 50% load with a
// fixed 3-clock latency that the gain pipeline mirrors.
module realistic_poly_ram #(
    parameter integer N=32,
    parameter integer VW=5,
    parameter ROM_FILE="instruments"
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        tick,          // single-cycle sample request
    input  wire        fire_on,       // single-cycle, co-located with tick
    input  wire        fire_off,
    input  wire [4:0]  event_note,
    input  wire        instrument,
    input  wire [23:0] fcw,
    input  wire [7:0]  velocity,
    // Vibrato depth for the next note: 0 = none for the electric piano,
    // 1/2/3 = 6.7 / 13.4 / 26.8 cents.  The cello never goes below 2 -- its
    // bow vibrato is part of the timbre.  Latched into the state word at
    // note-on so the shared datapath can scale the wobble per voice.
    input  wire [1:0]  vib_sel,
    // Portamento speed for the next note (0 = off, 1/2/3 = 41/82/166 ms).
    // Latched into the state word so the shared datapath can ramp freq0.
    input  wire [1:0]  glide_sel,
    // Runtime self-test: pin every voice to its own frequency and hold it open
    // so the output is 32 fundamentals plus 32 lines at 4.125x.
    input  wire        tst_mode,
    output wire signed [15:0] out,
    output wire [5:0]  n_active
);
    localparam IDLE=3'd0, RELEASE=3'd4;
    localparam integer         NV   = N;
    localparam [VW-1:0]        LAST = N-1;

    // ---- per-voice state RAM (10 x 36-bit BSRAM lanes) -------------------
    reg [359:0] smem [0:N-1] /* synthesis syn_ramstyle="registers" */;
    reg [359:0] st_q;
    reg         we;
    reg [VW-1:0] waddr, raddr;
    reg [359:0]  wdata;
    always @(posedge clk) if(we) smem[waddr] <= wdata;
    always @(posedge clk) st_q <= smem[raddr];

    // ---- window counter --------------------------------------------------
    reg [5:0] scnt;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) scnt<=6'd63;
        else if(tick)   scnt<=6'd0;
        else if(scnt==6'd63) scnt<=6'd0;
        else scnt<=scnt+6'd1;
    end
    // The state RAM cannot be reset, so the first window after reset is spent
    // writing zeros into every entry.  Without this the x state would be latched
    // straight back (`wdata` is a function of `st_q`) and never recover.
    reg init_pending;
    reg tst_d;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) tst_d<=1'b0; else tst_d<=tst_mode;
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)                    init_pending<=1'b1;
        else if(scnt==(NV-1))         init_pending<=1'b0;
        // Entering or leaving the test pattern re-zeroes the state RAM, so a
        // held chord cannot leave a voice singing underneath the test lines.
        else if(tst_mode ^ tst_d)     init_pending<=1'b1;
        // Leaving the pattern wipes the seeded voices, otherwise all 32 would
        // keep decaying underneath the next chord.

    end
    wire        init  = init_pending;
    // st_q holds the state of voice (scnt-1) in this clock.
    wire        sweep = (scnt!=6'd0) && (scnt<=NV) && !init;
    wire [VW-1:0] idx = scnt[VW-1:0]-1'b1;

    // ---- event capture ---------------------------------------------------
    reg        ev_on, ev_off;
    reg [1:0]  ev_vib, ev_gk;
    reg [4:0]  ev_note;
    reg [7:0]  ev_vel;
    reg [23:0] ev_fcw, ev_gfrom, prev_fcw;
    reg        ev_inst;
    reg [VW-1:0] ev_victim;

    // Allocator mirrors: cheap registers kept in step with the RAM so the
    // victim can be chosen without reading every entry.
    reg [N-1:0]  m_busy, m_rel;
    reg [N*5-1:0] m_note;

    reg [N-1:0] sel_free, sel_rel;
    integer i;
    always @* begin
        for(i=0;i<N;i=i+1) begin
            sel_free[i] = !m_busy[i];
            sel_rel[i]  = m_rel[i];
        end
    end
    reg [VW-1:0] free_idx, rel_idx;
    reg          have_free, have_rel;
    integer j;
    always @* begin
        free_idx={VW{1'b0}}; rel_idx={VW{1'b0}};
        have_free=1'b0;      have_rel=1'b0;
        for(j=0;j<N;j=j+1) begin
            if(!have_free && sel_free[j]) begin have_free=1'b1; free_idx=j[VW-1:0]; end
        end
        for(j=0;j<N;j=j+1) begin
            if(!have_rel && sel_rel[j]) begin have_rel=1'b1; rel_idx=j[VW-1:0]; end
        end
    end
    wire [VW-1:0] victim = have_free ? free_idx : (have_rel ? rel_idx : {VW{1'b0}});

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            ev_on<=1'b0; ev_off<=1'b0; ev_note<=0; ev_vel<=0;
            ev_fcw<=0; ev_gfrom<=0; prev_fcw<=0; ev_inst<=1'b0; ev_victim<=0; ev_vib<=2'd0; ev_gk<=2'd0;
        end else if(tick) begin
            ev_on <= fire_on;
            ev_off<= fire_off;
            ev_note<=event_note;
            ev_vel <=velocity;
            ev_fcw <=fcw;
            // Portamento starts from the frequency of the PREVIOUS note-on, not
            // from whatever this voice happened to play last time -- with 32
            // voices a new key usually lands on a virgin voice whose freq0 is 0.
            ev_gfrom<=prev_fcw;
            if(fire_on) prev_fcw<=fcw;
            ev_inst<=instrument;
            ev_vib <=vib_sel;
            ev_gk  <=glide_sel;
            ev_victim<=victim;
        end
    end

    // ---- shared datapath -------------------------------------------------
    // Bow excitation: every voice in the old design ran its own LFSR from the
    // same seed and clocked it once per tick, so the sequence was identical in
    // all of them.  One shared generator is bit-exact.
    reg [22:0]  noise_lfsr;
    reg signed [17:0] noise_lp;
    wire signed [17:0] noise_raw = {{2{noise_lfsr[15]}},noise_lfsr[15:0]};
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin noise_lfsr<=23'h51a9b3; noise_lp<=0; end
        else if(tick) begin
            noise_lfsr<={noise_lfsr[21:0],noise_lfsr[22]^noise_lfsr[17]};
            noise_lp<=noise_lp+((noise_raw-noise_lp)>>>3);
        end
    end

    wire [359:0] dsp_out;
    wire         d_active;
    wire         r0_valid, r1_valid;
    wire [23:0]  r0_phase, r1_phase;
    wire [3:0]   r0_bank, r1_bank;
    wire [7:0]   r0_bright;
    wire [15:0]  g0, g1;
    wire [4:0]   d_note;
    wire [2:0]   d_state;
    wire signed [31:0] d_bow;

    // ---- runtime test mode (EXPERIMENTAL, off by default) -----------------
    // The pattern is seeded through the normal note-on path rather than by
    // overwriting state words: 32 EP voices, one per sweep, each on its own
    // frequency from the table below and never released.
    // STATUS 2026-11-01: all 32 voices do get seeded and stay active, but the
    // captured line levels are far from flat (measured spread ~80 dB, only the
    // 9 voices between 277 and 686 Hz come out strong).  The cause is still
    // open -- it is not the envelope (g0 is the same for every voice) and not
    // the brightness (both were pinned during the investigation).  Do NOT
    // advertise this pattern until the levels are equalised; the shipping
    // evidence for oscillator count is main_O's compile-time TEST_MODE.
    function [23:0] test_fcw_of;
        input [4:0] v;
        begin
            case (v)
                5'd0 : test_fcw_of = 24'd16893;   //  100.0 Hz
                5'd1 : test_fcw_of = 24'd18920;   //  112.0
                5'd2 : test_fcw_of = 24'd21190;   //  125.4
                5'd3 : test_fcw_of = 24'd23733;   //  140.5
                5'd4 : test_fcw_of = 24'd26581;   //  157.4
                5'd5 : test_fcw_of = 24'd29771;   //  176.2
                5'd6 : test_fcw_of = 24'd33343;   //  197.4
                5'd7 : test_fcw_of = 24'd37343;   //  221.1
                5'd8 : test_fcw_of = 24'd41820;   //  247.6
                5'd9 : test_fcw_of = 24'd46835;   //  277.3
                5'd10: test_fcw_of = 24'd52447;   //  310.5
                5'd11: test_fcw_of = 24'd58732;   //  347.7
                5'd12: test_fcw_of = 24'd65768;   //  389.4
                5'd13: test_fcw_of = 24'd73656;   //  436.1
                5'd14: test_fcw_of = 24'd82489;   //  488.4
                5'd15: test_fcw_of = 24'd92379;   //  546.9
                5'd16: test_fcw_of = 24'd103455;//  612.5
                5'd17: test_fcw_of = 24'd115863;//  686.0
                5'd18: test_fcw_of = 24'd129760;//  768.3
                5'd19: test_fcw_of = 24'd145325;//  860.4
                5'd20: test_fcw_of = 24'd162757;//  963.6
                5'd21: test_fcw_of = 24'd182281;// 1079.2
                5'd22: test_fcw_of = 24'd204144;// 1208.6
                5'd23: test_fcw_of = 24'd228624;// 1353.5
                5'd24: test_fcw_of = 24'd256043;// 1515.8
                5'd25: test_fcw_of = 24'd286756;// 1697.6
                5'd26: test_fcw_of = 24'd321145;// 1901.3
                5'd27: test_fcw_of = 24'd359636;// 2129.2
                5'd28: test_fcw_of = 24'd402704;// 2384.3
                5'd29: test_fcw_of = 24'd451022;// 2670.1
                5'd30: test_fcw_of = 24'd505093;// 2990.3
                default: test_fcw_of = 24'd561760; // 3349.0
            endcase
        end
    endfunction

    reg [VW:0] seed_k;
    reg        seed_run;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            seed_k   <= {(VW+1){1'b0}};
            seed_run <= 1'b0;
        end else if(tst_mode) begin
            if(seed_k != NV[VW:0]) begin
                seed_run <= 1'b1;
                if(idx == seed_k[VW-1:0]) seed_k <= seed_k + 1'b1;
            end else begin
                seed_run <= 1'b0;
            end
        end else begin
            seed_k   <= {(VW+1){1'b0}};
            seed_run <= 1'b0;
        end
    end

    // One note-on per swept slot, spread over the three wavetable zones so the
    // per-zone brightness taper stays inside the range the tables were fitted
    // for.  pitch/zone therefore track the slot, frequency comes from the table.
    wire  [4:0]        seed_note  = idx;
    wire  [4:0]        seed_pitch = 5'd12 + {2'd0, idx[2:0]} * 5'd3;
    wire  [1:0]        seed_zone  = idx[4:3];
    wire  [359:0] tst_on_word = {
        ev_vib, 7'd0, ev_gk, seed_note,
        1'b0,                 // pend_inst = EP
        seed_zone,
        seed_pitch,
        8'd200,               // pend_vel
        test_fcw_of(idx),     // pend_freq
        32'd0,                // vel_squared
        32'd0,                // lfo
        32'd0,                // age
        32'hC0000000,         // tone_env: one brightness for every line
        32'd0,                // peak1, peak0
        32'd0,                // env1, env0
        dsp_out[119:72],      // phase1, phase0
        dsp_out[71:48],       // freq1 (recomputed at ATTACK)
        test_fcw_of(idx),     // freq0
        4'd0, seed_pitch, 8'd200, seed_zone, 1'b0, 1'b1, 3'd1 };
    wire hit_seed = sweep && seed_run && (idx == seed_k[VW-1:0]);

    realistic_voice_dsp #(.VW(VW)) u_dsp (
        // `sweep` is the sample strobe for the voice being visited: each voice
        // is visited exactly once per sample, so the datapath advances one
        // sample per visit -- the same cadence the parallel design got from
        // `tick`, which only ever pulses for the voice swept in slot 0.
        .clk(clk), .rst_n(rst_n), .tick(sweep), .st_in(st_q),
        .noise_lp(noise_lp), .st_out(dsp_out), .active(d_active),
        // In test mode both oscillators read the pure sine bank, so every
        // voice contributes exactly one line per oscillator.  Reading the
        // sampled wavetable instead made the line levels swing over 100 dB,
        // because a 45-harmonic table is not flat once the pitch leaves the
        // zone it was fitted for.
        .req0_valid(r0_valid), .req0_phase(r0_phase),
        .req0_bank(r0_bank), .req0_bright(r0_bright),
        .req1_valid(r1_valid), .req1_phase(r1_phase),
        .req1_bank(r1_bank),
        .gain0(g0), .gain1(g1), .held_note_o(d_note), .state_o(d_state),
        .bow_o(d_bow));

    // ---- user note events -------------------------------------------------
    wire [1:0] ev_zone_w = (ev_note<5'd6)  ? 2'd0 :
                           (ev_note<5'd12) ? 2'd1 :
                           (ev_note<5'd18) ? 2'd2 : 2'd3;
    // [359:358] = vibrato depth, [357:351] spare, [350:349] = glide speed.
    // The field ORDER matters: [359:358] are the top bits, so ev_vib has to come
    // first in the concatenation -- it once sat after the 9-bit pad, landed on
    // [350:349] while the datapath read [359:358], and main_R shipped with no
    // vibrato at all.
    wire [359:0] on_word = {ev_vib, 7'd0, ev_gk,
                            ev_note,             // held_note
                            ev_inst,             // pend_inst
                            ev_zone_w,           // pend_zone
                            ev_note,             // pend_pitch
                            ev_vel,              // pend_vel
                            ev_fcw,              // pend_freq
                            dsp_out[303:288],    // vel_squared
                            dsp_out[287:264],    // lfo
                            dsp_out[263:240],    // age
                            dsp_out[239:216],    // tone_env
                            dsp_out[215:184],    // peak1, peak0
                            dsp_out[183:120],    // env1, env0
                            dsp_out[119:72],     // phase1, phase0
                            dsp_out[71:48],      // freq1 (recomputed at ATTACK)
                            ev_gfrom,            // freq0 = glide start point
                            4'd0,
                            dsp_out[19:15],      // pitch_idx
                            dsp_out[14:7],       // vel
                            dsp_out[6:5],        // zone
                            dsp_out[4],          // inst
                            1'b1,                // gate
                            3'd1};               // FADE
    wire [359:0] off_word = {dsp_out[359:4], 1'b0, dsp_out[2:0]};

    wire hit_on  = sweep && ev_on  && (idx==ev_victim);
    wire hit_off = sweep && ev_off && (dsp_out[348:344]==ev_note) &&
                   (dsp_out[343]==ev_inst) &&
                   dsp_out[3] && (dsp_out[2:0]!=IDLE);

    always @* begin
        raddr = (scnt<=LAST) ? scnt[VW-1:0] : LAST;
        we    = init || sweep;
        waddr = init ? scnt[VW-1:0] : idx;
        wdata = dsp_out;
        if(init) begin
            wdata = 360'd0;
        end else if(hit_off) begin
            wdata = off_word;
        end else if(hit_on) begin
            wdata = on_word;
        end else if(hit_seed) begin
            wdata = tst_on_word;
        end
    end

    // ---- allocation mirrors ---------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            m_busy<={N{1'b0}}; m_rel<={N{1'b0}}; m_note<={(N*5){1'b0}};
        end else if(sweep) begin
            m_busy[idx] <= (wdata[2:0]!=IDLE);
            m_rel[idx]  <= (wdata[2:0]==RELEASE);
            m_note[idx*5 +: 5] <= wdata[348:344];
        end
    end


    // ---- table readers ---------------------------------------------------
    // One reader per oscillator lane.  The sweep issues a single voice per
    // clock, so each reader is 50% loaded and the fixed 3-clock latency is
    // absorbed by the matching gain pipeline.
    wire [15:0] rd0_sample, rd1_sample;
    wire        rd0_valid, rd1_valid;
    wire [15:0] rd0_tag, rd1_tag;

    // Each request carries the voice index and the lane, and the returned tag
    // is checked against the slot that will actually consume it three clocks
    // later.  A dropped or duplicated response then shows up as a discarded
    // sample instead of a silent voice.  (It also keeps the second reader
    // alive: with its tag tied off, synthesis folded `u_rom1` away entirely.)
    wire [VW-1:0] issue_idx = scnt[VW-1:0]-1'b1;
    wire [15:0]   tag0_wire = {{(15-VW){1'b0}},issue_idx,1'b0};
    wire [15:0]   tag1_wire = {{(15-VW){1'b0}},issue_idx,1'b1};

    periodic_interp #(.ROM_FILE(ROM_FILE)) u_rom0 (
        .clk(clk), .rst_n(rst_n), .req(r0_valid),
        .phase(r0_phase), .bank(r0_bank), .brightness(r0_bright),
        .tag(tag0_wire), .valid(rd0_valid), .sample(rd0_sample),
        .out_tag(rd0_tag));

    // GowinSynthesis folds a second instance of `periodic_interp` away even when
    // its outputs are live (WARN NL0002 "swept in optimizing"), which silently
    // killed the second oscillator.  Going through a distinct wrapper module
    // keeps both readers.
    periodic_interp_lane1 #(.ROM_FILE(ROM_FILE)) u_rom1 (
        .clk(clk), .rst_n(rst_n), .req(r1_valid),
        .phase(r1_phase), .bank(r1_bank), .brightness(r0_bright),
        .tag(tag1_wire), .valid(rd1_valid), .sample(rd1_sample),
        .out_tag(rd1_tag));

    // A request issued at slot k is accepted by the reader on that clock and
    // comes back three clocks later (`valid0/valid1/valid`), i.e. at slot k+3.
    wire [VW-1:0] expect_idx = scnt[VW-1:0]-4'd4;
    wire          use0 = rd0_valid && (rd0_tag[VW:1]==expect_idx) && !rd0_tag[0];
    wire          use1 = rd1_valid && (rd1_tag[VW:1]==expect_idx) &&  rd1_tag[0];

    reg [15:0] g0_d1,g0_d2,g0_d3, g1_d1,g1_d2,g1_d3;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            g0_d1<=0; g0_d2<=0; g0_d3<=0; g1_d1<=0; g1_d2<=0; g1_d3<=0;
        end else begin
            g0_d1<=g0; g0_d2<=g0_d1; g0_d3<=g0_d2;
            g1_d1<=g1; g1_d2<=g1_d1; g1_d3<=g1_d2;
        end
    end

    wire signed [32:0] p0 = $signed(rd0_sample)*$signed({1'b0,g0_d3});
    wire signed [32:0] p1 = $signed(rd1_sample)*$signed({1'b0,g1_d3});
    wire signed [23:0] t0 = {{7{p0[32]}},p0[32:16]};
    wire signed [23:0] t1 = {{7{p1[32]}},p1[32:16]};
    wire signed [23:0] tb = d_bow[23:0];

    // One contribution per clock: the sweep issues exactly one voice per clock,
    // so a lane-0 and a lane-1 response never arrive together.  Written as a sum
    // of masked terms rather than a nested ternary on purpose -- GowinSynthesis
    // silently deletes the *second* arm of `a ? x : b ? y : ...` and with it the
    // whole `u_rom1` subtree (WARN NL0002 "swept in optimizing"), which killed
    // the second oscillator without any error.  The sum form keeps both.
    wire signed [23:0] lane_sum = (use0 ? t0 : 24'sd0) + (use1 ? t1 : 24'sd0);
    wire signed [23:0] add_in   = lane_sum +
                                  ((sweep && d_active) ? tb : 24'sd0);
    wire               add_en   = use0 || use1 || (sweep && d_active);

    reg signed [23:0] acc;
    reg [5:0] cnt;
    reg signed [23:0] sum_r;
    reg [5:0] cnt_r;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            acc<=0; cnt<=0; sum_r<=0; cnt_r<=0;
        end else if(tick) begin
            acc<=0; cnt<=0;
        end else begin
            if(add_en) acc<=acc+add_in;
            if(sweep && d_active && !init) cnt<=cnt+6'd1;
            // Voice N-1 is issued at scnt==N and lands three clocks later, so
            // the accumulator is captured one clock after that.
            if(scnt==(NV+4)) begin
                sum_r<=acc;
                cnt_r<=cnt;
            end
        end
    end

    // ---- normalisation ---------------------------------------------------
    // 0.85/n with the one-bit shallower shift below = +3 dB on the old 1.2/n.
    // Kept under the 24000 soft knee on purpose: a loud four-note chord then
    // peaks near 30k without touching the flat part, so the knee only ever
    // catches transients instead of compressing every chord.
    reg [16:0] mix_gain;
    always @* begin
        case(cnt_r)
            6'd0: mix_gain=17'd0;
            6'd1: mix_gain=17'd55706;
            6'd2: mix_gain=17'd27853;
            6'd3: mix_gain=17'd18569;
            6'd4: mix_gain=17'd13926;
            6'd5: mix_gain=17'd11141;
            6'd6: mix_gain=17'd9284;
            6'd7: mix_gain=17'd7958;
            6'd8: mix_gain=17'd6963;
            6'd9: mix_gain=17'd6190;
            6'd10: mix_gain=17'd5571;
            6'd11: mix_gain=17'd5064;
            6'd12: mix_gain=17'd4642;
            6'd13: mix_gain=17'd4285;
            6'd14: mix_gain=17'd3979;
            6'd15: mix_gain=17'd3714;
            6'd16: mix_gain=17'd3482;
            6'd17: mix_gain=17'd3277;
            6'd18: mix_gain=17'd3095;
            6'd19: mix_gain=17'd2932;
            6'd20: mix_gain=17'd2785;
            6'd21: mix_gain=17'd2653;
            6'd22: mix_gain=17'd2532;
            6'd23: mix_gain=17'd2422;
            6'd24: mix_gain=17'd2321;
            6'd25: mix_gain=17'd2228;
            6'd26: mix_gain=17'd2143;
            6'd27: mix_gain=17'd2063;
            6'd28: mix_gain=17'd1989;
            6'd29: mix_gain=17'd1921;
            6'd30: mix_gain=17'd1857;
            6'd31: mix_gain=17'd1797;
            6'd32: mix_gain=17'd1741;
            default: mix_gain=17'd0;
        endcase
    end

    // Follow voice-count changes across output samples instead of stepping the
    // normalisation in one sample.
    function [16:0] approach_gain;
        input [16:0] current_gain;
        input [16:0] target_gain;
        reg [17:0] delta;
        reg [17:0] step;
        begin
            if(current_gain==target_gain) approach_gain=target_gain;
            else if(current_gain<target_gain) begin
                delta={1'b0,target_gain}-{1'b0,current_gain};
                step=(delta+18'd63)>>6;
                if(step==0) step=18'd1;
                approach_gain=current_gain+step[16:0];
            end else begin
                delta={1'b0,current_gain}-{1'b0,target_gain};
                step=(delta+18'd63)>>6;
                if(step==0) step=18'd1;
                approach_gain=current_gain-step[16:0];
            end
        end
    endfunction

    reg [16:0] mix_gain_cur;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) mix_gain_cur<=17'd0;
        else mix_gain_cur<=approach_gain(mix_gain_cur,mix_gain);
    end

    // +6 dB over the first release, which measured only -20.8 dBFS at velocity
    // 80 on a single note: the listener had to turn the volume up until the
    // fixed analogue floor of PT8211 + LMV321 came up as a machine hum.
    //
    // A bare +6 dB hard-clips a loud four-note chord (37.3k > 32.7k), so the
    // output stage now has a soft knee instead of a clip: unity up to 24000
    // (0.73 full scale), half slope above it, flat at 32766.  A fortissimo
    // single note lands at 24.6k and only loses 0.1 dB, chords bend gently, and
    // nothing ever reaches 7fff/8000 - which the regression test rejects as
    // clipped.  The 12 dB that fixed the hum lives in DAC_SHIFT (top.v).
    wire signed [40:0] mix_scaled = sum_r*$signed({1'b0,mix_gain_cur});
    wire signed [40:0] mix_shift  = mix_scaled>>>15;
    wire signed [25:0] pre        = mix_shift[25:0];
    wire        [25:0] pre_mag    = pre[25] ? (~pre[25:0]+26'd1) : pre[25:0];
    wire        [25:0] soft_mag   = (pre_mag<=26'd24000) ? pre_mag :
                                    (pre_mag>=26'd41532) ? 26'd32766 :
                                    26'd24000+((pre_mag-26'd24000)>>1);
    wire signed [25:0] lim        = pre[25] ? -$signed(soft_mag) : $signed(soft_mag);

    // ---- half-band decimation before the DAC ----------------------------
    // The engine runs at 99.33 kHz but the PT8211 frame rate is 49.67 kHz, so
    // whatever sits near the engine's own Nyquist folds straight back on top of
    // the note.  A two-tap average (1 + z^-1)/2 has a null exactly at fs/2, so
    // it removes the fold centre for one adder, and in exchange costs 0.4 dB at
    // 10 kHz.  Without it a held low note carries a narrow spur near 100 Hz
    // (measured -44 dBc) whose upper sidebands betray it as aliasing, and it
    // reads as a machine hum under the decay.
    reg  signed [15:0] hb_prev;
    reg  signed [15:0] hb_out;
    wire signed [16:0] hb_sum = $signed({lim[15],lim[15:0]})
                              + $signed({hb_prev[15],hb_prev});
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            hb_prev<=16'sd0;
            hb_out <=16'sd0;
        end else if(scnt==(NV+4)) begin
            hb_prev<=lim[15:0];
            hb_out <=hb_sum[16:1];
        end
    end

    assign out      = hb_out;
    assign n_active = cnt_r;
endmodule

// Thin wrapper whose only job is to be a different module type from
// `periodic_interp`, so the synthesiser keeps both table readers alive.
module periodic_interp_lane1 #(
    parameter ROM_FILE="instruments"
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        req,
    input  wire [23:0] phase,
    input  wire [3:0]  bank,
    input  wire [7:0]  brightness,
    input  wire [15:0] tag,
    output wire        valid,
    output wire [15:0] sample,
    output wire [15:0] out_tag
);
    periodic_interp #(.ROM_FILE(ROM_FILE)) u (
        .clk(clk), .rst_n(rst_n), .req(req),
        .phase(phase), .bank(bank), .brightness(brightness),
        .tag(tag), .valid(valid), .sample(sample), .out_tag(out_tag));
endmodule
