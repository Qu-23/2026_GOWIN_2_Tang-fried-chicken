//////////////////////////////////////////////////////////////////////////////////
// Module Name : touch_ctrl
// Description : 触摸采样控制 + 坐标滤波 + 校准映射
//
//   1) 每 POLL_CYC 个时钟（默认 10ms @33MHz）轮询一次 XPT2046：
//        X(0xD0) -> Y(0x90) -> Z1(0xB0) -> Z2(0xC0)
//   2) 采样值做“泄漏积分平均”滤波：acc = acc - acc/8 + new，等效 8 点滑动平均
//   3) 用 X_MIN/X_MAX、Y_MIN/Y_MAX 把 12bit ADC 值线性映射到 800x480 像素坐标
//   4) 触摸判定：PRESS_MODE=0 只用 PENIRQ(低有效)；=1 只用 Z1 阈值；=2 两者取或
//
//   注意：宏定义的整数常量除法在综合时会被常量折叠，不会产生除法器
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps

module touch_ctrl #(
    parameter        SCREEN_W = 480,         // 屏幕分辨率（4.3寸 480x272 / 5寸 800x480）
    parameter        SCREEN_H = 272,
    parameter [11:0] X_MIN    = 12'd200,     // X 方向原始值下限（校准）
    parameter [11:0] X_MAX    = 12'd3900,    // X 方向原始值上限（校准）
    parameter [11:0] Y_MIN    = 12'd200,
    parameter [11:0] Y_MAX    = 12'd3900,
    parameter        X_INVERT = 1'b0,        // 1 = X 方向左右翻转
    parameter        Y_INVERT = 1'b0,        // 1 = Y 方向上下翻转
    parameter        PRESS_MODE = 2'd0,      // 0:IRQ  1:Z1  2:IRQ|Z1
    parameter [11:0] Z_THRESH = 12'd2500,    // Z1 小于该值认为有按压
    parameter [19:0] POLL_CYC = 20'd90_000   // 轮询周期（9MHz 下 10ms）
)(
    input  wire        clk,
    input  wire        rst_n,

    //--- 与 touch_xpt2046 的接口 ---
    output reg  [7:0]  adc_cmd,
    output reg         adc_start,
    input  wire [11:0] adc_data,
    input  wire        adc_done,

    //--- 给上层的坐标与状态 ---
    output reg  [9:0]  pos_x,       // 像素坐标 0~479（松开后保持最后位置）
    output reg  [9:0]  pos_y,       // 像素坐标 0~271
    output reg         pressed,     // 去抖后的按压状态
    output reg         new_touch,   // 按下瞬间的单周期脉冲
    output wire [11:0] raw_x,       // 滤波后的原始 X（状态栏条形图用）
    output wire [11:0] raw_y,       // 滤波后的原始 Y
    output wire [11:0] raw_z1,      // Z1 原始值（调试）

    //--- 触摸面板中断（低有效） ---
    input  wire        irq_n
);

    //--------------------------------------------------------------
    // 校准参数 -> 定点比例系数
    //   px = (raw - MIN) * SCALE >> 12
    //   SCALE = 目标分辨率 * 4096 / (MAX - MIN)
    //--------------------------------------------------------------
    localparam integer XRANGE = (X_MAX > X_MIN) ? (X_MAX - X_MIN) : 1;
    localparam integer YRANGE = (Y_MAX > Y_MIN) ? (Y_MAX - Y_MIN) : 1;
    localparam [31:0]  XSCALE = (SCREEN_W * 4096) / XRANGE;
    localparam [31:0]  YSCALE = (SCREEN_H * 4096) / YRANGE;

    //--------------------------------------------------------------
    // 轮询定时器
    //--------------------------------------------------------------
    reg [19:0] poll_cnt;
    wire       poll_tick = (poll_cnt == (POLL_CYC - 1'b1));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            poll_cnt <= 20'd0;
        else if (poll_tick)    poll_cnt <= 20'd0;
        else                   poll_cnt <= poll_cnt + 20'd1;
    end

    //--------------------------------------------------------------
    // 采样状态机
    //--------------------------------------------------------------
    localparam [2:0] S_IDLE = 3'd0,
                     S_X    = 3'd1,
                     S_Y    = 3'd2,
                     S_Z1   = 3'd3,
                     S_Z2   = 3'd4,
                     S_UPD  = 3'd5;

    reg [2:0]  st;
    reg [11:0] rx, ry, rz1, rz2;
    reg [15:0] xacc, yacc;
    reg [1:0]  dbnc;
    reg        pressed_d;

    wire [12:0] xavg = xacc[15:3];      // 0 ~ 4095
    wire [12:0] yavg = yacc[15:3];

    // 坐标映射 ------------------------------------------------------
    wire [31:0] xmul = (xavg > X_MIN) ? ((xavg - X_MIN) * XSCALE) : 32'd0;
    wire [31:0] ymul = (yavg > Y_MIN) ? ((yavg - Y_MIN) * YSCALE) : 32'd0;

    localparam [11:0] XMAX_RAW = SCREEN_W - 1;
    localparam [11:0] YMAX_RAW = SCREEN_H - 1;

    wire [19:0] xsh = xmul >> 12;
    wire [19:0] ysh = ymul >> 12;
    wire [11:0] xpx = (xsh > XMAX_RAW) ? XMAX_RAW : xsh[11:0];
    wire [11:0] ypx = (ysh > YMAX_RAW) ? YMAX_RAW : ysh[11:0];

    wire [9:0] xfinal = X_INVERT ? (XMAX_RAW[9:0] - xpx[9:0]) : xpx[9:0];
    wire [9:0] yfinal = Y_INVERT ? (YMAX_RAW[9:0] - ypx[9:0]) : ypx[9:0];

    // 按压判定 ------------------------------------------------------
    wire z_ok    = (rz1 < Z_THRESH);
    wire press_raw = (PRESS_MODE == 2'd0) ? (~irq_n) :
                     (PRESS_MODE == 2'd1) ? z_ok    : (~irq_n | z_ok);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st         <= S_IDLE;
            adc_cmd    <= 8'hD0;
            adc_start  <= 1'b0;
            rx         <= 12'd0;
            ry         <= 12'd0;
            rz1        <= 12'd4095;
            rz2        <= 12'd4095;
            xacc       <= 16'd0;
            yacc       <= 16'd0;
            pos_x      <= 10'd0;
            pos_y      <= 10'd0;
            pressed    <= 1'b0;
            pressed_d  <= 1'b0;
            new_touch  <= 1'b0;
            dbnc       <= 2'd0;
        end else begin
            case (st)
                //--------------------------------------------------
                S_IDLE: begin
                    adc_start <= 1'b0;
                    if (poll_tick) begin
                        adc_cmd   <= 8'hD0;     // X 位置
                        adc_start <= 1'b1;
                        st        <= S_X;
                    end
                end

                //--------------------------------------------------
                S_X: begin
                    if (adc_done) begin
                        rx        <= adc_data;
                        adc_cmd   <= 8'h90;     // Y 位置
                        adc_start <= 1'b1;
                        st        <= S_Y;
                    end else
                        adc_start <= 1'b0;
                end

                //--------------------------------------------------
                S_Y: begin
                    if (adc_done) begin
                        ry        <= adc_data;
                        adc_cmd   <= 8'hB0;     // Z1
                        adc_start <= 1'b1;
                        st        <= S_Z1;
                    end else
                        adc_start <= 1'b0;
                end

                //--------------------------------------------------
                S_Z1: begin
                    if (adc_done) begin
                        rz1       <= adc_data;
                        adc_cmd   <= 8'hC0;     // Z2
                        adc_start <= 1'b1;
                        st        <= S_Z2;
                    end else
                        adc_start <= 1'b0;
                end

                //--------------------------------------------------
                S_Z2: begin
                    if (adc_done) begin
                        rz2       <= adc_data;
                        adc_start <= 1'b0;
                        st        <= S_UPD;
                    end else
                        adc_start <= 1'b0;
                end

                //--------------------------------------------------
                S_UPD: begin
                    // 8 点滑动平均
                    xacc <= xacc - (xacc >> 3) + {4'd0, rx};
                    yacc <= yacc - (yacc >> 3) + {4'd0, ry};

                    // 有按压就持续刷新坐标
                    if (press_raw) begin
                        pos_x <= xfinal;
                        pos_y <= yfinal;
                    end

                    // 按压状态去抖：连续 2 次一致才更新
                    if (press_raw != pressed) begin
                        if (dbnc == 2'd1) begin
                            pressed <= press_raw;
                            dbnc    <= 2'd0;
                        end else
                            dbnc <= dbnc + 2'd1;
                    end else
                        dbnc <= 2'd0;

                    // 按下瞬间产生脉冲
                    new_touch <= pressed && !pressed_d;
                    pressed_d <= pressed;

                    st <= S_IDLE;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

    assign raw_x  = xavg[11:0];
    assign raw_y  = yavg[11:0];
    assign raw_z1 = rz1;

endmodule
