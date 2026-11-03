//===============================================================
// waveform_set - 从 32bit 相位组合逻辑算出 4 种波形 (不用 ROM)
//
// 借鉴自 fpga-main/rtl/waveform_set.sv (Sipeed Tang Mega 138K 开源工程),
// 改成 Verilog-2001 + 16bit 输出。
//
// 好处: 没有 ROM、没有分时复用 —— 每个声部可以完全并行,
//       8 个声部就是 8 个真正独立的振荡器。
//
// 四种波形:
//   sine     : 65 点 Q15 正弦表 + 象限折叠
//   square   : 相位最高位
//   saw      : 相位高 24 位(带低 8 位小数进位补偿)
//   triangle : 相位折返 + 平移
//===============================================================
module waveform_set (
    input  wire [31:0] phase,
    output reg  signed [15:0] sine,
    output reg  signed [15:0] square,
    output reg  signed [15:0] saw,
    output reg  signed [15:0] triangle,
    //  2026-10-19 新增: 柔化锯齿 (soft saw)
    //   v7 的"铺底"之所以像大提琴, 就是因为它用的不是基础波形,
    //   而是谐波按 1/k^1.2 衰减的柔化锯齿 —— 偶次谐波完整保留。
    //   实测 v7 pad ROM: 2次 -7dB, 3次 -11, 4次 -14, 5次 -17, 6次 -19
    //   而三角波只有奇次且 1/k^2 (3次就 -19dB), 听起来像长笛/管风琴。
    //   大提琴/弦乐的频谱特征正是偶次谐波齐全且缓慢衰减。
    output reg  signed [15:0] softsaw
);

    // sin(k*pi/128), k=0..64, Q15
    function [15:0] sin_q;
        input [6:0] a;
        begin
            case (a)
                7'd0 : sin_q = 16'd0;     7'd1 : sin_q = 16'd804;
                7'd2 : sin_q = 16'd1608;  7'd3 : sin_q = 16'd2410;
                7'd4 : sin_q = 16'd3212;  7'd5 : sin_q = 16'd4011;
                7'd6 : sin_q = 16'd4808;  7'd7 : sin_q = 16'd5602;
                7'd8 : sin_q = 16'd6393;  7'd9 : sin_q = 16'd7179;
                7'd10: sin_q = 16'd7962;  7'd11: sin_q = 16'd8739;
                7'd12: sin_q = 16'd9512;  7'd13: sin_q = 16'd10278;
                7'd14: sin_q = 16'd11039; 7'd15: sin_q = 16'd11793;
                7'd16: sin_q = 16'd12539; 7'd17: sin_q = 16'd13279;
                7'd18: sin_q = 16'd14010; 7'd19: sin_q = 16'd14732;
                7'd20: sin_q = 16'd15446; 7'd21: sin_q = 16'd16151;
                7'd22: sin_q = 16'd16846; 7'd23: sin_q = 16'd17530;
                7'd24: sin_q = 16'd18204; 7'd25: sin_q = 16'd18868;
                7'd26: sin_q = 16'd19519; 7'd27: sin_q = 16'd20159;
                7'd28: sin_q = 16'd20787; 7'd29: sin_q = 16'd21403;
                7'd30: sin_q = 16'd22005; 7'd31: sin_q = 16'd22594;
                7'd32: sin_q = 16'd23170; 7'd33: sin_q = 16'd23731;
                7'd34: sin_q = 16'd24279; 7'd35: sin_q = 16'd24811;
                7'd36: sin_q = 16'd25329; 7'd37: sin_q = 16'd25832;
                7'd38: sin_q = 16'd26319; 7'd39: sin_q = 16'd26790;
                7'd40: sin_q = 16'd27245; 7'd41: sin_q = 16'd27683;
                7'd42: sin_q = 16'd28105; 7'd43: sin_q = 16'd28510;
                7'd44: sin_q = 16'd28898; 7'd45: sin_q = 16'd29268;
                7'd46: sin_q = 16'd29621; 7'd47: sin_q = 16'd29956;
                7'd48: sin_q = 16'd30273; 7'd49: sin_q = 16'd30571;
                7'd50: sin_q = 16'd30852; 7'd51: sin_q = 16'd31113;
                7'd52: sin_q = 16'd31356; 7'd53: sin_q = 16'd31580;
                7'd54: sin_q = 16'd31785; 7'd55: sin_q = 16'd31971;
                7'd56: sin_q = 16'd32137; 7'd57: sin_q = 16'd32285;
                7'd58: sin_q = 16'd32412; 7'd59: sin_q = 16'd32521;
                7'd60: sin_q = 16'd32609; 7'd61: sin_q = 16'd32678;
                7'd62: sin_q = 16'd32728; 7'd63: sin_q = 16'd32757;
                default: sin_q = 16'd32767;
            endcase
        end
    endfunction

    reg [6:0]         idx;
    reg               neg;
    reg [15:0]        mag;
    reg signed [23:0] s24, q24, w24, t24;
    reg signed [23:0] ss24;         // 柔化锯齿
    reg               frac;

    // 柔化锯齿 = (1 - 1/8)*saw + (1/8)*triangle
    //
    //   为什么这样混: saw 的谐波是 1/k, triangle 是 1/k^2 (仅奇次)。
    //   混合后:  偶次 (1-m)/k,  奇次 (1-m)/k + m/k^2
    //   m = 1/8 时: 2次 -7.2dB, 3次 -10.3dB, 4次 -13.2dB
    //   与 v7 pad ROM 实测的 -7 / -11 / -14 几乎一致。
    //
    //   纯移位实现, 不占 DSP: 一次 >>3 + 两次加减。

    always @* begin
        //---- sine: 象限折叠 ----
        case (phase[31:30])
            2'b00: begin idx = {1'b0, phase[29:24]};           neg = 1'b0; end
            2'b01: begin idx = 7'd64 - {1'b0, phase[29:24]};   neg = 1'b0; end
            2'b10: begin idx = {1'b0, phase[29:24]};           neg = 1'b1; end
            default: begin idx = 7'd64 - {1'b0, phase[29:24]}; neg = 1'b1; end
        endcase
        mag = sin_q(idx);
        s24 = neg ? -$signed({mag, 8'b0}) : $signed({mag, 8'b0});

        //---- saw: 低 8 位小数进位补偿(免掉一个乘法器) ----
        frac = |phase[7:0];
        if (frac && (phase[31:8] != 24'h7FFFFF))
            w24 = $signed(phase[31:8]) + 24'sd1;
        else
            w24 = $signed(phase[31:8]);

        //---- triangle: 折返后平移 ----
        t24 = phase[31] ? $signed({1'b0, ~phase[30:8]})
                        : $signed({1'b0,  phase[30:8]});
        t24 = (t24 <<< 1) - 24'sh7FFFFF;

        //---- square ----
        q24 = phase[31] ? -24'sh7FFFFF : 24'sh7FFFFF;

        //---- soft saw = 7/8 * saw + 1/8 * triangle ----
        //   两次移位 + 一次加法, 无乘法器。
        //   w24 - (w24>>3) + (t24>>3)  =  (7/8)w24 + (1/8)t24
        ss24 = w24 - (w24 >>> 3) + (t24 >>> 3);

        sine     = s24[23:8];
        square   = q24[23:8];
        saw      = w24[23:8];
        triangle = t24[23:8];
        softsaw  = ss24[23:8];
    end

endmodule
