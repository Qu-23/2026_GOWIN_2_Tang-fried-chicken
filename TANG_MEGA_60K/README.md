# Mega 60K 提交代码包

本包为 2026-11-03 当前 60K 工程快照，基于 Main_Y_HDMI_final。音源包含电钢 A、大提琴和 32 声部共享渲染器，并整合蓝牙控制、HDMI 波形、李萨如图与 FFT。
ACG525 拟通过 CH569 Type-C 接入，USB 主机、设备固件和 HSPI 接收仍待确认与实现，见 `docs/接口状态.md`。

## 目录

| 目录 | 内容 |
| --- | --- |
| fpga/ | Gowin 工程、RTL 快照、CST/SDC、初始化 HEX、当前 FS、构建及仿真报告 |
| pc/ | 手机网页、6 项曲谱、Windows 蓝牙代理、手动启动/停止入口、曲谱生成与软件测试 |
| verification/ | 包内可重跑的 RTL 仿真入口、原版 DSP 对照、卡农脱机测试数据与记录 |
| docs/ | 实际控制协议、CH569 接口核对与待确认事项、底板原理图 |

原工程历史固件、个人录音、日志、二维码、Git 数据和工具安装包不放入本提交包。保留当前实现所需的厂商 RTL/IP 文件及其原有版权标注。
ACG525 工程、传感器代码和 CH569 固件不在本包范围内。

## 构建及运行

FPGA 使用 GW5AT-LV60PG484AC1/I0，当前构建工具为 Gowin V1.9.12.03。
在 Gowin Tcl 控制台执行 `fpga/run_all.tcl`，或打开 `fpga/main_Y_HDMI_final.gprj` 并设置顶层 `top_hdmi`、SystemVerilog 2017、CPU regular IO。按脚本运行综合与布局布线。项目引用为相对路径。
现有 `fpga/main_Y_HDMI_final.fs` 与主工程最终演示 FS 一致；新生成文件默认在 `fpga/impl/pnr/`。

电脑侧在 `pc/` 手动双击 `start_bluetooth.cmd`，手机打开控制台当次地址。模块地址需按实际模块修改。只有启动脚本运行后才建立代理，退出用 Ctrl+C 或 `pc/stop_app.cmd`。
首次换电脑先按 `pc/requirements.txt` 准备 Python 依赖。蓝牙 SPP 连接使用 Windows 接口；有线串口使用 pyserial。

手机曲库仅《小星星》为电钢＋大提琴合奏；《欢乐颂》《生日快乐》用电钢，《卡农》《送别》用大提琴，音阶测试用电钢。
板端脱机演奏为 S/K/P/X 单旋律，资料见 `pc/materials/卡农/`；它不是断电保存，也不包含合奏。

## 校验与验证边界

运行 `python verify_submission.py` 检查文件清单、相对路径和 FS 来源。提交版整理了 RTL 注释；`rtl_comment_edits.json` 记录原文件散列与去注释后的词法序列散列，确认与构建版本一致。SHA256 清单不覆盖运行后新生成的日志或录音。
运行 `python verification/run_rtl.py --modelsim <ModelSim的win64目录> --license <许可证路径>` 可重跑包内三个 RTL 检查；不接触板卡。
电脑侧软件回归在 `pc/` 执行 `python -m unittest discover -s tools -p "test_*.py"` 和 `node tools/test_app.cjs`。测试使用模拟/回环通路，不表示蓝牙实板连接通过。

当前 FS 已完成综合、布局布线，Setup/Hold 违例均为 0；Logic 15573/59904、Register 13472/60780、BSRAM 108/118、DSP 26.5/118。
大提琴快速起音版仍待实板听音。v2 的 HDMI 已完成上板检查；该记录仅适用于 v2。CH569 通路尚未测试。报告中的原构建路径供溯源，重建和重跑使用本包相对路径。
