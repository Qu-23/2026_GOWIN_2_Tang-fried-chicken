//////////////////////////////////////////////////////////////////////////////////
// Module Name : tb_grid_panel
// Description : v5 网格 GUI 冒烟测试 —— 触摸动作 → 事件/配置 → 帧序列
//   ① 点音色 BA(300,60)   → cfg_wave=2, 无事件
//   ② 点 FX  (200,190)    → ev_type=3, note={rev0,mix0,fx1}=0x01, vel=0x5C
//   ③ 按住 CM (90,250)    → 3×note_on 60/64/67 vel=200; 松开 → 3×note_off
//   ④ 点 TS  (30,250)     → ev_type=2, ev_tst=1
//   ⑤ 点 G2  (390,130)    → ev_type=3, note=0x82 (滑音=2, 颤音=0)
//   ⑥ 点 CL  (450,250)    → ev_type=1, note=67 (和弦顶音)
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps

module tb_grid_panel;

    reg  clk = 1'b0;
    reg  rst_n = 1'b0;
    reg  [9:0] pos_x = 10'd0;
    reg  [9:0] pos_y = 10'd0;
    reg  pressed = 1'b0;

    wire        ev_vld;
    wire [2:0]  ev_type;
    wire [7:0]  ev_note;
    wire [7:0]  ev_vel;
    wire        ev_tst;
    wire [1:0]  cfg_wave, cfg_ep, cfg_vib;
    wire        tst_mode;
    wire [6:0]  cur_note;
    wire [1:0]  cfg_gli, cfg_fx, cfg_rev, cfg_mix;
    wire [1:0]  oct_mode;
    wire        lamp;
    wire        chord_hold;
    wire [1:0]  chord_idx;

    always #50 clk = ~clk;      // 10 MHz

    touch_panel dut (
        .clk(clk), .rst_n(rst_n),
        .pos_x(pos_x), .pos_y(pos_y), .pressed(pressed),
        .ev_vld(ev_vld), .ev_type(ev_type), .ev_note(ev_note), .ev_vel(ev_vel),
        .ev_tst(ev_tst),
        .cfg_wave(cfg_wave), .cfg_ep(cfg_ep), .cfg_vib(cfg_vib),
        .tst_mode(tst_mode), .cur_note(cur_note),
        .cfg_gli(cfg_gli), .cfg_fx(cfg_fx), .cfg_rev(cfg_rev), .cfg_mix(cfg_mix),
        .oct_mode(oct_mode), .lamp(lamp),
        .chord_hold(chord_hold), .chord_idx(chord_idx)
    );

    //---------------- 事件捕获 (negedge 采样, 避开 NBA 竞态) ----------------
    reg [2:0] mtype [0:31];
    reg [7:0] mnote [0:31];
    reg [7:0] mvel  [0:31];
    integer   ev_n = 0;
    always @(negedge clk) begin
        if (ev_vld && ev_n < 32) begin
            mtype[ev_n] = ev_type;
            mnote[ev_n] = ev_note;
            mvel [ev_n] = ev_vel;
            $display("EV#%0d type=%0d note=%0d vel=%0d (ci=%0d b01=%b)",
                     ev_n, ev_type, ev_note, ev_vel, dut.chord_idx, dut.col6[1:0]);
            ev_n = ev_n + 1;
        end
    end

    //---------------- 激励任务 (negedge 赋值: 组合逻辑在下一 posedge 前稳定) ----------------
    task click(input [9:0] x, input [9:0] y);
        begin
            @(negedge clk);
            pos_x = x; pos_y = y; pressed = 1;
            repeat (10) @(posedge clk);
            @(negedge clk);
            pressed = 0;
            repeat (3) @(posedge clk);
        end
    endtask

    task hold(input [9:0] x, input [9:0] y, input integer us);
        begin
            @(negedge clk);
            pos_x = x; pos_y = y; pressed = 1;
            repeat (us) @(posedge clk);
            @(negedge clk);
            pressed = 0;
            repeat (3) @(posedge clk);
        end
    endtask

    //---------------- 检查 ----------------
    integer errors = 0;
    task expect8(input [7:0] got, input [7:0] exp, input [127:0] tag);
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL %0s: got=%h exp=%h", tag, got, exp);
            end
        end
    endtask

    integer k;
    initial begin
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // ① 音色 BA
        click(300, 60);
        if (cfg_wave !== 2'd2) begin errors = errors + 1; $display("FAIL tone: cfg_wave=%0d", cfg_wave); end
        else $display("PASS-1: tone BA selected (cfg_wave=2)");

        // ② FX 循环 → 第一次点击 fx=1
        click(200, 190);
        #1000;
        expect8({5'd0, mtype[0]}, {5'd0, 3'd3}, "fx.type");
        expect8(mnote[0], 8'h01, "fx.note");   // rev=0 mix=0 fx=1
        expect8(mvel[0], 8'h5C, "fx.vel");

        // ③ 和弦 CM: 按住 ~3us 后应有 3 个 on
        hold(90, 250, 3000);
        #1000;
        if (ev_n < 6) begin errors = errors + 1; $display("FAIL chord: ev_n=%0d", ev_n); end
        else begin
            if (mtype[1] === 3'd0 && mnote[1] === 8'd60 &&
                mtype[2] === 3'd0 && mnote[2] === 8'd64 &&
                mtype[3] === 3'd0 && mnote[3] === 8'd67)
                $display("PASS-3a: chord CM 3x note_on 60/64/67");
            else begin
                errors = errors + 1;
                $display("FAIL-3a: chord on notes %h %h %h", mnote[1], mnote[2], mnote[3]);
            end
            if (mtype[4] === 3'd1 && mnote[4] === 8'd60 &&
                mtype[5] === 3'd1 && mnote[5] === 8'd64 &&
                mtype[6] === 3'd1 && mnote[6] === 8'd67)
                $display("PASS-3b: chord release 3x note_off");
            else begin
                errors = errors + 1;
                $display("FAIL-3b: chord off %h %h %h", mnote[4], mnote[5], mnote[6]);
            end
        end

        // ④ TS
        click(30, 250);
        #1000;
        if (mtype[7] === 3'd2 && ev_tst === 1'b1 && tst_mode === 1'b1)
            $display("PASS-4: TS test mode on");
        else begin
            errors = errors + 1;
            $display("FAIL-4: TS mtype=%h tst=%b", mtype[7], tst_mode);
        end

        // ⑤ 滑音 G2 (col6, vib 当前为 0)
        click(390, 130);
        #1000;
        if (mtype[8] === 3'd3 && mnote[8] === 8'h82)
            $display("PASS-5: glide G2 frame note=0x82");
        else begin
            errors = errors + 1;
            $display("FAIL-5: glide mtype=%h note=%h", mtype[8], mnote[8]);
        end

        // ⑥ CL (cur_note = 和弦顶音 67)
        click(450, 250);
        #1000;
        if (mtype[9] === 3'd1 && mnote[9] === 8'd67)
            $display("PASS-6: CL note_off 67");
        else begin
            errors = errors + 1;
            $display("FAIL-6: CL mtype=%h note=%h cur=%0d", mtype[9], mnote[9], cur_note);
        end

        $display("==== tb_grid_panel: %s ====", (errors == 0) ? "ALL PASS" : "HAS FAILURES");
        $finish;
    end

    initial begin
        #500_000;
        $display("==== TIMEOUT ====");
        $finish;
    end

endmodule
