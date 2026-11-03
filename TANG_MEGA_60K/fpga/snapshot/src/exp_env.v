// Exponential ADSR. 2026-10-30: use Q16.12 by default.
// Q16.4 made ceil rounding comparable to the entire quiet-note amplitude:
// K=15 has a 2048-unit output bias at FRAC=4, versus 8 at FRAC=12.
// Rate-specific ceil rounding guarantees finite convergence. The shared
// datapath remains; the numerical contract is sim/tb_env_accuracy.v.
// Explicit FRAC overrides remain available for legacy/resource comparisons.
module exp_env #(
    parameter [4:0] K_A = 5'd10,      // attack  时间常数
    parameter [4:0] K_D = 5'd10,      // decay   时间常数 (默认/慢速音色)
    parameter [4:0] K_D2 = 5'd10,     //  decay 快速档 (拨弦这类短促音色)
    parameter [4:0] K_R = 5'd10,      // release 时间常数
    // Fractional precision: K=15 quiet-note curve error <= 6 output units.
    parameter integer FRAC = 12
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        tick,           // 采样节拍 (99.3kHz)
    input  wire        fast_dec,       // 1 = 用 K_D2, 0 = 用 K_D
    input  wire        gate,           // 按下=1
    input  wire        restart,        // 重触发: 立即回到 ATTACK 且 env 从 0 起
                                       //    同一音快速重弹时, 相位会被清零, 如果包络
                                       //     还停在半空中, 波形就是一次满幅跳变 -> 爆音。
                                       //     让包络一起从 0 起音, 跳变就被起音斜坡盖住。
    input  wire [15:0] att_lvl,        // 起音峰值电平(已含力度)
    input  wire [15:0] sus_lvl,        // sustain 电平 (0=衰减到底, 即成拨弦)
    output wire [15:0] env,            // 16bit 输出 (= envx[W-1:FRAC])
    output wire [2:0]  state           // 当前状态(供总线 AGC 判定起音窗口)
);

    localparam integer W = 16 + FRAC;  // 内部电平总位宽

    localparam [2:0] S_IDLE = 3'd0, S_ATT = 3'd1, S_DEC = 3'd2, S_SUS = 3'd3, S_REL = 3'd4,
                     S_RETRIG = 3'd5;   // 重触发: 先快速淡出再起音
    reg [2:0] st;
    assign state = st;

    //---- 定点内部电平 (高 16 位 = 输出, 低 FRAC 位 = 小数) ----
    reg  [W-1:0] envx;

    // 目标电平也要扩到同样宽度
    wire [W-1:0] att24 = {att_lvl, {FRAC{1'b0}}};
    wire [W-1:0] sus24 = {sus_lvl, {FRAC{1'b0}}};

    //-----------------------------------------------------------
    // 统一数据通路
    //   方向: 只有 ATTACK 是往上走, 其余(含 RETRIG)都往 0/目标收
    //   gap  : 到目标的距离 (无符号, 多 1 位防下溢)
    //   step : 本拍应该移动的量 = (gap + 舍入常数) >> K
    //   snap : gap <= step 表示已经进入"最后一个步长", 直接吸附到目标
    //-----------------------------------------------------------
    reg  [W:0] sub_a, sub_b;
    //  必须钳位: 重按一个更轻的力度时 att24 < envx, 相减会下溢成天文数字,
    //   一步就把包络冲飞。原版是 agap/dgap 各自钳 0 —— 钳 0 后 step 也是 0,
    //   于是 snap 成立、直接吸附到目标, 这正是"重按轻力度立刻降到新峰值"的行为。
    wire        gap_ge = (sub_a >= sub_b);
    wire [W:0]  gap    = gap_ge ? (sub_a - sub_b) : {(W+1){1'b0}};
    reg         up;

    always @* begin
        up = (st == S_ATT);
        if (up) begin                                  // ATT: gap = att - env
            sub_a = {1'b0, att24};
            sub_b = {1'b0, envx};
        end
        else if (st == S_DEC) begin                    // DEC: gap = env - sus
            sub_a = {1'b0, envx};
            sub_b = {1'b0, sus24};
        end
        else begin                                     // REL / RETRIG: gap = env - 0
            sub_a = {1'b0, envx};
            sub_b = {(W+1){1'b0}};
        end
    end

    // Ceil rounding must match the selected decay rate. Do not share the
    // largest constant across rates: that accelerates quiet fast decays.
    reg  [15:0] rconst;
    always @* begin
        case (st)
            S_ATT:    rconst = (16'd1 << K_A) - 16'd1;
            S_DEC:    rconst = fast_dec ? ((16'd1 << K_D2) - 16'd1)
                                        : ((16'd1 << K_D) - 16'd1);
            S_REL:    rconst = (16'd1 << K_R) - 16'd1;
            S_RETRIG: rconst = 16'd15;
            default:  rconst = 16'd0;
        endcase
    end

    // 无符号相加: 16bit 常数会被自动零扩展到 max(宽度) = W+1
    wire [W:0] gap_c = gap + rconst;

    reg  [W:0] step;
    always @* begin
        case (st)
            S_ATT:    step = gap_c >> K_A;
            S_DEC:    step = fast_dec ? (gap_c >> K_D2) : (gap_c >> K_D);
            S_REL:    step = gap_c >> K_R;
            S_RETRIG: step = gap_c >> 4;
            default:  step = {(W+1){1'b0}};
        endcase
    end

    wire        snap    = (gap <= step);
    wire [W:0]  env_up  = {1'b0, envx} + step;
    wire [W:0]  env_dn  = {1'b0, envx} - step;
    wire [W:0]  env_upd = up ? env_up : env_dn;

    // "输出电平已经不足 1" —— 原版是 env24 < 256, 等价于 env24[23:8]==0
    wire retrig_done = (envx[W-1:FRAC] == 16'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st    <= S_IDLE;
            envx  <= {W{1'b0}};
        end
        else if (restart) begin
            //  不能直接 env<=0: 那是一次满幅跳变 -> 爆音(实测跳变 3823->0)。
            //   先进 S_RETRIG 快速淡出, 淡到不足一个输出电平单位再重新起音。
            st <= S_RETRIG;
        end
        else if (tick) begin
            case (st)
            S_IDLE: if (gate) begin
                        st   <= S_ATT;
                        envx <= {W{1'b0}};
                    end
            S_ATT:  if (!gate) st <= S_REL;
                    else if (snap) begin
                        envx <= att24;
                        st   <= S_DEC;
                    end
                    else
                        envx <= env_upd[W-1:0];
            S_DEC:  if (!gate) st <= S_REL;
                    else if (snap) begin                  // 收敛到 sustain
                        envx <= sus24;
                        st   <= S_SUS;
                    end
                    else
                        envx <= env_upd[W-1:0];
            S_SUS:  if (!gate)
                        st <= S_REL;
            // 释放期间重新按下 → 立即转回 ATTACK(不复位 env, 从当前电平平滑续上)
            // Re-enter ATTACK from RELEASE when gate rises, preserving env.
            // Waiting for RELEASE to finish delays rapid retriggers.
            S_REL:  if (gate)
                        st <= S_ATT;
                    else if (snap) begin                  // rdec >= envx
                        envx <= {W{1'b0}};
                        st   <= S_IDLE;
                    end
                    else
                        envx <= env_upd[W-1:0];
            // ---- 每拍衰减 1/16, 满幅到不足 1 LSB 约 1.8ms ----
            S_RETRIG: begin
                        if (retrig_done) begin
                            envx <= {W{1'b0}};
                            st   <= S_ATT;
                        end
                        else
                            envx <= env_upd[W-1:0];
                      end
            default: begin
                        st   <= S_IDLE;
                        envx <= {W{1'b0}};
                    end
            endcase
        end
    end

    // 16bit 输出直接截高位 —— 组合输出, 与原来"打一拍"相比只早半个周期,
    // 对 99.3kHz 的包络毫无影响, 但省掉一级 16bit 寄存器。
    assign env = envx[W-1:FRAC];

endmodule
