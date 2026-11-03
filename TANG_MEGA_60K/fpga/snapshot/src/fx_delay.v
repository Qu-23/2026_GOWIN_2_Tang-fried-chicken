//===============================================================
// fx_delay —— 延迟 / 合唱 (共用一条延迟线)
//
// 为什么共用: 延迟(回声)和合唱本质是同一件事 —— 从延迟线里取一个抽头。
//   区别只在
//     · echo  : 抽头固定, 有反馈, 输出 = 干 + 湿
//     · chorus: 抽头被慢速 LFO 调制, 无反馈, 输出 = 干 + 湿
//   共用一条 16384 样本 (165ms @99.3kHz) 的线, 省下 15 个 BSRAM。
//
//  一个 tick 拆成 3 个时钟相位完成:
//     ph=1 读 tap0        (rd0 = mem[wp-d])
//     ph=2 读 tap1        (rd1 = mem[wp-d-1], 合唱平滑用)
//     ph=3 写回 + 出结果
//   tick 每 64 个时钟才有一次, 用掉 3 拍毫无代价, 换来的是
//   "同一拍内不对同一块 BSRAM 既读又写" 的确定性行为。
//
//  反馈增益全用移位加, 不占 DSP:
//     fb_sel  0=0 / 1=0.375 / 2=0.5 / 3=0.625
//===============================================================
module fx_delay #(
    parameter integer MAXL = 16384,     // 最大延迟样本数 (165ms @99.3kHz)
    parameter integer AW   = 14         // 2^AW >= MAXL
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               tick1,          // 99.3kHz 单拍脉冲
    input  wire               mode,           // 0=echo  1=chorus
    input  wire [13:0]        dly,            // echo: 延迟样本数 / chorus: 基础延迟
    input  wire [1:0]         fb_sel,         // echo 反馈档
    input  wire signed [15:0] x,
    output reg  signed [15:0] y               // 纯湿声抽头 (不含干声)
);

    reg signed [15:0] mem [0:MAXL-1];
    // Deterministic BSRAM power-up contents; no runtime RAM reset.
    initial $readmemh("fx_delay_zero.hex", mem);
    reg [AW-1:0]      wp;

    //---- 3 相位时序 ----
    reg [1:0] ph;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          ph <= 2'd0;
        else if (tick1)      ph <= 2'd1;
        else if (ph != 2'd0) ph <= ph + 2'd1;   // 1->2->3->0
    end

    // Chorus delay modulation uses a phase-derived triangle LFO (~0.6 Hz).
    // Its 23-bit level avoids the coarse increments of the former sine LUT.
    // Delay interpolation below uses a Q8 fractional position.
    reg [23:0] lfo_ph;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)     lfo_ph <= 24'd0;
        else if (tick1) lfo_ph <= lfo_ph + 24'd101;   // 0.6Hz @99.3kHz
    end

    // 折成三角: 上升半周用原相位, 下降半周取反
    wire [22:0] tri_d = lfo_ph[23] ? ~lfo_ph[22:0] : lfo_ph[22:0];

    // Q8 定点调制量: 高 16 位 -> -32768..+32767 = +-128 样本 (+-1.29ms)
    wire signed [15:0] mod_q8 = $signed({1'b0, tri_d[22:7]}) - 16'sd32768;

    //---- 读地址 (Q8 定点, 有符号加法, 支持正负调制) ----
    //   echo 模式 frac 恒为 0, 插值退化成 rd0, 与原来完全等价。
    wire signed [23:0] d_echo_q8 = {1'b0, dly, 8'b0};
    wire signed [23:0] d_ch_q8   = {1'b0, dly, 8'b0} + {{8{mod_q8[15]}}, mod_q8};
    wire signed [23:0] d_use_q8  = mode ? d_ch_q8 : d_echo_q8;

    wire [AW-1:0]      base = wp - d_use_q8[AW+7:8];
    wire [AW-1:0]      a0   = base;
    wire [AW-1:0]      a1   = base - 1'b1;
    wire [7:0]         frac = d_use_q8[7:0];      // 0..255, 越大越靠近 a1

    reg signed [15:0] rd0, rd1;
    always @(posedge clk) begin
        if (ph == 2'd1)      rd0 <= mem[a0];
        else if (ph == 2'd2) rd1 <= mem[a1];
    end

    //---- 反馈增益 (纯移位加) ----
    wire signed [15:0] g_rd =
        (fb_sel == 2'd0) ? 16'sd0 :
        (fb_sel == 2'd1) ? ((rd0 >>> 2) + (rd0 >>> 3)) :   // 0.375
        (fb_sel == 2'd2) ?  (rd0 >>> 1) :                  // 0.5
                           ((rd0 >>> 1) + (rd0 >>> 3));    // 0.625

    //---- 写入数据 ----
    wire signed [16:0] wsum = $signed(x) + $signed(g_rd);
    wire signed [15:0] wd   = (wsum > 17'sd32767)  ?  16'sd32767 :
                              (wsum < -17'sd32768) ? -16'sd32768 : wsum[15:0];

    //---- 湿声: chorus 用线性插值 (消除抽头切换的台阶) ----
    //   a0 = wp-d, a1 = a0-1 (更早一个样本 = 延迟更长一格)
    //   frac 是小数延迟, 所以 wet = rd0 + (rd1-rd0)*frac/256
    //    这里只输出纯湿声, 干湿混合统一由 fx_engine 做。
    //     (早期版本在这里也混一次, 结果 fx_engine 又混一次, 干声被叠加两遍,
    //      相当于 +6dB 且 mix_sel 失效 —— 已在 2026-10-23 改掉。)
    wire signed [16:0] dlt   = $signed(rd1) - $signed(rd0);      // 17bit
    wire signed [24:0] dfrac = dlt * $signed({1'b0, frac});      // 17x8 -> 25bit
    wire signed [16:0] dsc   = dfrac >>> 8;                      // 回到 17bit 量纲
    wire signed [17:0] wet_f = $signed(rd0) + dsc;
    wire signed [15:0] wet_c = wet_f[15:0];
    wire signed [15:0] wet   = mode ? wet_c : rd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wp <= {AW{1'b0}};
            y  <= 16'sd0;
        end
        else if (ph == 2'd3) begin
            mem[wp] <= wd;
            wp      <= (wp == (MAXL-1)) ? {AW{1'b0}} : (wp + 1'b1);
            y       <= wet;
        end
    end

endmodule
