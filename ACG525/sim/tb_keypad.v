//////////////////////////////////////////////////////////////////////////////////
// Module Name : tb_keypad
// Description : 12 键 CdS 矩阵扫描 TB — 完整电气模拟 (含松开键亮阻导通)
//   列电平模型: col[c] = OR(选中行 & 该键松开)
//     选中行 + 松开键(亮阻导通) => 列高; 选中行 + 按下键(暗阻) => 列低
//   场景:
//     ① 复位后 6 圈无事件、key_pressed=0
//     ② 按键 5 (row1,col2) -> 去抖后 ev_on 65, key_pressed[5]=1
//     ③ 释放键 5 -> ev_off 65
//     ④ 同时按 0 与 11 -> ev_on 60 与 71
//     ⑤ 抖动 (按住 <1 圈即松) -> 无事件
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps

module tb_keypad;

    reg  clk = 1'b0;
    reg  rst_n = 1'b0;
    wire [3:0] row_onehot;
    wire [2:0] col_in;
    wire        ev_vld, ev_on;
    wire [6:0]  ev_note;
    wire [11:0] key_pressed;

    // TB 按键状态: 1=按下
    reg [11:0] key_state = 12'd0;

    always #55 clk = ~clk;              // ~9.09 MHz (标称 9 MHz, 1% 偏差无碍)

    keypad_scan #(
        .CLK_HZ      (9_000_000),
        .ROW_HOLD_US (20),
        .DBNC_ROWS   (4),
        .NOTE_BASE   (7'd60)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .row_onehot  (row_onehot),
        .col_in      (col_in),
        .ev_vld      (ev_vld),
        .ev_on       (ev_on),
        .ev_note     (ev_note),
        .key_pressed (key_pressed)
    );

    //---------------- 列电平电气模拟 ----------------
    // ps[c][r] = key_state[r*3+c] (1=按下)
    wire [3:0] ps0 = {key_state[9],  key_state[6], key_state[3], key_state[0]};
    wire [3:0] ps1 = {key_state[10], key_state[7], key_state[4], key_state[1]};
    wire [3:0] ps2 = {key_state[11], key_state[8], key_state[5], key_state[2]};
    // col=1 当且仅当: 选中行上该键为松开 (亮阻导通拉高)
    assign col_in[0] = |(row_onehot & ~ps0);
    assign col_in[1] = |(row_onehot & ~ps1);
    assign col_in[2] = |(row_onehot & ~ps2);

    //---------------- 事件捕获 (negedge 采样防 NBA 竞态) ----------------
    reg [7:0] evq [0:15];
    reg [7:0] evq_t;                    // bit0=on, 同字节记 note
    integer   evn = 0;
    always @(negedge clk) begin
        if (ev_vld && evn < 16) begin
            evq[evn] = ev_note;
            evq_t[evn] = ev_on;
            $display("[%0t] EV#%0d %s note=%0d", $time, evn, ev_on ? "ON " : "OFF", ev_note);
            evn = evn + 1;
        end
    end

    //---------------- 检查辅助 ----------------
    integer errors = 0;
    task expect_eq(input [31:0] got, input [31:0] exp, input [127:0] tag);
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL %0s: got=%0d exp=%0d", tag, got, exp);
            end
        end
    endtask

    localparam CIRCLE = 720;            // 4 行 x 180 clk
    integer k;

    initial begin
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;

        // ① 复位后 6 圈: 无事件, key_pressed=0
        repeat (6 * CIRCLE) @(posedge clk);
        expect_eq(evn, 0, "s1.no_ev");
        expect_eq(key_pressed, 12'd0, "s1.map0");
        $display("PASS-1: reset state clean");

        // ② 按键 5 (row1,col2), 等 5 圈 (去抖 4 圈 + 裕量)
        key_state[5] = 1'b1;
        repeat (6 * CIRCLE) @(posedge clk);
        expect_eq(key_pressed[5], 1'b1, "s2.pressed5");
        expect_eq(evn, 1, "s2.ev1");
        expect_eq(evq_t[0], 1'b1, "s2.on");
        expect_eq(evq[0], 8'd65, "s2.note65");
        $display("PASS-2: key5 on -> note 65");

        // ③ 释放键 5
        key_state[5] = 1'b0;
        repeat (6 * CIRCLE) @(posedge clk);
        expect_eq(key_pressed[5], 1'b0, "s3.rel5");
        expect_eq(evn, 2, "s3.ev2");
        expect_eq(evq_t[1], 1'b0, "s3.off");
        expect_eq(evq[1], 8'd65, "s3.note65off");
        $display("PASS-3: key5 off -> note 65");

        // ④ 同时按 0 与 11 -> 2 个 on (60 先, 71 后, 按位序)
        key_state[0] = 1'b1;
        key_state[11] = 1'b1;
        repeat (6 * CIRCLE) @(posedge clk);
        expect_eq(key_pressed[0], 1'b1, "s4.p0");
        expect_eq(key_pressed[11], 1'b1, "s4.p11");
        expect_eq(evn, 4, "s4.ev4");
        expect_eq(evq_t[2], 1'b1, "s4.on0");
        expect_eq(evq[2], 8'd60, "s4.note60");
        expect_eq(evq_t[3], 1'b1, "s4.on11");
        expect_eq(evq[3], 8'd71, "s4.note71");
        $display("PASS-4: key0+key11 -> 60 & 71");

        // ⑤ 抖动: 按 1 圈即松 (远小于去抖 4 圈) -> 无新事件
        key_state[7] = 1'b1;
        repeat (1 * CIRCLE) @(posedge clk);
        key_state[7] = 1'b0;
        repeat (4 * CIRCLE) @(posedge clk);
        expect_eq(evn, 4, "s5.no_bounce_ev");
        expect_eq(key_pressed[7], 1'b0, "s5.no_press7");
        $display("PASS-5: bounce rejected");

        // ⑥ 释放 0/11 -> 2 个 off (60 先, 71 后)
        key_state[0] = 1'b0;
        key_state[11] = 1'b0;
        repeat (6 * CIRCLE) @(posedge clk);
        expect_eq(evn, 6, "s6.ev6");
        expect_eq(evq[4], 8'd60, "s6.off60");
        expect_eq(evq[5], 8'd71, "s6.off71");
        expect_eq(key_pressed, 12'd0, "s6.map0");
        $display("PASS-6: release all");

        $display("==== tb_keypad: %s ====", (errors == 0) ? "ALL PASS" : "HAS FAILURES");
        $finish;
    end

    initial begin
        #20_000_000;                    // 20ms 超时
        $display("==== TIMEOUT ====");
        $finish;
    end

endmodule
