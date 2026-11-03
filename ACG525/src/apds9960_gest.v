//////////////////////////////////////////////////////////////////////////////////
// Module Name : apds9960_gest
// Description : APDS-9960 手势引擎驱动 (v10) —— ID 热插拔检测 + 手势模式配置
//               + GSTATUS/GFIFO 轮询 + 四方向判决
//
//   对应 Arduino MH_APDS9960 库的手势流程:
//     1) 读 ID(0x92)==0xAB, 失败每 RETRY_MS 重试 (支持热插拔)
//     2) 写手势配置: ENABLE=0 / WTIME=0xFF / GCONF1=0x00 / GCONF2=0x48
//                    GPULSE=0x87(32 脉冲) / GPENTH=0x50 / GEXTH=0x30
//                    ENABLE=0x41 (PON | GEN)
//     3) 轮询 GSTATUS(0xAF).GVALID: =1 则连读 GFIFO(0xFC) 4 字节(U/D/L/R)
//        累加到四方向计数; GVALID=0 且有数据 -> 判决 -> 单拍脉冲输出
//   判决 (避免除法, 用 2 倍交叉比较):
//     |U-D| > 2*|L-R| 且 >= 阈值  -> 上/下挥
//     |L-R| > 2*|U-D| 且 >= 阈值  -> 左/右挥
//     其余 (斜挥/幅度不足) -> 丢弃
//   语义映射 (由顶层/touch_panel 决定): 上/下=音色切换, 左/右=八度切换
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

