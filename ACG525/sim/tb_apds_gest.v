`timescale 1ns/1ps
//======================================================================
//  tb_apds_gest.v : APDS-9960 手势引擎 TB
//  复用原 apds_tb.sv 的行为级从机模型骨架, 扩展:
//    - GFIFO 队列 (fifo_q / fifo_rd / fifo_wr), 读 0xFC..0xFF 出队
//    - GSTATUS(0xAF).GVALID 动态 = (fifo 非空)
//  场景: init 检查 -> UP / LEFT / 斜挥(拒判) / DOWN / RIGHT
//  DUT 用 CLK_FREQ=1MHz 加快仿真 (SCL ~125kHz)
//======================================================================
module tb_apds_gest;

    reg  clk   = 1'b0;
    reg  rst_n = 1'b0;
    tri1 scl;
    tri1 sda;

    wire g_up, g_dn, g_lf, g_rt;
    wire ok;

    always #500 clk = ~clk;     // 1 MHz

    //------------------------------------------------------------------
    // DUT
    //------------------------------------------------------------------
    apds9960_gest #(
        .CLK_FREQ (1_000_000),
        .SCL_FREQ (100_000),
        .GEST_MIN (16'd8),
        .RETRY_MS (10),
        .POLL_GAP (1)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .scl        (scl),
        .sda        (sda),
        .gest_up    (g_up),
        .gest_down  (g_dn),
        .gest_left  (g_lf),
        .gest_right (g_rt),
        .sensor_ok  (ok)
    );

    //------------------------------------------------------------------
    // I2C 从机模型 (骨架来自 apds_tb.sv)
    //------------------------------------------------------------------
    reg sda_oe_s = 1'b0;
    assign sda = sda_oe_s ? 1'b0 : 1'bz;

    reg [7:0] mem [0:255];
    reg [7:0] fifo_q [0:63];       // 手势 FIFO: U,D,L,R 4 字节/组
    integer   fifo_wr = 0, fifo_rd = 0;

    integer i, k, j;

    initial begin
        for (i = 0; i < 256; i = i + 1) mem[i] = 8'h00;
        mem[8'h92] = 8'hAB;                       // ID
    end

    reg [7:0] rxbyte, raddr, d8;
    reg       rd_mode, ackbit, got_data, got_sr;

    task rx_byte(output [7:0] d);
        begin
            d = 8'h00;
            for (k = 0; k < 8; k = k + 1) begin
                @(posedge scl);
                d = {d[6:0], sda};
            end
        end
    endtask

    task tx_ack(input ack);
        begin
            @(negedge scl);
            sda_oe_s = ack;
            @(posedge scl);
            @(negedge scl);
            sda_oe_s = 1'b0;
        end
    endtask

    task tx_byte(input [7:0] d, output ack);
        begin
            for (j = 7; j >= 0; j = j - 1) begin
                sda_oe_s = ~d[j];
                @(posedge scl);
                @(negedge scl);
            end
            sda_oe_s = 1'b0;
            @(posedge scl);
            ack = sda;
            @(negedge scl);
        end
    endtask

    integer n_start = 0, n_wr = 0, n_rd = 0;

    initial begin : slave
        forever begin
            @(negedge sda);
            if (scl) begin
                n_start = n_start + 1;
                rx_byte(rxbyte);
                if (rxbyte[7:1] == 7'h39) begin
                    rd_mode = rxbyte[0];
                    tx_ack(1'b1);
                    if (!rd_mode) begin
                        rx_byte(rxbyte);
                        raddr = rxbyte;
                        tx_ack(1'b1);
                        got_data = 1'b0;
                        got_sr   = 1'b0;
                        fork
                            begin : WDATA
                                rx_byte(d8);
                                got_data = 1'b1;
                            end
                            begin : WSR
                                while (!got_sr) begin
                                    @(negedge sda);
                                    if (scl) got_sr = 1'b1;
                                end
                            end
                        join_any
                        disable fork;
                        if (got_data) begin
                            mem[raddr] = d8;
                            n_wr = n_wr + 1;
                            $display("[%0t] slave: write reg=%02h data=%02h", $time, raddr, d8);
                            tx_ack(1'b1);
                        end else if (got_sr) begin
                            rx_byte(rxbyte);
                            if ((rxbyte[7:1] == 7'h39) && rxbyte[0]) begin
                                tx_ack(1'b1);
                                ackbit = 1'b0;
                                while (!ackbit) begin
                                    if (raddr == 8'hAF)
                                        tx_byte((fifo_rd < fifo_wr) ? 8'h02 : 8'h00, ackbit);
                                    else if (raddr >= 8'hFC) begin
                                        tx_byte((fifo_rd < fifo_wr) ? fifo_q[fifo_rd % 64] : 8'h00, ackbit);
                                        if (fifo_rd < fifo_wr) fifo_rd = fifo_rd + 1;
                                    end
                                    else
                                        tx_byte(mem[raddr], ackbit);
                                    n_rd = n_rd + 1;
                                    raddr = raddr + 1'b1;
                                end
                            end else begin
                                tx_ack(1'b0);
                            end
                        end
                    end else begin
                        ackbit = 1'b0;
                        while (!ackbit) begin
                            tx_byte(mem[raddr], ackbit);
                            n_rd = n_rd + 1;
                            raddr = raddr + 1'b1;
                        end
                    end
                end else begin
                    tx_ack(1'b0);
                end
            end
        end
    end

    //------------------------------------------------------------------
    // 事件计数
    //------------------------------------------------------------------
    integer ev_up = 0, ev_dn = 0, ev_lf = 0, ev_rt = 0;
    always @(g_up)  if (g_up)  begin ev_up = ev_up + 1; $display("[%0t] GEST UP",    $time); end
    always @(g_dn)  if (g_dn)  begin ev_dn = ev_dn + 1; $display("[%0t] GEST DOWN",  $time); end
    always @(g_lf)  if (g_lf)  begin ev_lf = ev_lf + 1; $display("[%0t] GEST LEFT",  $time); end
    always @(g_rt)  if (g_rt)  begin ev_rt = ev_rt + 1; $display("[%0t] GEST RIGHT", $time); end

    // 手势注入: 4 字节/组
    task load_fifo(input [7:0] u, input [7:0] d, input [7:0] l, input [7:0] r, input [3:0] groups);
        integer g;
        begin
            for (g = 0; g < groups; g = g + 1) begin
                fifo_q[fifo_wr % 64] = u; fifo_wr = fifo_wr + 1;
                fifo_q[fifo_wr % 64] = d; fifo_wr = fifo_wr + 1;
                fifo_q[fifo_wr % 64] = l; fifo_wr = fifo_wr + 1;
                fifo_q[fifo_wr % 64] = r; fifo_wr = fifo_wr + 1;
            end
        end
    endtask

    integer errors = 0;
    task check(input cond, input [255:0] msg);
        begin
            if (cond) $display("PASS : %0s", msg);
            else begin
                $display("FAIL : %0s", msg);
                errors = errors + 1;
            end
        end
    endtask

    //------------------------------------------------------------------
    // 主流程
    //------------------------------------------------------------------
    initial begin
        $timeformat(-6, 3, " ms", 8);
        rst_n = 1'b0;
        #2000;
        rst_n = 1'b1;

        // 等 init 完成 (BOOT 100ms + 配置)
        wait (ok === 1'b1);
        $display("---- init done @ %0t, wr=%0d rd=%0d ----", $time, n_wr, n_rd);

        check(mem[8'h80] === 8'h41, "ENABLE(0x80)=0x41 (PON|GEN)");
        check(mem[8'hA1] === 8'h48, "GCONF2(0xA1)=0x48");
        check(mem[8'hA7] === 8'h87, "GPULSE(0xA7)=0x87");
        check(mem[8'hAA] === 8'h50, "GPENTH(0xAA)=0x50");
        check(mem[8'hAB] === 8'h30, "GEXTH(0xAB)=0x30");

        // ① UP 手势: U 主导 (sumU=14, sumD=0, L=R=3)
        load_fifo(8'd5, 8'd0, 8'd1, 8'd1, 4'd3);
        #10_000_000;                            // 10 ms
        check(ev_up == 1 && ev_dn == 0, "① UP gesture detected");
        check(ev_lf == 0 && ev_rt == 0, "① no spurious L/R");

        // ② LEFT 手势: L 主导 (sumL=9, sumR=0, U=D=2)
        load_fifo(8'd1, 8'd1, 8'd5, 8'd0, 4'd2);
        #10_000_000;
        check(ev_lf == 1 && ev_rt == 0, "② LEFT gesture detected");
        check(ev_up == 1 && ev_dn == 0, "② no spurious U/D");

        // ③ 斜挥 (U 与 L 均衡): dud=3, dlr=3 -> 拒判
        load_fifo(8'd3, 8'd2, 8'd3, 8'd2, 4'd3);
        #10_000_000;
        check(ev_up == 1 && ev_dn == 0 && ev_lf == 1 && ev_rt == 0,
              "③ diagonal rejected (no new event)");

        // ④ DOWN 手势
        load_fifo(8'd0, 8'd6, 8'd1, 8'd1, 4'd2);
        #10_000_000;
        check(ev_dn == 1, "④ DOWN gesture detected");

        // ⑤ RIGHT 手势
        load_fifo(8'd1, 8'd1, 8'd0, 8'd6, 4'd2);
        #10_000_000;
        check(ev_rt == 1, "⑤ RIGHT gesture detected");

        if (errors == 0) $display("==== ALL CHECKS PASSED ====");
        else             $display("==== %0d CHECK(S) FAILED ====", errors);
        $finish;
    end

    initial begin
        #800_000_000;                            // 800 ms 超时
        $display("TIMEOUT");
        $finish;
    end

endmodule
