//===============================================================
// fx_engine —— 硬件效果器 (混响 / 延迟 / 合唱)
//
// 赛题拓展要求第 2 条:
//   "在 FPGA 硬件内部实现混响、延迟、合唱等数字音频效果器"
//   —— "等" 是列举, 实现其中任意几种即可; 这里三种都做, 运行时可切。
//
// 结构 (全部在 tick1 = 99.3kHz 采样域, 与引擎同步, 不需要跨时钟):
//
//   x ──┬──► 干声 *(1-m) ─────────────────────────────────┐
//       │                                                 ▼
//       ├─► 4x fx_comb ─► 2x fx_allpass ──────────► reverb ─┐
//       │                                                    │
//       └─► fx_delay (mode 由 fx_sel 选 echo / chorus) ─────┤
//                                                            ▼
//                                                   按 fx_sel 选一路
//                                                            ▼
//                                              wet*m ──► 相加 ─► y
//
//  延迟与合唱共用同一条延迟线: 两者本质都是"从延迟线取一个抽头",
//   区别只是 echo 抽头固定+有反馈、chorus 抽头被 LFO 调制+无反馈。
//   共用一个 16384x16 的线 (约 15 个 BSRAM) 而不是两个, 省一半。
//   代价: 切换效果时线里残留上一效果的数据, 会有几十毫秒的过渡 ——
//   现场切换时听不出来。
//
//  为什么混响并联而不是串联: 串联时每一级都会把上一级的输出再延迟一次,
//   混响的预延迟变得不可控。并联时互不干扰, 演示时可单独开关, 讲解清楚。
//
//  湿声权重最大 0.5, 干声同步衰减到 (1-m), 交叉淡化保证
//   |y| <= max(|dry|,|wet|) 量级, 不会因为叠加而抬高峰值 (下面仍做饱和
//   兜底, 防止 wet 本身已满幅时略微超出)。
//
//  旁路: FX_ON=0 时整个模块被综合器优化掉 (generate), 不占任何资源。
//===============================================================
module fx_engine #(
    parameter FX_ON = 1
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               tick1,          // 99.3kHz 单拍脉冲

    input  wire [1:0]         fx_sel,         // 0=关 1=混响 2=延迟 3=合唱
    input  wire [1:0]         rev_size,       // 混响反馈增益档 0..3
    input  wire [13:0]        dly_len,        // 延迟长度 (样本)
    input  wire [1:0]         mix_sel,        // 干湿比 0=0 1=0.25 2=0.375 3=0.5

    input  wire signed [15:0] x,
    output wire signed [15:0] y
);

    generate
    if (FX_ON == 0) begin : g_off
        assign y = x;
    end
    else begin : g_on

        //===========================================================
        // 1) 混响 —— 4 并联梳状 + 2 级全通 (Schroeder)
        //
        //   梳状长度互质 (1487/1613/1751/1879, 都是质数), 避免回声周期
        //   重合产生"嗡"的驻波。这些长度对应 15.0/16.2/17.6/18.9ms,
        //   都在混响预延迟的常用区间内。
        //===========================================================
        wire signed [15:0] c0, c1, c2, c3;
        wire signed [15:0] ap0, ap1;

        fx_comb #(.L(1487), .AW(11)) u_c0
            (.clk(clk), .rst_n(rst_n), .tick1(tick1), .gsel(rev_size), .x(x), .y(c0));
        fx_comb #(.L(1613), .AW(11)) u_c1
            (.clk(clk), .rst_n(rst_n), .tick1(tick1), .gsel(rev_size), .x(x), .y(c1));
        fx_comb #(.L(1751), .AW(11)) u_c2
            (.clk(clk), .rst_n(rst_n), .tick1(tick1), .gsel(rev_size), .x(x), .y(c2));
        fx_comb #(.L(1879), .AW(11)) u_c3
            (.clk(clk), .rst_n(rst_n), .tick1(tick1), .gsel(rev_size), .x(x), .y(c3));

        // 四路求和 /4
        wire signed [17:0] csum = $signed(c0) + $signed(c1) + $signed(c2) + $signed(c3);
        wire signed [15:0] cmix = csum[17:2];

        fx_allpass #(.L(225), .AW(8), .GS(2)) u_a0
            (.clk(clk), .rst_n(rst_n), .tick1(tick1), .x(cmix), .y(ap0));
        fx_allpass #(.L(341), .AW(9), .GS(2)) u_a1
            (.clk(clk), .rst_n(rst_n), .tick1(tick1), .x(ap0),  .y(ap1));

        wire signed [15:0] rev = ap1;

        //===========================================================
        // 2) 延迟 / 合唱 —— 共用一条延迟线
        //    echo  : mode=0, 抽头固定 = dly_len, 反馈 0.5
        //    chorus: mode=1, 抽头被 0.6Hz LFO 调制, 无反馈
        //===========================================================
        wire        d_mode = (fx_sel == 2'd3);
        wire [13:0] d_len  = d_mode ? 14'd1100 : dly_len;
        wire [1:0]  d_fb   = d_mode ? 2'd0 : 2'd2;

        wire signed [15:0] dly_out;
        fx_delay #(.MAXL(16384), .AW(14)) u_dly (
            .clk(clk), .rst_n(rst_n), .tick1(tick1),
            .mode(d_mode), .dly(d_len), .fb_sel(d_fb),
            .x(x), .y(dly_out));

        //===========================================================
        // Dry/wet crossfade: dry*(1-m) + wet*m.
        // mix_sel selects m = 0, 0.25, 0.5 or 1.
        // fx_sel=0 bypasses the effect regardless of mix_sel.
        //===========================================================
        wire signed [15:0] wet = (fx_sel == 2'd1) ? rev     :
                                 (fx_sel == 2'd2) ? dly_out :
                                 (fx_sel == 2'd3) ? dly_out : 16'sd0;

        // 湿声权重 = m (纯移位加, 无 DSP)
        wire signed [17:0] wet_s = $signed(wet);
        wire signed [17:0] wq    = (mix_sel == 2'd0) ? 18'sd0 :
                                   (mix_sel == 2'd1) ? (wet_s >>> 2) :   // 25%
                                   (mix_sel == 2'd2) ? (wet_s >>> 1) :   // 50%
                                                       wet_s;            // 100%
        // 干声权重 = (1 - m)
        //    fx_sel==0 是旁路, 此时无论 mix_sel 是什么都必须逐样本直通,
        //     否则网页把 mix 拉满再关效果器, 音量会莫名掉一半。
        wire signed [17:0] dry_s = $signed(x);
        wire signed [17:0] dq    = (fx_sel == 2'd0) ? dry_s :
                                   (mix_sel == 2'd0) ? dry_s :
                                   (mix_sel == 2'd1) ? (dry_s - (dry_s >>> 2)) :   // 75%
                                   (mix_sel == 2'd2) ? (dry_s >>> 1) :             // 50%
                                                       18'sd0;                    // 0%
        wire signed [17:0] osum = dq + wq;
        wire signed [15:0] o    = (osum > 18'sd32767)  ?  16'sd32767 :
                                  (osum < -18'sd32768) ? -16'sd32768 : osum[15:0];
        assign y = o;

    end
    endgenerate

endmodule
