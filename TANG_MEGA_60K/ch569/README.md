# CH569 USB CDC 控制转发

此目录从 Sipeed TangMega-138K-example 中的 CH569_HSPI_USB 固件派生。USB 设备层沿用官方实现，转发部分改为 UART2；适配的 FPGA 接收入口与约束来自 Tang Mega 60K 工程。

## 数据路径

USB 主机 → CH569 CDC OUT → UART2 TX PA3 → 底板 HD3 → FPGA K22 → A5 控制帧解析。

底板已经连接 PA3 与 FPGA K22，不增加外部飞线。UART2 固定 115200、8N1，CPU 与外设统一按 120 MHz 配置。USB 的分包与合包不改变应用层的字节顺序。HSPI 在此版本关闭，避免占用 PA3 的复用功能。

FPGA 使用配套的 main_Y_HDMI_CH569 工程，顶层 top_hdmi_ch569，WIRED_RX_CH569=1。参数为 0 时改用 V14 有线接收；两种配置均保留 B15/B16 蓝牙。此转发版本提供 USB 到 FPGA 的单向命令通路，USB IN 不承载板端音频或演奏回传。

## 构建与配套

使用 MounRiver Studio 导入 .project 与 .cproject；保留 Startup、RVMSIS、Peripheral、User、链接脚本和 USB3 厂商库。芯片内存配置沿用官方说明：RAMX 96 KB、ROM 32 KB，下载配置脚 PA13。

CH569 是 USB 设备。连接它的设备需要承担 USB 主机、CDC 枚举及 OUT 端点写入，单独输出 TTL UART 的 TX 引脚不能直接替代 USB 主机。

本次交付修改源码，并完成宿主机 C 转发测试及 FPGA 接收仿真；没有执行 CH569 目标构建或烧录，也没有重建 FPGA FS。已有整机串口演奏实测记录见技术报告，其版本记录与本次源码回归分别保存。

## 修改范围

- User/Main.c：初始化 UART2，关闭 HSPI，保留 USB2/USB3 设备调度。
- User/CDC/cdc.c：逐字节转发 OUT 缓冲，完整消费后重新允许下一包；处理 USB2 零长度包。
- Peripheral/inc/CH56x_common.h：统一 FREQ_SYS 为 120 MHz。

原始 WCH 版权与芯片使用范围声明保留。User/USB30/libCH56x_USB30_device_lib.a 是官方 USB3 链接依赖，其他构建产物不纳入源码包。来源版本及修改文件散列见 origin.json。
