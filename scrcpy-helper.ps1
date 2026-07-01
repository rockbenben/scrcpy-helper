# scrcpy 投屏助手（图形界面）
# 由「投屏助手-双击运行.bat」启动，无需手动运行本文件。
# 启动器用 `conhost.exe --headless powershell ... -File 本文件`：Windows 11 默认终端是 Windows Terminal，
# 它会无视 `powershell -WindowStyle Hidden`、始终留一个可见终端窗口；conhost --headless 则无窗口运行、
# 且不移交给 Windows Terminal，从而彻底不出现残留窗口（纯脚本方案，不依赖 .vbs / 编译 exe）。
# 注意：.bat 里不要写 rem 注释——cmd 对 rem 行的解析很脆弱，多条 rem 会导致整个 .bat 不执行；说明放这里。

Set-Location -LiteralPath $PSScriptRoot

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

# 高 DPI 清晰化：必须在创建任何窗口之前声明进程 DPI 感知，否则 Windows 会把 96DPI 画面整体位图放大 → 文字发虚。
# 只声明感知还不够——本脚本布局全是写死像素坐标，声明后窗体会按原始像素在高分屏上显示（清晰但偏小），
# 需配合各窗体的 Set-DpiScale（见 New-Dialog / 忙窗 / 主窗）在 Load 时按真实 DPI 等比放大。
#
# 特意选「系统级 DPI 感知（System-Aware）」而非 Per-Monitor：本脚本跑在 powershell 宿主、无 app.config，
# WinForms 不会处理跨屏的 WM_DPICHANGED 重新布局。若用 Per-Monitor，把窗口从 150% 主屏拖到 125% 副屏时，
# 系统会按 125% 缩小窗框、但控件仍是 150% 的布局 → 界面被截断。改用 System-Aware：窗口一生只按主屏 DPI 布局一次，
# 拖到别的 DPI 屏时由系统整幅位图缩放（副屏略微发软但绝不截断），是本场景最稳的取舍。
# 逐级兜底：System-Aware 上下文（Win10 1607+）→ 旧的系统级感知（Win8.1+）→ 最旧的 SetProcessDPIAware（Vista+）。任何异常都吞掉、不阻断启动。
try {
    Add-Type -Namespace Native -Name Dpi -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(System.IntPtr value);
[System.Runtime.InteropServices.DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetDpiForWindow(System.IntPtr hwnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetDC(System.IntPtr hwnd);
[System.Runtime.InteropServices.DllImport("gdi32.dll")] public static extern int GetDeviceCaps(System.IntPtr hdc, int index);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int ReleaseDC(System.IntPtr hwnd, System.IntPtr hdc);
'@
    $ok = $false
    # DPI_AWARENESS_CONTEXT_SYSTEM_AWARE = -2
    try { $ok = [Native.Dpi]::SetProcessDpiAwarenessContext([System.IntPtr](-2)) } catch {}
    # PROCESS_SYSTEM_DPI_AWARE = 1
    if (-not $ok) { try { [void][Native.Dpi]::SetProcessDpiAwareness(1); $ok = $true } catch {} }
    if (-not $ok) { try { [void][Native.Dpi]::SetProcessDPIAware() } catch {} }
} catch {}

[System.Windows.Forms.Application]::EnableVisualStyles()

# scrcpy 4.0 的命令行输出是 UTF-8；Windows PowerShell 默认按系统 OEM 码页解码，会把中文
# （如「更多应用」里 --list-apps 列出的 App 中文名）读成乱码。统一按 UTF-8 解码原生命令输出。
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# 任务栏图标：把本进程标识成自己的 App，而不是跟着宿主 powershell.exe 走，
# 否则任务栏按钮会沿用 PowerShell 的蓝色图标（标题栏图标由 $form.Icon 控制，不受影响）。
try {
    Add-Type -Namespace Native -Name Shell -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", SetLastError = true)]
public static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);
'@
    [Native.Shell]::SetCurrentProcessExplicitAppUserModelID('rockbenben.scrcpyHelper') | Out-Null
} catch {}

# 控制台信号 API：关闭 / 停止时给「录制中」的 scrcpy 发 Ctrl+C 让它优雅收尾（见 Stop-ScrcpyGraceful）。
# 「后台录制」带 --no-window，没有窗口可 CloseMainWindow，只能靠这个信号，否则直接 Kill 会截断 mp4（尾原子没写、文件打不开）。
try {
    Add-Type -Namespace Native -Name ConIO -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)] public static extern bool AttachConsole(uint dwProcessId);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)] public static extern bool FreeConsole();
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)] public static extern bool GenerateConsoleCtrlEvent(uint dwCtrlEvent, uint dwProcessGroupId);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleCtrlHandler(System.IntPtr HandlerRoutine, bool Add);
'@
} catch {}

# 单实例：已在运行就把已开的窗口拉到最前，然后退出本次启动——双击 .bat 多次不再叠开多个助手。
# 多开的害处：两套 8s 轮询/自动连接白耗资源；更糟的是两个进程会同时写 投屏助手-设置.json、互相覆盖对方刚存的设备/设置。
# 用命名 Mutex 判定"是否首个实例"；不是则找到已有主窗口（按标题）拉到前台再退出。任何异常都按"首个实例"放行，绝不因守卫本身挡住启动。
$script:actEventName = 'rockbenben.scrcpyHelper.activate'   # 命名事件：后启动的实例用它通知已在运行的实例"激活你的窗口"
try {
    # FindWindow 必须指定 CharSet=Unicode（走 FindWindowW）：默认 ANSI 编组中文标题在非中文系统码页下匹配不到、返回 0。
    Add-Type -Namespace Native -Name Win -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)] public static extern System.IntPtr FindWindow(string lpClassName, string lpWindowName);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(uint dwProcessId);
'@
} catch {}
$script:isFirstInstance = $true
try { $script:appMutex = New-Object System.Threading.Mutex($true, 'rockbenben.scrcpyHelper.singleton', [ref]$script:isFirstInstance) } catch { $script:isFirstInstance = $true }
if (-not $script:isFirstInstance) {
    # 已有实例：核心思路——让"已在运行的那个实例激活它自己的窗口"（进程激活自己的窗口远比外部进程抢前台可靠）。
    # 本次(后启动的)实例先 AllowSetForegroundWindow(ASFW_ANY) 把抢前台权限授权出去，再 Set 命名事件通知对方，然后退出。
    try { [void][Native.Win]::AllowSetForegroundWindow([uint32]::MaxValue) } catch {}   # ASFW_ANY = -1：允许任意进程设置前台（授权给第一实例）
    $signaled = $false
    try {
        $evt = [System.Threading.EventWaitHandle]::OpenExisting($script:actEventName)
        [void]$evt.Set(); $evt.Dispose(); $signaled = $true
    } catch {}
    if (-not $signaled) {
        # 事件还没建好（第一实例刚启动中）→ 退回自己找窗口：先试抢前台，不成再用"最小化+还原"兜底（还原自最小化是被允许的前台切换，必成）。
        try {
            $h = [Native.Win]::FindWindow($null, 'scrcpy 投屏助手')
            if ($h -ne [System.IntPtr]::Zero) {
                if ([Native.Win]::IsIconic($h)) { [void][Native.Win]::ShowWindow($h, 9) }   # SW_RESTORE
                [void][Native.Win]::SetForegroundWindow($h)
                Start-Sleep -Milliseconds 60
                if ([Native.Win]::GetForegroundWindow() -ne $h) { [void][Native.Win]::ShowWindow($h, 6); [void][Native.Win]::ShowWindow($h, 9) }   # 6=SW_MINIMIZE→9=SW_RESTORE
            }
        } catch {}
    }
    return   # 已有实例，本次启动到此为止（$script:appMutex 未持有，进程退出即释放，不影响已在运行的那个）
}
# 首个实例：立刻建好命名事件，供后续实例来激活本窗口（等待线程在窗口显示后启动，见 Start-ActivationWaiter）。
try { $script:actEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $script:actEventName) } catch { $script:actEvent = $null }

# 配色（墨 + 素纸 + 朱砂印：素纸灰打底护眼，墨黑主操作，红仅作印章点缀）
$cPaper   = [System.Drawing.Color]::FromArgb(236, 232, 225)   # 素纸灰（暖而不黄，比白柔和）
$cInk     = [System.Drawing.Color]::FromArgb(43, 41, 38)      # 墨黑·主操作按钮/标题
$cInkDark = [System.Drawing.Color]::FromArgb(70, 66, 61)      # 主按钮悬停
$cMuted   = [System.Drawing.Color]::FromArgb(140, 136, 127)   # 次要文字
$cRed     = [System.Drawing.Color]::FromArgb(167, 43, 42)     # 朱砂印（仅标题竖条）
$cRedDark = [System.Drawing.Color]::FromArgb(138, 33, 33)
$cLine    = [System.Drawing.Color]::FromArgb(217, 212, 203)   # 发丝线 / 描边
$cGreen   = [System.Drawing.Color]::FromArgb(47, 129, 88)     # 已连接
$cGreenBg = [System.Drawing.Color]::FromArgb(220, 231, 223)
$cTagBg   = [System.Drawing.Color]::FromArgb(226, 221, 212)   # 未连接药丸
$cWhite   = [System.Drawing.Color]::FromArgb(252, 251, 249)   # 卡片软白（次要按钮 / 输入）
$cHover   = [System.Drawing.Color]::FromArgb(243, 240, 234)   # 次要按钮悬停

$exe = Join-Path $PSScriptRoot 'scrcpy.exe'
$adb = Join-Path $PSScriptRoot 'adb.exe'
$cfgPath = Join-Path $PSScriptRoot '投屏助手-设置.json'
$script:customApps = [ordered]@{}   # 用户自定义的常用 App（名称 => 包名），随设置一起存进 投屏助手-设置.json
$script:knownDevices = [ordered]@{} # 记住的无线设备（地址 ip:port => 备注名），连接成功自动记下，供「设备管理」切换/重连
$script:deviceNames  = [ordered]@{} # 用户自定义的设备显示名（序列号/地址 => 名称），优先于型号显示，可在「设备管理」里重命名
$script:autoConnectExclude = New-Object System.Collections.Generic.List[string]  # 不自动连接的无线地址（设备管理里可切换）
$script:camResByDevice = [ordered]@{}   # 摄像头采集尺寸记忆，按「序列号|前后」分记（serial|back / serial|front => WxH 或档位）
$script:camSizesCache  = @{}            # --list-camera-sizes 结果按设备会话缓存，同一台只读一次
$scrcpyProcs = New-Object System.Collections.ArrayList   # 记录本助手启动的所有 scrcpy 进程，关助手时一并停止
$script:autoConnectStarted = $false                      # 启动自动连接每次只跑一次
$script:bgTimers = New-Object System.Collections.ArrayList  # 钉住后台计时器防 GC（运行中的 Forms.Timer 仅靠自引用会被回收）

# 注：$exe/$adb 的最终解析与「没找到 scrcpy.exe」守卫都挪到了 Load-Settings 之后（见下方 Resolve-Tools + 守卫），
# 这样「设置 > 通用」里自定义的 adb/scrcpy 路径（存在 JSON 里）才能在守卫判断前生效；否则守卫用的是写死的自带路径。

# 同步执行 adb/scrcpy 并取回输出（用于 devices/getprop/connect/--list-* 等一次性查询）。
# 不用 `& $adb ...` 调用操作符：宿主虽是 -WindowStyle Hidden 的 powershell，但它的控制台仍然存在（只是被隐藏），
# `&` 启动 adb.exe/scrcpy.exe 这类控制台子程序时仍可能瞬间闪出一个新控制台窗口。改用 ProcessStartInfo 显式
# CreateNoWindow=true，从源头不创建窗口，而不是创建后再隐藏。顺带用 UTF8 直读输出，不再依赖宿主控制台编码。
function Invoke-Hidden {
    param([string]$FilePath, [string[]]$ArgumentList = @(), [switch]$DiscardStderr, [int]$TimeoutMs = 15000)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    # 不用 ProcessStartInfo.ArgumentList：本助手宿主是 Windows PowerShell 5.1（投屏助手-双击运行.bat 里调用的
    # powershell.exe），实测该属性取出来是 $null、Add 直接报错（“cannot call a method on a null-valued expression”）。
    # 改拼 Arguments 命令行串，和 Start-Scrcpy 给含空格参数补引号的写法保持一致。
    $psi.Arguments = (@($ArgumentList | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try { $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8 } catch {}
    try { $proc = [System.Diagnostics.Process]::Start($psi) } catch { return @() }
    # 并发读 stdout/stderr 再 WaitForExit：先 ReadToEnd 一路再读另一路，输出量大时（如 --list-apps 装机多）
    # 会把另一路的管道缓冲区写满，子进程卡在 write 上不退出，PowerShell 卡在 ReadToEnd 上——互相等死。
    $outTask = $proc.StandardOutput.ReadToEndAsync()   # 先起并发读，下面 WaitForExit 不会被管道缓冲区顶死
    $errTask = $proc.StandardError.ReadToEndAsync()
    # 带超时：adb 有时会在半死的无线设备上卡死（如 `adb -s <addr> shell getprop` 连接半开、永不返回）。
    # 本函数在 UI 线程被 8 秒轮询/按钮调用，若不设上限，一次卡死就把整个界面永久冻住。超时则杀掉子进程兜底。
    if (-not $proc.WaitForExit($TimeoutMs)) {
        try { $proc.Kill() } catch {}
        try { [void]$proc.WaitForExit(2000) } catch {}
    }
    try { [void][System.Threading.Tasks.Task]::WaitAll(@($outTask, $errTask), 3000) } catch {}
    $stdout = if ($outTask.IsCompleted -and -not $outTask.IsFaulted) { $outTask.Result } else { '' }
    $stderr = if ($DiscardStderr -or -not $errTask.IsCompleted -or $errTask.IsFaulted) { '' } else { $errTask.Result }
    $combined = if ($stderr) { "$stdout`n$stderr" } else { $stdout }
    if (-not $combined) { return @() }
    return @($combined -split "`r?`n")
}

# 「独立窗口」可一键打开的最常用 App（按使用度排，购物类靠后）；其余 App 用「更多应用…」从手机列表里挑
$apps = [ordered]@{
    '微信'   = 'com.tencent.mm'
    '抖音'   = 'com.ss.android.ugc.aweme'
    'QQ'     = 'com.tencent.mobileqq'
    '淘宝'   = 'com.taobao.taobao'
    '拼多多' = 'com.xunmeng.pinduoduo'
}

# ---------------- 设置（在界面里改，自动记忆到 投屏助手-设置.json） ----------------
# 用 [ordered] 有序表：保存出来的 JSON 键顺序就按下面的分组排（画面/声音/控制/…），不再是哈希随机序、看着乱。
$defaults = [ordered]@{
    # 画面
    maxSize = 1496; maxFps = 0; bitRate = 0; videoCodec = ''; crop = ''
    # 声音
    audioOn = $true; audioSource = ''; audioCodec = ''
    # 控制
    keyboard = ''; mouse = ''; gamepad = $false; noControl = $false
    screenOff = $false; stayAwake = $true; showTouches = $false; powerOffOnClose = $false
    # 摄像头（存“最大边长档位”如 1920/1280/0，或实测精确尺寸如 1920x1080；统一按字符串存，避免重载时类型转换报错）
    camResMax = '1920'
    # 摄像头面板上次的选择（全局偏好）：前后置 back/front、方向 land/port、补光灯、麦克风。分辨率另按设备+前后记在 camResByDevice。
    camFacing = 'back'; camOrientation = 'land'; camTorch = $false; camMic = $false
    # 窗口
    fullscreen = $false; onTop = $false; borderless = $false
    # 独立窗口
    ndSize = ''; ndDpi = ''; ndNoDecor = $false; ndMode = 'settings'; ndFixed = $false
    # 录制
    recFormat = 'mp4'; recTimeLimit = 0; recBackground = $false
    # 通用
    liveStatus = $true; autoConnect = $true; disconnectOnClose = $false; extraArgs = ''; lastWirelessAddr = ''; defaultDevice = ''
    # 自定义 adb / scrcpy 可执行文件路径（留空=用本助手同目录自带的）；在「设置 > 通用」里改，随设置存进 JSON
    scrcpyPath = ''; adbPath = ''
    # 记住主窗口位置（-1 = 还没记，居中显示）
    winX = -1; winY = -1
}
$settings = [ordered]@{}
foreach ($k in $defaults.Keys) { $settings[$k] = $defaults[$k] }

function Load-Settings {
    if (-not (Test-Path -LiteralPath $cfgPath)) { return }
    try {
        $j = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @($settings.Keys)) {
            if ($null -ne $j.$k) {
                if ($settings[$k] -is [bool]) { $settings[$k] = [bool]$j.$k }
                elseif ($settings[$k] -is [int]) { $settings[$k] = [int]$j.$k }
                else { $settings[$k] = [string]$j.$k }
            }
        }
        # 自定义常用 App 也存在同一个设置文件里：customApps 是个「名称=>包名」对象，不走上面的类型转换
        if ($j.customApps) {
            foreach ($p in $j.customApps.PSObject.Properties) {
                if ($p.Name -and $p.Value) { $script:customApps[[string]$p.Name] = [string]$p.Value }
            }
        }
        # 记住的无线设备同理：knownDevices 是「地址=>备注名」对象
        if ($j.knownDevices) {
            foreach ($p in $j.knownDevices.PSObject.Properties) {
                if ($p.Name -and $p.Value) { $script:knownDevices[[string]$p.Name] = [string]$p.Value }
            }
        }
        # 自定义显示名：deviceNames 是「序列号/地址=>名称」对象
        if ($j.deviceNames) {
            foreach ($p in $j.deviceNames.PSObject.Properties) {
                if ($p.Name -and $p.Value) { $script:deviceNames[[string]$p.Name] = [string]$p.Value }
            }
        }
        # 不自动连接名单：autoConnectExclude 是地址数组
        if ($j.autoConnectExclude) {
            foreach ($a in @($j.autoConnectExclude)) { if ($a) { [void]$script:autoConnectExclude.Add([string]$a) } }
        }
        # 摄像头尺寸记忆：camResByDevice 是「序列号|前后 => 尺寸」对象
        if ($j.camResByDevice) {
            foreach ($p in $j.camResByDevice.PSObject.Properties) {
                if ($p.Name -and $p.Value) { $script:camResByDevice[[string]$p.Name] = [string]$p.Value }
            }
        }
    } catch { }
}

# 把 JSON 重排成规整的 2 空格缩进（Windows PowerShell 5.1 的 ConvertTo-Json 缩进很丑：值对齐在键后、
# 嵌套对象缩进错位）。逐字符扫描、识别字符串（含转义），字符串里的 {}[]:," 原样保留、不当结构符处理。
function Format-Json {
    param([string]$Json)
    $sb = New-Object System.Text.StringBuilder
    $indent = 0; $inStr = $false; $esc = $false
    foreach ($c in $Json.ToCharArray()) {
        if ($inStr) {
            [void]$sb.Append($c)
            if ($esc) { $esc = $false }
            elseif ($c -eq '\') { $esc = $true }
            elseif ($c -eq '"') { $inStr = $false }
            continue
        }
        switch ($c) {
            '"' { $inStr = $true; [void]$sb.Append($c) }
            '{' { [void]$sb.Append($c); $indent++; [void]$sb.Append("`r`n" + ('  ' * $indent)) }
            '[' { [void]$sb.Append($c); $indent++; [void]$sb.Append("`r`n" + ('  ' * $indent)) }
            '}' { $indent--; [void]$sb.Append("`r`n" + ('  ' * $indent) + $c) }
            ']' { $indent--; [void]$sb.Append("`r`n" + ('  ' * $indent) + $c) }
            ',' { [void]$sb.Append($c); [void]$sb.Append("`r`n" + ('  ' * $indent)) }
            ':' { [void]$sb.Append(': ') }
            default { if ($c -notmatch '\s') { [void]$sb.Append($c) } }
        }
    }
    $lines = $sb.ToString() -split "`r?`n" | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -ne '' }
    return ($lines -join "`r`n")
}

function Save-Settings {
    try {
        $o = [ordered]@{}
        foreach ($k in $settings.Keys) { $o[$k] = $settings[$k] }
        $ca = [ordered]@{}
        foreach ($k in $script:customApps.Keys) { $ca[$k] = $script:customApps[$k] }
        $o['customApps'] = $ca
        $kd = [ordered]@{}
        foreach ($k in $script:knownDevices.Keys) { $kd[$k] = $script:knownDevices[$k] }
        $o['knownDevices'] = $kd
        $dn = [ordered]@{}
        foreach ($k in $script:deviceNames.Keys) { $dn[$k] = $script:deviceNames[$k] }
        $o['deviceNames'] = $dn
        $o['autoConnectExclude'] = @($script:autoConnectExclude)
        $cr = [ordered]@{}
        foreach ($k in $script:camResByDevice.Keys) { $cr[$k] = $script:camResByDevice[$k] }
        $o['camResByDevice'] = $cr
        # 原子写：先写临时文件再替换，避免写到一半崩溃/断电把设置文件截断——那会让 Load-Settings 解析失败、
        # 静默回退默认值，用户记住的设备/常用 App/备注名全丢。崩在临时文件上则原文件完好，下次照常读。
        $tmp = "$cfgPath.tmp"
        (Format-Json ($o | ConvertTo-Json -Depth 5)) | Set-Content -LiteralPath $tmp -Encoding UTF8
        if (Test-Path -LiteralPath $cfgPath) { [System.IO.File]::Replace($tmp, $cfgPath, [NullString]::Value) }   # 原子替换（第三参给 $null 会被当空路径报错，须用 [NullString]::Value）
        else { Move-Item -LiteralPath $tmp -Destination $cfgPath -Force }
    } catch { }
}

# 「不自动连接」名单的查询/切换：仅对无线地址有意义；改动即时存盘。
function Test-AutoConnectExcluded { param($addr) return ([bool]($addr -and ($script:autoConnectExclude -contains $addr))) }
function Set-AutoConnectExcluded {
    param($addr, [bool]$Excluded)
    if (-not $addr) { return }
    $has = $script:autoConnectExclude -contains $addr
    if ($Excluded -and -not $has) { [void]$script:autoConnectExclude.Add([string]$addr); Save-Settings }
    elseif ((-not $Excluded) -and $has) { [void]$script:autoConnectExclude.Remove([string]$addr); Save-Settings }
}

# 解析 adb / scrcpy 可执行文件的最终路径：优先用「设置 > 通用」里自定义、且文件确实存在的路径，否则回退到本助手同目录自带的。
# 保存设置时也会再调一次（$script:exe/$adb 即时更新，无需重启）。scrcpy 自身会去找 adb，这里顺带把环境变量 ADB 指到同一个 adb，
# 让 scrcpy 和本助手用的是同一个 adb（仅在该 adb 确实存在时才设，避免指向不存在路径反而让 scrcpy 找不到 adb）。
function Resolve-Tools {
    $script:exe = if ($settings.scrcpyPath -and (Test-Path -LiteralPath $settings.scrcpyPath)) { $settings.scrcpyPath } else { Join-Path $PSScriptRoot 'scrcpy.exe' }
    # adb 解析优先级：① 自定义 adbPath 且存在 → 用它；② 否则用「解析出的 scrcpy.exe 同目录里的 adb.exe」
    #（scrcpy 发行包本就把 adb.exe 放在 scrcpy.exe 旁边——这样只设 scrcpy、adb 留空时，也会自动配对到那个 scrcpy 对应的 adb，
    #  而不是回退到本助手自带的、可能与自定义 scrcpy 版本不一致的 adb，避免二者 adb 版本打架）；③ 都没有 → 回退本助手同目录自带的。
    if ($settings.adbPath -and (Test-Path -LiteralPath $settings.adbPath)) {
        $script:adb = $settings.adbPath
    } else {
        $sibling = Join-Path (Split-Path -Parent $script:exe) 'adb.exe'
        $script:adb = if (Test-Path -LiteralPath $sibling) { $sibling } else { Join-Path $PSScriptRoot 'adb.exe' }
    }
    if (Test-Path -LiteralPath $script:adb) { $env:ADB = $script:adb }
}

Load-Settings
Resolve-Tools

# 找不到 scrcpy.exe 时不直接退出——否则若有人删了自带的、又从没设过自定义路径，就永远够不到「设置」去指定它。
# 改为当场让用户选一次 scrcpy.exe 的位置：选了有效的就存进设置、重解析后继续进入助手；没选/取消才退出。
if (-not (Test-Path -LiteralPath $exe)) {
    $msg = "没找到 scrcpy.exe。`n`n正常情况下它应和本程序放在同一个文件夹里。`n如果你想用电脑里别处的 scrcpy，可点「是」现在选择它的位置。`n（选好后会记住，下次直接用；也可随时在「设置 > 通用」里改。）"
    if ([System.Windows.Forms.MessageBox]::Show($msg, 'scrcpy 投屏助手', 'YesNo', 'Warning') -eq 'Yes') {
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = 'scrcpy.exe|scrcpy.exe|可执行文件 (*.exe)|*.exe|所有文件 (*.*)|*.*'
        $ofd.Title = '选择 scrcpy.exe'
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $settings.scrcpyPath = $ofd.FileName; Save-Settings; Resolve-Tools
        }
    }
    if (-not (Test-Path -LiteralPath $exe)) {   # 仍然没有（没选/取消）→ 才退出
        [System.Windows.Forms.MessageBox]::Show("仍未找到 scrcpy.exe，助手退出。`n可把 scrcpy.exe 放到本程序同一文件夹，或重开后按提示选择它的位置。", 'scrcpy 投屏助手') | Out-Null
        return
    }
}

