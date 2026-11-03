//////////////////////////////////////////////////////////////////////////////////
// Module Name  : bh1750_i2c
// Description  : BH1750 光强传感器 I2C 主机 (bit-bang, SCL ≈ 50 kHz)
//                2026-11-01 测试集成 @ ACG525 C17(SCL)/C18(SDA)
//
//   循环时序:
//     上电等待 BOOT_MS -> [START -> 0x46 -> MEAS_CMD -> STOP]
//     -> 等待 WAIT_MS  -> [START -> 0x46 -> Sr -> 0x47 -> 读高字节(ACK) -> 读低字节(NACK) -> STOP]
//     -> 锁存 lux + lux_vld 单拍脉冲 -> 回到循环
//
//   - SCL 推挽输出 (单主机, BH1750 无时钟拉伸); SDA 开漏: sda_oe=1 拉低 / 0 释放
//     (三态驱动在顶层完成: assign BH_SDA = sda_oe ? 1'b0 : 1'bz)
//   - 收到 NACK (传感器不在位/掉线) -> i2c_err 置位, 发 STOP 优雅退出, 下一轮自动重试;
//     成功锁存 lux 时 i2c_err 清零
//   - MEAS_CMD=8'h10: 连续 H-res, 120ms, lux = 原始值 (1 lx/bit)
//     MEAS_CMD=8'h13: 连续 L-res,  16ms, lux = 原始值 x4 (实时光控/手势用)
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps

