# MEGA60K 合成引擎分支

Tang Mega 60K (GW5AT-60) —— 实时多音色合成电子乐器引擎之合成端。

- 完整工程见 `MEGA60K/`：`fpga/`（RTL 与固化码流 `main_Y_HDMI_final.fs`）、`pc/`（上位机 web 控制端与工具）、`docs/`（接口文档与底板原理图）、`verification/`（仿真与金标准校验）、`verify_submission.py`（提交自验脚本）
- 工程详情见 `MEGA60K/README.md`
- 姊妹分支 `ACG525`：交互前端（触摸 GUI / 12 键光电琴键 / APDS-9960 手势）
- 板间接口：UART 115200 8N1，4 字节帧 `[A5][cmd][note][vel]`（协议细节见 ACG525 分支 README）
