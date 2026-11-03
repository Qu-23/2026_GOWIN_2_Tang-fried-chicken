//////////////////////////////////////////////////////////////////////////////////
// Module Name : frame_pack
// Description : 把触摸面板事件打包成 Mega 60K 接收端要求的 4 字节帧并串出
//
//   [0xA5] [cmd] [note] [vel]      115200 8N1，一帧 348us
//
//   cmd: bit7 = 1 按下 / 0 松开
//        bit[1:0] 音色  0=电钢 1=拨弦 2=贝斯 3=铺底
//        bit[3:2] 电钢候选 A/B/C
//        bit[5:4] 颤音深度 0..3
//        bit6     = 1 控制帧
//   note: MIDI 音符号 60..84（C4..C6），对端会钳位到 0..24
//   vel : 力度 0..255
//
//   控制帧（cmd[6]=1）:
//     测试模式 : note[6]=1, note[0]=1/0 切换
//     表情帧   : note[7]=1, note[1:0]=滑音, note[3:2]=颤音
//     效果器帧 : note = fx_sel | mix<<2 | rev<<4（≤0x3F）, vel = 延迟长度
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps

module frame_pack (
    input  wire        clk,
    input  wire        rst_n,

    //--- 事件输入（来自 touch_panel，单周期脉冲）---
    input  wire        ev_vld,
    input  wire [2:0]  ev_type,      // 0=note_on 1=note_off 2=测试模式切换 3=原始控制帧
    input  wire [7:0]  ev_note,      // MIDI 音符号 / 控制帧负载
    input  wire [7:0]  ev_vel,
    input  wire        ev_tst,       // 测试模式新状态

    //--- 音色/表情配置 ---
    input  wire [1:0]  cfg_wave,
    input  wire [1:0]  cfg_ep,
    input  wire [1:0]  cfg_vib,

    //--- 串口 ---
    output wire        uart_tx_pin,
    output wire        uart_busy,
    output wire [7:0]  frame_cnt      // 已发送帧数（调试/UI）
);

    localparam [7:0] HDR = 8'hA5;

    reg [31:0] mem [0:7];
    reg [3:0]  wptr, rptr, cnt;
    reg        wr_en;
    reg [31:0] wr_word;

    reg [1:0]  st;
    reg [31:0] sh;
    reg [1:0]  bidx;
    reg [7:0]  tx_data;
    reg        tx_start;
    reg        rd_pop;
    reg [7:0]  fcnt;

    wire       uart_done;
    wire [31:0] rd_word = mem[rptr[2:0]];

    //==============================================================
    // 1) 事件 -> 32bit 帧
    //    type3 = 原始控制帧: cmd=0x40, note/vel 由面板给出 (滑音/效果器)
    //==============================================================
    wire [7:0] cmd_byte  = (ev_type == 3'd0) ? {1'b1, 1'b0, cfg_vib, cfg_ep, cfg_wave} :
                           (ev_type == 3'd1) ? {1'b0, 1'b0, cfg_vib, cfg_ep, cfg_wave} :
                                               8'h40;
    wire [7:0] note_byte = (ev_type == 3'd2) ? (8'h40 | {7'd0, ev_tst}) : ev_note;
    wire [7:0] vel_byte  = (ev_type == 3'd0) ? ev_vel :
                           (ev_type == 3'd3) ? ev_vel : 8'h00;

    always @(*) begin
        wr_word = {HDR, cmd_byte, note_byte, vel_byte};
        wr_en   = ev_vld && (cnt != 4'd8);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr <= 4'd0;
            rptr <= 4'd0;
            cnt  <= 4'd0;
        end else begin
            if (wr_en) mem[wptr[2:0]] <= wr_word;
            if (wr_en) wptr <= wptr + 4'd1;
            if (rd_pop) rptr <= rptr + 4'd1;
            cnt <= cnt + (wr_en ? 4'd1 : 4'd0) - (rd_pop ? 4'd1 : 4'd0);
        end
    end

    //==============================================================
    // 2) 帧 -> 字节串行器
    //==============================================================
    assign uart_busy = (st != 2'd0) || (cnt != 4'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= 2'd0;
            sh       <= 32'd0;
            bidx     <= 2'd0;
            tx_data  <= 8'd0;
            tx_start <= 1'b0;
            rd_pop   <= 1'b0;
            fcnt     <= 8'd0;
        end else begin
            tx_start <= 1'b0;
            rd_pop   <= 1'b0;

            case (st)
                2'd0: begin
                    if (cnt != 4'd0) begin
                        sh       <= rd_word;
                        tx_data  <= rd_word[31:24];
                        tx_start <= 1'b1;
                        bidx     <= 2'd0;
                        rd_pop   <= 1'b1;
                        st       <= 2'd1;
                    end
                end

                2'd1: begin
                    if (uart_done) begin
                        if (bidx == 2'd3) begin
                            st   <= 2'd0;
                            fcnt <= fcnt + 8'd1;
                        end else begin
                            bidx     <= bidx + 2'd1;
                            sh       <= {sh[23:0], 8'h00};
                            tx_data  <= sh[23:16];
                            tx_start <= 1'b1;
                        end
                    end
                end

                default: st <= 2'd0;
            endcase
        end
    end

    assign frame_cnt = fcnt;

    //==============================================================
    // 3) UART 发送器
    //==============================================================
    uart_tx #(.CLKS_PER_BIT(78)) u_tx (
        .clk   (clk),
        .rst_n (rst_n),
        .data  (tx_data),
        .start (tx_start),
        .tx    (uart_tx_pin),
        .busy  (),
        .done  (uart_done)
    );

endmodule
