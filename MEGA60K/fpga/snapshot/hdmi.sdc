# ---- 主固件 main_B 时钟约束 (顶层 top_main 例化 top, 层级多一层 u_top/) ----
# 与 audio_mega60k_check.sdc 的唯一区别: 所有 get_pins 加了 u_top/ 前缀。
# 若不加这层前缀, 约束匹配不到, 综合会退化成默认约束 (时序可能不收敛)。

# 内部 OSCA: 210MHz/4 = 52.5MHz
create_clock -name osc_clk -period 19.048 [get_pins {u_top/osc_inst/osc_inst_s0/OSCOUT}]

# PLLA: 52.5MHz * 31/(2*128) = 6.357MHz (倍频31/分频256)
create_generated_clock -name pll_clk
    -source [get_pins {u_top/osc_inst/osc_inst_s0/OSCOUT}]
    -multiply_by 31 -divide_by 256 [get_pins {u_top/pll_52p5_to_6m/PLLA_inst/CLKOUT0}]

# CLKDIV: 6.357MHz / 4 = 1.589MHz 位时钟
create_generated_clock -name audio_clk
    -source [get_pins {u_top/pll_52p5_to_6m/PLLA_inst/CLKOUT0}]
    -divide_by 4 [get_pins {u_top/clk_div4/clkdiv_inst/CLKOUT}]

create_clock -name video_ref -period 20.000 [get_ports {i_clk}]
create_generated_clock -name serial_clk -source [get_ports {i_clk}] -master_clock video_ref -multiply_by 22 -divide_by 3 [get_pins {u_tmds_pll/PLLA_inst/CLKOUT0}]
create_generated_clock -name pixel_clk -source [get_ports {i_clk}] -master_clock video_ref -multiply_by 22 -divide_by 15 [get_pins {u_tmds_pll/PLLA_inst/CLKOUT1}]
# Crossings: synchronized PT8211 wires, two-flop status request/ack, held status bus.
set_clock_groups -asynchronous -group [get_clocks {osc_clk pll_clk audio_clk}] -group [get_clocks {video_ref serial_clk pixel_clk}]
