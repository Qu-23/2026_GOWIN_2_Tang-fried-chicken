//Copyright (C)2014-2024 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: IP file
//Device: GW5AT-60 (Tang Mega 60K)
//Device Version: B
//Note: 内部振荡器 OSCA, FREQ_DIV=4 -> 210MHz/4 = 52.5MHz
module Gowin_OSC (oscout, oscen);
output oscout;
input oscen;
OSCA osc_inst (
    .OSCOUT(oscout),
    .OSCEN(oscen)
);
defparam osc_inst.FREQ_DIV = 4;
endmodule //Gowin_OSC
