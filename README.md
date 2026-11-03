# MEGA60K 合成引擎工程 (占位)

Tang Mega 60K (GW5AT-60) 合成引擎：8 复音、ADSR、多音色合成、I2S 音频输出、19" DVI 可视化。

代码由队友维护，待整合后上传。

## 与交互前端的接口

UART 115200 8N1，4 字节帧 `[A5][cmd][note][vel]`（见 ACG525 分支 README 的协议说明）。
