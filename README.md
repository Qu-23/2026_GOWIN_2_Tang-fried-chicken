# TANG_MEGA_60K 合成引擎分支

Tang Mega 60K (GW5AT-60) —— 实时多音色合成电子乐器引擎之合成端：8 复音并行合成、ADSR 包络、多音色波表、I2S 音频输出、HDMI 可视化（频谱/示波器/李萨如）、蓝牙上位机桥接。

- 姊妹分支 `ACG525`：交互前端（触摸网格 GUI / 12 键光电琴键 / APDS-9960 手势）
- 板间接口：UART 115200 8N1，4 字节帧 `[A5][cmd][note][vel]`（协议细节见 `docs/串口协议.md` 与 ACG525 分支 README）

## 目录结构

```
TANG_MEGA_60K/
├── fpga/                    # FPGA 工程
│   ├── main_Y_HDMI_final.fs     # 固化码流（含 HDMI 可视化）
│   ├── main_Y_HDMI_final.gprj   # Gowin 工程文件
│   ├── *.hex                    # 波表/效果器初始化数据
│   ├── run_all.tcl / manifest.json
│   ├── snapshot/                # 源码快照（含 hdmi/ 可视化: 频谱/示波器/李萨如）
│   └── reports/                 # 综合/布局布线报告
├── pc/                      # 上位机
│   ├── web/                     # 网页控制端（琴键/曲谱/参数）
│   ├── tools/                   # 蓝牙桥接与应用管理脚本
│   └── materials/               # 乐曲素材（卡农/小星星 脱机主旋律与校验）
├── docs/                    # 接口文档（串口协议/接口状态/接口图）
├── verification/            # 金标准校验链：TB + canon 基准 + run_rtl.py
├── SHA256.json              # 提交文件校验清单
└── verify_submission.py     # 提交自验脚本 (python verify_submission.py)
```

## 验证

`python verify_submission.py` 一键校验提交完整性；`verification/run_rtl.py` 跑 RTL 金标准比对（卡农曲目 DSP 逐样本对拍）。
