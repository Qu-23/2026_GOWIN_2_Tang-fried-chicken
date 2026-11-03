//////////////////////////////////////////////////////////////////////////////////
// Module Name : uart_tx
// Description : 115200 8N1 发送器
//
//   时钟 9MHz / 78 = 115384.6 bps，相对 115200 误差 +0.16%
//   对端 Mega 60K 的 uart_rx 采样时钟 1.59MHz/14 = 113571 bps（-1.4%），
//   两者合计约 1.3%，10 bit 累积偏差 0.13 bit，中点采样安全。
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps

module uart_tx #(
    parameter integer CLKS_PER_BIT = 78
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data,       // 待发字节
    input  wire       start,      // 单周期启动脉冲
    output reg        tx,         // 串口输出（空闲高）
    output reg        busy,
    output reg        done        // 一字节发完的单周期脉冲
);

    localparam [1:0] S_IDLE  = 2'd0,
                     S_START = 2'd1,
                     S_DATA  = 2'd2,
                     S_STOP  = 2'd3;

    reg [1:0]  st;
    reg [15:0] cnt;
    reg [2:0]  bitn;
    reg [7:0]  sh;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st   <= S_IDLE;
            tx   <= 1'b1;
            cnt  <= 16'd0;
            bitn <= 3'd0;
            sh   <= 8'd0;
            busy <= 1'b0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            case (st)
                S_IDLE: begin
                    tx   <= 1'b1;
                    busy <= 1'b0;
                    cnt  <= 16'd0;
                    if (start) begin
                        sh   <= data;
                        busy <= 1'b1;
                        st   <= S_START;
                    end
                end

                S_START: begin
                    tx <= 1'b0;
                    if (cnt == CLKS_PER_BIT - 1) begin
                        cnt  <= 16'd0;
                        bitn <= 3'd0;
                        st   <= S_DATA;
                    end else
                        cnt <= cnt + 16'd1;
                end

                S_DATA: begin
                    tx <= sh[bitn];          // LSB first
                    if (cnt == CLKS_PER_BIT - 1) begin
                        cnt <= 16'd0;
                        if (bitn == 3'd7) st <= S_STOP;
                        else              bitn <= bitn + 3'd1;
                    end else
                        cnt <= cnt + 16'd1;
                end

                S_STOP: begin
                    tx <= 1'b1;
                    if (cnt == CLKS_PER_BIT - 1) begin
                        cnt  <= 16'd0;
                        st   <= S_IDLE;
                        done <= 1'b1;
                        busy <= 1'b0;
                    end else
                        cnt <= cnt + 16'd1;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
