//===============================================================
// softsaw_osc - 只出"柔化锯齿"的单振荡器 (纯组合, 无 ROM 无乘法器)
//
//  2026-10-22 新增: 为了复现 v7 那个"像大提琴"的铺底。
//
// 为什么单独做一个模块, 而不是再例化一次 waveform_set:
//   齐奏(unison)需要 2 个额外的失谐振荡器, 每声部就是 3 个振荡器。
//   waveform_set 会同时算出 5 种波形 (含 65 点正弦表), 实测 77 LUT/份;
//   而铺底只用柔化锯齿, 柔化锯齿只用到 saw 和 triangle —— 两者都是
//   相位位的直接变换, 没有任何查表。单独拎出来只要二十几个 LUT。
//
// 柔化锯齿 = (7/8)*saw + (1/8)*triangle
//   saw 谐波 1/k, triangle 奇次 1/k^2 (无偶次)
//   混合后偶次 (1-m)/k, 奇次 (1-m)/k + m/k^2, m=1/8 时
//   2次 -7.2dB / 3次 -10.3 / 4次 -13.2 —— 与 v7 pad ROM 实测
//   (-7 / -11 / -14) 几乎一致。大提琴/弦乐的频谱特征正是
//   偶次谐波齐全且缓慢衰减, 三角波(只有奇次 1/k^2)听起来像长笛。
//===============================================================
module softsaw_osc (
    input  wire [31:0] phase,
    output wire signed [15:0] ssaw
);
    // saw: 低 8 位小数进位补偿(免掉一个乘法器)
    wire frac = |phase[7:0];
    wire signed [23:0] w24 = (frac && (phase[31:8] != 24'h7FFFFF))
                             ? ($signed(phase[31:8]) + 24'sd1)
                             : $signed(phase[31:8]);

    // triangle: 折返后平移
    wire signed [23:0] t24a = phase[31] ? $signed({1'b0, ~phase[30:8]})
                                        : $signed({1'b0,  phase[30:8]});
    wire signed [23:0] t24 = (t24a <<< 1) - 24'sh7FFFFF;

    // 7/8 saw + 1/8 tri: 两次移位 + 两次加减
    wire signed [23:0] ss24 = w24 - (w24 >>> 3) + (t24 >>> 3);

    assign ssaw = ss24[23:8];

endmodule
