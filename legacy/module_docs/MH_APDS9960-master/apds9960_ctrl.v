//======================================================================
//  File   : apds9960_ctrl.v
//  Brief  : APDS-9960 初始化 + 接近(红外)数据轮询控制器
//
//  对应 Arduino 库 MH_APDS9960 的 begin()/readProximity() 流程：
//    1) 读 ID(0x92) 判断是否 == 0xAB，失败则每 RETRY_MS 重试（支持热插拔）
//    2) 按表写配置：ENABLE/ATIME/CONTROL/CONFIG2/PPULSE/ENABLE(PON)/ENABLE(PON|PEN)
//    3) 每 POLL_MS 读一次 PDATA(0x9C)，输出 prox[7:0] 并给出 near 标志
//  任一 I2C 事务 NACK 则回到 ID 检测，sensor_ok 拉低（顶层用 LED 闪烁提示）
//======================================================================
`timescale 1ns / 1ps

module apds9960_ctrl #(
    parameter integer CLK_FREQ       = 50_000_000,
    parameter [7:0]   PROX_THRESHOLD = 8'd80,   // 接近判定阈值(0~255)
    parameter integer POLL_MS        = 20,      // 轮询周期 ms
    parameter integer RETRY_MS       = 100      // 通信失败重试周期 ms
)(
    input  wire       clk,
    input  wire       rst_n,
    // ---------------- 到 i2c_master ----------------
    output reg        i2c_go,
    output reg        i2c_rd,
    output reg  [7:0] i2c_reg,
    output reg  [7:0] i2c_wdata,
    output reg  [7:0] i2c_len,
    input  wire [7:0] i2c_rdata,
    input  wire       i2c_done,
    input  wire       i2c_ack_err,
    // ---------------- 结果 ----------------
    output reg  [7:0] prox,         // 接近值，0~255，越大越近
    output reg        prox_valid,   // 新数据脉冲
    output reg        near,         // prox >= PROX_THRESHOLD
    output reg        sensor_ok     // 1 = 已完成初始化且数据正常
);

    //------------------------------------------------------------------
    // 时间常数
    //------------------------------------------------------------------
    localparam integer MS = (CLK_FREQ / 1000);

    //------------------------------------------------------------------
    // 寄存器地址（与 MH_APDS9960.h 一致）
    //------------------------------------------------------------------
    localparam [7:0] REG_ENABLE  = 8'h80,
                     REG_ATIME   = 8'h81,
                     REG_PPULSE  = 8'h8E,
                     REG_CONTROL = 8'h8F,
                     REG_CONFIG2 = 8'h90,
                     REG_ID      = 8'h92,
                     REG_PDATA   = 8'h9C;

    localparam [7:0] CHIP_ID    = 8'hAB;

    //------------------------------------------------------------------
    // 状态
    //------------------------------------------------------------------
    localparam [3:0] ST_BOOT     = 4'd0,
                     ST_ID       = 4'd1,
                     ST_ID_W     = 4'd2,
                     ST_CFG      = 4'd3,
                     ST_CFG_W    = 4'd4,
                     ST_GAP      = 4'd5,
                     ST_POLL_DLY = 4'd6,
                     ST_POLL     = 4'd7,
                     ST_POLL_W   = 4'd8,
                     ST_RETRY    = 4'd9;

    localparam [2:0] CFG_LAST = 3'd6;

    reg [3:0]  st;
    reg [31:0] cnt;        // 通用延时计数
    reg [2:0]  cfg_idx;

    //------------------------------------------------------------------
    // 初始化配置表
    //------------------------------------------------------------------
    reg [7:0]  cfg_reg;
    reg [7:0]  cfg_dat;
    reg [31:0] cfg_gap;

    always @(*) begin
        case (cfg_idx)
        3'd0: begin cfg_reg = REG_ENABLE;  cfg_dat = 8'h00; cfg_gap = MS;      end // 先全部关闭
        3'd1: begin cfg_reg = REG_ATIME;   cfg_dat = 8'hFC; cfg_gap = MS;      end // 积分时间 ~11 ms
        3'd2: begin cfg_reg = REG_CONTROL; cfg_dat = 8'h0D; cfg_gap = MS;      end // PGAIN=8x, AGAIN=4x, LDRIVE=100mA
        3'd3: begin cfg_reg = REG_CONFIG2; cfg_dat = 8'h11; cfg_gap = MS;      end // LED_BOOST=150%
        3'd4: begin cfg_reg = REG_PPULSE;  cfg_dat = 8'h87; cfg_gap = MS;      end // 16us x 8 脉冲
        3'd5: begin cfg_reg = REG_ENABLE;  cfg_dat = 8'h01; cfg_gap = 10*MS;   end // PON=1
        3'd6: begin cfg_reg = REG_ENABLE;  cfg_dat = 8'h05; cfg_gap = 10*MS;   end // PON=1, PEN=1
        default: begin cfg_reg = REG_ENABLE; cfg_dat = 8'h05; cfg_gap = MS;    end
        endcase
    end

    //------------------------------------------------------------------
    // 主状态机
    //------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st         <= ST_BOOT;
            cnt        <= 20 * MS;
            cfg_idx    <= 3'd0;
            i2c_go     <= 1'b0;
            i2c_rd     <= 1'b0;
            i2c_reg    <= 8'h00;
            i2c_wdata  <= 8'h00;
            i2c_len    <= 8'd1;
            prox       <= 8'd0;
            prox_valid <= 1'b0;
            near       <= 1'b0;
            sensor_ok  <= 1'b0;
        end else begin
            i2c_go     <= 1'b0;
            prox_valid <= 1'b0;

            case (st)
            //----------------------------------------------------------
            // 上电等待，等传感器电源稳定
            //----------------------------------------------------------
            ST_BOOT: begin
                if (cnt == 32'd0) begin
                    st <= ST_ID;
                end else begin
                    cnt <= cnt - 1'b1;
                end
            end
            //----------------------------------------------------------
            // 读 ID
            //----------------------------------------------------------
            ST_ID: begin
                i2c_go    <= 1'b1;
                i2c_rd    <= 1'b1;
                i2c_reg   <= REG_ID;
                i2c_wdata <= 8'h00;
                i2c_len   <= 8'd1;
                st        <= ST_ID_W;
            end
            ST_ID_W: begin
                if (i2c_done) begin
                    if (!i2c_ack_err && (i2c_rdata == CHIP_ID)) begin
                        cfg_idx <= 3'd0;
                        st      <= ST_CFG;
                    end else begin
                        sensor_ok <= 1'b0;
                        cnt       <= RETRY_MS * MS;
                        st        <= ST_RETRY;
                    end
                end
            end
            //----------------------------------------------------------
            // 逐条写初始化寄存器
            //----------------------------------------------------------
            ST_CFG: begin
                i2c_go    <= 1'b1;
                i2c_rd    <= 1'b0;
                i2c_reg   <= cfg_reg;
                i2c_wdata <= cfg_dat;
                i2c_len   <= 8'd1;
                st        <= ST_CFG_W;
            end
            ST_CFG_W: begin
                if (i2c_done) begin
                    if (i2c_ack_err) begin
                        sensor_ok <= 1'b0;
                        cnt       <= RETRY_MS * MS;
                        st        <= ST_RETRY;
                    end else begin
                        cnt <= cfg_gap;
                        st  <= ST_GAP;
                    end
                end
            end
            ST_GAP: begin
                if (cnt == 32'd0) begin
                    if (cfg_idx == CFG_LAST) begin
                        cnt <= POLL_MS * MS;
                        st  <= ST_POLL_DLY;
                    end else begin
                        cfg_idx <= cfg_idx + 1'b1;
                        st      <= ST_CFG;
                    end
                end else begin
                    cnt <= cnt - 1'b1;
                end
            end
            //----------------------------------------------------------
            // 周期读接近数据
            //----------------------------------------------------------
            ST_POLL_DLY: begin
                if (cnt == 32'd0) begin
                    st <= ST_POLL;
                end else begin
                    cnt <= cnt - 1'b1;
                end
            end
            ST_POLL: begin
                i2c_go    <= 1'b1;
                i2c_rd    <= 1'b1;
                i2c_reg   <= REG_PDATA;
                i2c_wdata <= 8'h00;
                i2c_len   <= 8'd1;
                st        <= ST_POLL_W;
            end
            ST_POLL_W: begin
                if (i2c_done) begin
                    if (i2c_ack_err) begin
                        sensor_ok <= 1'b0;
                        cnt       <= RETRY_MS * MS;
                        st        <= ST_RETRY;
                    end else begin
                        prox       <= i2c_rdata;
                        near       <= (i2c_rdata >= PROX_THRESHOLD);
                        prox_valid <= 1'b1;
                        sensor_ok  <= 1'b1;
                        cnt        <= POLL_MS * MS;
                        st         <= ST_POLL_DLY;
                    end
                end
            end
            //----------------------------------------------------------
            // 失败后延时重试
            //----------------------------------------------------------
            ST_RETRY: begin
                if (cnt == 32'd0) begin
                    st <= ST_ID;
                end else begin
                    cnt <= cnt - 1'b1;
                end
            end
            default: begin
                st <= ST_BOOT;
            end
            endcase
        end
    end

endmodule