# ---------------- 参数拼接 ----------------
function Get-VideoArgs {
    $a = @()
    if ([int]$settings.maxSize -gt 0) { $a += @('-m', "$($settings.maxSize)") }
    if ([int]$settings.maxFps  -gt 0) { $a += "--max-fps=$($settings.maxFps)" }
    if ([int]$settings.bitRate -gt 0) { $a += "--video-bit-rate=$($settings.bitRate)M" }
    if ($settings.videoCodec)         { $a += "--video-codec=$($settings.videoCodec)" }
    if ($settings.crop)               { $a += "--crop=$($settings.crop)" }
    return $a
}
function Get-AudioArgs {
    if (-not $settings.audioOn) { return @('--no-audio') }
    $a = @()
    if ($settings.audioSource) { $a += "--audio-source=$($settings.audioSource)" }
    if ($settings.audioCodec)  { $a += "--audio-codec=$($settings.audioCodec)" }
    return $a
}
function Get-ControlArgs {
    param([bool]$Wireless)
    $a = @()
    if ($settings.keyboard)    { $a += "--keyboard=$($settings.keyboard)" }
    if ($settings.mouse)       { $a += "--mouse=$($settings.mouse)" }
    if ($settings.gamepad)     { $a += '--gamepad=uhid' }
    if ($settings.noControl)   { $a += '--no-control' }
    if ($settings.screenOff)   { $a += '--turn-screen-off' }
    if ($settings.showTouches) { $a += '--show-touches' }
    if ($settings.stayAwake)   { $a += $(if ($Wireless) { '--keep-active' } else { '-w' }) }
    if ($settings.powerOffOnClose) { $a += '--power-off-on-close' }
    return $a
}
function Get-WindowArgs {
    $a = @()
    if ($settings.fullscreen) { $a += '-f' }
    if ($settings.onTop)      { $a += '--always-on-top' }
    if ($settings.borderless) { $a += '--window-borderless' }
    return $a
}
function Get-MirrorArgs {
    param([bool]$Wireless)
    return (Get-VideoArgs) + (Get-AudioArgs) + (Get-ControlArgs -Wireless:$Wireless) + (Get-WindowArgs)
}
function Get-NewDisplayArgs {
    param($sz = $settings.ndSize, $dpi = $settings.ndDpi, [bool]$fixed = $settings.ndFixed, [bool]$noDecor = $settings.ndNoDecor)
    $nd = if ($sz -and $dpi) { "--new-display=$sz/$dpi" } elseif ($sz) { "--new-display=$sz" } elseif ($dpi) { "--new-display=/$dpi" } else { '--new-display' }
    $a = @($nd)
    # 固定方向时不加 --flex-display：虚拟屏不再跟着窗口尺寸变，避免最大化/全屏时画面循环自转。
    if (-not $fixed) { $a += '--flex-display' }
    if ($noDecor) { $a += '--no-vd-system-decorations' }
    return $a
}
# 按虚拟屏(WxH)比例算出一个塞进电脑屏幕可用区的「窗口大小」（--window-width/height），
# 让竖屏窗口不超出屏幕被切。虚拟屏分辨率保持真实（比例、密度都对，App 不拉伸），只缩窗口。
# 注意：--window-width/height 与 --flex-display 冲突（scrcpy 会报错禁用），故用它时必须不加 --flex-display。
# 尺寸未知（非 WxH）或放得下时返回 @() —— 交给 scrcpy 默认，不强行定窗口。
function Get-FitWindowArgs {
    param([string]$sizeWxH)
    if ($sizeWxH -notmatch '^(\d+)x(\d+)$') { return @() }
    $vw = [int]$matches[1]; $vh = [int]$matches[2]
    if ($vw -le 0 -or $vh -le 0) { return @() }
    try { $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea } catch { return @() }
    $maxW = $wa.Width * 0.92; $maxH = $wa.Height * 0.92
    if ($vw -le $maxW -and $vh -le $maxH) { return @() }   # 本就放得下：不必定窗口
    $winW = $maxW; $winH = [math]::Round($winW * $vh / $vw)
    if ($winH -gt $maxH) { $winH = $maxH; $winW = [math]::Round($winH * $vw / $vh) }
    $winW = [int]$winW; $winH = [int]$winH
    if ($winW -le 0 -or $winH -le 0) { return @() }
    return @("--window-width=$winW", "--window-height=$winH")
}
# 运行 scrcpy --list-camera-sizes，按朝向解析出本机真正支持的采集分辨率。
# 不同机型差别很大，写死 1080p 之类会触发 “Camera configuration error”（录像支持 ≠ 投屏采集支持），
# 所以运行时按设备实拉，让用户只在“一定能开”的尺寸里选。任何失败都返回空表，调用方自行回退到通用档位。
# 摄像头采集尺寸记忆：按「序列号|前后」分记，读不到该设备该朝向的记录时回退到全局 camResMax。
function Get-CamRemembered {
    param($serial, $facing)
    $k = "$serial|$facing"
    if ($script:camResByDevice.Contains($k)) { return [string]$script:camResByDevice[$k] }
    return [string]$settings.camResMax
}
function Set-CamRemembered {
    param($serial, $facing, $val)
    if ($serial) { $script:camResByDevice["$serial|$facing"] = [string]$val }   # 按设备+前后分记
    $settings.camResMax = [string]$val                                          # 同时更新全局默认（换设备时的回退值）
}

function Get-CameraSizes {
    param([string]$serial)
    if ($serial -and $script:camSizesCache.ContainsKey($serial)) { return $script:camSizesCache[$serial] }   # 同一台设备本会话缓存
    $result = @{ back = @(); front = @() }
    try {
        $argv = @(); if ($serial) { $argv += @('-s', $serial) }; $argv += '--list-camera-sizes'
        $out = (Invoke-Hidden -FilePath $exe -ArgumentList $argv) -join "`n"
    } catch { return $result }
    if (-not $out) { return $result }
    $facing = $null
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -match '--camera-id=\d') {
            # 摄像头分组头，如：--camera-id=0  (back, 4000x3000, fps=[...])；括号内 WxH 是传感器最大值，不计为可选项
            if     ($line -match '\bfront\b')    { $facing = 'front' }
            elseif ($line -match '\bback\b')     { $facing = 'back' }
            elseif ($line -match '\bexternal\b') { $facing = 'back' }
            else   { $facing = $null }
            continue
        }
        if ($facing -and $line -match '(\d{3,5})x(\d{3,5})') {
            $size = "$($Matches[1])x$($Matches[2])"
            if ($result[$facing] -notcontains $size) { $result[$facing] += $size }
        }
    }
    foreach ($f in @('back', 'front')) {
        $result[$f] = @($result[$f] | Sort-Object -Property @{ Expression = { [int]($_ -split 'x')[0] * [int]($_ -split 'x')[1] } } -Descending)
    }
    if ($serial -and ((@($result.back).Count + @($result.front).Count) -gt 0)) { $script:camSizesCache[$serial] = $result }   # 只缓存成功（非空）结果
    return $result
}

# 读设备真实分辨率与密度（adb shell wm size / wm density），供「独立窗口·手机版面」用真实尺寸而非写死值。
# 优先 Override（当前生效）再 Physical；按设备会话缓存（同一台只读一次）；读不到返回 $null 由调用方兜底。
$script:devDisplayCache = @{}
function Get-DeviceDisplay {
    param($serial)
    if (-not $serial) { return $null }
    if ($script:devDisplayCache.ContainsKey($serial)) { return $script:devDisplayCache[$serial] }
    $res = $null
    try {
        $szArgs = @(); if ($serial) { $szArgs += @('-s', $serial) }; $szArgs += @('shell', 'wm', 'size')
        $dnArgs = @(); if ($serial) { $dnArgs += @('-s', $serial) }; $dnArgs += @('shell', 'wm', 'density')
        $szOut = (Invoke-Hidden -FilePath $adb -ArgumentList $szArgs -DiscardStderr) -join "`n"
        $dnOut = (Invoke-Hidden -FilePath $adb -ArgumentList $dnArgs -DiscardStderr) -join "`n"
        $w = 0; $h = 0; $dpi = 0
        if     ($szOut -match 'Override size:\s*(\d+)x(\d+)') { $w = [int]$matches[1]; $h = [int]$matches[2] }
        elseif ($szOut -match 'Physical size:\s*(\d+)x(\d+)') { $w = [int]$matches[1]; $h = [int]$matches[2] }
        if     ($dnOut -match 'Override density:\s*(\d+)') { $dpi = [int]$matches[1] }
        elseif ($dnOut -match 'Physical density:\s*(\d+)') { $dpi = [int]$matches[1] }
        if ($w -gt 0 -and $h -gt 0) { $res = @{ W = $w; H = $h; Dpi = $dpi } }
    } catch {}
    if ($res) { $script:devDisplayCache[$serial] = $res }   # 只缓存成功结果，失败下次可重试
    return $res
}

