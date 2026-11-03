//===============================================================
// audio_drive_lsbj - PT8211 专用发送器 (LSBJ / Japanese format)
//
//  为什么需要这个模块:
//   PT8211-S 不是 Philips I2S, 而是 LSBJ (Japanese format)。
//   三处硬差异:
//
//   | 项目       | Philips I2S (原 audio_drive.v) | PT8211 LSBJ (本模块) |
//   |------------|-------------------------------|----------------------|
//   | WS 极性    | WS=0 -> 左, WS=1 -> 右         | WS=1 -> 左, WS=0 -> 右 |
//   | DIN 更新沿 | BCK 上升沿 (与采样同拍!)        | BCK 下降沿 (留半周期余量) |
//   | MSB 位置   | 比 WS 跳变晚 1 个 BCK           | 紧跟 WS 跳变       |
//
//   第二条最致命: PT8211 在 BCK 上升沿采样 DIN, 而原模块里
//   `HP_DIN_r <= sr[15]` 也发生在 clk 上升沿, 且 `HP_BCK = clk`。
//   于是 DIN 和 BCK 上升沿同拍翻转 —— DAC 采样时数据正在变,
//   采到的是翻转前的旧值。实测 (sim/tb_i2s_ab.v):
//       送入 L=0x1000 R=0x7000
//       Philips 版 DAC 收到 L=0x3800 R=0x0000
//   0x7000>>1 = 0x3800 —— 整体右移 1 位 (幅度减半 -6dB + 丢 LSB) + 声道错位。
//
//  时序设计:
//   - BCK 上升沿 = DAC 采样点
//   - DIN / WS 只在 下降沿 更新 → 到下一个上升沿稳定半个周期(≈315ns)
//   - 每个 slot 用一个独立移位寄存器装载, 保证 16 位全部来自同一个样本
//     ( 曾经用 32bit frame + `frame[31-b_cnt]` 直接索引, 结果是左声道
//       第 1 位取到上一帧的旧 MSB —— 每次过零就错一位, 实测 84/2096 个
//       样本的符号位翻转。改成整帧装载后逐位精确。)
//
//   装载点: posedge b_cnt==31 装左样本, posedge b_cnt==15 装右样本,
//           其余 posedge 左移。negedge 只把 sr[15] 推出去。
//
//   DAC 在 posedge b_cnt = k->k+1 采样 (k = 0..31):
//     k  0..15 -> L[15]..L[0], WS=1
//     k 16..31 -> R[15]..R[0], WS=0
//   WS 在 negedge 用 `~b_cnt[4]` 决定, 与上面的 slot 边界严格对齐。
//
//   req: 每 16 BCK 一次 (99.3kHz), 位置与原模块逐字一致 (b_cnt 14/30),
//        因此引擎采样率、音高标定、包络时间全部不变。
//===============================================================
module audio_drive_lsbj (
    input  wire        clk_1p536m,
    input  wire        rst_n,
    input  wire [15:0] idata_l,
    input  wire [15:0] idata_r,
    output wire        req,
    output wire        HP_BCK,
    output wire        HP_WS,
    output wire        HP_DIN
);

    assign HP_BCK = clk_1p536m;

    reg [4:0]  b_cnt;
    reg [15:0] sr;          // 当前 slot 的移位寄存器
    // Capture a coherent pair at the left frame boundary. req timing is
    // unchanged: the shared synth still updates twice per DAC stereo frame.
    reg [15:0] right_hold;
    reg        req_r;
    reg        ws_r, din_r;

    //---- 上升沿: 帧计数 / req / 整帧装载 / 左移 ----
    always @(posedge clk_1p536m or negedge rst_n) begin
        if (!rst_n) begin
            b_cnt <= 5'd0;
            sr    <= 16'd0;
            right_hold <= 16'd0;
            req_r <= 1'b0;
        end
        else begin
            b_cnt <= b_cnt + 5'd1;
            req_r <= (b_cnt == 5'd14) || (b_cnt == 5'd30);

            if      (b_cnt == 5'd31) begin sr <= idata_l; right_hold <= idata_r; end
            else if (b_cnt == 5'd15) sr <= right_hold;
            else                     sr <= {sr[14:0], 1'b0};
        end
    end

    //---- 下降沿: 只有 WS 和 DIN ----
    //   b_cnt 在上一个上升沿更新后, 整个低电平期间保持不变。
    always @(negedge clk_1p536m or negedge rst_n) begin
        if (!rst_n) begin
            ws_r  <= 1'b1;
            din_r <= 1'b0;
        end
        else begin
            ws_r  <= ~b_cnt[4];      // b_cnt 0..15 -> WS=1(左); 16..31 -> WS=0(右)
            din_r <= sr[15];         // MSB 在前
        end
    end

    assign HP_WS  = ws_r;
    assign HP_DIN = din_r;
    assign req    = req_r;

endmodule
