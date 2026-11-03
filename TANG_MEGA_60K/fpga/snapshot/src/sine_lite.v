//===============================================================
// sine_lite - 33 点 Q15 正弦表 + 象限折叠 (只出正弦, 给分音用)
//
// 为什么需要这个模块 (2026-10-21, 为 32 声部腾资源):
//   分音(tine)原来直接例化了一个 waveform_set, 只接 .sine 一个输出。
//   综合报告实测: u_bell 166 LUT/声部, 而五种波形全用的 u_ws 只要
//   47 ALU + 30 LUT = 77/声部。只出一个正弦反而比全出贵一倍多 ——
//   因为 u_ws 里正弦是用算术实现的, 而 u_bell 被综合成了一张大 LUT 表。
//
//   32 声部 × (166-100) ≈ 2100 逻辑, 这一项就能补回超资源的大半。
//
// 精度取舍:
//   表点 65 -> 33 (每象限 32 步, 每周期 128 步)。
//   相邻表值最大差 1608/32768 = 4.9%, 阶梯产生的杂散是分音频率的
//   整数次谐波(不是非谐杂散), 听感上就是"稍微毛一点的金属叮",
//   而分音本身 165ms 就衰减掉了, 可以接受。
//   表值直接取 65 点表里偶数下标的项 —— 曲线完全一致, 只是采样更稀。
//
// 相位约定与 waveform_set 相同: phase[31:30] = 象限,
//   phase[29:25] = 象限内 32 步索引。
//===============================================================
module sine_lite (
    input  wire [31:0] phase,
    output reg  signed [15:0] sine
);

    // sin(k*pi/64), k = 0..32, Q15
    function [15:0] sin_q;
        input [5:0] a;
        begin
            case (a)
                6'd0 : sin_q = 16'd0;      6'd1 : sin_q = 16'd1608;
                6'd2 : sin_q = 16'd3212;   6'd3 : sin_q = 16'd4808;
                6'd4 : sin_q = 16'd6393;   6'd5 : sin_q = 16'd7962;
                6'd6 : sin_q = 16'd9512;   6'd7 : sin_q = 16'd11039;
                6'd8 : sin_q = 16'd12539;  6'd9 : sin_q = 16'd14010;
                6'd10: sin_q = 16'd15446;  6'd11: sin_q = 16'd16846;
                6'd12: sin_q = 16'd18204;  6'd13: sin_q = 16'd19519;
                6'd14: sin_q = 16'd20787;  6'd15: sin_q = 16'd22005;
                6'd16: sin_q = 16'd23170;  6'd17: sin_q = 16'd24279;
                6'd18: sin_q = 16'd25329;  6'd19: sin_q = 16'd26319;
                6'd20: sin_q = 16'd27245;  6'd21: sin_q = 16'd28105;
                6'd22: sin_q = 16'd28898;  6'd23: sin_q = 16'd29621;
                6'd24: sin_q = 16'd30273;  6'd25: sin_q = 16'd30852;
                6'd26: sin_q = 16'd31356;  6'd27: sin_q = 16'd31785;
                6'd28: sin_q = 16'd32137;  6'd29: sin_q = 16'd32412;
                6'd30: sin_q = 16'd32609;  6'd31: sin_q = 16'd32728;
                default: sin_q = 16'd32767;
            endcase
        end
    endfunction

    reg [5:0]  idx;
    reg        neg;
    reg [15:0] mag;

    always @* begin
        case (phase[31:30])
            2'b00: begin idx = {1'b0, phase[29:25]};          neg = 1'b0; end
            2'b01: begin idx = 6'd32 - {1'b0, phase[29:25]};  neg = 1'b0; end
            2'b10: begin idx = {1'b0, phase[29:25]};          neg = 1'b1; end
            default: begin idx = 6'd32 - {1'b0, phase[29:25]}; neg = 1'b1; end
        endcase
        mag  = sin_q(idx);
        sine = neg ? -$signed(mag) : $signed(mag);
    end

endmodule
