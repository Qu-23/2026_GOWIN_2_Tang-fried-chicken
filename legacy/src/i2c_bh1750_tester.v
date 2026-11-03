//////////////////////////////////////////////////////////////////////////////////
// Module Name  : i2c_bh1750_tester
// Description  : BH1750 独立验证器 —— 可移植, 适配任意 FPGA 板卡
//                2026-11-01  嵌赛 ACG525 项目调试用
//
//   功能: ① 扫描 I2C 总线 (0x08~0x77), 应答者通过 UART 上报
//         ② 对 0x23 / 0x5C 发 0x10 连续测量, 每 ~300ms 读 2 字节上报
//   UART 协议 (115200 8N1, 串口助手 HEX 模式查看):
//         A5 <addr_byte>   : 扫描命中该地址 (addr_byte = 7bit地址<<1|W)
//         AC <hi> <lo>     : 一次测量读数 (0x10 模式, lux = 原始值)
//         99               : 总线上无任何设备 (每 2s 重扫一次)
//
//   接入方法 (以 DF7020P 为例, ~10 分钟):
//     1. Vivado 工程加入本文件, 例化: CLK_HZ = 板上时钟频率
//     2. XDC 4 个脚: clk / rst_n / SCL+SDA 两个普通 IO / tx 接板载 USB-UART
//     3. 共地 + 模块 3.3V; 串口助手 115200 HEX 模式:
//        健康模块应见 A5 46 (或 A5 B8), 之后每 ~300ms 一帧 AC xx xx 且随光强变化
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps

