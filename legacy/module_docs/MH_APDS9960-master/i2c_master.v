//======================================================================
//  File   : i2c_master.v
//  Brief  : 轮询式 I2C 主机（7 bit 地址，开漏输出，需上拉电阻）
//  Author : ported for GW5A-25A / APDS-9960 experiment
//
//  一次 go 完成一次完整事务：
//    写（rd=0）：START + ADDR+W + REG + DATA + STOP
//    读（rd=1）：START + ADDR+W + REG + Sr + ADDR+R + 第1字节 + ... + STOP
//
//  - SCL 频率 = SCL_FREQ（默认 100 kHz），每一位 4 个 1/4 周期相位
//  - 读事务里除最后一字节回 ACK 外，其余字节回 ACK；最后一字节回 NACK
//  - 从机 NACK 时 ack_err 置 1（go 时清除），并直接发 STOP
//======================================================================
`timescale 1ns / 1ps

module i2c_master #(
    parameter integer CLK_FREQ = 50_000_000,
    parameter integer SCL_FREQ = 100_000
)(
    input  wire       clk,
    input  wire       rst_n,
    // ---------------- 用户接口 ----------------
    input  wire       go,          // 单周期脉冲，启动一次事务
    input  wire       rd,          // 1 = 读，0 = 写
    input  wire [6:0] dev_addr,    // 7 bit 从机地址
    input  wire [7:0] reg_addr,    // 寄存器地址
    input  wire [7:0] wr_data,     // 写数据（rd=0）
    input  wire [7:0] rd_len,      // 读长度（rd=1，1~255）
    output reg  [7:0] rd_data,     // 最近一个读到的字节
    output reg        byte_done,   // 每读到一个字节给一个脉冲
    output reg        busy,
    output reg        ack_err,
    output reg        done,        // 事务结束脉冲
    // ---------------- I2C 焊盘 ----------------
    inout  wire       scl,
    inout  wire       sda
);

    //------------------------------------------------------------------
    // 1/4 SCL 周期节拍
    //------------------------------------------------------------------
    localparam integer QUARTER = CLK_FREQ / (SCL_FREQ * 4);

    reg [15:0] div_cnt;
    reg        tick;
    reg        scl_oe;     // 1: 拉低 SCL
    reg        sda_oe;     // 1: 拉低 SDA

    wire sda_i = sda;

    assign scl = scl_oe ? 1'b0 : 1'bz;
    assign sda = sda_oe ? 1'b0 : 1'bz;

    //------------------------------------------------------------------
    // 状态编码
    //------------------------------------------------------------------
    localparam [2:0] ST_IDLE  = 3'd0,
                     ST_START = 3'd1,
                     ST_TX    = 3'd2,
                     ST_ACK   = 3'd3,
                     ST_RSTRT = 3'd4,
                     ST_RX    = 3'd5,
                     ST_MACK  = 3'd6,
                     ST_STOP  = 3'd7;

    reg [2:0] st;
    reg [1:0] ph;          // 每个 bit 的 4 个相位
    reg [2:0] bitcnt;
    reg [7:0] sh;          // 发送/接收移位寄存器
    reg [7:0] len;         // 读事务剩余字节数
    reg [1:0] stage;       // 0:地址W 1:寄存器 2:写数据 3:地址R
    reg       rd_mode;
    reg       got_ack;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= ST_IDLE;
            ph       <= 2'd0;
            bitcnt   <= 3'd7;
            sh       <= 8'd0;
            len      <= 8'd1;
            stage    <= 2'd0;
            rd_mode  <= 1'b0;
            got_ack  <= 1'b1;
            scl_oe   <= 1'b0;
            sda_oe   <= 1'b0;
            busy     <= 1'b0;
            done     <= 1'b0;
            ack_err  <= 1'b0;
            rd_data  <= 8'd0;
            byte_done<= 1'b0;
            div_cnt  <= 16'd0;
            tick     <= 1'b0;
        end else begin
            //----------------------------------------------------------
            // 节拍产生：只在 busy 期间运行
            //----------------------------------------------------------
            if (!busy) begin
                div_cnt <= 16'd0;
                tick    <= 1'b0;
            end else if (div_cnt == (QUARTER - 1)) begin
                div_cnt <= 16'd0;
                tick    <= 1'b1;
            end else begin
                div_cnt <= div_cnt + 1'b1;
                tick    <= 1'b0;
            end

            done      <= 1'b0;
            byte_done <= 1'b0;

            if (!busy) begin
                if (go) begin
                    busy    <= 1'b1;
                    st      <= ST_START;
                    ph      <= 2'd0;
                    stage   <= 2'd0;
                    rd_mode <= rd;
                    // 第一个地址相位永远是"写"（先发寄存器地址），
                    // 读事务在寄存器 ACK 之后用重复 START + 地址+R 再读
                    sh      <= {dev_addr, 1'b0};
                    len     <= (rd_len == 8'd0) ? 8'd1 : rd_len;
                    bitcnt  <= 3'd7;
                    ack_err <= 1'b0;
                    got_ack <= 1'b1;
                    scl_oe  <= 1'b0;
                    sda_oe  <= 1'b0;
                end
            end else if (tick) begin
                ph <= ph + 1'b1;

                case (st)
                //------------------------------------------------------
                // START：SCL 高电平期间 SDA 由高变低
                //------------------------------------------------------
                ST_START: begin
                    case (ph)
                    2'd0: begin scl_oe <= 1'b0; sda_oe <= 1'b0; end
                    2'd1: begin sda_oe <= 1'b1; end
                    2'd2: begin scl_oe <= 1'b1; end
                    2'd3: begin
                        scl_oe <= 1'b1;
                        sda_oe <= ~sh[7];
                        st     <= ST_TX;
                    end
                    default: ;
                    endcase
                end
                //------------------------------------------------------
                // 发送 1 字节（MSB first）
                //------------------------------------------------------
                ST_TX: begin
                    case (ph)
                    2'd0: begin scl_oe <= 1'b1; sda_oe <= ~sh[7]; end
                    2'd1: begin scl_oe <= 1'b0; end
                    2'd2: begin end
                    2'd3: begin
                        scl_oe <= 1'b1;
                        if (bitcnt == 3'd0) begin
                            st <= ST_ACK;
                        end else begin
                            bitcnt <= bitcnt - 1'b1;
                            sh     <= {sh[6:0], 1'b0};
                        end
                    end
                    default: ;
                    endcase
                end
                //------------------------------------------------------
                // 接收从机 ACK
                //------------------------------------------------------
                ST_ACK: begin
                    case (ph)
                    2'd0: begin scl_oe <= 1'b1; sda_oe <= 1'b0; end
                    2'd1: begin scl_oe <= 1'b0; end
                    2'd2: begin got_ack <= ~sda_i; end
                    2'd3: begin
                        scl_oe <= 1'b1;
                        if (!got_ack) begin
                            ack_err <= 1'b1;
                            st      <= ST_STOP;
                        end else begin
                            case (stage)
                            2'd0: begin
                                sh     <= reg_addr;
                                bitcnt <= 3'd7;
                                stage  <= 2'd1;
                                st     <= ST_TX;
                            end
                            2'd1: begin
                                if (rd_mode) begin
                                    st <= ST_RSTRT;
                                end else begin
                                    sh     <= wr_data;
                                    bitcnt <= 3'd7;
                                    stage  <= 2'd2;
                                    st     <= ST_TX;
                                end
                            end
                            2'd2: begin
                                st <= ST_STOP;
                            end
                            default: begin
                                bitcnt <= 3'd7;
                                st     <= ST_RX;
                            end
                            endcase
                        end
                    end
                    default: ;
                    endcase
                end
                //------------------------------------------------------
                // 重复 START（读事务）
                //------------------------------------------------------
                ST_RSTRT: begin
                    case (ph)
                    2'd0: begin scl_oe <= 1'b1; sda_oe <= 1'b0; end
                    2'd1: begin scl_oe <= 1'b0; end
                    2'd2: begin sda_oe <= 1'b1; end
                    2'd3: begin
                        scl_oe <= 1'b1;
                        sda_oe <= 1'b0;
                        sh     <= {dev_addr, 1'b1};
                        bitcnt <= 3'd7;
                        stage  <= 2'd3;
                        st     <= ST_TX;
                    end
                    default: ;
                    endcase
                end
                //------------------------------------------------------
                // 接收 1 字节
                //------------------------------------------------------
                ST_RX: begin
                    case (ph)
                    2'd0: begin scl_oe <= 1'b1; sda_oe <= 1'b0; end
                    2'd1: begin scl_oe <= 1'b0; end
                    2'd2: begin sh <= {sh[6:0], sda_i}; end
                    2'd3: begin
                        scl_oe <= 1'b1;
                        if (bitcnt == 3'd0) begin
                            rd_data   <= sh;
                            byte_done <= 1'b1;
                            st        <= ST_MACK;
                        end else begin
                            bitcnt <= bitcnt - 1'b1;
                        end
                    end
                    default: ;
                    endcase
                end
                //------------------------------------------------------
                // 主机回 ACK / NACK，并决定是否继续读
                //------------------------------------------------------
                ST_MACK: begin
                    case (ph)
                    2'd0: begin
                        scl_oe <= 1'b1;
                        sda_oe <= (len == 8'd1) ? 1'b0 : 1'b1;
                    end
                    2'd1: begin scl_oe <= 1'b0; end
                    2'd2: begin end
                    2'd3: begin
                        scl_oe <= 1'b1;
                        sda_oe <= 1'b0;
                        if (len == 8'd1) begin
                            st <= ST_STOP;
                        end else begin
                            len    <= len - 1'b1;
                            bitcnt <= 3'd7;
                            st     <= ST_RX;
                        end
                    end
                    default: ;
                    endcase
                end
                //------------------------------------------------------
                // STOP：SCL 高电平期间 SDA 由低变高
                //------------------------------------------------------
                ST_STOP: begin
                    case (ph)
                    2'd0: begin scl_oe <= 1'b1; sda_oe <= 1'b1; end
                    2'd1: begin scl_oe <= 1'b0; end
                    2'd2: begin sda_oe <= 1'b0; end
                    2'd3: begin
                        scl_oe <= 1'b0;
                        sda_oe <= 1'b0;
                        busy   <= 1'b0;
                        done   <= 1'b1;
                        st     <= ST_IDLE;
                    end
                    default: ;
                    endcase
                end
                default: begin
                    busy   <= 1'b0;
                    scl_oe <= 1'b0;
                    sda_oe <= 1'b0;
                end
                endcase
            end
        end
    end

endmodule
