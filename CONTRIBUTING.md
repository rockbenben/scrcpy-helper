# 参与开发

欢迎 issue / PR。

## 改界面时

界面文案全部内嵌在 `scrcpy-helper.ps1`。改任何一段用户看得见的文字，同一轮里一起改：

- `README.md`：概览与「能做什么」里逐字引用的说法
- `使用说明.txt`：随包说明书，逐字引用必须对得上
- 脚本里的悬停提示与按钮文案：同一件事在别处也要统一口径
- `assets/*.png`：README 里画的是真实界面（头图里有主界面和「手机当摄像头」面板）

口径上有一条容易写错：数字输入框最小值是 0、留不下空值，所以要写「0=不限制」「0=用默认」；只有文本框才写「不填=…」（如「不填=投整屏」「不填=用自带的」）。

改控件坐标前先看这两条约定：

- **布局是写死像素 + 手动缩放。** 各窗体在 Load 时按真实 DPI 用 `Control.Scale` 等比放大（见脚本里的 `Set-DpiScale`）。别把 `AutoScaleMode` 改成 `Dpi`——本项目跑在 powershell 宿主里、没有 app.config，WinForms 自带的自动缩放取不到真实 DPI，会失效。坐标一律按 96dpi 写。
- **字号用磅值，别自己乘系数。** 高 DPI 下 GDI 会按显示器 DPI 放大磅值，与 `Control.Scale` 放到一起才是同比放大；再乘一次就成了双倍字号。

改完做一次语法自检（不用起界面）：

```powershell
$err = $null; $tok = $null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\scrcpy-helper.ps1), [ref]$tok, [ref]$err) | Out-Null
$err | ForEach-Object { $_.Message }
```

没有输出就是没语法错。但语法过了不等于界面对了——改了控件坐标或文案，还得双击 `投屏助手-双击运行.bat` 起真程序看一遍。

## 文件管理回归

在 Windows 上分别运行以下命令，CI 也会在这两个 PowerShell 版本中执行同一入口。

```powershell
powershell -NoProfile -File tests/run-file-manager-regression.ps1
pwsh -NoProfile -File tests/run-file-manager-regression.ps1
```

用例覆盖文件夹合并、逐项覆盖授权、链接保存目录，以及查重、传输、冲突复查和合并阶段的关窗取消。ADB 与文件选择框使用替身，文件操作使用临时目录，后台取消会启动并终止一个本地 PowerShell 子进程。回归不需要连接手机，实机验证仍按改动范围执行。

取消回归分别执行后台任务队列和真实 `Fm-Transfer`，以本地 PowerShell 子进程代替 ADB。子进程就绪后才触发关窗，从关窗事件起要求在 5 秒内返回，并确认该子进程已退出。触发关窗时，后台命令必须至少还剩 6 秒超时余量，余量不足会使回归失败，避免把等待命令超时当成主动取消。失败时也会清理该用例持有句柄的子进程。

统一入口还运行负向回归：在临时副本中禁用主动取消并延迟关窗，要求子测试以超时余量不足失败。父测试读取子进程身份及清理记录，再按 PID 和启动时间确认没有残留进程；移除余量断言会导致该负向回归失败。这些检查同样在 CI 的 PowerShell 5.1 与 7 中执行。

子进程身份在实际 `Process.Start()` 返回后立即原子写入，不等待解释器就绪或关窗事件；测试只给载入的函数副本增加启动观察点，取消、等待和 `Kill()` 仍执行原有实现。另有延迟启动且父级在关窗前超时的回归：父级必须清理仍存活的子进程，外层测试持有该进程句柄，验证父级确实超时失败、未触发关窗、对应子进程已经退出。外层失败兜底另用子进程自己发布的就绪身份回收进程，避免登记逻辑损坏时连回归本身也留下进程。

## 打包发行版

