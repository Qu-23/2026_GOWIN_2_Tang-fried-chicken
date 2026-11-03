//////////////////////////////////////////////////////////////////////////////////
// Module Name : touch_xpt2046
// Description : XPT2046 / TSC2046 / ADS7846 四线电阻触摸屏 SPI 时序驱动
//
//   控制字格式（8 bit）:
//     bit7    START   = 1
//     bit6:4  A2:A0   通道选择  101=X位置  001=Y位置  011=Z1  100=Z2
//     bit3    MODE    0 = 12bit 差分模式
//     bit2    SER/DFR 0 = 差分
//     bit1:0  PD1:PD0 00 = 转换后进入低功耗
//
//   一次转换 = 8 bit 命令 + 16 bit 读回
//   读回的第 1 bit 是空位(NULL)，接着 12 bit 才是转换结果，最后补 0
//   因此 16 bit 移位寄存器中 [14:3] 即为 12 bit ADC 值
//
//   SPI 模式 0：CS 拉低 -> 上升沿采样 -> 数据在下降沿更新
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps

module touch_xpt2046 #(
    parameter CLK_DIV = 16          // SCLK 半周期 = CLK_DIV 个时钟 => 33MHz/32 ≈ 1.03MHz
)(
    input  wire        clk,         // 33MHz
    input  wire        rst_n,

    input  wire        start,       // 单周期启动脉冲
    input  wire [7:0]  cmd,         // 转换命令
    output reg  [11:0] data,        // 12bit 转换结果
    output reg  [15:0] raw,         // 16bit 原始读回值（调试用）
    output reg         done,        // 单周期完成脉冲（与 data 同拍有效）

    output reg         cs_n,
    output reg         sclk,
    output reg         mosi,
    input  wire        miso
);

    localparam [1:0] S_IDLE = 2'd0,
                     S_CMD  = 2'd1,
                     S_RD   = 2'd2,
                     S_DONE = 2'd3;

    reg [1:0]  st;
    reg [4:0]  div;         // SCLK 分频计数
    reg [4:0]  bcnt;        // 位计数
    reg [15:0] rdsh;        // 读回移位寄存器
    reg [7:0]  shcmd;       // 命令移位寄存器

    wire tick = (div == (CLK_DIV - 1));

    //---------------- 分频计数 ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            div <= 5'd0;
        else if (st == S_IDLE)
            div <= 5'd0;
        else if (tick)
            div <= 5'd0;
        else
            div <= div + 5'd1;
    end

    //---------------- SPI 状态机 ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st   <= S_IDLE;
            cs_n <= 1'b1;
            sclk <= 1'b0;
            mosi <= 1'b0;
            bcnt <= 5'd0;
            rdsh <= 16'd0;
            shcmd<= 8'd0;
            data <= 12'd0;
            raw  <= 16'd0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;

            case (st)
                S_IDLE: begin
                    cs_n <= 1'b1;
                    sclk <= 1'b0;
                    if (start) begin
                        cs_n  <= 1'b0;
                        shcmd <= cmd;
                        mosi  <= cmd[7];
                        bcnt  <= 5'd0;
                        rdsh  <= 16'd0;
                        st    <= S_CMD;
                    end
                end

                S_CMD, S_RD: begin
                    if (tick) begin
                        if (!sclk) begin
                            // 上升沿：主设备输出已经稳定，从设备数据在此刻有效
                            sclk <= 1'b1;
                            if (st == S_RD)
                                rdsh <= {rdsh[14:0], miso};
                        end else begin
                            // 下降沿：更新 MOSI / 推进位计数
                            sclk <= 1'b0;
                            if (st == S_CMD) begin
                                if (bcnt == 5'd7) begin
                                    st   <= S_RD;
                                    bcnt <= 5'd0;
                                    mosi <= 1'b0;
                                end else begin
                                    bcnt  <= bcnt + 5'd1;
                                    shcmd <= {shcmd[6:0], 1'b0};
                                    mosi  <= shcmd[6];
                                end
                            end else begin
                                if (bcnt == 5'd15)
                                    st <= S_DONE;
                                else
                                    bcnt <= bcnt + 5'd1;
                            end
                        end
                    end
                end

                S_DONE: begin
                    cs_n <= 1'b1;
                    sclk <= 1'b0;
                    raw  <= rdsh;
                    data <= rdsh[14:3];     // 去掉 NULL 位，取 12bit 结果
                    done <= 1'b1;
                    st   <= S_IDLE;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
