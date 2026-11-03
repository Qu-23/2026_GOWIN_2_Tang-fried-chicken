//////////////////////////////////////////////////////////////////////////////////
// Module Name : ui_render
// Description : 触屏控制面板渲染 v2 (2026-11-01) —— 8 列网格, 无帧缓存, 纯组合逻辑
//
//   480x272 (RGB565, 亮色主题):
//     y  0.. 23  顶栏: TONE-var | TX 灯 | PLAY/TEST
//     y 24..111  音色 4 大格 ×120 (EP/PL/BA/CE, 2x 字形)
//     y112..167  颤音 V0..V3 | 滑音 G0..G3      (8 格 ×60)
//     y168..223  变体 A/B/C | FX | R | M | O- | O+ (8 格 ×60)
//     y224..271  TS | 和弦 CM/GM/FM | LAMP | CL 全停 (8 格 ×60)
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps

module ui_render (
    input  wire [11:0] hcount,
    input  wire [11:0] vcount,
    input  wire [9:0]  tx,
    input  wire [9:0]  ty,
    input  wire        pressed,
    input  wire [1:0]  cfg_wave,
    input  wire [1:0]  cfg_ep,
    input  wire [1:0]  cfg_vib,
    input  wire [1:0]  cfg_gli,
    input  wire [1:0]  cfg_fx,
    input  wire [1:0]  cfg_rev,
    input  wire [1:0]  cfg_mix,
    input  wire [1:0]  oct_mode,
    input  wire        tst_mode,
    input  wire        lamp,
    input  wire        chord_hold,
    input  wire [1:0]  chord_idx,
    input  wire        uart_busy,
    output reg  [15:0] rgb
);

    //---------------- 调色板 (RGB565) ----------------
    localparam [15:0] BG      = 16'hF7BF;  // #F4F6FA 页面底
    localparam [15:0] WHITE   = 16'hFFFF;
    localparam [15:0] BORD    = 16'hCE9B;  // #C9D0DC 边框
    localparam [15:0] TXT     = 16'h1906;  // #1A2332 深字
    localparam [15:0] BAR     = 16'h2188;  // #223047 顶栏
    localparam [15:0] BLUE    = 16'h2BFA;  // #2F7FD1
    localparam [15:0] BLUEL   = 16'hDF5F;  // #DCEAFB
    localparam [15:0] TEAL    = 16'h1CD2;  // #199A94
    localparam [15:0] TEALL   = 16'hDF9D;  // #D9F1EF
    localparam [15:0] ORG     = 16'hE445;  // #E08A2E
    localparam [15:0] ORGL    = 16'hFF7B;  // #FDEED8
    localparam [15:0] PUR     = 16'h7AE4;  // #7A5CC6
    localparam [15:0] PURL    = 16'hEF3F;  // #ECE5FA
    localparam [15:0] GRN     = 16'h2CEB;  // #2E9E5B
    localparam [15:0] GRNL    = 16'hDF9C;  // #DEF0E4
    localparam [15:0] GRYL    = 16'hE73D;  // #E2E6EE
    localparam [15:0] RED     = 16'hD228;  // #D64545
    localparam [15:0] REDL    = 16'hFF1C;  // #FBE3E3
    localparam [15:0] OCTON   = 16'hADD9;  // #AEB9CE 八度激活
    localparam [15:0] CROSS   = 16'hD228;

    //---------------- 行带与列 ----------------
    wire in_r0 = (vcount >= 12'd24)  && (vcount < 12'd112);
    wire in_r1 = (vcount >= 12'd112) && (vcount < 12'd168);
    wire in_r2 = (vcount >= 12'd168) && (vcount < 12'd224);
    wire in_r3 = (vcount >= 12'd224) && (vcount < 12'd272);

    wire [1:0] c2t = (hcount >= 12'd360) ? 2'd3 :
                     (hcount >= 12'd240) ? 2'd2 :
                     (hcount >= 12'd120) ? 2'd1 : 2'd0;
    wire [2:0] col6 = (hcount >= 12'd420) ? 3'd7 :
                      (hcount >= 12'd360) ? 3'd6 :
                      (hcount >= 12'd300) ? 3'd5 :
                      (hcount >= 12'd240) ? 3'd4 :
                      (hcount >= 12'd180) ? 3'd3 :
                      (hcount >= 12'd120) ? 3'd2 :
                      (hcount >= 12'd60)  ? 3'd1 : 3'd0;

    //---------------- 单元底色 + 选中标志 ----------------
    reg [15:0] fill;
    reg        sel;

    always @(*) begin
        fill = BG;
        sel  = 1'b0;
        if (in_r0) begin
            case (c2t)
                2'd0: begin fill = (cfg_wave == 2'd0) ? BLUE : BLUEL; sel = (cfg_wave == 2'd0); end
                2'd1: begin fill = (cfg_wave == 2'd1) ? TEAL : TEALL; sel = (cfg_wave == 2'd1); end
                2'd2: begin fill = (cfg_wave == 2'd2) ? ORG  : ORGL;  sel = (cfg_wave == 2'd2); end
                2'd3: begin fill = (cfg_wave == 2'd3) ? PUR  : PURL;  sel = (cfg_wave == 2'd3); end
            endcase
        end else if (in_r1) begin
            if (col6 < 3'd4) begin
                fill = (cfg_vib == col6[1:0]) ? GRN : GRNL;
                sel  = (cfg_vib == col6[1:0]);
            end else begin
                fill = (cfg_gli == col6[1:0]) ? PUR : PURL;
                sel  = (cfg_gli == col6[1:0]);
            end
        end else if (in_r2) begin
            case (col6)
                3'd0, 3'd1, 3'd2: begin
                    fill = (cfg_ep == col6[1:0]) ? ORG : ORGL;
                    sel  = (cfg_ep == col6[1:0]);
                end
                3'd3: begin fill = (cfg_fx  != 2'd0) ? TEAL : TEALL; sel = (cfg_fx  != 2'd0); end
                3'd4: begin fill = (cfg_rev != 2'd0) ? TEAL : TEALL; sel = (cfg_rev != 2'd0); end
                3'd5: begin fill = (cfg_mix != 2'd0) ? TEAL : TEALL; sel = (cfg_mix != 2'd0); end
                3'd6: begin fill = (oct_mode == 2'd2) ? OCTON : GRYL; sel = (oct_mode == 2'd2); end
                3'd7: begin fill = (oct_mode == 2'd1) ? OCTON : GRYL; sel = (oct_mode == 2'd1); end
            endcase
        end else if (in_r3) begin
            case (col6)
                3'd0: begin fill = tst_mode ? ORG : GRYL; sel = tst_mode; end
                3'd1: begin fill = (chord_hold && chord_idx == 2'd0) ? BLUE : BLUEL;
                            sel  = (chord_hold && chord_idx == 2'd0); end
                3'd2: begin fill = (chord_hold && chord_idx == 2'd1) ? BLUE : BLUEL;
                            sel  = (chord_hold && chord_idx == 2'd1); end
                3'd3: begin fill = (chord_hold && chord_idx == 2'd2) ? BLUE : BLUEL;
                            sel  = (chord_hold && chord_idx == 2'd2); end
                3'd4, 3'd5: begin fill = lamp ? GRN : GRYL; sel = lamp; end
                default: fill = REDL;
            endcase
        end
    end

    //---------------- 字符编码查表 (编码表见 font8x8.v 文件头) ----------------
    function [5:0] tone_ch;     // 音色名两字符
        input [1:0] t;
        input       k;           // 0=首字符
        begin
            case (t)
                2'd0: tone_ch = k ? 6'h1C : 6'h12;    // E P
                2'd1: tone_ch = k ? 6'h15 : 6'h1C;    // P L
                2'd2: tone_ch = k ? 6'h0A : 6'h0B;    // B A
                default: tone_ch = k ? 6'h12 : 6'h0C; // C E
            endcase
        end
    endfunction

    function [5:0] var_ch;      // 变体 A/B/C
        input [1:0] v;
        begin
            case (v)
                2'd0: var_ch = 6'h0A;    // A
                2'd1: var_ch = 6'h0B;    // B
                default: var_ch = 6'h0C; // C
            endcase
        end
    endfunction

    function [5:0] fx_ch;       // 效果名三字符 OFF/REV/DLY/CHO
        input [1:0] f;
        input [1:0] k;
        begin
            case (f)
                2'd0: fx_ch = (k == 2'd0) ? 6'h1B : 6'h0F;                          // O/F/F
                2'd1: fx_ch = (k == 2'd0) ? 6'h1D : (k == 2'd1) ? 6'h12 : 6'h11;    // R/E/V
                2'd2: fx_ch = (k == 2'd0) ? 6'h0D : (k == 2'd1) ? 6'h15 : 6'h1F;    // D/L/Y
                default: fx_ch = (k == 2'd0) ? 6'h0C : (k == 2'd1) ? 6'h19 : 6'h1B; // C/H/O
            endcase
        end
    endfunction

    //---------------- 文本窗 (显式减法索引, 无位技巧) ----------------
    wire [11:0] r1x0 = col6 * 12'd60 + 12'd22;   // R1 两字符
    wire [11:0] r2a0 = col6 * 12'd60 + 12'd26;   // R2 变体单字符
    wire [11:0] r2x0 = col6 * 12'd60 + 12'd22;   // R2 两字符 (R/M/O)
    wire [11:0] r3x0 = col6 * 12'd60 + 12'd22;   // R3 两字符
    wire [11:0] r3l0 = col6 * 12'd60 + 12'd14;   // R3 LAMP 四字符
    wire [11:0] r0x0 = c2t  * 12'd120 + 12'd52;  // R0 音色 2x

    reg        in_txt;
    reg        zoom;
    reg [2:0]  gfrow, gfcol;
    reg [5:0]  lch;

    // 窗内相对坐标
    wire [11:0] dyb = vcount - 12'd8;            // 顶栏
    wire [11:0] dxa = hcount - 12'd8;            // 顶栏 音色-变体 (w32)
    wire [11:0] dxd = hcount - 12'd436;          // 顶栏 PLAY/TEST (w32)
    wire [11:0] dy0 = vcount - 12'd60;           // R0
    wire [11:0] dx0 = hcount - r0x0;
    wire [11:0] dy1 = vcount - 12'd136;          // R1
    wire [11:0] dx1 = hcount - r1x0;
    wire [11:0] dy2 = vcount - 12'd192;          // R2
    wire [11:0] dx2a = hcount - r2a0;
    wire [11:0] dx2  = hcount - r2x0;
    wire [11:0] dxf  = hcount - 12'd198;         // FX 三字符 (w24)
    wire [11:0] dy3 = vcount - 12'd244;          // R3
    wire [11:0] dx3 = hcount - r3x0;
    wire [11:0] dxl = hcount - r3l0;             // LAMP (w32)
    wire [11:0] dxc3 = hcount - 12'd382;         // CL (w16)

    always @(*) begin
        in_txt = 1'b0; zoom = 1'b0; lch = 6'h16;
        gfrow = 3'd0; gfcol = 3'd0;

        //---------------- 顶栏 (y 8..15) ----------------
        if (dyb < 12'd8) begin
            gfrow = dyb[2:0];
            if (dxa < 12'd32) begin
                in_txt = 1'b1; zoom = 1'b0;
                gfcol = dxa[2:0];
                case (dxa[4:3])
                    2'd0: lch = tone_ch(cfg_wave, 1'b0);
                    2'd1: lch = tone_ch(cfg_wave, 1'b1);
                    2'd2: lch = 6'h20;                   // '-'
                    default: lch = var_ch(cfg_ep);
                endcase
            end else if (dxd < 12'd32) begin
                in_txt = 1'b1;
                gfcol = dxd[2:0];
                case (dxd[4:3])
                    2'd0: lch = tst_mode ? 6'h10 : 6'h1C; // T / P
                    2'd1: lch = tst_mode ? 6'h12 : 6'h15; // E / L
                    2'd2: lch = tst_mode ? 6'h13 : 6'h0A; // S / A
                    default: lch = tst_mode ? 6'h10 : 6'h1F; // T / Y
                endcase
            end
        end
        //---------------- R0 音色 (2x 字形, y 60..75, w16) ----------------
        else if (in_r0 && dy0 < 12'd16 && dx0 < 12'd16) begin
            in_txt = 1'b1; zoom = 1'b1;
            gfrow = dy0[3:1];
            gfcol = dx0[2:0];
            lch   = tone_ch(c2t, dx0[3]);
        end
        //---------------- R1 (y 136..143, 每列 w16) ----------------
        else if (in_r1 && dy1 < 12'd8 && dx1 < 12'd16) begin
            in_txt = 1'b1;
            gfrow = dy1[2:0];
            gfcol = dx1[2:0];
            if (col6 < 3'd4) lch = dx1[3] ? {2'h0, col6[1:0]} : 6'h11;   // V + 数字
            else             lch = dx1[3] ? {2'h0, col6[1:0]} : 6'h18;   // G + 数字
        end
        //---------------- R2 (y 192..199) ----------------
        else if (in_r2 && dy2 < 12'd8) begin
            gfrow = dy2[2:0];
            if (col6 < 3'd3) begin
                if (dx2a < 12'd8) begin
                    in_txt = 1'b1; gfcol = dx2a[2:0];
                    lch = var_ch(col6[1:0]);
                end
            end else if (col6 == 3'd3) begin
                if (dxf < 12'd24) begin
                    in_txt = 1'b1; gfcol = dxf[2:0];
                    lch = fx_ch(cfg_fx, dxf[4:3]);
                end
            end else if (col6 == 3'd4) begin
                if (dx2 < 12'd16) begin
                    in_txt = 1'b1; gfcol = dx2[2:0];
                    lch = dx2[3] ? {2'h0, cfg_rev} : 6'h1D;  // R + 数字
                end
            end else if (col6 == 3'd5) begin
                if (dx2 < 12'd16) begin
                    in_txt = 1'b1; gfcol = dx2[2:0];
                    lch = dx2[3] ? {2'h0, cfg_mix} : 6'h1A;  // M + 数字
                end
            end else begin                           // O- / O+
                if (dx2 < 12'd16) begin
                    in_txt = 1'b1; gfcol = dx2[2:0];
                    lch = dx2[3] ? ((col6 == 3'd7) ? 6'h21 : 6'h20) : 6'h1B;  // O+ / O-
                end
            end
        end
        //---------------- R3 (y 244..251) ----------------
        else if (in_r3 && dy3 < 12'd8) begin
            gfrow = dy3[2:0];
            if (col6 == 3'd0) begin
                if (dx3 < 12'd16) begin
                    in_txt = 1'b1; gfcol = dx3[2:0];
                    lch = dx3[3] ? 6'h13 : 6'h10;            // T S
                end
            end else if (col6 >= 3'd1 && col6 <= 3'd3) begin
                if (dx3 < 12'd16) begin
                    in_txt = 1'b1; gfcol = dx3[2:0];
                    case (col6)
                        3'd1: lch = dx3[3] ? 6'h1A : 6'h0C;    // C M
                        3'd2: lch = dx3[3] ? 6'h1A : 6'h18;    // G M
                        default: lch = dx3[3] ? 6'h1A : 6'h0F; // F M
                    endcase
                end
            end else if (col6 == 3'd4 || col6 == 3'd5) begin
                if (dxl < 12'd32) begin
                    in_txt = 1'b1; gfcol = dxl[2:0];
                    case (dxl[4:3])
                        2'd0: lch = 6'h15;                   // L
                        2'd1: lch = 6'h0A;                   // A
                        2'd2: lch = 6'h1A;                   // M
                        default: lch = 6'h1C;                // P
                    endcase
                end
            end else begin                           // CL (x 382..397)
                if (dxc3 < 12'd16) begin
                    in_txt = 1'b1; gfcol = dxc3[2:0];
                    lch = dxc3[3] ? 6'h15 : 6'h0C;           // C L
                end
            end
        end
    end

    //---------------- 字库 ----------------
    wire [7:0] glyph;
    font8x8 u_font (
        .ch   (lch),
        .row  (gfrow),
        .bits (glyph)
    );

    wire gpix = in_txt && glyph[3'd7 - gfcol];

    //---------------- 边框 ----------------
    wire v60  = (hcount == 12'd60)  || (hcount == 12'd120)  || (hcount == 12'd180) ||
                (hcount == 12'd240) || (hcount == 12'd300) || (hcount == 12'd360) ||
                (hcount == 12'd420);
    wire v120 = (hcount == 12'd120) || (hcount == 12'd240) || (hcount == 12'd360);
    wire hsep = (vcount == 12'd111) || (vcount == 12'd112) ||
                (vcount == 12'd167) || (vcount == 12'd168) ||
                (vcount == 12'd223) || (vcount == 12'd224);

    //---------------- 输出合成 ----------------
    always @(*) begin
        rgb = fill;
        if (vcount < 12'd24) begin
            rgb = BAR;
            if (vcount == 12'd23) rgb = BORD;
            if (gpix) rgb = WHITE;
            if (hcount >= 12'd404 && hcount < 12'd412 && dyb < 12'd8)
                rgb = uart_busy ? 16'hFFE0 : 16'h3B6A;         // TX 指示灯
        end else begin
            if ((in_r0 && v120) || ((in_r1 || in_r2 || in_r3) && v60) ||
                hsep || vcount == 12'd24 || vcount == 12'd271)
                rgb = BORD;
            else if (gpix)
                rgb = sel ? WHITE : TXT;
            if (pressed && (hcount == {2'b00, tx} || vcount == {2'b00, ty}))
                rgb = CROSS;                                    // 触摸准星
        end
    end

endmodule
