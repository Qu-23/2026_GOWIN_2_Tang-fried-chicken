# 云鸣 · 实时多音色合成引擎 I 式

**2026 全国大学生嵌入式芯片与系统设计竞赛 · 高云赛道选题二**
「基于 FPGA 的实时多音色合成电子乐器引擎」—— 双板 FPGA 系统（GOWIN）

| 板卡 | 角色 | 芯片 |
|---|---|---|
| ACG525 | 交互前端：触摸网格 GUI / 12 键光电琴键 / APDS-9960 手势 | GW5A-25 |
| Tang Mega 60K | 合成引擎：8 复音合成 / HDMI 可视化（频谱·示波器·李萨如）/ 蓝牙上位机 | GW5AT-60 |

板间接口：UART 115200 8N1，4 字节帧 `[A5][cmd][note][vel]`（协议细节见各分支 README）

## 分支导航

- [`ACG525`](https://github.com/Qu-23/2026_GOWIN_2_Tang-fried-chicken/tree/ACG525) —— 交互前端工程：v10 固化版（15 个 RTL + 3 个 ModelSim 测试台 + 固化码流 + UI 规格），`legacy/` 收录 v1~v10d 历史版本
- [`TANG_MEGA_60K`](https://github.com/Qu-23/2026_GOWIN_2_Tang-fried-chicken/tree/TANG_MEGA_60K) —— 合成引擎工程：`fpga/`（RTL + 固化码流 + HDMI 可视化源码）、`pc/`（网页控制端 + 蓝牙桥接 + 乐曲素材）、`verification/`（金标准校验链 + 提交自验脚本）
- `main` —— 项目门面与导航
