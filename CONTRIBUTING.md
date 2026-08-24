# 参与开发

欢迎 issue / PR。

## 打包发行版

仓库不含 scrcpy 二进制，打包就是复制三个文件：把 `scrcpy-helper.ps1`、`投屏助手-双击运行.bat`、`使用说明.txt` 复制进 [scrcpy](https://github.com/Genymobile/scrcpy/releases) 的解压目录，整个文件夹压成 zip。用户解压后双击 `.bat` 即可使用。

**还要把本仓库的 `LICENSE` 一并复制进去，改名为 `LICENSE-scrcpy-helper.txt`。** scrcpy 发行包里那个 `LICENSE.txt` 是它自己的 Apache-2.0，不覆盖本助手的三个文件；两份都放，解压的人才分得清哪个文件按哪个许可。scrcpy 的 `LICENSE.txt` 不要删——原样保留它是 Apache-2.0 的要求。

**请用 scrcpy 4.1 及以上版本打包。** 助手用到了 `--flex-display`（独立窗口）、`--keep-active`（无线投屏保持唤醒，4.0 起），以及 VP8 / VP9 视频编码、`--ignore-video-encoder-constraints`（编码器约束兜底，4.1 起）；用旧版打包会让这些功能因「未知参数」直接失败。升到 4.1 还白得：拖拽传文件后相册 / 文件管理器即时可见（媒体扫描）、色彩空间转换修复，以及若干稳定性修复（FFmpeg 8.1.2 / SDL 3.4.12）。

## 多语言（i18n）

尤其欢迎。当前界面文案内嵌在脚本里，后续可抽成字符串表以支持英文等语言——在那之前，仓库刻意不提供英文 README：界面全中文时把英文读者引进来，只会让他多点一次、再退出去。