# 启动 scrcpy（不阻塞界面；自动过滤空参数）
function Start-Scrcpy {
    param([string[]]$Options, [switch]$Recording)
    $extra = @(); if ($settings.extraArgs) { $extra = @($settings.extraArgs -split '\s+' | Where-Object { $_ }) }
    $clean = @(($Options + $extra) | Where-Object { $_ -ne '' -and $null -ne $_ })
    # 解析目标设备序列号（来自 -s），用于「投屏中」标记 / 「停止这台」，并据此给窗口起友好标题
    $serial = ''
    for ($i = 0; $i -lt $clean.Count - 1; $i++) { if ($clean[$i] -eq '-s') { $serial = $clean[$i + 1]; break } }
    if ($serial -and -not @($clean | Where-Object { $_ -like '--window-title=*' }).Count) {
        # 标题去空格（Windows PowerShell 的 Start-Process 数组传参对带空格的参数引号处理不可靠）
        $title = (Get-FriendlyName $serial) -replace '\s+', '-'
        if ($title) { $clean += "--window-title=$title" }
    }
    # Start-Process 数组传参不会给「含空格的参数」加引号——会把录屏路径 C:\My Videos\x.mp4 拆成多段、
    # 让 scrcpy 收到的 -r 路径残缺、录屏失败。这里自己给含空格/引号的参数补引号，整体作为命令行串传。
    $cmd = (@($clean | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')
    $p = if ($cmd) { Start-Process -FilePath $exe -ArgumentList $cmd -WorkingDirectory $PSScriptRoot -PassThru }
    else { Start-Process -FilePath $exe -WorkingDirectory $PSScriptRoot -PassThru }
    if ($p) { [void]$scrcpyProcs.Add([pscustomobject]@{ Proc = $p; Rec = [bool]$Recording; Serial = $serial }) }
}

# 是否有正在进行的录屏（关助手时据此决定要不要提醒）
function Test-Recording {
    foreach ($it in @($scrcpyProcs)) {
        if ($it.Rec -and $it.Proc -and -not $it.Proc.HasExited) { return $true }
    }
    return $false
}
# 优雅停止一个 scrcpy：给它的控制台发 Ctrl+C，让 scrcpy 正常收尾（录制时写好文件尾原子，否则 mp4 会损坏、打不开）。
# 无窗口的「后台录制」没有窗口可关，只能靠这个信号。做法（Windows 标准套路）：先让本进程忽略 Ctrl+C（护住自己）→
# 脱离自己的控制台 FreeConsole → AttachConsole 挂到目标进程的控制台 → 广播 CTRL_C_EVENT（只会打到该控制台里的 scrcpy）→
# 等它退出 → FreeConsole 脱离 → 恢复自己的 Ctrl+C 处理。任何失败/超时都返回 $false，交调用方强杀兜底（退回原行为，无回归）。
function Stop-ScrcpyGraceful {
    param($proc, [int]$WaitMs = 5000)
    if (-not $proc -or $proc.HasExited) { return $true }
    $ok = $false
    try {
        [void][Native.ConIO]::SetConsoleCtrlHandler([System.IntPtr]::Zero, $true)   # 先护住自己：忽略即将广播的 Ctrl+C
        [void][Native.ConIO]::FreeConsole()
        if ([Native.ConIO]::AttachConsole([uint32]$proc.Id)) {
            [void][Native.ConIO]::GenerateConsoleCtrlEvent(0, 0)   # 0 = CTRL_C_EVENT；进程组 0 = 本控制台所有进程（即 scrcpy）
            $ok = $proc.WaitForExit($WaitMs)
            [void][Native.ConIO]::FreeConsole()
        }
    } catch { $ok = $false }
    try { [void][Native.ConIO]::SetConsoleCtrlHandler([System.IntPtr]::Zero, $false) } catch {}   # 恢复自己的 Ctrl+C 处理
    return $ok
}
# 停止本助手启动的所有投屏：录制中的先发 Ctrl+C 优雅收尾（保住文件），再对其余优雅关窗，最后关不掉的强杀兜底
function Stop-AllScrcpy {
    foreach ($it in @($scrcpyProcs)) {   # 录制进程优先优雅停：后台录制无窗口，只能靠 Ctrl+C 收尾，否则强杀会损坏视频
        if ($it.Rec -and $it.Proc -and -not $it.Proc.HasExited) { [void](Stop-ScrcpyGraceful $it.Proc) }
    }
    foreach ($it in @($scrcpyProcs)) {
        try { if ($it.Proc -and -not $it.Proc.HasExited) { [void]$it.Proc.CloseMainWindow() } } catch {}
    }
    Start-Sleep -Milliseconds 500
    foreach ($it in @($scrcpyProcs)) {
        try { if ($it.Proc -and -not $it.Proc.HasExited) { $it.Proc.Kill() } } catch {}
    }
    $scrcpyProcs.Clear()
}
# 当前正在投屏的设备序列号列表（进程还活着的）——「设备管理」据此标「▶ 投屏中」
function Get-ActiveSerials {
    $res = @()
    foreach ($it in @($scrcpyProcs)) {
        if ($it.Serial -and $it.Proc -and -not $it.Proc.HasExited) { $res += $it.Serial }
    }
    return $res
}
# 只停某一台设备的投屏（不影响其它台）：先优雅关窗，关不掉再强杀，最后清理该设备的已结束记录
function Stop-DeviceScrcpy {
    param($serial)
    if (-not $serial) { return }
    foreach ($it in @($scrcpyProcs)) {   # 这台的录制进程先发 Ctrl+C 优雅收尾（后台录制无窗口，强杀会损坏视频）
        if ($it.Serial -eq $serial -and $it.Rec -and $it.Proc -and -not $it.Proc.HasExited) { [void](Stop-ScrcpyGraceful $it.Proc) }
    }
    foreach ($it in @($scrcpyProcs)) {
        if ($it.Serial -eq $serial -and $it.Proc -and -not $it.Proc.HasExited) { try { [void]$it.Proc.CloseMainWindow() } catch {} }
    }
    Start-Sleep -Milliseconds 300
    foreach ($it in @($scrcpyProcs)) {
        if ($it.Serial -eq $serial -and $it.Proc -and -not $it.Proc.HasExited) { try { $it.Proc.Kill() } catch {} }
    }
    $live = @($scrcpyProcs | Where-Object { $_.Serial -ne $serial -or ($_.Proc -and -not $_.Proc.HasExited) })
    $scrcpyProcs.Clear(); foreach ($x in $live) { [void]$scrcpyProcs.Add($x) }
}

# 读取已连接设备序列号列表（state=device）
function Get-DeviceList {
    try {
        $out = Invoke-Hidden -FilePath $adb -ArgumentList @('devices') -DiscardStderr
        $lines = $out | Select-Object -Skip 1 | Where-Object { $_ -match "`tdevice$" }
        return @($lines | ForEach-Object { ($_ -split "`t")[0] })
    } catch { return @() }
}
# 是否为无线地址（ip:port）
function Test-Wireless { param($s) return ($s -match '^\d{1,3}(\.\d{1,3}){3}:') }

# 设备信息（安卓大版本 + 型号），按序列号缓存：同一台只读一次 adb，状态栏显示和版本门控共用
$script:devInfo = @{}
function Get-DevInfo {
    param($serial)
    if (-not $serial) { return @{ Ver = 0; Text = '' } }
    if ($script:devInfo.ContainsKey($serial)) { return $script:devInfo[$serial] }
    $ver = 0; $txt = ''
    try {
        $vraw  = ((Invoke-Hidden -FilePath $adb -ArgumentList @('-s', $serial, 'shell', 'getprop', 'ro.build.version.release') -DiscardStderr | Select-Object -First 1) | Out-String).Trim()
        $model = ((Invoke-Hidden -FilePath $adb -ArgumentList @('-s', $serial, 'shell', 'getprop', 'ro.product.model') -DiscardStderr | Select-Object -First 1) | Out-String).Trim()
        if ($vraw -match '^(\d+)') { $ver = [int]$matches[1] }
        if ($vraw)  { $txt = "Android $vraw" }
        if ($model) { $txt = if ($txt) { "$txt · $model" } else { $model } }
    } catch {}
    $info = @{ Ver = $ver; Text = $txt }
    $script:devInfo[$serial] = $info
    return $info
}

# 小工具：建标签
function New-Lbl {
    param($text, $x, $y)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.AutoSize = $true; $l.Location = New-Object System.Drawing.Point($x, $y)
    return $l
}
# 素纸灰小字说明（8.5 号、自适应宽度）：按钮下方 / 弹窗里的次要提示
function New-Caption {
    param($text, $x, $y)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.AutoSize = $true; $l.ForeColor = $cMuted
    $l.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
    $l.Location = New-Object System.Drawing.Point($x, $y)
    return $l
}
# 小工具：建下拉（DropDownList），按当前值预选
function New-Combo {
    param($labels, $values, $current, $x, $y, $w)
    $c = New-Object System.Windows.Forms.ComboBox
    $c.DropDownStyle = 'DropDownList'
    $c.Location = New-Object System.Drawing.Point($x, $y)
    $c.Size = New-Object System.Drawing.Size($w, 26)
    $labels | ForEach-Object { [void]$c.Items.Add($_) }
    $i = [array]::IndexOf($values, $current); if ($i -lt 0) { $i = 0 }
    $c.SelectedIndex = $i
    $c | Add-Member -NotePropertyName Vals -NotePropertyValue $values
    return $c
}
function New-Nud {
    param($val, $min, $max, $step, $x, $y)
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Minimum = $min; $n.Maximum = $max; $n.Increment = $step
    $v = [int]$val; if ($v -lt $min) { $v = $min }; if ($v -gt $max) { $v = $max }
    $n.Value = [decimal]$v
    $n.Location = New-Object System.Drawing.Point($x, $y); $n.Size = New-Object System.Drawing.Size(90, 26)
    return $n
}
function New-Chk {
    param($text, $checked, $x, $y)
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $text; $c.Checked = [bool]$checked; $c.AutoSize = $true
    $c.Location = New-Object System.Drawing.Point($x, $y)
    return $c
}
# 主操作按钮（朱砂实心）
function New-PrimaryBtn {
    param($text, $x, $y, $w, $h, $fontSize = 13)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $cInk; $b.ForeColor = $cWhite
    $b.FlatAppearance.MouseOverBackColor = $cInkDark
    $b.FlatAppearance.MouseDownBackColor = $cInkDark
    $b.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', $fontSize, [System.Drawing.FontStyle]::Bold)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $b
}
# 次要操作按钮（描边）
function New-SecondaryBtn {
    param($text, $x, $y, $w, $h)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 1; $b.FlatAppearance.BorderColor = $cLine
    $b.BackColor = $cWhite; $b.ForeColor = $cInk
    $b.FlatAppearance.MouseOverBackColor = $cHover
    $b.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $b
}
# 文字链接按钮（设置/刷新）
function New-LinkBtn {
    param($text, $x, $y, $w)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($w, 26)
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $cPaper; $b.ForeColor = $cMuted
    $b.FlatAppearance.MouseOverBackColor = $cLine
    $b.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $b
}
# 把控件裁成圆角（用于连接状态药丸）
function Set-Rounded {
    param($ctl, $radius)
    $applyRegion = {
        param($c, $r)
        $d = [Math]::Max(2, [int]$r * 2)
        if ($d -ge $c.Width) { $d = $c.Width - 1 }
        if ($d -ge $c.Height) { $d = $c.Height - 1 }
        if ($d -lt 2 -or $c.Width -lt 2 -or $c.Height -lt 2) { return }
        $p = New-Object System.Drawing.Drawing2D.GraphicsPath
        $p.AddArc(0, 0, $d, $d, 180, 90)
        $p.AddArc($c.Width - $d - 1, 0, $d, $d, 270, 90)
        $p.AddArc($c.Width - $d - 1, $c.Height - $d - 1, $d, $d, 0, 90)
        $p.AddArc(0, $c.Height - $d - 1, $d, $d, 90, 90)
        $p.CloseAllFigures()
        $c.Region = New-Object System.Drawing.Region($p)
    }
    $origH = if ($ctl.Height -gt 0) { $ctl.Height } else { $radius * 2 }
    & $applyRegion $ctl $radius
    # 高 DPI：Control.Scale 会放大控件尺寸但不会重算 Region（圆角裁剪区），会导致药丸只显示原始小尺寸的一块。
    # 改为随尺寸变化（含 Scale 之后）重算 Region，并按高度比例放大圆角半径，保持药丸形状。
    $ctl.Add_SizeChanged({
        $c = $args[0]
        $r = [int][Math]::Round($radius * $c.Height / $origH)
        & $applyRegion $c $r
    }.GetNewClosure())
}

# ---------------- 设置窗口（分页） ----------------
# 窗口/任务栏图标：朱砂印·投屏（墨黑印章 + 素纸屏幕 + 朱砂手机），与界面同源配色。
# 图标以 base64 内嵌，确保「复制三个文件」打包后仍自带图标，无需附带 .ico 文件。
$script:AppIcon = $null
function Get-AppIcon {
    if ($script:AppIcon) { return $script:AppIcon }
    $b64 = @'
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
'@
    try {
        $bytes = [Convert]::FromBase64String(($b64 -replace '\s', ''))
        $ms = New-Object System.IO.MemoryStream(,$bytes)
        $script:AppIcon = New-Object System.Drawing.Icon($ms)
    } catch { $script:AppIcon = $null }
    return $script:AppIcon
}

# 高 DPI 清晰化：让窗体在高分屏上按真实缩放比等比放大，既清晰又不发小。
# 为何手动做而不用 AutoScaleMode=Dpi：.NET Framework 的 WinForms 自动 DPI 缩放被 app.config
# （EnableWindowsFormsHighDpiAutoResizing / DpiAwareness）门控，而本脚本跑在 powershell 宿主里、无法提供 app.config，
# 于是 AutoScaleMode 取不到真实 DPI（Control.DeviceDpi 恒为 96），窗体不会放大 → 在 150% 屏上清晰但偏小。
# 改为：进程已声明 DPI 感知（见开头），窗体 Load 时用 Win32 GetDpiForWindow 读到真实 DPI（如 144），
# 按 DPI/96 用 Control.Scale 一次性等比放大所有控件的坐标与尺寸。字体是磅值、在高 DPI 下由 GDI 自动放大，
# 而 Scale 不改磅值 → 坐标与字体同比放大、不会二次放大。任何异常都吞掉、绝不阻断窗口显示。
# Control.Scale 会放大 ListView 控件本身、但不缩放它的「列宽」（WinForms 已知短板）——
# 高 DPI 下列宽保持 96DPI 的像素值 → 字大了却挤在窄列里被截断、右侧留空。递归找出所有 ListView 按同一比例补缩列宽。
function Update-ListViewColumnWidths {
    param($ctrl, $factor)
    foreach ($child in $ctrl.Controls) {
        if ($child -is [System.Windows.Forms.ListView]) {
            foreach ($col in $child.Columns) { $col.Width = [int][Math]::Round($col.Width * $factor) }
        }
        if ($child.Controls.Count -gt 0) { Update-ListViewColumnWidths $child $factor }
    }
}

function Set-DpiScale {
    param($form)
    $form.AutoScaleMode = 'None'   # 关掉 WinForms 自带缩放（此处拿不到真实 DPI，且会与手动 Scale 冲突）
    $form.Add_Load({
        try {
            $f = $args[0]
            $dpi = 0
            try { $dpi = [Native.Dpi]::GetDpiForWindow($f.Handle) } catch {}          # Win10 1607+
            if ($dpi -le 0) {                                                          # 兜底：取桌面 DC 的系统 DPI
                try { $dc = [Native.Dpi]::GetDC([System.IntPtr]::Zero); $dpi = [Native.Dpi]::GetDeviceCaps($dc, 88); [void][Native.Dpi]::ReleaseDC([System.IntPtr]::Zero, $dc) } catch {}
            }
            if ($dpi -le 0) { $dpi = 96 }
            $fac = $dpi / 96.0
            if ($fac -gt 1.01) {
                $f.Scale([System.Drawing.SizeF]::new($fac, $fac))
                Update-ListViewColumnWidths $f $fac   # Scale 不管列宽，这里按同一比例补上
            }
        } catch {}
    })
}

# 统一风格的弹窗：标题/尺寸/居中父窗/固定边框/字体/底色一处定义，各弹窗共用
function New-Dialog {
    param($title, $w, $h, $owner)
    $d = New-Object System.Windows.Forms.Form
    Set-DpiScale $d   # 高 DPI 清晰化：Load 时按真实 DPI 等比放大
    $d.Text = $title; $d.ClientSize = New-Object System.Drawing.Size($w, $h)
    $d.Icon = Get-AppIcon
    $d.FormBorderStyle = 'FixedDialog'
    $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.Font = $owner.Font; $d.BackColor = $cPaper
    # 不遮挡父窗口：弹窗放到父窗口右侧（放不下就放左侧），顶部对齐；都放不下才退回居中。最后夹到屏幕工作区内。
    try {
        $gap = 12
        $sa = [System.Windows.Forms.Screen]::FromControl($owner).WorkingArea
        $ob = $owner.Bounds
        $dw = $d.Width; $dh = $d.Height
        $x = $ob.Right + $gap
        if (($x + $dw) -gt $sa.Right) { $x = $ob.Left - $gap - $dw }     # 右侧放不下 → 左侧
        if ($x -lt $sa.Left -or ($x + $dw) -gt $sa.Right) {              # 两侧都放不下 → 居中于父窗
            $x = $ob.Left + [int](($ob.Width - $dw) / 2)
        }
        $y = $ob.Top
        if ($x -lt $sa.Left) { $x = $sa.Left }
        if (($x + $dw) -gt $sa.Right) { $x = $sa.Right - $dw }
        if ($y -lt $sa.Top) { $y = $sa.Top }
        if (($y + $dh) -gt $sa.Bottom) { $y = $sa.Bottom - $dh }
        $d.StartPosition = 'Manual'
        $d.Location = New-Object System.Drawing.Point($x, $y)
    } catch { $d.StartPosition = 'CenterParent' }
    return $d
}

function Show-Settings {
    param($owner)
    $dlg = New-Dialog '设置' 570 340 $owner
    $tt = New-Object System.Windows.Forms.ToolTip
    $tt.AutoPopDelay = 12000

    # 左侧分类导轨（取代横排标签页）：选中项＝朱砂竖条 + 墨黑粗体（呼应主界面品牌竖条），未选＝素纸灰。
    # 右侧是对应的设置面板，按选中项切换显示。
    $nav = New-Object System.Windows.Forms.ListBox
    $nav.Location = New-Object System.Drawing.Point(14, 14)
    $nav.Size = New-Object System.Drawing.Size(110, 264)
    $nav.BorderStyle = 'None'; $nav.BackColor = $cPaper
    $nav.DrawMode = 'OwnerDrawFixed'; $nav.ItemHeight = 33; $nav.IntegralHeight = $false
    $nav.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5)
    $nav.Add_DrawItem({
        param($navSender, $e)
        if ($e.Index -lt 0) { return }
        $sel = ($e.Index -eq $nav.SelectedIndex)   # 按 SelectedIndex 判定，失焦也保持高亮
        $g = $e.Graphics; $r = $e.Bounds
        $bg = New-Object System.Drawing.SolidBrush($(if ($sel) { $cWhite } else { $cPaper }))
        $g.FillRectangle($bg, $r); $bg.Dispose()
        if ($sel) {
            $red = New-Object System.Drawing.SolidBrush($cRed)
            $g.FillRectangle($red, [int]$r.Left, [int]($r.Top + 7), 3, [int]($r.Height - 14)); $red.Dispose()
        }
        $fg = New-Object System.Drawing.SolidBrush($(if ($sel) { $cInk } else { $cMuted }))
        $f = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5, $(if ($sel) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }))
        $ty = $r.Top + ($r.Height - $f.GetHeight($g)) / 2
        $g.DrawString([string]$nav.Items[$e.Index], $f, $fg, [single]($r.Left + 16), [single]$ty)
        $fg.Dispose(); $f.Dispose()
    })
    $navDivider = New-Object System.Windows.Forms.Panel
    $navDivider.Size = New-Object System.Drawing.Size(1, 264); $navDivider.Location = New-Object System.Drawing.Point(131, 14); $navDivider.BackColor = $cLine

    # ===== 常用（把最常用 / 最重要的几项聚合在第一页） =====
    $tabCommon = New-Object System.Windows.Forms.Panel
    # 顺序按使用度：人人都调的清晰度/声音在前，只无线用户才碰的两项沉到最后
    $nudSize = New-Nud $settings.maxSize 0 4096 16 250 13
    $chkAudio = New-Chk '把手机声音也传到电脑' $settings.audioOn 14 46
    $chkStay = New-Chk '保持手机唤醒（避免锁屏 / 无线中途断开）' $settings.stayAwake 14 74
    $chkScreenOff = New-Chk '投屏时关闭手机屏幕（省电、防偷看）' $settings.screenOff 14 102
    $chkReconnect = New-Chk '自动连接记住的无线设备（启动连接附近设备 · 掉线自动重连）' $settings.autoConnect 14 130
    $chkDisconnect = New-Chk '关闭助手时断开无线连接（默认保持，重开即用）' $settings.disconnectOnClose 14 158
    $tt.SetToolTip($nudSize, '画面最大边长(像素)。数值越大越清晰、越小越流畅；0=原画不限制。')
    $tt.SetToolTip($chkAudio, '取消勾选则完全不传声音（等同 --no-audio）。')
    $tt.SetToolTip($chkStay, '保持手机不锁屏，避免无线投屏中途断开。想更省电可关掉，让手机自然休眠。')
    $tt.SetToolTip($chkScreenOff, '投屏时关掉手机屏幕，明显省电、还能防偷看（投屏照常进行）。无线投屏想省电首选它。')
    $tt.SetToolTip($chkReconnect, '记住最近一次的无线 IP，发现掉线就自动连回去，适合无线投屏中途断开。会略增耗电，按需开启。')
    $tt.SetToolTip($chkDisconnect, '不勾（默认）：关掉助手后仍保持手机连接，重开即用、几乎不耗电。勾上：关助手时一并断开无线连接，重开需重新连（可能要再插一次线）。')
    $tabCommon.Controls.AddRange(@(
        (New-Lbl '清晰度（越大越清晰，0=原画）' 14 16), $nudSize,
        $chkAudio, $chkStay, $chkScreenOff, $chkReconnect, $chkDisconnect))

    # ===== 画面 =====
    $tabVideo = New-Object System.Windows.Forms.Panel
    $nudFps  = New-Nud $settings.maxFps  0 240 5  250 16
    $nudBit  = New-Nud $settings.bitRate 0 50  1  250 52
    $cbVCodec = New-Combo @('默认（H.264，兼容最好）', 'H.265（更清晰）', 'AV1（更省流量）') @('', 'h265', 'av1') $settings.videoCodec 110 88 230
    $txtCrop = New-Object System.Windows.Forms.TextBox
    $txtCrop.Location = New-Object System.Drawing.Point(110, 120); $txtCrop.Size = New-Object System.Drawing.Size(230, 24)
    $txtCrop.Text = $settings.crop
    $tt.SetToolTip($nudFps, '每秒帧数上限。0=用默认；填 60 更顺滑、填 30 更省资源。')
    $tt.SetToolTip($nudBit, '视频码率(Mbps)。越高越清晰越占带宽；0=用默认(约 8M)。无线卡顿可调小。')
    $tt.SetToolTip($cbVCodec, 'H.265/AV1 同等清晰度更省带宽，但老机型/老电脑可能不支持，卡顿就换回 H.264。')
    $tt.SetToolTip($txtCrop, '只投屏幕的一块区域。格式 宽:高:左:上（像素），例如 1080:1080:0:300。留空=投整屏。')
    $tabVideo.Controls.AddRange(@(
        (New-Lbl '帧率（越高越流畅，0=默认）' 14 19), $nudFps,
        (New-Lbl '画质（越高越清晰，0=默认）' 14 55), $nudBit,
        (New-Lbl '视频编码：' 14 91), $cbVCodec,
        (New-Lbl '裁剪画面：' 14 123), $txtCrop,
        (New-Caption '宽:高:左:上，留空=投整屏。例 1080:1080:0:300' 14 150)))

    # ===== 声音 =====
    $tabAudio = New-Object System.Windows.Forms.Panel
    $cbASrc = New-Combo @('手机外放声音', '麦克风') @('', 'mic') $settings.audioSource 110 50 230
    $cbACodec = New-Combo @('默认（Opus）', 'AAC（兼容）', 'FLAC（无损）', '原始 PCM') @('', 'aac', 'flac', 'raw') $settings.audioCodec 110 88 230
    $lblAudioTip = New-Lbl '是否传声音，请到「常用」页开关。下面是进阶项：' 14 18; $lblAudioTip.ForeColor = $cMuted
    $tt.SetToolTip($cbASrc, '“手机外放声音”把手机正在播放的声音传到电脑；“麦克风”采集手机话筒，适合当摄像头/直播。')
    $tt.SetToolTip($cbACodec, '一般保持默认即可；个别播放器不出声时可改 AAC。')
    $tabAudio.Controls.AddRange(@(
        $lblAudioTip,
        (New-Lbl '声音来源：' 14 53), $cbASrc,
        (New-Lbl '音频编码：' 14 91), $cbACodec))

    # ===== 控制 =====
    $tabCtrl = New-Object System.Windows.Forms.Panel
    $cbKb = New-Combo @('默认（推荐，能打中文）', '游戏模式（更跟手，不能打中文）', 'USB 直连（特殊情况）') @('', 'uhid', 'aoa') $settings.keyboard 110 13 300
    $cbMouse = New-Combo @('默认（推荐）', '游戏模式（更跟手）', 'USB 直连（特殊情况）') @('', 'uhid', 'aoa') $settings.mouse 110 49 300
    # 顺序按使用度：键鼠模式在前，常用的「只投屏」「关窗息屏」次之，niche 的触摸点 / 手柄沉底
    $chkNoCtrl = New-Chk '只投屏，不允许控制手机' $settings.noControl 14 86
    $chkPowerOff = New-Chk '关闭投屏时顺手熄灭手机屏幕' $settings.powerOffOnClose 14 114
    $chkTouches = New-Chk '显示触摸点' $settings.showTouches 14 142
    $chkGamepad = New-Chk '启用手柄（把电脑手柄映射到手机）' $settings.gamepad 14 170
    $tt.SetToolTip($cbKb, '绝大多数人选「默认」即可，能正常用中文输入法。「游戏模式」让电脑键盘像真键盘一样直接控制游戏，但用不了中文输入法。')
    $tt.SetToolTip($chkNoCtrl, '只看画面、禁止鼠标键盘操作手机，适合演示/防误触。')
    $tt.SetToolTip($chkPowerOff, '结束投屏（关掉投屏窗口）时，顺手把手机屏幕熄灭，省电、防亮屏。')
    $tt.SetToolTip($chkGamepad, '把连在电脑上的游戏手柄映射给手机，适合手游。')
    $capKbCn = New-Caption "中文打不进投屏窗口？这是 scrcpy 与 Windows 输入法的已知限制：电脑输入法「组词」阶段的字 scrcpy 收不到。`n· 临时：电脑里复制好，再在投屏窗口按 Ctrl+V 粘贴。`n· 彻底：手机装「ADBKeyboard」设为当前输入法；或键盘模式选「游戏模式」，用手机自带输入法打拼音。" 14 200
    $tabCtrl.Controls.AddRange(@(
        (New-Lbl '键盘模式：' 14 16), $cbKb,
        (New-Lbl '鼠标模式：' 14 52), $cbMouse,
        $chkNoCtrl, $chkPowerOff, $chkTouches, $chkGamepad, $capKbCn))

    # ===== 窗口 =====
    $tabWin = New-Object System.Windows.Forms.Panel
    $chkFull = New-Chk '启动即全屏' $settings.fullscreen 14 18
    $chkTop = New-Chk '窗口总在最前' $settings.onTop 14 50
    $chkBorderless = New-Chk '无边框窗口' $settings.borderless 14 82
    $tt.SetToolTip($chkTop, '投屏窗口始终浮在其它窗口上方，边看手机边操作电脑很方便。')
    $tabWin.Controls.AddRange(@($chkFull, $chkTop, $chkBorderless))

    # ===== 独立窗口 =====
    $tabNd = New-Object System.Windows.Forms.Panel
    $cbNdSize = New-Object System.Windows.Forms.ComboBox
    $cbNdSize.DropDownStyle = 'DropDown'
    $cbNdSize.Location = New-Object System.Drawing.Point(14, 42); $cbNdSize.Size = New-Object System.Drawing.Size(200, 26)
    @('跟手机一致', '1280x720', '1600x900', '1920x1080') | ForEach-Object { [void]$cbNdSize.Items.Add($_) }
    $cbNdSize.Text = if ($settings.ndSize) { $settings.ndSize } else { '跟手机一致' }
    $cbNdDpi = New-Combo @('自动', '小', '中', '大') @('', '160', '240', '320') $settings.ndDpi 110 79 110
    $chkNoDecor = New-Chk '隐藏虚拟屏的系统状态栏' $settings.ndNoDecor 14 116
    $tt.SetToolTip($cbNdSize, '独立窗口（虚拟显示器）的分辨率。可直接输入自定义值，如 2560x1440。')
    $tt.SetToolTip($cbNdDpi, '虚拟屏里界面元素的大小。手机 App 显示太大就选“小”。')
    $tabNd.Controls.AddRange(@(
        (New-Lbl '分辨率（可直接输入，如 2560x1440）：' 14 17), $cbNdSize,
        (New-Lbl '界面缩放：' 14 82), $cbNdDpi,
        $chkNoDecor))

    # ===== 录制 =====
    $tabRec = New-Object System.Windows.Forms.Panel
    $cbRecFmt = New-Combo @('mp4', 'mkv') @('mp4', 'mkv') $settings.recFormat 110 15 110
    $nudTime = New-Nud $settings.recTimeLimit 0 86400 10 250 51
    $chkRecBg = New-Chk '后台录制（不显示画面，更省资源）' $settings.recBackground 14 90
    $tt.SetToolTip($nudTime, '到达该秒数自动停止录制。0=不限时，手动关窗即停。')
    $tt.SetToolTip($chkRecBg, '勾选后录制时不弹出投屏窗口，画面只写入文件，更省 CPU。')
    $tabRec.Controls.AddRange(@(
        (New-Lbl '保存格式：' 14 18), $cbRecFmt,
        (New-Lbl '录制时长上限（秒，0=不限）：' 14 54), $nudTime,
        $chkRecBg))

    # ===== 通用 =====
    $tabGen = New-Object System.Windows.Forms.Panel
    $chkLive = New-Chk '自动刷新连接状态显示（只更新上方那行文字）' $settings.liveStatus 14 18
    $txtExtra = New-Object System.Windows.Forms.TextBox
    $txtExtra.Location = New-Object System.Drawing.Point(14, 78); $txtExtra.Size = New-Object System.Drawing.Size(392, 24)
    $txtExtra.Text = $settings.extraArgs
    $lblExHint = New-Lbl '例如：--angle=90   --display-id=1   --time-limit=300' 14 108; $lblExHint.ForeColor = $cMuted
    $tt.SetToolTip($chkLive, '它只决定窗口顶部「已连接/未连接」多久自动更新一次，不影响投屏。开着时仅在窗口处于前台才每几秒刷一次；关掉后改为手动点「刷新」，更省资源。')
    $tt.SetToolTip($txtExtra, '高级用法（看不懂就留空，不影响正常使用）：在这里追加 scrcpy 命令行参数，会拼到启动命令末尾，多个用空格分隔。例如 --crop=1080:1920:0:0（裁剪画面）、--angle=90（旋转）、--display-id=1（指定屏幕）。')

    # 自定义 adb / scrcpy 路径（留空=用本助手同目录自带的）
    $lblPathHdr = New-Lbl '自定义 adb / scrcpy 路径（留空＝用自带的）：' 14 150; $lblPathHdr.ForeColor = $cMuted
    $lblAdbCap = New-Lbl 'adb' 14 181
    $txtAdbPath = New-Object System.Windows.Forms.TextBox
    $txtAdbPath.Location = New-Object System.Drawing.Point(66, 177); $txtAdbPath.Size = New-Object System.Drawing.Size(248, 24)
    $txtAdbPath.Text = $settings.adbPath
    $btnAdbBrowse = New-SecondaryBtn '浏览…' 322 176 72 26
    $lblScrcpyCap = New-Lbl 'scrcpy' 14 223
    $txtScrcpyPath = New-Object System.Windows.Forms.TextBox
    $txtScrcpyPath.Location = New-Object System.Drawing.Point(66, 219); $txtScrcpyPath.Size = New-Object System.Drawing.Size(248, 24)
    $txtScrcpyPath.Text = $settings.scrcpyPath
    $btnScrcpyBrowse = New-SecondaryBtn '浏览…' 322 218 72 26
    $btnAdbBrowse.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = '可执行文件 (*.exe)|*.exe|所有文件 (*.*)|*.*'; $ofd.Title = '选择 adb.exe'
        if ($txtAdbPath.Text -and (Test-Path -LiteralPath $txtAdbPath.Text)) { try { $ofd.InitialDirectory = Split-Path -Parent $txtAdbPath.Text } catch {} }
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtAdbPath.Text = $ofd.FileName }
    }.GetNewClosure())
    $btnScrcpyBrowse.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = '可执行文件 (*.exe)|*.exe|所有文件 (*.*)|*.*'; $ofd.Title = '选择 scrcpy.exe'
        if ($txtScrcpyPath.Text -and (Test-Path -LiteralPath $txtScrcpyPath.Text)) { try { $ofd.InitialDirectory = Split-Path -Parent $txtScrcpyPath.Text } catch {} }
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtScrcpyPath.Text = $ofd.FileName }
    }.GetNewClosure())
    $tt.SetToolTip($txtAdbPath, 'adb.exe 路径。留空＝优先用所选 scrcpy 旁边的 adb、没有再用自带的；填了也让 scrcpy 用同一个 adb。保存即时生效。')
    $tt.SetToolTip($txtScrcpyPath, 'scrcpy.exe 路径。留空＝用自带的；想用电脑里别处 / 更新版的 scrcpy 时填。保存即时生效。')

    $tabGen.Controls.AddRange(@(
        $chkLive,
        (New-Lbl '高级·其它命令行参数（看不懂就留空，多个用空格隔开）：' 14 52), $txtExtra, $lblExHint,
        $lblPathHdr, $lblAdbCap, $txtAdbPath, $btnAdbBrowse, $lblScrcpyCap, $txtScrcpyPath, $btnScrcpyBrowse))

    # 把 8 个面板叠放到右侧内容区，只显示选中的那个；导轨切换驱动显示
    $panels = @($tabCommon, $tabVideo, $tabAudio, $tabCtrl, $tabWin, $tabNd, $tabRec, $tabGen)
    foreach ($p in $panels) {
        $p.Location = New-Object System.Drawing.Point(140, 14); $p.Size = New-Object System.Drawing.Size(416, 264)
        $p.BackColor = $cPaper; $p.Visible = $false; $dlg.Controls.Add($p)
    }
    @('常用', '画面', '声音', '控制', '窗口', '独立窗口', '录制', '通用') | ForEach-Object { [void]$nav.Items.Add($_) }
    $nav.Add_SelectedIndexChanged({
        for ($i = 0; $i -lt $panels.Count; $i++) { $panels[$i].Visible = ($i -eq $nav.SelectedIndex) }
        $nav.Invalidate()   # 强制整条导轨重绘，否则上一个选中项的朱砂高亮可能不刷新、看起来两个都选中
    })
    $dlg.Controls.Add($nav); $dlg.Controls.Add($navDivider)
    $nav.SelectedIndex = 0

    $btnSave = New-PrimaryBtn '保存' 358 292 96 34 10
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'; $btnCancel.Size = New-Object System.Drawing.Size(96, 34); $btnCancel.Location = New-Object System.Drawing.Point(460, 292)
    $btnCancel.Add_Click({ $dlg.Close() })
    $btnSave.Add_Click({
        $ndText = $cbNdSize.Text.Trim()
        if ($ndText -and $ndText -ne '跟手机一致' -and $ndText -notmatch '^\d{3,4}x\d{3,4}$') {
            [System.Windows.Forms.MessageBox]::Show('独立窗口分辨率格式应为 宽x高，例如 1920x1080。', '设置') | Out-Null
            return
        }
        $cropText = $txtCrop.Text.Trim()
        if ($cropText -and $cropText -notmatch '^\d+:\d+:\d+:\d+$') {
            [System.Windows.Forms.MessageBox]::Show('裁剪格式应为 宽:高:左:上（纯数字），例如 1080:1080:0:300。留空表示不裁剪。', '设置') | Out-Null
            return
        }
        $settings.maxSize    = [int]$nudSize.Value
        $settings.maxFps     = [int]$nudFps.Value
        $settings.bitRate    = [int]$nudBit.Value
        $settings.videoCodec = $cbVCodec.Vals[$cbVCodec.SelectedIndex]
        $settings.crop       = $cropText
        $settings.audioOn    = $chkAudio.Checked
        $settings.audioSource = $cbASrc.Vals[$cbASrc.SelectedIndex]
        $settings.audioCodec = $cbACodec.Vals[$cbACodec.SelectedIndex]
        $settings.keyboard   = $cbKb.Vals[$cbKb.SelectedIndex]
        $settings.mouse      = $cbMouse.Vals[$cbMouse.SelectedIndex]
        $settings.gamepad    = $chkGamepad.Checked
        $settings.noControl  = $chkNoCtrl.Checked
        $settings.screenOff  = $chkScreenOff.Checked
        $settings.stayAwake  = $chkStay.Checked
        $settings.showTouches = $chkTouches.Checked
        $settings.powerOffOnClose = $chkPowerOff.Checked
        $settings.fullscreen = $chkFull.Checked
        $settings.onTop      = $chkTop.Checked
        $settings.borderless = $chkBorderless.Checked
        $settings.ndSize     = if ($ndText -eq '跟手机一致') { '' } else { $ndText }
        $settings.ndDpi      = $cbNdDpi.Vals[$cbNdDpi.SelectedIndex]
        $settings.ndNoDecor  = $chkNoDecor.Checked
        $settings.recFormat  = $cbRecFmt.Vals[$cbRecFmt.SelectedIndex]
        $settings.recTimeLimit = [int]$nudTime.Value
        $settings.recBackground = $chkRecBg.Checked
        $settings.liveStatus = $chkLive.Checked
        $settings.autoConnect = $chkReconnect.Checked
        $settings.disconnectOnClose = $chkDisconnect.Checked
        $settings.extraArgs  = $txtExtra.Text.Trim()
        $settings.adbPath    = $txtAdbPath.Text.Trim()
        $settings.scrcpyPath = $txtScrcpyPath.Text.Trim()
        Save-Settings
        Resolve-Tools   # 立刻按新路径重算 $exe/$adb（含环境变量 ADB），之后的连接/投屏即时生效、无需重启
        # 填了路径但文件不存在时提醒一句（仍然保存，运行时会回退到自带的那个）
        if ($settings.scrcpyPath -and -not (Test-Path -LiteralPath $settings.scrcpyPath)) {
            [System.Windows.Forms.MessageBox]::Show("填写的 scrcpy 路径不存在，已暂时回退到自带的：`n$($settings.scrcpyPath)", '设置') | Out-Null
        }
        if ($settings.adbPath -and -not (Test-Path -LiteralPath $settings.adbPath)) {
            [System.Windows.Forms.MessageBox]::Show("填写的 adb 路径不存在，已暂时回退到自带的：`n$($settings.adbPath)", '设置') | Out-Null
        }
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    })
    $btnReset = New-Object System.Windows.Forms.Button
    $btnReset.Text = '恢复默认'; $btnReset.Size = New-Object System.Drawing.Size(110, 34); $btnReset.Location = New-Object System.Drawing.Point(14, 292)
    $btnReset.Add_Click({
        if ([System.Windows.Forms.MessageBox]::Show('确定把所有设置恢复为默认值吗？', '恢复默认', 'YesNo', 'Warning') -eq 'Yes') {
            foreach ($k in @($defaults.Keys)) { $settings[$k] = $defaults[$k] }
            Save-Settings
            Resolve-Tools   # 默认里 adb/scrcpy 路径为空 → 重解析回退到自带的
            $dlg.Close()
            [System.Windows.Forms.MessageBox]::Show('已恢复默认设置。', '设置') | Out-Null
        }
    })
    $dlg.Controls.AddRange(@($btnReset, $btnSave, $btnCancel))
    $dlg.AcceptButton = $btnSave
    [void]$dlg.ShowDialog($owner)
}

