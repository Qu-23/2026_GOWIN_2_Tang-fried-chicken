//===============================================================
// 双路 UART RX 仲裁器 —— 给蓝牙模块预留第二路串口
//
//  2026-10-23 新增。动机:
//   赛题拓展第 4 条提到「可搭载蓝牙模块与手机 App 联动」。蓝牙串口模块
//   (HC-05 / JDY-31 / ESP32 透传) 本质就是一根 TTL 串口, 电平/波特率对上
//   就能把网页发的 [0xA5][cmd][note][vel] 原样送进 FPGA, 不需要改协议。
//   所以硬件上只要再加一路 RX, 软件上把两路合成一路喂给现有 uart_rx。
//
//   为什么不能简单地把两根线「线与」(AND) 到一起:
//     两路空闲都是高电平, AND 确实能工作; 但两边同时发送时会互相
//     拉低, 帧被破坏, 而且损坏的帧可能恰好凑出 0xA5 帧头, 触发乱音。
//     这个仲裁器改成「谁先拉低就锁定谁, 直到它回到空闲才释放」,
//     冲突时后到的那一路整帧被丢弃, 不会产生半截帧。
//
//   资源: 约 30 LUT, 无 BRAM/DSP。BT_ON=0 时整个模块不被例化。
//
// 时序: 用 clk_1p5m (1.59MHz)。释放判据是「线路连续 IDLE_CLR 个时钟为高」,
//       IDLE_CLR=160 约 100us, 比 115200 下一个字节 (87us) 略长,
//       保证一帧 4 字节之间不会被误判为「已空闲」而切到另一路。
//===============================================================
module uart_arb #(
    parameter integer IDLE_CLR = 160      // 连续高电平多少个 clk 算「线路空闲」
)(
    input  wire clk,
    input  wire rst_n,
    input  wire rx_a,        // 有线串口 (BL616 USB-UART)
    input  wire rx_b,        // 蓝牙模块 TX
    output wire rx_o,        // 送 uart_rx 的那一路
    output wire sel_b        // 当前锁定在 B (蓝牙) —— 仅用于调试/指示
);

    localparam [1:0] S_IDLE = 2'd0,   // 两路都空闲, 等谁先拉低
                     S_A    = 2'd1,   // 锁定 A
                     S_B    = 2'd2;   // 锁定 B

    reg [1:0]  st;
    reg [7:0]  hi_cnt;                // 锁定后连续高电平计数
    reg        sel_b_r;

    wire hi_a = rx_a;
    wire hi_b = rx_b;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st      <= S_IDLE;
            hi_cnt  <= 8'd0;
            sel_b_r <= 1'b0;
        end else begin
            case (st)
            S_IDLE: begin
                hi_cnt <= 8'd0;
                // 谁先拉低就先服务谁; 同时拉低时优先有线串口 (A)
                if      (!hi_a) begin st <= S_A; sel_b_r <= 1'b0; end
                else if (!hi_b) begin st <= S_B; sel_b_r <= 1'b1; end
            end
            S_A: begin
                sel_b_r <= 1'b0;
                if (hi_a) begin
                    if (hi_cnt == IDLE_CLR[7:0]) begin st <= S_IDLE; hi_cnt <= 8'd0; end
                    else hi_cnt <= hi_cnt + 8'd1;
                end
                else hi_cnt <= 8'd0;
            end
            S_B: begin
                sel_b_r <= 1'b1;
                if (hi_b) begin
                    if (hi_cnt == IDLE_CLR[7:0]) begin st <= S_IDLE; hi_cnt <= 8'd0; end
                    else hi_cnt <= hi_cnt + 8'd1;
                end
                else hi_cnt <= 8'd0;
            end
            default: st <= S_IDLE;
            endcase
        end
    end

    // 空闲时输出高 (UART 空闲态), 避免 uart_rx 看到假起始位
    assign rx_o  = (st == S_A) ? rx_a :
                   (st == S_B) ? rx_b : 1'b1;
    assign sel_b = sel_b_r;

endmodule
