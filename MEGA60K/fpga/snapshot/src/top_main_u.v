// Main_U entry point retained for the audio configuration.
// The HDMI submission uses top_hdmi as its top-level module.
// realistic_poly_ram shares a renderer across 32 voice states in BSRAM.
// Instruments: wave 0 = electric piano (jRhodes3c-derived tables),
// wave 3 = cello (Iowa MIS-derived tables).
// BT_SONG enables volatile S/K/P/X single-melody storage and playback.
// UART RX: V14; JDY-31 TXD -> B15, RXD <- B16.
// These UART pins do not connect to the CH569 USB Type-C data path.
// DAC_SHIFT=0 selects the unshifted PCM output.
module top_main (
    input  wire key0, key1, key2,
    input  wire uart_rx,
    input  wire uart_bt,      // JDY-31 TXD -> B15
    output wire uart_bt_tx,   // JDY-31 RXD <- B16
    output wire HP_BCK, HP_WS, HP_DIN, PA_EN,
    output wire [3:0] LEDs,
    output wire WS2812
);
    top #(
        .N_VOICES (32),
        .USE_LSBJ (1),
        .KEY_WAVE (2'd0),       // 板载按键 = 电钢
        .EP_SEL   (2'd0),       // 真实采样引擎不使用（只有两种乐器）
        .PLUCK_SEL(2'd1),
        .UNISON   (0),
        .PA_GATE  (0),
        .TEST_MODE(0),
        .FX_ON    (1),          // 硬件效果器（混响/延迟/合唱）
        .BT_ON    (1),          // 蓝牙双路 UART 仲裁
        .GLIDE    (1),
        .KEY_IN   (1),          // 板载按键可用（真实采样引擎只占 6% 逻辑）
        .DAC_SHIFT(0),         //  main_U: 满幅输出（main_T 是 2 = -12dB）
        .ENGINE_REAL(1),        //  用 realistic_poly_ram 取代 synth_engine
        .BT_SONG  (1)           //  蓝牙口挂上曲谱下发 + 脱机自动演奏
    ) u_top (
        .key0(key0), .key1(key1), .key2(key2),
        .uart_rx(uart_rx), .uart_bt(uart_bt), .uart_bt_tx(uart_bt_tx),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN),
        .LEDs(LEDs), .WS2812(WS2812)
    );
endmodule
