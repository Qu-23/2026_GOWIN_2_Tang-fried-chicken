//===============================================================
// timbre_morph - 在 4 种波形之间插值 (音色变形)
//
//   morph = 0    -> sine
//   morph = 341  -> square
//   morph = 682  -> softsaw
//   morph = 1023 -> triangle
//   中间值 = 相邻两种波形按比例线性混合
//
//  2026-10-23 (为 32 声部省逻辑): 段号 seg 与插值系数 frac 改为输入,
//   由 synth_engine 用全局的 p_morph 算一次。理由: morph 是引擎级的单个
//   寄存器, 32 个声部看到的 seg/frac 完全相同, 却在每个声部里各算一遍
//   (每个声部一个 12bit x 3 的 MULT12X12 + 一套 10bit 比较/减法)。
//   提到引擎后 32 个乘法器变成 1 个, 每声部还省约 30 LUT。
//   音质零影响 —— 算式完全没变, 只是搬到外面算。
//
//  2026-10-23: 试过把这里的乘法器改成移位加 (5 项, 窄位宽),
//   结果 逻辑反而涨了 5458 (probe: 51385 -> 56843), 只省下 65 DSP。
//   32 声部卡的是逻辑 (62599 > 59904) 而不是 DSP, 所以这个方向是错的, 已回退。
//   结论: 17x12 的乘法在 Gowin 上由 MULTALU27X18 硬核实现, 比 5 个 22bit
//   加法器便宜得多。省 DSP 要从「复用乘法器」下手, 不要从「换掉乘法器」下手。
//
//  踩过的坑: `{{8{a[15]}}, a} + (prod >>> 10)` 里, 拼接 `{}` 的结果是
//   无符号, 整个表达式就被当成无符号, `>>>` 退化成逻辑右移,
//   负的 delta 立刻变成天文数字 (实测 interp=33523711)。必须把拼接结果
//   单独赋给一个 signed 变量, 再相加。
//
//  另一个坑: interp 一定落在 a 与 b 之间 (frac/1024 在 [0,1)), 所以它
//   天然在 16bit 范围内 —— 不需要饱和逻辑。原来那对 24bit 比较器
//   纯属多余, 32 声部时白花约 50 LUT/声部。
//===============================================================
module timbre_morph (
    input  wire signed [15:0] sine,
    input  wire signed [15:0] square,
    input  wire signed [15:0] saw,
    input  wire signed [15:0] triangle,
    input  wire signed [15:0] softsaw,    //  柔化锯齿 (1/k^1.2, 偶次完整)
    input  wire [1:0]         seg,         // 0=sin->sqr 1=sqr->ssaw 2=ssaw->tri 3=tri
    input  wire [10:0]        frac,        // 0..1024, 段内比例 (1024 = 100%)
    output reg  signed [15:0] sample
);

    //---- 相邻两种波形 ----
    reg signed [16:0] a, b;
    always @* begin
        case (seg)
            2'd0:    begin a = {sine[15],    sine};     b = {square[15],  square};   end
            2'd1:    begin a = {square[15],  square};   b = {softsaw[15], softsaw};  end
            default: begin a = {softsaw[15], softsaw};  b = {triangle[15],triangle}; end
        endcase
    end

    wire signed [16:0] delta = b - a;                          // 17bit
    wire signed [29:0] prod  = delta * $signed({2'b00, frac}); // 17 x 13, MULTALU27X18
    wire signed [19:0] p10   = prod >>> 10;                    // |p10| <= |delta|
    wire signed [16:0] mix   = a + p10;

    always @* sample = mix[15:0];

endmodule
