// Polyphonic audition adapter, same pin-level interface as
// `realistic_board_adapter` so the board top only has to pick a module.
//
// Differences from the monophonic adapter:
//   * a note-off releases every voice holding that note, not just the newest
//   * allocation is done inside `realistic_poly` (it is the only place that
//     can see per-voice busy/held-note state)
//   * output is normalised by the number of sounding voices
module realistic_poly_adapter #(
    parameter integer N=16,
    parameter integer VW=4,
    parameter ROM_FILE="instruments",
    // 0 = one datapath per voice (realistic_poly)
    // 1 = state in BSRAM, one shared datapath swept over it (realistic_poly_ram)
    parameter integer USE_RAM=0
)(
    input wire clk,rst_n,tick,note_on,note_off,
    input wire [4:0] note_idx,
    input wire [7:0] velocity,
    input wire [1:0] wave_sel,ep_sel,vib_sel,glide_sel,
    input wire tst_mode,
    output wire signed [15:0] out_l,out_r,
    output wire [5:0] n_active,
    output wire [23:0] ph0_dbg
);
    reg tick_d,on_d,off_d;
    reg pending_valid,pending_on;
    reg [4:0] pending_note;
    reg [7:0] pending_velocity;
    reg [1:0] pending_wave;
    reg [1:0] pending_vib, pending_glide;
    wire tick1=tick && !tick_d;
    wire on_edge=note_on && !on_d;
    wire off_edge=note_off && !off_d;
    wire event_now=on_edge || off_edge;
    wire event_on=event_now ? on_edge : pending_on;
    wire [4:0] event_note=event_now ? note_idx : pending_note;
    // Velocity is passed through unchanged.  A gamma curve (meeting vel^2 half
    // way to linear amplitude) was tried here and rejected: forwarding a mapped
    // velocity into the engine dropped the output by 6.6 dB and shortened every
    // tail, so the level/decay path evidently is not a plain vel^2 - the extra
    // gain has to come from the mix stage instead.
    wire [7:0]  velocity_g = velocity;
    wire [7:0] event_velocity=event_now ? velocity_g : pending_velocity;
    wire [1:0] event_wave=event_now ? wave_sel : pending_wave;
wire [1:0] event_vib =event_now ? vib_sel  : pending_vib;
wire [1:0] event_glide=event_now ? glide_sel: pending_glide;
    wire deliver=tick1 && (event_now || pending_valid);
    wire supported=(event_wave==0 || event_wave==3);
    wire fire_on=deliver && event_on && event_velocity!=0 && supported;
    wire fire_off=deliver && (!event_on || event_velocity==0) && supported;
    wire [23:0] fcw;
    note_table notes(.note_idx(event_note),.fcw(fcw));
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            tick_d<=0;on_d<=0;off_d<=0;
            pending_valid<=0;pending_on<=0;pending_note<=0;
            pending_velocity<=0;pending_wave<=0;pending_vib<=0;pending_glide<=0;
        end else begin
            tick_d<=tick;on_d<=note_on;off_d<=note_off;
            if(tick1) pending_valid<=0;
            if(event_now && !tick1) begin
                pending_valid<=1;pending_on<=on_edge;pending_note<=note_idx;
                pending_velocity<=velocity_g;pending_wave<=wave_sel;
                pending_vib<=vib_sel;
                pending_glide<=glide_sel;
            end
        end
    end
    wire signed [15:0] out_w;
generate
if (USE_RAM==0) begin : g_par
    realistic_poly #(.N(N),.VW(VW),.ROM_FILE(ROM_FILE)) u_poly (
        .clk(clk),.rst_n(rst_n),.tick(tick1),
        .fire_on(fire_on),.fire_off(fire_off),.event_note(event_note),
        .instrument(event_wave==3),.fcw(fcw),.velocity(event_velocity),
        .out(out_w),.n_active(n_active));
end else begin : g_ram
    realistic_poly_ram #(.N(N),.VW(VW),.ROM_FILE(ROM_FILE)) u_poly (
        .clk(clk),.rst_n(rst_n),.tick(tick1),
        .fire_on(fire_on),.fire_off(fire_off),.event_note(event_note),
        .instrument(event_wave==3),.fcw(fcw),.velocity(event_velocity),
        .vib_sel(event_vib),
        .glide_sel(event_glide),
        .out(out_w),.n_active(n_active),
        .tst_mode(tst_mode));
end
endgenerate
    assign out_l=out_w;
    assign out_r=out_l;
    assign ph0_dbg=24'd0;
endmodule