module bh1750_i2c #(
    parameter        CLK_HZ   = 9_000_000,   // clk_ctrl = 9 MHz
    parameter [7:0]  MEAS_CMD = 8'h10,       // 0x10 连续H-res(120ms) / 0x13 连续L-res(16ms)
    parameter        WAIT_MS  = 200,         // 转换等待, 须大于 MEAS_CMD 转换时间
    parameter        BOOT_MS  = 50           // 上电稳定等待
)(
    input  wire        clk,
    input  wire        rst_n,
    output reg         scl,        // SCL 推挽
    output reg         sda_oe,     // SDA 驱动使能: 1=拉低, 0=释放
    input  wire        sda_in,     // SDA 采样输入
    output reg  [15:0] lux,        // 测量原始值
    output reg         lux_vld,    // 单拍脉冲: lux 已更新
    output reg         i2c_err,    // 最近一轮是否 NACK (调试观测)
    output reg  [2:0]  err_code,   // 诊断: 0=全部ACK 1=写地址NACK 2=命令NACK 3=读地址NACK 4=保留
    output wire        addr_sel    // 当前探测地址: 0=0x23(ADDR=L) 1=0x5C(ADDR=H)
);

    //---------------- 地址自动探测: ADDR=L -> 0x23, ADDR=H -> 0x5C ----------------
    localparam [6:0] ADDR_LO = 7'h23;
    localparam [6:0] ADDR_HI = 7'h5C;
    reg              addr_hi;   // NACK 时翻转, 收敛到有应答的地址
    wire [7:0]       addr_w = {(addr_hi ? ADDR_HI : ADDR_LO), 1'b0};
    wire [7:0]       addr_r = {(addr_hi ? ADDR_HI : ADDR_LO), 1'b1};

    assign addr_sel = addr_hi;

    //---------------- I2C 节拍: 1/4 位 = CLK_HZ/200k = 5us -> SCL 约 50kHz ----------------
    // 取 50kHz 而非 100kHz: START 保持/总线空闲等时序余量翻倍, 杜邦线更稳
    localparam [15:0] TICK_DIV = CLK_HZ/200_000;            // 9MHz -> 45
    localparam [31:0] MS_CYC   = CLK_HZ/1000;               // 1ms 的 clk 数
    localparam [31:0] WAIT_CYC = WAIT_MS * MS_CYC;
    localparam [31:0] BOOT_CYC = BOOT_MS * MS_CYC;

    //---------------- 状态机 ----------------
    localparam [3:0]
        S_BOOT  = 4'd0,   // 上电等待
        S_IDLE  = 4'd1,   // 总线空闲 1 拍 (tBUF)
        S_START = 4'd2,   // START -> 发 ADDR_W
        S_TXW   = 4'd3,   // ADDR_W + ACK
        S_TXC   = 4'd4,   // MEAS_CMD + ACK
        S_STOP1 = 4'd5,   // STOP -> 等转换
        S_WAIT  = 4'd6,
        S_START2= 4'd7,   // START -> 发 ADDR_W (虚写)
        S_TXA2  = 4'd8,
        S_START3= 4'd9,   // 重复 START -> 发 ADDR_R
        S_TXAR  = 4'd10,
        S_RXH   = 4'd11,  // 读高字节, 主机 ACK
        S_RXL   = 4'd12,  // 读低字节, 主机 NACK
        S_STOP2 = 4'd13,
        S_LATCH = 4'd14,  // 锁存结果 (1 clk)
        S_ABORT = 4'd15;  // NACK 后的恢复 STOP

    reg [3:0]  state;
    reg [15:0] divcnt;
    reg        tick;
    reg [1:0]  qph;       // SCL 四相位 0..3 (0:低/设数据, 1:高, 2:高/采样, 3:低)
    reg [7:0]  sh;        // 发送/接收移位
    reg [7:0]  hi_r;      // 高字节暂存
    reg [3:0]  bitn;      // TX: 8..0 (0=ACK槽) / RX: 9..1 (1=ACK槽)
    reg        ack_n;
    reg [31:0] mscnt;

    //---------------- 四相位节拍发生器 ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            divcnt <= 16'd0;
            tick   <= 1'b0;
        end else if (divcnt >= TICK_DIV - 1) begin
            divcnt <= 16'd0;
            tick   <= 1'b1;
        end else begin
            divcnt <= divcnt + 1'b1;
            tick   <= 1'b0;
        end
    end

    //---------------- 主状态机 ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_BOOT;
            scl     <= 1'b1;      // 复位即空闲高 (I2C 总线空闲态)
            sda_oe  <= 1'b0;
            addr_hi <= 1'b0;
            qph     <= 2'd0;
            sh      <= 8'h00;
            hi_r    <= 8'h00;
            bitn    <= 4'd0;
            ack_n   <= 1'b0;
            mscnt   <= 32'd0;
            lux     <= 16'h0;
            lux_vld <= 1'b0;
            i2c_err <= 1'b0;
            err_code<= 3'd0;
        end else begin
            lux_vld <= 1'b0;

            // 毫秒计数不受 tick 节流 (每 clk 递增)
            if (state == S_BOOT || state == S_WAIT)
                mscnt <= mscnt + 1'b1;

            if (state == S_LATCH) begin
                // 成功一轮: 锁存, 清错误标志 (不受 tick 节流)
                lux     <= {hi_r, sh};
                lux_vld <= 1'b1;
                i2c_err <= 1'b0;
                err_code<= 3'd0;
                scl     <= 1'b1;      // 保持 STOP2 后的空闲电平
                sda_oe  <= 1'b0;
                state   <= S_IDLE;
            end else if (tick) begin
                qph <= qph + 2'd1;
                case (state)
                    //---------------- 上电等待 ----------------
                    S_BOOT: begin
                        scl <= 1'b1;      // 上电等待期间保持总线空闲高:
                        sda_oe <= 1'b0;   // 避免传感器上电时看到 SCL=0 而进入异常状态
                        if (mscnt >= BOOT_CYC - 1) begin
                            mscnt <= 32'd0;
                            qph   <= 2'd0;
                            state <= S_IDLE;
                        end
                    end
                    //---------------- 总线空闲 ----------------
                    S_IDLE: begin
                        scl    <= 1'b1;
                        sda_oe <= 1'b0;
                        qph    <= 2'd0;
                        state  <= S_START;
                    end
                    //---------------- START ----------------
                    S_START: begin
                        case (qph)
                            2'd0: sda_oe <= 1'b1;             // SCL 高, SDA 下降 = START
                            2'd1: scl    <= 1'b0;
                            2'd3: begin
                                sh    <= addr_w;
                                bitn  <= 4'd8;
                                state <= S_TXW;
                            end
                            default: ;
                        endcase
                    end
                    //---------------- 发送字节 (8 位 + ACK 槽) ----------------
                    S_TXW, S_TXC, S_TXA2, S_TXAR: begin
                        case (qph)
                            2'd0: begin
                                scl    <= 1'b0;
                                sda_oe <= (bitn != 4'd0) ? ~sh[7] : 1'b0; // 数据位开漏; ACK 槽释放
                            end
                            2'd1: scl <= 1'b1;
                            2'd2: if (bitn == 4'd0) ack_n <= sda_in;
                            2'd3: begin
                                scl <= 1'b0;
                                if (bitn != 4'd0) begin
                                    sh   <= {sh[6:0], 1'b0};
                                    bitn <= bitn - 4'd1;
                                end else if (ack_n) begin
                                    i2c_err  <= 1'b1;         // NACK: 传感器不在位/地址不符
                                    err_code <= (state == S_TXW)  ? 3'd1 :   // 写地址被拒
                                                (state == S_TXC)  ? 3'd2 :   // 测量命令被拒
                                                (state == S_TXA2) ? 3'd3 :   // 读前虚写被拒
                                                                    3'd4;    // 读地址被拒
                                    addr_hi <= ~addr_hi;      // 自动探测 0x23/0x5C
                                    state   <= S_ABORT;
                                end else begin
                                    case (state)
                                        S_TXW:  begin sh <= MEAS_CMD; bitn <= 4'd8; state <= S_TXC;  end
                                        S_TXC:  state <= S_STOP1;
                                        S_TXA2: state <= S_START3;
                                        S_TXAR: begin sh <= 8'h00; bitn <= 4'd9; state <= S_RXH; end
                                        default: state <= S_ABORT;
                                    endcase
                                end
                            end
                            default: ;
                        endcase
                    end
                    //---------------- 重复 START ----------------
                    S_START3: begin
                        case (qph)
                            2'd2: sda_oe <= 1'b1;             // SCL 高, SDA 下降 = Sr
                            2'd3: begin
                                scl    <= 1'b0;
                                sh     <= addr_r;
                                bitn   <= 4'd8;
                                state  <= S_TXAR;
                            end
                            default: ;
                        endcase
                    end
                    //---------------- STOP ----------------
                    S_STOP1, S_STOP2: begin
                        case (qph)
                            2'd0: sda_oe <= 1'b1;             // SCL 低, 先拉低 SDA
                            2'd1: scl    <= 1'b1;
                            2'd2: sda_oe <= 1'b0;             // SCL 高, SDA 上升 = STOP
                            2'd3: begin
                                qph   <= 2'd0;
                                state <= (state == S_STOP1) ? S_WAIT : S_LATCH;
                            end
                            default: ;
                        endcase
                    end
                    //---------------- 等待转换完成 ----------------
                    S_WAIT: begin
                        scl    <= 1'b1;
                        sda_oe <= 1'b0;
                        if (mscnt >= WAIT_CYC - 1) begin
                            mscnt <= 32'd0;
                            qph   <= 2'd0;
                            state <= S_START2;
                        end
                    end
                    S_START2: begin
                        case (qph)
                            2'd0: sda_oe <= 1'b1;
                            2'd1: scl    <= 1'b0;
                            2'd3: begin
                                sh    <= addr_w;
                                bitn  <= 4'd8;
                                state <= S_TXA2;
                            end
                            default: ;
                        endcase
                    end
                    //---------------- 接收字节 (8 位 + 主机 ACK/NACK 槽) ----------------
                    S_RXH, S_RXL: begin
                        case (qph)
                            2'd0: begin
                                scl    <= 1'b0;
                                sda_oe <= (bitn == 4'd1) ? (state == S_RXH) : 1'b0;
                                // 数据位释放; ACK 槽: RXH 拉低应答 / RXL 释放(NACK)
                            end
                            2'd1: scl <= 1'b1;
                            2'd2: if (bitn != 4'd1) sh <= {sh[6:0], sda_in};
                            2'd3: begin
                                scl <= 1'b0;
                                if (bitn != 4'd1) begin
                                    bitn <= bitn - 4'd1;
                                end else if (state == S_RXH) begin
                                    hi_r  <= sh;
                                    bitn  <= 4'd9;
                                    state <= S_RXL;
                                end else begin
                                    state <= S_STOP2;
                                end
                            end
                            default: ;
                        endcase
                    end
                    //---------------- NACK 恢复: 释放总线并补一个 STOP ----------------
                    S_ABORT: begin
                        case (qph)
                            2'd0: begin scl <= 1'b0; sda_oe <= 1'b0; end
                            2'd1: sda_oe <= 1'b1;
                            2'd2: scl    <= 1'b1;
                            2'd3: begin
                                sda_oe <= 1'b0;
                                mscnt  <= 32'd0;
                                qph    <= 2'd0;
                                state  <= S_WAIT;
                            end
                            default: ;
                        endcase
                    end
                    default: state <= S_ABORT;
                endcase
            end
        end
    end

endmodule
