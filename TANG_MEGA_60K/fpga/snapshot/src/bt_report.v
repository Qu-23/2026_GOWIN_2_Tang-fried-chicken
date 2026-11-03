//=======================================================================
// bt_report —— 演奏事件回传 (2026-11-02)
//
// 每次按下/松开都从蓝牙发回一行可读文本, 手机端存下来就是一份等价 MIDI 记录
// (赛题拓展④ "演奏录音回传")。
//
// 固定宽度格式 (行尾 CR LF), 一共 13 字节:
//     <E|O><nn>,<vvv>,<ddd>
//     E60,200,000     按下 60 号音, 力度 200, 距上次事件 0 ms
//     O60,000,523     松开 60 号音, 力度 0,   距上次事件 523 ms
//
//   nn  = 音高两位 (0..99, 本工程音域 60..84)
//   vvv = 力度三位
//   ddd = 距上次事件的毫秒数三位 (钳在 999)
//
// 为什么固定宽度: 不用前导零抑制、不用变长状态机, 手机端也最好解析。
// 为什么发相对时间: MIDI 本来就是 delta time, 且 0..999 只需三次比较取位。
//=======================================================================
`default_nettype none

module bt_report #(
    parameter integer CLK_PER_BIT = 14
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       tick,        // 99.3 kHz
    input  wire       fire,        // 单拍脉冲: 有事件
    input  wire       is_on,       // 1 = note on, 0 = note off
    input  wire [7:0] note,
    input  wire [7:0] vel,
    output wire       tx,
    output reg        active       // 1 = 正在发报, 上层据此屏蔽心跳
);

    // ---------------- 事件锁存 (声明放在使用之前, 避免隐式 1-bit 线网) -------
    reg        busy;
    reg        ev_on;
    reg [7:0]  ev_note;
    reg [7:0]  ev_vel;
    reg [9:0]  ev_dt;
    reg [3:0]  idx;
    reg        send_r;

    // ---------------- 毫秒计数 (tick/100 ≈ 993 Hz) ----------------
    // ms 只能有一个驱动块: 清零走 ms_clr 脉冲, 不再在事件锁存块里赋值
    wire ms_clr = fire && !busy;
    reg [6:0] tdiv;
    reg [9:0] ms;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tdiv <= 7'd0;
            ms   <= 10'd0;
        end else if (ms_clr) begin
            tdiv <= 7'd0;
            ms   <= 10'd0;
        end else if (tick) begin
            if (tdiv == 7'd99) begin
                tdiv <= 7'd0;
                if (ms != 10'd999) ms <= ms + 10'd1;
            end else begin
                tdiv <= tdiv + 7'd1;
            end
        end
    end

    // ---------------- 十进制取位 (比较链, 无除法) ----------------
    function [3:0] digit_of;
        input [9:0] v;
        input [1:0] k;      // 0=百位 1=十位 2=个位
        reg [3:0]  hh, tt;
        reg [9:0]  rem;
        reg [3:0]  uu;
        begin
            hh = 4'd0;
            if      (v >= 10'd900) hh = 4'd9;
            else if (v >= 10'd800) hh = 4'd8;
            else if (v >= 10'd700) hh = 4'd7;
            else if (v >= 10'd600) hh = 4'd6;
            else if (v >= 10'd500) hh = 4'd5;
            else if (v >= 10'd400) hh = 4'd4;
            else if (v >= 10'd300) hh = 4'd3;
            else if (v >= 10'd200) hh = 4'd2;
            else if (v >= 10'd100) hh = 4'd1;

            rem = v - (hh * 10'd100);

            tt = 4'd0;
            if      (rem >= 10'd90) tt = 4'd9;
            else if (rem >= 10'd80) tt = 4'd8;
            else if (rem >= 10'd70) tt = 4'd7;
            else if (rem >= 10'd60) tt = 4'd6;
            else if (rem >= 10'd50) tt = 4'd5;
            else if (rem >= 10'd40) tt = 4'd4;
            else if (rem >= 10'd30) tt = 4'd3;
            else if (rem >= 10'd20) tt = 4'd2;
            else if (rem >= 10'd10) tt = 4'd1;

            uu = rem[3:0] - (tt * 4'd10);   // rem<100, 个位 <10

            digit_of = (k == 2'd0) ? hh : (k == 2'd1) ? tt : uu;
        end
    endfunction

    wire [9:0] n_note = {3'd0, ev_note};
    wire [9:0] n_vel  = {2'd0, ev_vel};

    // ---------------- 逐字节发送 ----------------
    wire tx_busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy    <= 1'b0;
            ev_on   <= 1'b0;
            ev_note <= 8'd60;
            ev_vel  <= 8'd0;
            ev_dt   <= 10'd0;
            idx     <= 4'd0;
            send_r  <= 1'b0;
            active  <= 1'b0;
        end else begin
            send_r <= 1'b0;
            if (fire && !busy) begin
                busy    <= 1'b1;
                active  <= 1'b1;
                idx     <= 4'd0;
                ev_on   <= is_on;
                ev_note <= note;
                ev_vel  <= vel;
                ev_dt   <= ms;
            end else if (busy && !tx_busy) begin
                if (idx == 4'd12) begin       // 已发完 13 个字节
                    busy   <= 1'b0;
                    active <= 1'b0;
                    idx    <= 4'd0;
                end else begin
                    send_r <= 1'b1;
                    idx    <= idx + 4'd1;
                end
            end
        end
    end

    // ------------- 本拍要发的字节: <E|O><nn>,<vvv>,<ddd> -------------
    reg [7:0] byte_now;
    always @* begin
        case (idx)
            4'd0:  byte_now = ev_on ? 8'h45 : 8'h4F;                        // 'E' / 'O'
            4'd1:  byte_now = 8'h30 + digit_of(n_note, 2'd1);               // 十位
            4'd2:  byte_now = 8'h30 + digit_of(n_note, 2'd2);               // 个位
            4'd3:  byte_now = 8'h2C;                                        // ','
            4'd4:  byte_now = 8'h30 + digit_of(n_vel, 2'd0);
            4'd5:  byte_now = 8'h30 + digit_of(n_vel, 2'd1);
            4'd6:  byte_now = 8'h30 + digit_of(n_vel, 2'd2);
            4'd7:  byte_now = 8'h2C;                                        // ','
            4'd8:  byte_now = 8'h30 + digit_of(ev_dt, 2'd0);
            4'd9:  byte_now = 8'h30 + digit_of(ev_dt, 2'd1);
            4'd10: byte_now = 8'h30 + digit_of(ev_dt, 2'd2);
            4'd11: byte_now = 8'h0D;                                        // CR
            default: byte_now = 8'h0A;                                      // LF
        endcase
    end

    uart_tx #(.CLK_PER_BIT(CLK_PER_BIT)) u_tx (
        .clk(clk), .rst_n(rst_n), .tick(1'b1), .send(send_r), .byte_in(byte_now),
        .tx(tx), .busy(tx_busy));

endmodule

`default_nettype wire
