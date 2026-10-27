# AGENTS.md

写给协作方（AI 编程工具或人类开发者）的仓库级工作约定。动手前读完这一份。
如果你用的工具自带指令文件，把它当成本文件的指针，不要当成第二套规则。

scrcpy 投屏助手：**一个单文件 PowerShell 脚本**，给开源投屏工具 scrcpy 套一层全中文图形界面。
免安装、解压双击即用、不需要管理员权限。

---

## 1. 仓库里有什么

```
scrcpy-helper.ps1            # 全部代码 + 全部界面文案（唯一的源文件）
投屏助手-双击运行.bat          # 启动器
使用说明.txt                  # 随包说明书（用户读的那份）
README.md                    # 仓库门面（GitHub 首页）
CONTRIBUTING.md              # 打包发行版、改界面时的同步清单、多语言
THIRD-PARTY-NOTICES.md       # 第三方组件声明（许可证义务，别乱改）
LICENSE                      # 本项目三个文件的 MIT
assets/                      # README 引用的截图与图标
```

- 仓库**不含** scrcpy 二进制：`.gitignore` 排掉了 `scrcpy.exe` / `adb.exe` / `*.dll` / `scrcpy-server` / scrcpy 官方包自带的 `LICENSE.txt` 等。
- `docs/superpowers/`、`design-preview/`、`.qoder*`、`投屏助手-设置.json`、`投屏助手-错误日志.txt` 都是本地产物，**不入库**。
- **没有 CI、没有测试框架、没有构建脚本。** 唯一的「构建」是复制三个文件压 zip。

## 2. 已确定的事（不要重新讨论）

1. **保持单文件 PowerShell + WinForms。** 不编译 exe、不引外部运行库、不换 Electron/WPF、不做安装器。用户的路径是「解压 → 双击 `.bat`」。
2. **界面全中文，刻意不提供英文 README。** 界面全中文时把英文读者引进来，只会让他多点一次再退出去。
3. **像素写死布局 + 手动 DPI 缩放。** 进程声明 System-Aware DPI 感知（不是 Per-Monitor：宿主没有 app.config，WinForms 处理不了跨屏的 `WM_DPICHANGED`）；各窗体 Load 时 `Set-DpiScale` 用 `GetDpiForWindow` 读真实 DPI，再 `Control.Scale` 等比放大。**不要**改回 `AutoScaleMode=Dpi`，也不要改成自动布局。
4. **打包基线是 scrcpy 5.0.1。** 助手用到 `--flex-display`、`--keep-active`、VP8/VP9、`--ignore-video-encoder-constraints`、`--hwdec`；5.0 的 H.265 硬件解码在部分显卡驱动上会花屏，所以下限卡 5.0.1。完整理由写在 `CONTRIBUTING.md`。
5. **许可证分工固定**：助手三个文件 MIT；发行包里其余全部是 scrcpy 官方 win64 包**逐字节原样转发**，遵循 Apache-2.0。`LICENSE.txt` 不能删、任何 scrcpy 文件不能改、发行包里不放本项目的 MIT 全文。详见 `THIRD-PARTY-NOTICES.md`。
6. **不做的事**：不 root 手机、不装手机端 App、不联网上报、不写开机自启项（只在 HKCU 写一个 AUMID 显示名，让任务栏图标和通知标题像自己的 App）、不采集遥测。

## 3. 改代码时的硬约束

- **注释写「为什么」，不写「什么」。** 不要写会漂的行号（`第 133 行` 这种几天就错），指代位置一律用函数名/控件名。
- **数组返回一律 `@(...)` 包一层。** PowerShell 会把单元素数组拆成标量，`字符串 + 数组` 变成拼接——`Get-MirrorArgs` 上方有完整说明。
- **含空格的参数不能靠 `Start-Process` 的数组传参。** 录屏路径 `C:\My Videos\x.mp4` 会被拆成多段，必须自己拼命令行串加引号。
- **闭包里不要写 `$script:裸变量`。** 闭包有自己的模块作用域，`$script:` 写进去的是副本，真标志永远不变。跨闭包共享状态用「哈希表 + 捕获引用」（`$script:mainFlow` / `$script:reconnectState`）。
- **别在 UI 线程上做长阻塞。** `Invoke-Hidden` 超时上限 15 秒；连接/重连这类慢操作走 runspace（`Connect-RememberedAsync` / `Reconnect-LastAsync`）。
- **主流程一律走 `Invoke-MainFlow`。** 它负责防重入、忙态配色、状态药丸和提示收尾；自己起流程就会漏掉这些，用户连点两次就跑两遍。
- **`Get-DeviceList` 只回 `state=device` 的设备。** 要区分 `offline` / `unauthorized` 用 `Get-AdbDeviceState`。

## 4. 界面文案改了要同轮同步

界面文案全部内嵌在 `scrcpy-helper.ps1`。改任何一段用户看得见的文字，同一轮必须一起改：

| 位置 | 改什么 |
| --- | --- |
| `README.md` | 概览、「能做什么」里逐字引用的说法 |
| `使用说明.txt` | 随包说明书，逐字引用必须对得上 |
| 脚本内 | 悬停提示、按钮文案、弹窗正文——同一件事在别处也要统一口径 |

- 数字输入框最小值是 0、留不下空值 → 写「0=不限制」「0=用默认」；只有文本框才写「不填=…」。
- 说明书用「一、二、三」分节，脚本里引用节号要写「第一节」，不是「第 1 节」。
- 同一功能的措辞在脚本、README、说明书里必须逐字一致，别各写各的。

## 5. 验证

```powershell
# 语法自检（没输出就是没语法错）
$err = $null; $tok = $null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\scrcpy-helper.ps1), [ref]$tok, [ref]$err) | Out-Null
$err | ForEach-Object { $_.Message }
```

- 语法过了**不等于**界面对了。改了控件坐标/文案/尺寸，双击 `投屏助手-双击运行.bat` 起真程序看。
- 仓库里没有自动化测试，不要声称「测试通过」。能做的验证是：语法自检 + 起真程序点一遍 + 必要时用 `design-preview/` 下的截图脚本留证（UIAutomation + PrintWindow，产物不入库）。
- 改了界面却没重截 `assets/*.png`，README 就会展示旧界面——截图和代码要同轮更新。

## 6. 工作树与提交

- **先看 `git status` 和 `git diff`。** 工作树常常是脏的：可能是另一个人/另一个会话留的未提交改动。**别把别人的改动当垃圾清掉**，也别把自己的改动混进不相关的提交。
- 提交按功能域分组，一个 commit 一个逻辑单元；commit message 用英文（Conventional Commits），不写 AI 署名。
- 不要提交 `投屏助手-设置.json`、`投屏助手-错误日志.txt`、`design-preview/`、`.qoder*`、`docs/superpowers/`。
- 不要 push、不要打 tag、不要发 Release，除非用户明确要求。

## 7. 做完的标准

1. 语法自检无输出。
2. 改过的界面自己起真程序看过（或用截图脚本留了证）。
3. 脚本、`README.md`、`使用说明.txt` 三处文案口径一致。
4. `git diff` 里没有顺手带上的无关改动。
5. 报告时说清：哪些实际验证过、哪些没验证、有没有推送。