module apds9960_gest #(
    parameter integer CLK_FREQ = 9_000_000,
    parameter integer SCL_FREQ = 90_000,      // 9MHz/25 -> 90 kHz
    parameter [15:0]  GEST_MIN = 16'd8,       // 方向差分最小幅度
    parameter integer RETRY_MS  = 100,        // 通信失败重试周期 ms
    parameter integer POLL_GAP  = 5           // 手势轮询间隔 ms
)(
    input  wire       clk,
    input  wire       rst_n,
    // ---------------- I2C 焊盘 (内部例化 i2c_master) ----------------
    inout  wire       scl,
    inout  wire       sda,
    // ---------------- 手势事件 (单拍脉冲) ----------------
    output reg        gest_up,
    output reg        gest_down,
    output reg        gest_left,
    output reg        gest_right,
    output reg        sensor_ok               // 1=初始化完成且通信正常
);

    localparam integer MS = (CLK_FREQ / 1000);

    //--------------------------------------------------------------
    // APDS-9960 寄存器
    //--------------------------------------------------------------
    localparam [7:0] REG_ENABLE = 8'h80,
                     REG_WTIME  = 8'h83,
                     REG_GCONF1 = 8'hA0,
                     REG_GCONF2 = 8'hA1,
                     REG_GPULSE = 8'hA7,
                     REG_GPENTH = 8'hAA,
                     REG_GEXTH  = 8'hAB,
                     REG_ID     = 8'h92,
                     REG_GSTATUS= 8'hAF,
                     REG_GFIFO  = 8'hFC;

    localparam [7:0] CHIP_ID = 8'hAB;

    //--------------------------------------------------------------
    // 状态
    //--------------------------------------------------------------
    localparam [3:0] ST_BOOT   = 4'd0,
                     ST_ID     = 4'd1,
                     ST_ID_W   = 4'd2,
                     ST_CFG    = 4'd3,
                     ST_CFG_W  = 4'd4,
                     ST_GAP    = 4'd5,
                     ST_POLL_D = 4'd6,
                     ST_GP     = 4'd7,   // 读 GSTATUS
                     ST_GP_W   = 4'd8,
                     ST_GF     = 4'd9,   // 读 GFIFO 4 字节
                     ST_GF_W   = 4'd10,
                     ST_JUDGE  = 4'd11,  // 判决 (FIFO 空)
                     ST_RETRY  = 4'd12;

    localparam [3:0] CFG_LAST = 4'd7;

    reg [3:0]  st;
    reg [31:0] cnt;
    reg [3:0]  cfg_idx;
    reg [1:0]  gfifo_n;                  // 本事务已收字节数 0..3

    //--------------------------------------------------------------
    // 配置表
    //--------------------------------------------------------------
    reg [7:0] cfg_reg, cfg_dat, cfg_gapms;
    always @(*) begin
        case (cfg_idx)
        4'd0: begin cfg_reg = REG_ENABLE; cfg_dat = 8'h00; cfg_gapms = 8'd1;  end
        4'd1: begin cfg_reg = REG_WTIME;  cfg_dat = 8'hFF; cfg_gapms = 8'd1;  end
        4'd2: begin cfg_reg = REG_GCONF1; cfg_dat = 8'h00; cfg_gapms = 8'd1;  end
        4'd3: begin cfg_reg = REG_GCONF2; cfg_dat = 8'h48; cfg_gapms = 8'd1;  end // GLDRIVE 100mA, GGAIN 4x
        4'd4: begin cfg_reg = REG_GPULSE; cfg_dat = 8'h87; cfg_gapms = 8'd1;  end // GELEV=2, 32 脉冲
        4'd5: begin cfg_reg = REG_GPENTH; cfg_dat = 8'h50; cfg_gapms = 8'd1;  end
        4'd6: begin cfg_reg = REG_GEXTH;  cfg_dat = 8'h30; cfg_gapms = 8'd1;  end
        4'd7: begin cfg_reg = REG_ENABLE; cfg_dat = 8'h41; cfg_gapms = 8'd10; end // PON|GEN
        default: begin cfg_reg = REG_ENABLE; cfg_dat = 8'h41; cfg_gapms = 8'd1; end
        endcase
    end

    //--------------------------------------------------------------
    // 手势累计
    //--------------------------------------------------------------
    reg [15:0] sum_u, sum_d, sum_l, sum_r;
    reg        any_data;

    //--------------------------------------------------------------
    // i2c_master 接口
    //--------------------------------------------------------------
    reg        i2c_go, i2c_rd;
    reg  [7:0] i2c_reg, i2c_wdata, i2c_len;
    wire [7:0] i2c_rdata;
    wire       i2c_done, i2c_ack_err, i2c_byte_done;

    i2c_master #(
        .CLK_FREQ (CLK_FREQ),
        .SCL_FREQ (SCL_FREQ)
    ) u_i2c (
        .clk       (clk),
        .rst_n     (rst_n),
        .go        (i2c_go),
        .rd        (i2c_rd),
        .dev_addr  (7'h39),
        .reg_addr  (i2c_reg),
        .wr_data   (i2c_wdata),
        .rd_len    (i2c_len),
        .rd_data   (i2c_rdata),
        .byte_done (i2c_byte_done),
        .busy      (),
        .ack_err   (i2c_ack_err),
        .done      (i2c_done),
        .scl       (scl),
        .sda       (sda)
    );

    //--------------------------------------------------------------
    // 方向判决 (组合)
    //--------------------------------------------------------------
    function [15:0] abs16;
        input [15:0] a, b;
        begin
            abs16 = (a > b) ? (a - b) : (b - a);
        end
    endfunction

    wire [15:0] dud = abs16(sum_u, sum_d);
    wire [15:0] dlr = abs16(sum_l, sum_r);
    wire        vert_wins = (dud > (dlr << 1)) && (dud >= GEST_MIN);
    wire        horz_wins = (dlr > (dud << 1)) && (dlr >= GEST_MIN);

    //--------------------------------------------------------------
    // 主状态机
    //--------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= ST_BOOT; cnt <= 100 * MS; cfg_idx <= 4'd0; gfifo_n <= 2'd0;
            sum_u <= 0; sum_d <= 0; sum_l <= 0; sum_r <= 0; any_data <= 1'b0;
            gest_up <= 0; gest_down <= 0; gest_left <= 0; gest_right <= 0;
            sensor_ok <= 0;
            i2c_go <= 0; i2c_rd <= 0; i2c_reg <= 0; i2c_wdata <= 0; i2c_len <= 1;
        end else begin
            i2c_go   <= 1'b0;
            gest_up   <= 1'b0;
            gest_down <= 1'b0;
            gest_left <= 1'b0;
            gest_right<= 1'b0;

            case (st)
            //----------------------------------------------------------
            ST_BOOT: begin                       // 上电等待
                if (cnt == 32'd0) st <= ST_ID;
                else              cnt <= cnt - 32'd1;
            end
            //----------------------------------------------------------
            ST_ID: begin                          // 读 ID (热插拔支持)
                i2c_go <= 1'b1; i2c_rd <= 1'b1;
                i2c_reg <= REG_ID; i2c_len <= 8'd1;
                st <= ST_ID_W;
            end
            ST_ID_W: if (i2c_done) begin
                if (!i2c_ack_err && i2c_rdata == CHIP_ID) begin
                    cfg_idx <= 4'd0;
                    st <= ST_CFG;
                end else begin
                    sensor_ok <= 1'b0;
                    cnt <= RETRY_MS * MS;
                    st <= ST_RETRY;
                end
            end
            //----------------------------------------------------------
            ST_CFG: begin                         // 逐条写配置
                i2c_go <= 1'b1; i2c_rd <= 1'b0;
                i2c_reg <= cfg_reg; i2c_wdata <= cfg_dat; i2c_len <= 8'd1;
                st <= ST_CFG_W;
            end
            ST_CFG_W: if (i2c_done) begin
                if (i2c_ack_err) begin
                    sensor_ok <= 1'b0;
                    cnt <= RETRY_MS * MS;
                    st <= ST_RETRY;
                end else begin
                    cnt <= cfg_gapms * MS;
                    st <= ST_GAP;
                end
            end
            ST_GAP: if (cnt == 32'd0) begin
                if (cfg_idx == CFG_LAST) begin
                    sensor_ok <= 1'b1;
                    cnt <= POLL_GAP * MS;
                    st <= ST_POLL_D;
                end else begin
                    cfg_idx <= cfg_idx + 4'd1;
                    st <= ST_CFG;
                end
            end else cnt <= cnt - 32'd1;
            //----------------------------------------------------------
            ST_POLL_D: begin                      // 轮询间隔
                if (cnt == 32'd0) st <= ST_GP;
                else              cnt <= cnt - 32'd1;
            end
            ST_GP: begin                          // 读 GSTATUS
                i2c_go <= 1'b1; i2c_rd <= 1'b1;
                i2c_reg <= REG_GSTATUS; i2c_len <= 8'd1;
                st <= ST_GP_W;
            end
            ST_GP_W: if (i2c_done) begin
                if (i2c_ack_err) begin
                    sensor_ok <= 1'b0;
                    cnt <= RETRY_MS * MS;
                    st <= ST_RETRY;
                end else if (i2c_rdata[1]) begin  // GVALID
                    gfifo_n <= 2'd0;
                    st <= ST_GF;
                end else begin                    // FIFO 空 -> 判决
                    st <= ST_JUDGE;
                end
            end
            //----------------------------------------------------------
            ST_GF: begin                          // 连读 GFIFO U/D/L/R
                i2c_go <= 1'b1; i2c_rd <= 1'b1;
                i2c_reg <= REG_GFIFO; i2c_len <= 8'd4;
                st <= ST_GF_W;
            end
            ST_GF_W: begin                        // 逐字节抓取累加
                if (i2c_byte_done) begin
                    case (gfifo_n)
                    2'd0: sum_u <= sum_u + {8'd0, i2c_rdata};
                    2'd1: sum_d <= sum_d + {8'd0, i2c_rdata};
                    2'd2: sum_l <= sum_l + {8'd0, i2c_rdata};
                    2'd3: sum_r <= sum_r + {8'd0, i2c_rdata};
                    endcase
                    any_data <= 1'b1;
                    gfifo_n  <= gfifo_n + 2'd1;
                end
                if (i2c_done) st <= ST_GP;        // 回去再看 FIFO 是否已空
            end
            //----------------------------------------------------------
            ST_JUDGE: begin                       // 手势判决
                if (any_data) begin
                    if      (vert_wins && (sum_u > sum_d)) begin gest_up   <= 1'b1; sensor_ok <= 1'b1; end
                    else if (vert_wins)                    begin gest_down <= 1'b1; sensor_ok <= 1'b1; end
                    else if (horz_wins && (sum_l > sum_r)) begin gest_left <= 1'b1; sensor_ok <= 1'b1; end
                    else if (horz_wins)                    begin gest_right<= 1'b1; sensor_ok <= 1'b1; end
                    // 斜挥/幅度不足: 无事件
                end
                sum_u <= 0; sum_d <= 0; sum_l <= 0; sum_r <= 0;
                any_data <= 1'b0;
                cnt <= POLL_GAP * MS;
                st <= ST_POLL_D;
            end
            //----------------------------------------------------------
            ST_RETRY: begin                       // 失败延时重试
                if (cnt == 32'd0) st <= ST_ID;
                else              cnt <= cnt - 32'd1;
            end
            default: st <= ST_BOOT;
            endcase
        end
    end

endmodule