# ---------------- 从手机已装 App 里挑一个（可搜索） ----------------
# 用 scrcpy --list-apps 列出手机所有 App（带中文名），免去手动查包名。返回包名，取消返回 $null。
function Show-AppPicker {
    param($owner, $serial)
    $owner.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    # 必须带 -s 指定设备：多设备连接时 scrcpy --list-apps 不指定设备会因「有多台设备」直接失败、列不出 App
    $listArgs = if ($serial) { @('-s', $serial, '--list-apps') } else { @('--list-apps') }
    try { $raw = (Invoke-Hidden -FilePath $exe -ArgumentList $listArgs) -join "`n" } catch { $raw = '' }
    $owner.Cursor = [System.Windows.Forms.Cursors]::Default
    $list = @()
    foreach ($line in ($raw -split "`n")) {
        # 形如：「 - 微信                 com.tencent.mm」/「 * 设置  com.android.settings」
        if ($line -match '^\s*[-*]\s+(.*?)\s+([A-Za-z][A-Za-z0-9._]+)\s*$') {
            $list += [pscustomobject]@{ Name = $matches[1].Trim(); Pkg = $matches[2] }
        }
    }
    if (-not $list) {
        [System.Windows.Forms.MessageBox]::Show("没能列出手机里的 App。请确认手机已连接并解锁后重试，或改用「手动输入名字或包名」。", '选择 App') | Out-Null
        return $null
    }
    $list = @($list | Sort-Object Name)

    $dlg = New-Dialog '选择 App' 340 388 $owner

    $lbl = New-Lbl '搜索 / 选择要在独立窗口里打开的 App：' 16 14
    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = '16,40'; $txt.Size = '308,24'
    $lb = New-Object System.Windows.Forms.ListBox
    $lb.Location = '16,74'; $lb.Size = '308,256'
    $lb.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)

    $shown = New-Object System.Collections.ArrayList
    $fill = {
        param($q)
        $ql = ([string]$q).ToLower()   # 字面子串匹配（大小写不敏感）：避免把 [ 等当通配符导致 -like 抛异常
        $lb.BeginUpdate(); $lb.Items.Clear(); $shown.Clear()
        foreach ($it in $list) {
            if (-not $ql -or $it.Name.ToLower().Contains($ql) -or $it.Pkg.ToLower().Contains($ql)) {
                [void]$lb.Items.Add("$($it.Name)   ·   $($it.Pkg)")
                [void]$shown.Add($it)
            }
        }
        $lb.EndUpdate()
        if ($lb.Items.Count -gt 0) { $lb.SelectedIndex = 0 }
    }
    & $fill ''
    $txt.Add_TextChanged({ & $fill $txt.Text.Trim() })

    $btnGo = New-PrimaryBtn '打开' 16 342 308 34 10
    $result = @{ app = $null }
    $pick = {
        if ($lb.SelectedIndex -ge 0) { $result.app = $shown[$lb.SelectedIndex]; $dlg.Close() }
    }
    $btnGo.Add_Click($pick)
    $lb.Add_DoubleClick($pick)
    $dlg.Controls.AddRange(@($lbl, $txt, $lb, $btnGo))
    $dlg.AcceptButton = $btnGo
    [void]$dlg.ShowDialog($owner)
    return $result.app   # 返回 [pscustomobject]@{ Name; Pkg }，取消则 $null
}

# ---------------- 管理「我的常用应用」：用户自己增删常用 App ----------------
function Show-ManageApps {
    param($owner)
    $dlg = New-Dialog '我的常用应用' 360 322 $owner

    $lbl = New-Lbl '你自己加的常用 App（会出现在独立窗口下拉里）：' 16 14
    $lb = New-Object System.Windows.Forms.ListBox
    $lb.Location = '16,40'; $lb.Size = '328,176'
    $lb.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $refresh = {
        $lb.BeginUpdate(); $lb.Items.Clear()
        foreach ($k in $script:customApps.Keys) { [void]$lb.Items.Add("$k   ·   $($script:customApps[$k])") }
        $lb.EndUpdate()
        if ($lb.Items.Count -eq 0) { [void]$lb.Items.Add('（还没有，点下面「手动添加」，或用独立窗口的「更多应用…」挑完选记住）') }
    }
    & $refresh

    $btnAdd = New-SecondaryBtn '手动添加…' 16 226 156 34
    $btnDel = New-SecondaryBtn '删除选中' 188 226 156 34
    $btnAdd.Add_Click({
        $name = [Microsoft.VisualBasic.Interaction]::InputBox('给这个 App 起个显示名字（如 飞书）：', '手动添加常用应用', '')
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        $pkg = [Microsoft.VisualBasic.Interaction]::InputBox("输入它的包名（如 com.ss.android.lark）。`n不知道包名？用独立窗口的「更多应用…」从手机列表里挑，会自动加，不用手填。", '手动添加常用应用', '')
        if ([string]::IsNullOrWhiteSpace($pkg)) { return }
        $script:customApps[$name.Trim()] = $pkg.Trim()
        Save-Settings; & $refresh
    })
    $btnDel.Add_Click({
        $keys = @($script:customApps.Keys)
        if ($lb.SelectedIndex -lt 0 -or $lb.SelectedIndex -ge $keys.Count) { return }
        $script:customApps.Remove($keys[$lb.SelectedIndex])
        Save-Settings; & $refresh
    })
    $btnDone = New-PrimaryBtn '完成' 16 274 328 34 10
    $btnDone.Add_Click({ $dlg.Close() })
    $dlg.Controls.AddRange(@($lbl, $lb, $btnAdd, $btnDel, $btnDone))
    [void]$dlg.ShowDialog($owner)
}

