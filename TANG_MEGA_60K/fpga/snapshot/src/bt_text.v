//=======================================================================
// bt_text —— 蓝牙"文本命令"接收器 (2026-11-02)
//
// 为什么需要它:
//   手机上的串口终端 (Serial Bluetooth Terminal) 的 hex 只是显示格式,
//   输入框里敲 "A5 00 3C F0" 发出去的是 12 个 ASCII 字符 41 35 20 30 30 ...
//   不是 4 个二进制字节。要发二进制得靠 App 的 hex 发送模式, 各家 App 不一样,
//   现场演示太容易翻车。
//
//   所以给蓝牙这一路加一个"文本命令"通道, 手机上直接敲字就能弹琴:
//
//       N60        -> 按下 60 号音 (MIDI 60 = C4), 默认力度 200
//       N60,240    -> 按下 60 号音, 力度 240
//       O60        -> 松开 60 号音
//
//   大小写都行, 也可以用 '+' / '-' 代替 N / O。
//   行尾 CR / LF 都行, 没收到行尾时遇到下一个命令字母也会自动收尾。
//
// 波特率必须与 uart_rx 的蓝牙通道一致 (CLK_PER_BIT=14 -> 113.6k)。
//=======================================================================
`default_nettype none

module bt_text #(
    parameter integer CLK_PER_BIT = 14
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,
    output reg        t_on,
    output reg        t_off,
    output reg [6:0]  t_note,
    output reg [7:0]  t_vel
);

    localparam integer CW = 8;                 // 计数器位宽 (够 166)

    // ---------------- 字节接收 (10 位 8N1, 中点采样) ----------------
    reg [2:0]  rx_sync;
    wire       rx_s = rx_sync[2];
    reg [2:0]  bstate;
    reg [CW-1:0] bcnt;
    reg [3:0]  bitn;
    reg [7:0]  shft;
    reg        byte_vld;
    reg [7:0]  byte_now;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync <= 3'b111;
        end else begin
            rx_sync <= {rx_sync[1:0], rx};
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bstate   <= 3'd0;
            bcnt     <= {CW{1'b0}};
            bitn     <= 4'd0;
            shft     <= 8'd0;
            byte_vld <= 1'b0;
            byte_now <= 8'd0;
        end else begin
            byte_vld <= 1'b0;
            case (bstate)
                3'd0: begin
                    bcnt <= {CW{1'b0}};
                    if (!rx_s) bstate <= 3'd1;         // 起始位下降沿
                end
                3'd1: begin                            // 半位 -> 起始位中点
                    if (bcnt == (CLK_PER_BIT / 2 - 1)) begin
                        bcnt   <= {CW{1'b0}};
                        bitn   <= 4'd0;
                        bstate <= (rx_s) ? 3'd0 : 3'd2; // 毛刺就回去
                    end else begin
                        bcnt <= bcnt + 1'b1;
                    end
                end
                3'd2: begin                            // 8 个数据位的中点
                    if (bcnt == (CLK_PER_BIT - 1)) begin
                        bcnt  <= {CW{1'b0}};
                        shft  <= {rx_s, shft[7:1]};    // LSB first
                        bitn  <= bitn + 4'd1;
                        if (bitn == 4'd7) bstate <= 3'd3;
                    end else begin
                        bcnt <= bcnt + 1'b1;
                    end
                end
                3'd3: begin                            // 停止位中点
                    if (bcnt == (CLK_PER_BIT - 1)) begin
                        bcnt     <= {CW{1'b0}};
                        byte_now <= shft;
                        byte_vld <= 1'b1;
                        bstate   <= 3'd0;
                    end else begin
                        bcnt <= bcnt + 1'b1;
                    end
                end
                default: bstate <= 3'd0;
            endcase
        end
    end

    // ---------------- 命令解析 ----------------
    localparam [2:0] P_IDLE = 3'd0, P_NOTE = 3'd1, P_VEL = 3'd2;
    reg [2:0]  pst;
    reg        p_on;                 // 1 = note on, 0 = note off
    reg        seen;                 // 本行是否已经收到命令字母
    reg [6:0]  acc_note;
    reg [7:0]  acc_vel;

    wire [7:0] ch = byte_now;
    wire is_digit = (ch >= 8'h30) && (ch <= 8'h39);
    wire is_note  = (ch == 8'h4E) || (ch == 8'h6E) || (ch == 8'h2B);   // 'N' 'n' '+'
    wire is_off   = (ch == 8'h4F) || (ch == 8'h6F) || (ch == 8'h2D);   // 'O' 'o' '-'
    wire is_comma = (ch == 8'h2C);
    wire is_eol   = (ch == 8'h0D) || (ch == 8'h0A);

    // The same BT wire also carries A5/cmd/note/velocity binary frames.
    // Payload bytes may be N/O, digits or LF: none are text commands.
    reg [1:0] binary_left;
    always @(posedge clk or negedge rst_n)
      if(!rst_n) binary_left<=0;
      else if(byte_vld) begin
        if(binary_left!=0) binary_left<=binary_left-1'b1;
        else if(ch==8'hA5) binary_left<=3;
      end

    task automatic emit_cmd;
        begin
            if (seen) begin
                t_note <= acc_note;
                t_vel  <= (acc_vel == 8'd0) ? 8'd200 : acc_vel;
                if (p_on) begin t_on <= 1'b1; t_off <= 1'b0; end
                else      begin t_off <= 1'b1; t_on <= 1'b0; end
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pst      <= P_IDLE;
            p_on     <= 1'b1;
            seen     <= 1'b0;
            acc_note <= 7'd60;
            acc_vel  <= 8'd0;
            t_on     <= 1'b0;
            t_off    <= 1'b0;
            t_note   <= 7'd60;
            t_vel    <= 8'd200;
        end else begin
            t_on  <= 1'b0;
            t_off <= 1'b0;
            if (byte_vld) begin
                if(binary_left!=0) begin
                    // Ignore exactly three payload bytes, including A5.
                end else if(ch==8'hA5) begin
                    pst<=P_IDLE;seen<=0;acc_vel<=0;
                end else if (is_eol) begin
                    if (seen) emit_cmd;
                    pst      <= P_IDLE;
                    seen     <= 1'b0;
                    acc_note <= acc_note;
                    acc_vel  <= 8'd0;
                end else if (is_note || is_off) begin
                    // 上一行没收到行尾就来了新命令字母: 先把上一行收尾
                    if (seen) emit_cmd;
                    p_on     <= is_note;
                    seen     <= 1'b1;
                    pst      <= P_NOTE;
                    acc_note <= 7'd0;
                    acc_vel  <= 8'd0;
                end else if (is_digit) begin
                    if (pst == P_VEL) begin
                        if (acc_vel <= 8'd25) acc_vel <= acc_vel * 8'd10 + (ch - 8'h30);
                    end else if (seen) begin
                        if (acc_note <= 7'd12) acc_note <= acc_note * 7'd10 + (ch[6:0] - 7'd48);
                    end
                end else if (is_comma) begin
                    if (seen) pst <= P_VEL;
                end
            end
        end
    end

endmodule

`default_nettype wire
