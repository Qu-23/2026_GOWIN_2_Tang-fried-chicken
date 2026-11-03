`timescale 1ns/1ps
// Sample-by-sample envelope checks against the frozen Main_Y HDMI v2 DSP.
// The audio tick is 99.3 kHz; this bench advances one state update per step.
module tb_cello_attack40;
    reg [359:0] current_state, baseline_state;
    wire [359:0] next_current, next_baseline;
    realistic_voice_dsp current_dsp(
        .clk(1'b0),.rst_n(1'b1),.tick(1'b1),.st_in(current_state),
        .noise_lp(18'sd1234),.st_out(next_current),
        .active(),.req0_valid(),.req0_phase(),.req0_bank(),.req0_bright(),
        .req1_valid(),.req1_phase(),.req1_bank(),.gain0(),.gain1(),
        .held_note_o(),.state_o(),.bow_o());
    realistic_voice_dsp_baseline baseline_dsp(
        .clk(1'b0),.rst_n(1'b1),.tick(1'b1),.st_in(baseline_state),
        .noise_lp(18'sd1234),.st_out(next_baseline),
        .active(),.req0_valid(),.req0_phase(),.req0_bank(),.req0_bright(),
        .req1_valid(),.req1_phase(),.req1_bank(),.gain0(),.gain1(),
        .held_note_o(),.state_o(),.bow_o());
    integer i, pitch, velocity, t10, t90, b90;
    reg [31:0] previous_env;
    reg [63:0] threshold10, threshold90;

    task seed(input integer cello,input integer p,input integer v);
        begin
            current_state=0;
            current_state[2:0]=3'd1; // FADE: exercise real pending-note startup.
            current_state[3]=1;
            current_state[327:304]=24'd56000;
            current_state[335:328]=v;
            current_state[340:336]=p;
            current_state[343]=cello;
            current_state[348:344]=p;
            current_state[359:358]=cello ? 2 : 0;
            baseline_state=current_state;
            #10;
        end
    endtask
    task step;
        begin
            #5;
            current_state=next_current;
            baseline_state=next_baseline;
            #5;
        end
    endtask

    initial begin
        // EP's complete state trajectory must remain bit-identical, including
        // attack, held decay, and release at three register/velocity extremes.
        for(pitch=0;pitch<=24;pitch=pitch+12) begin
            for(velocity=40;velocity<=240;velocity=velocity+100) begin
                seed(0,pitch,velocity);
                for(i=0;i<60000;i=i+1) begin
                    if(i==25000) begin
                        current_state[3]=0;baseline_state[3]=0;
                    end
                    step;
                    if(current_state!==baseline_state)
                        $fatal(1,"EP changed pitch=%0d vel=%0d sample=%0d",pitch,velocity,i);
                end
            end
        end

        // Bowed attacks must reach 90% in 30..50 ms, without a discontinuous
        // onset, overshoot, level drift, or altered release law.
        for(pitch=0;pitch<=24;pitch=pitch+12) begin
            for(velocity=40;velocity<=240;velocity=velocity+100) begin
                seed(1,pitch,velocity);
                step; // FADE -> ATTACK
                threshold10={current_state[199:184],16'd0};
                threshold90=(threshold10*9)/10;
                threshold10=threshold10/10;
                t10=-1;t90=-1;b90=-1;previous_env=0;
                for(i=1;i<=33000;i=i+1) begin
                    step;
                    if(current_state[151:120]<previous_env)
                        $fatal(1,"Cello attack decreased");
                    previous_env=current_state[151:120];
                    if(t10<0 && previous_env>=threshold10)t10=i;
                    if(t90<0 && previous_env>=threshold90)t90=i;
                    if(b90<0 && baseline_state[151:120]>=threshold90)b90=i;
                    if(previous_env>{current_state[199:184],16'd0})
                        $fatal(1,"Cello attack overshot target");
                end
                $display("ATTACK pitch=%0d vel=%0d t10=%0d t90=%0d baseline90=%0d samples",pitch,velocity,t10,t90,b90);
                if(t90<2979 || t90>4965)
                    $fatal(1,"Cello t90 outside 30..50 ms: %0d samples",t90);
                if(t10<100 || t10>=t90)$fatal(1,"Non-progressive cello onset");
                // Once both have settled, their entire states must agree:
                // same oscillators, timbre, final level, age and vibrato.
                if(current_state!==baseline_state)$fatal(1,"Cello held state changed");
                current_state[3]=0;baseline_state[3]=0;
                for(i=0;i<100000;i=i+1) begin
                    step;
                    if(current_state!==baseline_state)$fatal(1,"Cello release changed");
                end
                if(current_state[2:0]!=0 || current_state[151:120]!=0)
                    $fatal(1,"Cello failed to return to idle");
            end
        end
        $display("PASS tb_cello_attack40: cello onset 30..50ms, EP bit-exact, held/release unchanged");
        $finish;
    end
endmodule