module i2c_bh1750_tester #(
    parameter CLK_HZ  = 50_000_000,
    parameter BAUD    = 115200,
    parameter BOOT_MS = 50,
    parameter WAIT_MS = 200,
    parameter GAP_MS  = 100
)(
    input  wire        clk,
    input  wire        rst_n,
    output reg         scl,
    output reg         sda_oe,
    input  wire        sda_in,
    output reg         tx
);

    //---------------- 节拍参数 ----------------
    localparam [15:0] TICK_DIV = CLK_HZ/200_000;      // I2C 1/4 位
    localparam [15:0] BAUD_DIV = CLK_HZ/BAUD;
    localparam [31:0] MS_CYC   = CLK_HZ/1000;
    localparam [31:0] BOOT_CYC = BOOT_MS * MS_CYC;
    localparam [31:0] WAIT_CYC = WAIT_MS * MS_CYC;
    localparam [31:0] GAP_CYC  = GAP_MS  * MS_CYC;
    localparam [31:0] NDV_CYC  = 2000 * MS_CYC;

    //---------------- 状态机 ----------------
    localparam [4:0]
        S_BOOT      = 5'd0,   // 上电等待
        S_SCAN_GO   = 5'd1,   // 发起扫描 START
        S_SCAN_TX   = 5'd2,   // 发扫描地址字节
        S_SCAN_STOP = 5'd3,
        S_PICK      = 5'd4,   // 选择运行地址
        S_NODEV     = 5'd5,   // 无设备: 报 99 并重扫
        S_CMD_GO    = 5'd6,   // 命令事务: START
        S_CMD_ADDR  = 5'd7,   // 发 run_w
        S_CMD_TX    = 5'd8,   // 发 0x10
        S_CMD_STOP  = 5'd9,
        S_WAIT      = 5'd10,  // 等测量
        S_RD_GO     = 5'd11,  // 读事务: START
        S_RD_ADDR   = 5'd12,
        S_RD_STRT   = 5'd13,  // 重复 START
        S_RD_ADD    = 5'd14,  // 发 run_r
        S_RD_HI     = 5'd15,
        S_RD_LO     = 5'd16,
        S_RD_STOP   = 5'd17,
        S_GAP       = 5'd18,
        S_ABORT     = 5'd19;  // NACK 恢复 -> 重扫描自愈

    reg [4:0]  state;
    reg [15:0] divcnt;
    reg        tick;
    reg [1:0]  qph;
    reg [7:0]  sh, hi_r;
    reg [3:0]  bitn;
    reg        ack_n;
    reg [31:0] mscnt;
    reg        scan_hit;
    reg        got23, got5c;
    reg [6:0]  scan_addr;
    reg [6:0]  run_addr;
    wire [7:0] scan_byte = {scan_addr, 1'b0};
    wire [7:0] run_w     = {run_addr, 1'b0};
    wire [7:0] run_r     = {run_addr, 1'b1};

    //---------------- 待发帧寄存器 (单写者: 主状态机) ----------------
    reg [7:0] f0, f1, f2;
    reg [1:0] fn;       // 帧长 0..3, 0=空
    reg       fv;       // 帧有效

    //---------------- UART TX + 帧发送 (单写者) ----------------
    reg [7:0]  tx_data;
    reg        tx_go;
    reg [7:0]  ush;
    reg [15:0] ucnt;
    reg [3:0]  ubit;
    reg        ubusy;
    reg [1:0]  sidx;

    // 帧发送: 逐字节交给 UART
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_data <= 8'h00; tx_go <= 1'b0; sidx <= 2'd0; fv <= 1'b0;
        end else begin
            tx_go <= 1'b0;
            if (fv && !ubusy && !tx_go) begin
                tx_data <= (sidx == 2'd0) ? f0 : (sidx == 2'd1) ? f1 : f2;
                tx_go   <= 1'b1;
                if (sidx == fn - 2'd1) begin
                    fv <= 1'b0; sidx <= 2'd0;
                end else begin
                    sidx <= sidx + 2'd1;
                end
            end
        end
    end

    // UART 移位输出 (115200 8N1)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx <= 1'b1; ubusy <= 1'b0; ucnt <= 16'd0; ubit <= 4'd0; ush <= 8'h00;
        end else if (!ubusy) begin
            tx <= 1'b1;
            if (tx_go) begin
                ubusy <= 1'b1; ubit <= 4'd0; ucnt <= 16'd0;
                tx <= 1'b0;                      // 起始位
                ush  <= tx_data;
            end
        end else if (ucnt >= BAUD_DIV - 1) begin
            ucnt <= 16'd0;
            if (ubit == 4'd9) begin
                ubusy <= 1'b0;                   // 停止位结束
            end else begin
                ubit <= ubit + 1'b1;
                tx   <= (ubit == 4'd8) ? 1'b1 : ush[ubit[2:0]];
            end
        end else begin
            ucnt <= ucnt + 1'b1;
        end
    end

    //---------------- I2C 节拍 ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            divcnt <= 0; tick <= 1'b0;
        end else if (divcnt >= TICK_DIV - 1) begin
            divcnt <= 0; tick <= 1'b1;
        end else begin
            divcnt <= divcnt + 1'b1; tick <= 1'b0;
        end
    end

    //---------------- 主状态机 ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_BOOT; scl <= 1'b1; sda_oe <= 1'b0; qph <= 2'd0;
            sh <= 8'h00; hi_r <= 8'h00; bitn <= 4'd0; ack_n <= 1'b0;
            mscnt <= 32'd0; scan_hit <= 1'b0;
            got23 <= 1'b0; got5c <= 1'b0; scan_addr <= 7'h08;
            run_addr <= 7'h23;
            f0 <= 8'h00; f1 <= 8'h00; f2 <= 8'h00; fn <= 2'd0;
        end else begin
            // 毫秒计数不受 tick 门控 (每 clk 递增)
            if (state == S_BOOT || state == S_WAIT || state == S_NODEV || state == S_GAP)
                mscnt <= mscnt + 1'b1;
            if (tick) begin
                qph <= qph + 2'd1;
                case (state)
                    //---------------- 上电等待 ----------------
                    S_BOOT: begin
                        scl <= 1'b1; sda_oe <= 1'b0;
                        if (mscnt >= BOOT_CYC - 1) begin
                            mscnt <= 0; qph <= 0; state <= S_SCAN_GO;
                        end
                    end
                    //---------------- 扫描 ----------------
                    S_SCAN_GO: begin
                        case (qph)
                            2'd0: sda_oe <= 1'b1;          // START
                            2'd1: scl    <= 1'b0;
                            2'd3: begin sh <= scan_byte; bitn <= 4'd8; state <= S_SCAN_TX; end
                            default: ;
                        endcase
                    end
                    S_SCAN_TX: begin
                        case (qph)
                            2'd0: begin scl <= 1'b0; sda_oe <= (bitn != 0) ? ~sh[7] : 1'b0; end
                            2'd1: scl <= 1'b1;
                            2'd2: if (bitn == 0) ack_n <= sda_in;
                            2'd3: begin
                                scl <= 1'b0;
                                if (bitn != 0) begin
                                    sh <= {sh[6:0], 1'b0}; bitn <= bitn - 1;
                                end else begin
                                    scan_hit <= ~ack_n;
                                    state    <= S_SCAN_STOP;
                                end
                            end
                            default: ;
                        endcase
                    end
                    S_SCAN_STOP: begin
                        case (qph)
                            2'd0: sda_oe <= 1'b1;
                            2'd1: scl    <= 1'b1;
                            2'd2: sda_oe <= 1'b0;
                            2'd3: begin
                                qph <= 2'd0;
                                if (scan_hit) begin
                                    if      (scan_addr == 7'h23) got23 <= 1'b1;
                                    else if (scan_addr == 7'h5C) got5c <= 1'b1;
                                    if (!fv) begin               // 上报: A5 addr_byte
                                        f0 <= 8'hA5; f1 <= scan_byte; fn <= 2'd2; fv <= 1'b1;
                                    end
                                end
                                if (scan_addr == 7'h77) begin
                                    scan_addr <= 7'h08;
                                    state     <= S_PICK;
                                end else begin
                                    scan_addr <= scan_addr + 1'b1;
                                    state     <= S_SCAN_GO;
                                end
                            end
                            default: ;
                        endcase
                    end
                    //---------------- 选择运行地址 ----------------
                    S_PICK: begin
                        if (got23)      run_addr <= 7'h23;
                        else if (got5c) run_addr <= 7'h5C;
                        if (got23 || got5c) begin
                            qph <= 2'd0; state <= S_CMD_GO;
                        end else begin
                            mscnt <= 32'd0; state <= S_NODEV;
                        end
                    end
                    S_NODEV: begin                     // 无设备: 报 99, 周期重扫
                        scl <= 1'b1; sda_oe <= 1'b0;
                        if (mscnt >= NDV_CYC - 1) begin
                            mscnt <= 0; qph <= 0;
                            if (!fv) begin
                                f0 <= 8'h99; fn <= 2'd1; fv <= 1'b1;
                            end
                            scan_addr <= 7'h08; state <= S_SCAN_GO;
                        end
                    end
                    //---------------- 命令事务: START -> run_w -> 0x10 -> STOP ----------------
                    S_CMD_GO: begin
                        case (qph)
                            2'd0: sda_oe <= 1'b1;
                            2'd1: scl    <= 1'b0;
                            2'd3: begin sh <= run_w; bitn <= 4'd8; state <= S_CMD_ADDR; end
                            default: ;
                        endcase
                    end
                    S_CMD_ADDR: begin
                        case (qph)
                            2'd0: begin scl <= 1'b0; sda_oe <= (bitn != 0) ? ~sh[7] : 1'b0; end
                            2'd1: scl <= 1'b1;
                            2'd2: if (bitn == 0) ack_n <= sda_in;
                            2'd3: begin
                                scl <= 1'b0;
                                if (bitn != 0) begin
                                    sh <= {sh[6:0], 1'b0}; bitn <= bitn - 1;
                                end else if (ack_n) begin
                                    state <= S_ABORT;   // -> 重扫描自愈
                                end else begin
                                    sh <= 8'h10; bitn <= 4'd8; state <= S_CMD_TX;
                                end
                            end
                            default: ;
                        endcase
                    end
                    S_CMD_TX: begin
                        case (qph)
                            2'd0: begin scl <= 1'b0; sda_oe <= (bitn != 0) ? ~sh[7] : 1'b0; end
                            2'd1: scl <= 1'b1;
                            2'd2: if (bitn == 0) ack_n <= sda_in;
                            2'd3: begin
                                scl <= 1'b0;
                                if (bitn != 0) begin
                                    sh <= {sh[6:0], 1'b0}; bitn <= bitn - 1;
                                end else if (ack_n) begin
                                    state <= S_ABORT;
                                end else begin
                                    state <= S_CMD_STOP;
                                end
                            end
                            default: ;
                        endcase
                    end
                    S_CMD_STOP: begin
                        case (qph)
                            2'd0: sda_oe <= 1'b1;
                            2'd1: scl    <= 1'b1;
                            2'd2: sda_oe <= 1'b0;
                            2'd3: begin qph <= 2'd0; mscnt <= 32'd0; state <= S_WAIT; end
                            default: ;
                        endcase
                    end
                    S_WAIT: begin
                        scl <= 1'b1; sda_oe <= 1'b0;
                        if (mscnt >= WAIT_CYC - 1) begin
                            mscnt <= 0; qph <= 0; state <= S_RD_GO;
                        end
                    end
                    //---------------- 读事务 ----------------
                    S_RD_GO: begin
                        case (qph)
                            2'd0: sda_oe <= 1'b1;
                            2'd1: scl    <= 1'b0;
                            2'd3: begin sh <= run_w; bitn <= 4'd8; state <= S_RD_ADDR; end
                            default: ;
                        endcase
                    end
                    S_RD_ADDR: begin
                        case (qph)
                            2'd0: begin scl <= 1'b0; sda_oe <= (bitn != 0) ? ~sh[7] : 1'b0; end
                            2'd1: scl <= 1'b1;
                            2'd2: if (bitn == 0) ack_n <= sda_in;
                            2'd3: begin
                                scl <= 1'b0;
                                if (bitn != 0) begin
                                    sh <= {sh[6:0], 1'b0}; bitn <= bitn - 1;
                                end else if (ack_n) begin
                                    state <= S_ABORT;
                                end else begin
                                    state <= S_RD_STRT;
                                end
                            end
                            default: ;
                        endcase
                    end
                    S_RD_STRT: begin
                        case (qph)
                            2'd2: sda_oe <= 1'b1;          // Sr
                            2'd3: begin
                                scl <= 1'b0; sh <= run_r; bitn <= 4'd8; state <= S_RD_ADD;
                            end
                            default: ;
                        endcase
                    end
                    S_RD_ADD: begin
                        case (qph)
                            2'd0: begin scl <= 1'b0; sda_oe <= (bitn != 0) ? ~sh[7] : 1'b0; end
                            2'd1: scl <= 1'b1;
                            2'd2: if (bitn == 0) ack_n <= sda_in;
                            2'd3: begin
                                scl <= 1'b0;
                                if (bitn != 0) begin
                                    sh <= {sh[6:0], 1'b0}; bitn <= bitn - 1;
                                end else if (ack_n) begin
                                    state <= S_ABORT;
                                end else begin
                                    sh <= 8'h00; bitn <= 4'd9; state <= S_RD_HI;
                                end
                            end
                            default: ;
                        endcase
                    end
                    S_RD_HI, S_RD_LO: begin
                        case (qph)
                            2'd0: begin
                                scl    <= 1'b0;
                                sda_oe <= (bitn == 4'd1) ? (state == S_RD_HI) : 1'b0;
                            end
                            2'd1: scl <= 1'b1;
                            2'd2: if (bitn != 4'd1) sh <= {sh[6:0], sda_in};
                            2'd3: begin
                                scl <= 1'b0;
                                if (bitn != 4'd1) bitn <= bitn - 1;
                                else if (state == S_RD_HI) begin
                                    hi_r <= sh; bitn <= 4'd9; state <= S_RD_LO;
                                end else begin
                                    state <= S_RD_STOP;
                                end
                            end
                            default: ;
                        endcase
                    end
                    S_RD_STOP: begin
                        case (qph)
                            2'd0: sda_oe <= 1'b1;
                            2'd1: scl    <= 1'b1;
                            2'd2: sda_oe <= 1'b0;
                            2'd3: begin
                                qph <= 2'd0;
                                if (!fv) begin              // 上报: AC hi lo
                                    f0 <= 8'hAC; f1 <= hi_r; f2 <= sh; fn <= 2'd3; fv <= 1'b1;
                                end
                                mscnt <= 32'd0; state <= S_GAP;
                            end
                            default: ;
                        endcase
                    end
                    S_GAP: begin
                        scl <= 1'b1; sda_oe <= 1'b0;
                        if (mscnt >= GAP_CYC - 1) begin
                            mscnt <= 0; qph <= 0; state <= S_CMD_GO;
                        end
                    end
                    //---------------- NACK 恢复: 清标志重扫描 (自愈) ----------------
                    S_ABORT: begin
                        case (qph)
                            2'd0: begin scl <= 1'b0; sda_oe <= 1'b0; end
                            2'd1: sda_oe <= 1'b1;
                            2'd2: scl    <= 1'b1;
                            2'd3: begin
                                sda_oe <= 1'b0; qph <= 2'd0;
                                got23 <= 1'b0; got5c <= 1'b0;
                                scan_addr <= 7'h08;
                                state  <= S_SCAN_GO;
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
