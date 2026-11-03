// Shared audio/control core for Tang Mega 60K (GW5AT-LV60PG484AC1/I0).
// top_hdmi instantiates this core and adds the HDMI visualizations.
// ENGINE_REAL selects the shared sample-table renderer or synth_engine.
// UART binary input: A5 cmd MIDI_note velocity; note range 60..84.
// The internal note index is 0..24. The final instruments are 0 and 3.
// PT8211 output uses audio_drive_lsbj when USE_LSBJ=1.
// Current physical pin assignments are defined by the project CST.
module top #(
    parameter N_VOICES = 8,           // 复音数 (8 = 当前 v9 配置; 32 = 扩展验证)
    parameter USE_LSBJ = 1,           // 1=PT8211 原生 LSBJ (正确)  0=旧 Philips I2S (仅对照)
    //  2026-10-21: 板载按键的默认音色与电钢候选。
    //   电钢琴阶段把 KEY_WAVE 设成 0, 按键直接弹电钢, 不用开网页。
    //   做 A/B/C 三版 bitstream 时只改 EP_SEL, 其余代码完全相同。
    parameter [1:0] KEY_WAVE = 2'd0,  // 按键默认音色 0=电钢 1=拨弦 2=贝斯 3=铺底
    parameter [1:0] EP_SEL   = 2'd0,  // 按键默认电钢候选 0=A 1=B 2=C
    // PLUCK_SEL selects the legacy plucked-string preset.
    parameter [1:0] PLUCK_SEL = 2'd2, // 0=V1 现有 1=V2 明亮 2=V3 柔和(定稿)
    //  2026-10-22: 齐奏(unison) 硬件开关, 见 synth_voice.v。
    //   1 = 每声部多 2 个失谐振荡器, 铺底的"大提琴"变体(P3)靠它。
    //   扩 32 声部时若资源不够, 把它设 0 (P3 退化成普通单振荡器)。
    parameter UNISON = 1,
    //  2026-10-21: 功放使能方式。
    //   0 = 上电稳定后常开 (推荐, 修复「拨弦一按下就是电流声」)
    //   1 = 旧行为: 有音符才开、静音 200ms 后关 (仅诊断对照)
    parameter PA_GATE = 0,
    //  2026-10-22: 测试模式 (赛题现场验证项「多路不同频率 + 频谱可数谱峰」)。
    //   0 = 正常演奏固件
    //   1 = 上电后自动按下 N_VOICES 个不同频率的音并永不松键,
    //       频谱仪上就是 N 根等间距独立谱线。见 src/top_test.v。
    //   实际频率由 synth_engine 在 TEST_MODE 下按声部索引生成 (1/6 倍频程表),
    //   不走 note_table —— 所以 32 声部也能有 32 根谱线。
    parameter TEST_MODE = 0,
    //  2026-10-23: 硬件效果器 (赛题拓展要求第 2 条「混响/延迟/合唱」)。
    //   0 = 完全旁路, 综合器把整个 fx_engine 优化掉, 不占任何资源
    //   1 = 带效果器, 由 UART 的 fx 字段运行时切换混响/延迟/合唱
    parameter FX_ON = 0,
    // BT_ON enables the JDY-31 receive path and event transmission.
    // Module TXD connects to uart_bt; module RXD to uart_bt_tx.
    parameter BT_ON = 0,
    //  2026-10-23: 滑音(portamento) 硬件开关, 见 synth_voice.v。
    //   1 = 每声部多一个 24bit 当前音高寄存器 + 指数逼近器 (约 80 LUT/声部),
    //       配合 UART 表情帧的 glide_sel 使用 (赛题「滑音」表情维度)
    //   0 = 不综合这部分 (扩 32 声部省资源用)
    parameter GLIDE = 1,
    // KEY_IN enables the local key synchronizers, debounce and events.
    // UART and test-sequencer events remain available when KEY_IN=0.
    // ACG525 communication through CH569 USB/HSPI is not implemented.
    parameter KEY_IN = 1,
    parameter DAC_SHIFT = 0,         // diagnostic headroom: final PCM only; 0 preserves output
    parameter REALISTIC_LITE = 0,
    //  2026-11-01: 引擎二选一。
    //   0 = synth_engine (加法合成, 4 音色, 每声部 ~1100 逻辑)
    //   1 = realistic_poly_ram (真实采样波表, 电钢/大提琴, 状态入 BSRAM,
    //       32 声部只要 3412 逻辑 / 12.5 DSP)
    parameter ENGINE_REAL = 0,
    //  2026-11-01: 1 = 上电就一直发 AT+BAUD8 (9600), 专门用来改 JDY-31 波特率,
    //   不依赖按键和复位时机。见 src/top_main_cfg.v
    parameter BT_CFG_ALWAYS = 0,
    //  2026-11-01: 1 = 蓝牙口跑波特率扫频器 (4.8k~115.2k 全试一轮),
    //   用来在不知道 JDY-31 出厂波特率的情况下一次命中。见 src/bt_sweep.v
    parameter BT_SWEEP = 0,
    //  2026-11-01: 1 = 只发可读 ASCII 的二选一探针 (9600 / 115200 各 3 秒)
    parameter BT_PROBE2 = 0,
    //  2026-11-02: 1 = 蓝牙口挂上"曲谱下发 + 脱机自动演奏" (赛题拓展④)。
    //   手机网页把曲谱文本 (S/K/P/X) 推给 60K, 之后手机可以断开,
    //   60K 自己按节拍弹完整首。见 src/bt_song.v
    //   代价: 2 块 BSRAM (128 音 x 7bit 音高 + 7bit 时值)。
    //    存储块必须无复位 + 同步读才推得出 BSRAM; 若写成带复位的
    //     异步读, 综合器会推成 1792 个触发器 (实测 Register 1197→3158,
    //     BSRAM 一块没多)。
    parameter BT_SONG = 0
)(
    input        key0   , //KEY0 AA13, 按下为低
    input        key1   , //KEY1 AB13
    input        key2   , //KEY2 Y12
    input        uart_rx, //UART RX (来自 BL616 USB-JTAG&UART, 见 .cst)
    input        uart_bt, //JDY-31 TXD -> B15
    output       uart_bt_tx, //JDY-31 RXD <- B16
    //audio接口
    output       HP_BCK   , //位时钟 ~1.59MHz
    output       HP_WS    , //左右声道切换
    output       HP_DIN   , //dac串行数据
    output       PA_EN    , //功放使能, 低有效
    output reg   [3:0] LEDs,   // 电平指示输出，物理映射见 CST
    output wire monitor_clk,monitor_reset_n,
    output wire [42:0] monitor_status,
    output wire  WS2812      // 板载 RGB 灯 (J16)
);

