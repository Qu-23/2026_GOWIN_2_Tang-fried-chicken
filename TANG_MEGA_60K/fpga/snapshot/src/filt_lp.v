// Two cascaded first-order low-pass stages, using shift/add arithmetic.
// k=0 bypasses the filter; larger k lowers the cutoff.
// At approximately 99.3 kHz: k=1 ~7.9 kHz, k=2 ~4.0 kHz,
// k=3 ~2.0 kHz. For k=4 the second stage uses one extra shift.
// synth_engine selects k by note register and filter envelope.
// Constant shifts are expanded in a case statement for Gowin synthesis.
// clear resets both filter states when a voice restarts at silence.
module filt_lp (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               tick,       // 99.3kHz 采样节拍
    input  wire               clear,      // synchronous reset at a silent note restart
    input  wire signed [15:0] x,          // 输入
    input  wire [3:0]         k,          // 0..5, 越大越暗 (0 = 直通)
    output reg  signed [15:0] y           // 低通输出
);

    // 24bit 状态保留精度, 避免小 k 时的舍入噪声累积
    reg signed [23:0] s1, s2;

    // 输入左移 8 位对齐到 24bit 量纲, 低 8 位成为滤波的小数精度
    wire signed [23:0] x24 = $signed({x, 8'b0});

    // 25bit 有符号差值 (比 24bit 多一位, 防止相减溢出)
    wire signed [24:0] d1 = $signed({x24[23], x24}) - $signed({s1[23], s1});
    wire signed [24:0] d2 = $signed({s1[23],  s1})  - $signed({s2[23], s2});

    // ---- 常量移位: 用 case 展开, 不用变量移位 ----
    //
    //  2026-10-23 只保留 k = 0..4 (省 3 个分支 = 约 94 LUT/声部, 32 声部省 ~3000)。
    //   这不是"删功能", 而是删不可达分支: synth_engine 的 kcur 恒为
    //   min(ksub, flt_kmax), 而 flt_kmax 由 kmax_of 决定, 只可能是 2/3/4
    //   (见 synth_engine.v 的 kmax_of); TEST_MODE 下 kmax=0。
    //   所以 k=5/6/7 在任何预设下都到不了。
    //   default 走 k=4 只是为了综合器不必生成不可达逻辑, 万一越界也只是
    //   比预期亮一点, 不会静音或爆音。
    //
    //  2026-10-30: k=4 的第二级移位量 4 -> 5 (500Hz), 第一级仍是 1kHz。
    //   这构成"1kHz 一阶 + 500Hz 一阶"的非对称级联, 见文件头说明。
    reg signed [24:0] d1s, d2s;
    always @* begin
        case (k)
            4'd0: begin d1s = d1;            d2s = d2;            end
            4'd1: begin d1s = d1 >>> 1;      d2s = d2 >>> 1;      end
            4'd2: begin d1s = d1 >>> 2;      d2s = d2 >>> 2;      end
            4'd3: begin d1s = d1 >>> 3;      d2s = d2 >>> 3;      end
            default: begin d1s = d1 >>> 4;   d2s = d2 >>> 5;      end
        endcase
    end

    wire signed [24:0] n1 = $signed({s1[23], s1}) + d1s;
    wire signed [24:0] n2 = $signed({s2[23], s2}) + d2s;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1 <= 24'sd0;
            s2 <= 24'sd0;
            y  <= 16'sd0;
        end
        else if (tick) begin
            if (clear) begin
                s1 <= 24'sd0;
                s2 <= 24'sd0;
                y  <= 16'sd0;
            end else begin
                s1 <= n1[23:0];
                s2 <= n2[23:0];
                y  <= n2[23:8];
            end
        end
    end

endmodule
