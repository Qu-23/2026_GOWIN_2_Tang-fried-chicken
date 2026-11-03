//======================================================================
//  File   : apds9960_top.v
//  Brief  : ACG525 (GW5A-25A) + APDS-9960 接近/红外实验顶层
//
//  现象：
//    - 传感器未通信成功（ID 不对 / 无 ACK）：LED 以约 3 Hz 闪烁
//    - 通信正常：LED 亮度跟随接近值 prox(0~255)，手越近越亮
//
//  参数：
//    I2C_FREQ         : SCL 频率，默认 100 kHz
//    PROX_THRESHOLD   : near 判定阈值（本实验只作状态输出）
//    LED_ACTIVE_HIGH  : 板载 LED 高电平点亮时设为 1（若现象反了改成 0）
//======================================================================
`timescale 1ns / 1ps

module apds9960_top #(
    parameter integer CLK_FREQ       = 50_000_000,
    parameter integer I2C_FREQ       = 100_000,
    parameter [7:0]   PROX_THRESHOLD = 8'd80,
    parameter         LED_ACTIVE_HIGH = 1
)(
    input  wire clk,        // 50 MHz (T9)
    input  wire rst_n,      // 复位按键，低有效 (B16)
    inout  wire scl,        // 接 APDS-9960 SCL
    inout  wire sda,        // 接 APDS-9960 SDA
    output wire led         // 板载 LED (D14)
);

    wire       i2c_go;
    wire       i2c_rd;
    wire       i2c_busy;
    wire       i2c_done;
    wire       i2c_ack_err;
    wire [7:0] i2c_reg;
    wire [7:0] i2c_wdata;
    wire [7:0] i2c_len;
    wire [7:0] i2c_rdata;

    wire [7:0] prox;
    wire       prox_valid;
    wire       near;
    wire       sensor_ok;

    //------------------------------------------------------------------
    // I2C 主机
    //------------------------------------------------------------------
    i2c_master #(
        .CLK_FREQ (CLK_FREQ),
        .SCL_FREQ (I2C_FREQ)
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
        .byte_done (),
        .busy      (i2c_busy),
        .ack_err   (i2c_ack_err),
        .done      (i2c_done),
        .scl       (scl),
        .sda       (sda)
    );

    //------------------------------------------------------------------
    // APDS-9960 控制器
    //------------------------------------------------------------------
    apds9960_ctrl #(
        .CLK_FREQ       (CLK_FREQ),
        .PROX_THRESHOLD (PROX_THRESHOLD)
    ) u_ctrl (
        .clk       (clk),
        .rst_n     (rst_n),
        .i2c_go    (i2c_go),
        .i2c_rd    (i2c_rd),
        .i2c_reg   (i2c_reg),
        .i2c_wdata (i2c_wdata),
        .i2c_len   (i2c_len),
        .i2c_rdata (i2c_rdata),
        .i2c_done  (i2c_done),
        .i2c_ack_err (i2c_ack_err),
        .prox      (prox),
        .prox_valid(prox_valid),
        .near      (near),
        .sensor_ok (sensor_ok)
    );

    //------------------------------------------------------------------
    // LED 指示：正常时 PWM 调光，异常时闪烁
    //------------------------------------------------------------------
    reg [15:0] pwm_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pwm_cnt <= 16'd0;
        else        pwm_cnt <= pwm_cnt + 1'b1;
    end

    reg [23:0] blink_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) blink_cnt <= 24'd0;
        else        blink_cnt <= blink_cnt + 1'b1;
    end

    wire pwm_out = (pwm_cnt[15:8] < prox);   // 8 bit 占空比，约 762 Hz
    wire led_int = sensor_ok ? pwm_out : blink_cnt[23];

    assign led = LED_ACTIVE_HIGH ? led_int : ~led_int;

endmodule
