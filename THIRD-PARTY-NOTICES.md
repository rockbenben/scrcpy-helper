# 第三方组件声明 · Third-party notices

本仓库只有三个文件是自己的，以 MIT 开源（见 [LICENSE](./LICENSE)）：

- `scrcpy-helper.ps1`
- `投屏助手-双击运行.bat`
- `使用说明.txt`

Release 里的 zip 除上述三个文件外，**其余全部来自 [scrcpy](https://github.com/Genymobile/scrcpy) 官方 win64 发行包，逐字节原样转发、未作任何修改**，遵循 Apache License 2.0（by Genymobile）。

以 scrcpy v4.1 官方发行包 `scrcpy-win64-v4.1.zip` 为例，转发的 16 个文件是：

| 文件 | 说明 |
| ---- | ---- |
| `scrcpy.exe` | 投屏主程序 |
| `scrcpy-server` | 推送到手机端运行的服务端 |
| `adb.exe` · `AdbWinApi.dll` · `AdbWinUsbApi.dll` | Android 平台工具 |
| `avcodec-62.dll` · `avformat-62.dll` · `avutil-60.dll` · `swresample-6.dll` | FFmpeg 运行时 |
| `SDL3.dll` | SDL |
| `libusb-1.0.dll` | libusb |
| `scrcpy.png` · `disconnected.png` | scrcpy 自带图标 |
| `scrcpy-noconsole.vbs` · `open_a_terminal_here.bat` | scrcpy 自带辅助脚本 |
| `LICENSE.txt` | **Apache License 2.0 全文** |

上述 DLL 各自的上游许可（FFmpeg、SDL、libusb）沿用 scrcpy 官方发行包的既有安排——本项目不增删该发行包中的任何文件。

## 打包时必须遵守

1. **不要删 `LICENSE.txt`**。Apache-2.0 第 4(a) 条要求向接收者提供许可副本，那个文件就是。
2. **不要修改任何 scrcpy 文件**。一旦修改，Apache-2.0 第 4(b) 条要求在被改动的文件上显著标注改动。目前无一被改。
3. 发行包里**不放**本助手自己的 MIT 全文。`LICENSE.txt` 只是 scrcpy 的 Apache-2.0，不覆盖助手那三个文件；助手的 MIT 许可以仓库根目录的 `LICENSE` 为准，包内「使用说明.txt」末尾有仓库地址。MIT 那部分的版权人即本项目作者，随包附全文不是义务。

scrcpy 上游没有 `NOTICE` 文件，因此 Apache-2.0 第 4(d) 条不适用。

## 商标

scrcpy 是 Genymobile 的商标。本项目是独立的图形外壳，与 scrcpy 作者无从属关系，也未获其背书。
