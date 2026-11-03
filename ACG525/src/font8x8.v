//////////////////////////////////////////////////////////////////////////////////
// Module Name : font8x8
// Description : 8x8 点阵字库（原由 doc/gen_font.py 生成）
//               编码表 (6bit) —— ui_render 引用编码必须以此为准:
//                 0x00..0x09 : '0'..'9'
//                 0x0A..0x0F : 'A'..'F'   (十六进制段, lux 显示用)
//                 0x10 T  0x11 V  0x12 E  0x13 S  0x14 C2 0x15 L
//                 0x16 空格   0x17 '='
//                 0x18 G  0x19 H  0x1A M  0x1B O  0x1C P  0x1D R
//                 0x1E X  0x1F Y
//                 0x20 '-'    0x21 '+'    0x22 'Z'
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps

module font8x8 (
    input  wire [5:0] ch,      // 字符编码 0x00..0x17
    input  wire [2:0] row,     // 行 0..7
    output reg  [7:0] bits     // 该行 8 个像素, bit7 最左
);
    always @(*) begin
        case (ch)
            //---------- 十六进制 '0'..'F' ----------
            6'h00: begin // '0'
                case (row)
                    3'd0: bits = 8'h38; 3'd1: bits = 8'h44; 3'd2: bits = 8'h44; 3'd3: bits = 8'h44;
                    3'd4: bits = 8'h44; 3'd5: bits = 8'h44; 3'd6: bits = 8'h44; 3'd7: bits = 8'h38;
                    default: bits = 8'h00;
                endcase
            end
            6'h01: begin // '1'
                case (row)
                    3'd0: bits = 8'h18; 3'd1: bits = 8'h28; 3'd2: bits = 8'h08; 3'd3: bits = 8'h08;
                    3'd4: bits = 8'h08; 3'd5: bits = 8'h08; 3'd6: bits = 8'h08; 3'd7: bits = 8'h08;
                    default: bits = 8'h00;
                endcase
            end
            6'h02: begin // '2'
                case (row)
                    3'd0: bits = 8'h18; 3'd1: bits = 8'h24; 3'd2: bits = 8'h04; 3'd3: bits = 8'h04;
                    3'd4: bits = 8'h08; 3'd5: bits = 8'h10; 3'd6: bits = 8'h20; 3'd7: bits = 8'h3C;
                    default: bits = 8'h00;
                endcase
            end
            6'h03: begin // '3'
                case (row)
                    3'd0: bits = 8'h38; 3'd1: bits = 8'h04; 3'd2: bits = 8'h04; 3'd3: bits = 8'h18;
                    3'd4: bits = 8'h04; 3'd5: bits = 8'h44; 3'd6: bits = 8'h44; 3'd7: bits = 8'h38;
                    default: bits = 8'h00;
                endcase
            end
            6'h04: begin // '4'
                case (row)
                    3'd0: bits = 8'h08; 3'd1: bits = 8'h18; 3'd2: bits = 8'h28; 3'd3: bits = 8'h48;
                    3'd4: bits = 8'h7C; 3'd5: bits = 8'h08; 3'd6: bits = 8'h08; 3'd7: bits = 8'h00;
                    default: bits = 8'h00;
                endcase
            end
            6'h05: begin // '5'
                case (row)
                    3'd0: bits = 8'h7C; 3'd1: bits = 8'h40; 3'd2: bits = 8'h78; 3'd3: bits = 8'h04;
                    3'd4: bits = 8'h04; 3'd5: bits = 8'h44; 3'd6: bits = 8'h38; 3'd7: bits = 8'h00;
                    default: bits = 8'h00;
                endcase
            end
            6'h06: begin // '6'
                case (row)
                    3'd0: bits = 8'h38; 3'd1: bits = 8'h44; 3'd2: bits = 8'h40; 3'd3: bits = 8'h78;
                    3'd4: bits = 8'h44; 3'd5: bits = 8'h44; 3'd6: bits = 8'h38; 3'd7: bits = 8'h00;
                    default: bits = 8'h00;
                endcase
            end
            6'h07: begin // '7'
                case (row)
                    3'd0: bits = 8'h7C; 3'd1: bits = 8'h04; 3'd2: bits = 8'h08; 3'd3: bits = 8'h10;
                    3'd4: bits = 8'h10; 3'd5: bits = 8'h10; 3'd6: bits = 8'h10; 3'd7: bits = 8'h00;
                    default: bits = 8'h00;
                endcase
            end
            6'h08: begin // '8'
                case (row)
                    3'd0: bits = 8'h38; 3'd1: bits = 8'h44; 3'd2: bits = 8'h44; 3'd3: bits = 8'h38;
                    3'd4: bits = 8'h44; 3'd5: bits = 8'h44; 3'd6: bits = 8'h44; 3'd7: bits = 8'h38;
                    default: bits = 8'h00;
                endcase
            end
            6'h09: begin // '9'
                case (row)
                    3'd0: bits = 8'h38; 3'd1: bits = 8'h44; 3'd2: bits = 8'h44; 3'd3: bits = 8'h3C;
                    3'd4: bits = 8'h04; 3'd5: bits = 8'h44; 3'd6: bits = 8'h38; 3'd7: bits = 8'h00;
                    default: bits = 8'h00;
                endcase
            end
            6'h0A: begin // 'A'
                case (row)
                    3'd0: bits = 8'h38; 3'd1: bits = 8'h44; 3'd2: bits = 8'h44; 3'd3: bits = 8'h7C;
                    3'd4: bits = 8'h44; 3'd5: bits = 8'h44; 3'd6: bits = 8'h44; 3'd7: bits = 8'h00;
                    default: bits = 8'h00;
                endcase
            end
            6'h0B: begin // 'B'
                case (row)
                    3'd0: bits = 8'h78; 3'd1: bits = 8'h44; 3'd2: bits = 8'h44; 3'd3: bits = 8'h78;
                    3'd4: bits = 8'h44; 3'd5: bits = 8'h44; 3'd6: bits = 8'h44; 3'd7: bits = 8'h78;
                    default: bits = 8'h00;
                endcase
            end
            6'h0C: begin // 'C'
                case (row)
                    3'd0: bits = 8'h38; 3'd1: bits = 8'h44; 3'd2: bits = 8'h40; 3'd3: bits = 8'h40;
                    3'd4: bits = 8'h40; 3'd5: bits = 8'h44; 3'd6: bits = 8'h38; 3'd7: bits = 8'h00;
                    default: bits = 8'h00;
                endcase
            end
            6'h0D: begin // 'D'
                case (row)
                    3'd0: bits = 8'h78; 3'd1: bits = 8'h44; 3'd2: bits = 8'h44; 3'd3: bits = 8'h44;
                    3'd4: bits = 8'h44; 3'd5: bits = 8'h44; 3'd6: bits = 8'h44; 3'd7: bits = 8'h78;
                    default: bits = 8'h00;
                endcase
            end
            6'h0E: begin // 'E'
                case (row)
                    3'd0: bits = 8'h78; 3'd1: bits = 8'h40; 3'd2: bits = 8'h40; 3'd3: bits = 8'h78;
                    3'd4: bits = 8'h40; 3'd5: bits = 8'h40; 3'd6: bits = 8'h40; 3'd7: bits = 8'h7C;
                    default: bits = 8'h00;
                endcase
            end
            6'h0F: begin // 'F'
                case (row)
                    3'd0: bits = 8'h78; 3'd1: bits = 8'h40; 3'd2: bits = 8'h40; 3'd3: bits = 8'h78;
                    3'd4: bits = 8'h40; 3'd5: bits = 8'h40; 3'd6: bits = 8'h40; 3'd7: bits = 8'h00;
                    default: bits = 8'h00;
                endcase
            end
            //---------- 按钮标签字母 ----------
            6'h10: begin // 'T'
                case (row)
                    3'd0: bits = 8'h7C; 3'd1: bits = 8'h10; 3'd2: bits = 8'h10; 3'd3: bits = 8'h10;
                    3'd4: bits = 8'h10; 3'd5: bits = 8'h10; 3'd6: bits = 8'h10; 3'd7: bits = 8'h10;
                    default: bits = 8'h00;
                endcase
            end
            6'h11: begin // 'V'
                case (row)
                    3'd0: bits = 8'h84; 3'd1: bits = 8'h44; 3'd2: bits = 8'h44; 3'd3: bits = 8'h48;
                    3'd4: bits = 8'h28; 3'd5: bits = 8'h28; 3'd6: bits = 8'h30; 3'd7: bits = 8'h10;
                    default: bits = 8'h00;
                endcase
            end
            6'h12: begin // 'E' (备用, 与 0x0E 同形)
                case (row)
                    3'd0: bits = 8'h78; 3'd1: bits = 8'h40; 3'd2: bits = 8'h40; 3'd3: bits = 8'h40;
                    3'd4: bits = 8'h78; 3'd5: bits = 8'h40; 3'd6: bits = 8'h40; 3'd7: bits = 8'h7C;
                    default: bits = 8'h00;
                endcase
            end
            6'h13: begin // 'S'
                case (row)
                    3'd0: bits = 8'h1C; 3'd1: bits = 8'h22; 3'd2: bits = 8'h20; 3'd3: bits = 8'h18;
                    3'd4: bits = 8'h04; 3'd5: bits = 8'h02; 3'd6: bits = 8'h22; 3'd7: bits = 8'h1C;
                    default: bits = 8'h00;
                endcase
            end
            6'h14: begin // 'C'
                case (row)
                    3'd0: bits = 8'h38; 3'd1: bits = 8'h44; 3'd2: bits = 8'h84; 3'd3: bits = 8'h80;
                    3'd4: bits = 8'h80; 3'd5: bits = 8'h84; 3'd6: bits = 8'h44; 3'd7: bits = 8'h38;
                    default: bits = 8'h00;
                endcase
            end
            6'h15: begin // 'L'
                case (row)
                    3'd0: bits = 8'h40; 3'd1: bits = 8'h40; 3'd2: bits = 8'h40; 3'd3: bits = 8'h40;
                    3'd4: bits = 8'h40; 3'd5: bits = 8'h40; 3'd6: bits = 8'h40; 3'd7: bits = 8'h7C;
                    default: bits = 8'h00;
                endcase
            end
            6'h16: bits = 8'h00;                        // 空格
            6'h17: begin // '='
                case (row)
                    3'd0: bits = 8'h00; 3'd1: bits = 8'h00; 3'd2: bits = 8'h7C; 3'd3: bits = 8'h00;
                    3'd4: bits = 8'h7C; 3'd5: bits = 8'h00; 3'd6: bits = 8'h00; 3'd7: bits = 8'h00;
                    default: bits = 8'h00;
                endcase
            end
            //---------- 网格 GUI 扩充字母 ----------
            6'h18: begin // 'G'
                case (row)
                    3'd0: bits = 8'h38; 3'd1: bits = 8'h44; 3'd2: bits = 8'h40; 3'd3: bits = 8'h5C;
                    3'd4: bits = 8'h44; 3'd5: bits = 8'h44; 3'd6: bits = 8'h38; 3'd7: bits = 8'h00;
                    default: bits = 8'h00;
                endcase
            end
            6'h19: begin // 'H'
                case (row)
                    3'd0: bits = 8'h44; 3'd1: bits = 8'h44; 3'd2: bits = 8'h44; 3'd3: bits = 8'h7C;
                    3'd4: bits = 8'h44; 3'd5: bits = 8'h44; 3'd6: bits = 8'h44; 3'd7: bits = 8'h00;
                    default: bits = 8'h00;
                endcase
            end
            6'h1A: begin // 'M'
                case (row)
                    3'd0: bits = 8'h44; 3'd1: bits = 8'h6C; 3'd2: bits = 8'h54; 3'd3: bits = 8'h44;
                    3'd4: bits = 8'h44; 3'd5: bits = 8'h44; 3'd6: bits = 8'h44; 3'd7: bits = 8'h00;
                    default: bits = 8'h00;
                endcase
            end
            6'h1B: begin // 'O'
                case (row)
                    3'd0: bits = 8'h38; 3'd1: bits = 8'h44; 3'd2: bits = 8'h44; 3'd3: bits = 8'h44;
                    3'd4: bits = 8'h44; 3'd5: bits = 8'h44; 3'd6: bits = 8'h38; 3'd7: bits = 8'h00;
                    default: bits = 8'h00;
                endcase
            end
            6'h1C: begin // 'P'
                case (row)
                    3'd0: bits = 8'h78; 3'd1: bits = 8'h44; 3'd2: bits = 8'h44; 3'd3: bits = 8'h78;
                    3'd4: bits = 8'h40; 3'd5: bits = 8'h40; 3'd6: bits = 8'h40; 3'd7: bits = 8'h00;
                    default: bits = 8'h00;
                endcase
            end
            6'h1D: begin // 'R'
                case (row)
                    3'd0: bits = 8'h78; 3'd1: bits = 8'h44; 3'd2: bits = 8'h44; 3'd3: bits = 8'h78;
                    3'd4: bits = 8'h48; 3'd5: bits = 8'h44; 3'd6: bits = 8'h44; 3'd7: bits = 8'h00;
                    default: bits = 8'h00;
                endcase
            end
            6'h1E: begin // 'X'
                case (row)
                    3'd0: bits = 8'h44; 3'd1: bits = 8'h44; 3'd2: bits = 8'h28; 3'd3: bits = 8'h10;
                    3'd4: bits = 8'h28; 3'd5: bits = 8'h44; 3'd6: bits = 8'h44; 3'd7: bits = 8'h00;
                    default: bits = 8'h00;
                endcase
            end
            6'h1F: begin // 'Y'
                case (row)
                    3'd0: bits = 8'h44; 3'd1: bits = 8'h44; 3'd2: bits = 8'h28; 3'd3: bits = 8'h10;
                    3'd4: bits = 8'h10; 3'd5: bits = 8'h10; 3'd6: bits = 8'h10; 3'd7: bits = 8'h00;
                    default: bits = 8'h00;
                endcase
            end
            6'h20: begin // '-'
                case (row)
                    3'd0: bits = 8'h00; 3'd1: bits = 8'h00; 3'd2: bits = 8'h00; 3'd3: bits = 8'h7C;
                    3'd4: bits = 8'h00; 3'd5: bits = 8'h00; 3'd6: bits = 8'h00; 3'd7: bits = 8'h00;
                    default: bits = 8'h00;
                endcase
            end
            6'h21: begin // '+'
                case (row)
                    3'd0: bits = 8'h00; 3'd1: bits = 8'h10; 3'd2: bits = 8'h10; 3'd3: bits = 8'h7C;
                    3'd4: bits = 8'h10; 3'd5: bits = 8'h10; 3'd6: bits = 8'h00; 3'd7: bits = 8'h00;
                    default: bits = 8'h00;
                endcase
            end
            6'h22: begin // 'Z'
                case (row)
                    3'd0: bits = 8'h7C; 3'd1: bits = 8'h04; 3'd2: bits = 8'h08; 3'd3: bits = 8'h10;
                    3'd4: bits = 8'h20; 3'd5: bits = 8'h40; 3'd6: bits = 8'h7C; 3'd7: bits = 8'h00;
                    default: bits = 8'h00;
                endcase
            end
            6'h23: begin // 'K'
                case (row)
                    3'd0: bits = 8'h7C; 3'd1: bits = 8'h20; 3'd2: bits = 8'h28; 3'd3: bits = 8'h30;
                    3'd4: bits = 8'h28; 3'd5: bits = 8'h24; 3'd6: bits = 8'h22; 3'd7: bits = 8'h00;
                    default: bits = 8'h00;
                endcase
            end
            default: bits = 8'h00;
        endcase
    end
endmodule
