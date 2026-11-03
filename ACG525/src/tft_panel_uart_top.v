//////////////////////////////////////////////////////////////////////////////////
// Company      : 基于武汉芯路恒 ACG525 例程 + 2026 嵌赛选题二改造
// Module Name  : tft_panel_uart_top
// Description  : ACG525 演奏交互前端
//
//   屏幕(480x272) 触摸钢琴/参数按钮
//        │  XPT2046 SPI -> 坐标 -> touch_panel 语义解析
//        ▼
//   frame_pack 打包 [0xA5][cmd][note][vel] 115200 8N1
//        │
//        ▼
//   UART_TX(FPGA V8) ──> 对端 Mega 60K 的 uart_rx -> 合成引擎
//
//   人机维度：音高(按键) + 力度(纵向位置) + 音色 + 电钢候选 + 颤音
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps

module tft_panel_uart_top(
    input  wire        clk50M,
    input  wire        reset_n,

    //--- TFT ---
    output wire [15:0] TFT_rgb,
    output wire        TFT_hs,
    output wire        TFT_vs,
    output wire        TFT_clk,
    output wire        TFT_de,
    output wire        TFT_pwm,

    //--- 触摸 (XPT2046) ---
    output wire        T_CS,
    output wire        T_CLK,
    output wire        T_DIN,
    input  wire        T_DOUT,
    input  wire        T_IRQ,

    //--- 串口到 Mega 60K ---
    output wire        UART_TX,

    //--- 12 键 CdS 矩阵琴键 (v10: 4 行 one-hot Hi-Z x 3 列数字输入) ---
    inout  wire [3:0]  KEYPAD_ROW, // D17/D18/E16/F14: 行驱动 (选中 3.3V, 未选 Hi-Z)
    input  wire [2:0]  KEYPAD_COL, // F17/G14/G16: 列输入 (47k 下拉, 1=松开)

    //--- APDS-9960 手势 (I2C @ C17/C18, 与琴键引脚重排腾出) ---
    inout  wire        APDS_SCL,   // C17: I2C SCL
    inout  wire        APDS_SDA,   // C18: I2C SDA (模块板载 4.7k 上拉须使能)

    //--- 琴键底部照明 (琴键 CdS 依赖照明常开) ---
    output wire        LAMP        // C15: 照明 LED 开关
);

    wire reset = ~reset_n;

    //==============================================================
    // 时钟
    //==============================================================
    wire pll_locked;
    wire clk_ctrl;
    wire tft_reset_p;

    assign tft_reset_p = ~pll_locked;
    wire   rst_n       = reset_n & pll_locked;

    Gowin_PLL Gowin_PLL(
        .lock   (pll_locked),
        .clkout0(clk_ctrl),
        .clkin  (clk50M),
        .reset  (reset)
    );

    //==============================================================
    // 显示时序
    //==============================================================
    wire [11:0] h_addr;
    wire [11:0] v_addr;
    wire        disp_req;
    wire [15:0] ui_rgb;
    wire [4:0]  Disp_Red;
    wire [5:0]  Disp_Green;
    wire [4:0]  Disp_Blue;
    wire        Disp_PCLK;

    disp_driver disp_driver(
        .ClkDisp     (clk_ctrl),
        .Rst_p       (tft_reset_p),
        .Data        (ui_rgb),
        .DataReq     (disp_req),
        .H_Addr      (h_addr),
        .V_Addr      (v_addr),
        .Disp_HS     (TFT_hs),
        .Disp_VS     (TFT_vs),
        .Disp_Red    (Disp_Red),
        .Disp_Green  (Disp_Green),
        .Disp_Blue   (Disp_Blue),
        .Frame_Begin (),
        .Disp_DE     (TFT_de),
        .Disp_PCLK   (Disp_PCLK)
    );

    assign TFT_rgb = {Disp_Red, Disp_Green, Disp_Blue};
    assign TFT_clk = Disp_PCLK;
    assign TFT_pwm = 1'b1;

    //==============================================================
    // 触摸采样
    //==============================================================
    wire [7:0]  adc_cmd;
    wire        adc_start;
    wire [11:0] adc_data;
    wire        adc_done;
    wire [11:0] raw_z1;
    wire        new_touch;
    wire [9:0]  pos_x, pos_y;
    wire        pressed;
    wire [11:0] raw_x, raw_y;

    touch_xpt2046 #(.CLK_DIV(16)) u_touch_spi (
        .clk   (clk_ctrl),
        .rst_n (rst_n),
        .start (adc_start),
        .cmd   (adc_cmd),
        .data  (adc_data),
        .raw   (),
        .done  (adc_done),
        .cs_n  (T_CS),
        .sclk  (T_CLK),
        .mosi  (T_DIN),
        .miso  (T_DOUT)
    );

    touch_ctrl #(
        .SCREEN_W  (480),
        .SCREEN_H  (272),
        .X_MIN     (12'd200),
        .X_MAX     (12'd3900),
        .Y_MIN     (12'd200),
        .Y_MAX     (12'd3900),
        .X_INVERT  (1'b1),
        .Y_INVERT  (1'b1),
        .PRESS_MODE(2'd0),      // IRQ only (v6 的 IRQ|Z1 有坑: 无触摸时 Z1~0 会恒判按压;
                                //      用户的 IRQ 链路已被准星跟手证明工作正常)
        .Z_THRESH  (12'd2500),
        .POLL_CYC  (20'd30_000)     // v9: 3.3ms 轮询 (原 10ms), 灵敏度 x3
    ) u_touch_ctrl (
        .clk       (clk_ctrl),
        .rst_n     (rst_n),
        .adc_cmd   (adc_cmd),
        .adc_start (adc_start),
        .adc_data  (adc_data),
        .adc_done  (adc_done),
        .pos_x     (pos_x),
        .pos_y     (pos_y),
        .pressed   (pressed),
        .new_touch (new_touch),
        .raw_x     (raw_x),
        .raw_y     (raw_y),
        .raw_z1    (raw_z1),
        .irq_n     (T_IRQ)
    );

    //==============================================================
    // APDS-9960 手势引擎 (v10, I2C @ C17/C18)
    //   上/下挥 = 音色切换, 左/右挥 = 八度切换 (本地锁存, 下次 note_on 携带)
    //   模块接线: VCC=3.3V / GND / SCL=C17 / SDA=C18 / INT 不接(轮询模式)
    //   模块板载 "I2C pullup enable" 4.7k 跳线必须使能
    //==============================================================
    wire gest_up, gest_down, gest_left, gest_right;
    wire gest_ok;

    apds9960_gest #(
        .CLK_FREQ (9_000_000),
        .SCL_FREQ (90_000)
    ) u_gest (
        .clk        (clk_ctrl),
        .rst_n      (rst_n),
        .scl        (APDS_SCL),
        .sda        (APDS_SDA),
        .gest_up    (gest_up),
        .gest_down  (gest_down),
        .gest_left  (gest_left),
        .gest_right (gest_right),
        .sensor_ok  (gest_ok)
    );

    //==============================================================
    // 演奏语义 + 协议打包 (v9: 触摸 + 12 键琴键 双事件源, 琴键优先)
    //   KP_EN=0: 琴键矩阵未接线, 列浮空噪声会被关断, 防随机音符
    //   矩阵接好并验证后改为 1'b1
    //==============================================================
    localparam KP_EN = 1'b0;
    wire        tp_vld;       // 触摸面板事件
    wire [2:0]  tp_type;      // 0=on 1=off 2=test 3=raw-ctrl
    wire [7:0]  tp_note;
    wire [7:0]  tp_vel;
    wire        tp_tst;

    wire [3:0]  kp_row;       // 琴键事件
    wire [11:0] kp_pressed;
    wire        kp_vld, kp_on;
    wire [6:0]  kp_note;

    wire        kp_vld_g = kp_vld & KP_EN;
    wire        ev_vld  = kp_vld_g | tp_vld;
    wire [2:0]  ev_type = kp_vld_g ? (kp_on ? 3'd0 : 3'd1) : tp_type;
    wire [7:0]  ev_note = kp_vld_g ? {1'b0, kp_note} : tp_note;
    wire [7:0]  ev_vel  = kp_vld_g ? 8'd200 : tp_vel;
    wire        ev_tst  = tp_tst;

    wire [1:0]  cfg_wave, cfg_ep, cfg_vib;
    wire        tst_mode;
    wire [6:0]  cur_note;
    wire [1:0]  cfg_gli, cfg_fx, cfg_rev, cfg_mix;
    wire [1:0]  oct_mode;
    wire        lamp;
    wire        chord_hold;
    wire [1:0]  chord_idx;
    wire        uart_busy;
    wire [7:0]  frame_cnt;

    touch_panel u_panel (
        .clk        (clk_ctrl),
        .rst_n      (rst_n),
        .pos_x      (pos_x),
        .pos_y      (pos_y),
        .pressed    (pressed),
        .gest_up    (gest_up),
        .gest_down  (gest_down),
        .gest_left  (gest_left),
        .gest_right (gest_right),
        .ev_vld     (tp_vld),
        .ev_type    (tp_type),
        .ev_note    (tp_note),
        .ev_vel     (tp_vel),
        .ev_tst     (tp_tst),
        .cfg_wave   (cfg_wave),
        .cfg_ep     (cfg_ep),
        .cfg_vib    (cfg_vib),
        .tst_mode   (tst_mode),
        .cur_note   (cur_note),
        .cfg_gli    (cfg_gli),
        .cfg_fx     (cfg_fx),
        .cfg_rev    (cfg_rev),
        .cfg_mix    (cfg_mix),
        .oct_mode   (oct_mode),
        .lamp       (LAMP),
        .chord_hold (chord_hold),
        .chord_idx  (chord_idx)
    );

    frame_pack u_frame (
        .clk        (clk_ctrl),
        .rst_n      (rst_n),
        .ev_vld     (ev_vld),
        .ev_type    (ev_type),
        .ev_note    (ev_note),
        .ev_vel     (ev_vel),
        .ev_tst     (ev_tst),
        .cfg_wave   (cfg_wave),
        .cfg_ep     (cfg_ep),
        .cfg_vib    (cfg_vib),
        .uart_tx_pin(UART_TX),
        .uart_busy  (uart_busy),
        .frame_cnt  (frame_cnt)
    );

    //==============================================================
    // 12 键 CdS 矩阵琴键扫描 (v7, wire 已在事件区声明)
    //   键号 k = row*3 + col (0..11), 音符 = C4(60) + k (半音阶)
    //==============================================================
    keypad_scan #(
        .CLK_HZ      (9_000_000),   // clk_ctrl = 9 MHz
        .ROW_HOLD_US (20),
        .DBNC_ROWS   (4),
        .NOTE_BASE   (7'd60)
    ) u_keypad (
        .clk         (clk_ctrl),
        .rst_n       (rst_n),
        .row_onehot  (kp_row),
        .col_in      (KEYPAD_COL),
        .ev_vld      (kp_vld),
        .ev_on       (kp_on),
        .ev_note     (kp_note),
        .key_pressed (kp_pressed)
    );

    // 行三态: 选中行推 3.3V, 未选行 Hi-Z (防鬼影的关键!)
    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : g_row
            assign KEYPAD_ROW[gi] = kp_row[gi] ? 1'b1 : 1'bz;
        end
    endgenerate

    //==============================================================
    // 界面 (v5 网格控制面板)
    //==============================================================
    ui_render u_ui (
        .hcount    (h_addr),
        .vcount    (v_addr),
        .tx        (pos_x),
        .ty        (pos_y),
        .pressed   (pressed),
        .cfg_wave  (cfg_wave),
        .cfg_ep    (cfg_ep),
        .cfg_vib   (cfg_vib),
        .cfg_gli   (cfg_gli),
        .cfg_fx    (cfg_fx),
        .cfg_rev   (cfg_rev),
        .cfg_mix   (cfg_mix),
        .oct_mode  (oct_mode),
        .tst_mode  (tst_mode),
        .lamp      (lamp),
        .chord_hold(chord_hold),
        .chord_idx (chord_idx),
        .uart_busy (uart_busy),
        .rgb       (ui_rgb)
    );

endmodule
