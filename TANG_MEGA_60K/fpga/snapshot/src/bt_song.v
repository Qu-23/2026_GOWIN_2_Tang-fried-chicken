//=======================================================================
// bt_song —— 手机下发曲谱, 60K 脱机自动演奏 (2026-11-02)
//
// 赛题拓展④ "在线曲谱下载": 网页把曲谱下载到手机, 再经蓝牙推给 FPGA,
// 之后手机可以断开, 60K 自己把这首曲子弹完 —— 这才叫"下载到乐器"。
//
// 文本协议 (每行一条, 大小写不限, 行尾 CR/LF 都行):
//     S<tempo>        设速度 (40..240 拍/分钟), 同时清空缓冲区
//     K<note>,<beats> 追加一个音; note 0 = 休止符; beats 以四分音符为 1
//     P               从头播放
//     X               停止
//
// 例:
//     S100
//     K60,1
//     K62,0.5
//     P
//
//  全程无除法器:
//    - 时值按 1/16 拍存 (7bit, 最长 8 拍)。小数位用查表: 十分位 d1 贡献
//      round(d1*1.6), 百分位 d2 贡献 round(d2*0.16)。
//    - 节拍用 26bit 相位累加器: 每个 tick 加 tempo*16, 累到 60*TICK_HZ
//      就是走完一个 1/16 拍, 减掉再继续。等价于除法但只有加法器和比较器。
//
// 存储: 128 个音 x {7bit 音高, 7bit 时值} = 2 块小 BSRAM。
//=======================================================================
`default_nettype none

module bt_song #(
    parameter integer CLK_PER_BIT = 14,
    parameter integer TICK_HZ     = 99300,
    parameter integer MAX_NOTES   = 128
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rx,
    input  wire        play_btn,     // 板载按键, 上升沿 = 播放/停止
    output reg         s_on,         // 单拍脉冲: 发一个音
    output reg  [6:0]  s_note,
    output reg  [7:0]  s_vel,
    output reg         s_off,        // 单拍脉冲: 松开
    output reg         playing,
    output reg  [7:0]  s_pos,
    output reg         active,       // 1 = 正在收命令 (屏蔽心跳)
    output wire [7:0]  ncount       // 已存音符数 (给 LED / 调试)
);

    localparam [7:0]  MAXN  = MAX_NOTES[7:0];
    localparam [25:0] PH_1S = TICK_HZ * 60;      // 一个 1/16 拍的相位满量

    // ---------------- 字节接收 (10 位 8N1, 中点采样) ----------------
    localparam integer CW = 8;
    reg [2:0]    rx_sync;
    wire         rx_s = rx_sync[2];
    reg [2:0]    bstate;
    reg [CW-1:0] bcnt;
    reg [3:0]    bitn;
    reg [7:0]    shft;
    reg          byte_vld;
    reg [7:0]    byte_now;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rx_sync <= 3'b111;
        else        rx_sync <= {rx_sync[1:0], rx};
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
                3'd0: if (!rx_s) begin
                          bstate <= 3'd1;
                          bcnt   <= {CW{1'b0}};
                      end
                3'd1: begin                       // 半位宽 -> 起始位中点
                    if (bcnt == (CLK_PER_BIT / 2)) begin
                        bstate <= 3'd2;
                        bcnt   <= {CW{1'b0}};
                        bitn   <= 4'd0;
                    end else bcnt <= bcnt + 1'b1;
                end
                3'd2: begin                       // 逐位采样 (LSB first)
                    if (bcnt == (CLK_PER_BIT - 1)) begin
                        bcnt <= {CW{1'b0}};
                        shft <= {rx_s, shft[7:1]};
                        if (bitn == 4'd7) bstate <= 3'd3;
                        else              bitn   <= bitn + 4'd1;
                    end else bcnt <= bcnt + 1'b1;
                end
                3'd3: begin                       // 停止位
                    if (bcnt == (CLK_PER_BIT - 1)) begin
                        bstate   <= 3'd0;
                        bcnt     <= {CW{1'b0}};
                        byte_now <= shft;
                        byte_vld <= 1'b1;
                    end else bcnt <= bcnt + 1'b1;
                end
                default: bstate <= 3'd0;
            endcase
        end
    end

    // ---------------- 命令解析 ----------------
    localparam [1:0] P_IDLE = 2'd0, P_SPD = 2'd1, P_KN = 2'd2, P_KB = 2'd3;

    reg [1:0]  pst;
    reg [7:0]  ncount_r;
    reg [7:0]  acc;
    reg [3:0]  d1;             // 十分位
    reg [3:0]  d2;             // 百分位
    reg        fd1, fd2;
    reg [7:0]  tempo;
    reg        wr_en;
    reg [6:0]  wr_note;
    reg [6:0]  wr_len;
    reg        start_req;
    reg        stop_req;
    reg        clr_req;        // 新曲谱: 清空缓冲区 (单拍, 送给存储块)
    // active 超时: 约 0.6 秒没收到字节就放开心跳 (16bit @ 1.59MHz)
    //    active 是 output reg, 只能有一个 always 块驱动 (Gowin 会报
    //     ERROR (EX2000) multiple places)。所以这里只产生 idle_to 脉冲,
    //     真正的 active <= 0 在下面这个解析块里做。
    //    声明必须在使用之前 —— Verilog 里后声明的 wire 会被先当成隐式网线。
    reg  [15:0] idle_cnt;
    wire        idle_to = (idle_cnt == 16'hFFFF) && !byte_vld;

    wire is_digit = (byte_now >= 8'h30) && (byte_now <= 8'h39);
    wire is_eol   = (byte_now == 8'h0D) || (byte_now == 8'h0A);
    wire is_S = (byte_now == 8'h53) || (byte_now == 8'h73);
    wire is_K = (byte_now == 8'h4B) || (byte_now == 8'h6B);
    wire is_P = (byte_now == 8'h50) || (byte_now == 8'h70);
    wire is_X = (byte_now == 8'h58) || (byte_now == 8'h78);
    wire is_cmd = is_S | is_K | is_P | is_X;

    // Binary keyboard/effect frames share this UART with text scores.
    // A MIDI note of 80 is ASCII P, 83 is S, and velocity may be LF.
    reg [1:0] binary_left;
    always @(posedge clk or negedge rst_n)
      if(!rst_n) binary_left<=0;
      else if(byte_vld) begin
        if(binary_left!=0) binary_left<=binary_left-1'b1;
        else if(byte_now==8'hA5) binary_left<=3;
      end

    // 十分位查表: round(d*16/10)
    function [4:0] tenth16;
        input [3:0] d;
        begin
            case (d)
                4'd0: tenth16 = 5'd0;
                4'd1: tenth16 = 5'd2;
                4'd2: tenth16 = 5'd3;
                4'd3: tenth16 = 5'd5;
                4'd4: tenth16 = 5'd6;
                4'd5: tenth16 = 5'd8;
                4'd6: tenth16 = 5'd10;
                4'd7: tenth16 = 5'd11;
                4'd8: tenth16 = 5'd13;
                default: tenth16 = 5'd14;
            endcase
        end
    endfunction

    // 时值 = 整数拍*16 + 十分位*1.6 + 百分位*0.16
    wire [11:0] len_calc = ({4'd0, acc} << 4) + {7'd0, tenth16(d1)}
                         + {11'd0, (d2 >= 4'd7)};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pst       <= P_IDLE;
            acc       <= 8'd0;
            d1        <= 4'd0;
            d2        <= 4'd0;
            fd1       <= 1'b0;
            fd2       <= 1'b0;
            tempo     <= 8'd100;
            wr_en     <= 1'b0;
            wr_note   <= 7'd0;
            wr_len    <= 7'd0;
            start_req <= 1'b0;
            stop_req  <= 1'b0;
            clr_req   <= 1'b0;
            active    <= 1'b0;
        end else begin
            wr_en     <= 1'b0;
            start_req <= 1'b0;
            stop_req  <= 1'b0;
            clr_req   <= 1'b0;

            if (byte_vld && binary_left==0 && byte_now!=8'hA5) begin
                active <= 1'b1;
            end else if (idle_to) begin
                active <= 1'b0;      //  active 只能在这一个块里赋值 (见文件末尾注释)
            end
            if (byte_vld) begin
                if(binary_left!=0) begin
                    // Binary payload must never enter the score state machine.
                end else if(byte_now==8'hA5) begin
                    pst<=P_IDLE;acc<=0;d1<=0;d2<=0;fd1<=0;fd2<=0;
                end else begin
                case (pst)
                    //---------------------------------------------
                    P_IDLE: begin
                        acc <= 8'd0;
                        d1  <= 4'd0;
                        d2  <= 4'd0;
                        fd1 <= 1'b0;
                        fd2 <= 1'b0;
                        if      (is_S) pst <= P_SPD;
                        else if (is_K) pst <= P_KN;
                        else if (is_P) start_req <= 1'b1;
                        else if (is_X) stop_req  <= 1'b1;
                    end
                    //---------------------------------------------
                    P_SPD: begin
                        if (is_digit) begin
                            if (acc <= 8'd23) acc <= acc * 8'd10 + (byte_now - 8'h30);
                        end else if (is_eol || is_cmd) begin
                            tempo  <= (acc < 8'd40)  ? 8'd40 :
                                      (acc > 8'd240) ? 8'd240 : acc;
                            clr_req  <= 1'b1;        // 新曲谱: 清空 (由存储块执行)
                            pst    <= P_IDLE;
                        end
                    end
                    //---------------------------------------------
                    P_KN: begin
                        if (is_digit) begin
                            if (acc <= 8'd11) acc <= acc * 8'd10 + (byte_now - 8'h30);
                        end else if (byte_now == 8'h2C) begin        // ','
                            wr_note <= acc[6:0];
                            acc     <= 8'd0;
                            pst     <= P_KB;
                        end else if (is_eol) begin
                            wr_note <= acc[6:0];
                            wr_len  <= 7'd16;                    // 默认一拍
                            wr_en   <= 1'b1;
                            acc     <= 8'd0;
                            pst     <= P_IDLE;
                        end
                    end
                    //---------------------------------------------
                    P_KB: begin
                        if (is_digit) begin
                            if (!fd1) begin
                                if (acc <= 8'd7) acc <= acc * 8'd10 + (byte_now - 8'h30);
                            end else if (!fd2) begin
                                d1  <= byte_now[3:0];
                                fd2 <= 1'b1;
                            end else begin
                                d2 <= byte_now[3:0];
                            end
                        end else if (byte_now == 8'h2E) begin        // '.'
                            fd1 <= 1'b1;
                        end else if (is_eol || is_cmd) begin
                            wr_len <= (len_calc == 12'd0)  ? 7'd16 :
                                      (len_calc > 12'd127) ? 7'd127 : len_calc[6:0];
                            wr_en  <= 1'b1;
                            acc    <= 8'd0;
                            d1     <= 4'd0;
                            d2     <= 4'd0;
                            fd1    <= 1'b0;
                            fd2    <= 1'b0;
                            pst    <= P_IDLE;
                            if (is_cmd) begin                // 同一行紧跟下一条
                                if      (is_S) pst <= P_SPD;
                                else if (is_K) pst <= P_KN;
                                else if (is_P) start_req <= 1'b1;
                                else if (is_X) stop_req  <= 1'b1;
                            end
                        end
                    end
                    //---------------------------------------------
                    default: pst <= P_IDLE;
                endcase
                end
            end
        end
    end

    // ---------------- 曲谱存储 ----------------
    //   必须能推断成 BSRAM, 否则 128 深 x 7bit x 2 = 1792 个触发器,
    //    实测 main_X 因此 Register 从 1197 涨到 3158 (+1961) 而 BSRAM
    //    一块没多。BSRAM 推断的两条硬规矩:
    //      1. 存储块里不能有复位 —— 只写 posedge clk, 用 valid 位保护,
    //         不要去清表 (清表的复位会把整个阵列推成触发器)。
    //      2. 读口也要同步 —— 播放器原来直接 mem_note[cur] 组合读,
    //         同步读才推得出 BSRAM 的输出寄存器。
    //    改法: 用 q_note/q_len 两个同步读寄存器, 换音那一拍先给出地址,
    //    下一拍 (sw_st==SW_ADDR) 数据已经在手上, 正好拿去发 s_on。
    reg [6:0] mem_note [0:MAX_NOTES-1];
    reg [6:0] mem_len  [0:MAX_NOTES-1];

    reg [6:0] rd_addr;
    reg [6:0] q_note, q_len;

    always @(posedge clk) begin
        if (wr_en && ncount_r < MAXN) begin
            mem_note[ncount_r[6:0]] <= wr_note;
            mem_len [ncount_r[6:0]] <= wr_len;
        end
    end

    // 同步读口: rd_addr 由播放器在"决定换音"那一拍给出
    always @(posedge clk) begin
        q_note <= mem_note[rd_addr];
        q_len  <= mem_len [rd_addr];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ncount_r <= 8'd0;
        else if (clr_req) ncount_r <= 8'd0;
        else if (wr_en && ncount_r < MAXN) ncount_r <= ncount_r + 8'd1;
    end
    assign ncount = ncount_r;

    // ---------------- 播放器 ----------------
    //  left = 本音还剩多少个 1/16 拍;  每走完一个 1/16 拍减 1, 减到 0 换音。
    reg        play_d;
    wire       play_rise = play_btn & ~play_d;
    // 停止条件提成一根线: 换音第三步要用它做门控 (见下面 sw_st 段)
    wire       stop_now  = stop_req | (play_rise & playing);

    reg [7:0]  cur;
    reg [6:0]  left;
    reg [25:0] ph;
    reg        note_on_r;
    reg        start_now;      // 单拍: 立即取第一个音
    //  换音时 s_off 与 s_on 绝不能同拍: synth_engine 的 ev_on/ev_off
    //   (src/synth_engine.v:198-207) 是 if/else if, on 优先,
    //   同拍来的 off 会被整个丢掉 —— 上一个音就再也松不开了,
    //   32 个声部很快全被占死。所以换音拆成三步走:
    //     sw_st=0 走拍 → 判到 left==0, 发 s_off, 给出读地址 rd_addr, sw_st=1
    //     sw_st=1 等一拍 (同步读口把数据打出来)
    //     sw_st=2 直接用 q_note/q_len 发 s_on、装载 left, sw_st=0
    //   三步 = 1.9us @1.59MHz, 远小于一个 tick。
    localparam [1:0] SW_IDLE = 2'd0, SW_ADDR = 2'd1, SW_LATCH = 2'd2;
    reg [1:0]  sw_st;
    wire       sw_busy = (sw_st != SW_IDLE);

    wire [25:0] ph_inc = {14'd0, tempo, 4'd0};      // tempo * 16
    wire [25:0] ph_sum = ph + ph_inc;

    //  相位累加器必须每个 tick 加一次, 不是每个 clk。
    //   本模块跑在 1.589MHz, 而 PH_1S 是按 TICK_HZ(99.3k) 标定的 ——
    //   clk/tick 正好 16 倍, 所以累加要除以 16, 否则整曲快 16 倍。
    //   (2026-11-02 实测: K60,1 @120BPM 本该响 0.5s, 实际只响 31.2ms。)
    //   用 4bit 自由计数器做时钟使能, 不引入除法器, 代价 4 个触发器。
    reg  [3:0]  tick_div;
    wire        tick_en = (tick_div == 4'd15);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) tick_div <= 4'd0;
        else        tick_div <= tick_div + 4'd1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            play_d    <= 1'b0;
            playing   <= 1'b0;
            cur       <= 8'd0;
            left      <= 7'd0;
            ph        <= 26'd0;
            note_on_r <= 1'b0;
            s_on      <= 1'b0;
            s_off     <= 1'b0;
            s_note    <= 7'd60;
            s_vel     <= 8'd200;
            s_pos     <= 8'd0;
            start_now <= 1'b0;
            sw_st     <= SW_IDLE;
            rd_addr   <= 7'd0;
        end else begin
            play_d    <= play_btn;
            s_on      <= 1'b0;
            s_off     <= 1'b0;
            start_now <= 1'b0;

            // ---- 换音第三步: q_note/q_len 此刻已有效, 直接取用并发 s_on ----
            //    必须让 stop_now 优先: 若这一拍既发 s_on 又发 s_off,
            //     引擎 on 优先会把 off 丢掉, 那个音就永远挂着。
            //    时值也在这里装载: 换音那拍 left 被读成 0, 若不当场重装,
            //     下一拍走拍段又会判 left==0 再换一次音 (整曲变成 1.9us 一个音)。
            //    时序: T 拍给出 rd_addr, T+1 拍 q_note 才打出来 (非阻塞),
            //     所以必须等到 T+2 拍 (即本拍 SW_LATCH) 才读得到新值。
            //     早先在 SW_ADDR 那拍就锁存 q_note, 拿到的是上一个音的旧值。
            if (sw_st == SW_LATCH) begin
                sw_st <= SW_IDLE;
                left  <= ((q_len == 7'd0) ? 7'd1 : q_len) - 7'd1;
                if (!stop_now && q_note != 7'd0) begin
                    s_on      <= 1'b1;
                    s_note    <= q_note;
                    s_vel     <= 8'd200;
                    note_on_r <= 1'b1;
                end
            end

            // ---- 换音第二步: 同步读口这一拍正在把 mem[rd_addr] 打出来 ----
            if (sw_st == SW_ADDR) begin
                sw_st <= SW_LATCH;
            end

            // ---- 启停 ----
            if (stop_now) begin
                playing <= 1'b0;
                sw_st   <= SW_IDLE;      // 别让半个换音漏到停止之后
                if (note_on_r) begin
                    s_off     <= 1'b1;
                    note_on_r <= 1'b0;
                end
            end else if ((start_req || play_rise) && !playing && (ncount_r != 8'd0)) begin
                playing   <= 1'b1;
                cur       <= 8'd0;
                left      <= 7'd0;
                ph        <= 26'd0;
                sw_st     <= SW_IDLE;
                start_now <= 1'b1;          // 第一个音立即起振
            end

            // ---- 走拍 ----
            //    sw_busy 那两拍整段挂起: 只搬数据/发 s_on, 不动 left/ph。
            //     (早先写成 else 分支复位 left, 会把刚装好的时值清零,
            //      结果每个音都当成长度 0, 一进来就又换音。)
            //    相位只在 tick_en 那拍累加 (见上面 tick_div 的注释),
            //     start_now 例外 —— 第一个音要立刻起振, 不等满 16 拍。
            if (playing) begin
                if (!sw_busy && (tick_en || start_now)) begin
                    if (start_now || (ph_sum >= PH_1S)) begin
                        if (!start_now) ph <= ph_sum - PH_1S;

                        if (left == 7'd0) begin
                            // 换音: 这一拍只松开上一个, 并给出读地址
                            if (note_on_r) begin
                                s_off     <= 1'b1;
                                note_on_r <= 1'b0;
                            end
                            if (cur >= ncount_r) begin
                                playing <= 1'b0;            // 曲终
                            end else begin
                                s_pos   <= cur;
                                rd_addr <= cur[6:0];        // 同步读口取数
                                sw_st   <= SW_ADDR;
                                cur     <= cur + 8'd1;
                            end
                        end else begin
                            left <= left - 7'd1;
                        end
                    end else begin
                        ph <= ph_sum;
                    end
                end
            end else begin
                ph   <= 26'd0;
                left <= 7'd0;
            end
        end
    end

    // active 超时计时器 (idle_to 的声明见上面解析块前)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                     idle_cnt <= 16'd0;
        else if (byte_vld)              idle_cnt <= 16'd0;
        else if (idle_cnt != 16'hFFFF)  idle_cnt <= idle_cnt + 16'd1;
    end

endmodule

`default_nettype wire