# ---------------- 独立窗口：选 App ----------------
function Show-NewDisplay {
    param($owner, $serial)
    $dlg = New-Dialog '独立窗口' 320 308 $owner

    $l1 = New-Lbl '在电脑上单开一块屏，运行下面这个 App：' 18 18
    $l2 = New-Lbl '（手机本身照常用，互不影响；需 Android 11+）' 18 42; $l2.ForeColor = $cMuted
    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.DropDownStyle = 'DropDownList'; $cb.Location = New-Object System.Drawing.Point(18, 76); $cb.Size = New-Object System.Drawing.Size(284, 28)
    foreach ($name in $apps.Keys) { [void]$cb.Items.Add($name) }
    foreach ($name in $script:customApps.Keys) { [void]$cb.Items.Add($name) }
    [void]$cb.Items.Add('更多应用…（从手机里挑）')
    [void]$cb.Items.Add('手动输入名字或包名…')
    [void]$cb.Items.Add('管理我的常用应用…')
    $cb.SelectedIndex = 0

    # 窗口比例/方向：微信、QQ 等手机应用在“横屏平板”虚拟屏上会用平板版面、显示不全，选「竖屏·手机」即用手机版面
    $lblMode = New-Lbl '窗口比例' 18 120
    $cbMode = New-Combo @('竖屏·手机版面（推荐微信/QQ）', '横屏·平板版面', '跟随“设置”里的尺寸', '自定义…') @('portrait', 'landscape', 'settings', 'custom') $settings.ndMode 86 117 216
    $chkFixed = New-Chk '固定方向（最大化时画面不乱转）' $settings.ndFixed 18 152
    $capMode = New-Caption "竖屏适合聊天/刷信息；横屏适合看视频。乱转就勾上「固定方向」。`n应用双开/分身在独立窗口常黑屏、点不到，建议改用普通投屏在手机上开分身。" 18 176

    $btnGo = New-PrimaryBtn '打开' 18 228 284 38 11
    $btnGo.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Close() })
    $dlg.Controls.AddRange(@($l1, $l2, $cb, $lblMode, $cbMode, $chkFixed, $capMode, $btnGo))
    $dlg.AcceptButton = $btnGo
    if ($dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) {
        $sel = [string]$cb.SelectedItem
        if ($sel -eq '管理我的常用应用…') { Show-ManageApps $owner; return }
        if ($sel -like '更多应用*') {
            $app = Show-AppPicker $owner $serial
            if (-not $app) { return }
            $target = "+$($app.Pkg)"
            # 挑完顺手问一句要不要记住，下次直接在下拉里选
            if (-not $apps.Contains($app.Name) -and -not $script:customApps.Contains($app.Name)) {
                if ([System.Windows.Forms.MessageBox]::Show("要把「$($app.Name)」加到常用列表吗？以后可直接在下拉里选它。", '常用应用', 'YesNo', 'Question') -eq 'Yes') {
                    $script:customApps[$app.Name] = $app.Pkg; Save-Settings
                }
            }
        }
        elseif ($sel -like '手动输入*') {
            $name = [Microsoft.VisualBasic.Interaction]::InputBox("输入 App 名字（如 chrome）或完整包名（如微信 com.tencent.mm）。`n中文 App 建议用包名，更准确。", '独立窗口 - 打开 App', '')
            if ([string]::IsNullOrWhiteSpace($name)) { return }
            $name = $name.Trim()
            $target = if ($name -match '\.') { "+$name" } else { "+?$name" }
        }
        elseif ($apps.Contains($sel)) { $target = '+' + $apps[$sel] }
        elseif ($script:customApps.Contains($sel)) { $target = '+' + $script:customApps[$sel] }
        else { return }
        # 按所选比例/方向算出虚拟屏尺寸与 DPI
        $ndModeSel = [string]$cbMode.Vals[$cbMode.SelectedIndex]
        $ndSz = $settings.ndSize; $ndDpi = $settings.ndDpi
        $autoFit = $false   # portrait/landscape：虚拟屏用真实/标准尺寸，窗口适配屏幕（非 flex）
        switch ($ndModeSel) {
            'portrait'  {
                # 手机版面：虚拟屏用设备真实分辨率/密度，比例、密度都跟手机一致（App 不拉伸、走手机版面）；
                # 窗口再按比例缩进屏幕、避免超出被切。读不到设备尺寸才兜底通用竖屏值。
                $disp = Get-DeviceDisplay $serial
                if ($disp) {
                    $w = [Math]::Min($disp.W, $disp.H); $h = [Math]::Max($disp.W, $disp.H)   # 保证竖屏 W<H
                    $d = if ($disp.Dpi -gt 0) { $disp.Dpi } else { 420 }
                } else { $w = 1080; $h = 2340; $d = 420 }
                $ndSz = "${w}x${h}"; $ndDpi = "$d"; $autoFit = $true
            }
            'landscape' { $ndSz = '1920x1080'; $ndDpi = '240'; $autoFit = $true }
            'custom'    {
                $ndSz  = ([Microsoft.VisualBasic.Interaction]::InputBox("分辨率（宽x高），如 1080x2340。`n留空 = 跟设备一致。", '独立窗口 - 自定义尺寸', $settings.ndSize)).Trim()
                if ($ndSz -and $ndSz -notmatch '^\d{3,4}x\d{3,4}$') {
                    [System.Windows.Forms.MessageBox]::Show('分辨率格式应为 宽x高（用小写字母 x），例如 1080x2340。留空表示跟设备一致。', '独立窗口') | Out-Null
                    return
                }
                $ndDpi = ([Microsoft.VisualBasic.Interaction]::InputBox("DPI（数字），如 420。留空 = 默认。`n数值越大，应用界面越像手机版。", '独立窗口 - 自定义 DPI', $settings.ndDpi)).Trim()
                if ($ndDpi -and $ndDpi -notmatch '^\d+$') {
                    [System.Windows.Forms.MessageBox]::Show('DPI 应为纯数字，例如 420。留空表示用默认。', '独立窗口') | Out-Null
                    return
                }
                $settings.ndSize = $ndSz; $settings.ndDpi = $ndDpi
            }
        }
        $settings.ndMode = $ndModeSel; $settings.ndFixed = $chkFixed.Checked; Save-Settings
        $pre = if ($serial) { @('-s', $serial) } else { @() }
        # 自动模式(手机/平板版面)：窗口适配屏幕；用 --window-* 就必须非 flex（否则 scrcpy 报错），非 flex 也顺带避免最大化画面自转。
        $fitWin = if ($autoFit) { Get-FitWindowArgs $ndSz } else { @() }
        $useFixed = if ($fitWin.Count -gt 0) { $true } else { $chkFixed.Checked }
        # 虚拟屏保留系统装饰（状态栏/导航栏）：去掉 --no-vd-system-decorations 后，像微信这种 App 会把自己的顶栏
        # 同时画进「状态栏预留区」和正常位置，出现「两条一样的顶栏」；保留系统栏则是正常的「状态栏+单顶栏」手机观感。
        Start-Scrcpy ($pre + (Get-NewDisplayArgs $ndSz $ndDpi $useFixed $settings.ndNoDecor) + $fitWin + "--start-app=$target")
    }
}

# ---------------- 无线：配对码连接（Android 11+，免插线） ----------------
# 只需手机「使用配对码配对设备」弹窗里的两样东西：配对地址 + 配对码（并排显示，不会填错）。
# 配对成功后，连接端口用 adb mdns 自动发现，无需用户再去看无线调试主界面那个端口。
# 成功返回连接地址（ip:port），失败/取消返回 $null。
function Show-WirelessPair {
    param($owner)
    $dlg = New-Dialog '用配对码连接（免插线）' 360 262 $owner

    $l1 = New-Lbl '手机需 Android 11+，且与电脑连同一个 Wi-Fi。' 18 14; $l1.ForeColor = $cMuted
    $l2 = New-Lbl '手机：开发者选项 → 无线调试 → 使用配对码配对设备' 18 38

    $l3 = New-Lbl '配对地址（那个弹窗里的「IP 地址和端口」）' 18 72
    $txtPair = New-Object System.Windows.Forms.TextBox
    $txtPair.Location = '18,94'; $txtPair.Size = '324,24'

    $l4 = New-Lbl '配对码（同一弹窗里的 6 位数字）' 18 124
    $txtCode = New-Object System.Windows.Forms.TextBox
    $txtCode.Location = '18,146'; $txtCode.Size = '324,24'; $txtCode.MaxLength = 6

    $lblNote = New-Lbl '两项都在同一个弹窗里照抄即可，连接端口会自动识别。' 18 178; $lblNote.ForeColor = $cMuted

    $btnGo = New-PrimaryBtn '配对并连接' 18 208 324 38 11
    $result = @{ addr = $null }
    $btnGo.Add_Click({
        $pairAddr = $txtPair.Text.Trim()
        $code = $txtCode.Text.Trim()
        if ($pairAddr -notmatch '^(\d{1,3}(\.\d{1,3}){3}):\d+$') { [System.Windows.Forms.MessageBox]::Show('配对地址格式应为 IP:端口，例如 192.168.1.5:37123。', '配对') | Out-Null; return }
        $ip = $matches[1]
        if ($code -notmatch '^\d{6}$') { [System.Windows.Forms.MessageBox]::Show('配对码应为 6 位数字。', '配对') | Out-Null; return }
        try { $pairOut = (Invoke-Hidden -FilePath $adb -ArgumentList @('pair', $pairAddr, $code)) -join "`n" } catch { $pairOut = $_.Exception.Message }
        if ($pairOut -notmatch 'Successfully paired') {
            [System.Windows.Forms.MessageBox]::Show("配对失败。请核对配对地址和配对码（配对码会过期，必要时在手机上重新生成一个）。`n`n$pairOut", '配对') | Out-Null
            return
        }
        # 配对成功：用 mdns 自动发现连接端口（同一 IP，端口不同），轮询几次等服务出现
        $connAddr = $null
        for ($i = 0; $i -lt 5 -and -not $connAddr; $i++) {
            try { $mdns = (Invoke-Hidden -FilePath $adb -ArgumentList @('mdns', 'services')) -join "`n" } catch { $mdns = '' }
            foreach ($line in ($mdns -split "`n")) {
                if ($line -match '_adb-tls-connect\._tcp' -and $line -match "($([regex]::Escape($ip)):\d+)") { $connAddr = $matches[1]; break }
            }
            if (-not $connAddr) { Start-Sleep -Milliseconds 500 }
        }
        # 自动没找到（mdns 不可用等）：退一步问端口号
        if (-not $connAddr) {
            $port = [Microsoft.VisualBasic.Interaction]::InputBox("已配对成功！但没能自动识别连接端口。`n请在手机「无线调试」主界面看「IP 地址和端口」，把冒号后面的端口号填这里：", '用配对码连接', '')
            if ([string]::IsNullOrWhiteSpace($port)) { return }
            $port = $port.Trim()
            if ($port -notmatch '^\d+$') { [System.Windows.Forms.MessageBox]::Show('端口应为纯数字。', '配对') | Out-Null; return }
            $connAddr = "${ip}:$port"
        }
        try { $connOut = (Invoke-Hidden -FilePath $adb -ArgumentList @('connect', $connAddr)) -join "`n" } catch { $connOut = $_.Exception.Message }
        if ($connOut -match 'connected to') {
            $result.addr = $connAddr
            $dlg.Close()
        } else {
            [System.Windows.Forms.MessageBox]::Show("已配对成功，但连接 $connAddr 失败。可在手机「无线调试」主界面核对端口后重试。`n`n$connOut", '配对') | Out-Null
        }
    })
    $dlg.Controls.AddRange(@($l1, $l2, $l3, $txtPair, $l4, $txtCode, $lblNote, $btnGo))
    $dlg.AcceptButton = $btnGo
    [void]$dlg.ShowDialog($owner)
    return $result.addr
}

# ---------------- 快捷键速查 ----------------
# 内容依据 scrcpy 官方 doc/shortcuts.md；MOD 默认 = 左 Alt 或 左 Super。
function Show-Shortcuts {
    param($owner)
    $dlg = New-Dialog '快捷键速查' 380 432 $owner
    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Multiline = $true; $txt.ReadOnly = $true; $txt.ScrollBars = 'Vertical'
    $txt.Location = New-Object System.Drawing.Point(16, 14); $txt.Size = New-Object System.Drawing.Size(348, 358)
    $txt.BackColor = $cWhite; $txt.BorderStyle = 'FixedSingle'
    $txt.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $txt.Text = (@'
MOD 键 = 左 Alt 或 左 Super 键

— 窗口 —
全屏：MOD+f 或 F11
退出：MOD+q
去黑边：MOD+w（或双击画面）
显示帧率：MOD+i

— 手机操作 —
回到桌面：MOD+h（或鼠标中键）
返回：MOD+b（或鼠标右键）
多任务：MOD+s
菜单：MOD+m
音量 加/减：MOD+↑ / MOD+↓
电源键：MOD+p
通知栏 展开/收起：MOD+n / MOD+Shift+n
复制到电脑：MOD+c
粘贴到手机：MOD+v

— 屏幕 —
手机息屏（继续投屏）：MOD+o
手机点亮：MOD+Shift+o
旋转手机屏幕：MOD+r
旋转投屏画面：MOD+← / MOD+→
暂停/恢复画面：MOD+z / MOD+Shift+z

— 拖拽（拖进投屏窗口）—
拖入 APK：安装到手机
拖入其它文件：传到手机

— 相机（手机当摄像头时）—
补光灯 开/关：MOD+t / MOD+Shift+t
放大/缩小：MOD+↑ / MOD+↓
'@ -replace "`r?`n", "`r`n")
    $txt.Select(0, 0)
    $btnClose = New-PrimaryBtn '知道了' 16 382 348 32 10
    $btnClose.Add_Click({ $dlg.Close() })
    $dlg.Controls.AddRange(@($txt, $btnClose))
    $dlg.AcceptButton = $btnClose
    [void]$dlg.ShowDialog($owner)
}

# ---------------- 设备：记住 / 友好名 / 选择 / 解析目标 ----------------
# 给设备起个一眼能认的名字：优先用户记住的备注名，否则取型号，再不行用序列号兜底。
function Get-FriendlyName {
    param($serial)
    if (-not $serial) { return '' }
    if ($script:deviceNames.Contains($serial))  { return $script:deviceNames[$serial] }   # 用户自定义名优先
    if ($script:knownDevices.Contains($serial)) { return $script:knownDevices[$serial] }
    $info = Get-DevInfo $serial
    if ($info.Text) { return ($info.Text -split ' · ')[-1] }   # 取「Android 13 · Pixel 6」里的型号
    return $serial
}
# 把一个无线地址记进列表（已存在则不动），连接成功后调用，下次可在「设备管理」里直接重连。
function Add-KnownDevice {
    param($addr, $name)
    if (-not $addr) { return }
    if ($script:knownDevices.Contains($addr)) { return }
    if (-not $name) { $name = Get-FriendlyName $addr }
    $script:knownDevices[$addr] = $name
    Save-Settings
}

# 把设备移到「最近连接」最前（knownDevices 有序表，最近在前）。只在离散连接成功事件调用，不在每 8s 轮询调，
# 否则会每 8s 写盘、多台同连时反复顶来顶去。Add-KnownDevice 仍只管「第一次记住新设备」。
function Touch-KnownDevice {
    param($addr, $name)
    if (-not $addr) { return }
    if (-not $name) { $name = if ($script:knownDevices.Contains($addr)) { $script:knownDevices[$addr] } else { Get-FriendlyName $addr } }
    $keys = @($script:knownDevices.Keys)
    if ($keys.Count -gt 0 -and $keys[0] -eq $addr -and $script:knownDevices[$addr] -eq $name) { return }
    if ($script:knownDevices.Contains($addr)) { $script:knownDevices.Remove($addr) }
    $script:knownDevices.Insert(0, $addr, $name)
    Save-Settings
}

# 启动自动连接的候选：记住的无线设备(最近在前) 去掉排除名单, 封顶 Max; 默认/上次设备保证纳入并靠前。
function Get-AutoConnectCandidates {
    param([int]$Max = 16)
    $all = @($script:knownDevices.Keys | Where-Object { (Test-Wireless $_) -and (-not (Test-AutoConnectExcluded $_)) })
    if ($all.Count -eq 0) { return @() }
    $priority = @()
    foreach ($p in @($settings.defaultDevice, $settings.lastWirelessAddr)) {
        if ($p -and ($all -contains $p) -and ($priority -notcontains $p)) { $priority += $p }
    }
    $rest = @($all | Where-Object { $priority -notcontains $_ })
    $ordered = @($priority + $rest)
    if ($ordered.Count -gt $Max) { $ordered = @($ordered[0..($Max-1)]) }
    return $ordered
}

# 启动时后台连接所有可达的记住设备：runspace 里并行 TCP 探测(轮询、不用 WaitAll) + 对可达者 CreateNoWindow 跑 adb connect。
# UI 线程零阻塞；完成后一次性 Timer 在 UI 线程回收 runspace、Touch 连上的设备、回调刷新状态。
function Connect-RememberedAsync {
    param($OnDone)
    if ($script:autoConnectStarted) { return }
    if (-not $settings.autoConnect) { return }
    $cands = @(Get-AutoConnectCandidates 16)
    if ($cands.Count -eq 0) { return }
    $script:autoConnectStarted = $true

    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $rs.SessionStateProxy.SetVariable('adbPath', $adb)
    $rs.SessionStateProxy.SetVariable('cands', $cands)
    $rs.SessionStateProxy.SetVariable('probeTimeoutMs', 600)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
        $clients=@(); $iars=@()
        foreach ($addr in $cands) {
            $parts = $addr -split ':'; $ip=$parts[0]
            $port = if ($parts.Count -gt 1 -and $parts[1]) { [int]$parts[1] } else { 5555 }
            $c = New-Object System.Net.Sockets.TcpClient
            try { $iar = $c.BeginConnect($ip,$port,$null,$null) } catch { $iar=$null }
            $clients += $c; $iars += $iar
        }
        $sw=[System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt $probeTimeoutMs) {
            $allDone=$true
            for ($i=0;$i -lt $iars.Count;$i++){ if ($iars[$i] -and -not $iars[$i].IsCompleted){ $allDone=$false; break } }
            if ($allDone){ break }
            Start-Sleep -Milliseconds 30
        }
        $reachable=@()
        for ($i=0;$i -lt $cands.Count;$i++){
            $ok=$false
            try { if ($iars[$i] -and $iars[$i].IsCompleted){ $clients[$i].EndConnect($iars[$i]); $ok=$clients[$i].Connected } } catch { $ok=$false }
            try { $clients[$i].Close() } catch {}
            if ($ok){ $reachable += $cands[$i] }
        }
        $connected=@()
        foreach ($addr in $reachable) {
            try {
                $psi = [System.Diagnostics.ProcessStartInfo]::new()
                $psi.FileName=$adbPath; $psi.Arguments="connect $addr"
                $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
                $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
                $p=[System.Diagnostics.Process]::Start($psi)
                $out=$p.StandardOutput.ReadToEnd(); [void]$p.StandardError.ReadToEnd(); $p.WaitForExit()
                if ($out -match 'connected to' -or $out -match 'already connected') { $connected += $addr }
            } catch {}
        }
        return ,$connected
    })
    $async = $ps.BeginInvoke()
    $bag = $script:bgTimers
    $t = New-Object System.Windows.Forms.Timer; $t.Interval = 400; [void]$bag.Add($t)
    $t.Add_Tick({
        if ($async.IsCompleted) {
            $t.Stop()
            $connected=@()
            try { $connected = @($ps.EndInvoke($async)) } catch {}
            try { $rs.Dispose() } catch {}
            $ps.Dispose(); $t.Dispose(); [void]$bag.Remove($t)
            foreach ($a in $connected) { if ($a) { Touch-KnownDevice $a } }
            if ($OnDone) { & $OnDone $connected }
        }
    }.GetNewClosure())
    $t.Start()
}

