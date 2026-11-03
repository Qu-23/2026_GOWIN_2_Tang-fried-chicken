//////////////////////////////////////////////////////////////////////////////////
// Module Name : keypad_scan
// Description : 12 键 CdS 光电矩阵扫描 (4 行 one-hot x 3 列数字输入) — v7
//
//   电路 (每键 = 1 个 CdS 光敏电阻, 琴键下装挡光片):
//     行 KEYPAD_ROW[3:0] : 3.3V one-hot 推挽驱动, 未选行 Hi-Z (防鬼影)
//     列 KEYPAD_COL[2:0] : 各接 47k 下拉到 GND, FPGA 数字输入
//     键: 行(x) -> CdS -> 列(y), 键号 k = row*3 + col (0..11)
//
//   电气: 松开(照明亮阻 2~10k) => 列压 2.4~3.1V => col=1
//         按下(挡光暗阻 1M+)   => 列压 ~0.15V   => col=0
//     底部照明 (LAMP) 必须常开, 保证亮阻足够低!
//
//   时序: 每行保持 ROW_HOLD_US (含建立), 4 行一圈 80us => 12.5kHz 刷新
//         CdS 的光响应 (20~100ms) 与扫描解耦, 扫描只读电气状态
//   去抖: 连续 DBNC_ROWS 圈 raw 一致才更新 stable, 更新时按沿生成事件
//   事件: note_on/off 脉冲流 (多键同变逐个发), note = NOTE_BASE + 键号
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps

module keypad_scan #(
    parameter       CLK_HZ      = 9_000_000,
    parameter       ROW_HOLD_US = 20,       // 每行保持 20us
    parameter       DBNC_ROWS   = 4,        // 连续 4 圈一致才确认
    parameter [6:0] NOTE_BASE   = 7'd60     // 键 0 = C4 (60), 12 半音到 B4 (71)
)(
    input  wire        clk,
    input  wire        rst_n,

    output reg  [3:0]  row_onehot,   // 内部 one-hot (top 负责三态化到引脚)
    input  wire [2:0]  col_in,       // 列数字输入: 1=该列无键按下

    output reg         ev_vld,       // 单拍事件脉冲
    output reg         ev_on,        // 1=note_on, 0=note_off
    output reg  [6:0]  ev_note,      // NOTE_BASE + 键号
    output reg  [11:0] key_pressed   // 去抖后键位图, 1=按下
);

    localparam [15:0] HOLD_CYC = ROW_HOLD_US * (CLK_HZ / 1_000_000);

    //==============================================================
    // 行扫描
    //==============================================================
    reg [1:0]  row_i;
    reg [15:0] cnt;
    reg [11:0] raw;                    // 本圈累积 (1=按下)

    wire       circle_end = (cnt == HOLD_CYC - 16'd1) && (row_i == 2'd3);
    wire [1:0] row_nxt    = row_i + 2'd1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_i      <= 2'd0;
            cnt        <= 16'd0;
            raw        <= 12'h000;     // 0=无按下 (raw 位: 1=按下)
            row_onehot <= 4'b0001;
        end else if (cnt >= HOLD_CYC - 16'd1) begin
            cnt <= 16'd0;
            // 行保持期结束: 采样本行 3 列 (建立时间已过)
            // 键位图布局: 键 k=row*3+col => 行 r 占 raw[3r +: 3]
            raw[row_i * 3 +: 3] <= ~col_in;   // col=0 -> 按下 -> 1
            row_i      <= row_nxt;
            row_onehot <= 4'b0001 << row_nxt;
        end else begin
            cnt <= cnt + 16'd1;
        end
    end

    //==============================================================
    // 去抖: 连续 DBNC_ROWS 圈一致 -> 锁定 stable
    //==============================================================
    reg [11:0] stable;
    reg [11:0] pend;
    reg [1:0]  same;

    //==============================================================
    // 事件队列: 按沿位图, 逐拍发射
    //==============================================================
    reg [11:0] p_on, p_off;

    wire circle_confirm = circle_end && (raw == pend) &&
                          (same == DBNC_ROWS[1:0] - 2'd1) && (raw != stable);

    // 找最低位的 1 (12bit)
    function [3:0] low_bit;
        input [11:0] v;
        integer i;
        reg found;
        begin
            low_bit = 4'd0;
            found   = 1'b0;
            for (i = 0; i < 12; i = i + 1)
                if (!found && v[i]) begin
                    low_bit = i[3:0];
                    found   = 1'b1;
                end
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stable      <= 12'd0;
            pend        <= 12'h000;
            same        <= 2'd0;
            p_on        <= 12'd0;
            p_off       <= 12'd0;
            ev_vld      <= 1'b0;
            ev_on       <= 1'b0;
            ev_note     <= 7'd0;
            key_pressed <= 12'd0;
        end else begin
            ev_vld <= 1'b0;

            if (circle_end) begin
                if (raw == pend) begin
                    if (same == DBNC_ROWS[1:0] - 2'd1) begin
                        if (raw != stable) begin
                            stable      <= raw;
                            key_pressed <= raw;
                            p_on        <= p_on  | ( raw & ~stable);
                            p_off       <= p_off | (~raw &  stable);
                        end
                        // raw==stable: 稳态, 无动作 (same 保持)
                    end else begin
                        same <= same + 2'd1;
                    end
                end else begin
                    pend <= raw;       // 新观测, 第 1 次计数
                    same <= 2'd1;
                end
            end else if (p_on != 12'd0) begin
                ev_vld  <= 1'b1;
                ev_on   <= 1'b1;
                ev_note <= NOTE_BASE + {1'b0, low_bit(p_on)};
                p_on    <= p_on & ~(12'd1 << low_bit(p_on));
            end else if (p_off != 12'd0) begin
                ev_vld  <= 1'b1;
                ev_on   <= 1'b0;
                ev_note <= NOTE_BASE + {1'b0, low_bit(p_off)};
                p_off   <= p_off & ~(12'd1 << low_bit(p_off));
            end
        end
    end

endmodule
