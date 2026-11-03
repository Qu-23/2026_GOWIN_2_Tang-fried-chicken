//===============================================================
// synth_engine - 8 路复音合成器引擎 (v10)
//
// 架构借鉴 fpga-main/rtl/{voice,waveform_set,timbre_morph}.sv:
//   每声部 = DDS 相位 -> 4 波形(组合逻辑, 无 ROM) -> morph 插值 -> ADSR -> 力度
//   声部之间完全并行, 不需要分时复用波表
//
// 音色切换: wave_sel 选 morph 预设
//   0 -> 正弦(0)   1 -> 方波(341)   2 -> 锯齿(682)   3 -> 三角(1023)
//   (以后可以把 morph 做成 10bit 连续旋钮, 就是一个表情维度)
//
// 时钟: 6.36MHz, tick = 99.3kHz
//===============================================================
module synth_engine #(
    parameter        N_V      = 8,
    parameter [4:0]  K_A      = 5'd10,
    parameter [4:0]  K_D      = 5'd12,
    parameter [4:0]  K_R      = 5'd13,
    parameter [15:0] SUS_LVL  = 16'd45000,
    parameter [15:0] ATT_LVL  = 16'd65535,
    parameter [7:0]  MASTER   = 8'd40,
    //  2026-10-21: 拨弦音色三变体, 编译期选 (见 preset 2'd1 分支)
    //   为什么是 parameter 而不是运行时端口: exp_env 的衰减档位
    //   (25'd1 << K_D2) 必须是常量移位, 换成变量就成了 32 选 1 桶形移位器。
    //  2026-10-22 定稿: 拨弦选 V2(明亮)。V2/V3 已改成运行时变体(见 preset
    //   2'd1 分支), 这里只决定余音长度 K_D2: 0 -> 9 (V1 的 5ms),
    //   其余 -> 13 (82ms, V2/V3 共用)。所以设 1 和设 2 等价。
    parameter [1:0]  PLUCK_SEL = 2'd1,  // 0=V1 短促 1/2=V2/V3 长余音(定稿 V2)
    //  2026-10-22: 齐奏硬件开关。1 = 每声部多 2 个失谐振荡器 (铺底"大提琴"
    //   需要它), 0 = 不综合这部分 (扩 32 声部时省资源)。见 synth_voice.v。
    parameter        UNISON    = 1,
    //  2026-10-22: 测试模式 (赛题现场验证项「多路不同频率 + 频谱可数谱峰」)。
    //   1 = 忽略音色预设, 全部声部强制成「纯正弦 + 满持续 + 滤波旁路 + 无分音」,
    //       且频率不走 note_table, 而是按声部索引查 1/6 倍频程表,
    //       于是 N 声部 = N 根等间距独立谱线, 用频谱仪一眼能数。
    parameter        TEST_MODE = 0,
    //  2026-10-27 滑音(portamento)总开关。
    //   重构后斜坡搬到引擎里只做一份 (见 3d 段), 成本约 100 逻辑
    //   与声部数无关, 所以这个参数不再是"省资源开关", 只是 A/B 用:
    //   GLIDE=0 等价于把运行时 p_glide 强制成 0 (完全不滑音),
    //   GLIDE=1 由 UART/按键的 glide_sel 在 0/1/2/3 四档间选。
    parameter        GLIDE     = 1,
    // Two final instrument paths; legacy/main_O builds keep their old defaults.
    parameter        REALISTIC_LITE = 0
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        tick,

    input  wire        note_on,
    input  wire        note_off,
    input  wire [4:0]  note_idx,
    input  wire [7:0]  velocity,
    input  wire [1:0]  wave_sel,
    input  wire [1:0]  ep_sel,          //  电钢候选 A/B/C (仅 wave_sel==0 时有效)
    input  wire [1:0]  vib_sel,         //  颤音深度 0=关 1=浅 2=中 3=深
    input  wire [1:0]  glide_sel,       //  滑音速度 0=关 1=40ms 2=80ms 3=160ms
    input  wire        tst_mode,        //  2026-10-28 测试模式运行期开关

    output reg  signed [15:0] out_l,
    output reg  signed [15:0] out_r,

    output wire [5:0]  n_active,
    output wire [23:0] ph0_dbg
);

    //===========================================================
    // 0a) 拨弦衰减档位 (编译期常量)    //   V1 现有: K_D2=9  (tau 5.2ms, 4.6tau 约 24ms —— 近乎"嗒"一声)
    //   V2/V3  : K_D2=13 (tau 82ms,  4.6tau 约 380ms —— 有可闻余音)
    //    必须在这里算成 localparam, 不能写成端口: exp_env 里
    //     (25'd1 << K_D2) 若 K_D2 是信号就变成桶形移位器, 且 Gowin 会报
    //     SP00018 综合失败 (见 README 开发笔记)。
    //===========================================================
    localparam [4:0] K_D2_SEL = (PLUCK_SEL == 2'd0) ? 5'd9 : 5'd13;

    //===========================================================
    // 0b)  2026-10-28: 测试模式改成运行期可切换
    //   原来 TEST_MODE 是编译期参数, 现场要验「多路谱峰」就得重烧固件
    //   (main_K -> main_test32 -> main_K)。现在 UART 一条控制帧就能切,
    //   比赛现场不用换固件。
    //   TEST_MODE 参数保留: 设 1 表示"上电即测试模式"(main_test32 用)。
    //   两者取或 —— 所以 TEST_MODE=1 的固件行为与原来完全一致。
    //===========================================================
    wire tst = (TEST_MODE != 0) || tst_mode;

    // 模式切换那一拍清所有 gate: 否则从测试模式切回演奏时, N 个声部
    // 还按测试频率一直响 (tvoice 停在 N_VOICES, 不再发 note_off)。
    reg tst_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) tst_d <= 1'b0;
        else        tst_d <= tst;
    end
    wire tst_chg = tst ^ tst_d;

    //===========================================================
    // 0b)  测试模式频率表 (1/6 倍频程, 100Hz 起, 32 档)
    //   赛题现场验证要求「多路不同频率, 频谱可观测对应数量独立谱峰」。
    //   选 1/6 倍频程的理由: 相邻峰恒定相差 12%, 在对数频谱上等间距,
    //   任何 FFT 分辨率下都分得开。
    //    2026-10-28 从 200Hz 起改到 100Hz 起: 开分音后每声部出两根线
    //     (基频 + x4.125), 最高一根 = 3355.5 x 4.125 = 13.8kHz, 距 Nyquist
    //     49.66kHz 还很远。原来 200Hz 起时最高基频 7184Hz, x4.125 = 29.6kHz
    //     也不混叠, 但那样 64 根线挤在 200Hz..30kHz, 低频端相邻只差 24Hz,
    //     20ms 的 FFT 窗分不开。改成 100Hz 起后整表降到 100Hz..3.36kHz,
    //     基频段最低相邻差 12Hz 但都在低频, 用长窗即可; 而且 x4.125 后
    //     整体仍在 412Hz..13.8kHz, 谱线密度翻倍但都不挤。
    //   表里存的是 FCW = f * 2^24 / 99316, 直接就是 DDS 增量。
    //   声部索引 v 取表项 v*STRIDE (STRIDE = 32/N_V), 这样无论 8 还是
    //   32 声部, 谱线都铺满整个 100Hz..3.36kHz, 而不是挤在低频端。
    //===========================================================
    localparam [5:0] T_STRIDE = (32 / N_V < 1) ? 6'd1 : (32 / N_V);

    function [23:0] test_fcw_of;
        input [5:0] v;
        reg   [7:0] ti;
        begin
            ti = v * T_STRIDE;
            if (ti > 8'd31) ti = 8'd31;
            case (ti[4:0])
                6'd0 : test_fcw_of = 24'd16893;   //  100.0 Hz
                6'd1 : test_fcw_of = 24'd18920;   //  112.0
                6'd2 : test_fcw_of = 24'd21190;   //  125.4
                6'd3 : test_fcw_of = 24'd23733;   //  140.5
                6'd4 : test_fcw_of = 24'd26581;   //  157.4
                6'd5 : test_fcw_of = 24'd29771;   //  176.2
                6'd6 : test_fcw_of = 24'd33343;   //  197.4
                6'd7 : test_fcw_of = 24'd37345;   //  221.1
                6'd8 : test_fcw_of = 24'd41826;   //  247.6
                6'd9 : test_fcw_of = 24'd46845;   //  277.3
                6'd10: test_fcw_of = 24'd52466;   //  310.6
                6'd11: test_fcw_of = 24'd58762;   //  347.9
                6'd12: test_fcw_of = 24'd65814;   //  389.6
                6'd13: test_fcw_of = 24'd73711;   //  436.3
                6'd14: test_fcw_of = 24'd82557;   //  488.7
                6'd15: test_fcw_of = 24'd92464;   //  547.4
                6'd16: test_fcw_of = 24'd103559;  //  613.0
                6'd17: test_fcw_of = 24'd115986;  //  686.6
                6'd18: test_fcw_of = 24'd129905;  //  769.0
                6'd19: test_fcw_of = 24'd145493;  //  861.3
                6'd20: test_fcw_of = 24'd162953;  //  964.6
                6'd21: test_fcw_of = 24'd182507;  // 1080.4
                6'd22: test_fcw_of = 24'd204408;  // 1210.0
                6'd23: test_fcw_of = 24'd228937;  // 1355.2
                6'd24: test_fcw_of = 24'd256409;  // 1517.9
                6'd25: test_fcw_of = 24'd287178;  // 1700.0
                6'd26: test_fcw_of = 24'd321639;  // 1904.0
                6'd27: test_fcw_of = 24'd360236;  // 2132.5
                6'd28: test_fcw_of = 24'd403464;  // 2388.4
                6'd29: test_fcw_of = 24'd451880;  // 2675.0
                6'd30: test_fcw_of = 24'd506106;  // 2996.0
                default: test_fcw_of = 24'd566839; // 3355.5
            endcase
        end
    endfunction

    //===========================================================
    // 0) tick 上升沿检测 -> tick1 (1 拍)
    //     引擎跑 6.36MHz, tick 来自 1.59MHz 的 req, 在这个域里是 4 个时钟宽。
    //      直接用 if(tick) 会让相位/包络每 tick 执行 4 次 -> 音高 x4、包络快 4 倍。
    //===========================================================
    reg tick_d, tick1;
    // Mode changes can fall between audio ticks. Queue all-notes-off so
    // the voices, not only the allocator flags, leave test sustain.
    reg tst_flush_pending;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) tst_flush_pending <= 1'b0;
        else if (tst_chg) tst_flush_pending <= 1'b1;
        else if (tick1) tst_flush_pending <= 1'b0;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin tick_d <= 1'b0; tick1 <= 1'b0; end
        else        begin tick_d <= tick; tick1 <= tick & ~tick_d; end
    end

    //===========================================================
    // 1) 演奏事件锁存
    //===========================================================
    reg        ev_on, ev_off;
    reg [4:0]  ev_note;
    reg [7:0]  ev_vel;
    reg [1:0]  ev_wav;
    reg [1:0]  ev_ep;

    reg on_d, off_d;
    wire on_edge  = note_on  & ~on_d;
    wire off_edge = note_off & ~off_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin on_d <= 1'b0; off_d <= 1'b0; end
        else        begin on_d <= note_on; off_d <= note_off; end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ev_on <= 1'b0; ev_off <= 1'b0;
            ev_note <= 5'd0; ev_vel <= 8'd0; ev_wav <= 2'd0; ev_ep <= 2'd0;
        end
        else if (on_edge) begin
            ev_on <= 1'b1; ev_off <= 1'b0;
            ev_note <= note_idx; ev_vel <= velocity;
            ev_wav <= REALISTIC_LITE ? ((wave_sel == 2'd3) ? 2'd3 : 2'd0) : wave_sel;
            ev_ep <= REALISTIC_LITE ? ((wave_sel == 2'd3) ? 2'd2 : 2'd0) : ep_sel;
        end
        else if (off_edge) begin
            ev_off <= 1'b1; ev_on <= 1'b0;
            ev_note <= note_idx;
        end
        else if (tick1) begin
            ev_on  <= 1'b0;
            ev_off <= 1'b0;
        end
    end

    // Presets captured from wave_sel at note-on.
    // Each preset sets the waveform morph, octave, amplitude envelope,
    // filter-envelope range and secondary oscillator parameters.
    // This legacy engine is selected only when ENGINE_REAL=0.
    reg [9:0]  p_morph;
    //  2026-10-23 颤音深度 (0=关 1=浅 2=中 3=深), 由 UART cmd[5:4] 给。
    //   声明必须放在这里 (预设寄存器区): 复位块与 ev_on 分支都早于颤音段引用它,
    //   写在颤音段里会报 vlog-2730 Undefined variable。
    reg [1:0]  p_vib;
    //  2026-10-23 滑音速度 (0=关 1=40ms 2=80ms 3=160ms), 由 UART cmd[7] 选中
    //   时从 glide_sel 取。声明同样要放在预设寄存器区。
    reg [1:0]  p_glide;
    //  滑音起点用的"上一个音高"由每个声部的 v_gfrom 保存, 见 3b) 查表段。
    //  2026-10-23: 段号与段内比例由引擎算一次, 全声部共用 (morph 是全局寄存器,
    //   32 个声部看到的完全一样, 在声部里各算一遍等于白烧 32 个乘法器)。
    wire [1:0]  tm_seg  = (p_morph >= 10'd1023) ? 2'd3 :
                          (p_morph >= 10'd682)  ? 2'd2 :
                          (p_morph >= 10'd341)  ? 2'd1 : 2'd0;
    reg  [9:0]  tm_base;
    always @* begin
        case (tm_seg)
            2'd0:    tm_base = 10'd0;
            2'd1:    tm_base = 10'd341;
            2'd2:    tm_base = 10'd682;
            default: tm_base = 10'd1023;
        endcase
    end
    wire [9:0]  tm_off  = p_morph - tm_base;
    wire [11:0] tm_off3 = {2'b00, tm_off} * 12'd3;
    wire [10:0] tm_frac = (p_morph >= 10'd1023) ? 11'd1024 : {1'b0, tm_off3[9:0]};
    reg        p_oct;        // 1 = 低一个八度
    reg [1:0]  p_speed;      // 包络速度 0=1x 1=4x慢 2=16x慢
    reg [15:0] p_sus;        // sustain 电平(未乘力度)
    reg [3:0]  p_kmin;       // 滤波起始档位 (小=亮)
    reg [3:0]  p_kshift;     // 滤波关闭速度 (小=快)
    reg [3:0]  p_kt;         // 音高补偿: 低音加大 k (截止更低)
    reg [3:0]  p_kmax;       //  截止上限 (保证 fc >= 约 3 倍基频)
    reg        p_fastdec;    // 1 = 包络快速衰减 (拨弦)

    //----  2026-10-20 新增: 分音(tine) 参数 ----
    reg [1:0]  p_bell_ratio; // 0=x2  1=x3  2=x4.125  3=x7.125 (非谐!)
    reg [1:0]  p_bell_spd;   // 分音衰减 0=41ms 1=82ms 2=165ms 3=330ms
    reg [15:0] p_bell_amp;   // 分音起音幅度基值 (再乘力度平方律)
    reg [1:0]  p_kb;         // 力度亮度补偿: 重弹时 kmin 减 0~2 档

    //----  2026-10-22 新增: 齐奏失谐 + 释放降速 ----
    //   uni_det: 每 tick 的失谐相位增量。两路取 ±uni_det, 拍频
    //     = 2*uni_det/2^24*99316 Hz。118 -> 约 1.4Hz (与 v7 相邻两路一致)。
    //    加权 3:1 而不是 1:1: 等幅叠加时两路反相会完全抵消,
    //     实测基频包络起伏 11dB 峰峰 —— 那是"哇哇"的颤音, 不是弦乐群。
    //     3:1 后最大抵消只有 20log10(2/4) = -6dB, 起伏约 4dB, 自然得多。
    //   rel_speed: 释放降速档 0=1x 1=/4 2=/8 3=/16。
    //     只影响松键后的余音长度, 不影响起音。
    reg [23:0] p_uni_det;
    reg [1:0]  p_rel_speed;

    // 音高补偿查表: kt 随音高每 8 个半音降一档
    //   25 音表 0..24 = C4..C6:
    //     idx 0..7  (C4~G4)  -> kt=3
    //     idx 8..15 (G#4~D#5)-> kt=2
    //     idx 16..23(E5~B5)  -> kt=1
    //     idx 24    (C6)     -> kt=0
    //   这样截止频率始终在基频上方, 高音区不会被砍掉基频。
    reg [3:0] kt_of;
    always @* begin
        case (ev_note[4:3])
            2'd0:    kt_of = 4'd3;
            2'd1:    kt_of = 4'd2;
            2'd2:    kt_of = 4'd1;
            default: kt_of = 4'd0;
        endcase
    end

    //----  2026-10-21 新增: 截止上限 (kmax) ----
    //   只给 kt 偏移是不够的: kt 只挪起点, 滤波包络扫到底时 k 还是能到 7,
    //   而 k=7 的截止是 125Hz —— 对 C4(261Hz) 就是把基频砍掉 13dB。
    //   实测症状: 电钢 A 的包络在 150ms->200ms 之间从 -10.4dB 猛掉到 -21.2dB,
    //   听感是"琴音弹下去一半突然瘪掉"。修好 24bit 包络之后这个 bug 才暴露出来。
    //
    //   kmax 保证 fc >= 约 2~4 倍基频, 滤波器只削高次谐波, 绝不动基频:
    //     idx 0..7   (C4~G4,   262~392Hz) -> k=4 (1.0kHz, >=2.5x)
    //     idx 8..15  (G#4~D#5, 415~587Hz) -> k=3 (2.0kHz, >=3.4x)
    //     idx 16..23 (E5~B5,   659~988Hz) -> k=3 (2.0kHz, >=2.0x)
    //     idx 24     (C6,     1046Hz)     -> k=2 (4.0kHz, >=3.8x)
    reg [3:0] kmax_of;
    always @* begin
        case (ev_note[4:3])
            2'd0:    kmax_of = 4'd4;
            2'd3:    kmax_of = 4'd2;
            default: kmax_of = 4'd3;
        endcase
    end

    //----  力度 -> 亮度补偿 (重弹更亮) ----
    //   电钢的核心表达之一: 轻触是闷的圆润音, 重击是亮而带金属感的音。
    //   只改音量做不出这个 —— 必须让截止频率跟着力度走。
    //   3 档足够(听感上是连续的, 因为每档差 1 个八度的截止)。
    wire [1:0] kb_of = (ev_vel > 8'd160) ? 2'd2 :
                       (ev_vel > 8'd96 ) ? 2'd1 : 2'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p_morph <= 10'd0; p_oct <= 1'b0; p_speed <= 2'd0; p_sus <= 16'd26000;
            p_kmin  <= 4'd1;  p_kshift <= 4'd10; p_kt <= 4'd3; p_fastdec <= 1'b0;
            p_bell_ratio <= 2'd2; p_bell_spd <= 2'd2;
            p_bell_amp <= 16'd0;  p_kb <= 2'd0; p_kmax <= 4'd4;
            p_uni_det <= 24'd0;   p_rel_speed <= 2'd0;
            p_vib <= 2'd0;
            p_glide <= 2'd0;
        end
        else if (ev_on) begin
            p_kt <= kt_of;
            p_kmax <= kmax_of;
            p_kb <= kb_of;
            // 默认不齐奏、不降速释放; 只有铺底的分支会改写这两项。
            p_uni_det   <= 24'd0;
            p_rel_speed <= 2'd0;
            //  颤音深度由 UART 的 cmd[5:4] 给, 与音色无关, 任何音色都能用。
            //   放在 case 之后赋值, 保证不被各音色分支覆盖。
            p_vib <= vib_sel;
            //  滑音: 只在音高真的变化时启动。同一音重复按下不该滑,
            //   否则连奏同音会听到一个多余的弯音。
            p_glide <= glide_sel;
            case (ev_wav)
                //===================================================
                // 0 电钢 —— 三个候选 (由 ep_sel 选)
                //   三者共享: 正弦基频 + 非谐分音 + 力度耦合音色
                //   差别在"分音多高、多亮、多快消失"
                //===================================================
                2'd0: begin
                    p_oct <= 1'b0; p_speed <= 2'd0; p_fastdec <= 1'b0;
                    case (ev_ep)
                    //---- A: Rhodes 经典 (温暖, 分音柔和) ----
                    // Legacy Rhodes A: sine fundamental plus a decaying tine.
                    // Keep morph=0 to avoid a sustained static harmonic layer.
                    // Tine ratio, decay and amplitude are assigned below.
                    2'd0: begin
                        p_morph <= 10'd0;      // Sine fundamental
                        // Zero sustain lets a held piano note decay to silence.
                        // Decay time constant is approximately 330 ms.
                        p_sus   <= 16'd0;
                        p_kmin  <= 4'd1; p_kshift <= 4'd11;
                        p_bell_ratio <= 2'd2;  // x4.125 (非整数倍, 独立可闻)
                        p_bell_spd   <= 2'd3;  //  330ms (原 165ms)
                        p_bell_amp   <= 16'd26000;
                    end
                    //---- B: Wurlitzer 簧片 (明亮, 有奇次谐波) ----
                    //   分音 = 基频 x3.5 (非整数 -> 独立可闻的"噼")
                    //   基频带一点点方波 (morph=80 约 12%) -> 奇次谐波给"咬"感,
                    //   但不能太多: 25% 方波的 3/5/7 次谐波会盖过分音,
                    //   实测 morph=170 时分音 x3.5 只有 -26dB, 完全听不出来。
                    2'd1: begin
                        p_morph <= 10'd80;     // sine -> square 12%
                        p_sus   <= 16'd8000;   //  2026-10-30: 20000 -> 8000 (低音嗡鸣)
                        p_kmin  <= 4'd0; p_kshift <= 4'd10;
                        p_bell_ratio <= 2'd1;  // x3.5
                        p_bell_spd   <= 2'd1;  // 82ms (更快, 更"噼")
                        p_bell_amp   <= 16'd26000;
                    end
                    //---- C: DX7 金属 (高、亮、长尾) ----
                    //   分音 = 基频 x7.125, 330ms 才消失, 幅度 0.40
                    //   这是 FM 电钢那个"玻璃感"的来源
                    default: begin
                        p_morph <= 10'd0;
                        p_sus   <= 16'd8000;   //  2026-10-30: 22000 -> 8000 (低音嗡鸣)
                        p_kmin  <= 4'd1; p_kshift <= 4'd12;
                        p_bell_ratio <= 2'd3;  // x7.125
                        p_bell_spd   <= 2'd3;  // 330ms
                        p_bell_amp   <= 16'd26000;
                    end
                    endcase
                end
                2'd1: begin
                    //===================================================
                    // 拨弦 —— 三个编译期变体 (PLUCK_SEL)
                    //   三者都是 sus=0 + 快速衰减档, 差别在"多亮、余音多长"。
                    //    K_D2 必须是常量 (exp_env 里是 (25'd1<<K_D2) 常量移位),
                    //     所以余音长短只能编译期定, 不能做成运行时旋钮。
                    //     tau = 2^K_D2 / 99300:
                    //       K_D2=9  -> 5.2ms  (4.6tau 约 24ms, 近乎"嗒"一声)
                    //       K_D2=13 -> 82ms   (4.6tau 约 380ms, 有可闻余音)
                    //    kmin 对 C4 无效: kraw=kmin+(fenv>>kshift), kt=3,
                    //     C4 时 kraw 前 15ms 全部 < kt -> ksub=0 -> 直通。
                    //     所以"柔和"只能靠 kshift 关得快, 不能靠 kmin。
                    //===================================================
                    p_oct <= 1'b0; p_speed <= 2'd0;
                    p_sus <= 16'd0; p_kmin <= 4'd0;
                    p_fastdec <= 1'b1;
                    //  2026-10-28: 拨弦开分音。
                    //   真实拨弦在弦被拨动瞬间有一大堆高频泛音冲击, 然后迅速
                    //   衰减 —— 那就是"叮"的金属点。原来 bell_amp=0, 起音是
                    //   纯 softsaw, 听感偏"电子琴"。
                    //   x2.75 是非整数倍 (与 softsaw 的 2/3/4 次谐波都不重合),
                    //   41ms 衰完 (spd=0), 只负责音头那一下, 不影响余音长度。
                    //    每声部包含两个独立相位累加器。
                    p_bell_amp   <= 16'd10000;
                    p_bell_ratio <= 2'd0;   // x2.75
                    p_bell_spd   <= 2'd0;   // 41ms, 只做音头
                    if (PLUCK_SEL == 2'd0) begin
                        //---- V1 现有: 方波 + 5ms 衰减 + 极快变暗 ----
                        // Short-decay reference preset.
                        //   只在 PLUCK_SEL=0 时可用 (余音长度是编译期常量)。
                        p_morph  <= 10'd341;   // 方波
                        p_kshift <= 4'd9;      // 约 20ms 就暗到 1kHz
                    end else begin
                        //----  2026-10-22 定稿: V2/V3 改成运行时变体 ----
                        //   V2 与 V3 共用 K_D2=13 (余音一样长), 只差
                        //   morph 与 kshift, 全是寄存器 => 一份固件两个变体,
                        //   网页"变体"下拉即时切换, 不用重烧板子。
                        //   定稿是 V2 (ep_sel=0), V3 留作对照 (ep_sel=1)。
                        case (ev_ep)
                        //---- V2 较明亮 (定稿): 柔化锯齿 + 82ms 衰减 + 慢变暗 ----
                        //    用 softsaw(682) 而不是方波: 锯齿含全部谐波(1/k),
                        //     方波只有奇次。实测重心 softsaw 738Hz vs 方波 567Hz,
                        //     1-4kHz 占比 13.1% vs 7.4% —— softsaw 才是更亮的那个。
                        //     这也更像真实拨弦: 弦的振动本来就含所有谐波,
                        //     只有"空心"的音色(单簧管类)才只剩奇次。
                        //   kshift=12 让高次谐波保持 165ms 才暗下去,
                        //   配合 380ms 的余音, 是"拨弦"而不是"敲击"。
                        2'd0: begin
                            p_morph  <= 10'd682;   // softsaw (全部谐波)
                            p_kshift <= 4'd12;     // 约 165ms 才暗到 1kHz
                        end
                        //---- V3 较柔和: 近正弦 + 82ms 衰减 + 中等变暗 ----
                        //   morph=120 = 正弦往方波走 35%, 只剩很弱的奇次谐波。
                        //   实测重心 322Hz、1-4kHz 仅 1.5% —— 圆润、不刺耳,
                        //   代价是辨识度低, 可能不像拨弦而像软槌敲击。
                        default: begin
                            p_morph  <= 10'd120;   // sine -> square 35%
                            p_kshift <= 4'd10;     // 约 41ms 开始变暗
                        end
                        endcase
                    end
                end
                2'd2: begin
                     //===================================================
                     // 贝斯 —— 三个运行时变体 (由 ep_sel 选, 见网页"变体"下拉)
                     //   共用: 降一个八度 (C4 键 -> C3 130.8Hz) + softsaw
                     //    为什么能用运行时变体而拨弦不行: 拨弦的余音长度
                     //     靠 K_D2 (exp_env 里的常量移位), 必须编译期定;
                     //     贝斯只动 morph/sus/kmin/kshift/分音, 全是寄存器,
                     //     所以一份固件里放三个变体、串口切换即可。
                     //   k 的含义提醒: k 越大截止越低(越暗)。kraw=kmin+(fenv>>kshift),
                     //   再减 kt, 所以 kmin 是"起点亮度", kshift 是"变暗快慢"。
                     //===================================================
                     p_oct <= 1'b1; p_speed <= 2'd0; p_fastdec <= 1'b0;
                     case (ev_ep)
                     //---- B1 现有: 音头一闪就闷 ----
                     //   kmin=4 -> 起点 k=1 (7.9kHz), kshift=10 -> 41ms 就关到
                     //   kmax=4 (1kHz)。之后频谱完全静止 = 有点"死"。
                     //    2026-10-30 低音嗡鸣: sus 14000 -> 6000。
                     //     降八度后 C4 键出 130Hz, 14000 (-8.3dB) 的平台
                     //     意味着按住 0.6s 后电平几乎不动 —— 130Hz 的锯齿串
                     //     平着响就是"嗡嗡的贝斯嗡鸣"。6000 (-13.3dB) 让它在
                     //     0.8s 内落到 -13dB 再慢慢收, 保留贝斯该有的持续感,
                     //     但不再"卡住"。
                     2'd0: begin
                         p_morph <= 10'd682;  p_sus <= 16'd6000;
                         p_kmin  <= 4'd4;     p_kshift <= 4'd10;
                         p_bell_ratio <= 2'd2; p_bell_spd <= 2'd2;
                         p_bell_amp <= 16'd0;
                     end
                     //---- B2 厚实持续: 起点更亮、变暗慢 8 倍 ----
                     //   kshift=13 -> 每 82ms 关一档, 330ms 才关到底;
                     //   前 82ms k=0 (直通), 正好给拨奏一点"咬"。
                     //    2026-10-30 低音嗡鸣: sus 30000 -> 10000。
                     //     30000 (-3.4dB) 是三个变体里最"卡住"的一个,
                     //     低音区听起来就是"一个很响的嗡嗡音一直在"。
                     2'd1: begin
                         p_morph <= 10'd682;  p_sus <= 16'd10000;
                         p_kmin  <= 4'd2;     p_kshift <= 4'd12;
                         p_bell_ratio <= 2'd2; p_bell_spd <= 2'd2;
                         p_bell_amp <= 16'd0;
                     end
                     //---- B3 有音头/颗粒: 偏方波 + 一个 41ms 的低分音 ----
                     //   morph=520 = 方波往 softsaw 走 52% -> 奇次谐波更足,
                     //   是"酸贝斯"那种咬合感, 不是纯锯齿的糊。
                     //   分音 x2.75 = 360Hz, 41ms 衰完, 只负责"哒"一下的音头。
                     //    2026-10-30 低音嗡鸣: sus 22000 -> 8000。
                     2'd2: begin
                         p_morph <= 10'd520;  p_sus <= 16'd8000;
                         p_kmin  <= 4'd3;     p_kshift <= 4'd11;
                         p_bell_ratio <= 2'd0; p_bell_spd <= 2'd0;
                         p_bell_amp <= 16'd12000;
                     end
                     default: begin
                         p_morph <= 10'd682;  p_sus <= 16'd6000;
                         p_kmin  <= 4'd4;     p_kshift <= 4'd10;
                         p_bell_ratio <= 2'd2; p_bell_spd <= 2'd2;
                         p_bell_amp <= 16'd0;
                     end
                     endcase
                 end
                //  铺底: 改用 softsaw (morph=682) 而不是三角波。
                //   v7 之所以像大提琴, 就是因为它用柔化锯齿: 2次-7dB/3次-11dB
                //   偶次谐波完整; 而三角波只有奇次且 1/k^2, 像长笛。
                //   滤波也不能太狠: kmin=2 (4kHz) 保留弦乐的弓摩擦感,
                //   kshift=13 让变暗过程很慢, 符合弓弦持续音的特性。
                2'd3: begin
                     //===================================================
                     // 铺底 —— 三个运行时变体 (由 ep_sel 选)
                     //   共用: 不降八度 + env 慢 64 倍 (起音约 250ms)
                     //   铺底的问题从来不是"不够响", 是会往下沉:
                     //   滤波只会关不会开, 一关就越来越闷, 加上包络衰减,
                     //   听感是"音在往后缩"。所以三个变体都在削弱"变暗"。
                     //===================================================
                     p_oct <= 1'b0; p_speed <= 2'd3; p_fastdec <= 1'b0;
                     //  2026-10-28: 铺底开分音 (原来 bell_amp=0)。
                     //   铺底起音是 64x 慢 (约 250ms), 所以分音必须比主振荡器
                     //   活得久才有意义 —— 用最慢档 spd=3 (330ms tau, 约 1.5s
                     //   衰完), 幅度给 9000, 于是: 按下瞬间先出一个 x4.125 的
                     //   "气声"音头, 主振荡器慢慢涨上来时它还在, 两段重叠成
                     //   "弓起音"的质感。若用 165ms (spd=2) 则主振荡器还没起来
                     //   分音就没了, 只剩一个孤立的"咔哒", 等于白开。
                     //    每声部包含两个独立相位累加器。
                     // The x3.5 partial sits between harmonics 3 and 4.
                     // It avoids the close spacing of x4.125 and harmonic 4
                     // in the low register; bell_fcw_of implements the ratio.
                     p_bell_amp   <= 16'd9000;
                     p_bell_ratio <= 2'd1;   // x3.5 (避开整数次谐波, 不产生粗糙拍频)
                     p_bell_spd   <= 2'd3;   // 330ms tau, 覆盖整个慢起音
                     case (ev_ep)
                     //---- P1 现有: 先直通 165ms 再关到 1kHz ----
                     2'd0: begin
                         p_morph <= 10'd682;  p_sus <= 16'd20000;
                         p_kmin  <= 4'd2;     p_kshift <= 4'd13;
                     end
                     //---- P2 更柔更圆: 往三角波走 58%, 只留奇次低次谐波 ----
                     //   三角波没有偶次, 所以"厚度"下降、"毛刺"消失,
                     //   配合 kmin=3 (起点 2kHz) 与 kshift=14, 整体偏暗偏暖。
                     2'd1: begin
                         p_morph <= 10'd880;  p_sus <= 16'd22000;
                         p_kmin  <= 4'd3;     p_kshift <= 4'd14;
                     end
                     //---- P3  大提琴 (复现 v7) ----
                     //   v7 那个被听成"大提琴"的铺底, 关键不是波形也不是滤波,
                     //   而是多路轻微失谐的齐奏 + 长释放。单振荡器再怎么
                     //   滤波都是"死"的: 频谱从按下到松开一模一样, 像风琴。
                     //   失谐后两路互相拍频 (uni_det=230 -> 约 1.4Hz),
                     //   频谱包络每秒起伏一两次 —— 那才是"一群琴"的感觉。
                     //    kmin 必须给到 7, 不是 2:
                     //     p_kmin_eff = kmin - p_kb, 而重弹(vel=200)时 kb=2,
                     //     再减 kt=3, kmin=2 时 kraw=2 根本够不到 kt, k 恒为 0
                     //     = 滤波器全程旁路, 出来的就是没滤波的锯齿, 重心 5.9kHz,
                     //     听感是"嗡"不是"弦"。kmin=7 -> 重弹 k=2 (4kHz, 对应 v7 的
                     //     3.5kHz 固定低通), 轻弹 k=4 (1kHz, 更柔)。
                     default: begin
                         p_morph <= 10'd682;  p_sus <= 16'd24000;
                         p_kmin  <= 4'd7;     p_kshift <= 4'd15;
                         p_uni_det   <= 24'd118;
                         p_rel_speed <= 2'd3;
                     end
                     endcase
                 end
            endcase
            if (REALISTIC_LITE != 0) begin
                if (ev_wav == 2'd0) begin
                    // Keep the sine body and velocity-squared tine. The sampled
                    // candidate showed that a loud inharmonic tine sounds coarse;
                    // taper it in the treble rather than globally darkening the body.
                    p_morph <= 10'd0;
                    p_sus <= 16'd0;
                    p_bell_ratio <= 2'd2;
                    p_bell_amp <= (ev_note < 5'd8) ? 16'd4800 :
                                  (ev_note < 5'd16) ? 16'd3600 : 16'd2400;
                    p_bell_spd <= (ev_note < 5'd16) ? 2'd3 : 2'd2;
                end else begin
                    // Bowed sound: let the main envelope create the attack.
                    // A sine tine starting at full level is a struck/metallic onset.
                    p_morph <= 10'd682;
                    p_bell_amp <= 16'd0;
                    p_uni_det <= 24'd0;
                    p_sus <= 16'd40000;
                    p_rel_speed <= 2'd2;
                end
            end
            //----  测试模式覆盖: 放在 case 之后, 非阻塞赋值后写胜出 ----
            //   目标不是"好听", 而是"频谱干净、谱峰可数":
            //     纯正弦(morph=0)  -> 每声部基频一根线, 没有谐波干扰
            //     bell_amp=TB_AMP  ->  每声部再出一根 x4.125 的线, 共 2N 根
            //     uni_det=0        -> 关掉齐奏失谐, 否则每声部变成两根挨着的线
            //     sus=60000        -> 满持续, 不衰减, 稳态谱线幅度恒定
            //     kmin=kt=kmax=0   -> 滤波档位恒 0 = 旁路, 不会随时间变暗
            //    2026-10-28: 条件从编译期 TEST_MODE 改成运行期 tst;
            //     并且开了分音 —— 32 声部 = 64 根谱线, 吞吐量翻倍可当场数出来。
            //     分音包络由 test_hold 冻结 (见 synth_voice), 否则 330ms 后
            //     第二根线就衰没了, 只能数到 32 根。
            if (tst) begin
                p_morph     <= 10'd0;
                p_oct       <= 1'b0;
                p_speed     <= 2'd0;
                p_sus       <= 16'd60000;
                p_kmin      <= 4'd0;
                p_kshift    <= 4'd15;
                p_kt        <= 4'd0;
                p_kmax      <= 4'd0;
                p_kb        <= 2'd0;
                p_fastdec   <= 1'b0;
                p_bell_amp  <= 16'd16384;  // 半幅: 两根线等高, 不削波
                p_bell_ratio<= 2'd2;       // x4.125 (非整数倍, 不会和基频谐波撞)
                p_bell_spd  <= 2'd3;       // 最慢档 (虽然 test_hold 会冻结它)
                p_uni_det   <= 24'd0;
                p_rel_speed <= 2'd0;
                p_vib       <= 2'd0;   // 测试模式要谱线稳定, 关颤音
                p_glide     <= 2'd0;   // 测试模式要谱线稳定, 关滑音
            end
        end
    end

    // 力度亮度补偿后的实际起始档位 (不能为负)
    wire [3:0] p_kmin_eff = (p_kmin > {2'd0, p_kb}) ? (p_kmin - {2'd0, p_kb}) : 4'd0;

    //===========================================================
    // 3) 声部状态
    //===========================================================
    reg [4:0]  v_note [0:N_V-1];
    reg        v_gate [0:N_V-1];
    reg [15:0] v_att  [0:N_V-1];
    reg [15:0] v_sus  [0:N_V-1];
    //  2026-10-20 新增: 每声部的分音(tine)参数
    reg [23:0] v_bfcw [0:N_V-1];   // 分音频率控制字 (非谐倍频)
    reg [15:0] v_bamp [0:N_V-1];   // 分音起音幅度 (已含力度平方律)

    wire [23:0] v_fcw     [0:N_V-1];
    wire [23:0] v_bfcw_s  [0:N_V-1];   // 分音 FCW (已含八度偏移)
    wire [15:0] v_level [0:N_V-1];
    wire signed [15:0] v_out [0:N_V-1];
    wire        v_busy  [0:N_V-1];
    wire        v_aud   [0:N_V-1];   //  可闻: 归一化只用这个, 不用 busy
    wire [2:0]  v_st    [0:N_V-1];
    wire [23:0] v_ph    [0:N_V-1];

    //  2026-10-27 滑音斜坡本身放在 4) 写声部段之后 (那里才声明 wr_* /
    //   last_fcw / v_glide_en)。这里只留声明, 见下面的 "3d) 滑音斜坡"。
    reg [N_V-1:0] v_glide_en;   // 1 bit/声部: 该声部是否跟随滑音斜坡
    wire [23:0]   glide_fcw_o;  // 引擎斜坡的当前音高 (已含八度偏移)


    //-----------------------------------------------------------
    // 3a) 音符查表: 全引擎共享一份
    //
    //    2026-10-19 重构 (音域 25 -> 61 音):
    //     原来是 generate 里每声部例化一份 note_table, 32 声部 = 32 份
    //     组合 case 表 = 1152 LUT, 而且是每声部组合路径的一部分。
    //     32 声部综合后 pll_clk Fmax 只有 6.417MHz (需求 6.357MHz,
    //     余量 1%), 再往组合路径上加东西必然崩。
    //
    //     改法: 只留一份组合表, 只在 note_on 分配声部的那一拍用它查一次,
    //     把结果锁进该声部的 v_fcw_r 寄存器。面积从 1152 LUT 降到 ~90 LUT
    //     + 每声部 24bit FF, 同时查表移出声部组合路径。
    //
    //     代价: 声部音高在 note_on 那一拍才更新 —— 本来就是如此
    //     (v_note 也只在 note_on 时写), 行为等价。
    //-----------------------------------------------------------
    wire [23:0] fcw_lut;            // 共享查表输出 (组合)
    reg  [23:0] v_fcw_r [0:N_V-1];  // 每声部锁存的 FCW
    //  2026-10-27 删除了 v_gfrom (每声部 24bit 滑音起点)。
    //   滑音斜坡搬到引擎之后, 起点由引擎的 glide_from 寄存器统一保存
    //   (见 3d) 段), 声部侧不再需要。32 声部共省 32×24 = 768 个 FF。

    // 用哪个 note 去查表: note_on 时查新音, 否则查 0 号(结果丢弃)
    wire [4:0]  lut_idx = ev_on ? ev_note : 5'd0;
    note_table u_nt (.note_idx(lut_idx), .fcw(fcw_lut));

    genvar gi;
    generate
    for (gi = 0; gi < N_V; gi = gi + 1) begin : g_nt
        // 音色预设 2(贝斯): 频率控制字右移 1 位 = 低一个八度
        assign v_fcw[gi]  = p_oct ? {1'b0, v_fcw_r[gi][23:1]} : v_fcw_r[gi];
        // 分音跟随同一个八度偏移, 否则低音色上分音会跑高一个八度
        assign v_bfcw_s[gi] = p_oct ? {1'b0, v_bfcw[gi][23:1]} : v_bfcw[gi];
    end
    endgenerate

    //===========================================================
    // 3c)  2026-10-23 颤音 (vibrato) —— 赛题拓展第 2 条的第三个表情维度
    //
    //   力度是第 1 维, 音色(4 音色 x 变体)是第 2 维, 这里补第 3 维。
    //
    //    为什么用相位调制而不是改 fcw:
    //     改 fcw 要 fcw * LFO 的乘法, 每声部一个, 32 声部就是 32 个乘法器 ——
    //     main_F 的 DSP 已经 101/118, 装不下。
    //     相位调制只是给相位累加器的输出加一个偏移, 每声部一个 25bit
    //     加法器 (约 12 LUT), LFO 本身全引擎只算一份。零 DSP。
    //
    //    为什么 PM 的深度可以很大: PM 造成的音高偏移 = 深度(周期数) x 调制
    //     频率, 与载波频率无关。深度 +-0.5 周期 @6Hz = +-3Hz 偏移 ——
    //     在 440Hz 上是 +-12 音分 (标准弦乐颤音), 在低音区音分更大,
    //     这正是人耳对低音颤音更敏感的自然规律。
    //
    //    三角波而不是正弦: 三角波只要一个加法器 + 两个比较器,
    //     听感上与正弦颤音的差别要专门训练才分得出。
    //===========================================================
    localparam signed [25:0] VIB_A    = 26'sd8388608;   // 幅度 2^23
    localparam signed [25:0] VIB_STEP = 26'sd2048;      // 2^11 -> 4*A/step = 16384 tick = 6.05Hz

    reg  signed [25:0] vib_acc;
    reg               vib_dir;      // 0 = 上升, 1 = 下降
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vib_acc <= 26'sd0;
            vib_dir <= 1'b0;
        end
        else if (tick1) begin
            //  2026-10-23 修正: 最初写的是"越界就反弹到 VIB_A - STEP",
            //   但那不是三角波 —— 反弹后下一拍又变成 +STEP, 立刻又越界,
            //   于是 vib_acc 在 VIB_A-STEP 和 VIB_A 之间卡死在顶部,
            //   颤音完全不工作 (只有一次上冲, 之后是恒定的 +A 相位偏移)。
            //   必须用方向标志真正来回走。
            if (vib_acc >= VIB_A) begin
                vib_acc <= VIB_A - VIB_STEP;
                vib_dir <= 1'b1;
            end
            else if (vib_acc <= -VIB_A) begin
                vib_acc <= -VIB_A + VIB_STEP;
                vib_dir <= 1'b0;
            end
            else begin
                vib_acc <= vib_dir ? (vib_acc - VIB_STEP) : (vib_acc + VIB_STEP);
            end
        end
    end

    // 深度档: 0=关 1=浅 2=中 3=深
    //    2026-10-23 修正: 最初写 >>>5/>>>4/>>>3, 实测只有 +-1.5/3/6 音分,
    //     比标准弦乐颤音 (15~30 音分) 浅得多, 上板几乎听不出区别。
    //     现在 >>>3/>>>2/>>>1 给出 +-6/12/24 音分 @440Hz。
    //    2026-10-29 想再加深一档 (>>>2/>>>1/>>>0 -> ±16.6/32.9/65.8 音分),
    //     但实测这一改让 32 声部固件布不通: build/m32_fxn3 连续三次
    //     卡死在 [60%] Routing Phase 0 (每次 60~70 分钟无进展后人工终止),
    //     而同一份源码只把这一处 + 滑音分频还原成 >>>3/>>>2/>>>1 就能在
    //     11 分钟内布通 (build/m32_fxn2)。⇒ 保持 >>>3/>>>2/>>>1 不变。
    //     现场觉得"不明显"的真正原因见 firmware/main_N/README.md:
    //     颤音被滑音的连续音高变化掩蔽, 演示时把滑音关掉 (glide_sel=0)
    //     再听颤音, 三档差别是清楚的。
    //
    //   换算 (三角波 PM, 载波 fc, 调制 fm=6.05Hz):
    //     相位峰值 A (周期) -> 瞬时频偏 = 4*A*fm
    //     vib_acc 满幅 2^23, 右移 k 位后 A = 2^(23-k)/2^24 = 2^(-1-k) 周期
    //       k=3 -> A=1/16 -> 1.51Hz -> 6 音分 (实测 ±8.3, 三角波均值效应)
    //       k=2 -> A=1/8  -> 3.03Hz -> 12 音分 (实测 ±16.6)
    //       k=1 -> A=1/4  -> 6.05Hz -> 24 音分 (实测 ±32.9)
    //   p_vib 的声明在预设寄存器区 (见上方), 这里只做译码。
    wire signed [24:0] vib_pm =
        (p_vib == 2'd0) ? 25'sd0 :
        (p_vib == 2'd1) ? ($signed({vib_acc[25], vib_acc}) >>> 3) :
        (p_vib == 2'd2) ? ($signed({vib_acc[25], vib_acc}) >>> 2) :
                          ($signed({vib_acc[25], vib_acc}) >>> 1);

    //===========================================================
    // 4) 分配器
    //
    //    2026-10-19 时序修复:
    //     32 声部后关键路径变成 v_level(16bit) -> 32 路比较器 -> min_idx
    //     -> v_fcw_r[24] 的 CE 译码, pll_clk Fmax 只剩 6.374MHz
    //     (需求 6.357MHz, 余量 0.3%), 等于没有余量。
    //
    //     两处改动:
    //      a) 比较器只用 v_level[15:8] (高 8 位)。抢声部本来就不需要
    //         16bit 精度 —— 电平差在 1/256 以内时选谁听不出来。
    //         比较树从 16bit 降到 8bit, 少约 4 级逻辑。
    //      b) 分配结果先锁进 wr_* 寄存器, 下一拍再写声部状态。
    //         把 "选择器 -> CE 译码" 从 "比较器 -> 选择器" 上切开,
    //         关键路径变成两段。
    //
    //     事件本来就只有 tick1 一拍 (99.3kHz, 相对 6.36MHz 是 64 拍一次),
    //     多一拍延迟完全无所谓。
    //===========================================================
    integer i;
    reg [5:0] alloc_sel, min_idx, reuse_sel;   // 声部索引, N_V<=64 时 6bit 够
    reg       alloc_vld, reuse_vld;
    reg [7:0] min_env;

    always @* begin
        alloc_sel = 6'd0; alloc_vld = 1'b0;
        min_env = 8'hFF; min_idx = 6'd0;
        reuse_sel = 6'd0; reuse_vld = 1'b0;
        for (i = 0; i < N_V; i = i + 1) begin
            if (!v_gate[i] && !v_busy[i]) begin
                if (!alloc_vld) begin alloc_sel = i; alloc_vld = 1'b1; end
            end
            if (!reuse_vld && v_note[i] == ev_note && (v_gate[i] || v_busy[i])) begin
                reuse_vld = 1'b1; reuse_sel = i;
            end
            if (v_level[i][15:8] < min_env) begin min_env = v_level[i][15:8]; min_idx = i; end
        end
    end

    wire [23:0] att_full = {8'd0, ATT_LVL} * {16'd0, ev_vel};
    wire [15:0] att_s    = att_full[23:8];
    wire [23:0] sus_full = {8'd0, p_sus} * {16'd0, ev_vel};
    wire [15:0] sus_s    = sus_full[23:8];

    //===========================================================
    // 4a)  分音(tine) 参数生成
    //
    //   频率 = 基频 × 非整数倍率。倍率只用移位加法算, 不占乘法器:
    //     0: x2.75   = (fcw<<1)+(fcw>>1)+(fcw>>2)    (Wurlitzer 簧片)
    //     1: x3.5    = (fcw<<1)+fcw+(fcw>>1)         (备用, 中音区"木"感)
    //     2: x4.125  = (fcw<<2) + (fcw>>3)           (Rhodes 音叉)
    //     3: x7.125  = (fcw<<2)+(fcw<<1)+fcw+(fcw>>3) (DX7 金属)
    //
    //    2026-10-21 教训: 倍率必须避开整数, 尤其是 3 和 5。
    //     原来 B 候选用 x3.0, 结果和方波的 3 次谐波频率完全相同,
    //     两者叠加只是把 3 次谐波加响, 听不出"另一个音" ——
    //     实测 B 的 782Hz 从 30ms 到 800ms 一直是 -18dB 不动,
    //     那是一个静态谐波, 不是会衰减的金属分音。
    //     换成 x2.75 后 719Hz 落在基频和 3 次谐波之间, 才有"叮"的独立感。
    //
    //    幅度用力度平方律单独缩放, 而且比基频更陡:
    //     真实电钢轻弹时几乎没有"叮"声, 重击时金属分音很突出。
    //     所以分音幅度 ∝ vel², 而基频幅度 ∝ vel。
    //     这样力度就不只是"响/轻", 而是真正的音色维度。
    //
    //    时序: 这些量必须在 p_bell_* 更新之后再算, 所以不在
    //     tick1 那一拍算(那一拍 p_bell_* 还是上一音色的值),
    //     而是放到 wr_en 有效的下一拍(见 4b 的写声部阶段)。
    //===========================================================
    function [23:0] bell_fcw_of;
        input [23:0] f;
        input [1:0]  r;
        begin
            case (r)
                2'd0:    bell_fcw_of = {f[22:0], 1'b0} + {1'b0, f[23:1]}
                                     + {2'b00, f[23:2]};                       // x2.75
                2'd1:    bell_fcw_of = {f[22:0], 1'b0} + f + {1'b0, f[23:1]};  // x3.5
                2'd2:    bell_fcw_of = {f[21:0], 2'b0} + {3'd0, f[23:3]};      // x4.125
                default: bell_fcw_of = {f[21:0], 2'b0} + {f[22:0], 1'b0}
                                     + f + {3'd0, f[23:3]};                    // x7.125
            endcase
        end
    endfunction

    // 力度平方: vel²/65536 -> 0..~1.0 (Q16)
    wire [15:0] vel2      = ev_vel * ev_vel;
    wire [31:0] bamp_full = {16'd0, p_bell_amp} * {16'd0, vel2};
    wire [15:0] bamp_s    = bamp_full[31:16];
    //  用 fcw_lut 而不是 wr_fcw: 同一拍 wr_fcw 还是旧值。
    //   p_bell_ratio 在 ev_on 那一拍就更新了, 到 tick1&&ev_on 时已是新值。
    wire [23:0] bfcw_s    = bell_fcw_of(fcw_lut, p_bell_ratio);

    //---- 分配结果打一拍 ----
    reg        wr_en;
    reg [1:0]  wr_kind;        // 0=reuse 1=alloc 2=steal
    reg [5:0]  wr_sel;
    reg [4:0]  wr_note;
    reg [15:0] wr_att, wr_sus;
    reg [23:0] wr_fcw;
    //  最近一次分配出去的音高, 作为下一个音的滑音起点。
    reg [23:0] last_fcw;
    //  上一个音的滑音起点 (在写 wr_* 的那一拍抓 last_fcw 的旧值)。
    reg [23:0] wr_gfrom;
    reg [23:0] wr_bfcw;
    reg [15:0] wr_bamp;

    //===========================================================
    // 3d)  2026-10-27 滑音(portamento) 斜坡 —— 全引擎只做一份
    //
    //   原来是每声部一套 (synth_voice 里 24bit ph_cur + 指数逼近 + 节拍分频),
    //   实测 124 逻辑/声部, 32 声部 +3986。那正是 32 声部固件综合 96.2%、
    //   布线卡死在 Routing Phase 0 的最后一个障碍。
    //
    //   重构的两条理由:
    //     1) 音乐上: 滑音只对单音连奏有意义。复音时 N 个声部同时滑音
    //        是噪音; 评委听滑音也只在单音上听。所以斜坡本来就该全引擎一份。
    //     2) 硬件上: 指数逼近是"减法 + 常量右移 + 加法", 一份 vs N 份的
    //        差别就是 32 倍。搬到引擎后声部只剩一个 24bit 二选一。
    //
    //   谁跟斜坡: 只有最近一次分配的那个声部 (v_glide_en[wr_sel])。
    //   其余声部直接走 v_fcw, 与重构前 GLIDE=0 的行为逐位相同。
    //
    //   指数逼近而不是线性:
    //     - 零 DSP: 一次减法 + 一次常量右移 + 一次加法;
    //     - 高音滑得快、低音滑得慢, 与真实弦乐/长号的滑音一致
    //       (人耳听的是音程比例, 指数逼近在音程上是等速的)。
    //
    //    变量移位是 Gowin 综合的雷区 (见 filt_lp 的教训: `d1 >>> k`
    //     报 SP00018 综合失败), 所以这里固定 K=12, 三档速度改用
    //     "更新节拍分频": spd=1 每拍 (41ms) / spd=2 每 2 拍 (82ms) /
    //     spd=3 每 4 拍 (165ms)。指数收敛下, 放慢更新节拍与加大移位量
    //     在时间常数上完全等价 (2 倍节拍 = 2^1 移位)。
    //
    //    死区吸附(必须有): 步长是 (gdiff + 2^12 - 1) >> 12, 当
    //     |gdiff| < 2^12 时舍入结果是 0, 音高就永久停在目标下方。
    //     判据不用比较器, 直接看 gstep 是否为 0 (等价 |gdiff| <= 4095),
    //     省一个 25bit 比较器。
    //
    //    起振时机: 斜坡在写声部那一拍就把 glide_cur 摆到 glide_from,
    //     随即开始指数逼近。这里不能等声部空闲 —— 声部 gate/env 是
    //     同一拍起来的, 音立刻发声; 若等旧音尾巴(电钢约 2.5s)衰完才装载,
    //     这段时间声部一直停在旧音高上, 旋律里等于跑调。
    //     (曾经试过 gld_pend + v_busy 版本, 实测音高卡在上一个音不动。)
    //
    //   glide_from == 0 表示"没有上一个音"(上电后第一个音), 这时直接
    //   落在目标音高, 不能从 0Hz 滑上来。
    //===========================================================
    reg  [23:0] glide_cur;      // 斜坡当前音高 (24bit FCW)
    reg  [1:0]  glide_cnt;      // 更新节拍分频
    reg  [23:0] glide_tgt;      // 目标音高 (随 wr_fcw 一起锁存)
    reg  [23:0] glide_from;     // 起振起点 (随 wr_en 一起锁存 last_fcw 旧值)
    reg         glide_run;      // 1 = 斜坡正在跑

    wire signed [24:0] gld_diff = $signed({1'b0, glide_tgt}) - $signed({1'b0, glide_cur});
    wire signed [24:0] gld_step = (gld_diff + 25'sd2048) >>> 12;
    wire signed [24:0] gld_sum  = (gld_step == 25'sd0)
                                ? $signed({1'b0, glide_tgt})
                                : ($signed({1'b0, glide_cur}) + gld_step);
    //  GLIDE=0 (编译期关掉滑音) 时把运行时档位强制成 0, 与 GLIDE=1 下
    //   p_glide=0 走同一条通路 —— 斜坡逻辑因此不需要两套实现。
    wire [1:0] gl_sel = (GLIDE != 0) ? p_glide : 2'd0;
    // 更新节拍分频: spd=1 每拍, spd=2 每 2 拍, spd=3 每 4 拍
    //   ⇒ 实测时间常数 41/82/165ms (sim/tb_glide.v + analysis/glide_diag.py)。
    //    2026-10-29 曾整体放慢一倍 (82/165/330ms) 想让它更明显, 但实测
    //     让 32 声部固件布不通: build/m32_fxn3 三次卡死在 [60%] Routing
    //     Phase 0 (每次 60~70 分钟), 而只把这一处还原就能 11 分钟布通
    //     (build/m32_fxn2)。⇒ 保持 41/82/165ms 不变。
    //     现场觉得"不明显"是因为旋律里两个音之间只隔几十毫秒, 41ms 的指数
    //     逼近听起来就是"直接到位"——演示时用 spd=3 (165ms) 弹慢速连奏即可。
    wire gld_upd = (gl_sel == 2'd1) ? 1'b1
                 : (gl_sel == 2'd2) ? (glide_cnt[0] == 1'b1)
                 :                    (glide_cnt == 2'd3);

    //  装载部分不能套在 `else if (tick1)` 里。
    //   wr_en 是紧跟 tick1 之后一拍的单拍脉冲 (wr_en <= 1'b0 是默认值),
    //   而 tick1 每 64 拍才来一次 —— 套在 tick1 里 `if (wr_en)` 永远不成立。
    //   实测后果: 声部 v_glide_en 已置位但 glide_cur 还是复位值 0,
    //   主振荡器 ph_inc = 0 相位冻结, 基频完全不发声(只剩 1078Hz 分音)。
    //   所以: 装载走任意拍 (看 wr_en), 斜坡推进才按 tick1 节拍。
    //
    //    glide_from / glide_tgt 只在"写 wr_* 的那个 always"里赋值
    //   (那里 last_fcw 还是旧值), 本块只读 —— 避免双驱动。
    //
    //    斜坡在写声部那一拍就启动, 不等声部空闲。理由: 声部 gate 与
    //   env 同一拍就起来了, 音是立刻发声的; 若等旧音尾巴(电钢 2.5s)衰完,
    //   这段时间声部会一直停在 glide_from 的旧音高上 —— 旋律里等于跑调。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            glide_cur  <= 24'd0;
            glide_cnt  <= 2'd0;
            glide_run  <= 1'b0;
        end
        else begin
            if (tick1) glide_cnt <= glide_cnt + 2'd1;

            if (wr_en) begin
                glide_cur <= (glide_from == 24'd0 || gl_sel == 2'd0)
                             ? glide_tgt : glide_from;
                glide_run <= (glide_from != 24'd0) && (gl_sel != 2'd0);
            end
            else if (gl_sel == 2'd0) begin
                glide_cur <= glide_tgt;      // 关掉滑音: 立刻跟随
                glide_run <= 1'b0;
            end
            else if (tick1 && glide_run && gld_upd) begin
                glide_cur <= gld_sum[23:0];
                // 收敛后停止, 省掉无用的减法翻转 (也让 ph 完全稳定)
                if (gld_step == 25'sd0) glide_run <= 1'b0;
            end
        end
    end

    // 八度偏移与 v_fcw 保持一致 (贝斯预设降八度, 滑音目标也要降)
    assign glide_fcw_o = p_oct ? {1'b0, glide_cur[23:1]} : glide_cur;

    //===========================================================
    // 3c)  测试模式查表 (2026-10-28 只为削减逻辑)
    //   原来写 v_bfcw[wr_sel] <= tst ? bell_fcw_of(test_fcw_of(wr_sel), ...)
    //   —— 把 32:1 查表 MUX 例化了两份(基频一份 + 分音一份), 再串一组
    //   3 个 24bit 加法器。实测 main_L 比 main_K 多 511 逻辑 (u_eng +370),
    //   91.7% 让布线在 Routing Phase 0 卡死 12 小时。
    //   现在查表只留一份 (tfcw), 分音按测试模式固定的 x4.125 算:
    //   测试模式下 p_bell_ratio 恒为 2'd2 (见上面的 preset 覆盖块),
    //   所以直接写死倍率与 bell_fcw_of(...,2'd2) 完全等价, 只要一个加法器。
    //===========================================================
    wire [23:0] tfcw  = test_fcw_of(wr_sel);
    wire [23:0] tbfcw = {tfcw[21:0], 2'b0} + {3'd0, tfcw[23:3]};   // x4.125

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_en <= 1'b0; wr_kind <= 2'd0; wr_sel <= 6'd0;
            wr_note <= 5'd0; wr_att <= 16'd0; wr_sus <= 16'd0; wr_fcw <= 24'd0;
            wr_bfcw <= 24'd0; wr_bamp <= 16'd0;
            last_fcw <= 24'd0;
        end
        else begin
            wr_en <= 1'b0;
            if (tick1 && ev_on) begin
                wr_en   <= 1'b1;
                wr_kind <= reuse_vld ? 2'd0 : (alloc_vld ? 2'd1 : 2'd2);
                wr_sel  <= reuse_vld ? reuse_sel : (alloc_vld ? alloc_sel : min_idx);
                wr_note <= ev_note;
                wr_att  <= att_s;
                wr_sus  <= sus_s;
                wr_fcw  <= fcw_lut;
                wr_bfcw <= bfcw_s;
                wr_bamp <= bamp_s;
                //  滑音起点/目标必须在这一拍锁存 —— 只有这一拍 last_fcw
                //   还是上一个音的值。等到 3d) 段用 wr_en 时 last_fcw
                //   已经变成新音, 那里读会得到"起点 == 目标", 滑音永远不滑
                //   (实测 bug: 滑音完全失效)。
                //   同音重复按下时起点等于目标, 指数逼近立刻收敛, 听不出弯音。
                glide_from <= tst ? 24'd0 : last_fcw;
                glide_tgt  <= fcw_lut;
                last_fcw   <= tst ? 24'd0 : fcw_lut;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < N_V; i = i + 1) begin
                v_note[i] <= 6'd0; v_gate[i] <= 1'b0;
                v_att[i] <= 16'd0; v_sus[i] <= 16'd0;
                v_fcw_r[i] <= 24'd0;
                v_bfcw[i] <= 24'd0; v_bamp[i] <= 16'd0;
            end
            v_glide_en <= {N_V{1'b0}};
        end
        else begin
            //---- 写入选中的声部 (wr_* 已寄存, 这一拍只做 CE 译码) ----
            if (wr_en) begin
                if (wr_kind != 2'd0) v_note[wr_sel] <= wr_note;  // reuse 不改音名
                v_gate[wr_sel] <= 1'b1;
                v_att[wr_sel]  <= wr_att;
                v_sus[wr_sel]  <= wr_sus;
                //  测试模式下频率不走 note_table, 而是按声部索引查表:
                //   这样不管分配顺序如何, 每个声部都拿到一个互不相同的频率,
                //   频谱上必然是 N 根独立谱线。
                v_fcw_r[wr_sel] <= tst ? tfcw : wr_fcw;
                //  2026-10-28 测试模式的分音也必须跟 test_fcw_of, 不能用
                //   wr_bfcw (= 4.125 x note_table 的 fcw)。原来漏了这一步,
                //   分音频率跟的是"按下的音"(C4..G4), 与基频谱线无关,
                //   实测 8 声部只有 7 根分音线且偏差最多 21 cent。
                //    2026-10-28 二改: 原来写 bell_fcw_of(test_fcw_of(...)),
                //     等于把 32:1 查表 MUX 例化了两份(基频一份 + 分音一份),
                //     再串一组 3 个 24bit 加法器。实测 main_L 比 main_K 多
                //     511 逻辑(u_eng +370), 91.7% 让布线卡死 12 小时。
                //     现在查表只留一份 (wire tfcw), 分音直接按测试模式固定的
                //     x4.125 算(测试模式下 p_bell_ratio 恒为 2'd2, 见上面的
                //     覆盖块), 只要一个 24bit 加法器。
                v_bfcw[wr_sel]  <= tst ? tbfcw : wr_bfcw;
                v_bamp[wr_sel]  <= wr_bamp;
                //  2026-10-27 滑音: 只有刚分配的这个声部跟随引擎斜坡,
                //   同时把斜坡目标/起点更新成这个音 (见 3d 段)。
                //    tst 下必须置 0: 测试模式给每个声部的频率是
                //   test_fcw_of(声部号), 而引擎斜坡跟的是 note_table 的
                //   fcw_lut —— 两者不同, 跟了就出不了 N 根等间隔谱线。
                v_glide_en <= tst ? {N_V{1'b0}}
                             : ({N_V{1'b0}} | ({{(N_V-1){1'b0}}, 1'b1} << wr_sel));
            end
            //----  2026-10-28: 模式切换那一拍清所有 gate ----
            //   测试模式下 tvoice 停在 N_VOICES 不再发 note_off, 所以切回
            //   演奏模式时 N 个声部会一直按测试频率响。这里统一清掉,
            //   让它们走正常的释放包络 (gate=0 后 exp_env 进 S_REL)。
            if (tst_chg) begin
                for (i = 0; i < N_V; i = i + 1) begin
                    v_gate[i] <= 1'b0;
                    v_glide_en[i] <= 1'b0;
                end
            end
            //---- 松键 ----
            if (tick1 && ev_off) begin
                for (i = 0; i < N_V; i = i + 1)
                    if (v_note[i] == ev_note) begin
                        v_gate[i] <= 1'b0;
                        // 尾巴还在响, 但不该继续弯音了
                        v_glide_en[i] <= 1'b0;
                    end
            end
        end
    end

    reg [N_V-1:0] v_on_p, v_off_p;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin v_on_p <= {N_V{1'b0}}; v_off_p <= {N_V{1'b0}}; end
        else if (tick1) begin
            v_on_p  <= {N_V{1'b0}};
            v_off_p <= {N_V{1'b0}};
            if (REALISTIC_LITE && tst_flush_pending) begin
                v_off_p <= {N_V{1'b1}};
            end
            else if (ev_on) begin
                if (reuse_vld)      v_on_p[reuse_sel] <= 1'b1;
                else if (alloc_vld) v_on_p[alloc_sel] <= 1'b1;
                else                v_on_p[min_idx]   <= 1'b1;
            end
            else if (ev_off) begin
                for (i = 0; i < N_V; i = i + 1)
                    if (v_note[i] == ev_note) v_off_p[i] <= 1'b1;
            end
        end
    end

    //===========================================================
    // 5) N_V 个合成器声部
    //===========================================================
    generate
    for (gi = 0; gi < N_V; gi = gi + 1) begin : g_vo
        synth_voice #(
            .K_A(K_A), .K_D(K_D), .K_D2(K_D2_SEL), .K_R(K_R),
            .UNISON(UNISON),
            .REALISTIC_LITE(REALISTIC_LITE),
            .ENV_FRAC(REALISTIC_LITE ? 12 : 4)
        ) u_v (
            .clk(clk), .rst_n(rst_n), .tick(tick1),
            .note_on (v_on_p[gi]),
            .note_off(v_off_p[gi]),
            .fcw     (v_fcw[gi]),
            .tm_seg  (REALISTIC_LITE ? {p_morph[9], 1'b0} : tm_seg),
            .tm_frac (REALISTIC_LITE ? 11'd0 : tm_frac),
            // Expose the two-preset limits at the voice boundary, so synthesis
            // removes unused variable-shift/mux branches in every voice.
            .env_speed(REALISTIC_LITE ? {2{p_speed[0]}} : p_speed),
            .env_att (v_att[gi]),
            .env_sus (v_sus[gi]),
            .flt_kmin (p_kmin_eff),
            .flt_kshift(REALISTIC_LITE ? {1'b1, p_kshift[2], 2'b11} : p_kshift),
            .flt_kt   (p_kt),
            .flt_kmax (p_kmax),
            .fast_dec (REALISTIC_LITE ? 1'b0 : p_fastdec),
            .uni_det  (p_uni_det),
            .rel_speed(REALISTIC_LITE ? {p_rel_speed[1], 1'b0} : p_rel_speed),
            .vib_pm   (vib_pm),
            .bell_fcw (v_bfcw_s[gi]),
            .bell_amp (v_bamp[gi]),
            .bell_spd (REALISTIC_LITE ? {1'b1, p_bell_spd[0]} : p_bell_spd),
            .test_hold(tst),
            .glide_en (v_glide_en[gi]),
            .glide_fcw(glide_fcw_o),
            .out     (v_out[gi]),
            .level   (v_level[gi]),
            .busy    (v_busy[gi]),
            .audible (v_aud[gi]),
            .st_dbg  (v_st[gi]),
            .ph_dbg  (v_ph[gi])
        );
    end
    endgenerate

    //===========================================================
    // 6) 混音 + 归一化 + 软削波
    //===========================================================
    reg signed [23:0] mix_sum;
    always @* begin
        mix_sum = 24'sd0;
        for (i = 0; i < N_V; i = i + 1) mix_sum = mix_sum + v_out[i];
    end

    //---- 活跃声部计数 ----
    // Use v_aud for normalization and v_busy for allocation.
    // Including inaudible release tails in the mix count changes the gain
    // of notes still sounding when those tails finally reach zero.
    reg [5:0] nact;
    always @* begin
        nact = 6'd0;
        for (i = 0; i < N_V; i = i + 1) nact = nact + (v_aud[i] ? 6'd1 : 6'd0);
    end

    //---- 连续归一化 (2026-10-22 修) ----
    // Eight gain levels reduce jumps as the active-voice count changes.
    // The curve is applied to the sum of voice outputs.
    function [15:0] gain_of;
        input [5:0] n;
        begin
            // 0.75 / n —— 原曲线(0.75 / 0.375 / 0.1875 / 0.09375)其实就是它的
            // 2 的幂取整, 这里补上中间的 n=3,5,6,7, 台阶从 6dB 降到 <=3.5dB。
            // 关键点 n=1/2/4/8 与旧曲线完全相同, 总电平不变, 不引入新的削波风险。
            //  2026-10-22: 表扩到 n=32 (原来 >7 全部落到 default=3072)。
            //   N_V=8 时 nact 最大 8, n<=7 的取值一个没变, 所以 8 声部行为
            //   完全不变; 扩到 32 声部时才有意义 —— 32 个声部若还按 /8 衰减,
            //   总和会超 4 倍直接削波, 削波产生的互调会把"数谱峰"搅乱。
            //   0.75/n 保证任意 N 下满幅叠加都刚好落在 0.75 满度。
            case (n)
                6'd0, 6'd1: gain_of = 16'd24576;   // 0.750
                6'd2:       gain_of = 16'd12288;   // 0.375   -6.0dB
                6'd3:       gain_of = 16'd8192;    // 0.250   -3.5dB
                6'd4:       gain_of = 16'd6144;    // 0.188   -2.5dB
                6'd5:       gain_of = 16'd4915;    // 0.150   -1.9dB
                6'd6:       gain_of = 16'd4096;    // 0.125   -1.6dB
                6'd7:       gain_of = 16'd3511;    // 0.107   -1.3dB
                6'd8:       gain_of = 16'd3072;    // 0.094   -1.2dB
                6'd9:       gain_of = 16'd2731;    // 0.083   -1.0dB
                6'd10:      gain_of = 16'd2458;    // 0.075   -0.9dB
                6'd11:      gain_of = 16'd2234;    // 0.068   -0.8dB
                6'd12:      gain_of = 16'd2048;    // 0.063   -0.8dB
                6'd13:      gain_of = 16'd1890;    // 0.058   -0.7dB
                6'd14:      gain_of = 16'd1755;    // 0.054   -0.6dB
                6'd15:      gain_of = 16'd1638;    // 0.050   -0.6dB
                6'd16:      gain_of = 16'd1536;    // 0.047   -0.6dB
                6'd17:      gain_of = 16'd1446;    // 0.044   -0.5dB
                6'd18:      gain_of = 16'd1365;    // 0.042   -0.5dB
                6'd19:      gain_of = 16'd1293;    // 0.039   -0.5dB
                6'd20:      gain_of = 16'd1229;    // 0.038   -0.5dB
                6'd21:      gain_of = 16'd1170;    // 0.036   -0.4dB
                6'd22:      gain_of = 16'd1117;    // 0.034   -0.4dB
                6'd23:      gain_of = 16'd1069;    // 0.033   -0.4dB
                6'd24:      gain_of = 16'd1024;    // 0.031   -0.4dB
                6'd25:      gain_of = 16'd983;     // 0.030   -0.3dB
                6'd26:      gain_of = 16'd945;     // 0.029   -0.3dB
                6'd27:      gain_of = 16'd910;     // 0.028   -0.3dB
                6'd28:      gain_of = 16'd878;     // 0.027   -0.3dB
                6'd29:      gain_of = 16'd847;     // 0.026   -0.3dB
                6'd30:      gain_of = 16'd819;     // 0.025   -0.3dB
                6'd31:      gain_of = 16'd793;     // 0.024   -0.3dB
                default:    gain_of = 16'd768;     // 0.023  (=0.75/32)
            endcase
        end
    endfunction

    wire [15:0]        g_tgt = gain_of(nact);
    //  24bit 定点增益 = 16bit 整数 + 8bit 小数 (g_cur[23:8] 是实际乘数)。
    //   为什么加小数: 原来 16bit 增益时, 慢抬升一旦让每拍增量 < 1 LSB 就退化成
    //   "每拍 +1" 的线性斜坡, 再慢就卡死不走了 —— 想做得更缓根本做不到。
    //   实测(analysis/poly_tail.py) 16bit 时无论 >>>13 还是 >>>14, 20ms 内的
    //   最大抬升都卡在 +1.78dB 不动, 就是被这个量化下限顶住了。
    reg  [23:0]        g_cur;
    wire signed [24:0] gdiff = $signed({1'b0, g_tgt, 8'd0}) - $signed({1'b0, g_cur});
    //  非对称平滑:
    //   下压 >>>7  (约 1.3ms 走完) —— 新音符叠加时必须尽快让出余量, 否则削波
    //   抬升 >>>15 (约 330ms 走完) —— 声部释放时缓慢回抬, 不要"突然变响"
    //    nact==0 时直接跳到目标: 全场没有可闻声部, 没人听得见这个跳变,
    //     这样下一首曲子的第一个音一定以满增益起音, 不会被慢抬升吃掉音头。
    //   原来两个方向都是 >>>7 —— 抬升太快, 就是台阶感的来源:
    //   实测旧版 979.6ms nact 3->2 时 20ms 内抬 +4.47dB。
    // Lite starts new voices before their attack becomes loud. A 0.32 ms
    // downward ramp uses that lead time while preserving a continuous gain.
    wire signed [24:0] gdn   = gdiff >>> (REALISTIC_LITE ? 5 : 7);
    wire signed [24:0] gup   = (gdiff + 25'sd32767) >>> 15;
    wire signed [24:0] gstep = (nact == 6'd0) ? gdiff
                             : ((gdiff < 25'sd0) ? gdn : gup);
    wire signed [24:0] gsum  = $signed({1'b0, g_cur}) + gstep;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)     g_cur <= {16'd24576, 8'd0};
        else if (tick1) g_cur <= gsum[23:0];
    end

    // 只用整数部分做乘 —— 小数部分只用来让斜坡连续, 1/32768 的台阶(-90dB)听不出来
    // Only the steady spectrum demonstration can enable 32 full-level tines
    // faster than the musical attack. Clamp there; playing keeps the ramp.
    wire [15:0] mix_gain = (REALISTIC_LITE && tst && g_cur[23:8] > g_tgt)
                           ? g_tgt : g_cur[23:8];
    wire signed [39:0] mp = mix_sum * $signed({1'b0, mix_gain});
    wire signed [24:0] ms = mp >>> 15;

    wire signed [15:0] sl = (ms >  25'sd32767) ?  16'sd32767 :
                            ((ms < -25'sd32768) ? -16'sd32768 : ms[15:0]);

    //---- 输出抗超声低通 [1 3 3 1]/8 ----
    //    为什么需要: 引擎跑 99.3kHz, 波形谐波一直延伸到 49kHz;
    //     板上模拟低通只有两阶(截止 7.8kHz), 到 25kHz 才 -20dB,
    //     所以大量超声波进了 DAC 和运放。器件的非线性会把这些超声波
    //     互调回音频段 —— 而且互调产物与信号成固定比例,
    //     正好解释"调音量没用、噪声始终跟着信号走"。
    //   这一级把 24kHz 以上压 9dB、37kHz 以上压 25dB,
    //   而 12kHz 以内只损 2dB(听不出), 三角波 8kHz 以上的谐波本来就在 -50dB。
    //   代价: 3 个加法器, 不占 DSP。
    //   OUT_LP=0 可整级旁路。
    localparam OUT_LP = 1;
    reg signed [15:0] lp1, lp2, lp3;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin lp1 <= 16'sd0; lp2 <= 16'sd0; lp3 <= 16'sd0; end
        else if (tick1) begin lp1 <= sl; lp2 <= lp1; lp3 <= lp2; end
    end
    wire signed [18:0] lsum = $signed({{3{sl[15]}}, sl})
                            + $signed({{3{lp1[15]}}, lp1}) + $signed({{2{lp1[15]}}, lp1, 1'b0})
                            + $signed({{3{lp2[15]}}, lp2}) + $signed({{2{lp2[15]}}, lp2, 1'b0})
                            + $signed({{3{lp3[15]}}, lp3});
    wire signed [15:0] lpf = lsum[18:3];      // /8

    wire signed [15:0] yl = OUT_LP ? lpf : sl;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_l <= 16'sd0;
            out_r <= 16'sd0;
        end
        else if (tick1) begin
            out_l <= (yl > 17'sd32767) ? 16'sd32767 :
                     ((yl < -17'sd32768) ? -16'sd32768 : yl[15:0]);
            out_r <= (yl > 17'sd32767) ? 16'sd32767 :
                     ((yl < -17'sd32768) ? -16'sd32768 : yl[15:0]);
        end
    end

    assign n_active = nact;
    // 0 号声部相位 (调试/测频用)。原来恒 0, 测频台子无法工作。
    assign ph0_dbg  = v_ph[0];

endmodule