# 掉线后台重连单台无线地址（8s 轮询发现掉线时用）：先 TCP 探测可达再 CreateNoWindow adb connect，
# 全程在后台 runspace 跑——不阻塞 UI、不闪控制台（与全脚本一致，不再用 Start-Process -WindowStyle Hidden）。
# in-flight 守卫避免每 8s 轮询叠加多个探测/连接；被「不自动连」排除的地址直接跳过（与启动自动连接口径一致）。
$script:reconnectInFlight = $false
function Reconnect-LastAsync {
    param($addr)
    if (-not $addr) { return }
    if ($script:reconnectInFlight) { return }
    if (Test-AutoConnectExcluded $addr) { return }
    $script:reconnectInFlight = $true
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $rs.SessionStateProxy.SetVariable('adbPath', $adb)
    $rs.SessionStateProxy.SetVariable('addr', $addr)
    $rs.SessionStateProxy.SetVariable('probeTimeoutMs', 700)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
        $parts = $addr -split ':'; $ip = $parts[0]
        $port = if ($parts.Count -gt 1 -and $parts[1]) { [int]$parts[1] } else { 5555 }
        $c = New-Object System.Net.Sockets.TcpClient
        $ok = $false
        try {
            $iar = $c.BeginConnect($ip, $port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne($probeTimeoutMs)) { $c.EndConnect($iar); $ok = $c.Connected }
        } catch { $ok = $false } finally { try { $c.Close() } catch {} }
        if (-not $ok) { return }   # 死地址：探测即止，不发 adb connect，避免堆 ~21s 卡死的隐藏 adb
        try {
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $adbPath; $psi.Arguments = "connect $addr"
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            [void]$p.StandardOutput.ReadToEnd(); [void]$p.StandardError.ReadToEnd(); $p.WaitForExit()
        } catch {}
    })
    $async = $ps.BeginInvoke()
    $bag = $script:bgTimers
    $t = New-Object System.Windows.Forms.Timer; $t.Interval = 400; [void]$bag.Add($t)
    $t.Add_Tick({
        if ($async.IsCompleted) {
            $t.Stop()
            try { $ps.EndInvoke($async) } catch {}
            try { $rs.Dispose() } catch {}
            $ps.Dispose(); $t.Dispose(); [void]$bag.Remove($t)
            $script:reconnectInFlight = $false
        }
    }.GetNewClosure())
    $t.Start()
}

# 多设备时让用户挑一台投屏，返回序列号 / 地址，取消返回 $null。
function Select-Device {
    param($owner, $devs, $title = '选择设备')
    $dlg = New-Dialog $title 340 296 $owner
    $lbl = New-Lbl '检测到多台设备，选择要投屏的一台：' 16 14
    $lb = New-Object System.Windows.Forms.ListBox
    $lb.Location = '16,42'; $lb.Size = '308,160'
    $lb.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    foreach ($s in $devs) {
        $tp = if (Test-Wireless $s) { '无线' } else { 'USB' }
        [void]$lb.Items.Add("$(Get-FriendlyName $s)   ·   $tp   ·   $s")
    }
    if ($lb.Items.Count -gt 0) { $lb.SelectedIndex = 0 }
    $btnGo = New-PrimaryBtn '投屏这台' 16 218 308 34 10
    $result = @{ s = $null }
    $pick = { if ($lb.SelectedIndex -ge 0) { $result.s = $devs[$lb.SelectedIndex]; $dlg.Close() } }
    $btnGo.Add_Click($pick); $lb.Add_DoubleClick($pick)
    $dlg.Controls.AddRange(@($lbl, $lb, $btnGo)); $dlg.AcceptButton = $btnGo
    [void]$dlg.ShowDialog($owner)
    return $result.s
}

# 决定这次投屏用哪台设备。返回 @{ Ok; Serial; Reason }：
#   Ok=$true 时 Serial 可用；Ok=$false 时 Reason='none'(没设备) 或 'cancel'(多设备时用户取消选择)。
# 规则：0 台→none；1 台→用它；多台→优先「默认设备」，否则按偏好类型唯一匹配，再否则弹窗让用户选。
# 并行探测一批「ip:port」此刻哪些可连（TCP 半连接 + 超时）。关键：离线设备若直接 adb connect 会卡满
# 系统 TCP 超时（Windows 上每个死地址约 21 秒），先用它筛掉不可达地址，自动重连就不会一直转圈。
# 一次同时 BeginConnect 全部、轮询等到超时，总耗时≈单台超时而非逐台累加——记住的设备多时不再串行卡界面。
# 轮询而非 WaitHandle.WaitAll：Windows 上 WaitAll 句柄数上限 64，且这里在 UI 线程只需 ≤timeout 的短阻塞。
function Get-ReachableAddrs {
    param([string[]]$addrs, [int]$timeoutMs = 700)
    if (-not $addrs -or $addrs.Count -eq 0) { return @() }
    $clients = @(); $iars = @()
    foreach ($addr in $addrs) {
        $parts = $addr -split ':'; $ip = $parts[0]
        $port = if ($parts.Count -gt 1 -and $parts[1]) { [int]$parts[1] } else { 5555 }
        $c = New-Object System.Net.Sockets.TcpClient
        try { $iar = $c.BeginConnect($ip, $port, $null, $null) } catch { $iar = $null }
        $clients += $c; $iars += $iar
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $allDone = $true
        for ($i = 0; $i -lt $iars.Count; $i++) { if ($iars[$i] -and -not $iars[$i].IsCompleted) { $allDone = $false; break } }
        if ($allDone) { break }
        Start-Sleep -Milliseconds 30
    }
    $reachable = @()
    for ($i = 0; $i -lt $addrs.Count; $i++) {
        $ok = $false
        try { if ($iars[$i] -and $iars[$i].IsCompleted) { $clients[$i].EndConnect($iars[$i]); $ok = $clients[$i].Connected } } catch { $ok = $false }
        try { $clients[$i].Close() } catch {}
        if ($ok) { $reachable += $addrs[$i] }
    }
    return $reachable
}

# 没检测到设备、但有「记住的无线设备」时，先尝试连回来，再返回刷新后的设备列表。
# 先 TCP 探测筛掉离线地址（只对在线的 adb connect），期间弹「正在连接…」小提示而非干转圈；
# 连不上不弹错，交给调用方走原有兜底（选连接方式 / 没检测到手机）。
function Ensure-Devices {
    param($owner)
    $devs = @(Get-DeviceList)
    if ($devs.Count -gt 0 -or $script:knownDevices.Count -eq 0) { return $devs }

    # 先并行探测哪些记住的设备此刻在线，不可达的直接跳过，避免对死地址 adb connect 卡很久
    $reachable = @(Get-ReachableAddrs @($script:knownDevices.Keys) 700)
    if ($reachable.Count -eq 0) { return @(Get-DeviceList) }

    # 非阻塞小提示，避免用户只看到光标转圈以为卡死
    $busy = $null
    try {
        $busy = New-Object System.Windows.Forms.Form
        Set-DpiScale $busy   # 高 DPI 清晰化：Load 时按真实 DPI 等比放大
        $busy.FormBorderStyle = 'None'; $busy.BackColor = $cPaper; $busy.ShowInTaskbar = $false
        $busy.Size = New-Object System.Drawing.Size(260, 64)
        $bl = New-Object System.Windows.Forms.Label
        $bl.Text = '正在连接已记住的设备…'; $bl.Dock = 'Fill'; $bl.TextAlign = 'MiddleCenter'
        $bl.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
        $busy.Controls.Add($bl)
        if ($owner) {
            $ob = $owner.Bounds; $busy.StartPosition = 'Manual'
            $busy.Location = New-Object System.Drawing.Point(($ob.Left + [int](($ob.Width - 260) / 2)), ($ob.Top + [int](($ob.Height - 64) / 2)))
            $busy.Show($owner)
        } else { $busy.StartPosition = 'CenterScreen'; $busy.Show() }
        # 同步重绘忙提示（父窗 + 子标签各自 Update）。不用 Application::DoEvents——它会把整个输入队列也泵掉：
        # 断连+有可达记住设备时，用户快速双击「有线/无线投屏」，第二次点击会在这里被重入派发，最终开出两个 scrcpy 窗口。
        $busy.Refresh(); $bl.Refresh()
    } catch { $busy = $null }

    foreach ($addr in $reachable) {
        try { Invoke-Hidden -FilePath $adb -ArgumentList @('connect', $addr) | Out-Null } catch {}
    }

    if ($busy) { try { $busy.Close(); $busy.Dispose() } catch {} }
    return @(Get-DeviceList)
}

function Resolve-Target {
    param($owner, [string]$Prefer = '')
    $devs = @(Ensure-Devices $owner)
    if ($devs.Count -eq 0) { return @{ Ok = $false; Reason = 'none'; Serial = $null } }
    if ($devs.Count -eq 1) { return @{ Ok = $true; Serial = $devs[0] } }
    if ($settings.defaultDevice -and ($devs -contains $settings.defaultDevice)) { return @{ Ok = $true; Serial = $settings.defaultDevice } }
    if ($Prefer -eq 'usb')      { $m = @($devs | Where-Object { -not (Test-Wireless $_) }); if ($m.Count -eq 1) { return @{ Ok = $true; Serial = $m[0] } } }
    elseif ($Prefer -eq 'wireless') { $m = @($devs | Where-Object { Test-Wireless $_ });   if ($m.Count -eq 1) { return @{ Ok = $true; Serial = $m[0] } } }
    $s = Select-Device $owner $devs
    if ($s) { return @{ Ok = $true; Serial = $s } } else { return @{ Ok = $false; Reason = 'cancel'; Serial = $null } }
}

# 对「有版本要求」的功能（摄像头需 12+、独立窗口需 11+）：点一下就先定目标设备、查它的实际版本，
# 不够直接弹提示并返回 $null（调用方据此中止，连功能弹窗都不会打开）。够了/读不到版本则返回目标序列号。
function Resolve-TargetForFeature {
    param($owner, [int]$Need, [string]$Feature)
    $devs = @(Ensure-Devices $owner)
    if ($devs.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("没检测到手机，请先连接手机再使用「$Feature」。", $Feature) | Out-Null; return $null }
    # 先把版本不够的设备排除在候选之外，再在「合格设备」里定目标：
    # 2 台里排掉 1 台后只剩 1 台就直接用，不必再弹窗问。读不到版本的当「未知」、不排除（交给 scrcpy 兜底）。
    $eligible = @($devs | Where-Object { $v = (Get-DevInfo $_).Ver; ($v -eq 0) -or ($v -ge $Need) })
    if ($eligible.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("「$Feature」需要手机系统为 Android $Need 及以上。`n当前连接的设备都不满足，换一台或升级系统后再试。", $Feature) | Out-Null
        return $null
    }
    if ($eligible.Count -eq 1) { return $eligible[0] }
    if ($settings.defaultDevice -and ($eligible -contains $settings.defaultDevice)) { return $settings.defaultDevice }
    return (Select-Device $owner $eligible "$Feature · 选择设备")
}

# ---------------- 无线：输入 IP 直连（保底连法，不限系统版本；无需配对码） ----------------
# 只要手机已开启网络 adb（Android 11+ 的「无线调试」，或更早系统 tcpip 过一次），给个 IP 就能连。
# 成功返回连接地址（ip:port）并自动记住，失败/取消返回 $null。
function Connect-ByIp {
    param($owner)
    $dlg = New-Dialog '输入 IP 连接' 360 214 $owner
    $l1 = New-Lbl '用 IP 直接连接手机，不需要配对码。' 18 14; $l1.ForeColor = $cMuted
    $l2 = New-Lbl '保底连法：任何已开网络 adb 的设备都适用，重连也方便。' 18 36; $l2.ForeColor = $cMuted
    $l3 = New-Lbl 'IP 地址' 18 68
    $txtIp = New-Object System.Windows.Forms.TextBox; $txtIp.Location = '18,90'; $txtIp.Size = '208,24'
    $l4 = New-Lbl '端口' 242 68
    $txtPort = New-Object System.Windows.Forms.TextBox; $txtPort.Location = '242,90'; $txtPort.Size = '100,24'; $txtPort.Text = '5555'
    $btnGo = New-PrimaryBtn '连接' 18 130 324 38 11
    $result = @{ addr = $null }
    $btnGo.Add_Click({
        $ip = $txtIp.Text.Trim(); $port = $txtPort.Text.Trim()
        if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { [System.Windows.Forms.MessageBox]::Show('IP 地址格式应为 4 段数字，例如 192.168.1.7。', '输入 IP 连接') | Out-Null; return }
        if (-not $port) { $port = '5555' }
        if ($port -notmatch '^\d+$') { [System.Windows.Forms.MessageBox]::Show('端口应为纯数字，常见是 5555。', '输入 IP 连接') | Out-Null; return }
        $addr = "${ip}:$port"
        try { $out = (Invoke-Hidden -FilePath $adb -ArgumentList @('connect', $addr)) -join "`n" } catch { $out = $_.Exception.Message }
        if ($out -match 'connected to') {
            $result.addr = $addr; $dlg.Close()
        } else {
            [System.Windows.Forms.MessageBox]::Show("连接 $addr 失败。`n`n多半是手机没开「网络 adb」。Android 11+ 在开发者选项「无线调试」里打开即可；更早的系统可先用主界面「无线投屏 → 插数据线连接」插一次线完成切换，之后即可用 IP 直连。`n`n$out", '输入 IP 连接') | Out-Null
        }
    })
    $dlg.Controls.AddRange(@($l1, $l2, $l3, $txtIp, $l4, $txtPort, $btnGo))
    $dlg.AcceptButton = $btnGo
    [void]$dlg.ShowDialog($owner)
    if ($result.addr) { Touch-KnownDevice $result.addr }
    return $result.addr
}

# ---------------- 设备管理：切换 / 断开 / 设默认 / 忘记 / IP 直连 ----------------
function Show-DeviceManager {
    param($owner)
    $dlg = New-Dialog '设备管理' 520 420 $owner

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location = '16,14'; $lv.Size = '488,206'
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $true; $lv.HideSelection = $false
    $lv.HeaderStyle = 'Nonclickable'; $lv.BackColor = $cWhite
    $lv.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    [void]$lv.Columns.Add('设备', 156)
    [void]$lv.Columns.Add('地址', 138)
    [void]$lv.Columns.Add('类型 · 系统', 184)   # 这栏要装下「无线 · Android 13  ▶ 投屏中」，给它最宽，别截断
    # 三列合计 478 < 列表内宽，留点余量，避免出现底部水平滚动条
    $grpConn  = New-Object System.Windows.Forms.ListViewGroup -ArgumentList '已连接'
    $grpKnown = New-Object System.Windows.Forms.ListViewGroup -ArgumentList '已记住（未连接）'
    [void]$lv.Groups.Add($grpConn)   # 逐个加：AddRange 收 PS 的 Object[] 会因类型转换失败
    [void]$lv.Groups.Add($grpKnown)

    # 两条发丝线把按钮分成「投屏 / 管理 / 全局」三组，组左侧的小字标签说明这组按钮是干嘛的（结构即信息）
    $line1 = New-Object System.Windows.Forms.Panel; $line1.Size = New-Object System.Drawing.Size(488, 1); $line1.Location = New-Object System.Drawing.Point(16, 230); $line1.BackColor = $cLine
    $line2 = New-Object System.Windows.Forms.Panel; $line2.Size = New-Object System.Drawing.Size(488, 1); $line2.Location = New-Object System.Drawing.Point(16, 334); $line2.BackColor = $cLine

    # 第一组「投屏」：连接与投屏分开——连接只负责连上，投屏只负责开镜像窗口（已连的才可投）
    $capCast = New-Caption '投屏' 18 257
    $btnConnect = New-SecondaryBtn '连接'    58  248 86  34
    $btnCast    = New-SecondaryBtn '投屏'    150 248 86  34
    $btnStop    = New-SecondaryBtn '停止投屏' 242 248 92  34
    $btnAll     = New-SecondaryBtn '全部投屏' 402 248 102 34
    # 第二组「管理」：对单台设备的设置项
    $capManage  = New-Caption '管理' 18 299
    $btnDefault = New-SecondaryBtn '设为默认' 58  290 92 34
    $btnDisc    = New-SecondaryBtn '断开'    156 290 72 34
    $btnRename  = New-SecondaryBtn '重命名'   234 290 82 34
    $btnForget  = New-SecondaryBtn '忘记'    322 290 72 34
    $btnAuto    = New-SecondaryBtn '不自动连' 400 290 104 34   # 切换：把选中无线设备移入/移出「不自动连接」名单
    # 第三组「全局」
    $btnIp      = New-SecondaryBtn '输入 IP 连接…' 16 346 150 34
    $btnRefresh2= New-SecondaryBtn '刷新'    326 346 80  34
    $btnDone    = New-PrimaryBtn   '完成'    414 346 90  34 10

    # refresh 把「已连接设备」「正在投屏的序列号」算一次塞进 $state；updateButtons 只读它，不再每次点都跑 adb
    $state = @{ Active = @(); Connected = @() }

    # 按选中项启用/禁用：连接=有选中的未连设备；投屏=有选中的已连且未在投；停止=有选中的在投；管理类仅单选有效
    $updateButtons = {
        $items = @($lv.SelectedItems | Where-Object { $_.Tag })
        $one = if ($items.Count -eq 1) { $items[0].Tag } else { $null }
        $active = $state.Active
        $btnConnect.Enabled = @($items | Where-Object { -not $_.Tag.Connected }).Count -gt 0
        $btnCast.Enabled    = @($items | Where-Object { $_.Tag.Connected -and ($active -notcontains $_.Tag.Serial) }).Count -gt 0
        $btnStop.Enabled    = @($items | Where-Object { $active -contains $_.Tag.Serial }).Count -gt 0
        $btnAll.Enabled     = @($state.Connected | Where-Object { $active -notcontains $_ }).Count -gt 0
        # 设为默认 ↔ 取消默认：选中的就是当前默认时，按钮变「取消默认」，让人知道再点是取消
        if ($one -and $one.Connected) {
            $btnDefault.Enabled = $true
            $btnDefault.Text = if ($settings.defaultDevice -eq $one.Serial) { '取消默认' } else { '设为默认' }
        } else {
            $btnDefault.Enabled = $false; $btnDefault.Text = '设为默认'
        }
        $btnDisc.Enabled    = [bool]($one -and $one.Connected -and $one.Wireless)
        $btnRename.Enabled  = [bool]$one
        $btnForget.Enabled  = [bool]($one -and -not $one.Connected)
        if ($one -and $one.Wireless) {
            $btnAuto.Enabled = $true
            $btnAuto.Text = if (Test-AutoConnectExcluded $one.Serial) { '恢复自动连' } else { '不自动连' }
        } else { $btnAuto.Enabled = $false; $btnAuto.Text = '不自动连' }
    }
    $refresh = {
        $active = Get-ActiveSerials; $state.Active = $active
        $selSerials = @($lv.SelectedItems | Where-Object { $_.Tag } | ForEach-Object { $_.Tag.Serial })   # 刷新前记住选中项
        $lv.BeginUpdate(); $lv.Items.Clear()
        $connected = @(Get-DeviceList); $state.Connected = $connected
        foreach ($s in $connected) {
            $info = Get-DevInfo $s; $wl = Test-Wireless $s
            $tag = if ($settings.defaultDevice -eq $s) { '  ★默认' } else { '' }
            $it = New-Object System.Windows.Forms.ListViewItem(('●  ' + (Get-FriendlyName $s) + $tag))
            $it.Group = $grpConn; $it.ForeColor = $cGreen
            [void]$it.SubItems.Add($s)
            $sys = if ($info.Ver -gt 0) { "Android $($info.Ver)" } else { '' }
            $typ = $(if ($wl) { '无线' } else { 'USB' }) + $(if ($sys) { " · $sys" } else { '' })
            if ($active -contains $s) { $typ += '  ▶ 投屏中' }   # 正在投屏的标注出来（与整行同为绿色）
            if (Test-AutoConnectExcluded $s) { $typ += '  ⊘ 不自动连' }
            [void]$it.SubItems.Add($typ)
            $it.Tag = @{ Serial = $s; Connected = $true; Wireless = $wl }
            [void]$lv.Items.Add($it)
        }
        foreach ($addr in $script:knownDevices.Keys) {
            if ($connected -contains $addr) { continue }
            $it = New-Object System.Windows.Forms.ListViewItem(('○  ' + (Get-FriendlyName $addr)))
            $it.Group = $grpKnown; $it.ForeColor = $cMuted
            [void]$it.SubItems.Add($addr)
            $typ2 = '无线 · 未连接'; if (Test-AutoConnectExcluded $addr) { $typ2 += '  ⊘ 不自动连' }
            [void]$it.SubItems.Add($typ2)
            $it.Tag = @{ Serial = $addr; Connected = $false; Wireless = $true }
            [void]$lv.Items.Add($it)
        }
        if ($lv.Items.Count -eq 0) {
            $empty = New-Object System.Windows.Forms.ListViewItem('（没有已连接或记住的设备，点下方「输入 IP 连接」或回主界面无线投屏）')
            $empty.ForeColor = $cMuted; [void]$lv.Items.Add($empty)
        }
        foreach ($it in $lv.Items) { if ($it.Tag -and ($selSerials -contains $it.Tag.Serial)) { $it.Selected = $true } }   # 还原选中
        $lv.EndUpdate(); & $updateButtons
    }

    # 连接选中的未连设备（只连，不投）：连成功后它会进到「已连接」组，再点「投屏」即可
    $connectSelected = {
        $items = @($lv.SelectedItems | Where-Object { $_.Tag -and -not $_.Tag.Connected })
        if ($items.Count -eq 0) { return }
        $fail = @()
        $owner.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        foreach ($it in $items) {
            $addr = $it.Tag.Serial
            try { $out = (Invoke-Hidden -FilePath $adb -ArgumentList @('connect', $addr)) -join "`n" } catch { $out = $_.Exception.Message }
            if ($out -match 'connected to') { Touch-KnownDevice $addr } else { $fail += "$addr：$out" }
        }
        $owner.Cursor = [System.Windows.Forms.Cursors]::Default
        if ($fail) { [System.Windows.Forms.MessageBox]::Show("有设备没连上（可能不在线或网络 adb 已关）：`n`n" + ($fail -join "`n"), '设备管理') | Out-Null }
        & $refresh
    }
    # 投屏选中的已连设备（只投，不连）：已在投的跳过不重复开，窗口保持打开方便继续管理
    $castSelected = {
        foreach ($it in @($lv.SelectedItems | Where-Object { $_.Tag -and $_.Tag.Connected })) {
            $addr = $it.Tag.Serial
            if ($state.Active -contains $addr) { continue }
            Start-Scrcpy (@('-s', $addr) + (Get-MirrorArgs -Wireless:(Test-Wireless $addr)))
        }
        & $refresh
    }
    # 全部投屏：把所有已连、尚未投屏的设备各开一个窗口
    $castAll = {
        $active = Get-ActiveSerials
        foreach ($s in @(Get-DeviceList)) {
            if ($active -contains $s) { continue }
            Start-Scrcpy (@('-s', $s) + (Get-MirrorArgs -Wireless:(Test-Wireless $s)))
        }
        & $refresh
    }
    # 停止投屏：只关掉选中设备的投屏窗口，不影响其它台
    $stopSelected = {
        foreach ($it in @($lv.SelectedItems | Where-Object { $_.Tag })) { Stop-DeviceScrcpy $it.Tag.Serial }
        & $refresh
    }
    # 双击某行＝对它做最顺手的那一步：未连就连、已连未投就投（不关窗口，方便接着操作）
    $rowDouble = {
        $items = @($lv.SelectedItems | Where-Object { $_.Tag }); if ($items.Count -ne 1) { return }
        $tag = $items[0].Tag
        if (-not $tag.Connected) { & $connectSelected }
        elseif ($state.Active -notcontains $tag.Serial) { & $castSelected }
    }

    $lv.Add_SelectedIndexChanged($updateButtons)
    $lv.Add_DoubleClick($rowDouble)
    $btnConnect.Add_Click($connectSelected)
    $btnCast.Add_Click($castSelected)
    $btnStop.Add_Click($stopSelected)
    $btnAll.Add_Click($castAll)
    $btnDisc.Add_Click({
        $items = @($lv.SelectedItems | Where-Object { $_.Tag }); if ($items.Count -ne 1) { return }
        $addr = $items[0].Tag.Serial
        Stop-DeviceScrcpy $addr   # 断开前先停掉它的投屏窗口，避免悬空
        try { Invoke-Hidden -FilePath $adb -ArgumentList @('disconnect', $addr) -DiscardStderr | Out-Null } catch {}
        if ($settings.defaultDevice -eq $addr) { $settings.defaultDevice = ''; Save-Settings }
        & $refresh
    })
    $btnDefault.Add_Click({
        $items = @($lv.SelectedItems | Where-Object { $_.Tag }); if ($items.Count -ne 1) { return }
        $s = $items[0].Tag.Serial
        $settings.defaultDevice = if ($settings.defaultDevice -eq $s) { '' } else { $s }   # 再点一次取消默认
        Save-Settings; & $refresh
    })
    $btnRename.Add_Click({
        $items = @($lv.SelectedItems | Where-Object { $_.Tag }); if ($items.Count -ne 1) { return }
        $s = $items[0].Tag.Serial
        $name = [Microsoft.VisualBasic.Interaction]::InputBox("给这台设备起个名字（如 客厅电视）：", '重命名设备', (Get-FriendlyName $s))
        $name = $name.Trim()
        if ($name -and $name -ne (Get-FriendlyName $s)) { $script:deviceNames[$s] = $name; Save-Settings; & $refresh }
    })
    $btnForget.Add_Click({
        $items = @($lv.SelectedItems | Where-Object { $_.Tag }); if ($items.Count -ne 1) { return }
        $addr = $items[0].Tag.Serial
        if ($script:knownDevices.Contains($addr)) { $script:knownDevices.Remove($addr) }
        if ($script:deviceNames.Contains($addr)) { $script:deviceNames.Remove($addr) }   # 忘记设备时一并清掉它的自定义名
        if ($settings.defaultDevice -eq $addr) { $settings.defaultDevice = '' }
        # 若忘记的正是"上次无线地址"，一并清掉——否则主界面 8s 轮询会用它 Reconnect-LastAsync 连回来、再 Add-KnownDevice 把它重新记住，忘记等于白忘
        if ($settings.lastWirelessAddr -eq $addr) { $settings.lastWirelessAddr = '' }
        Save-Settings; & $refresh
    })
    $btnAuto.Add_Click({
        $items = @($lv.SelectedItems | Where-Object { $_.Tag }); if ($items.Count -ne 1) { return }
        $addr = $items[0].Tag.Serial
        if (-not (Test-Wireless $addr)) { return }
        Set-AutoConnectExcluded $addr (-not (Test-AutoConnectExcluded $addr))
        & $refresh
    })
    $btnIp.Add_Click({ if (Connect-ByIp $dlg) { & $refresh } })
    $btnRefresh2.Add_Click($refresh)
    $btnDone.Add_Click({ $dlg.Close() })

    $dlg.Controls.AddRange(@($lv, $line1, $line2, $capCast, $capManage,
        $btnConnect, $btnCast, $btnStop, $btnAll, $btnDefault, $btnDisc, $btnRename, $btnForget, $btnAuto,
        $btnIp, $btnRefresh2, $btnDone))
    $dlg.AcceptButton = $btnDone
    & $refresh
    [void]$dlg.ShowDialog($owner)
}

