//Copyright (C)2014-2024 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: IP file
//Device: GW5AT-60 (Tang Mega 60K)
//Device Version: B
//Note: 时钟分频器 CLKDIV, DIV_MODE=4 -> 6MHz/4 = 1.5MHz 位时钟
module Gowin_CLKDIV (clkout, hclkin, resetn);
output clkout;
input hclkin;
input resetn;
wire gw_gnd;
assign gw_gnd = 1'b0;
CLKDIV clkdiv_inst (
    .CLKOUT(clkout),
    .HCLKIN(hclkin),
    .RESETN(resetn),
    .CALIB(gw_gnd)
);
defparam clkdiv_inst.DIV_MODE = "4";
endmodule //Gowin_CLKDIV
