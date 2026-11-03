//======================================================================
// uart_tx —— 8N1 发送器, 波特率与 uart_rx 一致 (CLK_PER_BIT=166 @1.59MHz = 9.6k
//            = 113.6 kbaud, 与网页/蓝牙模块的 115200 相差 1.2%, 可接受)
//
//   2026-11-01 新增: 蓝牙原来只收不发 (src/top.v:61 的老注释)。
//   加了它之后 60K -> JDY-31 的 RXD 就有信号了, 拓展④ 的「录音回传」
//   和「模块应答」才有物理通路。
//======================================================================
module uart_tx #(
    parameter integer CLK_PER_BIT = 166
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       tick,        // 采样节拍 (这里只用来做限速, 可接 1'b1)
    input  wire       send,        // 单拍脉冲: 把 byte_in 发出去
    input  wire [7:0] byte_in,
    output reg        tx,          // 空闲为高
    output reg        busy
);
    localparam integer CW = (CLK_PER_BIT <= 2) ? 2 : $clog2(CLK_PER_BIT);
    reg [CW-1:0]  div;
    reg [3:0]     bitn;            // 0=起始位, 1..8=数据, 9=停止
    reg [9:0]     sh;              // {停止, 数据[7:0], 起始}

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx <= 1'b1; busy <= 1'b0; div <= 0; bitn <= 4'd0; sh <= 10'h3ff;
        end else if (!busy) begin
            tx <= 1'b1;
            if (send) begin
                sh   <= {1'b1, byte_in, 1'b0};
                bitn <= 4'd0;
                div  <= 0;
                busy <= 1'b1;
                tx   <= 1'b0;      // 起始位立刻拉低
            end
        end else begin
            if (div == CLK_PER_BIT - 1) begin
                div <= 0;
                if (bitn == 4'd9) begin
                    busy <= 1'b0;
                    tx   <= 1'b1;
                    bitn <= 4'd0;
                end else begin
                    bitn <= bitn + 1'b1;
                    tx   <= sh[bitn + 1'b1];
                end
            end else begin
                div <= div + 1'b1;
            end
        end
    end
endmodule