# 首个实例的「激活等待线程」：后台 runspace 阻塞等命名事件；被后启动的实例 Set 时，把本进程自己的窗口拉到最前。
# 关键：这是本进程激活自己的窗口（比外部进程抢前台可靠得多），加上后启动实例已 AllowSetForegroundWindow 授权，
# SetForegroundWindow 基本必成；万一仍被前台锁挡住，就用「最小化→还原」兜底——还原自最小化是系统允许的前台切换，必定把窗口带到最前并聚焦。
# 直接用 Win32 对 HWND 操作（跨线程安全、作用于窗口所属线程），不碰 WinForms 对象，避免跨 runspace 的线程亲和/死锁问题。
$script:actStop = [hashtable]::Synchronized(@{ stop = $false })   # 关闭时置 stop=$true 让等待线程退出循环——否则它永远阻塞在 WaitOne 上，会把整个进程钉住不退出（残留 powershell.exe 占着单实例 mutex，下次启动被误判成"已在运行"）
function Start-ActivationWaiter {
    param($hwnd, $evt)
    if (-not $evt -or $hwnd -eq [System.IntPtr]::Zero) { return }
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $rs.SessionStateProxy.SetVariable('evt', $evt)
    $rs.SessionStateProxy.SetVariable('hwnd', $hwnd)
    $rs.SessionStateProxy.SetVariable('shared', $script:actStop)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
        while (-not $shared.stop) {
            $sig = $false
            try { $sig = $evt.WaitOne() } catch { break }   # 事件被销毁/异常 → 退出等待
            if ($shared.stop) { break }                       # 关闭时唤醒：检出停止标记就退出，让线程结束、进程可正常退出
            if (-not $sig) { continue }
            try {
                if ([Native.Win]::IsIconic($hwnd)) { [void][Native.Win]::ShowWindow($hwnd, 9) }   # SW_RESTORE：最小化先还原
                [void][Native.Win]::SetForegroundWindow($hwnd)
                Start-Sleep -Milliseconds 60
                if ([Native.Win]::GetForegroundWindow() -ne $hwnd) { [void][Native.Win]::ShowWindow($hwnd, 6); [void][Native.Win]::ShowWindow($hwnd, 9) }   # 6=SW_MINIMIZE→9=SW_RESTORE 兜底，必成
            } catch {}
        }
    })
    [void]$ps.BeginInvoke()
    $script:actWaiter = @{ Rs = $rs; Ps = $ps }
}
# 关闭时调用：置停止标记并 Set 事件唤醒等待线程，令其退出循环，进程随即可正常退出。
function Stop-ActivationWaiter {
    try { $script:actStop.stop = $true } catch {}
    try { if ($script:actEvent) { [void]$script:actEvent.Set() } } catch {}
}

