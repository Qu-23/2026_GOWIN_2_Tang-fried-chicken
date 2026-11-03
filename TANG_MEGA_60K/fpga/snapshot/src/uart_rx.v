//===============================================================
// uart_rx - 串口音符接收 (网页 <-> 板卡)
//
// 时钟: clk_1p5m_w = 1.59MHz
// 波特率: 115200 8N1
//   CLK/BAUD = 1590000/115200 = 13.80 -> 取 14 clk/bit (误差 +1.4%, 在 ±2% 容限内)
//   10 bit 累积偏差 0.14 bit, 在 bit 中点采样安全。
//
// 协议 (4 字节, 4x87us = 348us, 远低于赛题 10ms 延迟要求):
//   [0xA5]  帧头
//   [cmd ]  bit7 = 1 -> note_on, 0 -> note_off
//           bit[1:0] = 波形选择 (0=电钢 1=拨弦 2=贝斯 3=铺底)
//           bit[3:2] =  电钢候选 A/B/C (仅波形 0 有效)
//           bit[5:4] =  颤音深度 0=关 1=浅 2=中 3=深 (第三表情维度)
//           bit6 = 1 -> 这是控制帧, 不是音符帧, 分三种:
//                  a) note[7]=0, note[6]=0 -> 效果器帧:
//                       [note] = fx_sel[1:0] | mix_sel[3:2] | rev_size[5:4]
//                       [vel ] = 延迟长度 (单位 0.65ms, 0=用默认 60ms)
//                  b) note[7]=1 -> 表情帧 (2026-10-23 加, 滑音/颤音):
//                       [note] = glide_sel[1:0] | vib_sel[3:2]
//                       [vel ] = 保留
//                  c) note[7]=0, note[6]=1 ->  测试模式帧 (2026-10-28 加):
//                       [note] bit0 = 1 进测试模式 / 0 回演奏模式
//                       [vel ] = 保留
//                      用 note[6] 区分是向后兼容的: 效果器帧的 note
//                       最大只到 0x3F (fx_sel|mix|rev 只占 bit5:0),
//                       而表情帧占 bit7, 剩下的 bit6 正好空着。
//                      有了运行期切换, 现场验「多路谱峰」不用重烧固件,
//                       按一下网页/上位机的按钮即可 (赛题要求的是"支持
//                       测试模式", 没规定必须编译期固化)。
//   [note]  0..24  (C4..C6)
//   [vel ]  0..255 力度
//
// 输出: note_on/note_off 在 tick 拍给出 1 拍脉冲, 直接接 synth_engine。
//===============================================================
module uart_rx #(
    //  2026-11-01: 14 (=113.6kbaud) -> 166 (=9.6kbaud)
    //   JDY-31 出厂 9600 且改不动 (AT 进不去), 于是让 FPGA 迁就它。
    //   代价: 4 字节音符帧 347us -> 4.17ms, 总延迟 2.4ms -> 6.2ms (仍 <10ms)。
    //   1.59MHz/166 = 9578 baud, 对 9600 误差 -0.23%, 安全。
    parameter integer CLK_PER_BIT = 166,
    parameter [7:0]   HDR         = 8'hA5
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       tick,                 // 99.3kHz
    input  wire       rx,                   // UART RX (空闲高)

    output reg        note_on,
    output reg        note_off,
    output reg [4:0]  note_idx,
    output reg [7:0]  velocity,
    output reg [1:0]  wave_sel,
    output reg [1:0]  ep_sel,               //  电钢候选 A/B/C
    output reg [1:0]  vib_sel,              //  颤音深度 0=关 1=浅 2=中 3=深
    output reg [1:0]  glide_sel,            //  滑音速度 0=关 1=40ms 2=80ms 3=160ms
    output reg        fx_vld,               //  效果器控制帧有效 (单拍)
    output reg [7:0]  fx_note,              //  fx_sel/mix_sel/rev_size 打包
    output reg [7:0]  fx_vel,               //  延迟长度
    output reg        tst_mode,             //  2026-10-28 测试模式运行期开关

    output reg        rx_led,               // 接收活动指示
    output reg [7:0]  frame_cnt             // 调试: 已收完整帧数
);

    //===========================================================
    // 1) 输入同步 (2 级)
    //===========================================================
    reg rx_s0, rx_s1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rx_s0 <= 1'b1; rx_s1 <= 1'b1; end
        else        begin rx_s0 <= rx;   rx_s1 <= rx_s0; end
    end
    wire rx_i = rx_s1;

    //===========================================================
    // 2) 位采样状态机
    //===========================================================
    localparam [2:0] S_IDLE = 3'd0, S_START = 3'd1, S_DATA = 3'd2, S_STOP = 3'd3;

    reg [2:0] st;
    //  2026-11-01: 4 bit -> 8 bit。CLK_PER_BIT=166 时 4 bit 只能数到 15,
    //   比较永远不成立 => 一个字节都收不到, 综合器把整条 UART 链全优化掉
    //   (WARN NL0002 swept: uart_arb / fx_engine 全部消失)。
    reg [7:0] bcnt;             // bit 内计数
    reg [2:0] bitn;             // 数据位序号
    reg [7:0] sh;               // 移位寄存器

    reg [7:0] byte_r;           // 收满一字节
    reg       byte_vld;         // 1 clk 脉冲

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; bcnt <= 8'd0; bitn <= 3'd0; sh <= 8'd0;
            byte_r <= 8'd0; byte_vld <= 1'b0;
        end
        else begin
            byte_vld <= 1'b0;
            case (st)
            S_IDLE: if (!rx_i) begin
                        bcnt <= 8'd0;
                        st   <= S_START;
                    end
            S_START: begin
                if (bcnt == (CLK_PER_BIT/2 - 1)) begin
                    bcnt <= 8'd0;
                    if (!rx_i) begin
                        bitn <= 3'd0;
                        st   <= S_DATA;
                    end
                    else
                        st <= S_IDLE;            // 毛刺, 回空闲
                end
                else
                    bcnt <= bcnt + 8'd1;
            end
            S_DATA: begin
                if (bcnt == CLK_PER_BIT - 1) begin
                    bcnt <= 8'd0;
                    sh   <= {rx_i, sh[7:1]};     // LSB first
                    if (bitn == 3'd7) st <= S_STOP;
                    else              bitn <= bitn + 3'd1;
                end
                else
                    bcnt <= bcnt + 8'd1;
            end
            S_STOP: begin
                if (bcnt == CLK_PER_BIT - 1) begin
                    bcnt     <= 4'd0;
                    byte_r   <= sh;
                    byte_vld <= 1'b1;
                    st       <= S_IDLE;
                end
                else
                    bcnt <= bcnt + 8'd1;
            end
            default: st <= S_IDLE;
            endcase
        end
    end

    //===========================================================
    // 3) 字节 -> 帧解析 (HDR, cmd, note, vel)
    //===========================================================
    reg [1:0] pc;                       // 帧内位置
    reg [7:0] cmd_r, note_r;

    // 待发事件 (在 tick 拍送给引擎)
    reg       pend_vld, pend_on;
    reg [4:0] pend_note;
    reg [7:0] pend_vel;
    reg [1:0] pend_wave;
    reg [1:0] pend_ep;
    reg [1:0] pend_vib;
    reg [1:0] pend_glide;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc <= 2'd0; cmd_r <= 8'd0; note_r <= 8'd0;
            pend_vld <= 1'b0; pend_on <= 1'b0;
            pend_note <= 5'd0; pend_vel <= 8'd0; pend_wave <= 2'd0; pend_ep <= 2'd0;
            pend_vib  <= 2'd0;
            pend_glide <= 2'd0;
            frame_cnt <= 8'd0; rx_led <= 1'b0;
            note_on <= 1'b0; note_off <= 1'b0;
            note_idx <= 5'd0; velocity <= 8'd0; wave_sel <= 2'd0; ep_sel <= 2'd0;
            vib_sel  <= 2'd0;
            glide_sel <= 2'd0;
            fx_vld   <= 1'b0; fx_note <= 8'd0; fx_vel <= 8'd0;
            tst_mode <= 1'b0;
        end
        else begin
            fx_vld <= 1'b0;
            // 接收指示
            if (byte_vld)          rx_led <= 1'b1;
            else if (tick && rx_led) rx_led <= 1'b0;

            //---- 字节解析 ----
            if (byte_vld) begin
                case (pc)
                2'd0: if (byte_r == HDR) pc <= 2'd1;    // 等帧头, 否则丢弃
                2'd1: begin cmd_r  <= byte_r; pc <= 2'd2; end
                2'd2: begin note_r <= byte_r; pc <= 2'd3; end
                2'd3: begin
                          pc <= 2'd0;
                          frame_cnt <= frame_cnt + 8'd1;
                          pend_vld  <= 1'b1;
                          pend_on   <= cmd_r[7];
                          //  2026-10-19: 回退到 25 音表。
                          //   note 字节仍是 MIDI 音符号 (网页发的就是 MIDI),
                          //   这里转成表索引 0..24 = MIDI 60..84 = C4..C6。
                          //   超出范围钳位, 不再像原来那样 5bit 截断
                          //   (截断会把高音绕回低音, 听起来像走调)。
                          pend_note <= (note_r < 8'd60) ? 5'd0  :
                                       (note_r > 8'd84) ? 5'd24 :
                                       (note_r[4:0] - 5'd28);
                          pend_vel  <= byte_r;
                          pend_wave <= cmd_r[1:0];
                          pend_ep   <= cmd_r[3:2];
                          pend_vib  <= cmd_r[5:4];
                          //  控制帧: cmd[6]=1, 不当音符处理。
                          //   note[7]=1 -> 表情帧(滑音+颤音); 否则 -> 效果器帧。
                          if (cmd_r[6]) begin
                              pend_vld <= 1'b0;      // 撤销这一帧的音符事件
                              if (note_r[7]) begin
                                  // 表情帧: 不改音色/音高, 只更新表情参数
                                  glide_sel <= note_r[1:0];
                                  vib_sel   <= note_r[3:2];
                              end
                              else if (note_r[6]) begin
                                  //  测试模式帧: note[0]=1 进, 0 回演奏
                                  tst_mode <= note_r[0];
                              end
                              else begin
                                  fx_vld   <= 1'b1;
                                  fx_note  <= note_r;
                                  fx_vel   <= byte_r;
                              end
                          end
                      end
                endcase
            end

            //---- tick 拍发出事件 ----
            note_on  <= 1'b0;
            note_off <= 1'b0;
            if (tick) begin
                if (pend_vld) begin
                    note_idx <= pend_note;
                        wave_sel <= pend_wave;
                        ep_sel   <= pend_ep;
                        vib_sel  <= pend_vib;

                    if (pend_on) begin
                        note_on  <= 1'b1;
                        velocity <= pend_vel;
                    end
                    else
                        note_off <= 1'b1;
                    pend_vld <= 1'b0;
                end
            end
        end
    end

endmodule