仓库不含 scrcpy 二进制，发行包的做法就是：把 `scrcpy-helper.ps1`、`投屏助手-双击运行.bat`、`使用说明.txt` 复制进 [scrcpy](https://github.com/Genymobile/scrcpy/releases) 的解压目录，整个文件夹压成 zip。用户解压后双击 `.bat` 即可使用。

**这一步现在由 CI 做**（`.github/workflows/release.yml`）：推一个 `v*` 标签，它会下载官方 win64 包、按官方 `SHA256SUMS.txt` 核对、把这三个文件放进去、确认 scrcpy 的 16 个文件逐字节没动且 `LICENSE.txt` 还在，压成 `scrcpy-helper-<版本>-windows.zip` 传到 Release 上，并把 `releases/latest` 指向它。

发版说明建议提前写好放在 `.github/release-notes/<标签>.md`（例如 `.github/release-notes/v1.6.3.md`），CI 会拿它当 Release 正文；没有这个文件就用提交记录拼一版。标签推上去之后想补发（当时还没有这个 workflow），去 Actions 页面手动跑一次 `Release`、填标签名即可。标签格式为 `v主版本.次版本.修订号`（如 `v1.6.3`）；预检和打包均使用该标签解析出的同一提交。手动补发默认不改变最新版，需要提升时勾选 `promote_latest`。推送版本标签仍会自动提升最新版。

**scrcpy 的 `LICENSE.txt` 不要删**——原样保留它是 Apache-2.0 的要求。它只覆盖 scrcpy 自己那些文件；助手这三个文件的 MIT 许可放在仓库的 `LICENSE` 里，不再往发行包里塞一份副本（版权人就是本项目作者，不存在第三方授权约束）。CI 会替你查这一条：少了或被改动就打不出包。

**请用 scrcpy 5.0.1 及以上版本打包。** 助手用到了 `--flex-display`（独立窗口）、`--keep-active`（无线投屏保持唤醒，4.0 起）、VP8 / VP9 视频编码与 `--ignore-video-encoder-constraints`（编码器约束兜底，4.1 起），以及 `--hwdec`（「解码方式」选软件解码时才传，5.0 起）；用旧版打包会让这些功能因「未知参数」直接失败。`release.yml` 里的 `SCRCPY_VERSION` 钉的就是这个版本号，升 scrcpy 时连同这里的说明一起改。

5.0 本身也白得一批好处：画面改由电脑显卡解码（`--hwdec` 默认 `auto`，助手不做任何事就生效，CPU 占用约降一个数量级、更省电，显卡解不了会自动回落软件解码）、部分键盘布局的丢键与 `AltGr` 组合键修好、`--time-limit` 的数据竞争修好，依赖升到 adb 37.0.1 / FFmpeg 9.0.2 / SDL 3.4.18。

但下限要卡在 **5.0.1** 而不是 5.0：5.0 的硬件解码在某些显卡驱动上把 H.265 解成绿屏、花屏（FFmpeg 对 Main 码流选中了 Main10 的 D3D11VA 解码器），而「H.265（更清晰）」正是「设置 > 画面」里的一个可选项；5.0.1 已修，顺带修好 `--render-driver=opengl` 在 Windows / macOS 上起不来（助手不传这个参数，只有用户自己填进「其它命令行参数」才会碰到）。5.0.1 没有增删任何命令行参数（`--help` 的参数列表与 5.0 完全一致），依赖版本也没动（仍是 adb 37.0.1 / FFmpeg 9.0.2 / SDL 3.4.18），所以助手代码无需为此改动。

ARM 版 Windows 有官方 `scrcpy-winarm64-v5.0.1.zip`；x64 包在 ARM 机器上靠系统模拟也能跑，所以发行仍只出一个 x64 包，不必为 ARM 单开一份。

## 多语言（i18n）

尤其欢迎。当前界面文案内嵌在脚本里，后续可抽成字符串表以支持英文等语言——在那之前，仓库刻意不提供英文 README：界面全中文时把英文读者引进来，只会让他多点一次、再退出去。