//  2026-10-22 定稿: 板载按键的变体默认值按音色走 ——
//   电钢 A Rhodes(0) / 贝斯 B3 音头颗粒(2) / 铺底 P3 大提琴(2) / 拨弦 V2(0)。
//   板载按键只有 3 个键, 不能分音色选变体, 所以按 KEY_WAVE 给一个定稿值;
//   网页则用"变体"下拉显式指定 (ev_ep 直接透传)。
//    必须是 localparam (而不是 wire): WS2812 的颜色表也是 localparam,
//     里面要引用这个值; wire 在 localparam 的常量上下文里是非法的
//     (ModelSim: "Parameter value must be constant")。
localparam [1:0] KEY_EP_V = (KEY_WAVE == 2'd2) ? 2'd2 :   // 贝斯 -> B3
                            (KEY_WAVE == 2'd3) ? 2'd2 :   // 铺底 -> P3
                            (KEY_WAVE == 2'd1) ? 2'd0 :   // 拨弦 -> V2
                                                 EP_SEL;  // 电钢 -> A

wire clk_w;        //内部OSC 52.5MHz
wire clk_6m_w;     //PLLA ~6.36MHz
wire clk_1p5m_w;   //CLKDIV /4 = 1.59MHz 位时钟
wire rst_n;        //上电复位
wire req_w;        //采样节拍(每16位时钟一次, 99.3kHz)

//---- 功放门控 (见文件末尾), 先声明信号 ----
reg [23:0] pa_hold;

//---- 内部振荡器: 210MHz/4 = 52.5MHz ----
Gowin_OSC osc_inst(
    .oscout(clk_w),
    .oscen (1'b1)
);

//---- PLLA: 52.5MHz -> ~6.36MHz ----
Gowin_PLL pll_52p5_to_6m(
    .clkout0(clk_6m_w),
    .clkin  (clk_w)
);

//---- CLKDIV: 6.36MHz/4 = 1.59MHz 位时钟 ----
Gowin_CLKDIV clk_div4(
    .clkout (clk_1p5m_w),
    .hclkin (clk_6m_w  ),
    .resetn (rst_n     )
);

//---- 上电复位: 52.5MHz 计数, 计满 2^17 后释放(≈2.5ms) ----
reg [16:0] rst_cnt;
initial rst_cnt = 17'd0;        // 仿真需要; 实机配置后寄存器本来就是 0
assign rst_n = rst_cnt[16];
always @(posedge clk_w) begin
    if (rst_cnt != 17'h1FFFF)
        rst_cnt <= rst_cnt + 1'b1;
end

//===============================================================
// 按键输入同步(2级) + 去抖
//    2026-10-27: 整段包进 generate, KEY_IN=0 时完全不综合。
//     双 FPGA 分工下 60K 只收 ACG525 的串口指令, 板载三个键不用,
//     省下 3×(2 级同步 2FF + 16bit 计数 + 边沿) ≈ 120 逻辑。
//===============================================================
wire k0_on, k0_off, k1_on, k1_off, k2_on, k2_off;
generate
if (KEY_IN != 0) begin : g_key
    reg [1:0] key0_sync, key1_sync, key2_sync;
    always @(posedge clk_1p5m_w or negedge rst_n) begin
        if (!rst_n) begin
            key0_sync <= 2'b11; key1_sync <= 2'b11; key2_sync <= 2'b11;
        end
        else begin
            key0_sync <= {key0_sync[0], key0};
            key1_sync <= {key1_sync[0], key1};
            key2_sync <= {key2_sync[0], key2};
        end
    end

//---- 按键消抖: 稳定 ~2ms (1.59MHz*3179) ----
//    2026-10-22: 原来 15999 (10.06ms) 正好踩在赛题「延迟 ≤10ms」的红线上,
//     光消抖就吃满整个预算。改成 3179 = 2.00ms, 留出 8ms 给别处。
//     消抖机制是「电平一直不变才计数」, 所以按键抖动期间计数器不断清零,
//     真正的总延迟 = 抖动持续时间 + 2ms, 机械按键抖动一般 <3ms, 仍然安全。
//     端到端延迟 = 2ms 消抖 + 0.6us 边沿 + 10.1us tick + 20.8us I2S 帧 ≈ 2.03ms。
reg [15:0] dly0, dly1, dly2;
reg key0_d, key1_d, key2_d;
always @(posedge clk_1p5m_w or negedge rst_n) begin
    if (!rst_n) begin
        dly0 <= 16'd0; dly1 <= 16'd0; dly2 <= 16'd0;
        key0_d <= 1'b1; key1_d <= 1'b1; key2_d <= 1'b1;
    end
    else begin
        if (key0_sync[1] != key0_d) begin
            if (dly0 == 16'd3179) begin key0_d <= key0_sync[1]; dly0 <= 16'd0; end
            else dly0 <= dly0 + 1'b1;
        end
        else dly0 <= 16'd0;
        if (key1_sync[1] != key1_d) begin
            if (dly1 == 16'd3179) begin key1_d <= key1_sync[1]; dly1 <= 16'd0; end
            else dly1 <= dly1 + 1'b1;
        end
        else dly1 <= 16'd0;
        if (key2_sync[1] != key2_d) begin
            if (dly2 == 16'd3179) begin key2_d <= key2_sync[1]; dly2 <= 16'd0; end
            else dly2 <= dly2 + 1'b1;
        end
        else dly2 <= 16'd0;
    end
end

    //---- 按键电平 -> 边沿事件 ----
    wire k0_down = ~key0_d;     // 按下=1
    wire k1_down = ~key1_d;
    wire k2_down = ~key2_d;

    reg k0_dd, k1_dd, k2_dd;
    always @(posedge clk_1p5m_w or negedge rst_n) begin
        if (!rst_n) begin k0_dd <= 1'b0; k1_dd <= 1'b0; k2_dd <= 1'b0; end
        else        begin k0_dd <= k0_down; k1_dd <= k1_down; k2_dd <= k2_down; end
    end

    assign k0_on  = k0_down & ~k0_dd;
    assign k0_off = ~k0_down & k0_dd;
    assign k1_on  = k1_down & ~k1_dd;
    assign k1_off = ~k1_down & k1_dd;
    assign k2_on  = k2_down & ~k2_dd;
    assign k2_off = ~k2_down & k2_dd;
end else begin : g_nokey
    // 不用板载按键: 三路事件恒 0, key0/1/2 输入被综合器丢弃
    assign k0_on  = 1'b0;
    assign k0_off = 1'b0;
    assign k1_on  = 1'b0;
    assign k1_off = 1'b0;
    assign k2_on  = 1'b0;
    assign k2_off = 1'b0;
end
endgenerate

//===============================================================
// UART 音符接收 (网页弹琴)
//===============================================================
wire        u_on, u_off;
wire [4:0]  u_note;
wire [7:0]  u_vel;
wire [1:0]  u_wav;
wire [1:0]  u_ep;
wire [1:0]  u_vib;
wire [1:0]  u_glide;
wire        u_fx_vld;
wire [7:0]  u_fx_note, u_fx_vel;
wire        u_tst;
wire        u_led;
wire [7:0]  u_fcnt;

//----  2026-11-01 双路 UART, 各自独立波特率 ----
//   起因: JDY-31 出厂就是 9600, 而且 AT 指令进不去 (模块欠压改不动),
//   只能让 FPGA 迁就。但 9600 下一个音符帧 4.17ms, 会把总延迟从 2.4ms
//   拉到 6.2ms, 丢掉赛题拓展③的 5ms 档。
//   做法: 不再用 uart_arb 去"复用一根线"(那样两路必须同波特率),
//   而是两路各一个 uart_rx, 各自按自己的波特率解帧, 在帧级合并:
//     - USB 路 (BL616, V14): CLK_PER_BIT=14  = 113.6kbaud, 帧 347us
//     - 蓝牙路 (JDY-31, B15): CLK_PER_BIT=166 = 9.6kbaud,   帧 4.17ms
//   两路同一拍都出事件的情形实际上不会发生 (音符合成事件是罕见的),
//   万一撞上的话蓝牙优先 (bt_act), 丢的是 USB 那一帧 —— 手弹会重按。
wire bt_act_b;
wire bt_rpt_tx, bt_rpt_active;
wire bt_song_active;
wire a_on, a_off;
wire [4:0] a_note;
wire [7:0] a_vel, a_fxnote, a_fxvel, a_fcnt;
wire [1:0] a_wav, a_ep, a_vib, a_glide;
wire a_fxv, a_tst, a_led;

uart_rx #(.CLK_PER_BIT(14)) u_uart_usb (
    .clk(clk_1p5m_w), .rst_n(rst_n), .tick(req_w), .rx(uart_rx),
    .note_on(a_on), .note_off(a_off), .note_idx(a_note),
    .velocity(a_vel), .wave_sel(a_wav), .ep_sel(a_ep), .vib_sel(a_vib),
    .glide_sel(a_glide),
    .fx_vld(a_fxv), .fx_note(a_fxnote), .fx_vel(a_fxvel),
    .tst_mode(a_tst),
    .rx_led(a_led), .frame_cnt(a_fcnt));

//===============================================================
//  2026-11-02 修隐藏 bug: MIDI 音符号 (60..84) -> note_table 索引 (0..24)
//
//   引擎吃的是 5bit 表索引, 不是 MIDI 号。src/uart_rx.v:194 一直在做这个
//   转换, 但文本通道 (bt_text) 和曲谱通道 (bt_song) 输出的是 MIDI,
//   之前 top.v 直接写 `{1'b0, t_note}` 赋给 5bit 索引 ——
//   MIDI 60 变成索引 28 (越界钳到 0 附近的错音), 只有极少数值碰巧对。
//   现在三条通道统一走这个函数。
//
//   为什么可以只减 28: 60..84 跨度 25 < 32, 5bit 模 32 算术刚好闭合。
//     MIDI 60 -> [4:0]=28, 28-28= 0 ✓
//     MIDI 64 -> [4:0]= 0,  0-28= 4 (mod 32) ✓
//     MIDI 84 -> [4:0]=20, 20-28=24 (mod 32) ✓
//===============================================================
function [4:0] midi2idx;
    input [6:0] m;
    begin
        midi2idx = (m < 7'd60) ? 5'd0 :
                   (m > 7'd84) ? 5'd24 :
                                 (m[4:0] - 5'd28);
    end
endfunction

generate
    if (BT_ON == 0) begin : g_bt_off
        assign bt_act_b    = 1'b0;
        assign bt_song_active = 1'b0;
        assign bt_rpt_tx   = 1'b1;
        assign bt_rpt_active = 1'b0;
        assign u_on        = a_on;
        assign u_off       = a_off;
        assign u_note      = a_note;
        assign u_vel       = a_vel;
        assign u_wav       = a_wav;
        assign u_ep        = a_ep;
        assign u_vib       = a_vib;
        assign u_glide     = a_glide;
        assign u_fx_vld    = a_fxv;
        assign u_fx_note   = a_fxnote;
        assign u_fx_vel    = a_fxvel;
        assign u_tst       = a_tst;
        assign u_led       = a_led;
        assign u_fcnt      = a_fcnt;
    end else begin : g_bt_on
        wire b_on, b_off;
        wire [4:0] b_note;
        wire [7:0] b_vel, b_fxnote, b_fxvel, b_fcnt;
        wire [1:0] b_wav, b_ep, b_vib, b_glide;
        wire b_fxv, b_tst, b_led;

        //  2026-11-01 最终结论 (扫频实测两回合):
        //   第 1 回合可读窗口在 9600 相位 => 出厂 9600, 且 AT+BAUD8 被接受;
        //   第 2 回合可读窗口移到 113.6k 相位 => 模块已经变成 115200。
        //   所以蓝牙这一路固定 113.6k (1.59MHz/14), 收发一致。
        uart_rx #(.CLK_PER_BIT(14)) u_uart_bt (    // JDY-31 已被 AT+BAUD8 改成 115200 (btprobe 实测 OK1152)
            .clk(clk_1p5m_w), .rst_n(rst_n), .tick(req_w), .rx(uart_bt),
            .note_on(b_on), .note_off(b_off), .note_idx(b_note),
            .velocity(b_vel), .wave_sel(b_wav), .ep_sel(b_ep), .vib_sel(b_vib),
            .glide_sel(b_glide),
            .fx_vld(b_fxv), .fx_note(b_fxnote), .fx_vel(b_fxvel),
            .tst_mode(b_tst),
            .rx_led(b_led), .frame_cnt(b_fcnt));

        //  文本命令通道 (2026-11-02): 手机上直接敲 "N60" / "O60" / "N60,240"
        wire t_on, t_off;
        wire [6:0] t_note;
        wire [7:0] t_vel;
        bt_text #(.CLK_PER_BIT(14)) u_bt_text (
            .clk(clk_1p5m_w), .rst_n(rst_n), .rx(uart_bt),
            .t_on(t_on), .t_off(t_off), .t_note(t_note), .t_vel(t_vel));

        //  曲谱下发 + 脱机自动演奏 (2026-11-02, 赛题拓展④)
        //   bt_song 与 bt_text 并联在同一根 uart_bt 上, 互不干扰:
        //   bt_text 只认 N/O 开头的行, bt_song 只认 S/K/P/X 开头的行。
        //   P/X 用文本命令, 所以手机点"播放"其实就是发一个 "P\n"。
        wire so_on, so_off;
        wire [6:0] so_note;
        wire [7:0] so_vel;
        wire so_playing, so_active;
        wire [7:0] so_ncount;

        if (BT_SONG == 0) begin : g_no_song
            assign so_on      = 1'b0;
            assign so_off     = 1'b0;
            assign so_note    = 7'd60;
            assign so_vel     = 8'd200;
            assign so_active  = 1'b0;
            assign so_playing = 1'b0;
        end else begin : g_song
            bt_song #(.CLK_PER_BIT(14), .TICK_HZ(99300), .MAX_NOTES(128))
            u_bt_song (
                .clk(clk_1p5m_w), .rst_n(rst_n), .rx(uart_bt),
                .play_btn(1'b0),           // 播放只走 "P" 命令, 板载键留给别的用途
                .s_on(so_on), .s_note(so_note), .s_vel(so_vel), .s_off(so_off),
                .playing(so_playing), .s_pos(), .active(so_active),
                .ncount(so_ncount));
        end

        // Legacy text/song has no timbre in its off command. Remember ownership
        // independently of per-event binary wave_sel and reconnect off sweeps.
        reg [1:0] legacy_wave, legacy_ep, legacy_vib;
        reg [24:0] text_cello;
        reg song_latched;
        reg [1:0] song_wave, song_ep, song_vib;
        wire [1:0] text_wave = t_on ? legacy_wave :
                              (text_cello[midi2idx(t_note)] ? 2'd3 : 2'd0);
        wire [1:0] song_event_wave = song_latched ? song_wave : legacy_wave;
        wire [1:0] song_event_ep = song_latched ? song_ep : legacy_ep;
        wire [1:0] song_event_vib = song_latched ? song_vib : legacy_vib;
        always @(posedge clk_1p5m_w or negedge rst_n) begin
            if(!rst_n) begin
                legacy_wave<=0;legacy_ep<=0;legacy_vib<=0;text_cello<=0;
                song_latched<=0;song_wave<=0;song_ep<=0;song_vib<=0;
            end else begin
                if(b_on && b_vel!=0) begin
                    legacy_wave<=b_wav;legacy_ep<=b_ep;legacy_vib<=b_vib;
                end
                if(t_on) text_cello[midi2idx(t_note)] <= (legacy_wave==3);
                if(!so_playing) song_latched<=0;
                else if(so_on && !song_latched) begin
                    song_latched<=1;song_wave<=legacy_wave;
                    song_ep<=legacy_ep;song_vib<=legacy_vib;
                end
            end
        end

        wire t_act_b  = t_on | t_off;
        wire so_act_b = so_on | so_off;
        assign bt_act_b = b_on | b_off | b_fxv | b_tst | t_act_b | so_act_b;
        // 收曲谱期间屏蔽心跳, 否则 13 字节的 E/O 回传会和心跳抢发送口
        assign bt_song_active = so_active | so_playing;

        assign u_on       = a_on  | b_on  | t_on  | so_on;
        assign u_off      = a_off | b_off | t_off | so_off;
        //  三条通道的输出都是 MIDI 号, 必须过 midi2idx 才是表索引
        assign u_note     = so_act_b ? midi2idx(so_note) :
                            t_act_b  ? midi2idx(t_note)  :
                            bt_act_b ? b_note            : a_note;
        assign u_vel      = so_act_b ? so_vel : (t_act_b ? t_vel : (bt_act_b ? b_vel : a_vel));
        assign u_wav      = so_act_b ? song_event_wave : (t_act_b ? text_wave : (bt_act_b ? b_wav : a_wav));
        assign u_ep       = so_act_b ? song_event_ep : (t_act_b ? legacy_ep : (bt_act_b ? b_ep : a_ep));
        assign u_vib      = so_act_b ? song_event_vib : (t_act_b ? legacy_vib : (bt_act_b ? b_vib : a_vib));
        assign u_glide    = bt_act_b ? b_glide : a_glide;
        assign u_fx_vld   = a_fxv | b_fxv;
        assign u_fx_note  = bt_act_b ? b_fxnote: a_fxnote;
        assign u_fx_vel   = bt_act_b ? b_fxvel : a_fxvel;
        assign u_tst      = a_tst | b_tst;
        assign u_led      = a_led | b_led;
        assign u_fcnt     = a_fcnt;

        //  演奏事件回传 (2026-11-02): 每个 note on/off 发一行可读文本
        //   格式 <E|O><nn>,<vvv>,<ddd>  例: E60,200,000
        //    u_note 是表索引 (0..24), 回传要给手机看 MIDI 号, 所以 +60 还原。
        bt_report #(.CLK_PER_BIT(14)) u_bt_rpt (
            .clk(clk_1p5m_w), .rst_n(rst_n), .tick(req_w),
            .fire(u_on | u_off), .is_on(u_on),
            .note({2'd0, u_note} + 8'd60), .vel(u_vel),
            .tx(bt_rpt_tx), .active(bt_rpt_active));
    end
endgenerate

//===============================================================
//  测试模式音序器 (运行期可切换, 2026-10-28 改)
//   赛题现场验证项: "支持测试模式下输出多路不同频率音频,
//   频谱可观测对应数量独立谱峰"。
//   做法: 进测试模式后每隔 32 个 clk_1p5m 周期触发一个声部, 音名依次 0,1,2,...
//     (音名必须互不相同, 否则引擎的"同音重用"会把它们合并到一个声部),
//     触发满 N_VOICES 个后永不松键 => N 个声部同时持续发声。
//   实际频率不来自 note_table: 引擎在测试模式下按声部索引查
//   1/6 倍频程频率表, 所以 8 声部 = 100Hz..1.7kHz 的 8 根谱线,
//   32 声部 = 100Hz..3.36kHz 的 32 根谱线, 每声部再带一个 x4.125 分音
//   => 64 根谱线。
//
//    2026-10-22 修 bug: 原来是「每 4 个 clk_1p5m 周期一个」= 2.52us,
//     而引擎每 tick(10.07us) 只认一个 ev_on —— 4 个脉冲挤进一个 tick 里,
//     只有最后一个的 ev_note 存活, 实际只起振 8/4 = 2 个声部。
//     改成 32 个周期 (20.1us = 2 个 tick), 留一个完整 tick 的余量。
//    2026-10-28: 从 generate(TEST_MODE) 改成 always + 运行期 tst 门控。
//     tst 由 UART 控制帧切换 (见 uart_rx), 所以现场验谱峰不用重烧固件。
//     代价: 音序器逻辑永远存在 (约 30 LUT), 换掉的是"要重烧一次板子"。
//===============================================================
wire        t_on, t_off;
wire [4:0]  t_note;
wire        tst_all = (TEST_MODE != 0) || u_tst;   // 编译期或运行期, 二者取或

reg [4:0] tdiv2;
reg [5:0] tvoice;
reg       ton_r;
reg [4:0] tnote_r;
always @(posedge clk_1p5m_w or negedge rst_n) begin
    if (!rst_n) begin
        tdiv2 <= 5'd0; tvoice <= 6'd0;
        ton_r <= 1'b0; tnote_r <= 5'd0;
    end else begin
        ton_r <= 1'b0;
        if (!tst_all) begin
            // 退出测试模式: 音序器复位, 下次进来从头触发
            tdiv2 <= 5'd0; tvoice <= 6'd0;
        end
        else if (tvoice < N_VOICES) begin
            if (tdiv2 == 5'd31) begin
                tdiv2   <= 5'd0;
                ton_r   <= 1'b1;
                tnote_r <= tvoice[4:0];
                tvoice  <= tvoice + 6'd1;
            end else
                tdiv2 <= tdiv2 + 5'd1;
        end
    end
end
assign t_on   = ton_r;
assign t_off  = 1'b0;
assign t_note = tnote_r;

//===============================================================
// 输入仲裁 (测试 > UART > key2 > key1 > key0)
//   按键映射依据 Sipeed 官方 pmod_led demo (同款 Dock 板):
//     key0 = AA13, key1 = AB13, key2 = Y12
//===============================================================
wire        ev_on  = u_on  | k2_on  | k1_on  | k0_on | t_on;
wire        ev_off = u_off | k2_off | k1_off | k0_off | t_off;

wire        uart_act = u_on | u_off;
wire        test_act = t_on | t_off;
wire        k2_act   = k2_on | k2_off;
wire        k1_act   = k1_on | k1_off;

//  2026-10-19: 回退到 25 音表, 索引 0..24 = C4..C6。
//   所以 C4=0, E4=4, G4=7 (与 61 音表的 24/28/31 不同)。
wire [4:0]  ev_note = test_act ? t_note :
                      uart_act ? u_note :
                      k2_act   ? 5'd7  :      // G4 (Sol, MIDI 67)
                      k1_act   ? 5'd4  :      // E4 (Mi,  MIDI 64)
                                 5'd0;        // C4 (Do,  MIDI 60)
wire [7:0]  ev_vel  = test_act ? 8'd255 : (uart_act ? u_vel : 8'd200);
// 音色选择: 网页/UART 发来的 wave_sel 直接透传
//   0=电钢(A/B/C 由 cmd[3:2] 选) 1=拨弦 2=贝斯 3=铺底
//   板载按键没有音色选择, 用参数 KEY_WAVE 决定 (默认电钢, 方便上板试听)
wire [1:0]  ev_wav  = uart_act ? u_wav : KEY_WAVE;
//  2026-10-22 定稿: 板载按键的变体默认值按音色走 ——
//   电钢 A Rhodes(0) / 贝斯 B3 音头颗粒(2) / 铺底 P3 大提琴(2) / 拨弦 V2(0)。
//   板载按键只有 3 个键, 不能分音色选变体, 所以按 KEY_WAVE 给一个定稿值;
//   网页则用"变体"下拉显式指定 (ev_ep 直接透传)。
//  2026-10-22 定稿: 板载按键的变体默认值见模块头的 KEY_EP_V localparam。
wire [1:0]  key_ep  = KEY_EP_V;
wire [1:0]  ev_ep   = test_act ? 2'd0 : (uart_act ? u_ep : key_ep);
//  颤音: 只有 UART 能给 (板载三个键没有第四维输入), 按键时固定关。
wire [1:0]  ev_vib  = test_act ? 2'd0 : (uart_act ? u_vib : 2'd0);
//  滑音同理: 按键时固定关 (三个键就是三个固定音高, 没有"上一个音"的概念)。
wire [1:0]  ev_glide = test_act ? 2'd0 : (uart_act ? u_glide : 2'd0);

// audio_clk is a related /4 clock. Its rising-edge event/data outputs are
// sampled on the falling edge of the engine clock, leaving half a cycle
// before synth_engine consumes the complete bundle on the next rising edge.
reg eng_on, eng_off, eng_req;
reg [4:0] eng_note;
reg [7:0] eng_vel;
reg [1:0] eng_wav, eng_ep;
reg [1:0] eng_vib;
reg [1:0] eng_glide;
reg       eng_tst;
always @(negedge clk_6m_w or negedge rst_n) begin
    if (!rst_n) begin
        eng_on <= 1'b0; eng_off <= 1'b0; eng_req <= 1'b0;
        eng_note <= 5'd0; eng_vel <= 8'd0;
        eng_wav <= KEY_WAVE; eng_ep <= EP_SEL; eng_vib <= 2'd0;
        eng_glide <= 2'd0;
        eng_tst <= (TEST_MODE != 0);
    end else begin
        eng_on <= ev_on; eng_off <= ev_off;
        // The /4-domain request needs the same half-cycle handoff as events.
        // Direct req -> rising-edge tick_d had a routed hold violation.
        eng_req <= req_w;
        //  测试模式开关也走同一个半周期交接 (跨 clk_1p5m -> clk_6m 域)
        eng_tst <= tst_all;
        // Keep the payload after its short event pulse. In particular ep_sel
        // is read while the engine's pending event waits for an audio tick.
        if (ev_on || ev_off) begin
            eng_note <= ev_note; eng_vel <= ev_vel;
            eng_wav <= ev_wav; eng_ep <= ev_ep; eng_vib <= ev_vib;
            eng_glide <= ev_glide;
        end
    end
end

//===============================================================
// 合成引擎 (二选一, 由 ENGINE_REAL 决定)
//
//   ENGINE_REAL=0: synth_engine —— 加法/波表合成的 4 音色引擎
//   ENGINE_REAL=1: realistic_poly_ram —— 真实采样波表引擎, 声部状态存
//                  BSRAM, 单份 datapath 扫过, 32 声部只要 6% 逻辑
//
//   两个模块的端口逐条对应 (clk/rst_n/tick/note_on/note_off/note_idx/
//   velocity/wave_sel/ep_sel/vib_sel/glide_sel/tst_mode ->
//   out_l/out_r/n_active/ph0_dbg), 所以下半部分的 FX/DAC/LED 全部不用改。
//===============================================================
wire signed [15:0] hp_l, hp_r;
wire [5:0]  n_active;
wire [23:0] ph0_dbg;

generate
if (ENGINE_REAL == 0) begin : g_eng_syn

synth_engine #(
    .N_V(N_VOICES),
    // 钢琴包络: 快击弦(K_A=7, ~6ms) + 持续衰减(K_D=15, tau≈330ms) + 快速制音(K_R=11, ~95ms)
    //   SUS_LVL 低(8000) -> 按住时持续衰减而不是平顶, 更像真实钢琴
    .K_A(5'd7),  .K_D(5'd15), .K_R(5'd11),
    .SUS_LVL(16'd8000), .ATT_LVL(16'd65535),
    .MASTER(8'd40),
    .PLUCK_SEL(PLUCK_SEL),
    .UNISON(UNISON),
    .GLIDE(GLIDE),
    .TEST_MODE(TEST_MODE),
    .REALISTIC_LITE(REALISTIC_LITE)
) u_eng (
    .clk   (clk_6m_w),      // 加法分音引擎跑 6.36MHz: 每 tick 64 个时隙
    .rst_n (rst_n),
    .tick  (eng_req),
    .note_on (eng_on),
    .note_off(eng_off),
    .note_idx(eng_note),
    .velocity(eng_vel),
    .wave_sel(eng_wav),
    .ep_sel  (eng_ep),
    .vib_sel (eng_vib),
    .glide_sel(eng_glide),
    .tst_mode (eng_tst),
    .out_l (hp_l),
    .out_r (hp_r),
    .n_active(n_active),
    .ph0_dbg(ph0_dbg)
);

end else begin : g_eng_real

// N_VOICES 上限 32: 每个采样 64 个时钟, 每声部每采样 2 次波表读, 两个读口
// 各分一半 => 32 声部正好用满 (2*32 = 64 次读 / 64 时钟)。
realistic_poly_adapter #(
    .N(N_VOICES),
    .VW(5),
    .USE_RAM(1)
) u_eng (
    .clk   (clk_6m_w),
    .rst_n (rst_n),
    .tick  (eng_req),
    .note_on (eng_on),
    .note_off(eng_off),
    .note_idx(eng_note),
    .velocity(eng_vel),
    .wave_sel(eng_wav),
    .ep_sel  (eng_ep),
    .vib_sel (eng_vib),
    .glide_sel(eng_glide),
    .tst_mode (eng_tst),
    .out_l (hp_l),
    .out_r (hp_r),
    .n_active(n_active),
    .ph0_dbg(ph0_dbg)
);

end
endgenerate

//===============================================================
//  2026-10-23 硬件效果器 (赛题拓展第 2 条: 混响 / 延迟 / 合唱)
//
//   接在引擎输出之后、DAC 之前。FX_ON=0 时整个模块被优化掉。
//   控制量来自 UART 控制帧 (cmd[6]=1):
//     note 字节 = fx_sel[1:0] | mix_sel[3:2] | rev_size[5:4]
//     vel  字节 = 延迟长度, 单位 0.65ms (0..255 -> 0..165ms)
//===============================================================
// 引擎的 tick1 (单拍脉冲) 在 top 里复现一份, 给效果器用
reg eng_req_d;
always @(posedge clk_6m_w or negedge rst_n) begin
    if (!rst_n) eng_req_d <= 1'b0;
    else        eng_req_d <= eng_req;
end
wire eng_tick1 = eng_req & ~eng_req_d;

reg [1:0]  fx_sel, fx_mix, fx_rev;
reg [13:0] fx_dly;
//  2026-10-24 修 bug: 原来是 `fx_dly <= {6'd0,u_fx_vel} * 14'd65;`
//   255*65 = 16575 > 16383 (14bit 上限), 也 > fx_delay 的 MAXL(16384)
//   -> 高位被截掉, 滑块拉到底反而变成 16575-16384 = 191 样本 = 1.9ms,
//   听感是"梳状滤波"而不是回声。现在用 22bit 中间量再钳到 16383。
localparam [13:0] DLY_MAX = 14'd16383;      // = fx_delay MAXL-1
// 8bit x 常数 65 -> 15bit 足够 (255*65 = 16575 < 32768), 乘法器比 22bit 小
wire [14:0] fx_dly_raw = u_fx_vel * 15'd65;
always @(posedge clk_1p5m_w or negedge rst_n) begin
    if (!rst_n) begin
        fx_sel <= 2'd0; fx_mix <= 2'd2; fx_rev <= 2'd1; fx_dly <= 14'd5960;
    end
    else if (u_fx_vld) begin
        fx_sel <= u_fx_note[1:0];
        fx_mix <= u_fx_note[3:2];
        fx_rev <= u_fx_note[5:4];
        // 延迟长度: 0 -> 直接用默认 60ms; 否则 1..255 映射到 0.65..166ms (钳位)
        fx_dly <= (u_fx_vel == 8'd0) ? 14'd5960 :
                  (fx_dly_raw > {1'b0, DLY_MAX}) ? DLY_MAX : fx_dly_raw[13:0];
    end
end

reg [1:0] hdmi_fx_sel,hdmi_fx_mix,hdmi_fx_rev;
reg [13:0] hdmi_fx_dly;
always @(negedge clk_6m_w or negedge rst_n)
 if(!rst_n)begin hdmi_fx_sel<=0;hdmi_fx_mix<=2;hdmi_fx_rev<=1;hdmi_fx_dly<=5960;end
 else begin hdmi_fx_sel<=fx_sel;hdmi_fx_mix<=fx_mix;hdmi_fx_rev<=fx_rev;hdmi_fx_dly<=fx_dly;end

wire signed [15:0] fx_l, fx_r;

generate
    if (FX_ON == 0) begin : g_fx_off
        assign fx_l = hp_l;
        assign fx_r = hp_r;
    end
    else begin : g_fx_on
        fx_engine #(.FX_ON(1)) u_fx (
            .clk     (clk_6m_w),
            .rst_n   (rst_n),
            .tick1   (eng_tick1),
            .fx_sel  (hdmi_fx_sel),
            .rev_size(hdmi_fx_rev),
            .dly_len (hdmi_fx_dly),
            .mix_sel (hdmi_fx_mix),
            .x       (hp_l),
            .y       (fx_l)
        );
        // 右声道直通 (引擎左右本来就相同, 效果器只做一路, 省一半 BSRAM)
        assign fx_r = fx_l;
    end
endgenerate

//===============================================================
// 功放使能 PA_EN (0=开, 1=关)
//
// PA_GATE=0 holds the amplifier enabled to avoid note-triggered switching.
// PA_GATE=1 enables it while voices are active and for 200 ms afterward.
// The gated option is retained for comparison.
//===============================================================
generate
    if (PA_GATE == 0) begin : g_pa_always
        // 常开: 不给 pa_hold 综合任何逻辑, 避免无用的 24bit 计数器
        assign PA_EN = 1'b0;
    end else begin : g_pa_gated
        always @(posedge clk_1p5m_w or negedge rst_n) begin
            if (!rst_n)                pa_hold <= 24'd0;
            else if (n_active != 6'd0) pa_hold <= 24'd318000;  // 200ms @1.59MHz
            else if (pa_hold != 24'd0) pa_hold <= pa_hold - 24'd1;
        end
        assign PA_EN = (pa_hold != 24'd0) ? 1'b0 : 1'b1;
    end
endgenerate

//===============================================================
// I2S 音频驱动(立体声)
//
//  2026-10-20: PT8211-S 实际是 LSBJ (Japanese format), 不是 Philips I2S。
//   旧 audio_drive 把 DIN 和 BCK 放在同一个上升沿翻转, DAC 采样到的是
//   翻转前的旧值 -> 每个样本整体右移 1 位(幅度减半 -6dB) + 左右声道互换。
//   旧版接口逐位对照记录:
//       送入 L=0x1801 R=0x68fd -> Philips 版 DAC 收到 L=0x347e R=0x8c00
//   audio_drive_lsbj 把 DIN/WS 改到 BCK 下降沿更新, 逐位精确。
//   USE_LSBJ=0 可一键回退到旧时序做对照(不推荐上板)。
//===============================================================
// The DAC and HDMI share these real, audible stereo samples.
wire signed [15:0] stereo_l,stereo_r;
stereo_phase u_stereo(clk_6m_w,rst_n,eng_tick1,fx_l,stereo_l,stereo_r);
wire signed [15:0] dac_l = stereo_l >>> DAC_SHIFT;
wire signed [15:0] dac_r = stereo_r >>> DAC_SHIFT;

generate
    if (USE_LSBJ) begin : g_tx_lsbj
        audio_drive_lsbj u_audio_drive_0(
            .clk_1p536m(clk_1p5m_w),
            .rst_n     (rst_n),
            .idata_l   (dac_l),
            .idata_r   (dac_r),
            .req       (req_w),
            .HP_BCK    (HP_BCK),
            .HP_WS     (HP_WS),
            .HP_DIN    (HP_DIN)
        );
    end
    else begin : g_tx_phil
        audio_drive u_audio_drive_0(
            .clk_1p536m(clk_1p5m_w),
            .rst_n     (rst_n),
            .idata_l   (dac_l),
            .idata_r   (dac_r),
            .req       (req_w),
            .HP_BCK    (HP_BCK),
            .HP_WS     (HP_WS),
            .HP_DIN    (HP_DIN)
        );
    end
endgenerate

//===============================================================
// LED 指示
//   有 UART 数据 -> 常亮; 否则按 0.5s 闪烁(心跳)
//===============================================================
reg [24:0] counter;
always @(posedge clk_w or negedge rst_n) begin
    if (!rst_n) counter <= 25'd0;
    else if (counter < 25'd2624_9999) counter <= counter + 1'b1;
    else counter <= 25'd0;
end

reg hb;
always @(posedge clk_w or negedge rst_n) begin
    if (!rst_n) hb <= 1'b1;
    else if (counter == 25'd2624_9999) hb <= ~hb;
end

//---------------------------------------------------------------
// 输出指示
// LEDs[3:0] provide level indicators; physical pins are listed in the CST.
// WS2812 provides the onboard color indication.
//---------------------------------------------------------------

//---- 音频电平表 (取 hp_l 的绝对值, 峰值保持 + 缓慢回落) ----
wire [15:0] hl  = hp_l;
wire [15:0] mag = hl[15] ? (~hl + 16'd1) : hl;

reg [15:0] div_l;
reg [15:0] pk;
always @(posedge clk_w or negedge rst_n) begin
    if (!rst_n) begin div_l <= 16'd0; pk <= 16'd0; end
    else begin
        div_l <= div_l + 1'b1;
        if (div_l == 16'd0) begin                 // 每 65536 clk ≈ 1.25ms
            if (mag > pk) pk <= mag;
            else          pk <= pk - (pk >> 3);   // 缓慢回落
        end
    end
end

wire [3:0] bar = { (pk > 16'd4200), (pk > 16'd2500),
                   (pk > 16'd1200), (pk > 16'd300) };

always @(posedge clk_w or negedge rst_n) begin
    if (!rst_n) LEDs <= 4'h0;
    else        LEDs <= bar;
end

//---- 板载 WS2812 (J16): 800kHz 单线, 24bit GRB, 0.5s 慢闪 ----
//    2026-10-22 定稿: 闪烁颜色 = 当前固件的音色方案, 上板一眼就知道烧的是哪版。
//     测试模式 = 白色快闪(见下面 ws_tmr 分支)
//     电钢 A Rhodes = 绿   B = 蓝   C = 紫红
//     拨弦 V1 = 白   V2 = 橙   V3 = 青
//     贝斯 B1/B2/B3 = 暗红/暗黄/暗橙
//     铺底 P1/P2/P3 = 暗蓝/暗紫/暗青
//     亮度都压低, 免得刺眼。
//     注意 WS2812 是 GRB 顺序: 24'hGGRRBB
localparam [23:0] WS_OFF = 24'h000000;
localparam [23:0] WS_ON  = (TEST_MODE != 0)        ? 24'h202020 :          // 测试模式: 白
                           (KEY_WAVE == 2'd0) ?                          // 电钢: 按候选
                           ((EP_SEL   == 2'd0) ? 24'h180000 :            // 绿 = A Rhodes
                            (EP_SEL   == 2'd1) ? 24'h00001A :            // 蓝 = B Wurlitzer
                                                 24'h001818) :           // 紫红 = C DX7
                           (KEY_WAVE == 2'd1) ?                          // 拨弦: 按变体
                           ((PLUCK_SEL == 2'd0) ? 24'h181818 :           // 白 = V1 现有
                            (PLUCK_SEL == 2'd1) ? 24'h181000 :           // 橙 = V2 明亮(定稿)
                                                  24'h180018) :          // 青 = V3 柔和
                           (KEY_WAVE == 2'd2) ?                          // 贝斯: 按变体
                           ((KEY_EP_V  == 2'd0) ? 24'h001800 :           // 暗红 = B1
                            (KEY_EP_V  == 2'd1) ? 24'h181800 :           // 暗黄 = B2
                                                  24'h181000) :          // 暗橙 = B3(定稿)
                           (KEY_WAVE == 2'd3) ?                          // 铺底: 按变体
                           ((KEY_EP_V  == 2'd0) ? 24'h000018 :           // 暗蓝 = P1
                            (KEY_EP_V  == 2'd1) ? 24'h100018 :           // 暗紫 = P2
                                                  24'h001818) :          // 暗青 = P3(定稿)
                                                24'h101010;              // 兜底: 白

// 闪烁周期: 正常 0.5s, 测试模式 0.1s (快闪一眼区分)
localparam [24:0] WS_HALF = (TEST_MODE != 0) ? 25'd2624999 : 25'd26249999;

reg [24:0] ws_tmr;                          // 0.5s @ 52.5MHz = 26250000
reg        ws_lit;
reg [23:0] ws_word;
always @(posedge clk_w or negedge rst_n) begin
    if (!rst_n) begin
        ws_tmr <= 25'd0; ws_lit <= 1'b1; ws_word <= WS_ON;
    end
    else begin
        if (ws_tmr == WS_HALF) begin
            ws_tmr <= 25'd0;
            ws_lit <= ~ws_lit;
        end
        else ws_tmr <= ws_tmr + 1'b1;
        ws_word <= ws_lit ? WS_OFF : WS_ON;
    end
end

reg [6:0]  ws_ph;                           // 位内相位 0..65 (1.25us)
reg [4:0]  ws_bit;                          // 0..23
reg [23:0] ws_sr;
reg        ws_o;
reg [15:0] ws_gap;

always @(posedge clk_w or negedge rst_n) begin
    if (!rst_n) begin
        ws_ph <= 7'd0; ws_bit <= 5'd0; ws_sr <= WS_ON; ws_o <= 1'b0; ws_gap <= 16'd0;
    end
    else if (ws_gap != 16'd0) begin
        ws_gap <= ws_gap - 1'b1;
        ws_o   <= 1'b0;
    end
    else if (ws_ph == 7'd65) begin
        ws_ph  <= 7'd0;
        ws_sr  <= {ws_sr[22:0], 1'b0};
        if (ws_bit == 5'd23) begin
            ws_bit <= 5'd0;
            ws_sr  <= ws_word;              // 装下一帧
            ws_gap <= 16'd40000;            // ~760us 复位间隔
        end
        else ws_bit <= ws_bit + 1'b1;
    end
    else begin
        ws_ph <= ws_ph + 1'b1;
        ws_o  <= (ws_ph < (ws_sr[23] ? 7'd42 : 7'd21));   // T1H=0.8us / T0H=0.4us
    end
end

assign WS2812 = ws_o;

//======================================================================
// 蓝牙双向 + 波特率配置模式  (2026-11-01 新增)
//
//   常规模式: 每 100 ms 从 uart_bt_tx 发 [0xA5][0x55][计数] @113.6kbaud,
//             用来验证 60K -> JDY-31 这条发送链路。
//   配置模式: 上电/复位时若按住 key2 (Y12), 先用 9600 连发 10 次
//             "AT+BAUD8\r\n", 把 JDY-31 从出厂 9600 改成 115200。
//              为什么必须由 FPGA 发: JDY-31 的 AT 指令只从它的 RXD 引脚
//               (uart_bt_tx) 接受, 而且已连接(透传)状态下完全不解析 AT。
//             9600 分频 = 1.59MHz/9600 = 165.6 -> 166 (误差 +0.24%)
//======================================================================
    localparam integer CFG_DIV = 166;

    wire        tx_send;
    wire [7:0]  tx_byte;
    wire        hb_tx, hb_busy;
    wire        cfg_tx, cfg_busy_w;

    reg  [23:0] hb_cnt;
    reg  [1:0]  hb_idx;
    reg  [7:0]  hb_seq;

    reg         cfg_lat;      // 已采样到"要不要进配置模式"
    reg  [15:0] pwr_wait;     // 上电 20ms 后才采 key2
    reg  [15:0] slot;         // 15ms 字节节拍
    reg  [3:0]  cfg_idx;      // 0..9 字符下标
    reg  [3:0]  cfg_rep;      // 0..10 重复次数
    reg         cfg_done;

    wire cfg_active = BT_CFG_ALWAYS | (cfg_lat && !cfg_done);
    wire slot_tick  = (slot == 16'd23899);

    function [7:0] cfg_char;
        input [3:0] i;
        begin
            case (i)
                4'd0: cfg_char = 8'h41;  // 'A'
                4'd1: cfg_char = 8'h54;  // 'T'
                4'd2: cfg_char = 8'h2B;  // '+'
                4'd3: cfg_char = 8'h42;  // 'B'
                4'd4: cfg_char = 8'h41;  // 'A'
                4'd5: cfg_char = 8'h55;  // 'U'
                4'd6: cfg_char = 8'h44;  // 'D'
                4'd7: cfg_char = 8'h38;  // '8'
                4'd8: cfg_char = 8'h0D;  // CR
                default: cfg_char = 8'h0A; // LF
            endcase
        end
    endfunction

    //  同上: 心跳与模块同为 113.6k
    uart_tx #(.CLK_PER_BIT(14)) u_bt_tx (           // 与 u_uart_bt 同一个 113.6k
        .clk(clk_1p5m_w), .rst_n(rst_n), .tick(1'b1),
        .send(tx_send), .byte_in(tx_byte),
        .tx(hb_tx), .busy(hb_busy));

    uart_tx #(.CLK_PER_BIT(CFG_DIV)) u_bt_tx_cfg (
        .clk(clk_1p5m_w), .rst_n(rst_n), .tick(1'b1),
        .send(cfg_send), .byte_in(cfg_char(cfg_idx)),
        .tx(cfg_tx), .busy(cfg_busy_w));

    wire sweep_tx;
    generate
        if (BT_SWEEP == 0) begin : g_no_sweep
            assign sweep_tx = 1'b1;      // 空闲高
        end else begin : g_sweep
            if (BT_PROBE2 == 0) begin : g_sw
                bt_sweep u_sweep (.clk(clk_1p5m_w), .rst_n(rst_n), .tx(sweep_tx));
            end else begin : g_pr
                bt_probe2 u_probe (.clk(clk_1p5m_w), .rst_n(rst_n), .tx(sweep_tx));
            end
        end
    endgenerate
    // 优先级: 事件回传 > 波特率配置 > 扫描探针 > 心跳
    assign uart_bt_tx = bt_rpt_active ? bt_rpt_tx
                      : BT_SWEEP      ? sweep_tx
                      : cfg_active    ? cfg_tx
                      :                 hb_tx;

    // ---- 心跳帧 (常规模式) --------------------------------------------
    always @(posedge clk_1p5m_w or negedge rst_n) begin
        if (!rst_n) begin
            hb_cnt <= 24'd0; hb_idx <= 2'd0; hb_seq <= 8'd0;
        end else if (cfg_active) begin
            hb_cnt <= 24'd0; hb_idx <= 2'd0;
        end else begin
            if (hb_idx == 2'd0) begin
                if (hb_cnt == 24'd158_000) hb_cnt <= 24'd0;
                else                       hb_cnt <= hb_cnt + 1'b1;
                if (hb_cnt == 24'd158_000) hb_idx <= 2'd1;
            end else if (!hb_busy) begin
                if (hb_idx == 2'd3) begin hb_idx <= 2'd0; hb_seq <= hb_seq + 1'b1; end
                else                 hb_idx <= hb_idx + 1'b1;
            end
        end
    end

    //  2026-11-02: 收曲谱 / 播放曲谱期间停心跳。
    //   心跳和事件回传共用 uart_bt_tx 这根线 (上面那个优先级 MUX),
    //   如果心跳正在发 "A5 55 xx" 时回传突然插进来, 会把半个字节撕开,
    //   手机端两个方向都解不出来。曲子播放时每个音都要回传, 心跳必须让路。
    assign tx_send = (hb_idx != 2'd0) && !hb_busy && !cfg_active && !bt_song_active;
    assign tx_byte = (hb_idx == 2'd1) ? 8'hA5 :
                     (hb_idx == 2'd2) ? 8'h55 : hb_seq;

    // ---- 配置模式: key2 采样 + 15ms 节拍发串 --------------------------
    always @(posedge clk_1p5m_w or negedge rst_n) begin
        if (!rst_n) begin
            cfg_lat <= 1'b0; cfg_done <= 1'b0; pwr_wait <= 16'd0;
            slot <= 16'd0; cfg_idx <= 4'd0; cfg_rep <= 4'd0;
        end else begin
            if (!cfg_lat) begin
                if (pwr_wait != 16'd31999) pwr_wait <= pwr_wait + 1'b1;
                else begin
                    cfg_lat  <= 1'b1;
                    // key2 按下为低 -> cfg_done=0 -> cfg_active=1 进配置模式;
                    // 未按下为高 -> cfg_done=1 -> 常规模式
                    cfg_done <= key2;
                end
            end
            if (slot == 16'd23899) slot <= 16'd0;
            else                   slot <= slot + 1'b1;

            if (cfg_active) begin
                if (slot_tick && !cfg_busy_w) begin
                    if (cfg_idx == 4'd9) begin
                        cfg_idx <= 4'd0;
                        if (cfg_rep == 4'd9 && !BT_CFG_ALWAYS) cfg_done <= 1'b1;
                        else                 cfg_rep <= cfg_rep + 1'b1;
                    end else cfg_idx <= cfg_idx + 1'b1;
                end
            end
        end
    end

    assign cfg_send = cfg_active && slot_tick && !cfg_busy_w;

// Passive display status. No input into the musical event path.
reg [24:0] monitor_keys;
reg [1:0] monitor_wave;
reg [7:0] monitor_velocity;
always @(posedge clk_1p5m_w or negedge rst_n) begin
  if(!rst_n)begin monitor_keys<=0;monitor_wave<=0;monitor_velocity<=0;end
  else begin
    if(ev_on && ev_vel!=0 && ev_note<25)begin
      monitor_keys[ev_note]<=1;monitor_wave<=ev_wav;monitor_velocity<=ev_vel;
    end else if((ev_off || (ev_on && ev_vel==0)) && ev_note<25) monitor_keys[ev_note]<=0;
  end
end
assign monitor_clk=clk_1p5m_w;
assign monitor_reset_n=rst_n;
assign monitor_status={fx_sel,monitor_velocity,monitor_wave,n_active,monitor_keys};


endmodule
