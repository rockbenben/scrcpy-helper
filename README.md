# scrcpy 投屏助手 · scrcpy Helper (Windows)

给 [scrcpy](https://github.com/Genymobile/scrcpy) 套一层 **免安装、双击即用、全中文** 的 Windows 图形界面。
A zero-install, double-click, Chinese-first GUI wrapper for **scrcpy** on Windows.

> 365 开源计划 #019 · 给 scrcpy 套一层免安装、双击即用、全中文的 Windows 投屏图形界面

![scrcpy 投屏助手界面](./assets/scrcpy-helper-ui.png)

## 这是什么 · What

scrcpy 是优秀的安卓投屏工具，但它是命令行程序，对普通用户不友好。本项目用一个 **单文件 PowerShell 脚本** 给它套了个图形界面：解压、双击，点按钮就能投屏，常用设置一键勾选，零基础也能上手。

> scrcpy is great but command-line only. This wraps it in a tiny PowerShell GUI — unzip, double-click, click a button. No install, no runtime, all Chinese UI.

## 特点 · Features

- 🟢 **绿色单文件**：一个 `.ps1` + 一个 `.bat`，零依赖、免安装，U 盘 / 受限电脑也能跑。
- 🇨🇳 **全中文 + 人话提示**：每个设置悬停都有大白话说明。
- 🖥️ 有线 / 无线投屏、手机当摄像头、录屏、独立窗口（虚拟显示器），都是一个按钮。
- ⚙️ 「常用」设置页聚合最高频项：保持唤醒、投屏关屏、无线自动重连、清晰度……改完自动记忆。
- 🔌 关窗口=停投屏（录屏先确认），最小化=投屏继续；可选关闭时断开无线连接。

## 怎么用（普通用户）· Usage

1. 到 [Releases](../../releases) 下载打包好的 zip（已内置 scrcpy），解压到任意文件夹。
2. 手机开启「USB 调试」（设置 > 关于手机 > 连点 7 次版本号 > 开发者选项）。
3. 双击 `投屏助手-双击运行.bat`，点「有线投屏」即可。

详见随包的 `使用说明.txt`。

## 与 QtScrcpy / escrcpy 的区别 · Why another one

想要功能完整、跨平台，更推荐成熟的 [QtScrcpy](https://github.com/barry-ran/QtScrcpy) 或 [escrcpy](https://github.com/viarotel-org/escrcpy)。本项目走的是另一条路：一个单脚本、免安装的小工具，界面全中文。如果你只是想简单投个屏、又偏爱绿色便携，可以试试它。

> Want full features? Go with QtScrcpy / escrcpy. This is just a tiny, no-install, Chinese GUI for simple mirroring.

## 打包发布 · Build a release

仓库不含 scrcpy 二进制。打包很简单：把 `scrcpy-helper.ps1`、`投屏助手-双击运行.bat`、`使用说明.txt` 三个文件复制进任意 [scrcpy](https://github.com/Genymobile/scrcpy/releases) 的解压目录，整个文件夹压成 zip 即可。用户解压后双击 `.bat` 就能用。

## 致谢 · Credits

- 投屏核心：[scrcpy](https://github.com/Genymobile/scrcpy)（Apache-2.0）by Genymobile。本项目仅是其图形外壳。
- 图文教程：<https://newzone.top/posts/2019-08-26-scrcpy_screen_projection.html>

## 许可证 · License

封装脚本以 [MIT](./LICENSE) 开源；scrcpy 本体遵循其 Apache-2.0 许可。

## 贡献 · Contributing

欢迎 issue / PR。**多语言（i18n）** 尤其欢迎：当前界面文案内嵌在脚本里，后续可抽成字符串表以支持英文等语言。

## 关于 365 开源计划 · About

本项目是 [365 开源计划](https://github.com/rockbenben/365opensource) 的第 19 个项目。

一个人 + AI，一年 300+ 个开源项目。[提交你的需求 →](https://my.feishu.cn/share/base/form/shrcnI6y7rrmlSjbzkYXh6sjmzb)
