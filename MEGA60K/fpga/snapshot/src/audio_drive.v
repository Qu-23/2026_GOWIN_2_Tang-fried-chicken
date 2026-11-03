//audio_drive - 标准 Philips I2S 发送机（16bit / 32BCK 帧，左右声道各 16 位，1 位延迟）
//=====================================================================
// 修复说明（2026-10-10, 受 M3-Grant/fpga-synth-engine 的 I2S 调试记录启发）:
//   原 nano20k 例程右声道 MSB 与 WS 跳变同拍（左对齐时序, 0 位延迟），
//   标准 I2S 接收端会把跳变后第 1 个 BCK 当无效位跳过, 导致右声道数据
//   被整体左移 1 位 = 音量翻倍 + 削波失真（声音发闷/发炸）。
//   本版重写为左右声道对称: WS 跳变后第 1 个 BCK 为无效位, 第 2 个 BCK 出 MSB。
//
// 帧结构（b_cnt 0..31）:
//   b_cnt  0 : WS->0(左声道), 锁存左样本
//   b_cnt  1 : DIN=左MSB     (跳变后第2个BCK) ✓
//   b_cnt  2~15 : D14..D0
//   b_cnt 16 : WS->1(右声道), 锁存右样本
//   b_cnt 17 : DIN=右MSB     ✓
//   b_cnt 18~31 : D14..D0
//
// 采样率: fs = 1.59MHz/32 = 49.7kHz；合成器每 16 BCK 消费一个新样本(左右交替)
//
// v7 改动(2026-10-10, 支持真立体声): 单一 idata 拆成 idata_l / idata_r。
//   下游加了立体声效果器(合唱/延迟), 左右声道不再是同一个信号。
//   锁存时序、WS 跳变位置、帧长全部保持不变 → 与 DAC 的时序关系不受影响。
//=====================================================================
module audio_drive(
    input        clk_1p536m,//bit时钟，每个采样点占32个clk_1p536m(左右声道各16)
    input        rst_n     ,//低电平有效异步复位信号
    //PCM 数据接口(v7: 左右独立)
    input [15:0] idata_l   ,//左声道样本（有符号16bit）
    input [15:0] idata_r   ,//右声道样本（有符号16bit）
    output       req       ,//数据请求信号（合成器采样节拍，每16 BCK一次）
    //audio接口
    output       HP_BCK   ,//同clk_1p536m
    output       HP_WS    ,//LRCK: 低电平=左声道 高电平=右声道
    output       HP_DIN    //dac串行数据输入信号（MSB first）
);
reg [4:0]  b_cnt;      //0..31 帧内位计数
reg [15:0] sr;         //移位寄存器
reg        HP_WS_r, HP_DIN_r;
reg        req_r;
assign HP_BCK = clk_1p536m;
assign HP_WS  = HP_WS_r ;
assign HP_DIN = HP_DIN_r;
assign req    = req_r  ;

//---- b_cnt ----
always@(posedge clk_1p536m or negedge rst_n)
begin
if(!rst_n)
    b_cnt <= 5'd0;
else
    b_cnt <= b_cnt + 1'b1;
end

//---- req: 锁存前 2 拍请求（合成器在下一沿更新样本, 锁存沿读到新值）----
// b_cnt==14/30 置位 → 合成器在 b_cnt==15/31 沿更新 out → b_cnt==16/0 沿锁存
always@(posedge clk_1p536m or negedge rst_n)
begin
if(!rst_n)
    req_r <= 1'b0;
else
    req_r <= (b_cnt == 5'd14) || (b_cnt == 5'd30);
end

//---- 锁存/移位 + WS + DIN ----
always@(posedge clk_1p536m or negedge rst_n)
begin
if(!rst_n)
    begin
    sr       <= 16'd0;
    HP_WS_r  <= 1'b0;
    HP_DIN_r <= 1'b0;
    end
else
    begin
    if(b_cnt == 5'd0)        //帧起点: 锁存左样本, WS切左声道
        begin
        HP_WS_r <= 1'b0;
        sr      <= idata_l;
        end
    else if(b_cnt == 5'd16)  //半帧: 锁存右样本, WS切右声道
        begin
        HP_WS_r <= 1'b1;
        sr      <= idata_r;
        end
    else                     //其余拍左移
        sr <= {sr[14:0], 1'b0};
    HP_DIN_r <= sr[15];      //MSB 输出(锁存后1拍 → WS跳变后第2个BCK, 标准Philips)
    end
end
endmodule
