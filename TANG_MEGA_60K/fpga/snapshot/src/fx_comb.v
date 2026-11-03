//===============================================================
// fx_comb —— 施罗德梳状滤波器 (混响的基本单元)
//
// 结构: 环形延迟线, 读出的样本乘反馈增益再加回输入
//     rd      = mem[wp]              (L 个样本之前的值)
//     mem[wp] = x + g*rd
//     wp++
//     y = rd
//
//  读写分两个时钟周期: tick1 读, 下一拍写同一个地址。
//   若读写同拍同址, 结果取决于 BSRAM 原语的 write mode (read-before-write
//   vs write-first), 仿真和综合可能不一致。tick1 每 64 个时钟才有一次,
//   中间 63 拍全空闲, 隔一拍写不花任何代价, 却让行为完全确定。
//
//  反馈增益用移位加而不是乘法器: g 是编译期常量, 三个移位加约 45 LUT,
//   而一个 16x16 乘法器要占一个 DSP 硬核。32 声部已把 DSP 用到 101/118,
//   效果器不该再抢 DSP。
//
//  gsel 四档 (运行时选, 全 < 1 保证稳定):
//     0 -> 0.500  (2^-1)                  短尾巴, "小房间"
//     1 -> 0.688  (2^-1 + 2^-3 + 2^-4)    中等, 默认
//     2 -> 0.750  (2^-1 + 2^-2)           长一点
//     3 -> 0.813  (2^-1 + 2^-2 + 2^-4)    "大厅", T60 约 0.9s
//===============================================================
module fx_comb #(
    parameter integer L  = 1487,   // 延迟长度 (样本, 99.3kHz 下 1487 = 15.0ms)
    parameter integer AW = 11      // 地址位宽, 必须满足 2^AW >= L
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               tick1,          // 99.3kHz 采样节拍 (单拍脉冲)
    input  wire [1:0]         gsel,           // 反馈增益档
    input  wire signed [15:0] x,
    output wire signed [15:0] y
);

    reg signed [15:0] mem [0:L-1];
    // Deterministic power-up contents; inferred BSRAM initialization.
    integer hdmi_init_i;
    initial begin
        for(hdmi_init_i=0;hdmi_init_i<L;hdmi_init_i=hdmi_init_i+1) begin
            mem[hdmi_init_i] = 16'sd0;
        end
    end
    reg [AW-1:0]      wp;
    reg signed [15:0] rd;
    reg               tick1d;

    //---- tick1 延后一拍, 用来错开读写 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) tick1d <= 1'b0;
        else        tick1d <= tick1;
    end

    //---- 反馈增益 (纯移位加, 四档) ----
    wire signed [15:0] g0 =  (rd >>> 1);
    wire signed [15:0] g1 =  (rd >>> 1) + (rd >>> 3) + (rd >>> 4);
    wire signed [15:0] g2 =  (rd >>> 1) + (rd >>> 2);
    wire signed [15:0] g3 =  (rd >>> 1) + (rd >>> 2) + (rd >>> 4);
    wire signed [15:0] fb = (gsel == 2'd0) ? g0 :
                            (gsel == 2'd1) ? g1 :
                            (gsel == 2'd2) ? g2 : g3;

    //---- x + fb, 饱和到 16bit ----
    wire signed [16:0] sum = $signed(x) + $signed(fb);
    wire signed [15:0] wd  = (sum > 17'sd32767)  ?  16'sd32767 :
                             (sum < -17'sd32768) ? -16'sd32768 : sum[15:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wp <= {AW{1'b0}};
            rd <= 16'sd0;
        end
        else if (tick1) begin
            rd <= mem[wp];                   // 读最老样本
        end
        else if (tick1d) begin
            mem[wp] <= wd;                   // 下一拍写回同一地址
            wp      <= (wp == (L-1)) ? {AW{1'b0}} : (wp + 1'b1);
        end
    end

    assign y = rd;

endmodule
