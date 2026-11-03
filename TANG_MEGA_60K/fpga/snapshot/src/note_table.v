// ============================================================
//  note_table.v —— 音符 → 频率控制字（FCW）查找表
//  自动生成，请勿手改。重新生成：
//    python gen_fcw.py 3.18e6 1 --out src/note_table.v
//
//  主时钟   : 3.180 MHz
//  BCK_HALF : 1
//  实际 fs  : 99375.000 Hz
//  公式     : FCW = f * 2^24 / fs
//
// 25 notes: index 0..24 maps to MIDI 60..84 (C4..C6).
// One shared lookup supplies the FCW stored in each voice.
// ============================================================

module note_table (
    input  wire [4:0]  note_idx,   // 0..24 -> MIDI 60..84 (C4..C6)
    output reg  [23:0] fcw
);

    always @(*) begin
        case (note_idx)
            5'd0 : fcw = 24'd44170;  // C4 (261.63 Hz)
            5'd1 : fcw = 24'd46796;  // C#4 (277.18 Hz)
            5'd2 : fcw = 24'd49579;  // D4 (293.66 Hz)
            5'd3 : fcw = 24'd52527;  // D#4 (311.13 Hz)
            5'd4 : fcw = 24'd55650;  // E4 (329.63 Hz)
            5'd5 : fcw = 24'd58959;  // F4 (349.23 Hz)
            5'd6 : fcw = 24'd62465;  // F#4 (369.99 Hz)
            5'd7 : fcw = 24'd66180;  // G4 (392.00 Hz)
            5'd8 : fcw = 24'd70115;  // G#4 (415.30 Hz)
            5'd9 : fcw = 24'd74284;  // A4 (440.00 Hz)
            5'd10: fcw = 24'd78701;  // A#4 (466.16 Hz)
            5'd11: fcw = 24'd83381;  // B4 (493.88 Hz)
            5'd12: fcw = 24'd88339;  // C5 (523.25 Hz)
            5'd13: fcw = 24'd93592;  // C#5 (554.37 Hz)
            5'd14: fcw = 24'd99157;  // D5 (587.33 Hz)
            5'd15: fcw = 24'd105053; // D#5 (622.25 Hz)
            5'd16: fcw = 24'd111300; // E5 (659.26 Hz)
            5'd17: fcw = 24'd117919; // F5 (698.46 Hz)
            5'd18: fcw = 24'd124930; // F#5 (739.99 Hz)
            5'd19: fcw = 24'd132359; // G5 (783.99 Hz)
            5'd20: fcw = 24'd140230; // G#5 (830.61 Hz)
            5'd21: fcw = 24'd148568; // A5 (880.00 Hz)
            5'd22: fcw = 24'd157402; // A#5 (932.33 Hz)
            5'd23: fcw = 24'd166762; // B5 (987.77 Hz)
            5'd24: fcw = 24'd176678; // C6 (1046.50 Hz)
            default: fcw = 24'd0;
        endcase
    end

endmodule
