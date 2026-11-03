//===============================================================
// synth_voice - 一个合成器声部
//
//   主振荡器: DDS 相位 -> 4 种波形(组合逻辑) -> 音色 morph 插值
//             -> 低通滤波 + 滤波包络 -> ADSR 包络
//   分音振荡器:  2026-10-20 新增, 电钢琴的"音叉叮"(tine)
//             独立相位(非谐倍频) + 独立快速衰减包络
//             两路相加后一起饱和
//
// 为什么需要分音 (这次改版的核心):
//   电钢琴(Rhodes/Wurlitzer/DX7)的辨识度不在稳态频谱, 而在音头:
//   击弦瞬间会激励一个比基频高 3~5 倍、且不是整数倍的金属分音,
//   它在 100~300ms 内迅速衰减, 而基频继续以正弦方式慢慢衰减。
//   只用一个振荡器 + 滤波器做不出这个 —— 滤波器只能让已有的谐波变暗,
//   造不出一个"本来不存在、且频率不成整数比"的分音。
//
//   非整数倍是关键: 整数倍(2x/4x)听起来像风琴的谐波叠加,
//   稍微偏离整数(如 4.125x)才有金属棒的"叮"感。
//
// 成本:
//   每声部多 1 个 24bit 相位累加器 + 1 个正弦查表 + 1 个乘法器。
//   分音频率在 note_on 时由引擎用移位加法算好(见 synth_engine.v),
//   不需要乘法器。
//===============================================================
module synth_voice #(
    parameter [4:0] K_A  = 5'd10,
    parameter [4:0] K_D  = 5'd12,
    parameter [4:0] K_D2 = 5'd9,      // 快速衰减档 (短促音色)
    parameter [4:0] K_R  = 5'd11,
    //  齐奏开关: 1 = 每声部带 2 路失谐振荡器(多约 50 LUT/声部),
    //   0 = 不综合这部分硬件(扩 32 声部时用 0 省资源)。
    parameter       UNISON = 1,
    // Keep the existing 32-voice resource budget until the shared new engine
    // is integrated. Select 12 explicitly for the corrected-envelope candidate.
    parameter integer ENV_FRAC = 4,
    parameter REALISTIC_LITE = 0
    //  2026-10-27 滑音重构: 原来每声部一套「24bit 当前音高 + 指数逼近」
    //   (实测 124 逻辑/声部, 32 声部 +3986, 直接导致 32 声部固件 96.2%
    //   布线卡死)。现在滑音斜坡移到 synth_engine 里只做一份
    //   (见 synth_engine.v 的 "3d) 滑音斜坡"), 声部只剩一个 24bit 二选一
    //   多路器 + 1 bit 使能 (约 25 LUT/声部), 32 声部合计约 -3000 逻辑。
    //
    //   音乐上也更合理: 滑音只对单音连奏有意义, 复音时 32 个声部同时
    //   滑音是噪音。所以本来就应该"全引擎一个斜坡 + 只让最新那个声部跟"。
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        tick,          // 99.3kHz 采样节拍

    input  wire        note_on,
    input  wire        note_off,
    input  wire [23:0] fcw,           // 主振荡器频率控制字
    input  wire [1:0]  tm_seg,        //  morph 段号 (引擎算一次, 全声部共用)
    input  wire [10:0] tm_frac,       //  morph 段内比例 0..1024 (引擎算一次)
    input  wire [15:0] env_att,       // 起音峰值(已含力度)
    input  wire [15:0] env_sus,       // sustain 电平
    input  wire [1:0]  env_speed,     // 包络速度: 0=1x 1=4x慢 2=16x慢 3=64x慢
    input  wire [3:0]  flt_kmin,      // 滤波起始档位 (小=亮)
    input  wire [3:0]  flt_kshift,    // 滤波关闭速度 (小=快)
    input  wire [3:0]  flt_kt,        // 音高补偿: 低音加大 k, 高音减小 k
    input  wire [3:0]  flt_kmax,      //  截止上限: 保证 fc >= 约 3 倍基频
    input  wire        fast_dec,      // 1 = 包络走快速衰减档

    //----  2026-10-22 新增: 齐奏(unison) 失谐 + 释放降速 ----
    //   为复现 v7 那个"像大提琴"的铺底。v7 的 pad 是 3 路失谐齐奏
    //   (INC_DET=230/2^24, 约 1.4Hz 拍频) + 慢起音 + 固定 3.5kHz 低通
    //   + 长释放。这里补上缺的两样: 失谐、慢释放。
    input  wire [23:0] uni_det,       // 齐奏失谐增量 (fcw 单位, 0 = 关闭)
    input  wire [1:0]  rel_speed,     // 释放降速: 0=1x 1=/4 2=/8 3=/16
    //----  2026-10-23 颤音 (相位调制) ----
    //   给相位累加器的输出加偏移, 零 DSP (引擎侧算一份 LFO, 每声部一个加法器)。
    //   深度单位: 24bit 相位的一个 LSB。+-(1<<24) 就是 +-1 个完整周期。
    input  wire signed [24:0] vib_pm, // 颤音相位偏移 (有符号, 0=关)

    //----  新增: 分音(tine) ----
    input  wire [23:0] bell_fcw,      // 分音频率控制字 (非谐倍频)
    input  wire [15:0] bell_amp,      // 分音起音幅度 (已含力度平方律)
    input  wire [1:0]  bell_spd,      // 分音衰减速度 0=41ms 1=82ms 2=165ms 3=330ms
    //  2026-10-28: 测试模式冻结分音包络。
    //   赛题现场验谱峰要求每根线稳态幅度恒定, 而分音包络最长 330ms 就衰完,
    //   衰完第二根线就没了, 评委只能数到 N 根而不是 2N 根。
    //   置 1 时 benv 停在起音值不动 (与主包络的 sus=60000 满持续一致)。
    input  wire        test_hold,

    //----  2026-10-27 滑音(portamento) —— 重构后只剩一个多路器 ----
    //   斜坡本身在 synth_engine 里只算一份 (glide_cur), 声部只决定
    //   "我这个声部跟不跟"。只有最近分配的那个声部跟, 其余直接走 fcw。
    //   成本: 1 bit 使能 + 24bit 二选一 ≈ 25 LUT/声部 (原 124)。
    input  wire        glide_en,      // 1 = 本声部跟随引擎滑音斜坡
    input  wire [23:0] glide_fcw,     // 引擎斜坡的当前音高 (已含八度偏移)

    output reg  signed [15:0] out,
    output wire [15:0] level,
    output wire        busy,
    output wire        audible,       //  可闻判定: 尾巴衰到听不见就不再算活跃
    output wire [2:0]  st_dbg,
    output wire [23:0] ph_dbg
);

    wire [15:0] env;            // 包络电平 (exp_env 输出)
    // ENV_FRAC=12 preserves a 634-unit quiet tine through its nominal tau.
    // ENV_FRAC=4 is the legacy production resource configuration.
    localparam integer BFRAC = ENV_FRAC;
    localparam integer BW = 16 + BFRAC;
    reg [BW-1:0] benv;
    reg retrig_pending;
    // Restart both oscillators only after the old main and tine are silent.
    // Keeping this pending state busy prevents a gain/allocator transition.
    wire start_note = retrig_pending && (st_dbg == 3'd5)
                     && (env == 16'd0) && (benv == {BW{1'b0}}) && !note_on;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) retrig_pending <= 1'b0;
        else if (tick) begin
            if (note_on) retrig_pending <= 1'b1;
            else if (start_note) retrig_pending <= 1'b0;
        end
    end

    //===========================================================
    // 0)  2026-10-27 滑音(portamento) —— 重构后只剩一个多路器
    //
    //   原来这里是一整套「24bit 当前音高寄存器 + 指数逼近 + 节拍分频」,
    //   实测 124 逻辑/声部, 32 声部 +3986 —— 直接导致 32 声部固件
    //   综合 96.2%、布线卡死在 Routing Phase 0。
    //
    //   重构理由(音乐 + 硬件):
    //     滑音只对单音连奏有意义。复音时 32 个声部同时滑音是噪音,
    //     而评委听滑音也只会在单音上听。所以斜坡本来就该全引擎一份,
    //     声部只需要回答"我这个声部跟不跟"。
    //     ⇒ 斜坡移到 synth_engine (见那里的 "3d) 滑音斜坡"),
    //       声部剩 1 bit 使能 + 一个 24bit 二选一 ≈ 25 LUT/声部。
    //
    //   为什么用 glide_fcw 而不是让引擎改写 fcw:
    //     斜坡要按 tick 更新, 而 fcw 来自 v_fcw_r (只在 note_on 那拍写)。
    //     多一路只读的 glide_fcw 让两者互不干扰, 也便于逐样本验证。
    //===========================================================
    wire [23:0] ph_inc = glide_en ? glide_fcw : fcw;

    //===========================================================
    // 1) 主振荡器 DDS 相位累加器 (24bit)
    //===========================================================
    reg [23:0] ph;
    reg        gate;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        ph <= 24'd0;
        else if (tick) begin
            // The old sound has faded before resetting either phase.
            if (start_note)             ph <= 24'd0;
            else                         ph <= ph + ph_inc;
        end
    end

    //  颤音: 相位偏移加在累加器输出上 (不是改 fcw, 零 DSP)。
    //   vib_pm 是 24bit 相位量纲, ph 也是 24bit, 直接相加。
    wire [24:0] ph_vib = $signed({1'b0, ph}) + vib_pm;
    wire [23:0] ph_out = ph_vib[23:0];

    wire [31:0] phase32 = {ph_out, 8'd0};

    //===========================================================
    // 2) 波形 + 音色 morph
    //===========================================================
    wire signed [15:0] w_sin, w_sqr, w_saw, w_tri, w_ssaw, w_mor;

    waveform_set u_ws (
        .phase(phase32),
        .sine(w_sin), .square(w_sqr), .saw(w_saw), .triangle(w_tri),
        .softsaw(w_ssaw)
    );

    generate
        if (REALISTIC_LITE != 0) begin : g_lite_wave
            // Final presets only use the endpoints sine(0) and softsaw(682).
            // Avoid one general interpolation multiplier per voice.
            assign w_mor = (tm_seg == 2'd2) ? w_ssaw : w_sin;
        end else begin : g_morph_wave
            timbre_morph u_tm (
                .sine(w_sin), .square(w_sqr), .saw(w_saw), .triangle(w_tri),
                .softsaw(w_ssaw),
                .seg(tm_seg), .frac(tm_frac), .sample(w_mor)
            );
        end
    endgenerate

    //===========================================================
    // 2b)  2026-10-22 新增: 齐奏(unison) 失谐
    //
    //   为什么要这个: 单振荡器的锯齿无论怎么滤波都是"死的"——
    //   频谱从按下到松开一模一样, 听起来像风琴/嗡鸣, 不像弦乐。
    //   真实的弦乐声部是一群乐器, 各自音高略有偏差, 叠加后产生
    //   每秒 1~2 次的拍频, 频谱包络随之缓慢起伏 —— 这就是
    //   "活"的感觉, 也是 v7 那个铺底被听成"大提琴"的关键。
    //
    //   做法: 主相位 ± 一个缓慢累加的失谐量, 得到两路振荡器,
    //   取平均。uni_det=0 时两路完全同相, 平均 == 原信号,
    //   所以对不启用齐奏的音色零影响(靠 uni_on 直接旁路)。
    //
    //   为什么不用 3 路: 3 路要除以 3, 没有免费的三分频;
    //   2 路取平均只需 >>1, 幅度精确不变。拍频 = 2*uni_det/2^24*fs。
    //===========================================================
    reg [23:0] ph_det;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        ph_det <= 24'd0;
        else if (tick) begin
            if (start_note) ph_det <= 24'd0;
            else            ph_det <= ph_det + uni_det;
        end
    end

    // uni_on 打一拍, 避免失谐量在音符中途变化时相位跳变
    reg uni_on;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)    uni_on <= 1'b0;
        else if (tick) uni_on <= (uni_det != 24'd0);
    end

    wire signed [15:0] w_u1, w_u2, w_uni, w_pre;

    generate
        if (UNISON != 0) begin : g_uni
            //  2026-10-23: 必须用 ph_out (含颤音偏移) 而不是裸 ph,
            //   否则齐奏的两路不跟着颤 —— 铺底 P3 正好走齐奏通路
            //   (w_pre = w_uni), 颤音会完全听不见。
            wire [31:0] ph_u1 = {ph_out + ph_det, 8'd0};
            wire [31:0] ph_u2 = {ph_out - ph_det, 8'd0};

            softsaw_osc u_u1 (.phase(ph_u1), .ssaw(w_u1));
            softsaw_osc u_u2 (.phase(ph_u2), .ssaw(w_u2));

            //  位宽陷阱(2026-10-22 修): 原来写
            //     wire signed [16:0] u3 = $signed(w_u1) + (($signed(w_u1) <<< 1));
            //   `<<<` 的结果位宽 = 左操作数位宽(16bit), 不会被外层的 17bit
            //   上下文拓宽。w_u1 峰值 32750, 2*w_u1 溢出 16bit 回绕,
            //   于是 3*u1 变成垃圾: 实测 3 次谐波从 -9.7dB 抬到 -5.3dB,
            //   4 次 -10.1 -> -6.9dB —— 听感就是"发毛/发吵"的毛刺。
            //   必须先把操作数显式符号扩展到 18bit 再做移位。
            wire signed [17:0] w1x = {{2{w_u1[15]}}, w_u1};   // 16 -> 18bit
            wire signed [17:0] w2x = {{2{w_u2[15]}}, w_u2};
            wire signed [18:0] u3  = w1x + (w1x <<< 1);       // 3*u1 (max 98250)
            wire signed [18:0] usum = u3 + w2x;               // max 131000 < 2^17
            assign w_uni = usum[17:2];              // /4, 等幅时幅度不变
            assign w_pre = uni_on ? w_uni : w_mor;  // 未启用时完全旁路
        end else begin : g_nouni
            assign w_uni = 16'sd0;
            assign w_pre = w_mor;
        end
    endgenerate

    //===========================================================
    // 3) 滤波包络 + 低通
    //===========================================================
    reg [15:0] fenv;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                    fenv <= 16'd0;
        else if (tick) begin
            if (start_note)             fenv <= 16'd0;
            else if (fenv != 16'hFFFF)   fenv <= fenv + 16'd1;
        end
    end

    // k = kmin + (fenv >> kshift) - kt, 钳到 0..7
    //   上限 7 / 下限 0: 超出范围会让滤波器不稳定或把基频砍掉。
    //   kt 是音高补偿: 低音区 kt 大(截止更低, 更闷), 高音区 kt 小。
    //
    //   位宽: 右边是 16bit 移位结果, 必须先用 17bit 容器接住再比较,
    //     直接写 wire [4:0] 会触发 EX3791 截断警告, 并在 Gowin 综合里
    //     升级成 SP00018 直接失败(实测)。
    //    2026-10-21 关键修复: 上限不能是 7, 必须由 flt_kmax 给。
    //     k=7 的截止是 125Hz, 对 C4(261Hz) 来说是把基频本身砍掉 13dB。
    //     实测(24bit 包络修好之后)电钢 A 的包络在 150ms->200ms 之间
    //     从 -10.4dB 突然掉到 -21.2dB —— 就是滤波器扫过基频造成的,
    //     听感是"钢琴音弹下去一半突然瘪掉", 完全不像琴。
    //     现在 flt_kmax 按音高给 (见 synth_engine 的 kmax_of), 保证
    //     截止始终 >= 约 3 倍基频, 滤波器只削高次谐波, 不动基频。
    wire [16:0] kraw = {12'd0, flt_kmin} + ({1'b0, fenv} >> flt_kshift);
    wire [16:0] ksub = (kraw > {13'd0, flt_kt}) ? (kraw - {13'd0, flt_kt}) : 17'd0;
    wire [3:0]  kcur = (ksub > {13'd0, flt_kmax}) ? flt_kmax : ksub[3:0];

    wire signed [15:0] w_flt;
    filt_lp u_flt (
        .clk(clk), .rst_n(rst_n), .tick(tick), .clear(start_note),
        .x(w_pre), .k(kcur), .y(w_flt)
    );

    //===========================================================
    // 4)  分音振荡器 (tine) + 快速衰减包络
    //
    //   相位独立, 频率是基频的非整数倍 (如 4.125x)。
    //   包络不受 gate 控制: 松键后分音自然衰减完,
    //   这符合真实乐器 —— 制音器止住的是弦的基频, 金属分音本来就很短。
    //===========================================================
    reg [23:0] ph_bell;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        ph_bell <= 24'd0;
        else if (tick) begin
            if (start_note)             ph_bell <= 24'd0;
            else                         ph_bell <= ph_bell + bell_fcw;
        end
    end

    //  2026-10-21: 原来这里例化的是 waveform_set 只接 .sine。
    //   综合报告实测 u_bell = 166 LUT/声部, 而五种波形全出的 u_ws 只要
    //   47 ALU + 30 LUT = 77/声部 —— 只出一个正弦反而贵一倍多
    //   (u_ws 的正弦是算术实现, u_bell 被综合成了一张大 LUT 表)。
    //   32 声部因此超资源 1368。换成 33 点专用小表 sine_lite。
    wire signed [15:0] w_bell;
    sine_lite u_bell (
        .phase({ph_bell, 8'd0}),
        .sine(w_bell)
    );

    // Rate-matched ceil rounding. The corrected candidate uses 12 fractional bits. Each speed
    // uses its own bias; the low-level tail still reaches exactly zero.
    reg [15:0] bround;
    always @* begin
        case (bell_spd)
            2'd0: bround = 16'd4095;
            2'd1: bround = 16'd8191;
            2'd2: bround = 16'd16383;
            default: bround = 16'd32767;
        endcase
    end
    wire [BW:0] benv_c = {1'b0, benv} + bround;
    reg [BW:0] bdec;
    always @* begin
        case (bell_spd)
            2'd0: bdec = benv_c >> 12;
            2'd1: bdec = benv_c >> 13;
            2'd2: bdec = benv_c >> 14;
            default: bdec = benv_c >> 15;
        endcase
    end
    wire [BW-1:0] bamp_fixed = {bell_amp, {BFRAC{1'b0}}};
    wire [BW:0] retrig_bdec = ({1'b0, benv} + {{(BW-3){1'b0}},4'd15}) >> 4;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) benv <= {BW{1'b0}};
        else if (tick) begin
            if (start_note)
                benv <= (gate && !note_off) ? bamp_fixed : {BW{1'b0}};
            // Entering spectrum mode over a ringing note must still fade the
            // old tine before phase reset; otherwise RETRIG can wait forever.
            else if (test_hold && !(REALISTIC_LITE && (note_on || retrig_pending)))
                benv <= benv;                      // 测试模式: 冻结, 谱线幅度恒定
            else if (note_on || retrig_pending)
                // Fade the old tine; do not raise its amplitude at an arbitrary phase.
                benv <= benv - retrig_bdec[BW-1:0];
            else if (bdec >= {1'b0, benv})
                benv <= {BW{1'b0}};
            else
                benv <= benv - bdec[BW-1:0];
        end
    end

    //===========================================================
    // 5) gate
    //===========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            gate <= 1'b0;
        else if (tick) begin
            if (note_on)       gate <= 1'b1;
            else if (note_off) gate <= 1'b0;
        end
    end

    //===========================================================
    // 6) ADSR (复用 exp_env)
    //
    //   包络速度由音色预设给: 慢起音/长释放的音色只要把 tick 分频即可。
    //    重触发淡出(S_RETRIG=5)和释放(S_REL=4)必须走全速 tick。
    //     只有 ATTACK/DECAY 才跟着 env_speed 降速。
    //===========================================================
    reg [5:0] env_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)    env_cnt <= 6'd0;
        else if (tick) env_cnt <= env_cnt + 6'd1;
    end

    wire env_slow = (env_speed == 2'd1) ? (env_cnt[1:0] == 2'd0) :   // 每 4 拍
                    (env_speed == 2'd2) ? (env_cnt[3:0] == 4'd0) :   // 每 16 拍
                    (env_speed == 2'd3) ? (env_cnt[5:0] == 6'd0) :   // 每 64 拍
                                          1'b1;                      // 每拍
    // Once the main envelope is silent, wait for the tine before leaving RETRIG.
    wire wait_tine = retrig_pending && (st_dbg == 3'd5)
                     && (env == 16'd0) && (benv != {BW{1'b0}});

    //  2026-10-22 新增: 释放降速。
    //   弦乐/铺底的松键余音不是"咔"一下消失, 而是持续几百毫秒到几秒。
    //   exp_env 的 K_R 是编译期常量(全局共用), 想给某一个音色单独拉长
    //   释放就只能在这里分频。rel_speed: 0=1x 1=/4 2=/8 3=/16。
    //   只在 S_REL(4) 生效 —— 起音/衰减/重触发都不能变慢。
    wire rel_slow = (rel_speed == 2'd0) ? 1'b1 :
                    (rel_speed == 2'd1) ? (env_cnt[1:0] == 2'd0) :
                    (rel_speed == 2'd2) ? (env_cnt[2:0] == 3'd0) :
                                          (env_cnt[3:0] == 4'd0);
    wire tick_rel = (rel_speed == 2'd0) ? tick : (tick & rel_slow);

    wire tick_env = !wait_tine && ((st_dbg == 3'd5) ? tick :
                                   (st_dbg == 3'd4) ? tick_rel :
                                   (tick & env_slow));

    exp_env #(.K_A(K_A), .K_D(K_D), .K_D2(K_D2), .K_R(K_R), .FRAC(ENV_FRAC))
    u_env (
        .clk(clk), .rst_n(rst_n), .tick(tick_env), .gate(gate), .restart(note_on),
        .fast_dec(fast_dec),
        .att_lvl(env_att), .sus_lvl(env_sus),
        .env(env), .state(st_dbg)
    );

    //===========================================================
    // 7) 输出 = (滤波后主波形 × 包络) + (分音 × 分音包络)
    //
    //   先滤波再乘包络(减法合成的标准顺序): 滤波器看到的是满幅波形,
    //   不会因为包络很小时把滤波器"喂不饱"而产生量化噪声。
    //===========================================================
    wire signed [31:0] pe = $signed(w_flt)  * $signed({1'b0, env});
    wire signed [31:0] pb = $signed(w_bell) * $signed({1'b0, benv[BW-1:BFRAC]});

    wire signed [32:0] psum = $signed(pe) + $signed(pb);
    wire signed [16:0] sg   = psum >>> 16;

    wire signed [15:0] sat = (sg >  17'sd32767) ?  16'sd32767 :
                             ((sg < -17'sd32768) ? -16'sd32768 : sg[15:0]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)     out <= 16'sd0;
        else if (tick)  out <= sat;
    end

    assign level   = env;
    // busy: 分配器用 —— 还在发声(哪怕极轻)就不能被偷, 否则会掐断余音
    assign busy    = gate | retrig_pending | (env != 16'd0) | (benv != {BW{1'b0}});
    // audible controls mix normalization; busy controls voice allocation.
    // Ignore envelope tails below 64/65535 (~-60 dBFS) for normalization.
    // gate is excluded because a held pluck may already have decayed.
    assign audible = retrig_pending
                   | (env        >= 16'd64)
                   | (benv[BW-1:BFRAC] >= 16'd64);
    //  2026-10-23: ph_dbg 从裸累加器 ph 改成含颤音偏移的 ph_out。
    //   否则用相位差分测频看不到颤音 (vib_pm 只作用在 ph_out 上),
    //   tb_vib 会得出"颤音完全没工作"的假结论。
    //   vib_pm=0 时 ph_out == ph, 既有测频台不受影响。
    assign ph_dbg  = ph_out;

endmodule
