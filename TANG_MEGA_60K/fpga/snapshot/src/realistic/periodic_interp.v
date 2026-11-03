// Pipelined dual-read periodic ROM. One independent oscillator request/clock.
// Pipeline: synchronous adjacent-point reads -> phase interpolation -> layer
// interpolation. Tag follows the sample through all three register edges.
// A 1024-point table uses phase[23:14], with ten interpolation bits.
module periodic_interp #(
    parameter integer BANKS=9,
    parameter ROM_FILE="instruments"
)(
    input wire clk, rst_n, req,
    input wire [23:0] phase,
    input wire [3:0] bank,
    input wire [7:0] brightness,
    input wire [15:0] tag,
    output reg valid,
    output reg signed [15:0] sample,
    output reg [15:0] out_tag
);
    // Even and odd points are separate SINGLE-read memories. Adjacent
    // samples always belong to opposite memories. This avoids Gowin's
    // duplication of a generic two-read ROM while preserving one req/clk.
    reg [31:0] even_rom [0:BANKS*512-1];
    reg [31:0] odd_rom [0:BANKS*512-1];
    initial begin
        $readmemh({ROM_FILE,"_even.hex"},even_rom);
        $readmemh({ROM_FILE,"_odd.hex"},odd_rom);
    end
    wire [8:0] even_index=phase[23:15]+{8'd0,phase[14]};
    wire [12:0] even_address={bank,even_index};
    wire [12:0] odd_address={bank,phase[23:15]};
    reg [31:0] even_point,odd_point;
    reg odd0;
    wire [31:0] qa=odd0 ? odd_point : even_point;
    wire [31:0] qb=odd0 ? even_point : odd_point;
    reg [9:0] fraction0;
    reg [7:0] bright0,bright1;
    reg [15:0] tag0,tag1;
    reg valid0,valid1;
    // No reset on ROM read registers: permits synchronous BSRAM inference.
    always @(posedge clk) begin
        even_point<=even_rom[even_address];
        odd_point<=odd_rom[odd_address];
    end
    wire signed [16:0] low_a={qa[15],qa[15:0]}, low_b={qb[15],qb[15:0]};
    wire signed [16:0] high_a={qa[31],qa[31:16]}, high_b={qb[31],qb[31:16]};
    wire signed [16:0] low_diff=low_b-low_a, high_diff=high_b-high_a;
    wire signed [27:0] low_product=low_diff*$signed({1'b0,fraction0});
    wire signed [27:0] high_product=high_diff*$signed({1'b0,fraction0});
    wire signed [27:0] low_interp=low_a+(low_product>>>10);
    wire signed [27:0] high_interp=high_a+(high_product>>>10);
    reg signed [15:0] low1,high1;
    wire signed [16:0] layer_diff=$signed({high1[15],high1})-$signed({low1[15],low1});
    wire signed [25:0] layer_product=layer_diff*$signed({1'b0,bright1});
    wire signed [25:0] result=$signed(low1)+(layer_product>>>8);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            fraction0<=0; bright0<=0; bright1<=0; odd0<=0;
            tag0<=0; tag1<=0; out_tag<=0;
            valid0<=0; valid1<=0; valid<=0;
            low1<=0; high1<=0; sample<=0;
        end else begin
            valid0<=req; valid1<=valid0; valid<=valid1;
            fraction0<=phase[13:4]; bright0<=brightness; tag0<=tag;
            odd0<=phase[14];
            low1<=low_interp[15:0]; high1<=high_interp[15:0];
            bright1<=bright0; tag1<=tag0;
            sample<=result[15:0]; out_tag<=tag1;
        end
    end
endmodule
