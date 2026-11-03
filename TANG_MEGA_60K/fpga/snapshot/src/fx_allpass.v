//===============================================================
// fx_allpass —— 施罗德全通滤波器 (混响的扩散单元)
//
// 一阶全通:
//     y[n] = -g*x[n] + x[n-D] + g*y[n-D]
//
// 幅频响应恒为 1 (全通), 只改相位。作用是把梳状滤波器产生的
// "金属回声" 打散成密集的扩散声 —— Schroeder 混响器的标准第二级。
//
//  两条独立延迟线: 一条存 x、一条存 y, 都是 read-before-write,
//   环路被打断一拍但功能等价 (两条线长度相同, 延迟对齐)。
//
//  读写分两拍 (与 fx_comb 同理), 避免同址同拍读写的行为歧义。
//
//  g 用 2^-GS 的纯移位, 不用乘法器。稳定条件 |g| < 1,
//   任何 2^-GS (GS>=1) 都满足。
//===============================================================
module fx_allpass #(
    parameter integer L  = 225,     // 延迟长度 (样本, 225 = 2.27ms)
    parameter integer AW = 8,       // 地址位宽, 2^AW >= L
    parameter integer GS = 2        // 系数 g = 2^-GS
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               tick1,
    input  wire signed [15:0] x,
    output wire signed [15:0] y
);

    reg signed [15:0] mx [0:L-1];   // x 的延迟线
    reg signed [15:0] my [0:L-1];   // y 的延迟线
    // Deterministic power-up contents; inferred BSRAM initialization.
    integer hdmi_init_i;
    initial begin
        for(hdmi_init_i=0;hdmi_init_i<L;hdmi_init_i=hdmi_init_i+1) begin
            mx[hdmi_init_i] = 16'sd0;
            my[hdmi_init_i] = 16'sd0;
        end
    end
    reg [AW-1:0]      wp;
    reg signed [15:0] xd, yd;
    reg               tick1d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) tick1d <= 1'b0;
        else        tick1d <= tick1;
    end

    wire signed [15:0] gx = x  >>> GS;      // g*x
    wire signed [15:0] gy = yd >>> GS;      // g*y[n-D]

    // y[n] = -g*x[n] + x[n-D] + g*y[n-D]
    wire signed [16:0] sum = -$signed(gx) + $signed(xd) + $signed(gy);
    wire signed [15:0] yd_new = (sum > 17'sd32767)  ?  16'sd32767 :
                                (sum < -17'sd32768) ? -16'sd32768 : sum[15:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wp <= {AW{1'b0}};
            xd <= 16'sd0;
            yd <= 16'sd0;
        end
        else if (tick1) begin
            xd <= mx[wp];
            yd <= my[wp];
        end
        else if (tick1d) begin
            mx[wp] <= x;
            my[wp] <= yd_new;
            wp     <= (wp == (L-1)) ? {AW{1'b0}} : (wp + 1'b1);
        end
    end

    assign y = yd_new;

endmodule
