// N-voice polyphony on ONE copy of the wave tables.
//
// Why this module exists
// ----------------------
// The realistic engine is table driven: one voice already occupies 32 of the
// 118 BSRAM blocks (288 Kbit of 9 banks x 512 x 32 bit x 2).  Copying the
// voice N times therefore dies at N = 3 (3*32 = 96 < 118, 4*32 = 128 > 118),
// which is not a chord.  So the tables stay in one place and every voice
// borrows the read port for two clocks per sample:
//
//   clock budget per sample = 64 (6.357 MHz / 99.334 kHz)
//   cost per sounding voice = 2 reads  => 2*N must fit in ~60
//   N = 16 uses 32 clocks, leaving 28 for the 3-clock reader latency and
//   for voices whose requests pile up behind the round-robin arbiter.
//
// A voice leaves the arbiter alone while it is IDLE, so a two-note chord only
// spends four reader slots, not 2*N.
//
// Mixing uses the same 0.75/n style normalisation as the production engine so
// that stacking notes does not clip the PT8211: the scale is 1.2/n, i.e. a
// single note keeps its audition level and a full 16-note cluster still peaks
// below full scale.
module realistic_poly #(
    parameter integer N=16,
    parameter integer VW=4,
    parameter ROM_FILE="instruments"
)(
    input wire clk,rst_n,
    input wire tick,                 // per-sample strobe (already edge detected)
    input wire fire_on, fire_off,
    input wire [4:0] event_note,
    input wire instrument,           // 0 = electric piano, 1 = cello
    input wire [23:0] fcw,
    input wire [7:0] velocity,
    output wire signed [15:0] out,
    output wire [5:0] n_active
);
    wire [N-1:0] v_req,v_valid,v_busy,v_rel;
    reg  [N-1:0] v_grant;
    wire [N*24-1:0] v_phase;
    wire [N*4-1:0]  v_bank;
    wire [N*8-1:0]  v_bright;
    wire [N*16-1:0] v_tag;
    wire [N*16-1:0] v_sample;
    wire [N*5-1:0]  v_note;

    // ---- note allocation ------------------------------------------------
    // Priority 1: a completely free voice (lowest index).
    // Priority 2: a voice already in RELEASE (its sound is fading out anyway).
    // Priority 3: voice 0, i.e. steal rather than drop the note.
    reg [VW-1:0] sel_free,sel_rel;
    reg found_free,found_rel;
    integer i;
    always @* begin
        sel_free=0; found_free=1'b0;
        for (i=N-1;i>=0;i=i-1) if(!v_busy[i]) begin sel_free=i[VW-1:0]; found_free=1'b1; end
        sel_rel=0; found_rel=1'b0;
        for (i=N-1;i>=0;i=i-1) if(v_rel[i]) begin sel_rel=i[VW-1:0]; found_rel=1'b1; end
    end
    wire [VW-1:0] victim = found_free ? sel_free : (found_rel ? sel_rel : {VW{1'b0}});
    wire [N-1:0] v_on = fire_on ? ({{(N-1){1'b0}},1'b1} << victim) : {N{1'b0}};
    // note-off releases every voice holding that note, which is what makes a
    // repeated key press (same note twice) unwind both of them.
    wire [N-1:0] v_off;
    genvar gi;
    generate
        for (gi=0;gi<N;gi=gi+1) begin : g_off
            assign v_off[gi] = fire_off && v_busy[gi] && (v_note[gi*5 +: 5]==event_note);
        end
    endgenerate

    // ---- voices ---------------------------------------------------------
    //  These three must be declared BEFORE the voice instances. A net that is
    //   first mentioned in a port connection is implicitly created as a 1-bit
    //   wire, so a later "wire [15:0] rd_tag;" does NOT widen it: the reader
    //   ended up driving one net while every voice listened to an undriven
    //   copy, which showed up as ret_tag=zzzz / hit=x and a silent output.
    // Two independent reader lanes. The reader accepts one request per clock
    // and needs 3 clocks of latency, so a single lane can only serve about 30
    // voices at two reads per sample (2*N+3 <= 64 clocks per sample). The
    // second lane halves that: even voices go to u_rom0, odd voices to u_rom1,
    // and each lane then sees 2*(N/2) = N reads per sample.
    // Cost: one extra periodic_interp (3 MULTALU) and a second copy of the
    // wavetable BSRAM. That is the price of 32 voices.
    wire rd0_valid, rd1_valid;
    wire signed [15:0] rd0_sample, rd1_sample;
    wire [15:0] rd0_tag, rd1_tag;
    wire [N-1:0] v_req0, v_req1;
    generate
        for (gi=0;gi<N;gi=gi+1) begin : g_v
            assign v_req0[gi] = ((gi % 2)==0) ? v_req[gi] : 1'b0;
            assign v_req1[gi] = ((gi % 2)==1) ? v_req[gi] : 1'b0;
            realistic_poly_voice #(.ROM_FILE(ROM_FILE),.VOICE_ID(gi),.VW(VW)) u_v (
                .clk(clk),.rst_n(rst_n),.tick(tick),
                .note_on(v_on[gi]),.note_off(v_off[gi]),.instrument(instrument),
                .note_idx(event_note),.fcw(fcw),.velocity(velocity),
                .sample(v_sample[gi*16 +: 16]),.sample_valid(v_valid[gi]),
                .busy(v_busy[gi]),.held_note(v_note[gi*5 +: 5]),.releasing(v_rel[gi]),
                .req(v_req[gi]),
                .req_phase(v_phase[gi*24 +: 24]),
                .req_bank(v_bank[gi*4 +: 4]),
                .req_bright(v_bright[gi*8 +: 8]),
                .req_tag(v_tag[gi*16 +: 16]),
                .grant(v_grant[gi]),
                .ret_valid(((gi % 2)==0) ? rd0_valid : rd1_valid),
                .ret_sample(((gi % 2)==0) ? rd0_sample : rd1_sample),
                .ret_tag(((gi % 2)==0) ? rd0_tag : rd1_tag));
        end
    endgenerate

    // ---- round-robin arbiters (one per reader lane) ----------------------
    localparam integer NH = N/2;
    reg [VW-1:0] rr0, rr1, sel0, sel1;
    reg picked0, picked1;
    // Separate loop variables per block: a shared integer written by two
    // always @* blocks puts each block in the other's sensitivity list and the
    // simulation spins until the iteration limit.
    integer k0, h0, k1, h1;
    always @* begin
        sel0={VW{1'b0}}; picked0=1'b0;
        for (k0=0;k0<NH;k0=k0+1) begin
            h0=rr0+k0; if(h0>=NH) h0=h0-NH;
            if(!picked0 && v_req0[h0*2]) begin picked0=1'b1; sel0=h0*2; end
        end
    end
    always @* begin
        sel1={VW{1'b0}}; picked1=1'b0;
        for (k1=0;k1<NH;k1=k1+1) begin
            h1=rr1+k1; if(h1>=NH) h1=h1-NH;
            if(!picked1 && v_req1[h1*2+1]) begin picked1=1'b1; sel1=h1*2+1; end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin rr0<=0; rr1<=0; end
        else begin
            if(picked0) rr0<=((sel0>>1)==NH-1) ? {VW{1'b0}} : ((sel0>>1)+1'b1);
            if(picked1) rr1<=((sel1>>1)==NH-1) ? {VW{1'b0}} : ((sel1>>1)+1'b1);
        end
    end
    always @* begin
        v_grant={N{1'b0}};
        if(picked0) v_grant[sel0]=1'b1;
        if(picked1) v_grant[sel1]=1'b1;
    end

    periodic_interp #(.ROM_FILE(ROM_FILE)) u_rom0(
        .clk(clk),.rst_n(rst_n),.req(picked0),
        .phase(v_phase[sel0*24 +: 24]),.bank(v_bank[sel0*4 +: 4]),
        .brightness(v_bright[sel0*8 +: 8]),.tag(v_tag[sel0*16 +: 16]),
        .valid(rd0_valid),.sample(rd0_sample),.out_tag(rd0_tag));
    periodic_interp #(.ROM_FILE(ROM_FILE)) u_rom1(
        .clk(clk),.rst_n(rst_n),.req(picked1),
        .phase(v_phase[sel1*24 +: 24]),.bank(v_bank[sel1*4 +: 4]),
        .brightness(v_bright[sel1*8 +: 8]),.tag(v_tag[sel1*16 +: 16]),
        .valid(rd1_valid),.sample(rd1_sample),.out_tag(rd1_tag));

    // ---- mix ------------------------------------------------------------
    reg signed [21:0] mix_sum;
    reg [5:0] count;
    integer m;
    always @* begin
        mix_sum=0; count=0;
        for (m=0;m<N;m=m+1) begin
            mix_sum=mix_sum+$signed(v_sample[m*16 +: 16]);
            count=count+{5'd0,v_busy[m]};
        end
    end
    // Register the sum before the scale multiply: 16 addends plus a 21x17
    // multiply in one cone would be the critical path of this firmware.
    reg signed [21:0] mix_sum_r;
    reg [5:0] count_r;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin mix_sum_r<=0; count_r<=0; end
        else begin mix_sum_r<=mix_sum; count_r<=count; end
    end
    // 1.2/n, so one note keeps the audition level and a full 32-note cluster
    // stays under full scale. Values are round(78643/n).
    reg [16:0] mix_gain;
    always @* begin
        case(count_r)
            6'd0: mix_gain=17'd0;
            6'd1: mix_gain=17'd78643;
            6'd2: mix_gain=17'd39321;
            6'd3: mix_gain=17'd26214;
            6'd4: mix_gain=17'd19661;
            6'd5: mix_gain=17'd15729;
            6'd6: mix_gain=17'd13107;
            6'd7: mix_gain=17'd11235;
            6'd8: mix_gain=17'd9830;
            6'd9: mix_gain=17'd8738;
            6'd10: mix_gain=17'd7864;
            6'd11: mix_gain=17'd7149;
            6'd12: mix_gain=17'd6554;
            6'd13: mix_gain=17'd6049;
            6'd14: mix_gain=17'd5617;
            6'd15: mix_gain=17'd5243;
            6'd16: mix_gain=17'd4915;
            6'd17: mix_gain=17'd4626;
            6'd18: mix_gain=17'd4369;
            6'd19: mix_gain=17'd4150;
            6'd20: mix_gain=17'd3932;
            6'd21: mix_gain=17'd3745;
            6'd22: mix_gain=17'd3575;
            6'd23: mix_gain=17'd3419;
            6'd24: mix_gain=17'd3277;
            6'd25: mix_gain=17'd3146;
            6'd26: mix_gain=17'd3025;
            6'd27: mix_gain=17'd2913;
            6'd28: mix_gain=17'd2809;
            6'd29: mix_gain=17'd2712;
            6'd30: mix_gain=17'd2621;
            6'd31: mix_gain=17'd2537;
            6'd32: mix_gain=17'd2458;
            default: mix_gain=17'd0;
        endcase
    end

    // Follow voice-count changes over output samples instead of switching the
    // normalization in one sample. The rounded 1/64 error step is monotonic,
    // bounded, and reaches the target without getting stuck at a small delta.
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

    reg [16:0] mix_gain_current;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) mix_gain_current<=17'd0;
        else if(tick) mix_gain_current<=approach_gain(mix_gain_current,mix_gain);
    end

    wire signed [38:0] mix_scaled=mix_sum_r*$signed({1'b0,mix_gain_current});
    wire signed [38:0] mix_out=mix_scaled>>>16;
    assign out=(mix_out>38'sd32767) ? 16'sd32767 :
               (mix_out< -38'sd32768) ? -16'sd32768 : mix_out[15:0];
    assign n_active=count_r;
endmodule