try {
    # ---------------- 主窗口 ----------------
    $form = New-Object System.Windows.Forms.Form
    Set-DpiScale $form   # 高 DPI 清晰化：Load 时按真实 DPI 等比放大
    $form.Text = 'scrcpy 投屏助手'
    $form.ClientSize = New-Object System.Drawing.Size(512, 384)
    # 记住上次的位置：存过且仍落在可见屏幕范围内就沿用，否则居中（换了显示器/分辨率也不会跑到屏幕外）
    $savedX = [int]$settings.winX; $savedY = [int]$settings.winY
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    # 只把「精确的 -1,-1」当作「还没记录过」的哨兵；其余交给下面的虚拟屏边界校验（副屏在主屏左/上方时坐标本就是负的）。
    if (-not ($savedX -eq -1 -and $savedY -eq -1) -and $savedX -ge $vs.Left -and $savedX -le ($vs.Right - 120) -and $savedY -ge $vs.Top -and $savedY -le ($vs.Bottom - 60)) {
        $form.StartPosition = 'Manual'
        $form.Location = New-Object System.Drawing.Point($savedX, $savedY)
    } else {
        $form.StartPosition = 'CenterScreen'
    }
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox = $false
    $form.BackColor = $cPaper
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    $form.Icon = Get-AppIcon
    $tt = New-Object System.Windows.Forms.ToolTip
    $tt.AutoPopDelay = 12000

    # 标题（左侧朱砂竖条，是全局唯一的品牌点缀）
    $brand = New-Object System.Windows.Forms.Panel
    $brand.Size = New-Object System.Drawing.Size(4, 34); $brand.Location = New-Object System.Drawing.Point(28, 24)
    $brand.BackColor = $cRed
    $form.Controls.Add($brand)
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = 'scrcpy 投屏助手'; $lblTitle.AutoSize = $true
    $lblTitle.Location = New-Object System.Drawing.Point(44, 22)
    $lblTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 18, [System.Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = $cInk
    $form.Controls.Add($lblTitle)
    $lblSub = New-Object System.Windows.Forms.Label
    $lblSub.Text = '把安卓手机投到电脑，鼠标键盘随便用'; $lblSub.AutoSize = $true
    $lblSub.Location = New-Object System.Drawing.Point(46, 62)
    $lblSub.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $lblSub.ForeColor = $cMuted
    $form.Controls.Add($lblSub)

    # 连接状态药丸（信号灯，右上角醒目）
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Size = New-Object System.Drawing.Size(124, 28)
    $lblStatus.Location = New-Object System.Drawing.Point(360, 28)
    $lblStatus.TextAlign = 'MiddleCenter'
    $lblStatus.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $lblStatus.BackColor = $cTagBg; $lblStatus.ForeColor = $cMuted
    $lblStatus.Text = '检测中…'
    $lblStatus.Cursor = [System.Windows.Forms.Cursors]::Hand   # 点状态药丸 = 进入设备管理（状态→管理，语义自洽）
    $form.Controls.Add($lblStatus)
    Set-Rounded $lblStatus 13

    # 设备信息小字（型号 + 安卓版本），让用户一眼看出摄像头(12+)/独立窗口(11+)能不能用
    $lblDevInfo = New-Object System.Windows.Forms.Label
    $lblDevInfo.Size = New-Object System.Drawing.Size(160, 16)
    $lblDevInfo.Location = New-Object System.Drawing.Point(324, 60)
    $lblDevInfo.TextAlign = 'MiddleRight'
    $lblDevInfo.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
    $lblDevInfo.ForeColor = $cMuted
    $form.Controls.Add($lblDevInfo)

    # 分隔细线
    $rule = New-Object System.Windows.Forms.Panel
    $rule.Size = New-Object System.Drawing.Size(456, 1); $rule.Location = New-Object System.Drawing.Point(28, 102)
    $rule.BackColor = $cLine
    $form.Controls.Add($rule)

    # 主操作（最常用，做大做显眼）
    $btnWired = New-PrimaryBtn '有线投屏' 28 120 220 64
    $btnWireless = New-PrimaryBtn '无线投屏' 264 120 220 64
    $form.Controls.AddRange(@($btnWired, $btnWireless))
    $capWired = New-Caption '数据线连接 · 最稳定' 32 190
    $capWireless = New-Caption '免数据线 · 一次配置' 268 190
    $form.Controls.AddRange(@($capWired, $capWireless))

    # 更多功能（次要操作）
    $lblMore = New-Object System.Windows.Forms.Label
    $lblMore.Text = '更多功能'; $lblMore.AutoSize = $true; $lblMore.ForeColor = $cMuted
    $lblMore.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9); $lblMore.Location = New-Object System.Drawing.Point(28, 222)
    $form.Controls.Add($lblMore)
    $btnCamera = New-SecondaryBtn '手机当摄像头' 28 246 141 42
    $btnRecord = New-SecondaryBtn '录制屏幕' 185 246 141 42
    $btnNd = New-SecondaryBtn '独立窗口' 343 246 141 42
    $form.Controls.AddRange(@($btnCamera, $btnRecord, $btnNd))

    # 底部细线：把「功能区」和下面这排「工具 / 关于」次要入口分开（分隔=信息，不是装饰）
    $rule2 = New-Object System.Windows.Forms.Panel
    $rule2.Size = New-Object System.Drawing.Size(456, 1); $rule2.Location = New-Object System.Drawing.Point(28, 318)
    $rule2.BackColor = $cLine
    $form.Controls.Add($rule2)

    # 底部：提示（左） + 设备/快捷键/设置/刷新 链接 + GitHub 图标（右，归入「工具/关于」这组安静的次要入口）
    $lblHint = New-Caption '首次连接点「允许 USB 调试」' 28 338
    $form.Controls.Add($lblHint)
    # 不再放「刷新」：状态会在窗口重新获得焦点时自动重测，「设备」管理打开也会重新扫描
    $btnDevices = New-LinkBtn '设备' 288 334 52
    $btnShortcuts = New-LinkBtn '快捷键' 344 334 62
    $btnSettings = New-LinkBtn '设置' 410 334 52
    $form.Controls.AddRange(@($btnDevices, $btnShortcuts, $btnSettings))

    # GitHub 源码 / 反馈入口：用素纸灰描出的 GitHub 标记（透明底、与上面几个链接同色同高），点开仓库主页。
    # 图标以 base64 内嵌，打包不需附带图片文件。
    $ghB64 = 'iVBORw0KGgoAAAANSUhEUgAAACQAAAAkCAYAAADhAJiYAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAOkSURBVFhH7ZdXU1sxEIX550lIo5liSgyG0EzL0DEEDMEYMAyYYooxvYQAaf9hM58cORfp2r4OkwkPPJxBSGd3j3RX2nXJz69X8phQYk78bzwJKoQHCbq5OpbTw6Qc7CbkYHddjZkzecWgaEFXZweyOD8l/aGgNDdWSX3NG6mteqnAmLm+7qDiwDXtC8GzoLvrU4lMDUuTv1yqyp5JTWWp+KtfS33NW2mozYAxc6zBaawrk5nJIbn9fGL5ywVPgtJ7CWlrrlVBCEggLSIX4MDFpjVQqz6r6dcNBQUlN5alzpfZtRchJrDBFh/biSXLv4m8glI761Lne6VAfvjKn0t1xQs1zieONThwsWGMIPJsP7lmxfEk6MvlkUpQnOCso7Ve1uKfJDzarwISSIPAOrgGnImRPmXT2daQFYTP64tDK15BQTjTiUmA6fBgdu38eE8mRnplanxAVhYjsrkWU2A8Nf5Bxod75exoN8vnMmiR+GTdjJdX0Ek6+fszZT4BzqKzExbPK2KfJpUPfOGTkzo+2LZ4wFUQu9Q70oLGhnosnldw2lqQPvHJsQGLByxB327O1TXlhHSSkh+rS7OWsVesxefVTdP+8N0aqFGxTK4l6Ci1dU8Mx9vTGbAMiwWvN76coo5SmxbPEpRYjWaPV3+uhbmwZVgsKCWm3/WVqMWzBLkZcuQmr1gkVhcsv8QyeZYgTsM0fEj+aPAemX7dTt4StLwwbRnOTY9ahsViPjJu+SWWybMEba0vqlulDUnE3q4Wy7BY0K44bxoxiGXyLEG8wtQeZ1uBKOqayfUKuoVMv5Txx19iEMvkWoJ+3F1K1/vG7BVlVxwvb9PlacpyUAjY0Lo4rzxjYhDL5FuCAMlGzcGYuhPqeKf+pzDGY5G8xVEDTjw2o2ycrYuuZ24JDVwF4YzOsLqiVCUjO0EYjvj2gYZKCXUEXOvRSXpbrcHhZKnyzlaFpq3JX5FzU66CAG8EAgCimOOY9VxLk8/16WeuPei/dzGcwNbt/dHIKYhT6etuUQ5IQHb0/fZClqIf1TNAiTFtNMKjf4qphi6q+HTLHY2cgsD1RVolM6K4+l5/RVDJnYK0GHzh0+Q7kVcQ4JbQLSKKvOoPtSpx+fojukqnIGzbg/WebmlBQYCfMfRDOn/A6GDI4mnQTSKIS0EujQ2FPP8U8iRIY2czns2rfA2bFg8XG3M9H4oSpHG4vyEXJ/vWvAZrcMx5L/grQf8ST4IK4dEJ+gX3m3AeIyd/VAAAAABJRU5ErkJggg=='
    $btnGh = New-Object System.Windows.Forms.PictureBox
    # 与链接按钮同高(26)、但整体上移 2px：octocat 的包围盒含底部小尾巴，几何居中会显得偏低，微提更平
    $btnGh.Size = New-Object System.Drawing.Size(18, 26); $btnGh.Location = New-Object System.Drawing.Point(466, 332)
    $btnGh.SizeMode = 'Zoom'; $btnGh.BackColor = $cPaper
    $btnGh.Cursor = [System.Windows.Forms.Cursors]::Hand
    try { $btnGh.Image = [System.Drawing.Image]::FromStream((New-Object System.IO.MemoryStream(,[Convert]::FromBase64String($ghB64)))) } catch {}
    $btnGh.Add_Click({ try { Start-Process 'https://github.com/rockbenben/scrcpy-helper' } catch {} })
    $form.Controls.Add($btnGh)
    $tt.SetToolTip($btnGh, '在 GitHub 查看源码 / 反馈问题')

    $tt.SetToolTip($btnWired, '用数据线连接，最稳定、延迟最低。')
    $tt.SetToolTip($btnWireless, '不用线。已连手机时直接开始；首次可选插一次线，或 Android 11+ 用配对码免插线。')
    $tt.SetToolTip($btnCamera, '把手机摄像头当电脑摄像头用（需 Android 12+）。')
    $tt.SetToolTip($btnRecord, '把手机屏幕录制成视频文件。')
    $tt.SetToolTip($btnNd, '在电脑上单开一块屏运行某个 App，不影响手机（需 Android 11+）。')
    $tt.SetToolTip($btnShortcuts, 'scrcpy 常用快捷键速查（全屏、息屏、旋转、复制粘贴、拖文件装 APK 等）。')
    $tt.SetToolTip($btnSettings, '画质、声音、控制、窗口、独立窗口、录制等都可在这里自定义。')
    $tt.SetToolTip($btnDevices, '管理多台设备：切换、断开、设默认、忘记，或输入 IP 直连。')
    $tt.SetToolTip($lblStatus, '点击管理设备：切换 / 断开 / 输入 IP 连接（状态会在切回窗口时自动刷新）。')

    # ---------------- 行为 ----------------
    $updateStatus = {
        $devs = @(Get-DeviceList)
        # 掉线且开了自动重连：后台探测+连回上次的无线地址（不阻塞界面，下次刷新生效）。
        # 交给 Reconnect-LastAsync：先 TCP 探测可达才连、respect「不自动连」名单、CreateNoWindow 不闪控制台、in-flight 防叠加。
        if ($devs.Count -eq 0 -and $settings.autoConnect -and $settings.lastWirelessAddr) {
            Reconnect-LastAsync $settings.lastWirelessAddr
        }
        if ($devs.Count -gt 0) {
            $w = $devs | Where-Object { Test-Wireless $_ } | Select-Object -First 1
            if ($w) {
                if ($settings.lastWirelessAddr -ne $w) { $settings.lastWirelessAddr = $w; Save-Settings }
                Add-KnownDevice $w   # 任何方式连上的无线设备都自动记住，供「设备管理」重连
            }
            # 状态显示哪台：默认设备（若在线）优先，否则无线优先，再否则第一台
            $isDefault = $settings.defaultDevice -and ($devs -contains $settings.defaultDevice)
            $dev = if ($isDefault) { $settings.defaultDevice } elseif ($w) { $w } else { $devs[0] }
            $type = if (Test-Wireless $dev) { '无线' } else { 'USB' }
            $lblStatus.BackColor = $cGreenBg; $lblStatus.ForeColor = $cGreen
            $lblStatus.Text = "● 已连接 $type"
            $info = Get-DevInfo $dev
            $ver = if ($info.Ver -gt 0) { " · Android $($info.Ver)" } else { '' }
            $star = if ($isDefault -and $devs.Count -gt 1) { '★ ' } else { '' }   # 多设备时标出当前是默认那台
            $lblDevInfo.Text = "$star$(Get-FriendlyName $dev)$ver"
        } else {
            $lblStatus.BackColor = $cTagBg; $lblStatus.ForeColor = $cMuted
            $lblStatus.Text = '○ 未连接'
            $lblDevInfo.Text = ''
        }
    }
    $btnShortcuts.Add_Click({ Show-Shortcuts $form })
    $btnSettings.Add_Click({ Show-Settings $form })
    # 设备管理入口：底部「设备」链接 + 右上角状态药丸都可进；关掉后刷新一次状态
    $openDevices = { Show-DeviceManager $form; & $updateStatus }
    $btnDevices.Add_Click($openDevices)
    $lblStatus.Add_Click($openDevices)

    $btnWired.Add_Click({
        $devs = @(Ensure-Devices $form)
        if ($devs.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('没检测到手机。请用数据线连接并点「允许 USB 调试」，或点右上角状态药丸用无线连接。', '有线投屏') | Out-Null; return }
        $usb = @($devs | Where-Object { -not (Test-Wireless $_) })
        $wl  = @($devs | Where-Object { Test-Wireless $_ })
        # 有线优先：只要有 USB 设备就在 USB 里选；没有 USB 才退回无线。
        # 必须用 @(...) 重新包成数组：PowerShell 会把 if 分支里的单元素数组拆成标量字符串，
        # 那样 $pool[0] 取到的是首字符（serial 被截成 "N"），scrcpy 就会报 Could not find ADB device。
        $pool = @(if ($usb.Count -gt 0) { $usb } else { $wl })
        $t = if ($pool.Count -eq 1) { $pool[0] }
             elseif ($settings.defaultDevice -and ($pool -contains $settings.defaultDevice)) { $settings.defaultDevice }
             else { Select-Device $form $pool '有线投屏 · 选择设备' }   # 多台同类设备 → 弹窗问要投哪台
        if ($t) { Start-Scrcpy (@('-s', $t) + (Get-MirrorArgs -Wireless:(Test-Wireless $t))) }
    })

    $btnWireless.Add_Click({
        $devs = @(Ensure-Devices $form)
        $wl = @($devs | Where-Object { Test-Wireless $_ })
        $usb = @($devs | Where-Object { -not (Test-Wireless $_) })
        if ($wl.Count -ge 1) {
            # 已是无线连接：单台直接投；多台优先默认设备，否则让用户挑
            $t = if ($wl.Count -eq 1) { $wl[0] } elseif ($settings.defaultDevice -and ($wl -contains $settings.defaultDevice)) { $settings.defaultDevice } else { Select-Device $form $wl }
            if ($t) { Start-Scrcpy (@('-s', $t) + (Get-MirrorArgs -Wireless:$true)) }
        }
        elseif ($usb.Count -ge 1) {
            # 只有数据线连着：切到无线（连上后可拔线）。多台先选一台再切
            $t = if ($usb.Count -eq 1) { $usb[0] } else { Select-Device $form $usb }
            if ($t) { Start-Scrcpy (@('-s', $t, '--tcpip') + (Get-MirrorArgs -Wireless:$true)) }
        }
        else {
            # 没检测到设备：三条路——插线切无线（最省事）/ 配对码（11+）/ 输入 IP 直连（保底·无需配对码）
            $pick = New-Dialog '无线投屏' 360 292 $form

            $pl = New-Lbl '没有检测到手机，选一种无线连接方式：' 20 16
            $btnCable = New-PrimaryBtn '插数据线连接（推荐 · 最省事）' 20 46 320 46 11
            $capCable = New-Caption '插一次线即可，连上后自动切无线、可拔线。' 24 94
            $btnPair = New-SecondaryBtn '用配对码连接（Android 11+ · 免插线）' 20 120 320 40
            $capPair = New-Caption '手机开「无线调试 → 使用配对码配对设备」。' 24 162
            $btnIpc = New-SecondaryBtn '输入 IP 直接连接（保底 · 无需配对码）' 20 188 320 40
            $capIp = New-Caption '手机已开网络 adb 时，给个 IP 即可，新旧设备都行。' 24 230

            $btnCable.Add_Click({ $pick.Tag = 'cable'; $pick.Close() })
            $btnPair.Add_Click({ $pick.Tag = 'pair'; $pick.Close() })
            $btnIpc.Add_Click({ $pick.Tag = 'ip'; $pick.Close() })
            $pick.Controls.AddRange(@($pl, $btnCable, $capCable, $btnPair, $capPair, $btnIpc, $capIp))
            [void]$pick.ShowDialog($form)

            if ($pick.Tag -eq 'cable') {
                $msg = "请用数据线把手机连上电脑，并点「允许 USB 调试」。`n`n连好后点「确定」，会自动切到无线（连上后即可拔掉数据线）。`n若手机重启过导致连不上，也请重新插线再点一次。"
                if ([System.Windows.Forms.MessageBox]::Show($msg, '无线投屏', 'OKCancel', 'Information') -eq 'OK') {
                    Start-Scrcpy (@('--tcpip') + (Get-MirrorArgs -Wireless:$true))
                }
            }
            elseif ($pick.Tag -eq 'pair') {
                $addr = Show-WirelessPair $form
                if ($addr) {
                    if ($settings.lastWirelessAddr -ne $addr) { $settings.lastWirelessAddr = $addr; Save-Settings }
                    Touch-KnownDevice $addr
                    Start-Scrcpy (@('-s', $addr) + (Get-MirrorArgs -Wireless:$true))
                }
            }
            elseif ($pick.Tag -eq 'ip') {
                $addr = Connect-ByIp $form   # 内部已成功即记住
                if ($addr) {
                    if ($settings.lastWirelessAddr -ne $addr) { $settings.lastWirelessAddr = $addr; Save-Settings }
                    Start-Scrcpy (@('-s', $addr) + (Get-MirrorArgs -Wireless:$true))
                }
            }
        }
    })

    $btnCamera.Add_Click({
        $serial = Resolve-TargetForFeature $form 12 '手机当摄像头'   # 点击即定设备、查版本，不够直接弹提示并中止
        if (-not $serial) { return }
        # 自动读取这台设备真正支持的采集分辨率（约 1~2 秒），让分辨率下拉只列“一定能开”的尺寸
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $camSizes = Get-CameraSizes $serial
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $camDetected = ((@($camSizes.back).Count + @($camSizes.front).Count) -gt 0)
        $dlg = New-Dialog '手机当摄像头' 264 344 $form

        $gb1 = New-Object System.Windows.Forms.GroupBox
        $gb1.Text = '摄像头'; $gb1.Location = '16,12'; $gb1.Size = '232,52'
        $rbBack = New-Object System.Windows.Forms.RadioButton; $rbBack.Text = '后置'; $rbBack.Location = '16,20'; $rbBack.AutoSize = $true; $rbBack.Checked = ($settings.camFacing -ne 'front')
        $rbFront = New-Object System.Windows.Forms.RadioButton; $rbFront.Text = '前置'; $rbFront.Location = '124,20'; $rbFront.AutoSize = $true; $rbFront.Checked = ($settings.camFacing -eq 'front')
        $gb1.Controls.AddRange(@($rbBack, $rbFront))

        $gb2 = New-Object System.Windows.Forms.GroupBox
        $gb2.Text = '画面方向'; $gb2.Location = '16,74'; $gb2.Size = '232,52'
        $rbLand = New-Object System.Windows.Forms.RadioButton; $rbLand.Text = '横屏'; $rbLand.Location = '16,20'; $rbLand.AutoSize = $true; $rbLand.Checked = ($settings.camOrientation -ne 'port')
        $rbPort = New-Object System.Windows.Forms.RadioButton; $rbPort.Text = '竖屏'; $rbPort.Location = '124,20'; $rbPort.AutoSize = $true; $rbPort.Checked = ($settings.camOrientation -eq 'port')
        $gb2.Controls.AddRange(@($rbLand, $rbPort))

        # 分辨率：优先用实测支持尺寸（精确 --camera-size，一定能开）；读不到时回退到「最大边长」通用档位。
        # 下拉内容随「后置/前置」切换重填——两个摄像头支持的尺寸常常不一样。
        $lblRes = New-Lbl '分辨率' 18 140
        $cbRes = New-Combo @('自动') @('auto') 'auto' 78 137 170
        $capRes = New-Caption '' 78 166
        $fillRes = {
            param($facing)
            $list = @($camSizes[$facing])
            $cbRes.Items.Clear()
            if ($list.Count -gt 0) {
                for ($i = 0; $i -lt $list.Count; $i++) {
                    $tag = if ($i -eq 0) { '  · 最清晰' } elseif ($i -eq $list.Count - 1) { '  · 最流畅' } else { '' }
                    [void]$cbRes.Items.Add("$($list[$i])$tag")
                }
                $cbRes.Vals = [array]$list
            } else {
                [void]$cbRes.Items.Add('高（约 1080p，推荐）')
                [void]$cbRes.Items.Add('中（更流畅）')
                [void]$cbRes.Items.Add('原始最高')
                $cbRes.Vals = @('1920', '1280', '0')
            }
            # 优先恢复这台设备这个朝向上次的选择；否则默认选「长边 ≤1920 里最清晰的」，兼顾清晰与稳定
            $vals = [array]$cbRes.Vals
            $idx = [array]::IndexOf($vals, (Get-CamRemembered $serial $facing))
            if ($idx -lt 0) {
                $idx = 0
                if ($list.Count -gt 0) {
                    for ($i = 0; $i -lt $list.Count; $i++) {
                        if ([Math]::Max([int]($list[$i] -split 'x')[0], [int]($list[$i] -split 'x')[1]) -le 1920) { $idx = $i; break }
                    }
                }
            }
            $cbRes.SelectedIndex = $idx
        }
        $capRes.Text = if ($camDetected) { '✓ 已读取本机支持的尺寸，随便选都能开' } else { '没读到支持列表，用通用档位（打不开就选低一档）' }
        & $fillRes $(if ($settings.camFacing -eq 'front') { 'front' } else { 'back' })   # 按上次记住的前后置初始填充
        $rbBack.Add_CheckedChanged({ if ($rbBack.Checked) { & $fillRes 'back' } })
        $rbFront.Add_CheckedChanged({ if ($rbFront.Checked) { & $fillRes 'front' } })

        $chkTorch = New-Chk '打开补光灯' $settings.camTorch 18 196
        $chkMic = New-Chk '同时采集麦克风声音' $settings.camMic 18 222

        $btnGo = New-PrimaryBtn '开始' 16 262 232 32 11
        $btnGo.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Close() })

        $dlg.Controls.AddRange(@($gb1, $gb2, $lblRes, $cbRes, $capRes, $chkTorch, $chkMic, $btnGo))
        $dlg.AcceptButton = $btnGo
        if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $selVal = [string]$cbRes.Vals[$cbRes.SelectedIndex]
            $facing = if ($rbFront.Checked) { 'front' } else { 'back' }
            Set-CamRemembered $serial $facing $selVal                  # 分辨率按设备+前后记
            # 面板其余选择记成全局偏好，下次打开沿用：前后置 / 横竖屏 / 补光灯 / 麦克风
            $settings.camFacing = $facing
            $settings.camOrientation = if ($rbPort.Checked) { 'port' } else { 'land' }
            $settings.camTorch = $chkTorch.Checked
            $settings.camMic = $chkMic.Checked
            Save-Settings
            $a = @('-s', $serial, '--video-source=camera', "--camera-facing=$facing")
            if ($selVal -match '^\d+x\d+$') {
                # 设备实测支持的精确采集尺寸：直接用 --camera-size，不再加 --camera-ar 以免比例冲突
                $a += "--camera-size=$selVal"
            } else {
                # 回退档位：宽高比 + 最大边长，让 scrcpy 自己在支持范围里挑
                $a += '--camera-ar=16:9'
                if ([int]$selVal -gt 0) { $a += @('-m', "$selVal") }
            }
            # 竖屏旋转要分前后置：多数机型后置传感器方向 90°、前置 270°（差 180°），--capture-orientation 只叠加旋转、
            # 不自动补偿这个差异——前置若也用 90 会上下颠倒，需 270 才是正的。
            if ($rbPort.Checked) { $a += $(if ($rbFront.Checked) { '--capture-orientation=270' } else { '--capture-orientation=90' }) }
            if ($chkTorch.Checked) { $a += '--camera-torch' }
            if ($chkMic.Checked) { $a += '--audio-source=mic' } else { $a += '--no-audio' }
            Start-Scrcpy $a
        }
    })

    $btnRecord.Add_Click({
        $tgt = Resolve-Target $form
        if (-not $tgt.Ok) { if ($tgt.Reason -eq 'none') { [System.Windows.Forms.MessageBox]::Show('没检测到手机，请先连接手机再录制。', '录制屏幕') | Out-Null }; return }
        $sfd = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.InitialDirectory = $PSScriptRoot
        $sfd.FileName = "录屏-$(Get-Date -Format 'yyyyMMdd-HHmmss').$($settings.recFormat)"
        $sfd.Filter = 'MP4 视频|*.mp4|MKV 视频|*.mkv'
        if ($sfd.ShowDialog($form) -eq 'OK') {
            $a = @('-s', $tgt.Serial, '-r', $sfd.FileName) + (Get-VideoArgs) + (Get-AudioArgs)
            # 保持唤醒要分连接方式：无线用 --keep-active（-w/--stay-awake 只在 USB 插电时生效，无线录制会中途息屏断流）
            if ($settings.stayAwake) { $a += $(if (Test-Wireless $tgt.Serial) { '--keep-active' } else { '-w' }) }
            if ([int]$settings.recTimeLimit -gt 0) { $a += "--time-limit=$($settings.recTimeLimit)" }
            if ($settings.recBackground) { $a += @('--no-window', '--no-playback') }
            Start-Scrcpy $a -Recording
            # 非模态提示（不弹窗打断）：把底部提示行临时换成录制提示，几秒后自动恢复。文字保持短，避免压到右侧「设备/快捷键/设置」链接。
            $recTip = if ($settings.recBackground) { '● 后台录制中 · 「设备」里停止投屏即保存' } else { '● 录制中 · 关掉投屏窗口即停止并保存' }
            # 只在「当前不是录制提示态」时记住原始提示——否则 6s 内连续两次录制会让第二次把 recTip 当成「原文」记下，
            # 两个恢复定时器先后触发后底部会永久卡在 recTip（明明没在录）。恢复统一用这份记住的原始文案。
            if (-not $script:recTipActive) { $script:recHintText = $lblHint.Text; $script:recHintColor = $lblHint.ForeColor }
            $script:recTipActive = $true
            $lblHint.Text = $recTip; $lblHint.ForeColor = $cGreen
            $rt = New-Object System.Windows.Forms.Timer; $rt.Interval = 6000; [void]$script:bgTimers.Add($rt)
            $rt.Add_Tick({ $rt.Stop(); $lblHint.Text = $script:recHintText; $lblHint.ForeColor = $script:recHintColor; $script:recTipActive = $false; $rt.Dispose(); [void]$script:bgTimers.Remove($rt) }.GetNewClosure())
            $rt.Start()
        }
    })

    $btnNd.Add_Click({
        $serial = Resolve-TargetForFeature $form 11 '独立窗口'   # 点击即定设备、查版本，不够直接弹提示并中止
        if (-not $serial) { return }
        Show-NewDisplay $form $serial
    })

    # 设备状态轮询：仅在窗口处于前台时进行；最小化/失焦自动暂停，省电省资源
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 8000
    $timer.Add_Tick($updateStatus)
    $form.Add_Shown({
        & $updateStatus
        if ($settings.liveStatus -or $settings.autoConnect) { $timer.Start() }
        Connect-RememberedAsync ({ param($connected) & $updateStatus }.GetNewClosure())
        Start-ActivationWaiter $form.Handle $script:actEvent   # 开始监听"再次启动时激活本窗口"的信号
        # 首次显示主动抢一次前台：conhost --headless 启动的进程窗口有时不会自动到前台/不聚焦，用户以为"没反应"。
        # 本进程激活自己的窗口是可靠的：Activate + TopMost 翻转 + SetForegroundWindow(自身句柄)。
        try { $form.Activate(); $form.TopMost = $true; $form.TopMost = $false; [void][Native.Win]::SetForegroundWindow($form.Handle) } catch {}
    })
    $form.Add_Activated({ & $updateStatus; if ($settings.liveStatus -or $settings.autoConnect) { $timer.Start() } else { $timer.Stop() } })
    $form.Add_Deactivate({ $timer.Stop() })
    # 关闭助手 = 停止它开过的所有投屏；正在录屏时先确认，避免误关丢录像
    $form.Add_FormClosing({
        param($formSender, $e)
        if (Test-Recording) {
            $r = [System.Windows.Forms.MessageBox]::Show("正在录屏。关闭助手会停止录制（已录部分会保存）。`n`n确定要关闭吗？`n（想继续录、只收起助手，请点最小化）", '正在录屏', 'YesNo', 'Warning')
            if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { $e.Cancel = $true; return }
        }
        # 记住这次的窗口位置（仅正常状态，避免存到最小化时的 -32000）
        if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal) {
            if ($settings.winX -ne $form.Location.X -or $settings.winY -ne $form.Location.Y) {
                $settings.winX = $form.Location.X; $settings.winY = $form.Location.Y; Save-Settings
            }
        }
        Stop-AllScrcpy
        if ($settings.disconnectOnClose) { try { Invoke-Hidden -FilePath $adb -ArgumentList @('disconnect') -DiscardStderr | Out-Null } catch {} }
        # 关助手时顺手结束自带 adb.exe 的常驻 server 进程，避免它残留在后台、还得去任务管理器手动杀。
        # 用本助手目录里的 adb 自己 kill-server（只停默认端口的 server，下次用到会自动重启）。
        try { Invoke-Hidden -FilePath $adb -ArgumentList @('kill-server') -DiscardStderr | Out-Null } catch {}
    })
    $form.Add_FormClosed({ $timer.Stop(); $timer.Dispose(); Stop-ActivationWaiter })   # 让激活等待线程退出，否则它阻塞 WaitOne 会钉住进程不退出

    [void]$form.ShowDialog()
}
catch {
    [System.Windows.Forms.MessageBox]::Show("启动出错：`n$($_.Exception.Message)", 'scrcpy 投屏助手') | Out-Null
}
