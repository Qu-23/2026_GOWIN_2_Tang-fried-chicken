# 2026 GOWIN_2 Tang-fried-chicken — ACG525 交互前端

2026 全国大学生嵌入式芯片与系统设计竞赛 · 高云赛道选题二
**「基于 FPGA 的实时多音色合成电子乐器引擎」** —— 双板架构之交互前端（ACG525, GW5A-25）。

> 分支说明：`ACG525` = 交互前端工程（本分支）｜`TANG_MEGA_60K` = 合成引擎工程（fpga / 上位机 / 验证，已完整入库）｜`main` = 项目主入口

## 系统定位

```
┌─────────────────────────┐  UART 115200 8N1   ┌──────────────────────────┐
│  ACG525 (GW5A-25)       │  [A5][cmd][note]   │  Tang Mega 60K (GW5AT-60)│
│  交互前端 (本仓库分支)    │ ────────────────▶ │  合成引擎 (8 复音,       │
│  触摸 GUI / 12键琴键 /  │    4-byte frame    │  ADSR / 多音色 / I2S)    │
│  手势 → 事件编码         │                    │  + 19" DVI 可视化        │
└─────────────────────────┘                    └──────────────────────────┘
```

交互维度：**触摸面板**（音色/变体/颤音/滑音/效果器/八度/和弦/测试模式）+ **12 键光电琴键**（CdS 挡光矩阵）+ **APDS-9960 手势**（挥手切音色/八度）。

## 目录结构

```
ACG525/
├── tft_panel_uart.gprj     # Gowin 工程文件 (GW5A-LV25UG324ES)
├── src/                    # v10 最终版全部 RTL
│   ├── tft_panel_uart_top.v    # 顶层：时钟(9MHz)/显示/触摸/琴键/手势/UART 汇聚
│   ├── touch_xpt2046.v         # XPT2046 电阻屏 SPI 驱动
│   ├── touch_ctrl.v            # 坐标滤波 + 校准映射 + 按压去抖 (3.3ms 轮询)
│   ├── touch_panel.v           # 网格 GUI 语义层 (9 态状态机 + 手势配置入口)
│   ├── keypad_scan.v           # 12 键 CdS 矩阵键扫 (4 行 one-hot Hi-Z × 3 列)
│   ├── apds9960_gest.v         # APDS-9960 手势引擎 (ID 热插拔/GFIFO/四方向判决)
│   ├── i2c_master.v            # 通用 I2C 主机 (重复 START/多字节连读/ACK 检测)
│   ├── frame_pack.v            # 事件 → [A5][cmd][note][vel] 帧打包 (8 深 FIFO)
│   ├── uart_tx.v               # UART 发送
│   ├── ui_render.v             # 480x272 流式渲染 (无帧缓存, 纯组合)
│   ├── font8x8.v               # 6bit 编码 8x8 字库 (A-Z/0-9/符号)
│   ├── disp_driver.v           # TFT 时序驱动 (厂商例程)
│   ├── disp_parameter_cfg.v    # TFT 时序参数 (480x272)
│   ├── gowin_pll/gowin_pll.v   # PLL IP (50MHz → 9MHz)
│   └── tft_panel_uart.cst      # 引脚约束
├── sim/                    # ModelSim 测试台
│   ├── tb_grid_panel.v         # 网格 GUI 语义冒烟 (ALL PASS)
│   ├── tb_keypad.v             # 矩阵键扫电气级仿真 (ALL PASS)
│   └── tb_apds_gest.v          # 手势引擎 + I2C 从机行为模型 (ALL PASS)
├── bitstream/
│   └── tft_panel_uart_gest_v10.fs  # v10 固化版码流 (作品视频同版本)
└── docs/
    └── gui_touch_spec.html     # 触摸 UI 交互规格 (480x272 1:1 可点原型)

legacy/                    # 历史版本与调试资料 (不在最终工程内)
├── bitstreams/             # v1~v10d 各版本码流
├── src/                    # 废案: bh1750_i2c.v (BH1750 克隆芯片测量引擎失效)、
│                           #       i2c_bh1750_tester.v (FPGA 独立 I2C 测试器)
├── stm32_bh1750_test/      # STM32 独立验证程序
├── gui/                    # 设计过程图
└── module_docs/            # 模块厂商资料 (APDS-9960 / GY-302)
```

## 构建与烧录

1. Gowin V1.9.12.03 打开 `tft_panel_uart.gprj`（器件 GW5A-LV25UG324ES），或命令行：
   `gw_sh.exe build.tcl`（Synthesis + PnR，产物 `impl/pnr/tft_panel_uart.fs`）
2. 烧录 `bitstream/tft_panel_uart_gest_v10.fs`（固化版本，与作品视频一致）到 ACG525。
3. 外设连接见 `src/tft_panel_uart.cst` 注释：TFT 排线（厂商例程引脚）、触摸 SPI、
   APDS-9960 I2C@C17/C18（模块 4.7k 上拉跳线须使能）、琴键矩阵 ROW=D17/D18/E16/F14 / COL=F17/G14/G16（各列 47k 下拉）、LAMP=C15、UART TX=V8 → 60K RX（共地）。

## 通信协议（下行至合成引擎）

115200 8N1，4 字节帧 `[0xA5][cmd][note][vel]`：
- `cmd[7]=1` note_on（`cmd[5:4]`=颤音、`cmd[3]`=音色候选位、`cmd[2:0]`=音色），`cmd[7]=0` note_off
- `cmd=0x40` 测试模式切换（`note[0]`=开关）
- `cmd=0x80|{rev,mix,fx}` 原始控制帧（滑音/效果器，`vel=0x5C` 标记）

## 资源占用（GW5A-25）

Logic 2338/23040 (11%)，Register 735/23685 (4%)，无时序违例。

## 版本

v10（2026-11-03）：触摸网格 GUI + 12 键矩阵键扫（KP_EN=0 待矩阵接线）+ APDS-9960 手势 + 双事件源仲裁 + 2s 防死锁。此版本为作品视频录制与提交的固化基准。
