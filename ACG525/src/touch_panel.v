//////////////////////////////////////////////////////////////////////////////////
// Module Name : touch_panel
// Description : 触摸界面语义层 v2 —— 8 列网格控制面板 (2026-11-01)
//
//   屏幕布局（480x272, 8 列 × 60px）:
//     y  0.. 23 : 顶栏 (音色-变体 / L=lux / E 诊断 / TX 灯 / PLAY|TEST)
//     y 24..111 : 音色 4 大格 ×120: EP(0) PL(1) BA(2) CE(3)
//     y112..167 : 颤音 V0..V3 (col0..3) | 滑音 G0..G3 (col4..7, 点击即发表情帧)
//     y168..223 : 变体 A/B/C (col0..2) | FX 循环 (3) | R 循环 (4) | M 循环 (5)
//                 | O- (6) | O+ (7)
//     y224..271 : TS (0) | 和弦 CM/GM/FM (1..3, 按下 3×on 松开 3×off)
//                 | LAMP 照明 (4..5, 本地 GPIO) | CL 全停 (6..7)
//
//   事件类型 ev_type: 0=note_on 1=note_off 2=测试模式 3=原始控制帧(滑音/效果器)
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps

module touch_panel (
    input  wire       clk,
    input  wire       rst_n,

    input  wire [9:0] pos_x,
    input  wire [9:0] pos_y,
    input  wire       pressed,

    //--- 下行事件（单周期脉冲）---
    output reg        ev_vld,
    output reg  [2:0] ev_type,     // 0=on 1=off 2=test 3=raw-ctrl
    output reg  [7:0] ev_note,
    output reg  [7:0] ev_vel,
    output reg        ev_tst,

    //--- 手势输入 (APDS-9960, 单拍脉冲, 独立于触摸) ---
    input  wire        gest_up,      // 上挥: 音色 +1
    input  wire        gest_down,    // 下挥: 音色 -1
    input  wire        gest_left,    // 左挥: 八度降 (与 O- 同)
    input  wire        gest_right,   // 右挥: 八度升 (与 O+ 同)

    //--- 配置 / 状态（给 UI 和 frame_pack）---
    output reg  [1:0] cfg_wave,
    output reg  [1:0] cfg_ep,
    output reg  [1:0] cfg_vib,
    output reg        tst_mode,
    output reg  [6:0] cur_note,    // 最近触发的单音（CL 用），0=无
    output reg  [1:0] cfg_gli,
    output reg  [1:0] cfg_fx,      // 0=关 1=混响 2=延迟 3=合唱
    output reg  [1:0] cfg_rev,
    output reg  [1:0] cfg_mix,
    output reg  [1:0] oct_mode,    // 0=0 1=+12 2=-12
    output reg        lamp,        // 琴键底部照明 GPIO
    output reg        chord_hold,
    output reg  [1:0] chord_idx    // 0=CM 1=GM 2=FM
);

    //==============================================================
    // 输入打拍: 坐标/按下标志同步为一致快照
    //   防止"新坐标 + 旧区域判定"的单周期混合态 (仿真与实机都可能发生)
    //==============================================================
    reg [9:0] px_q, py_q;
    reg       pr_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            px_q <= 10'd0; py_q <= 10'd0; pr_q <= 1'b0;
        end else begin
            px_q <= pos_x; py_q <= pos_y; pr_q <= pressed;
        end
    end

    //==============================================================
    // 区域判定 (基于打拍后的快照)
    //==============================================================
    wire in_r0 = (py_q >= 10'd24)  && (py_q < 10'd112);
    wire in_r1 = (py_q >= 10'd112) && (py_q < 10'd168);
    wire in_r2 = (py_q >= 10'd168) && (py_q < 10'd224);
    wire in_r3 = (py_q >= 10'd224);

    reg [2:0] col6;                // 8 列 × 60px
    always @(*) begin
        if      (px_q < 10'd60)  col6 = 3'd0;
        else if (px_q < 10'd120) col6 = 3'd1;
        else if (px_q < 10'd180) col6 = 3'd2;
        else if (px_q < 10'd240) col6 = 3'd3;
        else if (px_q < 10'd300) col6 = 3'd4;
        else if (px_q < 10'd360) col6 = 3'd5;
        else if (px_q < 10'd420) col6 = 3'd6;
        else                      col6 = 3'd7;
    end

    reg [1:0] tone_col;            // 4 大格 × 120px
    always @(*) begin
        if      (px_q < 10'd120) tone_col = 2'd0;
        else if (px_q < 10'd240) tone_col = 2'd1;
        else if (px_q < 10'd360) tone_col = 2'd2;
        else                      tone_col = 2'd3;
    end

    //==============================================================
    // 和弦音符（含八度偏移 + 钳位 60..84）
    //==============================================================
    function [6:0] chord_note;
        input [1:0] ch;      // 0=CM 1=GM 2=FM
        input [1:0] k;       // 0..2 和弦内第几个
        input [1:0] om;      // 八度模式
        reg [7:0]  t;
        reg [6:0]  base;
        begin
            case (ch)
                2'd0: base = 7'd60;               // C4
                2'd1: base = 7'd67;               // G4
                default: base = 7'd65;            // F4
            endcase
            case (k)
                2'd0: t = {1'b0, base};
                2'd1: t = {1'b0, base} + 8'd4;    // 大三度
                default: t = {1'b0, base} + 8'd7; // 纯五度
            endcase
            if (om == 2'd1) t = t + 8'd12;        // +12
            if (om == 2'd2) t = t - 8'd12;        // -12
            if (t < 8'd60) t = 8'd60;             // 钳位
            if (t > 8'd84) t = 8'd84;
            chord_note = t[6:0];
        end
    endfunction

    //==============================================================
    // 状态机
    //==============================================================
    localparam [3:0] S_IDLE  = 4'd0,
                     S_WAIT  = 4'd1,      // 普通按钮按住
                     S_CH1   = 4'd2,      // 和弦 on 依次发 3 帧
                     S_CH2   = 4'd3,
                     S_CH3   = 4'd4,
                     S_CHHLD = 4'd5,      // 和弦按住
                     S_CHO1  = 4'd6,      // 松开依次发 3 个 off
                     S_CHO2  = 4'd7,
                     S_CHO3  = 4'd8;

    reg [3:0] st;                  // 注意: 4 位, S_CHO3=8 超出 3 位会截断回 S_IDLE
    reg [7:0] n1, n2, n3;          // 和弦三音（已加八度）
    reg [1:0] ch_cur;

    //--------------------------------------------------------------
    // 等待超时 (v8 防死锁): pressed 若因 IRQ 线故障恒为 1,
    // S_WAIT/S_CHHLD 将永远等不到释放 -> 界面彻底无响应。
    // 2s 超时强制回 IDLE (长按 >2s 会重复触发一次, 可容忍)
    //--------------------------------------------------------------
    localparam [24:0] WT_MAX = 25'd18_000_000;   // 2s @ 9MHz
    reg  [24:0] wt_cnt;
    wire        wt_out = (wt_cnt >= WT_MAX);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                     wt_cnt <= 25'd0;
        else if (st == S_IDLE || !pr_q) wt_cnt <= 25'd0;
        else                            wt_cnt <= wt_cnt + 25'd1;
    end

    task emit;
        input [2:0] t;
        input [7:0] n;
        input [7:0] v;
        begin
            ev_vld  <= 1'b1;
            ev_type <= t;
            ev_note <= n;
            ev_vel  <= v;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; ev_vld <= 0; ev_type <= 0; ev_note <= 0; ev_vel <= 0;
            ev_tst <= 0; cfg_wave <= 0; cfg_ep <= 0; cfg_vib <= 0; tst_mode <= 0;
            cur_note <= 0; cfg_gli <= 0; cfg_fx <= 0; cfg_rev <= 0; cfg_mix <= 0;
            oct_mode <= 0; lamp <= 0; chord_hold <= 0; chord_idx <= 0;
            n1 <= 0; n2 <= 0; n3 <= 0; ch_cur <= 0;
        end else begin
            ev_vld <= 1'b0;
`ifdef SIM_DBG
            if (pr_q && st == S_IDLE)
                $display("[DBG] T=%0t press x=%0d y=%0d -> r0=%b r1=%b r2=%b r3=%b col6=%0d tone=%0d",
                         $time, px_q, py_q, in_r0, in_r1, in_r2, in_r3, col6, tone_col);
`endif
            case (st)
                //--------------------------------------------------
                S_IDLE: begin
                    //---- 手势: 上/下切音色, 左/右切八度 (独立于触摸) ----
                    // 音色/八度是本地锁存, 下一次 note_on 帧自动携带新配置
                    if (gest_up)    cfg_wave <= (cfg_wave == 2'd3) ? 2'd0 : cfg_wave + 2'd1;
                    if (gest_down)  cfg_wave <= (cfg_wave == 2'd0) ? 2'd3 : cfg_wave - 2'd1;
                    if (gest_left)  oct_mode <= (oct_mode == 2'd2) ? 2'd0 : 2'd2;   // 同 O-
                    if (gest_right) oct_mode <= (oct_mode == 2'd1) ? 2'd0 : 2'd1;   // 同 O+
                    if (pr_q) begin
                        if (in_r0) begin
                            cfg_wave <= tone_col;                    // 音色本地锁存
                            st <= S_WAIT;
                        end else if (in_r1) begin
                            if (col6 < 3'd4)
                                cfg_vib <= col6[1:0];                // 颤音本地锁存
                            else begin
                                cfg_gli <= col6[1:0];                // 滑音: 立即发表情帧
                                emit(3'd3, 8'h80 | {1'b0, cfg_vib, col6[1:0]}, 8'h00);
                            end
                            st <= S_WAIT;
                        end else if (in_r2) begin
                            case (col6)
                                3'd0, 3'd1, 3'd2: cfg_ep <= col6[1:0];
                                3'd3: begin                        // FX 循环 + 发效果帧
                                    cfg_fx  <= (cfg_fx == 2'd3) ? 2'd0 : cfg_fx + 1'b1;
                                    emit(3'd3, {cfg_rev, cfg_mix, (cfg_fx == 2'd3) ? 2'd0 : cfg_fx + 1'b1}, 8'h5C);
                                end
                                3'd4: begin                        // 混响大小循环
                                    cfg_rev <= (cfg_rev == 2'd2) ? 2'd0 : cfg_rev + 1'b1;
                                    emit(3'd3, {(cfg_rev == 2'd2) ? 2'd0 : cfg_rev + 1'b1, cfg_mix, cfg_fx}, 8'h5C);
                                end
                                3'd5: begin                        // 干湿循环
                                    cfg_mix <= cfg_mix + 1'b1;
                                    emit(3'd3, {cfg_rev, cfg_mix + 1'b1, cfg_fx}, 8'h5C);
                                end
                                3'd6: oct_mode <= (oct_mode == 2'd2) ? 2'd0 : 2'd2;  // O-
                                default: oct_mode <= (oct_mode == 2'd1) ? 2'd0 : 2'd1; // O+
                            endcase
                            st <= S_WAIT;
                        end else if (in_r3) begin
                            case (col6)
                                3'd0: begin                        // TS 测试模式
                                    tst_mode <= ~tst_mode;
                                    emit(3'd2, 8'h00, 8'h00);
                                    ev_tst <= ~tst_mode;
                                    st <= S_WAIT;
                                end
                                3'd1, 3'd2, 3'd3: begin            // 和弦按下
`ifdef SIM_DBG
                                    $display("[DBG] chord: col6=%0d ch=%0d fn=%0d/%0d/%0d oct=%0d",
                                             col6, col6[1:0] - 2'd1,
                                             chord_note(col6[1:0] - 2'd1, 2'd0, oct_mode),
                                             chord_note(col6[1:0] - 2'd1, 2'd1, oct_mode),
                                             chord_note(col6[1:0] - 2'd1, 2'd2, oct_mode),
                                             oct_mode);
`endif
                                    ch_cur     <= col6[1:0] - 2'd1;
                                    chord_idx  <= col6[1:0] - 2'd1;
                                    n1 <= chord_note(col6[1:0] - 2'd1, 2'd0, oct_mode);
                                    n2 <= chord_note(col6[1:0] - 2'd1, 2'd1, oct_mode);
                                    n3 <= chord_note(col6[1:0] - 2'd1, 2'd2, oct_mode);
                                    st <= S_CH1;
                                end
                                3'd4, 3'd5: begin                  // 照明
                                    lamp <= ~lamp;
                                    st <= S_WAIT;
                                end
                                default: begin                     // CL 全停
                                    if (cur_note != 7'd0) begin
                                        emit(3'd1, {1'b0, cur_note}, 8'h00);
                                        cur_note <= 7'd0;
                                    end
                                    st <= S_WAIT;
                                end
                            endcase
                        end else begin
                            st <= S_WAIT;                          // 顶栏等空区
                        end
                    end
                end                                                // S_IDLE
                //--------------------------------------------------
                S_CH1: begin                                       // 和弦音 1 on
                    emit(3'd0, {1'b0, n1}, 8'd200);
                    cur_note <= n3;
                    st <= S_CH2;
                end
                S_CH2: begin                                       // 和弦音 2 on
                    emit(3'd0, {1'b0, n2}, 8'd200);
                    st <= S_CH3;
                end
                S_CH3: begin                                       // 和弦音 3 on
                    emit(3'd0, {1'b0, n3}, 8'd200);
                    chord_hold <= 1'b1;
                    st <= S_CHHLD;
                end
                S_CHHLD: if (!pr_q) begin
`ifdef SIM_DBG
                    $display("[DBG] CHHLD release -> CHO1");
`endif
                    chord_hold <= 1'b0;
                    st <= S_CHO1;
                end else if (wt_out) begin
                    // 超时保险: 补发顶音 off 防挂音, 强制回 IDLE
                    chord_hold <= 1'b0;
                    emit(3'd1, {1'b0, n3}, 8'h00);
                    cur_note   <= 7'd0;
                    st <= S_IDLE;
                end
                S_CHO1: begin                                      // 和弦音 1 off
`ifdef SIM_DBG
                    $display("[DBG] CHO1 off n1=%0d", n1);
`endif
                    emit(3'd1, {1'b0, n1}, 8'h00);
                    st <= S_CHO2;
                end
                S_CHO2: begin                                      // 和弦音 2 off
`ifdef SIM_DBG
                    $display("[DBG] CHO2 off n2=%0d", n2);
`endif
                    emit(3'd1, {1'b0, n2}, 8'h00);
                    st <= S_CHO3;
                end
                S_CHO3: begin                                      // 和弦音 3 off
`ifdef SIM_DBG
                    $display("[DBG] CHO3 off n3=%0d", n3);
`endif
                    emit(3'd1, {1'b0, n3}, 8'h00);
                    st <= S_IDLE;
                end
                //--------------------------------------------------
                S_WAIT: if (!pr_q || wt_out) st <= S_IDLE;
                default: if (!pr_q || wt_out) st <= S_IDLE;
            endcase
        end
    end

endmodule
