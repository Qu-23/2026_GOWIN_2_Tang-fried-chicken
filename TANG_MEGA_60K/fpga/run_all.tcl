set task_dir [file dirname [file normalize [info script]]]
cd $task_dir
open_project main_Y_HDMI_final.gprj
set_option -top_module top_hdmi
set_option -verilog_std sysv2017
set_option -use_cpu_as_gpio 1
run syn
run pnr
exit
