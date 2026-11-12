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
# 需配合各窗体的 Set-DpiScale（见 New-Dialog 弹窗 / 主窗 $form）在 Load 时按真实 DPI 等比放大。
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

# UI 线程事件处理器里的漏网异常：默认会弹 .NET Framework 的「未经处理的异常」模态窗（还带「退出」按钮，
# 一点就把助手整个杀掉、收尾代码全跳过）。改为记到脚本旁的错误日志里、程序照常继续，用户不被打断还留下线索。
# 但 PipelineStoppedException 例外：它不是程序出错，而是「某个 Timer 的 tick 想在一个已经跑着脚本块的线程上
# 再开一条管道」被 PowerShell 拒绝——典型场景是模态框开着的时候看门狗/提示还原定时器跳了一下。
# 被拒的只是这一次 tick，定时器照旧按间隔继续跳（模态框一关就正常执行），所以既没丢状态也没卡死。
# 记进日志反而会把真正的异常淹掉，故直接放过。
[System.Windows.Forms.Application]::add_ThreadException([System.Threading.ThreadExceptionEventHandler]{
    param($s, $e)
    try {
        if ($e.Exception -is [System.Management.Automation.PipelineStoppedException]) { return }
        $logPath = Join-Path $PSScriptRoot '投屏助手-错误日志.txt'
        if ((Test-Path -LiteralPath $logPath) -and ((Get-Item -LiteralPath $logPath).Length -gt 262144)) { Remove-Item -LiteralPath $logPath -Force }   # 日志封顶 256KB，超了重头记
        Add-Content -LiteralPath $logPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $($e.Exception)`r`n" -Encoding UTF8
    } catch {}
})

# scrcpy 4.0 的命令行输出是 UTF-8；Windows PowerShell 默认按系统 OEM 码页解码，会把中文
# （如「更多应用」里 --list-apps 列出的 App 中文名）读成乱码。统一按 UTF-8 解码原生命令输出。
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# 任务栏图标 / 通知身份：把本进程标识成自己的 App，而不是跟着宿主 powershell.exe 走，
# 否则任务栏按钮沿用 PowerShell 的蓝色图标，托盘通知顶部的应用名也是乱的。
# 必须满足两点，缺一通知身份行就会出问题：
# 1) P/Invoke 必须显式 CharSet.Unicode——该 API 只有 Unicode 版本，漏写时按 ANSI 封送，
#    系统把单字节串当 UTF-16 读，进程 AUMID 会变成乱码（通知顶部显示一堆汉字乱码，实测）。
# 2) AUMID 要在 HKCU 注册显示名，否则通知顶部只能显示裸的 AUMID 字符串。
# 用 Reflection.Emit 在内存里发出 P/Invoke，不走 Add-Type/csc（后者在部分管控机上编译失败）。
try {
    $appId = 'rockbenben.scrcpyHelper'
    try {
        $aumidKey = "HKCU:\Software\Classes\AppUserModelId\$appId"
        if (-not (Test-Path -LiteralPath $aumidKey)) { New-Item -Path $aumidKey -Force | Out-Null }
        New-ItemProperty -Path $aumidKey -Name DisplayName -Value 'scrcpy 投屏助手' -PropertyType String -Force | Out-Null
    } catch {}
    if (-not ('Native.ShellEmit' -as [type])) {
        $_asm = [AppDomain]::CurrentDomain.DefineDynamicAssembly(
            (New-Object Reflection.AssemblyName('scrcpyHelperNative')), [Reflection.Emit.AssemblyBuilderAccess]::Run)
        $_mod = $_asm.DefineDynamicModule('scrcpyHelperNative')
        $_tb = $_mod.DefineType('Native.ShellEmit', [Reflection.TypeAttributes]'Public, Class, Sealed, Abstract')
        [void]$_tb.DefinePInvokeMethod(
            'SetCurrentProcessExplicitAppUserModelID', 'shell32.dll',
            [Reflection.MethodAttributes]'Public, Static, PinvokeImpl', [Reflection.CallingConventions]::Standard,
            [int], @([string]),
            [Runtime.InteropServices.CallingConvention]::Winapi, [Runtime.InteropServices.CharSet]::Unicode)
        [void]$_tb.CreateType()
    }
    [Native.ShellEmit]::SetCurrentProcessExplicitAppUserModelID($appId) | Out-Null
} catch {}

# 控制台信号 API：关闭 / 停止时给「录制中」的 scrcpy 发 Ctrl+C 让它优雅收尾（见 Stop-ScrcpyGraceful）。
# 「后台录制」带 --no-window，没有窗口可 CloseMainWindow，只能靠这个信号，否则直接 Kill 会截断 mp4（尾原子没写、文件打不开）。
try {
    Add-Type -Namespace Native -Name ConIO -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)] public static extern bool AttachConsole(uint dwProcessId);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)] public static extern uint GetConsoleProcessList([System.Runtime.InteropServices.Out] uint[] processList, uint processCount);
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
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(uint dwProcessId);
public delegate bool EnumWinProc(System.IntPtr h, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumWindows(EnumWinProc cb, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, ExactSpelling = true)] public static extern int GetWindowTextW(System.IntPtr h, System.Text.StringBuilder s, int n);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
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
$cMuted   = [System.Drawing.Color]::FromArgb(108, 104, 96)    # 次要文字（已压深到过 WCAG AA，勿再调浅）
$cRed     = [System.Drawing.Color]::FromArgb(167, 43, 42)     # 朱砂印（仅标题竖条）
$cRedDark = [System.Drawing.Color]::FromArgb(138, 33, 33)
$cLine    = [System.Drawing.Color]::FromArgb(217, 212, 203)   # 发丝线 / 描边
$cGreen   = [System.Drawing.Color]::FromArgb(38, 110, 74)     # 已连接（已压深到在绿药丸上过 WCAG AA，勿再调浅）
$cGreenBg = [System.Drawing.Color]::FromArgb(220, 231, 223)
$cTagBg   = [System.Drawing.Color]::FromArgb(226, 221, 212)   # 未连接药丸
$cWhite   = [System.Drawing.Color]::FromArgb(252, 251, 249)   # 卡片软白（次要按钮 / 输入）
$cHover   = [System.Drawing.Color]::FromArgb(243, 240, 234)   # 次要按钮悬停
# 忙时退档色：主按钮=墨色被纸色冲淡一档，次按钮=卡片白退到悬停白、字收进次要灰，链接再淡一档。
# 为什么不交给系统禁用态：Enabled=false 时平面渲染器无视 ForeColor 自己派生字色，实测黑底按钮的字被画成
# #0F0E0D（压在 #2B2926 上 = 1.33:1，读不出），白底按钮的字画成橄榄 #776540（跳出色板）。
$cBusyInk      = [System.Drawing.Color]::FromArgb(87, 83, 78)
$cBusyInkText  = [System.Drawing.Color]::FromArgb(228, 224, 216)
$cBusySecBg    = [System.Drawing.Color]::FromArgb(243, 240, 234)
$cBusySecText  = [System.Drawing.Color]::FromArgb(108, 104, 96)
$cBusySecLine  = [System.Drawing.Color]::FromArgb(226, 221, 212)
$cBusyLink     = [System.Drawing.Color]::FromArgb(180, 174, 164)

$exe = Join-Path $PSScriptRoot 'scrcpy.exe'
$adb = Join-Path $PSScriptRoot 'adb.exe'
$cfgPath = Join-Path $PSScriptRoot '投屏助手-设置.json'

$script:customApps = [ordered]@{}   # 用户自定义的常用 App（名称 => 包名），随设置一起存进 投屏助手-设置.json
$script:knownDevices = [ordered]@{} # 记住的无线设备（ip:port 或 mDNS 标识 => 备注名），连接成功自动记下，供「设备管理」切换/重连
$script:deviceNames  = [ordered]@{} # 用户自定义的设备显示名（序列号/地址 => 名称），优先于型号显示，可在「设备管理」里重命名
$script:autoConnectExclude = New-Object System.Collections.Generic.List[string]  # 不自动连接的无线地址（设备管理里可切换）
$script:camResByDevice = [ordered]@{}   # 摄像头采集尺寸记忆，按「序列号|前后」分记（serial|back / serial|front => WxH 或档位）
$script:camSizesCache  = @{}            # --list-camera-sizes 结果按设备会话缓存，同一台只读一次
$scrcpyProcs = New-Object System.Collections.ArrayList   # 记录本助手启动的所有 scrcpy 进程，关助手时一并停止
$script:camSessions = New-Object System.Collections.ArrayList   # 摄像头会话（看门狗自动重连，见主窗 $script:camWatch）；Stop-* 先打 Stopped 标记免得被看门狗拉起来
$script:autoConnectStarted = $false                      # 启动自动连接每次只跑一次

# 注：$exe/$adb 的最终解析与「没找到 scrcpy.exe」守卫都挪到了 Load-Settings 之后（见下方 Resolve-Tools + 守卫），
# 这样「设置 > 通用」里自定义的 adb/scrcpy 路径（存在 JSON 里）才能在守卫判断前生效；否则守卫用的是写死的自带路径。

# 同步执行外部命令并捕获标准输入/输出/错误，支持取消标志和超时熔断，从源头隐藏控制台窗口且不阻塞 UI。
function Invoke-ShortCommand {
    param([string]$FilePath, [string[]]$ArgumentList = @(),
          [ValidateRange(1,15000)][int]$TimeoutMs = 15000, $Control)
    $result = [pscustomobject]@{ Started = $false; ExitCode = $null; TimedOut = $false; Cancelled = $false; Stdout = ''; Stderr = ''; Error = '' }
    $proc = $null
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        if ($Control -and $Control.Cancelled) { $result.Cancelled = $true; return $result }
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $FilePath
        # 5.1 没有 ArgumentList；按 Windows argv 规则处理引号前和收尾的反斜杠。
        $psi.Arguments = (@($ArgumentList | ForEach-Object {
            '"' + ([regex]::Replace([regex]::Replace($_, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1')) + '"'
        }) -join ' ')
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
        $proc = [Diagnostics.Process]::Start($psi)
        if ($Control) { $Control.Process = $proc }
        $result.Started = $true
        $proc.StandardInput.Close()
        $outTask = $proc.StandardOutput.ReadToEndAsync(); $errTask = $proc.StandardError.ReadToEndAsync()
        while (-not $proc.HasExited -or -not $outTask.IsCompleted -or -not $errTask.IsCompleted) {
            if ($Control -and $Control.Cancelled) { $result.Cancelled = $true; break }
            if ($watch.ElapsedMilliseconds -ge $TimeoutMs) { $result.TimedOut = $true; break }
            Start-Sleep -Milliseconds 25
        }
        if ($proc.HasExited) { $result.ExitCode = $proc.ExitCode }
        if ($outTask.IsCompleted -and -not $outTask.IsFaulted) { $result.Stdout = $outTask.Result }
        if ($errTask.IsCompleted -and -not $errTask.IsFaulted) { $result.Stderr = $errTask.Result }
    } catch { $result.Error = $_.Exception.Message }
    finally {
        if ($proc) {
            try { if (-not $proc.HasExited) { $proc.Kill(); [void]$proc.WaitForExit(200) } } catch {}
            $proc.Dispose()
        }
        if ($Control) { $Control.Process = $null }
    }
    return $result
}

# 兼容原有文本行调用方；新流程直接读取结构化结果，区分失败、超时与空列表。
function Invoke-Hidden {
    param([string]$FilePath, [string[]]$ArgumentList = @(), [switch]$DiscardStderr,
          [ValidateRange(1,15000)][int]$TimeoutMs = 15000)
    $result = Invoke-ShortCommand -FilePath $FilePath -ArgumentList $ArgumentList -TimeoutMs $TimeoutMs
    $combined = $result.Stdout
    if (-not $DiscardStderr -and $result.Stderr) { $combined += "`n" + $result.Stderr }
    if (-not $combined) { return @() }
    return @($combined -split "`r?`n")
}

# worker 只使用快照和取消标志，绝不读写控件或实时设置。
function Invoke-DeviceScan {
    param($AdbPath, [string[]]$Candidates, [bool]$ConnectAlways, $InfoCache, $Control, [int]$BudgetMs = 15000)
    $scan = [pscustomobject]@{ Success = $false; Devices = @(); Connected = @(); Info = @{}; Error = '' }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    function Run-Adb {
        param([string[]]$Arguments, [int]$Limit = 3000)
        $left = $BudgetMs - [int]$clock.ElapsedMilliseconds
        if ($left -le 0) { return [pscustomobject]@{ Started = $false; ExitCode = $null; TimedOut = $true; Cancelled = $false; Stdout = ''; Stderr = ''; Error = '' } }
        return (Invoke-ShortCommand -FilePath $AdbPath -ArgumentList $Arguments -TimeoutMs ([Math]::Min($Limit,$left)) -Control $Control)
    }
    function Read-Devices {
        $r = Run-Adb @('devices')
        if (-not $r.Started -or $r.ExitCode -ne 0 -or $r.TimedOut -or $r.Cancelled -or $r.Stdout -notmatch 'List of devices attached') {
            $scan.Error = if ($r.Error) { $r.Error } elseif ($r.Stderr) { $r.Stderr } else { 'adb devices 未在时限内返回有效设备列表' }
            return $false
        }
        $scan.Devices = @($r.Stdout -split "`r?`n" | Where-Object { $_ -match "`tdevice`r?$" } | ForEach-Object { ($_ -split "`t")[0] })
        return $true
    }
    if (-not (Read-Devices)) { return $scan }
    if ($ConnectAlways -or $scan.Devices.Count -eq 0) {
        foreach ($addr in @(Get-ReachableAddrs $Candidates 700)) {
            if ($Control.Cancelled -or $clock.ElapsedMilliseconds -ge $BudgetMs) { break }
            [void](Run-Adb @('connect',$addr))
        }
        if ($Candidates.Count -gt 0 -and -not (Read-Devices)) { return $scan }
        # 只记实际在线的地址，不把 connect 的提示文本当成授权成功。
        $scan.Connected = @($Candidates | Where-Object { $scan.Devices -contains $_ })
    }
    $scan.Success = $true
    foreach ($serial in $scan.Devices) {
        if ($Control.Cancelled -or $clock.ElapsedMilliseconds -ge $BudgetMs) { break }
        if ($InfoCache.ContainsKey($serial)) { $scan.Info[$serial] = $InfoCache[$serial]; continue }
        $v = Run-Adb @('-s',$serial,'shell','getprop','ro.build.version.release') 1500
        $m = Run-Adb @('-s',$serial,'shell','getprop','ro.product.model') 1500
        $version = 0; $text = ''
        if ($v.ExitCode -eq 0 -and -not $v.TimedOut -and $v.Stdout.Trim() -match '^(\d+)') {
            $version = [int]$matches[1]; $text = "Android $($v.Stdout.Trim())"
        }
        if ($m.ExitCode -eq 0 -and -not $m.TimedOut -and $m.Stdout.Trim()) { $text = (@($text,$m.Stdout.Trim()) | Where-Object { $_ }) -join ' · ' }
        if ($version -gt 0 -and $m.ExitCode -eq 0 -and -not $m.TimedOut -and $m.Stdout.Trim()) { $scan.Info[$serial] = @{ Ver = $version; Text = $text } }
    }
    return $scan
}

$script:deviceScanState = @{ Active = $null; Pending = (New-Object Collections.ArrayList); Closing = $false; Paused = $false }
function Start-DeviceScan {
    param($Owner, [string[]]$Candidates = @(), [bool]$ConnectAlways = $false,
          [string]$Kind = 'status', [scriptblock]$OnDone, [scriptblock]$OnFinally)
    Start-UiTask -Owner $Owner -Kind $Kind -OnDone $OnDone -OnFinally $OnFinally -Inputs @{
        AdbPath = $adb; Candidates = $Candidates; ConnectAlways = $ConnectAlways
    }
}
function Start-UiTask {
    param($Owner, [string]$Kind = 'operation', [scriptblock]$Work, [hashtable]$Inputs = @{},
          [string[]]$Functions = @(), [scriptblock]$OnDone, [scriptblock]$OnFinally)
    $state = $script:deviceScanState
    if ($state.Closing -or ($script:closeState.InProgress -and $Kind -ne 'shutdown')) { if ($OnFinally) { & $OnFinally }; return }
    if ($Kind -eq 'status' -and ($state.Active -or $state.Pending.Count)) { return }
    [void]$state.Pending.Add(@{
        Owner = $Owner; Kind = $Kind; Work = $Work; Inputs = $Inputs; Functions = $Functions
        OnDone = $OnDone; OnFinally = $OnFinally
    })
    Start-NextDeviceScan
}
function Start-NextDeviceScan {
    $state = $script:deviceScanState
    if ($state.Closing -or $state.Active -or $state.Pending.Count -eq 0) { return }
    $job = $state.Pending[0]; $state.Pending.RemoveAt(0)
    if ($job.Owner -and $job.Owner.IsDisposed) {
        if ($job.OnFinally) { & $job.OnFinally }
        Start-NextDeviceScan
        return
    }
    $job.Control = [hashtable]::Synchronized(@{ Cancelled = $false; Process = $null })
    $job.Ps = $null; $job.Rs = $null; $job.Timer = $null
    $state.Active = $job
    try {
        $job.Rs = [runspacefactory]::CreateRunspace(); $job.Rs.Open()
        $job.Ps = [powershell]::Create(); $job.Ps.Runspace = $job.Rs
        $cache = @{}; foreach ($key in $script:devInfo.Keys) { $cache[$key] = $script:devInfo[$key] }
        $job.Rs.SessionStateProxy.SetVariable('Inputs',$job.Inputs)
        $job.Rs.SessionStateProxy.SetVariable('Control',$job.Control)
        $job.Rs.SessionStateProxy.SetVariable('InfoCache',$cache)
        $names = @('Invoke-ShortCommand','Test-TcpAddress','Test-MdnsSerial','Test-Wireless','Get-ReachableAddrs','Invoke-DeviceScan') + @($job.Functions)
        $definitions = @($names | Select-Object -Unique | ForEach-Object { "function $_ { $((Get-Item "function:$_").Definition) }" })
        $work = if ($job.Work) { $job.Work.ToString() } else {
            'Invoke-DeviceScan -AdbPath $Inputs.AdbPath -Candidates $Inputs.Candidates -ConnectAlways $Inputs.ConnectAlways -InfoCache $InfoCache -Control $Control'
        }
        [void]$job.Ps.AddScript(($definitions -join "`n") + "`n" + $work)
        $job.Async = $job.Ps.BeginInvoke()
        $job.Timer = New-Object System.Windows.Forms.Timer
        $job.Timer.Interval = 100
        $job.Timer.Add_Tick({ Receive-DeviceScan })
        $job.Timer.Start()
    } catch { Receive-DeviceScan -Failed }
}
function Receive-DeviceScan {
    param([switch]$Failed)
    $state = $script:deviceScanState; $job = $state.Active
    if (($state.Paused -and -not $Failed) -or -not $job -or (-not $Failed -and -not $job.Async.IsCompleted)) { return }
    $result = [pscustomobject]@{ Success = $false; Devices = @(); Connected = @(); Info = @{}; Error = '后台操作失败' }
    try {
        if (-not $Failed) {
            $items = @($job.Ps.EndInvoke($job.Async))
            if ($items.Count -eq 1) { $result = $items[0] }
        }
    } catch { $result.Error = $_.Exception.Message }
    finally {
        if ($job.Timer) { $job.Timer.Stop(); $job.Timer.Dispose() }
        if ($job.Ps) { $job.Ps.Dispose() }
        if ($job.Rs) { $job.Rs.Dispose() }
        $state.Active = $null
    }
    try {
        if (-not $state.Closing -and -not $job.Control.Cancelled -and (-not $job.Owner -or -not $job.Owner.IsDisposed)) {
            foreach ($key in $result.Info.Keys) { $script:devInfo[$key] = $result.Info[$key] }
            foreach ($addr in $result.Connected) { Touch-KnownDevice $addr (Get-FriendlyName $addr -CachedOnly) }
            if ($job.OnDone) { & $job.OnDone $result }
        }
    } finally {
        try { if ($job.OnFinally) { & $job.OnFinally } }
        finally { Start-NextDeviceScan }
    }
}
function Stop-DeviceScans {
    $state = $script:deviceScanState; $state.Closing = $true
    $jobs = @($state.Pending); $state.Pending.Clear()
    if ($state.Active) { $jobs+=$state.Active; $state.Active = $null }
    foreach ($job in $jobs) {
        if ($job.Control) {
            $job.Control.Cancelled = $true
            try { if ($job.Control.Process) { $job.Control.Process.Kill() } } catch {}
        }
        if ($job.Timer) { $job.Timer.Stop(); $job.Timer.Dispose() }
        if ($job.Ps) { try { $job.Ps.Stop() } catch {}; $job.Ps.Dispose() }
        if ($job.Rs) { $job.Rs.Dispose() }
        if ($job.OnFinally) { & $job.OnFinally }
    }
}

# 关闭局部对话框只取消它拥有的任务，不能停止其它设备的查询或共享 adb server。
function Cancel-OwnerTasks {
    param($Owner)
    $state = $script:deviceScanState
    foreach ($job in @($state.Pending)) {
        if ([object]::ReferenceEquals($job.Owner,$Owner)) {
            [void]$state.Pending.Remove($job)
            if ($job.OnFinally) { & $job.OnFinally }
        }
    }
    $job = $state.Active
    if ($job -and [object]::ReferenceEquals($job.Owner,$Owner)) {
        $job.Control.Cancelled = $true
        try { if ($job.Control.Process) { $job.Control.Process.Kill() } } catch {}
    }
}
function Wait-UiTask {
    param($Owner, [scriptblock]$Work, [hashtable]$Inputs = @{}, [string[]]$Functions = @(), [string]$Kind='operation')
    if ($script:deviceScanState.Closing -or ($Owner -and $Owner.IsDisposed)) {
        return [pscustomobject]@{ Success = $false; Cancelled = $true; Error = '操作已取消' }
    }
    $box = @{ Completed = $false; InsideClosing=$false; Result = [pscustomobject]@{ Success = $false; Cancelled = $true; Error = '操作已取消' } }
    $wait = New-Dialog '正在处理，请稍候…' 280 100 $Owner
    $wait.Controls.Add((New-Lbl '正在处理，请稍候…' 16 14))
    $cancel = New-SecondaryBtn '取消' 174 52 90 32
    $cancel.Add_Click({ $wait.Close() }.GetNewClosure())
    $wait.Controls.Add($cancel)
    New-EscCancel $wait
    $received = { param($value) $box.Result = $value }.GetNewClosure()
    $finished = {
        $box.Completed = $true
        if (-not $box.InsideClosing -and -not $wait.IsDisposed -and $wait.Visible) { $wait.Close() }
    }.GetNewClosure()
    $wait.Add_FormClosing({
        param($sender,$eventArgs)
        if (-not $box.Completed) {
            # 取消后等 worker 的 finally 真正结束，避免调用方提前 Dispose 它仍在使用的进程。
            $box.InsideClosing=$true
            try {
                Cancel-OwnerTasks $sender
                $eventArgs.Cancel=(-not $box.Completed)
                $cancel.Enabled=$false
            } finally { $box.InsideClosing=$false }
        }
    }.GetNewClosure())
    $wait.Add_FormClosed({ param($sender) Cancel-OwnerTasks $sender })
    try {
        Start-UiTask -Owner $wait -Kind $Kind -Work $Work -Inputs $Inputs -Functions $Functions -OnDone $received -OnFinally $finished
        # 回调直接捕获本函数的状态；避免在 Shown 的闭包里再捕获一次，丢失等待窗和结果引用。
        if (-not $box.Completed) {
            $modalOwner = if ($Owner -and $Owner.Visible) { $Owner } elseif ($form -and $form.Visible) { $form } else { $null }
            if ($modalOwner) { [void]$wait.ShowDialog($modalOwner) } else { [void]$wait.ShowDialog() }
        }
        return $box.Result
    } finally { $wait.Dispose() }
}
function Invoke-UiCommand {
    param($Owner, [string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutMs = 15000)
    return (Wait-UiTask -Owner $Owner -Inputs @{ FilePath = $FilePath; ArgumentList = $ArgumentList; TimeoutMs = $TimeoutMs } -Work {
        Invoke-ShortCommand -FilePath $Inputs.FilePath -ArgumentList $Inputs.ArgumentList -TimeoutMs $Inputs.TimeoutMs -Control $Control
    })
}
function Test-CommandSuccess {
    param($Result)
    return ($Result.Started -and $Result.ExitCode -eq 0 -and -not $Result.TimedOut -and -not $Result.Cancelled)
}
function Get-CommandDetail {
    param($Result)
    if ($Result.TimedOut) { return '操作超时，请稍后重试。' }
    if ($Result.Error) { return $Result.Error }
    return (@($Result.Stdout,$Result.Stderr) -join "`n").Trim()
}

function Invoke-ConnectDevices {
    param($Adb, [string[]]$Addresses, $Control, [int]$BudgetMs = 15000, [switch]$Probe)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    function Command {
        param([string[]]$Arguments,[int]$Limit = 3000)
        $left = $BudgetMs-[int]$clock.ElapsedMilliseconds
        if ($left -le 0) { return [pscustomobject]@{ Started = $false; TimedOut = $true; Cancelled = $false; ExitCode = $null; Error = '操作超时，请稍后重试。'; Stdout = ''; Stderr = '' } }
        Invoke-ShortCommand $Adb $Arguments -TimeoutMs ([Math]::Min($left,$Limit)) -Control $Control
    }
    $reachable = if ($Probe) { @(Get-ReachableAddrs $Addresses 3000) } else { @($Addresses) }
    $records = @()
    foreach ($addr in $Addresses) {
        if ($Control.Cancelled) { break }
        $record = [pscustomobject]@{ Address = $addr; Success = $false; State = $null; Error = '' }
        if ($reachable -notcontains $addr) { $record.State = ''; $record.Error = "电脑上探测不到 $addr（IP 或端口没有响应）。"; $records+=$record; continue }
        $connect = Command @('connect',$addr)
        $record.Error = Get-CommandDetail $connect
        $verify = [Diagnostics.Stopwatch]::StartNew()
        do {
            $devices = Command @('devices') 1000
            if (Test-CommandSuccess $devices) {
                if ($devices.Stdout -match 'List of devices attached') {
                    $record.State = Get-AdbDeviceState $addr -DeviceText $devices.Stdout -FromText
                } else { $record.State = $null }
            } else { $record.State = $null }
            if ($record.State -in @('device','unauthorized') -or $Control.Cancelled -or $clock.ElapsedMilliseconds -ge $BudgetMs) { break }
            Start-Sleep -Milliseconds 100
        } while ($verify.ElapsedMilliseconds -lt 3000)
        $record.Success = ($record.State -eq 'device')
        # 查询失败不能拆掉可能仍在录制的连接；只有明确的坏状态才清理本次地址。
        if ($record.State -in @('offline','unauthorized') -and -not $Control.Cancelled) { [void](Command @('disconnect',$addr) 1000) }
        if (-not $record.Success -and $clock.ElapsedMilliseconds -ge $BudgetMs) { $record.Error = '操作超时，请稍后重试。' }
        $records+=$record
    }
    [pscustomobject]@{ Records = @($records); Cancelled = [bool]$Control.Cancelled }
}
function Connect-DevicesUi {
    param($Owner,[string[]]$Addresses,[switch]$Probe)
    Wait-UiTask -Owner $Owner -Functions @('Invoke-ConnectDevices','Test-CommandSuccess','Get-CommandDetail','Get-AdbDeviceState') -Inputs @{
        Adb = $adb; Addresses = $Addresses; Probe = [bool]$Probe
    } -Work {
        Invoke-ConnectDevices -Adb $Inputs.Adb -Addresses $Inputs.Addresses -Probe:$Inputs.Probe -Control $Control
    }
}
function Invoke-PairDiscovery {
    param($Adb,$PairAddress,$Code,$Ip,$Control)
    $pair = Invoke-ShortCommand $Adb @('pair',$PairAddress,$Code) -TimeoutMs 7000 -Control $Control
    $result = [pscustomobject]@{ Paired = $false; Address = $null; Error = (Get-CommandDetail $pair); Cancelled = $pair.Cancelled }
    if (-not (Test-CommandSuccess $pair) -or ($pair.Stdout+$pair.Stderr) -notmatch 'Successfully paired') { return $result }
    $result.Paired = $true
    for ($i = 0; $i -lt 5 -and -not $Control.Cancelled; $i++) {
        $mdns = Invoke-ShortCommand $Adb @('mdns','services') -TimeoutMs 1000 -Control $Control
        if (Test-CommandSuccess $mdns) {
            foreach ($line in ($mdns.Stdout -split "`r?`n")) {
                if ($line -match '_adb-tls-connect\._tcp\.?\s+' -and $line -match ('(?<![\d.])'+[regex]::Escape($Ip)+':(\d+)(?=\s|$)')) {
                    $port = [int]$matches[1]
                    if ($port -ge 1 -and $port -le 65535) { $result.Address = $Ip+':'+$port; return $result }
                }
            }
        }
        Start-Sleep -Milliseconds 300
    }
    $result.Cancelled = [bool]$Control.Cancelled
    return $result
}

function Test-ProcessExited {
    param($Process)
    if (-not $Process) { return $true }
    try { return $Process.HasExited } catch { return $false }
}
function Wait-ScrcpyExit {
    param($Process,[int]$WaitMs,$Control)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-ProcessExited $Process) -and $clock.ElapsedMilliseconds -lt $WaitMs) {
        if ($Control -and $Control.Cancelled) { return $false }
        try { [void]$Process.WaitForExit([Math]::Min(50,[Math]::Max(1,$WaitMs-[int]$clock.ElapsedMilliseconds))) }
        catch { return $false }
    }
    return (Test-ProcessExited $Process)
}
function Invoke-StopItems {
    param($Items,$Adb,[string[]]$Disconnect,$Control,[switch]$Force,[int]$WaitMs=5000)
    $results=@()
    $clock=[Diagnostics.Stopwatch]::StartNew()
    foreach ($item in $Items) {
        if ($Control.Cancelled) { break }
        $outcome='Exited'; $errorText=''; $sent=[bool]$item.StopSignalSent
        if (-not (Test-ProcessExited $item.Proc)) {
            if ($Force) {
                try {
                    $item.Proc.Kill()
                    $item.Forced=$true
                    $outcome=if (Wait-ScrcpyExit $item.Proc 1000 $Control) { 'Killed' } else { 'TimedOut' }
                } catch { $outcome='Failed'; $errorText=$_.Exception.Message }
            } else {
                $left=[Math]::Max(0,[Math]::Min($WaitMs,15000-[int]$clock.ElapsedMilliseconds))
                if ($item.Rec) {
                    $stopped=Stop-ScrcpyGraceful $item.Proc $left $Control -WaitOnly:$sent
                    $sent=$sent -or $stopped.SignalSent
                    $item.StopSignalSent=$sent
                    $errorText=$stopped.Error
                    $outcome=if ($stopped.Exited) { 'Stopped' } else { 'TimedOut' }
                } else {
                    try { [void]$item.Proc.CloseMainWindow() } catch { $errorText=$_.Exception.Message }
                    $outcome=if (Wait-ScrcpyExit $item.Proc ([Math]::Min(1000,$left)) $Control) { 'Stopped' } else { 'TimedOut' }
                }
            }
        }
        if ($Control.Cancelled -and -not (Test-ProcessExited $item.Proc)) { $outcome='Cancelled' }
        $exitCode=$null
        if (Test-ProcessExited $item.Proc) { try { if ($item.Proc) { $exitCode=$item.Proc.ExitCode } } catch {} }
        $results += [pscustomobject]@{ Item=$item; Outcome=$outcome; SignalSent=$sent; ExitCode=$exitCode; Error=$errorText }
    }
    $pending=@($Items | Where-Object { -not (Test-ProcessExited $_.Proc) })
    $errorText=''
    # 仍有活进程时不能 disconnect，否则会中断尚未写完的录制。
    if ($pending.Count -eq 0 -and -not $Control.Cancelled) {
        foreach ($addr in $Disconnect) {
            if ($Control.Cancelled) { break }
            $left=15000-[int]$clock.ElapsedMilliseconds
            if ($left -le 0) { $errorText='操作超时，请稍后重试。'; break }
            $command=Invoke-ShortCommand $Adb @('disconnect',$addr) -TimeoutMs ([Math]::Min(3000,$left)) -Control $Control
            if (-not (Test-CommandSuccess $command)) { $errorText=Get-CommandDetail $command }
        }
    }
    [pscustomobject]@{
        Results=@($results); Pending=@($pending); Cancelled=[bool]$Control.Cancelled
        Success=($pending.Count -eq 0 -and -not $errorText -and -not $Control.Cancelled); Error=$errorText
    }
}
function Stop-DevicesUi {
    param($Owner,[string[]]$Serials,[switch]$Disconnect,[object[]]$Items,[switch]$All,[switch]$ForExit)
    if (-not $PSBoundParameters.ContainsKey('Items')) {
        $Items=@($scrcpyProcs | Where-Object { $All -or $Serials -contains $_.Serial })
    }
    $Items=@($Items)
    if ($Items.Count -eq 0 -and -not $Disconnect) {
        Update-ProcessLifecycle
        return [pscustomobject]@{ Success=$true; Cancelled=$false; Results=@(); Pending=@(); Error='' }
    }
    if (@($Items | Where-Object { $_.StopInProgress }).Count) {
        return [pscustomobject]@{ Success=$false; Cancelled=$true; Error='正在停止，请稍候。' }
    }
    $sessions=@($script:camSessions | Where-Object {
        $session=$_
        @($Items | Where-Object { [object]::ReferenceEquals($_.Proc,$session.Proc) }).Count -gt 0
    })
    $previous=@($sessions | ForEach-Object { [pscustomobject]@{ Session=$_; Stopped=$_.Stopped } })
    foreach ($session in $sessions) { $session.Stopped=$true }
    foreach ($item in $Items) {
        if (-not $item.PSObject.Properties['StopSignalSent']) { $item | Add-Member StopSignalSent $false }
        if (-not $item.PSObject.Properties['StopInProgress']) { $item | Add-Member StopInProgress $false }
        if (-not $item.PSObject.Properties['ExitReported']) { $item | Add-Member ExitReported $false }
        if (-not $item.PSObject.Properties['Forced']) { $item | Add-Member Forced $false }
        $item.StopInProgress=$true
    }
    $addresses=if ($Disconnect) { @($Serials | Where-Object { Test-Wireless $_ }) } else { @() }
    $pending=@($Items); $force=$false
    $forcedRecording=$false
    $recordingError=$false
    $result=[pscustomobject]@{ Success=$false; Cancelled=$true; Error='' }
    try {
        do {
            $result=Wait-UiTask -Owner $Owner -Kind $(if ($ForExit) { 'shutdown' } else { 'operation' }) -Functions @(
                'Invoke-StopItems','Stop-ScrcpyGraceful','Wait-ScrcpyExit','Test-ProcessExited','Test-CommandSuccess','Get-CommandDetail'
            ) -Inputs @{ Items=$pending; Adb=$adb; Disconnect=$addresses; Force=$force } -Work {
                Invoke-StopItems $Inputs.Items $Inputs.Adb $Inputs.Disconnect $Control -Force:$Inputs.Force
            }
            foreach ($stopped in $result.Results) {
                $stopped.Item.StopSignalSent=$stopped.SignalSent
                if ($stopped.Item.Rec -and $stopped.Outcome -ne 'Killed' -and $null -ne $stopped.ExitCode -and $stopped.ExitCode -ne 0) { $recordingError=$true }
                if ($stopped.Outcome -eq 'Killed') {
                    $stopped.Item.Forced=$true
                    if ($stopped.Item.Rec) { $forcedRecording=$true }
                    [void](Add-ErrorLog '强制结束进程' ("设备：{0}；退出码：{1}；录屏：{2}" -f $stopped.Item.Serial,$stopped.ExitCode,$stopped.Item.Rec))
                }
            }
            if ($result.Cancelled) { break }
            $pending=@($Items | Where-Object { -not (Test-ProcessExited $_.Proc) })
            if ($pending.Count -eq 0) {
                if (-not $result.Success) { [void](Show-ResultDialog $Owner '停止投屏' '操作未完成' '可以稍后重试。' $result.Error @('ok')) }
                break
            }
            $detail=(@($pending | ForEach-Object { "设备：$($_.Serial)" }) -join "`n")
            $errors=@($result.Results | Where-Object { $_.Error } | ForEach-Object { "{0}：{1}" -f $_.Item.Serial,$_.Error })
            if ($errors.Count) { $detail += "`n" + ($errors -join "`n") }
            $heading=if (@($result.Results | Where-Object { $_.Outcome -eq 'Failed' }).Count) { '强制结束失败' } else { '进程尚未正常结束' }
            $choice=Show-ResultDialog $Owner '停止投屏' $heading '强制结束可能导致视频文件损坏或无法播放。可以继续等待，或取消本次停止。' $detail @('wait','force','cancel')
            if ($choice -eq 'cancel' -or $choice -notin @('wait','force')) {
                $result=[pscustomobject]@{ Success=$false; Cancelled=$true; Error='' }
                break
            }
            $force=($choice -eq 'force')
        } while ($pending.Count -gt 0)
        $forcedRecording=(@($Items | Where-Object { $_.Rec -and $_.Forced }).Count -gt 0)
        if ($forcedRecording) {
            [void](Show-ResultDialog $Owner '录制屏幕' '已强制结束录屏，请检查视频文件。' '强制结束可能导致视频文件损坏或无法播放。' '' @('ok'))
        }
        if ($recordingError -and -not $forcedRecording) {
            [void](Show-ResultDialog $Owner '录制屏幕' '录屏异常结束，请检查视频文件。' '请确认录屏文件能正常播放。' '' @('ok'))
        }
        if ($recordingError -or $forcedRecording) { foreach ($item in $Items) { $item.ExitReported=$true } }
        return $result
    } finally {
        foreach ($item in $Items) { $item.StopInProgress=$false }
        foreach ($entry in $previous) {
            if (-not (Test-ProcessExited $entry.Session.Proc)) { $entry.Session.Stopped=$entry.Stopped }
        }
        Update-ProcessLifecycle
    }
}

$script:closeState=@{ InProgress=$false }
function Confirm-AppExit {
    param($Owner)
    return ([System.Windows.Forms.MessageBox]::Show($Owner,"正在录屏。关闭助手会先尝试正常停止录制。`n`n确定要关闭吗？`n（想继续录、只收起助手，点最小化即可）",'正在录屏','YesNo','Warning') -eq 'Yes')
}
function Request-AppClose {
    param($Owner,$EventArgs,[scriptblock]$OnResume)
    $EventArgs.Cancel=$true
    if ($script:closeState.InProgress) { return }
    $script:closeState.InProgress=$true
    $script:deviceScanState.Paused=$true
    $quiesced=$false
    try {
        Update-ProcessLifecycle
        if ((Test-Recording) -and -not (Confirm-AppExit $Owner)) { return }
        $addresses=@(@($script:knownDevices.Keys) + @($scrcpyProcs | ForEach-Object { $_.Serial }) |
            Where-Object { Test-Wireless $_ } | Select-Object -Unique)
        Stop-DeviceScans
        $quiesced=$true
        # 旧查询已取消；只允许 shutdown 任务运行，用户取消退出后可重新发起普通查询。
        $script:deviceScanState.Closing=$false
        $script:deviceScanState.Paused=$false
        $stopped=Stop-AllScrcpy $Owner
        if (-not $stopped.Success) { return }
        if ($settings.disconnectOnClose -and $addresses.Count) {
            $disconnected=Wait-UiTask -Owner $Owner -Kind 'shutdown' -Inputs @{ Adb=$adb; Addresses=$addresses } -Work {
                $clock=[Diagnostics.Stopwatch]::StartNew()
                foreach ($addr in $Inputs.Addresses) {
                    if ($Control.Cancelled -or $clock.ElapsedMilliseconds -ge 15000) { break }
                    [void](Invoke-ShortCommand $Inputs.Adb @('disconnect',$addr) -TimeoutMs ([Math]::Max(1,[Math]::Min(3000,15000-[int]$clock.ElapsedMilliseconds))) -Control $Control)
                }
                [pscustomobject]@{ Cancelled=[bool]$Control.Cancelled }
            }
            if ($disconnected.Cancelled) { return }
        }
        if ($Owner.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal) {
            if ($settings.winX -ne $Owner.Location.X -or $settings.winY -ne $Owner.Location.Y) {
                $settings.winX=$Owner.Location.X; $settings.winY=$Owner.Location.Y; Save-Settings
            }
        }
        Update-ProcessLifecycle
        $EventArgs.Cancel=$false
    } finally {
        if ($EventArgs.Cancel) {
            $script:closeState.InProgress=$false
            $script:deviceScanState.Paused=$false
            $script:deviceScanState.Closing=$false
            if ($quiesced -and -not $Owner.IsDisposed) {
                Set-BusyLook -On $false
                $Owner.Cursor=[System.Windows.Forms.Cursors]::Default
                $script:hintHeld=$false
                if ($script:recHintColor) { & $script:restoreHint }
                if ($OnResume) { & $OnResume }
            }
        }
    }
}

# 「独立窗口」可一键打开的最常用 App（按使用度排，购物类靠后）；其余 App 用「更多应用…」从手机列表里挑
$apps = [ordered]@{
    '微信'   = 'com.tencent.mm'
    '抖音'   = 'com.ss.android.ugc.aweme'
    'QQ'     = 'com.tencent.mobileqq'
    '淘宝'   = 'com.taobao.taobao'
    '拼多多' = 'com.xunmeng.pinduoduo'
}

# ---------------- 设置（改完点「保存」才写进 投屏助手-设置.json） ----------------
# 设置窗口里的改动只停在控件上：点「保存」才落盘，点「取消」丢弃。
# 设置窗口之外的即时选择（设备重命名、常用 App、摄像头面板的分辨率/倍率/前后置/横竖屏/倒置修正/补光灯/麦克风、
# 独立窗口的比例与声音）当场就存。
# 用 [ordered] 有序表：保存出来的 JSON 键顺序就按下面的分组排（画面/声音/控制/…），不再是哈希随机序、看着乱。
$defaults = [ordered]@{
    # 画面
    maxSize = 1496; maxFps = 0; bitRate = 0; videoCodec = ''; crop = ''; hwDec = ''; ignoreEncoderConstraints = $false
    # 声音
    audioOn = $true; audioSource = ''; audioCodec = ''
    # 控制
    keyboard = ''; mouse = ''; gamepad = $false; noControl = $false
    screenOff = $false; stayAwake = $true; showTouches = $false; powerOffOnClose = $false
    # 摄像头（存“最大边长档位”如 1920/1280/0，或实测精确尺寸如 1920x1080；统一按字符串存，避免重载时类型转换报错）
    camResMax = '1920'
    # 摄像头初始倍率的全局兜底（换设备、没记录时用）；具体倍率同样按设备+前后记在 camResByDevice（键带 |zoom 后缀）
    camZoom = '1'
    # 摄像头面板上次的选择（全局偏好）：前后置 back/front、方向 land/port、倒置修正、补光灯、麦克风。分辨率另按设备+前后记在 camResByDevice。
    camFacing = 'back'; camOrientation = 'land'; camTorch = $false; camMic = $false
    camRotate180 = $false
    # 窗口
    fullscreen = $false; onTop = $false; borderless = $false; minToTray = $false
    # 独立窗口
    ndSize = ''; ndDpi = ''; ndNoDecor = $false; ndMode = 'settings'; ndFixed = $false; ndAudio = 'auto'
    # 录制
    recFormat = 'mp4'; recTimeLimit = 0; recBackground = $false
    # 通用
    liveStatus = $true; autoConnect = $true; disconnectOnClose = $false; extraArgs = ''; lastWirelessAddr = ''; defaultDevice = ''
    # 自定义 adb / scrcpy 可执行文件路径（留空=用本助手同目录自带的）；在「设置 > 通用」里改，随设置存进 JSON
    scrcpyPath = ''; adbPath = ''
    # 记住主窗口位置（-1 = 还没记，居中显示）
    winX = -1; winY = -1
    # 控制台
    showConsole = $false
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
    $ErrorActionPreference = 'Stop'
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
    } catch {
        $detail = $_.Exception.Message
        try {
            Add-Content -LiteralPath (Join-Path $PSScriptRoot '投屏助手-错误日志.txt') -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] 保存设置失败：$detail" -Encoding UTF8
        } catch {}
        [System.Windows.Forms.MessageBox]::Show("保存设置失败，本次修改仅在当前运行中生效。请确认软件目录可写。`n`n$detail", '保存设置失败') | Out-Null
    }
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
    $msg = "没找到 scrcpy.exe。`n`n正常情况下它应和本程序放在同一个文件夹里。`n如果你想用电脑里别处的 scrcpy，可点「是」选择它的位置。`n（选好后会记住，下次直接用；也可随时在「设置 > 通用」里改。）"
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
# 解码方式：不选就什么都不传（scrcpy 自己优先用显卡解码，显卡解不了它会回落软件解码）。
# 选「软件解码」= --hwdec=disabled，是画面花屏/偏色/黑屏时排除显卡兼容问题的开关。
# 摄像头、独立窗口两段自己拼参数数组、不走 Get-VideoArgs，所以它们要单独带上这个（录制走 Get-VideoArgs，已覆盖）。
function Get-HwDecArgs {
    if ($settings.hwDec) { return @("--hwdec=$($settings.hwDec)") }
    return @()
}
function Get-VideoArgs {
    $a = @()
    if ([int]$settings.maxSize -gt 0) { $a += @('-m', "$($settings.maxSize)") }
    if ([int]$settings.maxFps  -gt 0) { $a += "--max-fps=$($settings.maxFps)" }
    if ([int]$settings.bitRate -gt 0) { $a += "--video-bit-rate=$($settings.bitRate)M" }
    if ($settings.videoCodec)         { $a += "--video-codec=$($settings.videoCodec)" }
    if ($settings.crop)               { $a += "--crop=$($settings.crop)" }
    $a += @(Get-HwDecArgs)
    # 忽略机型上报的编码器分辨率约束(含对齐)：某些机型上报值不准，导致分辨率/独立窗口选不对时的兜底。scrcpy 4.1+ 参数。
    if ($settings.ignoreEncoderConstraints) { $a += '--ignore-video-encoder-constraints' }
    return $a
}
function Get-AudioArgs {
    if (-not $settings.audioOn) { return @('--no-audio') }
    $a = @()
    if ($settings.audioSource) { $a += "--audio-source=$($settings.audioSource)" }
    if ($settings.audioCodec)  { $a += "--audio-codec=$($settings.audioCodec)" }
    return $a
}
function Get-RecordingExtension {
    # PCM 无法封装进 MP4；关闭音频时不应受此前保存的音频编码影响。
    if ($settings.videoCodec -in @('vp8', 'vp9') -or ($settings.audioOn -and $settings.audioCodec -eq 'raw')) { return 'mkv' }
    return [string]$settings.recFormat
}
function Get-ControlArgs {
    param([bool]$Wireless)
    if ($settings.noControl) { return @('--no-control') }
    $a = @()
    if ($settings.keyboard)    { $a += "--keyboard=$($settings.keyboard)" }
    if ($settings.mouse)       { $a += "--mouse=$($settings.mouse)" }
    if ($settings.gamepad)     { $a += '--gamepad=uhid' }
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
    # 每段都必须 @() 包一层：PowerShell 的 return 会把「只剩一个元素的数组」拆成字符串，
    # 而「字符串 + 数组」是字符串拼接（数组按空格连成一串接在后面），不是数组相加。
    # 于是清晰度/帧率/画质都关掉、视频段只剩一个参数时，会拼出
    # 「--video-codec=av1--gamepad=uhid --turn-screen-off --keep-active」这种粘连的单个参数，scrcpy 报「不支持的编码」。
    return @(Get-VideoArgs) + @(Get-AudioArgs) + @(Get-ControlArgs -Wireless:$Wireless) + @(Get-WindowArgs)
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
# 摄像头画面方向的基准角。--capture-orientation 只在采集流上叠加旋转，不会替我们补偿前后置摄像头之间
# 那 180° 的差异（前置镜头在机身另一面，传感器方向与后置相反），所以基准角必须自己算对：
#   竖屏：后置 90°、前置 270°——真机实测过（「摄像头前置竖屏方向修正」那次改动）。
#   横屏：手机转 90°，前后置的原始画面一起转 90°，两者之间那 180° 的差并不变 → 后置 0°、前置 180°。
#     ← 这一格是按上面那条 180° 差推出来的，还没单独在真机上验过（以前横屏一律不传参数，等于漏了这半圈）。
#       要确认的话：选前置 + 横屏，看画面是不是正的；不对就把这里的 180 改回 0。
# $rotate180 = 面板上的「旋转 180°（倒置修正）」：手机整个倒过来放时画面跟着转半圈，在基准角上再叠 180°。
function Get-CamOrientationArgs {
    param([string]$facing, [bool]$portrait, [bool]$rotate180)
    $rotation = if ($portrait) {
        if ($facing -eq 'front') { 270 } else { 90 }
    } else {
        if ($facing -eq 'front') { 180 } else { 0 }
    }
    if ($rotate180) { $rotation = ($rotation + 180) % 360 }
    if ($rotation -eq 0) { return @() }
    return @("--capture-orientation=$rotation")
}
# 运行 scrcpy --list-camera-sizes，按朝向解析出本机真正支持的采集分辨率。
# 不同机型差别很大，写死 1080p 之类会触发 “Camera configuration error”（录像支持 ≠ 投屏采集支持），
# 所以运行时按设备实拉，避免把其它镜头的尺寸放入选项。任何失败都返回空表，调用方自行回退到通用档位。
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
# 初始倍率记忆：跟采集尺寸共用 camResByDevice，键多个 |zoom 后缀区分，省一套加载/保存代码（两处都按整表遍历读写）。
# 倍率一律按不变文化格式化成字符串（1.5 而非德语区的 1,5），否则拼进命令行 scrcpy 解析不了。
function Format-Zoom { param($v) return ([double]$v).ToString('0.##', [cultureinfo]::InvariantCulture) }
function Get-CamZoom {
    param($serial, $facing)
    $k = "$serial|$facing|zoom"
    if ($script:camResByDevice.Contains($k)) { return [double]$script:camResByDevice[$k] }
    return [double]$settings.camZoom
}
function Set-CamZoom {
    param($serial, $facing, $zs)
    if ($serial) { $script:camResByDevice["$serial|$facing|zoom"] = [string]$zs }
    $settings.camZoom = [string]$zs
}

function Get-CameraSizes {
    param([string]$serial, $Owner=$form)
    if ($serial -and $script:camSizesCache.ContainsKey($serial)) { return $script:camSizesCache[$serial] }   # 同一台设备本会话缓存
    $result = @{ back = @(); front = @(); zoom = @{ back = $null; front = $null }; ids = @{ back=$null; front=$null } }
    try {
        $argv = @(); if ($serial) { $argv += @('-s', $serial) }; $argv += '--list-camera-sizes'
        $command=Invoke-UiCommand $Owner $exe $argv
        if ($command.Cancelled) { return $null }
        $out=if (Test-CommandSuccess $command) { $command.Stdout + "`n" + $command.Stderr } else { '' }
    } catch { return $result }
    if (-not $out) { return $result }
    $facing=$null
    $seen=@{ back=$false; front=$false }
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -match '--camera-id=(?<id>.+?)\s*\(') {
            $id=$matches['id'].Trim('"')
            $facing=$null
            # 同朝向的其它镜头与外接镜头不能补充当前镜头的尺寸或倍率。
            if ($line -match '\(\s*(front|back)\b') {
                $direction=$matches[1]
                if (-not $seen[$direction]) {
                    $seen[$direction]=$true
                    $facing=$direction
                    $result.ids[$facing]=$id
                    if ($line -match 'zoom-range=\[\s*([\d.]+)\s*,\s*([\d.]+)\s*\]') {
                        $result.zoom[$facing]=@([double]$matches[1],[double]$matches[2])
                    }
                }
            }
            continue
        }
        if ($line -match '--camera-id=') { $facing=$null; continue }
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

function Get-CameraSelectionArgs {
    param($Sizes,[string]$Facing)
    $id=if ($Sizes -and $Sizes.ids) { [string]$Sizes.ids[$Facing] } else { '' }
    if ($id) { return @("--camera-id=$id") }
    return @("--camera-facing=$Facing")
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
        $outputs=Wait-UiTask -Owner $form -Inputs @{ Adb=$adb; Size=$szArgs; Density=$dnArgs } -Work {
            $size=Invoke-ShortCommand $Inputs.Adb $Inputs.Size -TimeoutMs 7000 -Control $Control
            $density=Invoke-ShortCommand $Inputs.Adb $Inputs.Density -TimeoutMs 7000 -Control $Control
            [pscustomobject]@{ Size=$size; Density=$density }
        }
        if ($outputs.Cancelled) { return @{ Cancelled=$true } }
        $szOut=if (Test-CommandSuccess $outputs.Size) { $outputs.Size.Stdout } else { '' }
        $dnOut=if (Test-CommandSuccess $outputs.Density) { $outputs.Density.Stdout } else { '' }
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

# 一个常驻的空文件，专给摄像头 scrcpy 当 stdin（-RedirectStandardInput 需要真实存在的文件路径；空文件=立刻 EOF，
# 让 scrcpy 退出时的「Press Enter to continue…」读到 EOF 直接返回、不卡）。只在第一次用到时建，之后复用。
$script:nulStdinPath = $null
function Get-NulStdin {
    if ($script:nulStdinPath -and (Test-Path -LiteralPath $script:nulStdinPath)) { return $script:nulStdinPath }
    $pth = Join-Path $env:TEMP 'scrcpy-helper-nul-stdin.txt'
    try { if (-not (Test-Path -LiteralPath $pth)) { Set-Content -LiteralPath $pth -Value '' -NoNewline -Encoding ascii } } catch {}
    $script:nulStdinPath = $pth
    return $pth
}

# 启动 scrcpy（不阻塞界面；自动过滤空参数）
function Start-Scrcpy {
    param(
        [string[]]$Options,
        [switch]$Recording,
        [switch]$PassThru,
        [string]$StderrFile,
        [string]$StdoutFile,
        # 本窗口声音：Auto=同设备已有出声窗口时自动静音（默认）；On=强制出声；Off=强制静音
        [ValidateSet('Auto', 'On', 'Off')][string]$AudioMode = 'Auto'
    )
    $extra = @(); if ($settings.extraArgs) { $extra = @($settings.extraArgs -split '\s+' | Where-Object { $_ }) }
    $clean = @(($Options + $extra) | Where-Object { $_ -ne '' -and $null -ne $_ })
    $Recording=[switch]($Recording -or @($clean | Where-Object { $_ -eq '-r' -or $_ -eq '--record' -or $_ -like '--record=*' }).Count -gt 0)
    $isCamera = @($clean | Where-Object { $_ -like '--video-source=camera*' }).Count -gt 0
    # 解析目标设备序列号（来自 -s），用于「投屏中」标记 / 「停止这台」，并据此给窗口起友好标题
    $serial = ''
    for ($i = 0; $i -lt $clean.Count - 1; $i++) { if ($clean[$i] -eq '-s') { $serial = $clean[$i + 1]; break } }
    $winTitle = ''
    $hadTitle = @($clean | Where-Object { $_ -like '--window-title=*' })
    if ($hadTitle.Count) {
        $winTitle = [string]$hadTitle[0] -replace '^--window-title=', ''
    } elseif ($serial) {
        # 标题去空格（Windows PowerShell 的 Start-Process 数组传参对带空格的参数引号处理不可靠）
        $title = (Get-FriendlyName $serial) -replace '\s+', '-'
        if ($title) {
            # 设备名/App 名可能含引号或换行；标题最终进命令行，先去掉不可控字符
            $title = $title -replace '[\r\n\x00-\x1F"]', ''
            if ($Recording) { $title = "$title · 录制" }   # 录屏窗口一眼可辨，避免和普通投屏窗同名
            elseif ($isCamera) { $title = "$title · 摄像头" }   # 摄像头窗口同理，和普通投屏区分
            $clean += "--window-title=$title"; $winTitle = $title
        }
    }
    # 声音三态：Off=强制静音；On=用户显式选了「播放」，不参与多开去重（但已有窗口出声时会提示可能重音）；
    # Auto=同一台手机只保留第一路在电脑出声——scrcpy 捕获整机一路混音，与主屏幕/虚拟屏无关，
    # 同设备开第二个会话等于把同一份声音再播一遍，音量叠加、发重音。
    # --no-playback（后台录制）不在电脑播放，不占位也不参与判定。
    # 录制会话(-Recording)即使传了模式也不静音：--no-audio 会连录进文件的声音一起掐掉，宁可短暂多播一路也不能毁录音。
    if ($AudioMode -eq 'Off' -and -not $Recording -and -not @($clean | Where-Object { $_ -eq '--no-audio' }).Count) { $clean += '--no-audio' }
    $playsAudio = (@($clean | Where-Object { $_ -eq '--no-audio' -or $_ -eq '--no-playback' }).Count -eq 0)
    if ($serial -and $playsAudio -and -not $Recording) {
        $otherLive = $false
        foreach ($it in @($scrcpyProcs)) {
            if ($it.Serial -ne $serial -or -not $it.Audio) { continue }
            try { if ($it.Proc -and -not $it.Proc.HasExited) { $otherLive = $true; break } } catch {}
        }
        if ($otherLive) {
            if ($AudioMode -eq 'Auto') {
                $clean += '--no-audio'; $playsAudio = $false
                if ($script:showTempHint) { & $script:showTempHint '这台手机已有窗口在出声，本窗口已静音（防重音）' $cMuted 8000 }
            }
            elseif ($AudioMode -eq 'On') {
                # 麦克风输入（摄像头面板）与媒体外放叠加是回声/啸叫风险，不是普通重音，分开提示
                $onHint = if (@($clean | Where-Object { $_ -like '--audio-source=*mic*' }).Count) { '麦克风已开，与已有窗口可能回声，建议戴耳机' } else { '本窗口强制播放声音，与已有窗口同时出声会有重音' }
                if ($script:showTempHint) { & $script:showTempHint $onHint $cMuted 8000 }
            }
        }
    }
    # Start-Process 数组传参不会给「含空格的参数」加引号——会把录屏路径 C:\My Videos\x.mp4 拆成多段、
    # 让 scrcpy 收到的 -r 路径残缺、录屏失败。这里自己给含空格/引号的参数补引号，整体作为命令行串传。
    $cmd = (@($clean | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')
    # StderrFile：摄像头看门狗要靠 stderr 里的报错分类「被抢 / 带不动 / 不明原因」，只对摄像头会话把 stderr 落到文件。
    # scrcpy 是控制台程序：一旦 -RedirectStandardError（=UseShellExecute 关）就会继承本助手的控制台，退出时触发它
    # Windows 版自带的「Press Enter to continue…」暂停——进程卡着不退、还冒出黑窗，看门狗误判成异常又反复重开。
    # 两道一起下才干净：① -RedirectStandardInput 指到一个空文件 → scrcpy 那次 getchar 立刻读到 EOF，不等回车；
    # ② -WindowStyle Hidden → 不弹控制台窗。stderr 落文件由 OS 直接写（不占管道缓冲，避免 scrcpy 刷不动 stderr 卡死）。
    # 普通投屏路径(elseif/else 分支)是 ShellExecute：若 scrcpy.exe 还带「网络来源」标记、SmartScreen 弹窗被用户取消，
    # Start-Process 会抛 ERROR_CANCELLED「操作已被用户取消」。这里提示用户自行确认来源并放行：
    # 万一仍被拦下并取消，给句人话提示而不是让异常冒成崩溃窗/静默无反应。摄像头带 -RedirectStandardError 那支是 UseShellExecute=$false，不触发。
    $p = $null
    try {
        $winStyle = if ($settings.showConsole) { 'Normal' } else { 'Hidden' }
        # StdoutFile 只有摄像头会话传：scrcpy 的 INFO 级日志（含每次变焦的 "Set camera zoom: 3.16"）走的是 stdout，
        # ERROR/WARN 才走 stderr——两路分开落两个文件，看门狗读 stderr 判病因，倍率回传读 stdout。
        $p = if ($cmd -and $StderrFile -and $StdoutFile) { Start-Process -FilePath $exe -ArgumentList $cmd -WorkingDirectory $PSScriptRoot -PassThru -RedirectStandardError $StderrFile -RedirectStandardOutput $StdoutFile -RedirectStandardInput (Get-NulStdin) -WindowStyle $winStyle }
        elseif ($cmd -and $StderrFile) { Start-Process -FilePath $exe -ArgumentList $cmd -WorkingDirectory $PSScriptRoot -PassThru -RedirectStandardError $StderrFile -RedirectStandardInput (Get-NulStdin) -WindowStyle $winStyle }
        elseif ($cmd) { Start-Process -FilePath $exe -ArgumentList $cmd -WorkingDirectory $PSScriptRoot -PassThru -WindowStyle $winStyle}
        else { Start-Process -FilePath $exe -WorkingDirectory $PSScriptRoot -PassThru -WindowStyle $winStyle }
    } catch {
        if ($script:showTempHint) { & $script:showTempHint '投屏被安全提示拦下：点弹窗里「更多信息」>「仍要运行」' $cRed 12000 }
        try { $lp = Join-Path $PSScriptRoot '投屏助手-错误日志.txt'; Add-Content -LiteralPath $lp -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Start-Scrcpy 启动失败: $($_.Exception.Message)`r`n" -Encoding UTF8 } catch {}
        return
    }
    # Audio=本会话是否在电脑上出声（被自动静音的新会话记 false，供后续同设备会话判定「是否已有出声窗口」）
    if (-not $p) { return }
    $entry=[pscustomobject]@{ Proc=$p; Rec=[bool]$Recording; Serial=$serial; Audio=[bool]$playsAudio; Starting=$true; StopInProgress=$false; StopSignalSent=$false; Forced=$false; ExitReported=$false }
    [void]$scrcpyProcs.Add($entry)
    try {
        if ($PassThru) { $p }
        # 三类不在此等待：摄像头会话有看门狗负责反馈；后台录制本来就没有窗口；勾了「显示控制台」的用户已经在看输出
        if ($StderrFile -and $StdoutFile) { return }
        if (@($clean | Where-Object { $_ -eq '--no-playback' }).Count) { return }
        if ($settings.showConsole) { return }
        if ($script:showTempHint) { & $script:showTempHint '正在打开投屏窗口…' $cMuted $null; $script:hintHeld = $true }
        if ((Wait-ScrcpyWindow $p $winTitle) -ne 'exited') { return }
        $code = try { $p.ExitCode } catch { '未知' }
        [void](Show-ResultDialog $form '投屏' '投屏窗口没能打开' '多半是数据线松了、手机刚锁屏，或这台正被别的地方占用。重新插一下、点亮屏幕再点一次；反复如此的话，到「设置 > 常用」勾「显示 scrcpy 控制台窗口」，就能看到具体原因。' ("命令：scrcpy.exe $cmd`r`n退出码：$code") @('ok'))
    } finally { $entry.Starting=$false }
}

# 进程起来 ≠ 画面出来：实测 scrcpy 从启动到窗口可见还要 0.9~1.5 秒（无线更慢），
# 这段时间界面已经恢复正常，用户完全不知道成没成。这里等窗口真出现再把忙态交回去；
# 等不到且进程已退 = 明确失败，给一句人话并把命令与退出码收进「查看原因」，不再静默。
# 判"窗口出现"：按我们自己设的 --window-title 用 EnumWindows 逐个比标题 + 可见性 + 进程 id。
# 两个代理方案实测都不行：Process.MainWindowHandle 对秒退的 cmd、隐藏控制台的 powershell 也立刻报"有窗口"；
# FindWindow 按标题找在部分宿主里恒返回 0（本脚本开头「单实例」那一段的兜底激活就吃过这个亏）。
# 同一台手机已经开着同名窗口时不等——那一屏本来就看得见，硬等还会把旧窗口误判成本次的成功。
function Test-WindowShown {
    param([string]$Title, [int]$ProcId)
    # 回调里只能读 \$script: 变量：EnumWindows 是从原生代码反过来调这个 scriptblock，
    # 它看不到本函数的局部 \$Title/\$ProcId/\$hit（实测恒不匹配、还静默抛异常）。
    $script:twTitle = $Title; $script:twPid = $ProcId
    $script:twHit = New-Object System.Collections.ArrayList
    $cb = [Native.Win+EnumWinProc]{ param($h, $l)
        $sb = New-Object System.Text.StringBuilder 512
        [void][Native.Win]::GetWindowTextW($h, $sb, 512)
        if ($sb.ToString() -eq $script:twTitle -and [Native.Win]::IsWindowVisible($h)) {
            $p = 0
            [void][Native.Win]::GetWindowThreadProcessId($h, [ref]$p)
            if ([int]$p -eq $script:twPid) { [void]$script:twHit.Add($h) }
        }
        return $true
    }
    [void][Native.Win]::EnumWindows($cb, [IntPtr]::Zero)
    return $script:twHit.Count -gt 0
}
function Wait-ScrcpyWindow {
    param($Proc, [string]$Title, [int]$TimeoutSec = 6)
    if (-not $Proc -or -not $Title) { return 'nowait' }
    $pid_ = 0
    try { $pid_ = [int]$Proc.Id } catch { return 'nowait' }
    if ($pid_ -le 0 -or (Test-WindowShown $Title $pid_)) { return 'nowait' }   # 已有同名窗口：不重复等
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if (Test-WindowShown $Title $pid_) { return 'shown' }
        try { if ($Proc.HasExited) { return 'exited' } } catch { return 'exited' }
        [System.Windows.Forms.Application]::DoEvents()   # 泵一下消息：忙态配色要画得出来，界面不能冻成灰块
        Start-Sleep -Milliseconds 60
    }
    return 'timeout'
}

# 启动一个 scrcpy 并把 Process 对象拿回来（摄像头看门狗要盯它的退出码和 stderr）；启动失败返回 $null。
# Start-Scrcpy 默认不输出进程对象，避免返回值漏入事件处理器输出流；显式传 -PassThru 获取进程。
function Start-CamProc {
    param([string[]]$argv, [string]$errFile, [string]$outFile)
    $camMode=if ($argv -contains '--no-audio') { 'Off' } else { 'On' }
    return (Start-Scrcpy $argv -StderrFile $errFile -StdoutFile $outFile -AudioMode $camMode -PassThru)
}
function Resume-CameraSession {
    param($Session,$Snapshot)
    if (-not $script:camSessions.Contains($Session) -or $Session.Stopped -or $script:closeState.InProgress -or $script:deviceScanState.Closing) { return }
    if (-not $Snapshot.Success) { return }
    if ($Snapshot.Devices -notcontains $Session.Serial) {
        Remove-CamSession $Session
        & $script:showTempHint '设备已断开，摄像头未自动重连' $cRed 12000
        return
    }
    $zoom=Read-CamZoom $Session.OutFile
    if ($null -ne $zoom) { $Session.LastZoom=$zoom }
    $previous=$Session.Proc
    $Session.Proc=$null
    Release-ExitedProcess $previous
    $Session.Proc=Start-CamProc $Session.Args $Session.ErrFile $Session.OutFile
    $Session.StartedAt=Get-Date
    if ($Session.Proc) { & $script:showTempHint '摄像头被亮屏打断，已自动重连；关窗即停' $cGreen }
}

# 从 scrcpy 的 stdout 日志里取「最后一次生效的倍率」：投屏中每按一下 MOD+↑/↓ 都会打一行 "Set camera zoom: 3.1640973"。
# 按住不放会自动重复刷几十行、到端点后还会重复打同一个夹住值，所以只认最后一条。
# 值是 3.1640973 这种脏浮点（每按一步约 +6%），四舍五入到 0.1 就够——面板的步进也是 0.1。
function Read-CamZoom {
    param([string]$file)
    if (-not $file) { return $null }
    try { $txt = [System.IO.File]::ReadAllText($file) } catch { return $null }
    $m = [regex]::Matches($txt, 'Set camera zoom:\s*([\d.]+)')
    if ($m.Count -eq 0) { return $null }
    $zoom=0.0
    if (-not [double]::TryParse($m[$m.Count - 1].Groups[1].Value,[Globalization.NumberStyles]::Float,[cultureinfo]::InvariantCulture,[ref]$zoom)) { return $null }
    return [Math]::Round($zoom,1)
}
function Release-ExitedProcess {
    param($Process)
    if (-not $Process -or -not (Test-ProcessExited $Process)) { return }
    if (@($script:camSessions | Where-Object { [object]::ReferenceEquals($_.Proc,$Process) }).Count) { return }
    $entries=@($scrcpyProcs | Where-Object { [object]::ReferenceEquals($_.Proc,$Process) })
    if (-not $entries.Count -or @($entries | Where-Object { $_.Starting -or $_.StopInProgress }).Count) { return }
    $exitCode=$null; try { $exitCode=$Process.ExitCode } catch {}
    foreach ($entry in $entries) {
        if ($entry.Rec -and -not $entry.Forced -and -not $entry.ExitReported -and $null -ne $exitCode -and $exitCode -ne 0) {
            [void](Add-ErrorLog '录屏异常结束' ("设备：{0}；退出码：{1}" -f $entry.Serial,$exitCode))
            if ($script:showTempHint -and -not $script:closeState.InProgress) {
                & $script:showTempHint '录屏异常结束，请检查视频文件。' $cRed 12000
            }
        }
        [void]$scrcpyProcs.Remove($entry)
    }
    $Process.Dispose()
}
function Update-ProcessLifecycle {
    # 看门狗尚未处理完退出码和日志时，会话引用仍需保留。
    foreach ($session in @($script:camSessions)) {
        if ($session.Stopped -and (Test-ProcessExited $session.Proc)) { Remove-CamSession $session }
    }
    foreach ($entry in @($scrcpyProcs)) {
        if (Test-ProcessExited $entry.Proc) { Release-ExitedProcess $entry.Proc }
    }
}
# 摘掉一个摄像头看门狗会话并清掉它的临时日志。所有结束路径（用户关窗 / 助手主动停 / 看门狗放弃）都过这里，
# 所以倍率回传收在这一处：把用户在画面里按出来的倍率写回设置，下次打开面板就是这个值。
function Remove-CamSession {
    param($cs)
    if (-not $script:camSessions.Contains($cs)) { return }
    # 活进程仍在写日志时只阻止重连；退出后才读取最后倍率并释放文件和句柄。
    if (-not (Test-ProcessExited $cs.Proc)) { $cs.Stopped=$true; return }
    $cs.Stopped=$true
    if (-not $cs.PSObject.Properties['CleanupAttempts']) { $cs | Add-Member CleanupAttempts 0 }
    if ($cs.CleanupAttempts -eq 0) {
        $zoom=Read-CamZoom $cs.OutFile
        if ($null -eq $zoom) { $zoom=$cs.LastZoom }
        if ($null -ne $zoom -and $cs.Serial -and -not $cs.SkipZoom) {
            Set-CamZoom $cs.Serial $cs.Facing (Format-Zoom $zoom)
            Save-Settings
        }
        $previous=$cs.Proc
        $cs.Proc=$null
        Release-ExitedProcess $previous
    }
    $cs.CleanupAttempts++
    $remaining=@()
    foreach ($path in @($cs.ErrFile,$cs.OutFile)) {
        if ($path -and (Test-Path -LiteralPath $path)) { try { Remove-Item -LiteralPath $path -Force -ErrorAction Stop } catch {
            $remaining += $path
        } }
    }
    # 杀毒软件可能暂时占用日志；只重试文件清理，不重复保存倍率或持有进程句柄。
    if ($remaining.Count -eq 0 -or $cs.CleanupAttempts -ge 3) {
        [void]$script:camSessions.Remove($cs)
        if ($remaining.Count) { [void](Add-ErrorLog '摄像头日志清理失败' ($remaining -join "`n")) }
    }
}

function Test-Recording {
    foreach ($it in @($scrcpyProcs)) {
        if ($it.Rec -and $it.Proc -and -not $it.Proc.HasExited) { return $true }
    }
    return $false
}
# 给录制进程发一次 Ctrl+C，再等待它自己退出；超时交由 UI 决定继续等待、强制结束或取消。
# 本函数只在 worker 运行，控制台信号的保护和解除必须配对。
function Stop-ScrcpyGraceful {
    param($proc,[int]$WaitMs=5000,$Control,[switch]$WaitOnly)
    $result=[pscustomobject]@{ Exited=(Test-ProcessExited $proc); SignalSent=$false; Error='' }
    if ($result.Exited) { return $result }
    try {
        if (-not $WaitOnly) {
            [void][Native.ConIO]::FreeConsole()
            if ([Native.ConIO]::AttachConsole([uint32]$proc.Id)) {
                # AttachConsole 会重置处理器表，必须在挂接之后保护本进程。
                [void][Native.ConIO]::SetConsoleCtrlHandler([IntPtr]::Zero,$true)
                $ids=New-Object uint32[] 64
                $count=[Native.ConIO]::GetConsoleProcessList($ids,64)
                # Ctrl+C 会广播到整个控制台；有其它会话时保留进程，让用户决定是否定向强制结束。
                $foreign=@($ids | Select-Object -First ([Math]::Min(64,[int]$count)) | Where-Object { $_ -ne $PID -and $_ -ne $proc.Id })
                if ($count -gt 0 -and $count -le 64 -and $foreign.Count -eq 0) {
                    $result.SignalSent=[Native.ConIO]::GenerateConsoleCtrlEvent(0,0)
                } else { $result.Error='共享控制台，无法安全发送 Ctrl+C。' }
            }
        }
        $result.Exited=Wait-ScrcpyExit $proc $WaitMs $Control
    } catch { $result.Error=$_.Exception.Message }
    finally {
        if (-not $WaitOnly) {
            try { [void][Native.ConIO]::FreeConsole() } catch {}
            try { [void][Native.ConIO]::SetConsoleCtrlHandler([IntPtr]::Zero,$false) } catch {}
        }
    }
    return $result
}
function Stop-AllScrcpy {
    param($Owner=$form)
    return (Stop-DevicesUi -Owner $Owner -All -ForExit)
}
# 当前正在投屏的设备序列号列表（进程还活着的）——「设备管理」据此标「▶ 投屏中」
function Get-ActiveSerials {
    $res = @()
    foreach ($it in @($scrcpyProcs)) {
        if ($it.Serial -and $it.Proc -and -not $it.Proc.HasExited) { $res += $it.Serial }
    }
    return $res
}
# 读取已连接设备序列号列表（state=device）
function Get-DeviceList {
    try {
        $command=Invoke-UiCommand $form $adb @('devices') -TimeoutMs 3000
        if (-not (Test-CommandSuccess $command)) { return @() }
        $out=@($command.Stdout -split "`r?`n")
        $lines = $out | Select-Object -Skip 1 | Where-Object { $_ -match "`tdevice$" }
        return @($lines | ForEach-Object { ($_ -split "`t")[0] })
    } catch { return @() }
}
# 读取单个地址的 adb 状态：device / offline / unauthorized。查询本身失败返回 $null，地址不在列表返回空串。
function Get-AdbDeviceState {
    param($addr, [string]$DeviceText, [switch]$FromText)
    if (-not $addr) { return $null }
    if (-not $FromText) {
        $command=Invoke-UiCommand $form $adb @('devices') -TimeoutMs 3000
        if (-not (Test-CommandSuccess $command)) { return $null }
        $DeviceText=$command.Stdout
    }
    if ($DeviceText -notmatch 'List of devices attached') { return $null }
    $match=[regex]::Match($DeviceText,'(?m)^'+[regex]::Escape([string]$addr)+'\s+(\S+)')
    if ($match.Success) { return [string]$match.Groups[1].Value }
    return ''
}
# 传输类型与可直接 TCP 探测的地址不同，mDNS 服务名由 adb 自己解析。
function Test-TcpAddress {
    param([string]$Address)
    $match=[regex]::Match($Address,'^(?<ip>[0-9]{1,3}(\.[0-9]{1,3}){3}):(?<port>[0-9]{1,5})$')
    if (-not $match.Success) { return $false }
    $ip=$null
    return ([Net.IPAddress]::TryParse($match.Groups['ip'].Value,[ref]$ip) -and
        [int]$match.Groups['port'].Value -ge 1 -and [int]$match.Groups['port'].Value -le 65535)
}
function Test-MdnsSerial {
    param([string]$Serial)
    return ($Serial -match '^[^\s]+\._adb(?:-tls-connect)?\._tcp\.?$')
}
function Test-Wireless {
    param([string]$s)
    return ((Test-TcpAddress $s) -or (Test-MdnsSerial $s))
}

# 设备信息（安卓大版本 + 型号），按序列号缓存：同一台只读一次 adb，状态栏显示和版本门控共用
$script:devInfo = @{}
function Get-DevInfo {
    param($serial, [switch]$CachedOnly)
    if (-not $serial) { return @{ Ver = 0; Text = '' } }
    if ($script:devInfo.ContainsKey($serial)) { return $script:devInfo[$serial] }
    if ($CachedOnly) { return @{ Ver=0; Text='' } }
    $ver = 0; $txt = ''
    try {
        $props=Wait-UiTask -Owner $form -Inputs @{ Adb=$adb; Serial=$serial } -Work {
            $version=Invoke-ShortCommand $Inputs.Adb @('-s',$Inputs.Serial,'shell','getprop','ro.build.version.release') -TimeoutMs 7000 -Control $Control
            $model=Invoke-ShortCommand $Inputs.Adb @('-s',$Inputs.Serial,'shell','getprop','ro.product.model') -TimeoutMs 7000 -Control $Control
            [pscustomobject]@{ Version=$version; Model=$model }
        }
        $vraw=if (Test-CommandSuccess $props.Version) { $props.Version.Stdout.Trim() } else { '' }
        $model=if (Test-CommandSuccess $props.Model) { $props.Model.Stdout.Trim() } else { '' }
        if ($vraw -match '^(\d+)') { $ver = [int]$matches[1] }
        if ($vraw)  { $txt = "Android $vraw" }
        if ($model) { $txt = if ($txt) { "$txt · $model" } else { $model } }
    } catch {}
    $info = @{ Ver = $ver; Text = $txt }
    if ($ver -gt 0 -and $model) { $script:devInfo[$serial] = $info }
    return $info
}

# 小工具：建标签
function New-Lbl {
    param($text, $x, $y)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.AutoSize = $true; $l.Location = New-Object System.Drawing.Point($x, $y)
    return $l
}
# 朱砂红小字（8.5 号、自适应宽度）：字段下方的错误提示
function New-ErrCaption {
    param($x, $y)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = ''; $l.AutoSize = $true; $l.ForeColor = $cRed
    $l.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
    $l.Location = New-Object System.Drawing.Point($x, $y)
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
# 别给它加 FlatStyle='Flat'：会把系统那个 ∨ 箭头换成生硬的小三角，比默认边框更出戏。
# 下拉框保持系统外观是有意为之，不必跟 New-Txt / New-Nud 的扁平描边看齐。
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
    $n.BorderStyle = 'FixedSingle'; $n.BackColor = $cWhite   # 扁平描边，同 New-Txt
    return $n
}
# 输入框：默认 Fixed3D 凹陷边框 + 系统白，跟本助手的扁平卡片风格打架，统一在这里刷平。
# 多行框传 $h（先 Size 后 Multiline 也不会被钳高——控件此时还没句柄）；.Text/.MaxLength 等按需在调用处补。
function New-Txt {
    param($x, $y, $w, $h = 24)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($x, $y); $t.Size = New-Object System.Drawing.Size($w, $h)
    $t.BorderStyle = 'FixedSingle'; $t.BackColor = $cWhite
    return $t
}
function New-Chk {
    param($text, $checked, $x, $y)
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $text; $c.Checked = [bool]$checked; $c.AutoSize = $true
    $c.Location = New-Object System.Drawing.Point($x, $y)
    return $c
}
# 主操作按钮（墨黑实心）
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
# 文字链接按钮（设备 / 快捷键 / 设置等次要入口）
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

# ---------------- 设置窗口（左侧分类导轨 + 右侧面板） ----------------
# 窗口/任务栏图标：朱砂印·投屏（墨黑印章 + 素纸屏幕 + 朱砂手机），与界面同源配色。
# 图标以 base64 内嵌，确保「复制三个文件」打包后仍自带图标，无需附带 .ico 文件。
$script:AppIcon = $null
function Get-AppIcon {
    if ($script:AppIcon) { return $script:AppIcon }
    $b64 = @'
AAABAAUAEBAAAAAAIADnAgAAVgAAABgYAAAAACAAMwQAAD0DAAAgIAAAAAAgAFgFAABwBwAAMDAAAAAAIACoCAAAyAwAAEBAAAAAACAAQQoAAHAVAACJUE
5HDQoaCgAAAA1JSERSAAAAEAAAABAIBgAAAB/z/2EAAAKuSURBVHicZVNLa1NBGD3f3LmvJNc03XRTEVFoIbqxtuLKByqkKOpCQUR8IbgQwa3gX3ChICii
+FjWByIi/ga1traxSEF00SCxSWPuvW3uzJ2RuW1sxA+GmfmGc+Z855sh9ES5XN5IJEpMMqVtTb1nRKSVUsxVfOlDtfrjbx4ADQ0NFWxOt7TSRwHt0Wr04t
eJQMvE6DVYdHVq6nuLA9Cc6dvcss4KJc1NSJIESSLA2P8kWmvPtu0z3HFtAKfIyIYSVQA+Y4ziOKbRnSO4cP4cOkknI+wBI+f7+tPUtL57774IirltHEnS
D06ciCzOuZZC0NiuMRysVBAtNWBxI3I1lDIEHgYHB9mDh4/0Slv0c8aYMnZJKRFGEVphhIVaDWI5yvZGQVeFIRAiQRiG2d5gueM4iDox+kolnDh2HA4RLN
fBxPOXqBw6AJmmPWVoWJZlgH9VsXw+jygMsWfPXozHy9j04iVGZ74gbrVR+/kTFmNQSmUjTdNsmHU3+FqTQdBYmJvDwvw8yHWR2z2KYl8fSv0lNJtL8H0f
RAyu76GQz2eGrhOshZPLZcMPAtTCCI+fPEUxCLB/3z58nJxEvf4LQRBgdraaeeZt8NYJDGOn1cJKowHZbqPZbOLmnTu4dvUK6vU6ZKrx6tVrfJ6ZQaEQwP
c9CCHALctipibH97H1yBGoQh6bd4zgG7eQ8zy8ffsOE89ewHXd7IENDAxkpq55wbhknYbneXJmajqVFy/R8HiFUgX9/sb1zO1fi4uZujiOzd48cVO8cVEC
diPrz/by8FOl0tMqVXBsB1IKJFJmtxpwt41d42ybQwg5Mfvl60njAf0Ol68UA8/QH06kMJ/JgMmUZtZrQG1mRtRJZfqGcfeySf7zW0ZGyltUh0pGpoDoPc
rC1Oxo3pysVue7uT8CzkRRCoGbyAAAAABJRU5ErkJggolQTkcNChoKAAAADUlIRFIAAAAYAAAAGAgGAAAA4Hc9+AAAA/pJREFUeJytVd9rHEUc/8zM7uZ2
72fkqml7pAhW5NRrmvgQEK30yRf7YFEURNoikdg3qxYfRN+0+KCiIIKo1BdDtX+AUVBL+5akljSmcgqSNrlQaXM/9m73dmdGZi67uSR3bYV+Ydhl5vv9fL
4/Z4ANobh7QqMf0vWVY2Njpt9qPE8JDnCJLAGk3NDpKZEOA2qciHO+L6fK5bIfYZJ1NlEsFocp4VOU0HFlKJUZOlqE3JIjZiIg4ELMcBm8sLDwV1lha/vx
QiFRTzu/McYeC8Mw6JASRLjtttrqEN5KpIRwHNsUgs97bfF4uVyuG2q/kXYOR+CEELPbSAiB3bt3glJ2exIJtlKpBIZhPJKwyIsAvlAEyuygBERXTcAoRa
1ex2uTr2Ji4hW4DReU9e8DwQWSqSR++P4sff/Uh8JJJg/GBCAkBSkpISR2Ua7nvlR6FHYigbbvgzHWn4AJWKaJfSP7YBgGlUKk1H6HoCt2BUop1UsBBkGg
l0qV2ouKv41ACgjO4ft+hCS7CWLwMAjgNhoarNGoo16tIplOo9lsxjq9hEjVFJ3VLTGBOvB9DzvuvQ9PP3s43pu9UsbqR5/g6JGXdSR31LK9CFQKEo6Djz
84haHKKrxaDSIMkRreg9Nzs5ie/gmHDj2DarWqo/tfBJQQtD0Pe+5/CINuEz9OToKqwrZaGC4WMfbmG7jyz99ar18NItl6vlEDQnQUKg12Pg9m27B8H6bK
v+dprznnekWNoPQjQPWvzgyDbUrjpiJ3eAgk53qpFEmhxgNIJBIYSGVxjyokgHqjgUwmozstInbSaazdXEMYhjAtqzfBVhFCwLFtnD39DRYuX8by8jJ27d
yFk2+dwDvvvoerS9eQz+fjDpqdm1NzAClkfwLCWGcZTKfOskxcvPg7Fhf+wPHjk3hw716k02kcePIJLC1dw6effY5araqj0ZEODKhLrzeBHpYbN0BtG6Hn
oZ3NwVJROA5Sto2V5RXUajVMT/+MwVwW7TCE49igdHtdugn01SmDAEOjoyideF13Ffd9DBUfxs38DnA10aaJ76bOaBBmMO2MMs1k0jo9qg5RHaN7rXPZCb
iWZcnrlQr+9X2Mnnx7U1Rff/WlNlYe5nLZbcMWAWusjU8jJhASv1iUHnGbTTFx7Cjbv39kvRUZXNfF+QvndYq6gfqKlIIQwsDFr1EYpFQqOWHQumAaZqnZ
bAWe14pHlVKCZDLVaV8p+14V2nMphWEwk3O+mHAy4zMzM7XuJ/MBKvkZw2QjW59hoebi9r5rciHEPKh8bn7+z8XoydSOKpxCoWAPDqZekgJPESlz4k7eyf
X3VRKyRok8h+sD315aveRGmFv07prEWP8BwnTQjwkhkH0AAAAASUVORK5CYIKJUE5HDQoaCgAAAA1JSERSAAAAIAAAACAIBgAAAHN6evQAAAUfSURBVHic
rVdtiFRVGH7Ox52dmTu6jhptYq4i2awjfmBKRmsLUT+CICj6IvpQWpcsyb+B7ppWIP0IkZAgfwdBPwKL3ILAMqF+Zbuzu22mtWGk7ra183nvPW+8Z+5s4+
z1Y2Z94XAv957zPs/7cd73HGCuSAAKt15UqPsqERHghl8ymcySNqUyBD8VQFBriCRAKl/y/ZGxsbHLjRiNBOyPrq6uTi3pDWPoMSFwWwTJZoVAuCKk+DQg
+c7w8PB46I2gnoAFX7v2rq1KyI+FECuMIRDZ0ZL1NREsDKAUiHDR+ObZodHRr2uYInyhbHb1ckHqjIBYFhjjCSF0o/WsSkrZkheIyAeRQ0STkrxtP478+j
Or1LNugt4npVzm+z6DOxGWwPM85PMF+26XNOcIJ+m6fsxxFvtGvAngafu9lnBa0ggRLaktaASvVCq4o6MDPT3ba8tu1nZIqVAo5DE4+BUVSyUoLfOibLrO
jo9PWA9IaboAsTQ0K1I7kzh4sB/dPQ+gnC80FYogMIinXGQ+PC76Bw5ROr0oFTjeegBVAkIIl6E536ruvRo4CAKkUi46Ojow+dclG4rGedclYAwW+h46Oz
uhtbJGCiFd/hfmAO/z68eUd4Xv+9BawxjTFAEOGe8CJl4nFlBfe42Yfdayv+aNViWKtIyayGBsZblUQrlctqNYLNh/6cVpG6pbJToKvFAo2JgvW768CkaA
0gr79h/A1i2b0ber15JqKgw3Q0Aq3i4FbNi0CYcPv4ulrgtQtWwzkZnAoH9gAMeOfYC9e/dgcnIKSqlbR0AA8CoV7H59L+I/fI/P33obiXTV5ZWZPFZ134
8D/fux57VXsfOff+cNPocAAzmORpvj4LdvvkXh0iVQEICMQeB5mDjzHTqKRcRdF5VyGbG2tnnng278wPoMGcSTSUjHsYMJWHJJ124poia3YWhcFFkZNVlA
WFDLpm7Yby0K14+2CI9pzFM4D9gZvG25WNXygoH4Gz+lECgWizh5cnB+BIgIsVgMFy/+iede2AFHO5jJz+DKlSn0vrwDu1/pw/Mv7kRuOIeF7e1w3STIcD
OSKJaKmJj4A8lk0hJrzQNEdqtwSb1w7nebhE89+QRSqQXYuGG9tf7hhx7Elns2Y/yXczhx4jNLuNpjpA1BPfi1CYQxl1rb2mC4FGtdbcOm2rDi8TgSiQS2
d3dj5apO/D01jdOnT2PTxg1ILViEU6dOYXDwSzunloBRSaij3AypIJ0YSpcvV9uUCRCUSki0t0OEzYhVlT0PvX27IWW1V/DgXlEFAxKJ+A17hw5hZ/eUYE
UA1vT1Qa9aCR2LWbcH5TKWrM0ink5DhJZwcnGc68Vx/j9M3aBGWExtFRlZIGHIHrt8HxPnz+O+e7dhfe+uOavGRnOYnp628W6xCFlgIpmfJeARDWvQFAHp
ZCJBR468J9iSzhUrYNiFYUtm4KPvH0WpVJqTzTcp1khjTAEyOFtjY8/o2a7McaXwUhAYz/d9h0E40WwBqjuUstvjYWI1jU7kK6U0GfPJT7mxx9n57AGrX/
rBISPko0KIpVprb2F7O0+8qt7ylmJpxXIiCqSUmoimAwT7a6EQ4QR7Schm7+5RwEeAuJ3PceHC+Z4+7N1EKcnKJg3EM0NDIyfrLyY1saFYt2ZNBloMAPQI
IBbM99BRPdDQDCC/8EzlwOjoubNRVzOEMntxzGZX3ymlWodApJq9hdSJICnzQYChXC53oRHjWsITWrp/3UAi9f4HoshvsbwxbdYAAAAASUVORK5CYIKJUE
5HDQoaCgAAAA1JSERSAAAAMAAAADAIBgAAAFcC+YcAAAhvSURBVHic1VpdbBxXFf7uz8Rre504NrFwaNLUjovrxkmBB6pKZE1QIxBVaZosIekLSKBQ2pci
QZqQP6NKoeIBFXiIUCUqoBWV05YS56UqggoqHmhp7Nju2vlVeGji1D9re39n5h507uxubNexN/HuRj3W1axn7s79zrnn954VKJKOHj0qh4aGxOjoqECZqa
ury3R3dxMAHssiycBxh+hosPai699UmpEI9DvvwOPPzc3NNWvW1HeSZ1oBEfZNOeACSgJEJikdde4anIFr/f2J+ViKYUDkuPbb2tpaQiv0d8mY3SSoRQqp
FmO6VGSM8QDxPynlq66f/n0sdmkkh+kTarUQGJ5oOjva9wiJ4wDuJgMYMiDiT+UnIYSUQkBIASJxDURHzg7FfrcQE/MZ0AC8jo57n9VCPmeIFEuDX7iULp
aBiIh8KYWWUsEn8/zg4PCzrGks4DwTBVDRaJQfeJs6Pv+ElvK47/u8lb4Qgpm6E4YseG1jyHie5yoh929qb3uaVTsSiajCpNxVMrvt7e13O0r8E6C1xhiT
A1/MSnaUg4gIOSwklYxnk9Q1fHH4bF7VrWSj0ShzS46i70sl7pol+aLA814mk0kkEgl7LdVIJBIMHlpraYwhQDSsqBZP51xssH4eSPOXmmsaEnV9UooWn4
gfLKk2bBqum7WfW1pasMJxrMRK5qcIuHjxEjLZDEKhEJExINBYxqWO8+fPX2cImnW/p6fHX5Os7zTStPp2t5ZGwHOM8Vk6OHzoAL7x9e3wPD/3sATYieBo
B2fO9OHAz45gbGxMaK1JSvWZqip8GUBvNBqVMp8auPDbcsCLcpVKKUxPT6MrshW7d0fhe34gfUZPyx8CAul0Blu3bcPe7+xGMpWClNJiE765l6+MvaDnwo
haSCu7ovMPxtvQuBrpVBqZrAutFYhyu7BMEkLA9z1kEjOoX10PjgssICtkiXB+3g1DFeK2EifP9VgydpTSEwkh7Dt5p5mReVTAumz/Xi73WewadyzTLBXJ
5b7AeiMy4MgdGHFlSRc1SQfTZgNk3bRDK4Rq67EaAtNTUxVTq6IZYDCTkxPwPc8Grtn3Pc/D66+9gaHBD/GtRx/Bjh2PIZvN2t2oFBN6sYcMgkP69oe3Y2
vXNjihFXOcLGPk4NV/5gwOHj6GD/r68fNjR5BKJStRNizOAKvH5OQk9u37IfYfPAQlJeBlAb7mAxZzoyT27nkCOx/fiR2PPYovfuEBfDu6CxMTE/YdFWeA
iKzOp9JpfG7tWvzgR09hZiSGt598Et7UNITjcMkUTJYSXjKJlmgUDx4+gp27ojj52uuI7tpZMRWSC93kxVmXm5rWoLq6GhdP9WL8TB/guvAmJuDF47kxBT
M9g0snT9oIvKG1FfH4lP3uHbcBYZM1Y9VFao0V4TCE1pB8Lw+O6wBUQdfUWAP3fK+stcFtulFOrgjk+4Huz/P1NsXlZ3Zm5YB/aiIxLREcdTkW5PjAY74q
8f95z7RU5BbWDt3Cd242t6QM5D3YqoYGVCeT9liEPS0VAp+LZDJl59XVheE4DrhSXMhkbGHHDwTwr3f/bZlYyLZKw4B9L1dQGvHJOE6f6kUmnbHARC7Vdl
0PjY0N2LK5037lvffex+j1j20Zys6CGeG/PESugPl9f/v7P/DWW28jHA7bXQtqjhIzYI3XGFSFqnDlyhU888xPrEdiyrqcWhhMT8/ga9u68PIfX7LS/PVv
T+D06dNoaGi0wKqrQ/NeKgIHYXerrnIqxOBqw7UWFNtByz33YN36dZiKx9HZ2YlMJmPnbNmyyapU/apVGB8bx/mLF6CUnguUixpbmfmVMmI+YgkA8KKhUA
gvvngCG1rvA/yUVbNsOmNV7tDBAwDbiFRIzaSwd89e9A0MYGVd3Q3ARPDzUX9ZDHBwyhlRYFizAhmXkpwfBSvm1iVIKay03/jLX9HRcQ6ZVNraQhD8AjaN
Mfbk4frH47g6Olqwh1upK5ZmgNWbU+RU4D1YLwsMSAnj+XATiVlBL8dK7vrCC78JgOefzyGy9/h4hncrz0DJI3HzV7Zi+JVX4KfTdifyErL5qO/irocfAa
SGcbOzdiNwgytXrlx6BRGkLeY2KrobDBAfyMyWEEE5DrxMBp996CF8s7cX2fgkhNJzVIUXr12/ITBg2z6YS7cq0SJJfIIBo01KQVEhICmNifFx7pjAdzMI
rW1G7br1CxwbCWSSM5aR62NjpWhrLUo2HfOJKyZLsqmpya5YRU6MT6i5F8BeoKamBpcvX0bPq3+GcqrgKMcmTnz2NXcQqmvCONvfh95Tb6KubmW5pM4U6K
eWw3xh7IWt2Lx5c62fTQ8JKdblGWEg7Mu5UIlsjUA7gZ/OZ502ckqFcyMjePlPf8DVqx+hpiaIAWUgsifhZOJCee0DA5eu5araoBvY3d1tNnW0Py+k+Knv
edyV0cEXyJ6B2tO33FF6nmuaVRezF6mqClmPUhb0RJ7SShPhpYHB2PfymAsNDjaD1o7WjdXCeRdkGoMkS6j8Ed9SmeOt+u9bBG+CBodIuJ731Vjswn/nND
j4QyQS0ReGLpyHR0ektDmv4R4Vg8q1m246ynmoRQwe8LRWijw6Hotd+ICx5k/R50cWBu7ff1/bL5TS+32f8RN3ayrSXp1H+bWlVlr65P5qYPDcj+d3KueD
ErlhOtrbn1KSnhNC1HOACVo8xfUOSkBSSinY5gxRUhCOnf1w+JfFtFnnMNF2f9uWEKl9gHkcQjYVTg1nW3KJiQox0owLyDeNlzkxOHLpP7fS6Lb3o1HInh
5Yl/LAxo1r3Cr1IJHYKGHCdh/KU00LQCRIiGHfx/uxWOyj3H3WecZCn8Yfe6jF5hSrCIIbapX4qQ0TR9ienp5CN34x+j/mCHWq4GpcEgAAAABJRU5ErkJg
golQTkcNChoKAAAADUlIRFIAAABAAAAAQAgGAAAAqmlx3gAACghJREFUeJzlW1tsVMcZ/mbO7K69a3BtFIiLFUNrzPoSizZqSSmqw8WEh1C1UTcPVQqCRk
FtIvWhIiHcWiUPJCJVQUUphShpaJ/qvjQliISYdEOfIE5THIMdjMHwQOUIML6sd/ecman+2T32Yu/C2sbrdfxJY+85Z+ac+f/5bzPzDzDLwSbYjodCIdbT
0zPR9vcV8+fP101NTRqAW6YErKGhQSDPkexj1gPDsqkUCsFqaoJ0r2trl1RzzWs1UAHoIqUwLeAcUApRi7NLiqm2traL7a4EhEIhq6mpabjPE2UASxZVWV
n5gM9jbWJASEM/YnFugeWFBgBaQyolAdbGmP47F86fzp3r6kmhL6NasLu8lrkN66qXbgHDy5zzhVprKKWgtZZTqW/jBGOMWZwxMM6JGT3Q2Nd2oeP15HNO
g5i2ITK8kIgrLy8v/NqcwCFu8Y1EtFLKYYzxFMnIJxgDqLVWnHNhcQ5HyeNDUeenXV1dtzMxgaV5kSGuoqLCG/D7jnssa5XtOES4lYdEZwIxwhFCeKRU5z
SzVp0/f/6Wq86pFfnolqEkpwKF3iMeYa1yHCfOGBuXZc0TlfA4jmNbFq9nyv4b3QulkVyeemEsJyBrg0s2CiGetm3HBmNezFC4TBAesaYmWLWLaEsO8Egd
jPpdVVU1z2PhPGNsHhm8dFIyw0BEKDAW57aqa7148XKqKnC3VkNDA+m4FkxvsizrAUVWb5LEWxZ5SkYKiVyBvsU5NyUJRgbB4rxQWuxXVKWhoWHkIUZgft
dUL/nE4ta3pFKKAcSUCYEIHxgYgNfrNSVXTKDvDg4OQgiBgoIC47JptMl7Ka2uF/rnVra0tERcTyeS7Yzhe3jp0qUKehnRziYx+tSJoaEhPBX6CZ588kfw
uQyYajOqKTrkuHr1Gv5w8A10Xb4Mv99PTODkHi1ulQ0N9T8K4BTZgiZAGgaQSITDYSUt1AtuccdxZNLtjRuWxdHX12+If3XvK4hEIlBKG6bkAjTidXU1qK
kJYvOWZ9Hz5ZfweDx0n6SAaUd/mxjQ09DAEA7jjsmNlmqRCbAnEeERsSTyNPKRyBAGBgaNLUiowNSLgKsCixcvwtrGNXjzzbdQUlLiqgIFiotSW4hRbyia
dBd0ggE+n9d8NDFlYDmSgMQ3iOGOIxHw+8f2D2xO6jW/ozlj92VeR0ygkiuxTwf6tkpjeNm9IsGvErJhP8csB8csB8csB5+qF5MRlFK67idvISbSKBu35i
8sRHFJCUT/ACKRwRy6wilkAGPMhJqxWAzScehGxrrbd+xCXW0d1qx+DMuXfwfRaMxIQ74xQWRbkTpOIt3f34eFC8tNdGV8/Rhnk4j4bt3qwztH/4LDR97E
5s2bsGP7C+ZpvjFBZFOJOuw4jpld7dnzG6xb9ziKS0vvuigsHYmuS504sP/3OHTosGHTnt07TZg64xhAoNHff+AAGh5bY66jvTfNorzhQmrERfN/peAJ+L
E0WIM3/ngY8Xgcb//5KNY/vg7Ll3/XTJNT5uv5zQBuWejv60NjY6MhPhYZwGd7X8W1EyfAPZ70syZalPB4UL9tG7654Yd4/rnncezYMXxw8kOsWPG9nC6Q
TJoBzIi/jbraWtPx66dP4/yRIygoLU2M/ChijAXgFpzBAZzbtw+LGtdicWUlFixYgMtXuo0qzUgVYEk3FrvVC1FQAE6LHHLszpMhjTF4AgEo24aKxYwUue
+Y8XEAo7k96X6a0U+FqUME5yHRqeDjbjEe/c0jXc8EjlkOjlkOjq8gxuNmBXKM5C7zXeukBknu8lq2oKq0DE/u9szZT+65JyGQQxBhtFDp7t6kh0YsFh8m
nAgQglaVs/8O7Un8bu9raGn5FAFyx3dhuEAOQB0o8PnQ0fEFtjyzFY6UI1Mo8pTmT2KyVVRUhJ0vvWA2NKi89fY7CH98GkUphGQaUbpLeQHdV6+hu7v7ns
TnjAHUYdqqok2K8Mf/vnPbgSJN2wHjif80yyTxNZ0TAhc6OnDyw2aUmvvS1BPD+wzpvgV4vR7DyGwWYwRyBJcJfn9CJ93pNXWytOxBIwq0xjC3uHhYPejZ
vJISVDz0EIqL55pNFzseR+/t22ZmmpkJiTSebCCQQ6TkFw0z4KUXt2H1mlVGb02OD2OGuMTaQz+e+flmbPzZ08MBJW20vLbvdZw82ZyViN8LAtMAl3gS0/
Xr12F+2YNwYvHhuQI9S0AblSDG0FhL6cDrL8UPVq7Ee++dQFHR5MNsMYHeT7puQh0s9Pb2Yufu36Jx7WqzZEaEuu1G8ttozpGwGvQ8Fo/j6NG/IhAwu77I
OQN0cjpLu4x39U1kqGgkM9QhfSZRP3XqI7z//smsZ4rEPL+/0Oz43o91BZF1zWQH/V8vg7Rt2AMDmatyDru/H4HycliFfuiB/rTSQASQHo93muzakfsBkX
XNZCfLVnwfj+zahSvvvmtWfcaMsMm+URD+AJZt3w7u9UHL3oyvne59A5F6obXOOBTuHr+SDh7+5XOo2frsyJpgOh33+JLeXoILkU+LIZnT5BhDLFObmzdu
DCc8OfFoYuQzhLMmXdWOwY5SdggwOBgxq8EjiRLTimjqBU+90IxdGs0lJaUJSZubmzEUGYSvsNC4KVNs2wQvYwrdV4kgh/z2iRPHcfPmTRMITTO0UrpzDA
PC4bBRRKHYf6WUlEtjUuZMC52w1leuXMH2F7chOhSDrzAAr68Q3gJ/5uLzo8BfhH991IwD+/djzpw506rvlCVmVJyz/9D1/HDY0Dc6TY7VBKs+tzgLqoSs
DksIhacUmVVXV+OJJzagrKzM+OjRO0PGb4PBjts4e/YMjh37p1EdGv1pFH9tEqS0uhGw9TfOdHb2uWlyLPWkRTgcdmqCVbuFsF52EgnSd8gs6TBlfUWj0S
yMGoW73Ix8rpMlx/QkkTgtpJSH2y58sTX1MAVLqWd+B4PBUs5UJ2dsbrpUWZKE8Vj0kbB2mlNlqe+K1bZ2dHSkps7z1IqhUIi3t7ffgMYrlsVJZ8b0nvR4
2AhmUaYbZvRJdKEPEPE0+qkp82xUfZbMoFS1wSXHLSHWU7Y1ZV1jBkJrbSfODMiWgUhsZXd3t50kflgf+eg2RDz9cDR/SkrZSi+gF+XR8ZhsoF3ilZJtUv
MN3d3d0XTH6ni6xiQJHR0d/bbEaqXkBx4hPMmsayfPGWFOilBfDfFSnXEUb2xvb78+niMzLtwGVm31kt0M/Nfc4kXJiQh5ybxK/iE/T4WMtJIyrqEPxmy9
o7OzMzaRQ1MuhqflwWCwSnD9C0D/mDFekUexvYFZRVbqfxr4h9T8YHt7++fJRxmJn9DByfr6+oC2o49qxpZprSnxuCgZ+0wLGGNDAC4xrT+D8H3a2tp6K3
n2iY7/3GHwJguedCF5jWQfs97xYhP4hnGVJt8+j0Cx/f0eccwG/B8ll+H6UMT9MAAAAABJRU5ErkJggg==
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

# 弹窗 Esc=取消：挂一个零尺寸、不可聚焦的隐藏按钮只充当 CancelButton（Esc 触发它即关窗、结果 Cancel）
function New-EscCancel {
    param($dlg)
    $c = New-Object System.Windows.Forms.Button
    $c.DialogResult = 'Cancel'; $c.Size = New-Object System.Drawing.Size(0, 0); $c.TabStop = $false
    [void]$dlg.Controls.Add($c); $dlg.CancelButton = $c
}

function Show-Settings {
    param($owner)
    $dlg = New-Dialog '设置' 570 356 $owner
    $tt = New-Object System.Windows.Forms.ToolTip
    $tt.AutoPopDelay = 12000

    # 左侧分类导轨（取代横排标签页）：选中项＝朱砂竖条 + 墨黑粗体（呼应主界面品牌竖条），未选＝素纸灰。
    # 右侧是对应的设置面板，按选中项切换显示。
    $nav = New-Object System.Windows.Forms.ListBox
    $nav.Location = New-Object System.Drawing.Point(16, 14)
    $nav.Size = New-Object System.Drawing.Size(110, 280)
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
    $navDivider.Size = New-Object System.Drawing.Size(1, 280); $navDivider.Location = New-Object System.Drawing.Point(133, 14); $navDivider.BackColor = $cLine

    # ===== 常用（把最常用 / 最重要的几项聚合在第一类） =====
    $tabCommon = New-Object System.Windows.Forms.Panel
    # 顺序按使用度：人人都调的清晰度/声音在前，只无线用户才碰的两项次之，调试用的控制台沉到最后
    $nudSize = New-Nud $settings.maxSize 0 4096 16 110 13
    $chkAudio = New-Chk '把手机声音也传到电脑' $settings.audioOn 14 46
    $chkStay = New-Chk '保持手机唤醒（避免锁屏 / 无线中途断开）' $settings.stayAwake 14 74
    $chkScreenOff = New-Chk '投屏时关闭手机屏幕（省电、防偷看）' $settings.screenOff 14 102
    $chkReconnect = New-Chk '自动连接记住的无线设备（开机自动连附近的 · 掉线自动重连）' $settings.autoConnect 14 130
    $chkDisconnect = New-Chk '关闭助手时断开无线连接（默认保持，重开即用）' $settings.disconnectOnClose 14 158
    $chkShowConsole = New-Chk '显示 scrcpy 控制台窗口（调试用，会弹黑窗）' $settings.showConsole 14 186
    $tt.SetToolTip($nudSize, '画面最大边长（像素）。数值越大越清晰、越小越流畅；0=不限制。')
    $tt.SetToolTip($chkAudio, '取消勾选则完全不传声音（等同 --no-audio）。')
    $tt.SetToolTip($chkStay, '保持手机不锁屏，避免无线投屏中途断开。想更省电可关掉，让手机自然休眠。')
    $tt.SetToolTip($chkScreenOff, '投屏时关掉手机屏幕，明显省电、还能防偷看（投屏照常进行）。无线投屏想省电首选它。')
    $tt.SetToolTip($chkReconnect, '开机自动连上附近记住的无线设备；掉线后也会自动连回。会略增耗电，按需开启。')
    $tt.SetToolTip($chkDisconnect, '不勾（默认）：关掉助手后仍保持手机连接，重开即用、几乎不耗电。勾上：关助手时定向断开助手记住或启动过的无线设备，重开需重新连。')
    $tt.SetToolTip($chkShowConsole, '勾上后投屏时会弹出一个黑色控制台窗口，里面显示 scrcpy 的运行日志。默认关闭，不影响正常使用。')
    $tabCommon.Controls.AddRange(@(
        (New-Lbl '清晰度：' 14 16), $nudSize, (New-Caption '越大越清晰，0=不限制' 210 19),
        $chkAudio, $chkStay, $chkScreenOff, $chkReconnect, $chkDisconnect, $chkShowConsole))

    # ===== 画面 =====
    $tabVideo = New-Object System.Windows.Forms.Panel
    $nudFps  = New-Nud $settings.maxFps  0 240 5  110 16
    $nudBit  = New-Nud $settings.bitRate 0 50  1  110 52
    $cbVCodec = New-Combo @('默认（H.264，兼容最好）', 'H.265（更清晰）', 'AV1（更省流量）', 'VP8（兜底）', 'VP9（兜底）') @('', 'h265', 'av1', 'vp8', 'vp9') $settings.videoCodec 110 88 230
    $txtCrop = New-Txt 110 124 230
    $txtCrop.Text = $settings.crop
    $chkIgnoreEnc = New-Chk '忽略编码器分辨率限制（分辨率或独立窗口画面不对时再勾）' $settings.ignoreEncoderConstraints 14 184
    $tt.SetToolTip($chkIgnoreEnc, '高级兜底：某些机型上报的编码器限制值不准，导致分辨率或独立窗口画面不对。勾上让 scrcpy 完全忽略这些限制（含对齐要求）。一般不用勾。需 scrcpy 4.1+。')
    $cbHwDec = New-Combo @('自动（用显卡解码，省电脑性能）', '软件解码（画面不对时再选）') @('', 'disabled') $settings.hwDec 110 217 230
    $tt.SetToolTip($cbHwDec, '电脑怎么把收到的画面还原出来。自动=优先让显卡干活，CPU 占用能低一个数量级、笔记本更省电，显卡干不了会自动改用 CPU。要是投屏出现花屏、偏色或整块变黑，改成「软件解码」再投，就能排除显卡的兼容问题；它更吃 CPU，平时不用选。')
    $tt.SetToolTip($nudFps, '每秒帧数上限。0=用默认；填 60 更顺滑、填 30 更省资源。')
    $tt.SetToolTip($nudBit, '视频码率（Mbps）。越高越清晰越占带宽；0=用默认（约 8M）。无线卡顿可调小。')
    $tt.SetToolTip($cbVCodec, 'H.265/AV1 同等清晰度更省带宽，但老机型/老电脑可能不支持，卡顿就换回 H.264。VP8/VP9 仅当机型这几种都不支持时才用作兜底；选 VP8 / VP9 编码，或开启音频并选原始 PCM 时，录屏使用 mkv。')
    $tt.SetToolTip($txtCrop, '只投屏幕的一块区域。格式 宽:高:左:上（像素），例如 1080:1080:0:300。不填=投整屏。')
    $tabVideo.Controls.AddRange(@(
        (New-Lbl '帧率：' 14 19), $nudFps, (New-Caption '越高越流畅，0=默认' 210 21),
        (New-Lbl '画质：' 14 55), $nudBit, (New-Caption '越高越清晰，0=默认' 210 57),
        (New-Lbl '视频编码：' 14 91), $cbVCodec,
        (New-Lbl '裁剪画面：' 14 127), $txtCrop,
        (New-Caption '宽:高:左:上，不填=投整屏。例 1080:1080:0:300' 110 156),
        $chkIgnoreEnc,
        (New-Lbl '解码方式：' 14 220), $cbHwDec,
        (New-Caption '画面花屏、偏色或整块变黑时，改成「软件解码」再投一次' 110 249)))

    # ===== 声音 =====
    $tabAudio = New-Object System.Windows.Forms.Panel
    $cbASrc = New-Combo @('手机外放声音', '麦克风') @('', 'mic') $settings.audioSource 110 73 230
    $cbACodec = New-Combo @('默认（Opus）', 'AAC（兼容）', 'FLAC（无损）', '原始 PCM') @('', 'aac', 'flac', 'raw') $settings.audioCodec 110 111 230
    # 主开关在「常用」类里也有一个：两处勾选框同时存在，状态必须互相同步，否则保存时后读的会把先改的抹掉
    $chkAudio2 = New-Chk '把手机声音也传到电脑' $settings.audioOn 14 18
    $chkAudio2.Add_CheckedChanged({ $chkAudio.Checked = $chkAudio2.Checked }.GetNewClosure())
    $chkAudio.Add_CheckedChanged({ $chkAudio2.Checked = $chkAudio.Checked }.GetNewClosure())
    $lblAudioTip = New-Caption '不勾就完全不出声。下面两项只在勾选时生效：' 14 46
    $tt.SetToolTip($cbASrc, '「手机外放声音」把手机正在播放的声音传到电脑；「麦克风」采集手机话筒，适合当摄像头/直播。')
    $tt.SetToolTip($cbACodec, '一般保持默认即可；个别播放器不出声时可改 AAC。')
    $tabAudio.Controls.AddRange(@(
        $lblAudioTip,
        $chkAudio2,
        (New-Lbl '声音来源：' 14 76), $cbASrc,
        (New-Lbl '音频编码：' 14 114), $cbACodec))

    # ===== 控制 =====
    $tabCtrl = New-Object System.Windows.Forms.Panel
    $cbKb = New-Combo @('默认（推荐，能打中文）', '游戏模式（更跟手，用不了电脑输入法）', 'USB 直连（特殊情况）') @('', 'uhid', 'aoa') $settings.keyboard 110 13 300
    $cbMouse = New-Combo @('默认（推荐）', '游戏模式（更跟手）', 'USB 直连（特殊情况）') @('', 'uhid', 'aoa') $settings.mouse 110 89 300
    # 顺序按使用度：键鼠模式在前，常用的「只投屏」「关窗息屏」次之，niche 的触摸点 / 手柄沉底
    $chkNoCtrl = New-Chk '只投屏，不允许控制手机' $settings.noControl 14 126
    $chkPowerOff = New-Chk '结束投屏后熄灭手机屏幕' $settings.powerOffOnClose 14 154
    $chkTouches = New-Chk '显示触摸点' $settings.showTouches 14 182
    $chkGamepad = New-Chk '启用手柄（把电脑手柄映射到手机）' $settings.gamepad 14 210
    $tt.SetToolTip($chkTouches, '手机画面上触点处显示小白点，演示时让别人看清你点了哪里。')
    $tt.SetToolTip($cbKb, '绝大多数人选「默认」即可，能正常用电脑上的中文输入法。「游戏模式」让电脑键盘像真键盘一样直接控制游戏，但用不了电脑输入法——想打字就改用手机屏幕上的输入法。装过 ADBKeyboard 这类输入法时可在手机上正常打字。')
    $tt.SetToolTip($chkNoCtrl, '只看画面、禁止鼠标键盘操作手机；保持唤醒、投屏关屏、显示触摸点和关窗息屏暂不生效。')
    $tt.SetToolTip($chkPowerOff, '结束投屏（关掉投屏窗口）时，顺手把手机屏幕熄灭，省电、防亮屏。')
    $tt.SetToolTip($chkGamepad, '把连在电脑上的游戏手柄映射给手机，适合手游。')
    # 说明紧跟「键盘模式」，两行封顶：离得远用户不知道它讲的是哪一项，长段落还会折出孤儿字
    $capKbCn = New-Caption "打不进中文？电脑里复制好，到投屏窗口按 Ctrl+V 粘贴。`n或选「游戏模式」，改用手机自己的输入法打字。" 14 44
    $capKbCn.MaximumSize = New-Object System.Drawing.Size(396, 0)   # 不限宽会裁出面板右缘；窄于 396 第一行就折出孤儿字
    $tabCtrl.Controls.AddRange(@(
        (New-Lbl '键盘模式：' 14 16), $cbKb,
        (New-Lbl '鼠标模式：' 14 92), $cbMouse,
        $chkNoCtrl, $chkPowerOff, $chkTouches, $chkGamepad, $capKbCn))

    # ===== 窗口 =====
    $tabWin = New-Object System.Windows.Forms.Panel
    $chkFull = New-Chk '启动即全屏' $settings.fullscreen 14 18
    $chkTop = New-Chk '窗口总在最前' $settings.onTop 14 46
    $chkBorderless = New-Chk '无边框窗口' $settings.borderless 14 74
    $chkMinTray = New-Chk '最小化时收起到系统托盘（不在任务栏占位）' $settings.minToTray 14 102
    $tt.SetToolTip($chkFull, '投屏后画面直接铺满整个屏幕；在投屏窗口按 左 Alt+f（或 F11）可退出全屏。')
    $tt.SetToolTip($chkTop, '投屏窗口始终浮在其它窗口上方，边看手机边操作电脑很方便。')
    $tt.SetToolTip($chkBorderless, '去掉投屏窗口的标题栏和边框，像把手机屏幕贴在桌面上。关窗用 左 Alt+q。')
    $tt.SetToolTip($chkMinTray, '勾上后点标题栏最小化，助手窗口会收起到右下角托盘区，任务栏不再占位；单击/双击托盘图标还原，右键菜单可退出。投屏、录制等功能在托盘下照常运行。')
    $tabWin.Controls.AddRange(@($chkFull, $chkTop, $chkBorderless, $chkMinTray))

    # ===== 独立窗口 =====
    $tabNd = New-Object System.Windows.Forms.Panel
    $cbNdSize = New-Object System.Windows.Forms.ComboBox
    $cbNdSize.DropDownStyle = 'DropDown'
    $cbNdSize.Location = New-Object System.Drawing.Point(110, 15); $cbNdSize.Size = New-Object System.Drawing.Size(200, 26)
    @('跟手机一致', '1280x720', '1600x900', '1920x1080') | ForEach-Object { [void]$cbNdSize.Items.Add($_) }
    $cbNdSize.Text = if ($settings.ndSize) { $settings.ndSize } else { '跟手机一致' }
    $ndDpiLabels = @('自动', '小', '中', '大')
    $ndDpiValues = @('', '160', '240', '320')
    $ndDpiCurrent = [string]$settings.ndDpi
    # 自定义尺寸面板允许任意数字 DPI，保存其它设置时不能把它静默重置为预设的「自动」。
    if ($ndDpiCurrent -match '^\d+$' -and $ndDpiValues -notcontains $ndDpiCurrent) {
        $ndDpiLabels += "自定义 $ndDpiCurrent"
        $ndDpiValues += $ndDpiCurrent
    }
    $cbNdDpi = New-Combo $ndDpiLabels $ndDpiValues $ndDpiCurrent 110 73 110
    $chkNoDecor = New-Chk '隐藏独立窗口顶部的手机状态栏' $settings.ndNoDecor 14 110
    $tt.SetToolTip($cbNdSize, '独立窗口（虚拟显示器）的分辨率。可直接输入自定义值，如 2560x1440。')
    $tt.SetToolTip($cbNdDpi, '虚拟屏里界面元素的大小。手机 App 显示太大就选「小」。已保存的自定义 DPI 会保留在选项中。')
    $tt.SetToolTip($chkNoDecor, '独立窗口顶部不再显示时间/电量那一条，App 内容顶到边；隐藏后通知栏也拉不出来。')
    $tabNd.Controls.AddRange(@(
        (New-Lbl '分辨率：' 14 18), $cbNdSize,
        (New-Caption '可直接输入，如 2560x1440；不填=跟手机一致' 110 46),
        (New-Lbl '界面缩放：' 14 76), $cbNdDpi,
        $chkNoDecor))

    # ===== 录制 =====
    $tabRec = New-Object System.Windows.Forms.Panel
    $cbRecFmt = New-Combo @('mp4', 'mkv') @('mp4', 'mkv') $settings.recFormat 110 15 110
    $nudTime = New-Nud $settings.recTimeLimit 0 86400 10 110 77
    $chkRecBg = New-Chk '后台录制（不显示画面，更省资源）' $settings.recBackground 14 114
    $tt.SetToolTip($nudTime, '到达该秒数自动停止录制。0=不限时，手动关窗即停。')
    $tt.SetToolTip($cbRecFmt, 'mp4 通用好打开；mkv 更稳——录制中途若被强退，mp4 可能整段丢失，mkv 一般能保住已录部分。')
    $tt.SetToolTip($chkRecBg, '勾选后录制时不弹出投屏窗口，画面只写入文件，更省 CPU。')
    $tabRec.Controls.AddRange(@(
        (New-Lbl '保存格式：' 14 18), $cbRecFmt,
        (New-Caption 'mp4 好打开；担心中途被强退丢整段，选 mkv 更稳' 110 46),
        (New-Lbl '录制时长：' 14 80), $nudTime, (New-Caption '秒，0=不限时长' 210 82),
        $chkRecBg))

    # ===== 通用 =====
    $tabGen = New-Object System.Windows.Forms.Panel
    $chkLive = New-Chk '自动刷新主界面的连接状态（不影响投屏）' $settings.liveStatus 14 18
    $txtExtra = New-Txt 14 78 392
    $txtExtra.Text = $settings.extraArgs
    $lblExHint = New-Lbl '例如：--angle=90   --display-id=1   --time-limit=300' 14 108; $lblExHint.ForeColor = $cMuted
    $tt.SetToolTip($chkLive, '它只决定窗口顶部「已连接/未连接」多久自动更新一次，不影响投屏。开着时仅在窗口处于前台才每几秒刷一次；关掉后不再定时刷新，切回窗口时仍会更新一次，更省资源。')
    $tt.SetToolTip($txtExtra, '高级用法（可选，一般不用填）：在这里追加 scrcpy 命令行参数，会拼到启动命令末尾，多个用空格分隔。例如 --crop=1080:1920:0:0（裁剪画面）、--angle=90（旋转）、--display-id=1（指定屏幕）。')

    # 自定义 adb / scrcpy 路径（留空=用本助手同目录自带的）
    $lblPathHdr = New-Lbl '自定义 adb / scrcpy 路径（不填=用自带的）：' 14 150; $lblPathHdr.ForeColor = $cMuted
    $lblAdbCap = New-Lbl 'adb' 14 181
    $txtAdbPath = New-Txt 66 177 248
    $txtAdbPath.Text = $settings.adbPath
    $btnAdbBrowse = New-SecondaryBtn '浏览…' 322 176 72 26
    $lblScrcpyCap = New-Lbl 'scrcpy' 14 223
    $txtScrcpyPath = New-Txt 66 219 248
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
    $tt.SetToolTip($txtAdbPath, 'adb.exe 路径。不填=优先用所选 scrcpy 旁边的 adb、没有再用自带的；填了也让 scrcpy 用同一个 adb。保存即时生效。')
    $tt.SetToolTip($txtScrcpyPath, 'scrcpy.exe 路径。不填=用自带的；想用电脑里别处 / 更新版的 scrcpy 时填。保存即时生效。')

    $tabGen.Controls.AddRange(@(
        $chkLive,
        (New-Lbl '其它命令行参数（可选，一般不用填；多个用空格隔开）：' 14 52), $txtExtra, $lblExHint,
        $lblPathHdr, $lblAdbCap, $txtAdbPath, $btnAdbBrowse, $lblScrcpyCap, $txtScrcpyPath, $btnScrcpyBrowse))

    # 把 8 个面板叠放到右侧内容区，只显示选中的那个；导轨切换驱动显示
    $panels = @($tabCommon, $tabVideo, $tabAudio, $tabCtrl, $tabWin, $tabNd, $tabRec, $tabGen)
    foreach ($p in $panels) {
        $p.Location = New-Object System.Drawing.Point(142, 14); $p.Size = New-Object System.Drawing.Size(412, 280)
        $p.BackColor = $cPaper; $p.Visible = $false; $dlg.Controls.Add($p)
    }
    @('常用', '画面', '声音', '控制', '窗口', '独立窗口', '录制', '通用') | ForEach-Object { [void]$nav.Items.Add($_) }
    $nav.Add_SelectedIndexChanged({
        for ($i = 0; $i -lt $panels.Count; $i++) { $panels[$i].Visible = ($i -eq $nav.SelectedIndex) }
        $nav.Invalidate()   # 强制整条导轨重绘，否则上一个选中项的朱砂高亮可能不刷新、看起来两个都选中
    })
    $dlg.Controls.Add($nav); $dlg.Controls.Add($navDivider)
    $nav.SelectedIndex = 0

    $btnSave = New-PrimaryBtn '保存' 358 308 96 34 10
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'; $btnCancel.Size = New-Object System.Drawing.Size(96, 34); $btnCancel.Location = New-Object System.Drawing.Point(458, 308)
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
        $settings.hwDec      = $cbHwDec.Vals[$cbHwDec.SelectedIndex]
        $settings.ignoreEncoderConstraints = $chkIgnoreEnc.Checked
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
        $settings.minToTray  = $chkMinTray.Checked
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
        $settings.showConsole = $chkShowConsole.Checked
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
    $btnReset.Text = '恢复默认'; $btnReset.Size = New-Object System.Drawing.Size(110, 34); $btnReset.Location = New-Object System.Drawing.Point(16, 308)
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
    $dlg.CancelButton = $btnCancel   # Esc=取消（不保存）
    [void]$dlg.ShowDialog($owner)
}

# ---------------- 从手机已装 App 里挑一个（可搜索） ----------------
# 用 scrcpy --list-apps 列出手机所有 App（带中文名），免去手动查包名。返回包名，取消返回 $null。
function Show-AppPicker {
    param($owner, $serial)
    $owner.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    # 必须带 -s 指定设备：多设备连接时 scrcpy --list-apps 不指定设备会因「有多台设备」直接失败、列不出 App
    $listArgs = if ($serial) { @('-s', $serial, '--list-apps') } else { @('--list-apps') }
    $command=Invoke-UiCommand $owner $exe $listArgs
    if ($command.Cancelled) { $owner.Cursor=[System.Windows.Forms.Cursors]::Default; return $null }
    $raw=if (Test-CommandSuccess $command) { $command.Stdout + "`n" + $command.Stderr } else { '' }
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
    $txt = New-Txt 16 40 308
    $lb = New-Object System.Windows.Forms.ListBox
    $lb.Location = '16,74'; $lb.Size = '308,256'
    $lb.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $lblEmpty = New-Caption '没有找到匹配的 App，换个关键词试试' 24 84
    $lblEmpty.BackColor = $cWhite
    $lblEmpty.Visible = $false

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
        $has = $lb.Items.Count -gt 0
        if ($has) { $lb.SelectedIndex = 0 }
        if ($lblEmpty) { $lblEmpty.Visible = -not $has }
        if ($btnGo) { $btnGo.Enabled = $has }
    }
    $btnGo = New-PrimaryBtn '打开' 16 342 308 34 10
    & $fill ''
    $txt.Add_TextChanged({ & $fill $txt.Text.Trim() })

    $result = @{ app = $null }
    $pick = {
        if ($lb.SelectedIndex -ge 0 -and $lb.SelectedIndex -lt $shown.Count) { $result.app = $shown[$lb.SelectedIndex]; $dlg.Close() }
    }
    $btnGo.Add_Click($pick)
    $lb.Add_DoubleClick($pick)
    $dlg.Controls.AddRange(@($lbl, $txt, $lb, $lblEmpty, $btnGo))
    $lblEmpty.BringToFront()
    $dlg.AcceptButton = $btnGo
    New-EscCancel $dlg
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
        if ($lb.Items.Count -eq 0) { [void]$lb.Items.Add('（还没有；点「手动添加」或「更多应用…」）') }
        if ($btnDel) { $btnDel.Enabled = ($script:customApps.Count -gt 0) }
    }

    $btnAdd = New-SecondaryBtn '手动添加…' 16 226 156 34
    $btnDel = New-SecondaryBtn '删除选中' 188 226 156 34
    & $refresh
    if ($tt) {
        $tt.SetToolTip($btnAdd, '不知道包名？用独立窗口的「更多应用…」从手机列表里挑，会自动加进来，不用手填。')
        $tt.SetToolTip($lb, '空态：点「手动添加」，或在独立窗口的「更多应用…」里挑')
    }
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
    $dlg.AcceptButton = $btnDone
    $dlg.CancelButton = $btnDone   # Enter/Esc 都能关窗
    [void]$dlg.ShowDialog($owner)
}

# ---------------- 独立窗口：自定义虚拟屏尺寸 ----------------
# 不能用 Interaction.InputBox：它把「取消」和「留空」都返回空串，用户点取消等于把已存的
# 自定义尺寸静默抹掉（实测：1080x2340 → 空）。这里用带真「取消」的对话框，取消 = 什么都不改。
function Show-CustomDisplaySize {
    param($owner, $size, $dpi)
    $d = New-Dialog '独立窗口 · 自定义尺寸' 360 248 $owner
    $l1 = New-Lbl '分辨率（宽x高）：' 16 21
    $t1 = New-Txt 150 17 190
    $t1.Text = $size
    $c1 = New-Caption '不填=跟手机一致。例 1080x2340' 150 47
    $e1 = New-ErrCaption 16 65
    $l2 = New-Lbl 'DPI：' 16 96
    $t2 = New-Txt 150 92 190
    $t2.Text = $dpi
    $c2 = New-Caption '不填=默认。常见 160~640' 150 122
    $e2 = New-ErrCaption 16 140
    $c3 = New-Caption '数值越大，界面越像手机版' 150 158
    $ok = New-PrimaryBtn '确定' 150 194 96 34 10
    $cancel = New-SecondaryBtn '取消' 254 194 86 34
    # 校验写进字段下方红字，不再弹 MessageBox 打断（设计稿问题编号 G8）：填错时窗不跳、已填内容不清空，光标送回出错那一格
    $ok.Add_Click({
        $s = $t1.Text.Trim(); $p = $t2.Text.Trim()
        $e1.Text = ''; $e2.Text = ''
        if ($s -and $s -notmatch '^\d{3,4}x\d{3,4}$') {
            $e1.Text = '格式应为 宽x高（用小写 x），例如 1080x2340'
            [void]$t1.Focus(); $t1.SelectAll()
            return
        }
        if ($p -and $p -notmatch '^\d+$') {
            $e2.Text = 'DPI 要填数字，例如 420'
            [void]$t2.Focus(); $t2.SelectAll()
            return
        }
        $d.Tag = @{ Size = $s; Dpi = $p }
        $d.DialogResult = [System.Windows.Forms.DialogResult]::OK
    })
    $cancel.Add_Click({ $d.DialogResult = [System.Windows.Forms.DialogResult]::Cancel })
    $d.Controls.AddRange(@($l1, $t1, $c1, $e1, $l2, $t2, $c2, $e2, $c3, $ok, $cancel))
    $d.AcceptButton = $ok
    $d.CancelButton = $cancel
    if ($d.ShowDialog($owner) -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return $d.Tag
}

# ---------------- 错误日志：把机器话收进文件，界面只留人话 ----------------
function Add-ErrorLog {
    param($Tag, $Text)
    try {
        $logPath = Join-Path $PSScriptRoot '投屏助手-错误日志.txt'
        if ((Test-Path -LiteralPath $logPath) -and ((Get-Item -LiteralPath $logPath).Length -gt 262144)) { Remove-Item -LiteralPath $logPath -Force }   # 与未处理异常共用一份，封顶 256KB
        Add-Content -LiteralPath $logPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Tag`r`n$Text`r`n" -Encoding UTF8
        return $logPath
    } catch { return '' }
}

# ---------------- 结果窗：结论在前、出路给全、原始报错折进「查看原因」 ----------------
# 系统 MessageBox 是白底黑框，和助手的暖米色自绘窗两副面孔；按钮只有「确定」，失败时等于把人弹回起点重做。
# $Buttons 按主次顺序传（第一个是深色主按钮，最后一个兼作 Esc/取消），返回被点按钮的键。
function Show-ResultDialog {
    param($owner, $Title, $Heading, $Body, $Detail = '', $Buttons = @('ok'))
    $labels = @{ wait='继续等待'; force='强制结束'; ok = '确定'; continue = '继续'; retry = '重试'; ip = '输入 IP 连接'; cancel = '取消' }
    $widths = @{ wait=96; force=96; ok = 96; continue = 96; retry = 96; ip = 112; cancel = 84 }
    # 正文按限宽量一次真实高度再定窗高：写死高度会在长文案时把最后一行裁掉
    $capFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
    $sz = [System.Windows.Forms.TextRenderer]::MeasureText([string]$Body, $capFont, (New-Object System.Drawing.Size(388, 0)), [System.Windows.Forms.TextFormatFlags]::WordBreak)
    $bodyH = [Math]::Max([int]$sz.Height, 18)
    $linkTop = 44 + $bodyH + 8
    $btnTop = $linkTop + $(if ($Detail) { 28 } else { 8 })
    $baseH = $btnTop + 50
    $d = New-Dialog $Title 420 $baseH $owner
    $lHead = New-Lbl $Heading 16 16
    $lHead.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5, [System.Drawing.FontStyle]::Bold)
    $lBody = New-Caption $Body 16 44
    $lBody.MaximumSize = New-Object System.Drawing.Size(388, 0)
    $link = $null; $txt = $null
    if ($Detail) {
        $link = New-Object System.Windows.Forms.LinkLabel
        $link.Text = '查看原因'; $link.AutoSize = $true
        $link.Font = $capFont
        $link.LinkColor = $cMuted; $link.VisitedLinkColor = $cMuted; $link.LinkVisited = $true
        $link.Location = New-Object System.Drawing.Point(16, $linkTop)
        $txt = New-Object System.Windows.Forms.TextBox
        $txt.Multiline = $true; $txt.ReadOnly = $true; $txt.ScrollBars = 'Vertical'
        $txt.Text = $Detail; $txt.Visible = $false; $txt.TabStop = $false
        $txt.Font = New-Object System.Drawing.Font('Consolas', 8.5)
        $txt.Size = New-Object System.Drawing.Size(388, 92)
        $txt.BackColor = $cWhite
        $txtTop = $linkTop + 22
        $txt.Location = New-Object System.Drawing.Point(16, $txtTop)
        [void](Add-ErrorLog $Title $Detail)   # 展不展开都先落盘，用户不必为了留证据去截图
        $link.Add_Click({
            $show = -not $txt.Visible
            $txt.Visible = $show
            $link.Text = $(if ($show) { '收起原因' } else { '查看原因' })
            # 明细框已随窗体按 DPI 缩放：按它的实际高度让按钮和窗体一起让位，
            # 不能再用未缩放的 100 直接设 ClientSize（会把窗改窄、正文裁掉、按钮压在明细上）。
            $dh = $txt.Height + 10
            if (-not $show) { $dh = -$dh }
            foreach ($b in @($d.Controls | Where-Object { $_ -is [System.Windows.Forms.Button] })) { $b.Top += $dh }
            $d.ClientSize = New-Object System.Drawing.Size($d.ClientSize.Width, ($d.ClientSize.Height + $dh))
            # 展开后可能顶出屏幕底部：把窗体夹回工作区，别让“确定/收起”按钮落到屏幕外
            try {
                $wa = [System.Windows.Forms.Screen]::FromControl($d).WorkingArea
                if ($d.Bottom -gt $wa.Bottom) { $d.Top = [Math]::Max($wa.Top, $wa.Bottom - $d.Height) }
                if ($d.Right -gt $wa.Right) { $d.Left = [Math]::Max($wa.Left, $wa.Right - $d.Width) }
            } catch {}
        }.GetNewClosure())
    }
    $x = 420 - 16
    $created = @()
    for ($i = $Buttons.Count - 1; $i -ge 0; $i--) {   # 从右往左排：$created[0] 是最右（取消），$created[-1] 是主按钮
        $key = [string]$Buttons[$i]; $w = $widths[$key]
        $x -= $w
        $b = if ($i -eq 0) { New-PrimaryBtn $labels[$key] $x $btnTop $w 34 10 } else { New-SecondaryBtn $labels[$key] $x $btnTop $w 34 }
        $b.Add_Click({ $d.Tag = $key; $d.Close() }.GetNewClosure())
        $created += $b
        $x -= 8
    }
    $ctl = @($lHead, $lBody) + @($created)
    if ($link) { $ctl += @($link, $txt) }
    $d.Controls.AddRange($ctl)
    $d.AcceptButton = $created[-1]
    $d.CancelButton = $created[0]
    [void]$d.ShowDialog($owner)
    return [string]$d.Tag
}

# ---------------- 独立窗口：选 App ----------------
function Show-NewDisplay {
    param($owner, $serial)
    $dlg = New-Dialog '独立窗口' 320 330 $owner

    $l1 = New-Lbl '在电脑上单开一块屏，运行下面这个 App：' 16 14
    $l2 = New-Lbl '（手机照常用，互不影响；需 Android 11+）' 16 38; $l2.ForeColor = $cMuted
    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.DropDownStyle = 'DropDownList'; $cb.Location = New-Object System.Drawing.Point(16, 64); $cb.Size = New-Object System.Drawing.Size(288, 28)
    $specialApps = @('更多应用…（从手机里挑）', '手动输入名字或包名…', '管理我的常用应用…')
    $refreshApps = {
        $cur = [string]$cb.SelectedItem
        $cb.Items.Clear()
        foreach ($name in $apps.Keys) { [void]$cb.Items.Add($name) }
        foreach ($name in $script:customApps.Keys) { [void]$cb.Items.Add($name) }
        foreach ($name in $specialApps) { [void]$cb.Items.Add($name) }
        $i = $cb.Items.IndexOf($cur)
        if ($i -ge 0) { $cb.SelectedIndex = $i } else { $cb.SelectedIndex = 0 }
    }
    & $refreshApps

    # 窗口比例/方向：微信、QQ 等手机应用在“横屏平板”虚拟屏上会用平板版面、显示不全，选「竖屏·手机」即用手机版面
    $lblMode = New-Lbl '窗口比例' 16 110
    # 「自定义」这一项要把已填的尺寸带在标签上，否则选完就看不见自己填的是什么了
    $customLabel = if ($settings.ndSize) { "自定义 $($settings.ndSize)" } else { '自定义…' }
    $cbMode = New-Combo @('竖屏·手机版面（推荐微信/QQ）', '横屏·平板版面', '跟随「设置」里的尺寸', $customLabel) @('portrait', 'landscape', 'settings', 'custom') $settings.ndMode 84 107 220
    $chkFixed = New-Chk '固定方向（最大化时画面不乱转）' $settings.ndFixed 16 143
    # 限宽自动换行：两行说明都比固定宽度的窗宽，不限宽会被右边缘裁掉、看不全
    $capMode = New-Caption "竖屏适合聊天/刷信息；横屏适合看视频。乱转就勾上「固定方向」。`n应用双开/分身在独立窗口常黑屏、点不到，建议改用普通投屏在手机上开分身。" 16 167
    $capMode.MaximumSize = New-Object System.Drawing.Size(288, 0)

    # 声音三态（记住上次选择）：自动=同设备只让第一个窗口出声；播放=这扇窗强制出声；静音=这扇窗不出声
    # 注意：上方 capMode 实际占 4 行（限宽 288 下两段各折两行），声音区必须排在 y≥235，否则会被盖住
    $lblAudio = New-Lbl '声音' 16 235
    $cbAudio = New-Combo @('自动（只第一个窗出声）', '播放（这扇窗始终出声）', '静音（这扇窗不出声）') @('auto', 'on', 'off') $settings.ndAudio 84 232 220
    $audioTt = '自动（推荐）：同一台手机只让第一个窗口出声，后开的窗口自动静音，避免重音；播放：这扇窗强制出声，可能与已有窗口重音；静音：这扇窗不发声。'
    if ($tt) { $tt.SetToolTip($cbAudio, $audioTt); $tt.SetToolTip($lblAudio, $audioTt) }   # $tt 是主窗体作用域的，动态查找；空值守卫

    $btnGo = New-PrimaryBtn '打开' 16 274 288 38 11
    # 空字符串是用户明确清空后的值，不能再用值的真假来判断是否确认过。
    $state = @{ Target = $null; Label = $null; CustomSize = $null; CustomDpi = $null; CustomConfirmed=$false }
    $ndBusy = $false
    $btnGo.Add_Click({
        if ($ndBusy) { return }
        $ndBusy = $true
        try {
        $sel = [string]$cb.SelectedItem
        if ($sel -eq '管理我的常用应用…') {
            Show-ManageApps $dlg
            & $refreshApps
            return
        }
        $ndModeSel = [string]$cbMode.Vals[$cbMode.SelectedIndex]
        if ($ndModeSel -eq 'custom') {
            $askSize = if ($state.CustomConfirmed) { [string]$state.CustomSize } else { [string]$settings.ndSize }
            $askDpi = if ($state.CustomConfirmed) { [string]$state.CustomDpi } else { [string]$settings.ndDpi }
            $ask = Show-CustomDisplaySize $dlg $askSize $askDpi
            if (-not $ask) { return }   # 取消：留在独立窗口面板，比例/声音不丢
            # 先记在本次面板的 pending 里，真正选定 App 后再写入 settings——取消选 App 不应改已存尺寸
            $state.CustomSize = [string]$ask.Size; $state.CustomDpi = [string]$ask.Dpi
            $state.CustomConfirmed=$true
            $i = $cbMode.SelectedIndex
            $cbMode.Items[3] = $(if ($ask.Size) { "自定义 $($ask.Size)" } else { '自定义…' })
            $cbMode.SelectedIndex = $i
        }
        if ($sel -like '更多应用*') {
            $oldText = $btnGo.Text
            $btnGo.Text = '正在读取应用列表…'; $btnGo.Enabled = $false; $dlg.Refresh()
            try { $app = Show-AppPicker $dlg $serial } finally { $btnGo.Text = $oldText; $btnGo.Enabled = $true; $dlg.Refresh() }
            if (-not $app) { return }   # 取消：留在独立窗口面板，比例/声音不丢
            $state.Label = $app.Name
            $state.Target = "+$($app.Pkg)"
            # 挑完顺手问一句要不要记住，下次直接在下拉里选
            if (-not $apps.Contains($app.Name) -and -not $script:customApps.Contains($app.Name)) {
                if ([System.Windows.Forms.MessageBox]::Show("要把「$($app.Name)」加到常用列表吗？以后可直接在下拉里选它。", '常用应用', 'YesNo', 'Question') -eq 'Yes') {
                    $script:customApps[$app.Name] = $app.Pkg; Save-Settings
                }
            }
        }
        elseif ($sel -like '手动输入*') {
            $name = [Microsoft.VisualBasic.Interaction]::InputBox("输入 App 名字（如 chrome）或完整包名（如 com.tencent.mm）。`n中文 App 建议用包名，更准确。", '独立窗口 · 打开 App', '')
            if ([string]::IsNullOrWhiteSpace($name)) { return }   # 取消：留在独立窗口面板
            $name = $name.Trim()
            $state.Label = $name
            $state.Target = if ($name -match '\.') { "+$name" } else { "+?$name" }
        }
        elseif ($apps.Contains($sel)) { $state.Target = '+' + $apps[$sel]; $state.Label = $sel }
        elseif ($script:customApps.Contains($sel)) { $state.Target = '+' + $script:customApps[$sel]; $state.Label = $sel }
        else { return }
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Close()
        } finally { $ndBusy = $false }
    })
    $dlg.Controls.AddRange(@($l1, $l2, $cb, $lblMode, $cbMode, $chkFixed, $capMode, $lblAudio, $cbAudio, $btnGo))
    $dlg.AcceptButton = $btnGo
    New-EscCancel $dlg
    if ($dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) {
        $target = [string]$state.Target
        $appLabel = [string]$state.Label
        if (-not $target) { return }
        # 按所选比例/方向算出虚拟屏尺寸与 DPI
        $ndModeSel = [string]$cbMode.Vals[$cbMode.SelectedIndex]
        $ndSz = $settings.ndSize; $ndDpi = $settings.ndDpi
        $autoFit = $false   # portrait/landscape：虚拟屏用真实/标准尺寸，窗口适配屏幕（非 flex）
        switch ($ndModeSel) {
            'portrait'  {
                # 手机版面：虚拟屏用设备真实分辨率/密度，比例、密度都跟手机一致（App 不拉伸、走手机版面）；
                # 窗口再按比例缩进屏幕、避免超出被切。读不到设备尺寸才兜底通用竖屏值。
                $disp = Get-DeviceDisplay $serial
                if ($disp.Cancelled) { return }
                if ($disp) {
                    $w = [Math]::Min($disp.W, $disp.H); $h = [Math]::Max($disp.W, $disp.H)   # 保证竖屏 W<H
                    $d = if ($disp.Dpi -gt 0) { $disp.Dpi } else { 420 }
                } else { $w = 1080; $h = 2340; $d = 420 }
                $ndSz = "${w}x${h}"; $ndDpi = "$d"; $autoFit = $true
            }
            'landscape' { $ndSz = '1920x1080'; $ndDpi = '240'; $autoFit = $true }
            # custom 的 pending 尺寸在“打开”时由 Show-CustomDisplaySize 确认，选定 App 后才落盘
            'custom'    {
                if ($state.CustomConfirmed) { $ndSz = [string]$state.CustomSize; $ndDpi = [string]$state.CustomDpi }
            }
        }
        $audioSel = [string]$cbAudio.Vals[$cbAudio.SelectedIndex]
        # 「自动」要服从设置里的总开关「把手机声音传到电脑」：总开关关了就不出声（独立窗口不带 Get-AudioArgs，否则总开关管不到它）；
        # 用户显式选的「播放/静音」以当次选择为准，不被总开关覆盖。
        $effAudio = if (-not $settings.audioOn -and $audioSel -eq 'auto') { 'off' } else { $audioSel }
        if ($ndModeSel -eq 'custom' -and $state.CustomConfirmed) {
            $settings.ndSize = [string]$state.CustomSize; $settings.ndDpi = [string]$state.CustomDpi
        }
        $settings.ndMode = $ndModeSel; $settings.ndFixed = $chkFixed.Checked; $settings.ndAudio = $audioSel; Save-Settings
        $pre = if ($serial) { @('-s', $serial) } else { @() }
        # 独立窗口和普通投屏窗同用设备名会重名（任务栏分不清），标题里补上 App 名
        $friendly = if ($serial) { Get-FriendlyName $serial } else { '' }
        $winLabel = (@($friendly, $appLabel) | Where-Object { $_ }) -join ' · '
        $winLabel = ($winLabel -replace '[\r\n\x00-\x1F"]', ' ').Trim()
        $titleArg = if ($winLabel) { @("--window-title=$winLabel") } else { @() }
        # 自动模式(手机/平板版面)：窗口适配屏幕；用 --window-* 就必须非 flex（否则 scrcpy 报错），非 flex 也顺带避免最大化画面自转。
        $fitWin = if ($autoFit) { Get-FitWindowArgs $ndSz } else { @() }
        $useFixed = if ($fitWin.Count -gt 0) { $true } else { $chkFixed.Checked }
        # 虚拟屏保留系统装饰（状态栏/导航栏）：去掉 --no-vd-system-decorations 后，像微信这种 App 会把自己的顶栏
        # 同时画进「状态栏预留区」和正常位置，出现「两条一样的顶栏」；保留系统栏则是正常的「状态栏+单顶栏」手机观感。
        # @() 防单元素退化粘连（同 Get-MirrorArgs 处的坑）：$pre 为空时 $null+单元素串 会变字符串拼接
        Start-Scrcpy ($pre + @(Get-HwDecArgs) + @(Get-NewDisplayArgs $ndSz $ndDpi $useFixed $settings.ndNoDecor) + $fitWin + $titleArg + "--start-app=$target") -AudioMode $effAudio
    }
}

# ---------------- 无线：配对码连接（Android 11+，免插线） ----------------
# 只需手机「使用配对码配对设备」弹窗里的两样东西：配对地址 + 配对码（并排显示，不会填错）。
# 配对成功后，连接端口用 adb mdns 自动发现，无需用户再去看无线调试主界面那个端口。
# 成功返回连接地址（ip:port），失败/取消返回 $null。
function Show-WirelessPair {
    param($owner)
    $dlg = New-Dialog '用配对码连接（免插线）' 360 260 $owner

    $l1 = New-Lbl '手机需 Android 11+，且与电脑连同一个 Wi-Fi。' 16 14; $l1.ForeColor = $cMuted
    $l2 = New-Lbl '手机：开发者选项 → 无线调试 → 使用配对码配对设备' 16 38

    $l3 = New-Lbl '配对地址（手机弹窗里的「IP 地址和端口」）' 16 70
    $txtPair = New-Txt 16 92 328

    $l4 = New-Lbl '配对码（同一个弹窗里的 6 位数字）' 16 122
    $txtCode = New-Txt 16 144 328; $txtCode.MaxLength = 6

    $lblNote = New-Lbl '照抄即可，连接端口会自动识别。' 16 176; $lblNote.ForeColor = $cMuted

    $btnGo = New-PrimaryBtn '配对并连接' 16 206 328 38 11
    $result = @{ addr = $null }
    $connectionFlow=@{ Busy=$false }
    $btnGo.Add_Click({ Invoke-MainFlow ({
        $pairAddr = $txtPair.Text.Trim()
        $code = $txtCode.Text.Trim()
        if ($pairAddr -notmatch '^(\d{1,3}(\.\d{1,3}){3}):\d+$') { [System.Windows.Forms.MessageBox]::Show('配对地址格式应为 IP:端口，例如 192.168.1.5:37123。', '配对') | Out-Null; return }
        $ip = $matches[1]
        if ($code -notmatch '^\d{6}$') { [System.Windows.Forms.MessageBox]::Show('配对码应为 6 位数字。', '配对') | Out-Null; return }
        $discovery=Wait-UiTask -Owner $dlg -Functions @('Invoke-PairDiscovery','Test-CommandSuccess','Get-CommandDetail') -Inputs @{
            Adb=$adb; PairAddress=$pairAddr; Code=$code; Ip=$ip
        } -Work { Invoke-PairDiscovery $Inputs.Adb $Inputs.PairAddress $Inputs.Code $Inputs.Ip $Control }
        if ($discovery.Cancelled) { return }
        if (-not $discovery.Paired) {
            [void](Show-ResultDialog $dlg '用配对码连接' '配对失败' '多半是配对码过期或地址抄错。请在手机上重新生成配对码，把弹窗里的地址和 6 位数字一起照抄再试。' $discovery.Error @('ok'))
            return
        }
        $connAddr=$discovery.Address
        # 自动没找到（mdns 不可用等）：退一步问端口号
        if (-not $connAddr) {
            $port = [Microsoft.VisualBasic.Interaction]::InputBox("已配对成功！但没能自动识别连接端口。`n请在手机「无线调试」主界面看「IP 地址和端口」，把冒号后面的端口号填这里：", '用配对码连接', '')
            if ([string]::IsNullOrWhiteSpace($port)) { return }
            $port = $port.Trim()
            if ($port -notmatch '^\d+$') { [System.Windows.Forms.MessageBox]::Show('端口应为纯数字。', '配对') | Out-Null; return }
            $connAddr = "${ip}:$port"
        }
        $connection=Connect-DevicesUi $dlg @($connAddr)
        if ($connection.Cancelled) { return }
        $record=@($connection.Records)[0]
        if ($record -and $record.Success) {
            $result.addr=$connAddr
            Touch-KnownDevice $connAddr (Get-FriendlyName $connAddr -CachedOnly)
            $dlg.Close()
        } else {
            [void](Show-ResultDialog $dlg '用配对码连接' "已配对成功，但连接 $connAddr 失败" '可在手机「无线调试」主界面核对端口后重试。' $(if ($record) { $record.Error } else { $connection.Error }) @('ok'))
        }
    }) $dlg $connectionFlow })
    $dlg.Controls.AddRange(@($l1, $l2, $l3, $txtPair, $l4, $txtCode, $lblNote, $btnGo))
    $dlg.AcceptButton = $btnGo
    New-EscCancel $dlg
    [void]$dlg.ShowDialog($owner)
    return $result.addr
}

# ---------------- 快捷键速查 ----------------
# 内容依据 scrcpy 官方 doc/shortcuts.md；官方写作 MOD（默认 = 左 Alt 或左 Super），界面按用户口径统一叫 Alt。
function Show-Shortcuts {
    param($owner)
    $dlg = New-Dialog '快捷键速查' 380 432 $owner
    $txt = New-Txt 16 14 348 358
    $txt.Multiline = $true; $txt.ReadOnly = $true; $txt.ScrollBars = 'Vertical'
    $txt.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $txt.Text = (@'
下面的 Alt，指左 Alt 或左 Win（两个都能用）

— 窗口 —
全屏：Alt+f 或 F11
退出：Alt+q
去黑边：Alt+w（或双击画面）
显示帧率：Alt+i

— 手机操作 —
回到桌面：Alt+h（或鼠标中键）
返回：Alt+b（或鼠标右键）
多任务：Alt+s
菜单：Alt+m
音量 加/减：Alt+↑ / Alt+↓（投屏窗口里）
锁屏/解锁手机：Alt+p
通知栏 展开/收起：Alt+n / Alt+Shift+n
复制到电脑：Alt+c
粘贴到手机：Alt+v

— 屏幕 —
手机息屏（继续投屏）：Alt+o
手机点亮：Alt+Shift+o
旋转手机屏幕：Alt+r
旋转投屏画面：Alt+← / Alt+→
暂停/恢复画面：Alt+z / Alt+Shift+z

— 拖拽（拖进投屏窗口）—
拖入 APK：安装到手机
拖入其它文件：传到手机

— 相机（手机当摄像头时）—
补光灯 开/关：Alt+t / Alt+Shift+t
放大/缩小：Alt+↑ / Alt+↓（只有「手机当摄像头」时才是变焦）
'@ -replace "`r?`n", "`r`n")
    $txt.Select(0, 0)
    $btnClose = New-PrimaryBtn '知道了' 16 382 348 34 10
    $btnClose.Add_Click({ $dlg.Close() })
    $dlg.Controls.AddRange(@($txt, $btnClose))
    $dlg.AcceptButton = $btnClose
    $dlg.CancelButton = $btnClose
    [void]$dlg.ShowDialog($owner)
}

# ---------------- 设备：记住 / 友好名 / 选择 / 解析目标 ----------------
# 给设备起个一眼能认的名字：优先用户记住的备注名，否则取型号，再不行用序列号兜底。
function Get-FriendlyName {
    param($serial, [switch]$CachedOnly)
    if (-not $serial) { return '' }
    if ($script:deviceNames.Contains($serial))  { return $script:deviceNames[$serial] }   # 用户自定义名优先
    if ($script:knownDevices.Contains($serial)) { return $script:knownDevices[$serial] }
    $info = Get-DevInfo $serial -CachedOnly:$CachedOnly
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
    if ($addr -isnot [string] -or [string]::IsNullOrWhiteSpace($addr)) { return }
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

# 重连共用扫描队列；finally 无论成功、失败还是关闭窗口都释放守卫。
function Connect-RememberedAsync {
    param($OnDone)
    if ($script:autoConnectStarted -or -not $settings.autoConnect) { return }
    $cands = @(Get-AutoConnectCandidates 16)
    if ($cands.Count -eq 0) { return }
    $script:autoConnectStarted = $true
    Start-DeviceScan -Owner $form -Candidates $cands -ConnectAlways $true -Kind 'startup' -OnDone ({
        param($result)
        if ($OnDone) { & $OnDone @($result.Connected) }
    }.GetNewClosure())
}
$script:reconnectState = @{ InFlight = $false }
function Reconnect-LastAsync {
    param($addr)
    if (-not $addr -or $script:reconnectState.InFlight -or (Test-AutoConnectExcluded $addr)) { return }
    $flag = $script:reconnectState
    $flag.InFlight = $true
    Start-DeviceScan -Owner $form -Candidates @($addr) -Kind 'reconnect' -OnFinally ({ $flag.InFlight = $false }.GetNewClosure())
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
    if (-not $addrs) { return @() }
    $requested=@($addrs)
    $services=@($requested | Where-Object { Test-MdnsSerial $_ })
    $addrs=@($requested | Where-Object { Test-TcpAddress $_ })
    $clients = @(); $iars = @(); $reachable = @()
    try {
        foreach ($addr in $addrs) {
            $c = New-Object Net.Sockets.TcpClient
            $clients += $c
            try {
                $parts = $addr -split ':'
                $port = if ($parts.Count -gt 1 -and $parts[1]) { [int]$parts[1] } else { 5555 }
                $iars += $c.BeginConnect($parts[0],$port,$null,$null)
            } catch { $iars += $null }
        }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
            if (@($iars | Where-Object { $_ -and -not $_.IsCompleted }).Count -eq 0) { break }
            Start-Sleep -Milliseconds 25
        }
        for ($i = 0; $i -lt $addrs.Count; $i++) {
            try {
                if ($iars[$i] -and $iars[$i].IsCompleted) {
                    $clients[$i].EndConnect($iars[$i])
                    if ($clients[$i].Connected) { $reachable += $addrs[$i] }
                }
            } catch {}
        }
        # 不让 Winsock 把服务名当主机名或 IP:port；adb connect 支持完整的服务名。
        return @($requested | Where-Object { $services -contains $_ -or $reachable -contains $_ })
    } finally {
        foreach ($c in $clients) { $c.Close() }
    }
}

# 查询完成后继续原功能；等待只发生在 worker，主流程的 Busy 直到回调完成才释放。
function Ensure-Devices {
    param($owner, [scriptblock]$OnDone, [scriptblock]$OnFinally)
    Start-DeviceScan -Owner $owner -Candidates @($script:knownDevices.Keys) -Kind 'ensure' -OnDone $OnDone -OnFinally $OnFinally
}

function Resolve-Target {
    param($owner, [string]$Prefer = '', [string[]]$Devices=@())
    $devs=@($Devices)
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
    param($owner, [int]$Need, [string]$Feature, [string[]]$Devices=@())
    $devs=@($Devices)
    if ($devs.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("没检测到手机，请先连接手机再使用「$Feature」。", $Feature) | Out-Null; return $null }
    # 先把版本不够的设备排除在候选之外，再在「合格设备」里定目标：
    # 2 台里排掉 1 台后只剩 1 台就直接用，不必再弹窗问。读不到版本的当「未知」、不排除（交给 scrcpy 兜底）。
    $eligible = @($devs | Where-Object { $v = (Get-DevInfo $_ -CachedOnly).Ver; ($v -eq 0) -or ($v -ge $Need) })
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
    $dlg = New-Dialog '输入 IP 连接' 360 182 $owner
    $l1 = New-Lbl '用 IP 直接连接手机，不需要配对码。' 16 14; $l1.ForeColor = $cMuted
    $l2 = New-Lbl '保底连法：开着「无线调试」就能连，重连也方便。' 16 36; $l2.ForeColor = $cMuted
    $l3 = New-Lbl 'IP 地址' 16 66
    $txtIp = New-Txt 16 88 208
    $l4 = New-Lbl '端口' 240 66
    $txtPort = New-Txt 240 88 104; $txtPort.Text = '5555'
    $btnGo = New-PrimaryBtn '连接' 16 128 328 38 11
    $result = @{ addr = $null }
    $connectionFlow=@{ Busy=$false }
    $btnGo.Add_Click({ Invoke-MainFlow ({
        $ip = $txtIp.Text.Trim(); $port = $txtPort.Text.Trim()
        if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { [System.Windows.Forms.MessageBox]::Show('IP 地址格式应为 4 段数字，例如 192.168.1.7。', '输入 IP 连接') | Out-Null; return }
        if (-not $port) { $port = '5555' }
        if ($port -notmatch '^\d+$') { [System.Windows.Forms.MessageBox]::Show('端口应为纯数字，常见是 5555。', '输入 IP 连接') | Out-Null; return }
        $addr = "${ip}:$port"
        $connection=Connect-DevicesUi $dlg @($addr) -Probe
        if ($connection.Cancelled) { return }
        $record=@($connection.Records)[0]
        $state=if ($record) { $record.State } else { $null }
        $out=if ($record) { $record.Error } else { $connection.Error }
        if ($state -eq 'device') {
            $result.addr = $addr; $dlg.Close()
        } elseif ($state -eq 'offline' -or $state -eq 'unauthorized') {
            $body = if ($state -eq 'unauthorized') {
                '手机上还没允许这台电脑调试：点亮手机，在「允许 USB 调试」弹窗里点允许后再试。'
            } else {
                '设备处于 offline 状态（常见于无线调试未完全就绪），已清理这次连接，请再试一次。'
            }
            [void](Show-ResultDialog $owner '输入 IP 连接' "连不上 $addr" $body $out @('ok'))
        } elseif ($state -eq '') {
            [void](Show-ResultDialog $owner '输入 IP 连接' "连不上 $addr" '手机没开「无线调试」或与电脑不在同一 WiFi：Android 11+ 去开发者选项里打开；更早的手机先插一次线，点「无线投屏 → 插数据线连接」切换。' $out @('ok'))
        } else {
            [void](Show-ResultDialog $owner '输入 IP 连接' "连不上 $addr" '电脑上查询设备状态失败（adb 没返回设备列表），这次没有断开任何连接；请稍后重试。' $out @('ok'))
        }
    }) $dlg $connectionFlow })
    $dlg.Controls.AddRange(@($l1, $l2, $l3, $txtIp, $l4, $txtPort, $btnGo))
    $dlg.AcceptButton = $btnGo
    New-EscCancel $dlg
    [void]$dlg.ShowDialog($owner)
    if ($result.addr) { Touch-KnownDevice $result.addr (Get-FriendlyName $result.addr -CachedOnly) }
    return $result.addr
}

# ---------------- 设备管理：切换 / 断开 / 设默认 / 忘记 / IP 直连 ----------------
function Show-DeviceManager {
    param($owner)
    $dlg = New-Dialog '设备管理' 520 396 $owner

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location = '16,14'; $lv.Size = '488,190'
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $true; $lv.HideSelection = $false
    $lv.HeaderStyle = 'Nonclickable'; $lv.BackColor = $cWhite
    $lv.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    # 空态提示放列表下方常驻一行：ListView 的行文字只占第一列宽，长指引会被截没
    $capNoDev = New-Caption '还没有设备？点下方「输入 IP 连接…」添加，或回主界面点「无线投屏」' 16 209
    [void]$lv.Columns.Add('设备', 146)
    [void]$lv.Columns.Add('地址', 128)
    [void]$lv.Columns.Add('类型 · 系统', 204)   # 这栏要装下「无线 · Android 13  ▶ 投屏中  ⊘ 不自动连」，给它最宽，别截断
    # 三列合计 478 < 列表内宽，留点余量，避免出现底部水平滚动条
    $grpConn  = New-Object System.Windows.Forms.ListViewGroup -ArgumentList '已连接'
    $grpKnown = New-Object System.Windows.Forms.ListViewGroup -ArgumentList '已记住（未连接）'
    [void]$lv.Groups.Add($grpConn)   # 逐个加：AddRange 收 PS 的 Object[] 会因类型转换失败
    [void]$lv.Groups.Add($grpKnown)

    # 两条发丝线把按钮分成「投屏 / 管理 / 全局」三组，组左侧的小字标签说明这组按钮是干嘛的（结构即信息）
    $line1 = New-Object System.Windows.Forms.Panel; $line1.Size = New-Object System.Drawing.Size(488, 1); $line1.Location = New-Object System.Drawing.Point(16, 230); $line1.BackColor = $cLine
    $line2 = New-Object System.Windows.Forms.Panel; $line2.Size = New-Object System.Drawing.Size(488, 1); $line2.Location = New-Object System.Drawing.Point(16, 334); $line2.BackColor = $cLine

    # 第一组「投屏」：连接与投屏分开——连接只负责连上，投屏只负责开镜像窗口（已连的才可投）
    # 三行按钮共用 5 列栅格（58/150/242/334/426，末列宽 78、右缘 504），行与行列对齐
    $capCast = New-Caption '投屏' 16 257
    $btnConnect = New-SecondaryBtn '连接'    58  248 86  34
    $btnCast    = New-SecondaryBtn '投屏'    150 248 86  34
    $btnStop    = New-SecondaryBtn '停止投屏' 242 248 86  34
    $btnAll     = New-SecondaryBtn '全部投屏' 426 248 78  34
    # 第二组「管理」：对单台设备的设置项
    $capManage  = New-Caption '管理' 16 299
    $btnDefault = New-SecondaryBtn '设为默认' 58  290 86  34
    $btnDisc    = New-SecondaryBtn '断开'    150 290 86  34
    $btnRename  = New-SecondaryBtn '重命名'   242 290 86  34
    $btnForget  = New-SecondaryBtn '忘记'    334 290 86  34
    $btnAuto    = New-SecondaryBtn '不自动连' 426 290 78  34   # 切换：把选中无线设备移入/移出「不自动连接」名单
    # 第三组「全局」
    $btnIp      = New-SecondaryBtn '输入 IP 连接…' 16 346 150 34
    $btnRefresh2= New-SecondaryBtn '刷新'    334 346 86  34
    $btnDone    = New-PrimaryBtn   '完成'    426 346 78  34 10
    $tt.SetToolTip($btnConnect, '把选中的离线设备连上，只连不开窗。')
    $tt.SetToolTip($btnCast, '为选中的已连设备开一个镜像窗口。')
    $tt.SetToolTip($btnStop, '只关选中那台的镜像窗口，其它设备不受影响。')
    $tt.SetToolTip($btnAll, '给每台已连接、还没开窗的设备各开一个窗口。')
    $tt.SetToolTip($btnDefault, '多设备时，其它功能默认对这台做；再点一次取消。')
    $tt.SetToolTip($btnDisc, '断开这台的无线连接，并先关掉它的投屏窗口（其它设备不受影响）。它仍留在「已记住」里，下次打开助手会自动连回，但断开后不会立刻自己偷偷连回来。想让它以后都不自动连，用「不自动连」。USB 设备请直接拔数据线。')
    $tt.SetToolTip($btnRename, '起个好认的名字，窗口标题和设备列表都会用。')
    $tt.SetToolTip($btnForget, '从「已记住」里去掉，这台设备的自定义名字和「默认设备」标记也一并清掉；以后连上会重新记住。设备还连着时点不动——要先「断开」（或拔掉数据线），否则它会立刻被重新记住。')
    $tt.SetToolTip($btnAuto, '不自动连：助手启动和掉线时都不再自动连这台（再点恢复自动连）。')

    # refresh 把「已连接设备」「正在投屏的序列号」算一次塞进 $state；updateButtons 只读它，不再每次点都跑 adb
    $state = @{ Active = @(); Connected = @(); SnapshotReady=$false }

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
        $state.SnapshotReady=$false
        $snapshot=Wait-UiTask -Owner $dlg -Inputs @{ Adb=$adb } -Work {
            Invoke-DeviceScan -AdbPath $Inputs.Adb -Candidates @() -ConnectAlways $false -InfoCache $InfoCache -Control $Control
        }
        if ($snapshot.Cancelled) { return }
        if (-not $snapshot.Success) {
            [void](Show-ResultDialog $dlg '设备管理' '查询设备失败，请稍后重试' '设备列表暂未更新，可以稍后重试。' $snapshot.Error @('ok'))
            return
        }
        foreach ($key in $snapshot.Info.Keys) { $script:devInfo[$key]=$snapshot.Info[$key] }
        $active = Get-ActiveSerials; $state.Active = $active
        $selSerials = @($lv.SelectedItems | Where-Object { $_.Tag } | ForEach-Object { $_.Tag.Serial })   # 刷新前记住选中项
        $lv.BeginUpdate(); $lv.Items.Clear()
        $connected = @($snapshot.Devices); $state.Connected = $connected
        foreach ($s in $connected) {
            $info = Get-DevInfo $s -CachedOnly; $wl = Test-Wireless $s
            $tag = if ($settings.defaultDevice -eq $s) { '  ★默认' } else { '' }
            $it = New-Object System.Windows.Forms.ListViewItem(('●  ' + (Get-FriendlyName $s -CachedOnly) + $tag))
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
            $it = New-Object System.Windows.Forms.ListViewItem(('○  ' + (Get-FriendlyName $addr -CachedOnly)))
            $it.Group = $grpKnown; $it.ForeColor = $cMuted
            [void]$it.SubItems.Add($addr)
            $typ2 = '无线 · 未连接'; if (Test-AutoConnectExcluded $addr) { $typ2 += '  ⊘ 不自动连' }
            [void]$it.SubItems.Add($typ2)
            $it.Tag = @{ Serial = $addr; Connected = $false; Wireless = $true }
            [void]$lv.Items.Add($it)
        }
        if ($lv.Items.Count -eq 0) {
            $empty = New-Object System.Windows.Forms.ListViewItem('（还没有设备）')
            $empty.Group = $grpConn   # 不挂组会冒出英文组头 Default
            $empty.ForeColor = $cMuted; [void]$lv.Items.Add($empty)
        }
        $capNoDev.Visible = ($lv.Items.Count -eq 1 -and $lv.Items[0].Text -eq '（还没有设备）')
        foreach ($it in $lv.Items) { if ($it.Tag -and ($selSerials -contains $it.Tag.Serial)) { $it.Selected = $true } }   # 还原选中
        $lv.EndUpdate(); & $updateButtons
        $state.SnapshotReady=$true
    }

    # 连接选中的未连设备（只连，不投）：连成功后它会进到「已连接」组，再点「投屏」即可
    $connectSelected = {
        $items = @($lv.SelectedItems | Where-Object { $_.Tag -and -not $_.Tag.Connected })
        if ($items.Count -eq 0) { return }
        $connection=Connect-DevicesUi $dlg @($items | ForEach-Object { $_.Tag.Serial })
        if ($connection.Cancelled) { return }
        $fail=@()
        foreach ($record in $connection.Records) {
            if ($record.Success) { Touch-KnownDevice $record.Address (Get-FriendlyName $record.Address -CachedOnly) }
            else { $fail += "$($record.Address)：$($record.Error)" }
        }
        if ($fail) { [void](Show-ResultDialog $dlg '设备管理' ("有 " + $fail.Count + " 台没连上") '多半是手机不在线，或没开「无线调试」。确认手机和电脑连的同一个 Wi-Fi 后可重试，或先插一次线。' ($fail -join "`r`n") @('ok')) }
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
        & $refresh
        if (-not $state.SnapshotReady) { return }
        $active = Get-ActiveSerials
        foreach ($s in @($state.Connected)) {
            if ($active -contains $s) { continue }
            Start-Scrcpy (@('-s', $s) + (Get-MirrorArgs -Wireless:(Test-Wireless $s)))
        }
        & $refresh
    }
    # 停止投屏：只关掉选中设备的投屏窗口，不影响其它台
    $stopSelected = {
        [void](Stop-DevicesUi $dlg @($lv.SelectedItems | Where-Object { $_.Tag } | ForEach-Object { $_.Tag.Serial }))
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
    $lv.Add_DoubleClick({ Invoke-MainFlow ({ & $rowDouble }) $dlg $script:dmFlow })
    $btnConnect.Add_Click({ Invoke-MainFlow ({ & $connectSelected }) $dlg $script:dmFlow })
    $btnCast.Add_Click({ Invoke-MainFlow ({ & $castSelected }) $dlg $script:dmFlow })
    $btnStop.Add_Click({
        $oldStopText = $btnStop.Text
        $btnStop.Text = '正在停止…'; $btnStop.Enabled = $false; $dlg.Refresh()
        try { Invoke-MainFlow ({ & $stopSelected }) $dlg $script:dmFlow }
        finally {
            $btnStop.Text = $oldStopText
            # 忙态直接 return / body 抛异常时 stopSelected 不会跑，必须自己把按钮状态算回来
            try { & $updateButtons } catch { $btnStop.Enabled = $true }
            $dlg.Refresh()
        }
    })
    $btnAll.Add_Click({ Invoke-MainFlow ({ & $castAll }) $dlg $script:dmFlow })
    $btnDisc.Add_Click({ Invoke-MainFlow ({
        $items = @($lv.SelectedItems | Where-Object { $_.Tag }); if ($items.Count -ne 1) { return }
        $addr = $items[0].Tag.Serial
        $stopped=Stop-DevicesUi $dlg @($addr) -Disconnect
        if ($stopped.Cancelled -or -not $stopped.Success) { & $refresh; return }
        $dirty = $false
        if ($settings.defaultDevice -eq $addr) { $settings.defaultDevice = ''; $dirty = $true }
        # 主动断开的那台别再被 8s 轮询连回来：Reconnect-LastAsync 只认 lastWirelessAddr，不清就等于「断开没生效」。
        # （「忘记」同理，见下面的 btnForget。）
        if ($settings.lastWirelessAddr -eq $addr) { $settings.lastWirelessAddr = ''; $dirty = $true }
        if ($dirty) { Save-Settings }
        & $refresh
    }) $dlg $script:dmFlow })
    $btnDefault.Add_Click({ Invoke-MainFlow ({
        $items = @($lv.SelectedItems | Where-Object { $_.Tag }); if ($items.Count -ne 1) { return }
        $s = $items[0].Tag.Serial
        $settings.defaultDevice = if ($settings.defaultDevice -eq $s) { '' } else { $s }   # 再点一次取消默认
        Save-Settings; & $refresh
    }) $dlg $script:dmFlow })
    $btnRename.Add_Click({ Invoke-MainFlow ({
        $items = @($lv.SelectedItems | Where-Object { $_.Tag }); if ($items.Count -ne 1) { return }
        $s = $items[0].Tag.Serial
        $name = [Microsoft.VisualBasic.Interaction]::InputBox("给这台设备起个名字（如 客厅电视）：", '重命名设备', (Get-FriendlyName $s -CachedOnly))
        $name = $name.Trim()
        if ($name -and $name -ne (Get-FriendlyName $s -CachedOnly)) { $script:deviceNames[$s] = $name; Save-Settings; & $refresh }
    }) $dlg $script:dmFlow })
    $btnForget.Add_Click({ Invoke-MainFlow ({
        $items = @($lv.SelectedItems | Where-Object { $_.Tag }); if ($items.Count -ne 1) { return }
        $addr = $items[0].Tag.Serial
        if ($script:knownDevices.Contains($addr)) { $script:knownDevices.Remove($addr) }
        if ($script:deviceNames.Contains($addr)) { $script:deviceNames.Remove($addr) }   # 忘记设备时一并清掉它的自定义名
        if ($settings.defaultDevice -eq $addr) { $settings.defaultDevice = '' }
        # 若忘记的正是"上次无线地址"，一并清掉——否则主界面 8s 轮询会用它 Reconnect-LastAsync 连回来、再 Add-KnownDevice 把它重新记住，忘记等于白忘
        if ($settings.lastWirelessAddr -eq $addr) { $settings.lastWirelessAddr = '' }
        Save-Settings; & $refresh
    }) $dlg $script:dmFlow })
    $btnAuto.Add_Click({ Invoke-MainFlow ({
        $items = @($lv.SelectedItems | Where-Object { $_.Tag }); if ($items.Count -ne 1) { return }
        $addr = $items[0].Tag.Serial
        if (-not (Test-Wireless $addr)) { return }
        Set-AutoConnectExcluded $addr (-not (Test-AutoConnectExcluded $addr))
        & $refresh
    }) $dlg $script:dmFlow })
    $btnIp.Add_Click({ Invoke-MainFlow ({ if (Connect-ByIp $dlg) { & $refresh } }) $dlg $script:dmFlow })
    $btnRefresh2.Add_Click({ Invoke-MainFlow ({ & $refresh }) $dlg $script:dmFlow })
    $btnDone.Add_Click({ $dlg.Close() })

    $dlg.Controls.AddRange(@($lv, $capNoDev, $line1, $line2, $capCast, $capManage,
        $btnConnect, $btnCast, $btnStop, $btnAll, $btnDefault, $btnDisc, $btnRename, $btnForget, $btnAuto,
        $btnIp, $btnRefresh2, $btnDone))
    $dlg.AcceptButton = $btnDone
    $dlg.CancelButton = $btnDone   # Esc=完成（关闭）
    & $refresh
    [void]$dlg.ShowDialog($owner)
}

# ---------------- 文件管理：基于 adb shell 的可视化文件管理器 ----------------
# 设计取舍（都是容易踩回去的坑，改之前先看这段）：
# 1) 列目录只用「一次 adb shell」：设备端跑一段 for + printf，输出 Tab 分隔的
#    类型 / 名称 / 字节数 / 修改时间(Unix 秒) 四列。不解析 ls -l：toybox / busybox / 各厂商 ROM
#    的列数都不一样（有无 group、SELinux label、日期带不带年份），正则解析很脆。
#    时间用 stat -c %Y 拿数字秒再在本地换算，不解析 %y 可读日期：各 ROM 的日期格式、时区都不一致。
#    它只是展示信息，读不到就显示「—」，绝不能让时间字段把整个文件条目弄丢。
#    性能：条目行只用内建命令，路径攒进位置参数后每 128 个批量跑一次 stat，属性另出 S 行、
#    在 Fm-ParseListLines 里按序回填；fork 次数从 ~4N 降到 ~2N/128。属性行数对不上就回退
#    逐文件模板重读一次，绝不把 A 的大小硬配到 B 上。
# 2) 设备端路径一律用 sh 单引号字面量包（Fm-ShQuote）：'$'、反引号、双引号、空格、单引号本身
#    都不会被设备 shell 解释，顺带从根上堵掉「文件名被当成命令」的注入。
# 3) adb 客户端对 `adb shell` 参数的处理随 platform-tools 版本变过：有的把整串直接交给设备 sh，
#    有的会对参数做 shell 转义（整串会被当成一个命令名，报 not found）。Get-FmShellArgs 用一条探针
#    自动判定，之后所有命令按对应写法发；设置里换了 adb 路径也不用改代码。
# 4) push / pull 不走 Invoke-Hidden：它 15s 超时会杀掉正在传大文件的 adb，且同步等待会冻住界面。
#    Fm-Transfer 用异步读 stdout/stderr + DoEvents 泵消息，界面能重绘、能显示「正在上传 2/5」和进度条。
# 5) push / pull 的远端路径不经过设备 shell（adb 自己解析），所以不用 Fm-ShQuote，只需
#    Windows 命令行这一层的引号（Fm-WinArg）。
# 6) 安全底线：删除目标只用「列表里的名字」，绝不用可能被污染的 Tag.Path；设备端先 cd 到
#    当前目录再 rm ./名字，范围钉死在这一层。Fm-ValidName 会把含 '/'、控制字符的名字整条丢掉，
#    因为列目录协议是 Tab 分隔 / 换行分记录，这类名字能伪造出结构化行。
# 7) 删除走 Fm-ShellLong（不设总超时）：普通设备端命令走新版后台任务的 15s 上限，删几千张
#    照片的目录会被超时掐断，造成「删了一半却报失败」。结论里没有 FM_OK / FM_FAIL 就立即停止
#    后续项，并提示可能已部分完成。
# 8) adb push / pull 会静默覆盖同名文件，等同于丢数据：传之前分别查设备端 / 本地同名项，
#    默认落在「取消」上，用户可选覆盖、跳过同名或整体取消。
# 9) 符号链接单列成 L，不被当成文件夹（不会误用 rm -rf，也不会让人误以为删掉了目标目录内容）。
# 10) 键盘导航挂在窗体上（KeyPreview）：← 上一级，→ / Enter 进入选中文件夹，和双击 / 按钮共用
#     $goUp / $openSelected 一套判断。路径框和设备下拉框有焦点时让出按键，组合键也一律不碰；
#     没选中文件夹时 Enter 不吞键，免得抢走按钮的原生回车，或在选中文件时假装在导航。
# 11) 列表重建用 ListViewItem[] + Items.AddRange 一次填充，不逐项 Items.Add；读目录前先把
#     状态行刷成「正在读取…」，等待时也看得出在干活。
# 12) 批量操作（上传 / 下载 / 删除）一开始就把设备和目录快照到 $batchSerial / $batchPath，
#     整批只认这两个值；等待期间 DoEvents 会泵消息，设备下拉框的 SelectedIndexChanged 仍会来，
#     忙时既不接受切换也把下拉框拨回去。否则第一项传去 A 手机、第二项就传去 B 手机了。
# 13) 目录协议有 FM_DONE 结束标记（V2 和兼容回退模板都打）。adb 启动失败、设备掉线、输出
#     被截断都会缺这个标记，一律判「读不到」，绝不把空输出显示成「这个文件夹是空的」。
# 14) 设备列表由入口的 Invoke-MainFlow -WithDevices 异步交付：新版 Ensure-Devices 只启动后台扫描，
#     通过 OnDone / OnFinally 回调，不再同步返回数组。查询失败、取消、忙态收尾都由 Invoke-MainFlow
#     统一处理；Show-FileManager 只接设备数组，空数组才是「扫描成功但确实没连手机」。
# 15) 设备端 shell 命令走新版 Start-UiTask：worker 里只跑 Invoke-ShortCommand（15s 硬上限，
#     不放宽全局 ValidateRange），不碰任何 UI 控件；取消靠 Cancel-OwnerTasks / Stop-DeviceScans，
#     关窗后 OnFinally 仍会复位。慢目录读不完就取消，界面不会冻住也不会留下「正在读取…」。
#     首屏读目录挂在窗口的 Shown 上：ShowDialog 之前 Visible=false，任何拿 Visible 当「已关闭」
#     的判断都会把第一次列目录误取消，症状是「打开就报打不开这个目录、点一下快捷入口却正常」。
# 16) adb pull 指定独立的目标临时名，便于验证本次产物，避免把原有同名文件误当作下载成功。
#     参数统一用 Fm-WinArg 加引号，Windows 非法字符提前拦。中文目标路径的编码问题见 18)。
# 17) 重命名只对「恰好选中一项」开放（按钮 + F2）：设备端 cd 到快照目录后 mv ./旧名 ./新名，
#     和新建共用 $fmBadNameChars 校验。同名直接拒绝——重命名覆盖等于静默删掉目标文件；
#     mv 后双向确认「新名在、旧名不在」才报成功，避免只读目录里误报。
# 18) 下载用所选目录作为进程工作目录，adb 只接收 ASCII 相对暂存名，避免依赖盘符根目录权限。
#     文件合并由后台任务执行，取消标志逐块检查；每个文件写完后才原子替换，保留取消时的原件。

# 设备端 sh 的单引号字面量：内部的 ' 用 '\'' 表示（闭合 + 转义单引号 + 重开）。
function Fm-ShQuote {
    param([string]$s)
    $sq = "'" + [string][char]92 + "''"
    return "'" + $s.Replace("'", $sq) + "'"
}

# Windows 命令行参数引用（CommandLineToArgvW 的逆变换）：处理空格、内嵌双引号、以及结尾反斜杠。
# 结尾反斜杠必须翻倍，否则选了 C:\ 当下载目录时，尾部 \ 会把收尾引号转义掉，路径当场被截断。
# 一律加引号，不再「看着安全就不加」：pull / push 的路径常是中文、含空格或带多个扩展名，
# 无引号参数在不同 adb / CRT 版本上的解析不一致，正是「D:\Desktop\.」「文件名被截断」这类
# 诡异报错的来源。带引号对 -s、pull 这类普通参数完全无害。
function Fm-WinArg {
    param([string]$s)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append([char]34)
    $slashes = 0
    foreach ($ch in $s.ToCharArray()) {
        if ($ch -eq [char]92) { $slashes++; continue }
        if ($ch -eq [char]34) {
            [void]$sb.Append([char]92, ($slashes * 2 + 1))
            [void]$sb.Append([char]34)
        } else {
            if ($slashes -gt 0) { [void]$sb.Append([char]92, $slashes) }
            [void]$sb.Append($ch)
        }
        $slashes = 0
    }
    if ($slashes -gt 0) { [void]$sb.Append([char]92, ($slashes * 2)) }
    [void]$sb.Append([char]34)
    return $sb.ToString()
}

function Fm-SizeText {
    param($n)
    $v = 0L
    if (-not [long]::TryParse([string]$n, [ref]$v)) { return '—' }
    if ($v -lt 0) { return '—' }
    if ($v -lt 1024) { return "$v B" }
    if ($v -lt 1MB)  { return ('{0:N1} KB' -f ($v / 1KB)) }
    if ($v -lt 1GB)  { return ('{0:N1} MB' -f ($v / 1MB)) }
    return ('{0:N2} GB' -f ($v / 1GB))
}

# 设备端给的是 stat -c %Y 的 Unix 秒（绝对时间点），在电脑这边按本地时区显示，
# 跟资源管理器里看到的手机文件时间一致。基准必须是 Kind=Utc 的 DateTime：
# 若用 [datetime]'1970-01-01T00:00:00Z'，PowerShell 会先把带 Z 的字符串折算成本地时间，
# 之后再 ToLocalTime() 会二次加 8 小时。
function Fm-TimeText {
    param($n)
    $v = 0L
    if (-not [long]::TryParse([string]$n, [ref]$v)) { return '—' }
    if ($v -le 0 -or $v -gt 4102444800) { return '—' }   # 1970 前 / 2100 后多半是脏数据或格式符原样回显
    try {
        $epoch = New-Object System.DateTime(1970, 1, 1, 0, 0, 0, ([System.DateTimeKind]::Utc))
        return $epoch.AddSeconds([double]$v).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
    } catch { return '—' }
}

function Fm-NormPath {
    param([string]$p)
    $t = ([string]$p).Trim()
    if (-not $t) { return '/' }
    $t = $t -replace '/+', '/'
    if (-not $t.StartsWith('/')) { $t = '/' + $t }
    # 词法上把 . / .. 消掉：路径栏显示什么，就真的是什么位置。
    # 不这样做的话，填 /sdcard/../system 能进去，但确认框里仍印着带 .. 的路径，
    # 用户照着这个位置判断「删的是哪一层」会判断错。
    $stack = New-Object System.Collections.ArrayList
    foreach ($seg in $t.Split('/')) {
        if (-not $seg -or $seg -eq '.') { continue }
        if ($seg -eq '..') { if ($stack.Count -gt 0) { $stack.RemoveAt($stack.Count - 1) }; continue }
        [void]$stack.Add($seg)
    }
    if ($stack.Count -eq 0) { return '/' }
    return '/' + ($stack -join '/')
}

# 设备端文件名合法性：Linux 文件名除了 '/' 和 NUL 几乎什么都能有，但我们的列目录协议是
# Tab 分隔 + 换行分记录，含控制字符的名字会撕裂协议、伪造出结构化行。宁可不显示，也不能让它
# 变成一个「看起来能点、删起来却指向别处」的条目。
# 反斜杠在设备端本身无害，但它紧挨内嵌双引号时会扰乱 Windows 命令行的 \" 转义，一并排除；
# 这类名字只会被隐藏（不可删），不会造成误判。
function Fm-ValidName {
    param([string]$s)
    if ([string]::IsNullOrEmpty($s)) { return $false }
    if ($s -eq '.' -or $s -eq '..') { return $false }
    if ($s.IndexOf('/') -ge 0 -or $s.IndexOf([char]92) -ge 0) { return $false }
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        if ($c -lt 32 -or $c -eq 127) { return $false }
    }
    return $true
}
# 「新建」和「重命名」输入的新名字必须用同一套更严的规则：设备端路径已经用 Fm-ShQuote 包成
# 单引号字面量，但 Windows 侧 / 用户输入框里这些符号仍会带来歧义，且名称里带 shell 元字符时
# 报错很难读懂。两处共用一份，免得哪天只改了一处、文案与行为对不上。
$fmBadNameChars = [char[]]@('\', '/', ':', '*', '?', '"', '<', '>', '|', "'", '`', '$', ';', '&', [char]13, [char]10)
function Fm-ParentPath {
    param([string]$p)
    $t = Fm-NormPath $p
    if ($t -eq '/') { return '/' }
    $i = $t.LastIndexOf('/')
    if ($i -le 0) { return '/' }
    return $t.Substring(0, $i)
}
function Fm-ChildPath {
    param([string]$parent, [string]$name)
    $t = Fm-NormPath $parent
    if ($t -eq '/') { return '/' + $name }
    return $t + '/' + $name
}

# 探测 adb shell 的参数写法。探针里同时含分号与空格：只有「整串被设备 sh 真正执行」才会
# 出现单独一行 FM_SHELL_RAW_OK；被转义成一个命令名时不会。两种写法都试，取能执行的那种。
$script:fmShellMode = $null
function Get-FmShellArgs {
    param($serial, [string]$Command, $Control)
    if ($null -eq $script:fmShellMode) {
        $probe = 'echo FM_SHELL_RAW_OK; echo A B'
        $hit = { param($lines) return ([bool](@($lines | Where-Object { ([string]$_).Trim() -eq 'FM_SHELL_RAW_OK' }).Count -gt 0)) }
        $probeResult = Invoke-ShortCommand -FilePath $adb -ArgumentList @('-s', $serial, 'shell', $probe) -Control $Control
        $r1 = @($probeResult.Stdout -split "`r?`n")
        if ($Control -and $Control.Cancelled) { throw '操作已取消' }
        if (& $hit $r1) {
            $script:fmShellMode = 'raw'
        } else {
            $probeResult = Invoke-ShortCommand -FilePath $adb -ArgumentList @('-s', $serial, 'shell', 'sh', '-c', $probe) -Control $Control
            $r2 = @($probeResult.Stdout -split "`r?`n")
            if (-not (& $hit $r2)) { throw '无法确认设备 shell' }
            $script:fmShellMode = if (& $hit $r2) { 'quoted' } else { 'raw' }
        }
    }
    if ($script:fmShellMode -eq 'raw') { return @('-s', $serial, 'shell', $Command) }
    return @('-s', $serial, 'shell', 'sh', '-c', $Command)
}

# 新版 main 的 Invoke-Hidden / Invoke-ShortCommand 都带 ValidateRange(1,15000)，
# 旧的 -TimeoutMs 20000 会在参数绑定阶段直接失败，绝不为这一次调用去放宽全局上限。
# 改用同一套 Start-UiTask 后台任务：worker 里只有 Invoke-ShortCommand（结构化结果、15s 硬上限、
# 受 $Control 取消标志约束），不读写任何 UI 控件；结果经 OnDone 回到 UI 线程。
# 不用现成的 Wait-UiTask / Invoke-UiCommand：它们每次都会弹一个模态等待窗，而列目录是高频操作，
# 闪一下会盖掉「正在读取…」状态行。这里在同一套机制上用 DoEvents 泵消息等价等待；关窗由
# Owner 的 FormClosed 调 Cancel-OwnerTasks，退出时 Stop-DeviceScans 兜底，OnFinally 无条件复位。
# 等待循环绝不可用 Visible 判断关窗：ShowDialog 之前窗口本来就是 Hidden，首屏读目录会被自己取消。
function Invoke-FmTask {
    param($Owner, [scriptblock]$Work, [hashtable]$Inputs, [string[]]$Functions = @())
    $box = @{ Done = $false; Result = $null }
    $received = { param($value) $box.Result = $value }.GetNewClosure()
    $finished = { $box.Done = $true }.GetNewClosure()
    Start-UiTask -Owner $Owner -Kind 'operation' -Inputs $Inputs -Work $Work -Functions $Functions -OnDone $received -OnFinally $finished
    $cancelled = $false
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (-not $box.Done) {
        [System.Windows.Forms.Application]::DoEvents()
        # 关窗 / 退出交给 Owner 的 FormClosed（Cancel-OwnerTasks）与 Stop-DeviceScans，
        # 这里只兜一个「控件已释放」。绝不能用 Visible 判断：窗口在 ShowDialog 之前本来就是
        # Hidden，首次进目录会被自己取消，表现成「打不开这个目录」，点一下快捷入口又正常。
        if (-not $cancelled -and $Owner -and $Owner.IsDisposed) {
            $cancelled = $true
            Cancel-OwnerTasks $Owner
        }
        # 兜底：万一 Timer 没 tick、任务卡在队列里，也不让 UI 线程无限等下去。
        # 15s 是单条命令上限，前面还可能排着一个最多 15s 的设备扫描，35s 留足余量。
        if (-not $cancelled -and $Inputs.ContainsKey('LimitMs') -and $clock.ElapsedMilliseconds -gt 35000) {
            $cancelled = $true
            Cancel-OwnerTasks $Owner
        }
        Start-Sleep -Milliseconds 20
    }
    if ($box.Result) { return $box.Result }
    return [pscustomobject]@{ Ok = $false; Cancelled = $true; Error = '操作已取消' }
}
function Invoke-FmShell {
    param($Owner, $serial, [string]$Command)
    $r = Invoke-FmTask $Owner -Functions @('Get-FmShellArgs') -Inputs @{ Adb=$adb; Serial=$serial; Command=$Command; Mode=$script:fmShellMode; LimitMs=15000 } -Work {
        $adb = $Inputs.Adb
        $script:fmShellMode = $Inputs.Mode
        try {
            $argv = @(Get-FmShellArgs $Inputs.Serial $Inputs.Command $Control)
            $r = Invoke-ShortCommand -FilePath $adb -ArgumentList $argv -TimeoutMs 15000 -Control $Control
            [pscustomobject]@{ Info=@{}; Connected=@(); Mode=$script:fmShellMode
                Ok=($r.Started -and $r.ExitCode -eq 0 -and -not $r.TimedOut -and -not $r.Cancelled)
                Lines=@($r.Stdout -split "`r?`n"); Err=$r.Stderr; Cancelled=$r.Cancelled }
        } catch { [pscustomobject]@{ Info=@{}; Connected=@(); Ok=$false; Cancelled=[bool]$Control.Cancelled; Error=$_.Exception.Message } }
    }
    if ($r.Mode) { $script:fmShellMode=$r.Mode }
    return $r
}

# 兼容既有调用方：只回文本行。失败 / 超时 / 取消一律回空数组——目录协议缺 FM_DONE 会判「读不到」，
# 同名检查缺 FM_DONE 会取消上传，绝不会把「没拿到结果」当成「空文件夹」或「没有同名文件」。
function Fm-Shell {
    param($serial, [string]$Command, $Owner)
    $o = if ($Owner) { $Owner } else { $form }
    $r = Invoke-FmShell $o $serial $Command
    if (-not $r.Ok) { return @() }
    $lines = @($r.Lines)
    if ($r.Err) { $lines += @($r.Err -split "`r?`n") }
    return @($lines)
}

# 删除专用的长时 shell：普通设备端命令走新版后台任务的 15s 上限，删几千张照片的目录时会在半路
# kill 掉 adb —— 目录已经删了一部分，连 FM_OK/FM_FAIL 都没机会打印，界面却报「没删成功」，
# 用户以为什么都没动。这里不设总超时，靠 DoEvents 泵消息保持界面能重绘；中途关窗则主动中止，
# 并由调用方如实提示「可能已部分删除」，绝不给出「什么都没发生」的假结论。
function Fm-ShellLong {
    param($serial, [string]$Command, $dlg, $status, [string]$tip)
    # 窗口已关就一条命令都别发：短命令可能在 WaitForExit(120) 的第一轮就跑完，
    # 根本进不到下面的关窗检查，外层批量循环会误以为这项正常结束、接着删下一项。
    if ($dlg -and ($dlg.IsDisposed -or -not $dlg.Visible)) {
        return @{ Aborted = $true; Output = '' }
    }
    if ($null -eq $script:fmShellMode) {
        $probe = Invoke-FmShell $dlg $serial 'true'
        if (-not $probe.Ok) { return @{ Code=-1; Aborted=$true; Output='' } }
    }
    if ($dlg -and ($dlg.IsDisposed -or -not $dlg.Visible)) { return @{ Code=-1; Aborted=$true; Output='' } }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $adb
    $psi.Arguments = (@((Get-FmShellArgs $serial $Command) | ForEach-Object { Fm-WinArg $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try { $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8 } catch {}
    try { $p = [System.Diagnostics.Process]::Start($psi) } catch { return @{ Aborted = $false; Output = $_.Exception.Message } }
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if ($status) { try { $status.Text = $tip; $status.Refresh() } catch {} }
    $aborted = $false
    while (-not $p.WaitForExit(120)) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($dlg -and ($dlg.IsDisposed -or -not $dlg.Visible)) {
            try { $p.Kill() } catch {}
            $aborted = $true
            break
        }
    }
    try { [void][System.Threading.Tasks.Task]::WaitAll(@($outTask, $errTask), 3000) } catch {}
    $out = if ($outTask.IsCompleted -and -not $outTask.IsFaulted) { $outTask.Result } else { '' }
    $err = if ($errTask.IsCompleted -and -not $errTask.IsFaulted) { $errTask.Result } else { '' }
    $code = try { $p.ExitCode } catch { -1 }
    try { $p.Dispose() } catch {}
    return @{ Code = $code; Aborted = $aborted; Output = (($out + "`n" + $err).Trim()) }
}

# 设备端脚本用单引号 here-string：里面的 $f / $p / $(...) 是给设备 sh 用的，绝不能让 PowerShell 先插值。
# 用 ./ 前缀让以 - 开头的文件名不会被 stat / test 当成选项；glob 里 . 与 .. 由两个补集模式排除。
# 每行四列：类型 / 名称 / 字节数 / 修改时间(Unix 秒)。ERR 行也必须凑齐四列，
# 否则按四列解析时会被当成噪声跳过，读不到目录反而显示成「空文件夹」。
#
# 性能（进目录卡几秒的主因）：原来每个条目都要 t=$(stat -c %Y)，普通文件再来一次 $(stat -c %s)，
# 每次命令替换都要 fork 一个子 shell 再 exec stat，约 4 次 fork/exec/条目，几百个文件就是上千次。
# 现在循环里只用内建命令输出「类型/名称 + 占位」，把路径攒进位置参数，每 128 个跑一次
# stat -c 'S %s %Y'（toybox / busybox / GNU stat 都支持多文件、每文件一行），属性另出 S 行由
# Fm-ParseListLines 按顺序回填。fork 次数从 ~4N 降到 ~2N/128，跟文件数基本脱钩。
# 细节：S 行用空格分隔——toybox stat -c 的格式串只 putchar 普通字符，并不解释 \t；
# stat 输出用 $(...) 收回后由 shell 自己 printf，避免内建 printf 的缓冲与外部进程输出交错；
# toybox stat 默认 lstat，符号链接取链接自身，不会顺着跑到别处。
$fmListTemplate = (@'
cd __PATH__ 2>/dev/null || { printf 'ERR\t%s\t-\t-\n' cannot-enter; exit 1; };
printf 'V2\n';
n=0; set --;
for f in * .[!.]* ..?*; do
  ctrl=$(printf '\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037\177'); case "$f" in *["$ctrl"]*) continue;; esac;
  p="./$f"; [ -e "$p" ] || [ -L "$p" ] || continue;
  if [ -L "$p" ]; then k=L; elif [ -d "$p" ]; then k=D; else k=F; fi;
  printf '%s\t%s\t-\t-\n' "$k" "$f";
  set -- "$@" "$p"; n=$((n+1));
  if [ "$n" -ge 128 ]; then s=$(stat -c 'S %s %Y' "$@" 2>/dev/null); printf '%s\n' "$s"; n=0; set --; fi;
done;
if [ "$n" -gt 0 ]; then s=$(stat -c 'S %s %Y' "$@" 2>/dev/null); printf '%s\n' "$s"; fi;
printf 'FM_DONE\n'
'@) -replace "`r?`n", ' '

# 兼容回退：老 ROM 的 stat 若不支持多参数，或某个文件 stat 失败（toybox 会跳过该文件、少输出一行），
# 属性行数就对不上，这时绝不硬配对（会把大小/时间张冠李戴），改用逐文件模板重读一次。
$fmListTemplateLegacy = @'
cd __PATH__ 2>/dev/null || { printf 'ERR\t%s\t-\t-\n' cannot-enter; exit 1; }; for f in * .[!.]* ..?*; do ctrl=$(printf '\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037\177'); case "$f" in *["$ctrl"]*) continue;; esac; p="./$f"; [ -e "$p" ] || [ -L "$p" ] || continue; t=$(stat -c %Y "$p" 2>/dev/null); if [ -L "$p" ]; then printf 'L\t%s\t-\t%s\n' "$f" "$t"; elif [ -d "$p" ]; then printf 'D\t%s\t-\t%s\n' "$f" "$t"; else printf 'F\t%s\t%s\t%s\n' "$f" "$(stat -c %s "$p" 2>/dev/null)" "$t"; fi; done; printf 'FM_DONE\n'
'@
# 解析一次 adb shell 的输出，同时兼容两代模板：
#   V2     —— 条目行四列占位，属性在「S 字节数 秒数」行里按出现顺序批量给出；
#   Legacy —— 属性直接写在条目行的第 3/4 列（无 V2 标记、无 S 行）。
# 两代模板都以 FM_DONE 收尾；没有它说明设备端没跑完（掉线 / 截断 / adb 没起来），
# 这时目录内容不完整，必须报「读不到」，不能当成空文件夹。
function Fm-ParseListLines {
    param($Lines, [string]$path)
    # 设备掉线 / offline 时 adb 只吐一句英文、没有任何结构化行，若不挡住会被当成「空文件夹」，
    # 用户还以为手机里真没东西。宁可显示「读不到」，也不要给出假结论。
    if ((@($Lines) -join "`n") -match '(?i)device (offline|not found)|no devices/emulators|adb: error') {
        return @{ Ok = $false; Items = @(); Hidden = 0; NeedLegacy = $false }
    }
    $items = New-Object System.Collections.ArrayList
    $attrs = New-Object System.Collections.ArrayList
    # 设备端为「每一个」遍历到的条目都 stat 了一次，被隐藏的条目也照样占一格属性。
    # slots[i] 记录第 i 格对应 items 里的下标，-1 表示那一行因协议污染被丢弃。
    # 少了这层映射，只要目录里有一个含 Tab/换行的名字，属性就会整体错位、白白触发回退。
    $slots = New-Object System.Collections.ArrayList
    $hidden = 0
    $isV2 = $false
    $done = $false
    foreach ($raw in @($Lines)) {
        if ($null -eq $raw) { continue }
        # Windows 版 adb 可能把设备端的 LF 换成 CRLF，行尾的 \r 先整体去掉。
        $ln = ([string]$raw).TrimEnd([char[]]@([char]13))
        if (-not $ln) { continue }
        if (([string]$ln).Trim() -eq 'FM_DONE') { $done = $true; continue }
        if ($ln -eq 'V2') { $isV2 = $true; continue }
        # 批量属性行：空格分隔，内容只有数字，不会被文件名里的特殊字符撕裂。
        if ($ln.StartsWith('S ')) {
            $ap = $ln -split ' ', 3
            $as = if ($ap.Count -ge 2) { [string]$ap[1] } else { '' }
            $at = if ($ap.Count -ge 3) { [string]$ap[2] } else { '' }
            # 老 ROM 不认 %Y 会给 '?' 或空，时间只显示「—」；但字节数必须是纯数字，
            # 否则这行不是 stat 给的，宁可少一条属性触发回退，也不能拿脏值算下载进度。
            if ($as -match '^\d+$' -and $at -notmatch '[\x00-\x1F\x7F]') {
                [void]$attrs.Add(@{ Size = $as; Time = $at })
            }
            continue
        }
        $parts = $ln -split "`t", 4
        # ERR 判断放在列数检查之前：万一设备端 printf 有差异只吐了三列，也照样判成「读不到」。
        if ($parts.Count -gt 0 -and $parts[0] -eq 'ERR') {
            return @{ Ok = $false; Items = @(); Hidden = 0; NeedLegacy = $false }
        }
        if ($parts[0] -ne 'D' -and $parts[0] -ne 'F' -and $parts[0] -ne 'L') { continue }
        [void]$slots.Add(-1)
        # 只强制到「类型/名称/大小」三列：时间列允许缺失或为空（旧模板在老 ROM 上会这样）。
        # 列数不够说明名称里的 Tab/换行把协议撕开了，整条隐藏，绝不做出幻影条目。
        if ($parts.Count -lt 3) { $hidden++; continue }
        $nm = $parts[1]; $sz = $parts[2]
        # 严格校验：名称一旦含 '/' 或控制字符，就可能是被换行/Tab 伪造出来的行。
        # 这种行整条丢掉（计数提示用户），绝不能让它变成可点击、可删除的条目。
        if (-not (Fm-ValidName $nm)) { $hidden++; continue }
        # V2 占位行的大小是 '-'；旧模板给的是真实字节数。两者都放行，其它一律视为协议被撕裂。
        if ($parts[0] -eq 'F') {
            if ($sz -and $sz -ne '-' -and $sz -notmatch '^\d+$') { $hidden++; continue }
        } elseif ($sz -ne '-') { $hidden++; continue }
        # 时间只是展示信息：'?' / 空 / 越界都会显示「—」；但夹了 Tab 或控制字符说明这行被污染。
        $ts = if ($parts.Count -ge 4) { [string]$parts[3] } else { '' }
        if ($ts -match '[\x00-\x1F\x7F]') { $hidden++; continue }
        $idx = $items.Add(@{
            Name = $nm; IsDir = ($parts[0] -eq 'D'); IsLink = ($parts[0] -eq 'L')
            Size = $sz; Time = $ts; Path = (Fm-ChildPath $path $nm)
        })
        $slots[$slots.Count - 1] = $idx
    }
    # 空输出、adb 启动失败、设备掉线、命令被掐断，都会缺 FM_DONE。这些情况下「目录里没东西」
    # 是最危险的假结论（用户可能据此以为文件没了），一律判失败，也不再走兼容回退。
    if (-not $done) {
        return @{ Ok = $false; Items = @(); Hidden = 0; NeedLegacy = $false }
    }
    # toybox stat 遇到某个文件失败会直接跳过、少输出一行，或老 ROM 根本不支持多参数。
    # 数量对不上时绝不按顺序硬配对（会把 A 的大小安到 B 上），交回逐文件模板重读一次。
    if ($isV2 -and $slots.Count -gt 0 -and $attrs.Count -ne $slots.Count) {
        return @{ Ok = $true; Items = @(); Hidden = 0; NeedLegacy = $true }
    }
    if ($isV2 -and $slots.Count -gt 0) {
        for ($i = 0; $i -lt $slots.Count; $i++) {
            if ($slots[$i] -lt 0) { continue }   # 这一格的条目已因协议污染被隐藏
            $e = $items[$slots[$i]]
            $e.Time = $attrs[$i].Time
            # 目录 / 链接的大小列本来就显示「—」，不回填，免得影响下载进度的判断。
            if (-not $e.IsDir -and -not $e.IsLink) { $e.Size = $attrs[$i].Size }
        }
    }
    return @{ Ok = $true; Items = $items.ToArray(); Hidden = $hidden; NeedLegacy = $false }
}

function Fm-ListDir {
    param($Owner, $serial, [string]$path)
    $q = Fm-ShQuote $path
    $lines = @(Fm-Shell $serial ($fmListTemplate.Replace('__PATH__', $q)) $Owner)
    $r = Fm-ParseListLines $lines $path
    if ($r.NeedLegacy) {
        $lines = @(Fm-Shell $serial ($fmListTemplateLegacy.Replace('__PATH__', $q)) $Owner)
        $r = Fm-ParseListLines $lines $path
    }
    return $r
}

# 批量查「当前目录下哪些名字已存在」：只回传序号，不回传文件名。
# 用序号而不是名字，是因为文件名里可能有 Tab/换行，回传名字又会把协议撕开一次。
$fmExistsTemplate = @'
i=0; for n in __NAMES__; do i=$((i+1)); if [ -e "./$n" ] || [ -L "./$n" ]; then printf 'EXISTS\t%s\n' "$i"; fi; done; printf 'FM_DONE\n'
'@
function Fm-ExistingIndexes {
    param($Owner, $serial, [string]$path, [string[]]$names)
    if ($names.Count -eq 0) { return @{ Ok = $true; Indexes = @() } }
    $qNames = (@($names | ForEach-Object { Fm-ShQuote $_ })) -join ' '
    # 只替换模板里那一个占位符，路径用拼接塞进去：若路径或文件名里恰好含有占位符字样，
    # 两次 Replace 会把已经填好的那段再改一次，命令当场变形。
    $cmd = 'cd ' + (Fm-ShQuote $path) + ' 2>/dev/null || exit 1; ' + $fmExistsTemplate.Replace('__NAMES__', $qNames)
    $hit = New-Object System.Collections.ArrayList
    $done = $false
    foreach ($ln in @(Fm-Shell $serial $cmd $Owner)) {
        if (([string]$ln).Trim() -eq 'FM_DONE') { $done = $true; continue }
        $p = ([string]$ln) -split "`t", 2
        if ($p.Count -eq 2 -and $p[0] -eq 'EXISTS') {
            $k = 0
            if ([int]::TryParse($p[1], [ref]$k) -and $k -ge 1 -and $k -le $names.Count) { [void]$hit.Add($k - 1) }
        }
    }
    # 没有 FM_DONE 就说明检查根本没跑完（设备掉线 / cd 失败 / 输出被截断）。
    # 这时「没有同名项」是不可信的结论，必须让调用方取消操作，而不是照常 push 把原件覆盖掉。
    return @{ Ok = $done; Indexes = $(if ($done) { $hit.ToArray() } else { @() }) }
}

# 同名冲突确认：默认落在「取消」上（Button3）。是=覆盖继续，否=跳过同名只处理其余，取消=什么都不做。
function Fm-ConfirmOverwrite {
    param($owner, [string]$action, [string[]]$names, [string]$where)
    $show = @($names | Select-Object -First 12)
    $list = (@($show | ForEach-Object { '· ' + $_ }) -join "`n")
    if ($names.Count -gt $show.Count) { $list += "`n· …以及另外 $($names.Count - $show.Count) 项" }
    $msg = "$where 已经有 $($names.Count) 个同名项，${action}会覆盖它们，覆盖后无法恢复：`n`n$list`n`n「是」= 覆盖并继续（其余项照常处理）`n「否」= 跳过这些同名项，只处理其余的`n「取消」= 什么都不做"
    # 显式转成 IWin32Window + 强类型枚举：6 个参数的 Show 有两个重载，只靠字符串让 PowerShell
    # 自己挑，有可能误落到 (String, ..., MessageBoxOptions) 那个上，把窗体当字符串塞进去。
    $r = [System.Windows.Forms.MessageBox]::Show(
        [System.Windows.Forms.IWin32Window]$owner, [string]$msg, '发现同名文件',
        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button3)
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { return 'overwrite' }
    if ($r -eq [System.Windows.Forms.DialogResult]::No) { return 'skip' }
    return 'cancel'
}

# adb push / pull：不设总超时（大文件可能传几分钟），靠 DoEvents 保持界面可用；
# stdout/stderr 异步读，避免管道被写满导致子进程卡在 write 上、这边卡在 WaitForExit 上互相等死。
# $prog 可选：进度状态 @{ Bar; Pct; Index; Total; WatchPath; TotalBytes }。
# 为什么不解析 adb 自己打印的「[ 45%]」：新版 adb 判断 stdout 不是控制台时（LinePrinter 的
# non-TTY 分支）只把进度行存进 info_line_，等传输结束才吐最后一行，重定向后根本拿不到实时百分比。
# 所以下载改看「本地目标文件长了多少 ÷ 手机上的文件大小」，这是唯一稳的真实进度；上传没有这个信号，
# 就按已完成的项数走步进条，单项时切成跑马灯——界面一直在动，但绝不编一个假的百分比出来。
# 下载先落到独立暂存项，避免失败或取消破坏已有文件；提交时用 Unicode API 精确处理目标名。
# 目标已存在时保持 adb pull 原本的语义：同名文件覆盖，文件夹合并内容、绝不整目录删掉旧文件。
# 写入前检查完整树，避免合并到一半才发现类型冲突或目录联接。
# 保存根目录由用户明确选择，先通过句柄解析实际位置；其下的子路径仍逐级拒绝链接。
function Get-FmSaveRoot {
    param([string]$Path)
    if (-not ('Native.FmPath' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace Native {
    public static class FmPath {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder name, uint size, uint flags);
        public static string Resolve(string path) {
            using (SafeFileHandle handle = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
                if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                StringBuilder name = new StringBuilder(32768);
                uint size = GetFinalPathNameByHandle(handle, name, (uint)name.Capacity, 0);
                if (size == 0 || size >= name.Capacity) throw new Win32Exception(Marshal.GetLastWin32Error());
                string result = name.ToString();
                if (result.StartsWith(@"\\?\UNC\")) return @"\\" + result.Substring(8);
                if (result.StartsWith(@"\\?\")) return result.Substring(4);
                return result;
            }
        }
    }
}
'@
    }
    $root = [Native.FmPath]::Resolve([IO.Path]::GetFullPath($Path))
    Assert-FmLocalPath $root
    return $root
}
function Test-FmOverwrite {
    param($Approved, [string]$Path)
    if ($Approved -is [bool]) { return $Approved }
    return ($null -ne $Approved -and $Approved.ContainsKey([IO.Path]::GetFullPath($Path)))
}
# 授权只记录确认框出现之前实际存在的路径，避免给整批中新出现的目标顺带授权。
function Get-FmExistingTargets {
    param([string]$Path, $Control)
    if ($Control -and $Control.Cancelled) { throw '操作已取消' }
    Assert-FmLocalPath $Path
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @((Get-Item -LiteralPath $Path -Force -ErrorAction Stop).FullName)
}
function Get-FmUnapprovedTargets {
    param([string]$From, [string]$To, $Approved, $Control)
    if ($Control -and $Control.Cancelled) { throw '操作已取消' }
    Assert-FmLocalPath $From
    Assert-FmLocalPath $To
    $paths = @()
    if ((Test-Path -LiteralPath $To) -and -not (Test-FmOverwrite $Approved $To)) { $paths += [IO.Path]::GetFullPath($To) }
    if ((Get-Item -LiteralPath $From -Force -ErrorAction Stop).PSIsContainer) {
        foreach ($child in @(Get-ChildItem -LiteralPath $From -Force -ErrorAction Stop)) {
            $paths += @(Get-FmUnapprovedTargets $child.FullName (Join-Path $To $child.Name) $Approved $Control)
        }
    }
    return @($paths)
}
function Get-FmTargetPaths {
    param($Owner, [string]$Path, [string]$From = '', $Approved = @{}, [string[]]$Paths = @())
    return (Invoke-FmTask $Owner -Functions @('Get-FmExistingTargets','Get-FmUnapprovedTargets','Test-FmOverwrite','Assert-FmLocalPath') -Inputs @{ Path=$Path; From=$From; Approved=$Approved; Paths=$Paths } -Work {
        try {
            $paths = if ($Inputs.From) { @(Get-FmUnapprovedTargets $Inputs.From $Inputs.Path $Inputs.Approved $Control) }
                     else {
                         # 只扫描远端清单对应的目标，已有目录中的无关内容不会被访问。
                         $targets = if ($Inputs.Paths.Count) { @($Inputs.Paths) } else { @($Inputs.Path) }
                         foreach ($target in $targets) { Get-FmExistingTargets $target $Control }
                     }
            [pscustomobject]@{ Info=@{}; Connected=@(); Ok=$true; Paths=@($paths) }
        } catch {
            [pscustomobject]@{ Info=@{}; Connected=@(); Ok=$false; Cancelled=[bool]$Control.Cancelled; Error=$_.Exception.Message }
        }
    })
}
function Assert-FmUploadTarget {
    param($Owner, $Serial, [string]$Local, [string]$Remote)
    $q = Fm-ShQuote $Remote
    $type = @(Fm-Shell $Serial "if [ -L $q ]; then echo FM_LINK; elif [ -d $q ]; then echo FM_DIR; elif [ -e $q ]; then echo FM_FILE; else echo FM_NEW; fi" $Owner | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($Owner.IsDisposed -or -not $Owner.Visible) { throw '操作已取消' }
    if ($type -contains 'FM_LINK') { throw "上传目标是链接：$Remote" }
    $isDirectory = (Get-Item -LiteralPath $Local -Force -ErrorAction Stop).PSIsContainer
    if ($type.Count -ne 1 -or $type[0] -notin @('FM_DIR','FM_FILE','FM_NEW')) { throw "无法确认目标类型：$Remote" }
    if ($type[0] -eq 'FM_NEW') { return }
    if (($type[0] -eq 'FM_DIR') -ne $isDirectory) { throw "目标类型不符：$Remote" }
    if ($isDirectory) {
        foreach ($child in @(Get-ChildItem -LiteralPath $Local -Force -ErrorAction Stop)) {
            Assert-FmUploadTarget $Owner $Serial $child.FullName (Fm-ChildPath $Remote $child.Name)
        }
    }
}
function Assert-FmLocalPath {
    param([string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "路径包含链接：$current" }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}
function Assert-FmNames {
    param([string[]]$Names)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $Names) {
        if (-not (Fm-ValidName $name) -or $name -match '[:*?"<>|]|[. ]$|^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            throw "无法保存这个名称：$name"
        }
        if (-not $seen.Add($name)) { throw "同一批文件存在重名（含大小写冲突）：$name" }
    }
}
function Assert-FmTree {
    param([string]$From, [string]$To, $Overwrite, $Control, $Skipped = @{})
    if ($Skipped.ContainsKey([IO.Path]::GetFullPath($To))) { return }
    if ($Control -and $Control.Cancelled) { throw '操作已取消' }
    Assert-FmLocalPath $From
    Assert-FmLocalPath $To
    $a = Get-Item -LiteralPath $From -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $To) {
        $b = Get-Item -LiteralPath $To -Force -ErrorAction Stop
        if ($a.PSIsContainer -ne $b.PSIsContainer) { throw "文件与文件夹同名：$To" }
        if (-not (Test-FmOverwrite $Overwrite $To)) { throw "目标已存在：$To" }
    }
    if ($a.PSIsContainer) {
        $children = @(Get-ChildItem -LiteralPath $From -Force -ErrorAction Stop)
        Assert-FmNames @($children | ForEach-Object { $_.Name })
        foreach ($child in $children) { Assert-FmTree $child.FullName (Join-Path $To $child.Name) $Overwrite $Control $Skipped }
    }
}
function Copy-FmFile {
    param([string]$From, [string]$To, $Overwrite, $Control, $Skipped = @{})
    if ($Skipped.ContainsKey([IO.Path]::GetFullPath($To))) { return }
    Assert-FmLocalPath $To
    $temp = Join-Path ([IO.Path]::GetDirectoryName($To)) ('.scrcpy-' + [guid]::NewGuid().ToString('N'))
    $inputStream=$null; $outputStream=$null
    try {
        $inputStream=[IO.File]::OpenRead($From)
        $outputStream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $buffer=New-Object byte[] 1048576
        while (($read=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
            if ($Control -and $Control.Cancelled) { throw '操作已取消' }
            $outputStream.Write($buffer,0,$read)
        }
        $outputStream.Dispose(); $outputStream=$null
        if ($Control -and $Control.Cancelled) { throw '操作已取消' }
        Assert-FmLocalPath $To
        if ([IO.File]::Exists($To) -and (Test-FmOverwrite $Overwrite $To)) { [IO.File]::Replace($temp,$To,[System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temp,$To) }
    } finally {
        if ($inputStream) { $inputStream.Dispose() }
        if ($outputStream) { $outputStream.Dispose() }
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}
function Merge-FmDirectory {
    param([string]$From, [string]$To, $Overwrite = $false, $Control, $Skipped = @{})
    if ($Skipped.ContainsKey([IO.Path]::GetFullPath($To))) { return }
    Assert-FmTree $From $To $Overwrite $Control $Skipped
    if (-not (Test-Path -LiteralPath $To)) { [void][IO.Directory]::CreateDirectory($To) }
    foreach ($child in @(Get-ChildItem -LiteralPath $From -Force -ErrorAction Stop)) {
        $target = Join-Path $To $child.Name
        if ($child.PSIsContainer) { Merge-FmDirectory $child.FullName $target $Overwrite $Control $Skipped }
        else {
            Copy-FmFile $child.FullName $target $Overwrite $Control $Skipped
        }
    }
}
function Move-FmPulledItem {
    param([string]$From, [string]$To, $Overwrite = $false, $Control, $Skipped = @{})
    if ($Skipped.ContainsKey([IO.Path]::GetFullPath($To))) { return }
    try {
        Assert-FmTree $From $To $Overwrite $Control $Skipped
        $a = Get-Item -LiteralPath $From -Force -ErrorAction Stop
        if ($a.PSIsContainer) { Merge-FmDirectory $From $To $Overwrite $Control $Skipped }
        else { Copy-FmFile $From $To $Overwrite $Control $Skipped }
        return $true
    } catch { return $false }
}
function Assert-FmRemoteTree {
    param($Owner, $Serial, [string]$Path)
    $listing = Fm-ListDir $Owner $Serial $Path
    if (-not $listing.Ok -or $listing.Hidden -gt 0) { throw "目录未能完整检查：$Path" }
    Assert-FmNames @($listing.Items | ForEach-Object { $_.Name })
    $paths = @()
    foreach ($entry in $listing.Items) {
        if ($entry.IsLink) { throw "下载目录含链接：$($entry.Path)" }
        $paths += $entry.Name
        if ($entry.IsDir) {
            foreach ($relative in @(Assert-FmRemoteTree $Owner $Serial $entry.Path)) {
                $paths += $entry.Name + '/' + $relative
            }
        }
    }
    return @($paths)
}

function Fm-Transfer {
    param([string[]]$Argv, $dlg, $status, [string]$tip, $prog, [string]$WorkingDirectory)
    # 先挡一道：窗口关了就别再起 adb。传输本身可能 120ms 内就结束、一次都不进下面的等待循环，
    # 只靠循环里的关窗判断会漏掉，外层批量循环就接着发下一项了。
    if ($dlg -and ($dlg.IsDisposed -or -not $dlg.Visible)) {
        return @{ Ok = $false; Code = -1; Aborted = $true; Detail = '窗口已关闭' }
    }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $adb
    $psi.Arguments = (@($Argv | ForEach-Object { Fm-WinArg $_ }) -join ' ')
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try { $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8 } catch {}
    try { $p = [System.Diagnostics.Process]::Start($psi) } catch { return @{ Ok = $false; Code = -1; Aborted = $false; Detail = $_.Exception.Message } }
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    try { $status.Text = $tip; $status.Refresh() } catch {}
    $aborted = $false
    while (-not $p.WaitForExit(120)) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($dlg -and ($dlg.IsDisposed -or -not $dlg.Visible)) { try { $p.Kill() } catch {}; $aborted = $true; break }
        if ($prog) {
            # 每 120ms 一跳：读一次本地文件大小即可，不额外起 adb 进程、不干扰正在进行的传输。
            $frac = 0.0
            if ($prog.WatchPath -and $prog.TotalBytes -gt 0) {
                try {
                    $fi = New-Object System.IO.FileInfo([string]$prog.WatchPath)
                    if ($fi.Exists) { $frac = [Math]::Min(0.99, [double]$fi.Length / [double]$prog.TotalBytes) }
                } catch {}
            }
            $doneItems = [Math]::Max(0, [int]$prog.Index - 1)
            $totalItems = [Math]::Max(1, [int]$prog.Total)
            $overall = [int][Math]::Floor((($doneItems + $frac) / $totalItems) * 100)
            if ($overall -lt 0) { $overall = 0 }; if ($overall -gt 100) { $overall = 100 }
            try {
                $bar = $prog.Bar
                # 只有「单项、且压根没有可观测的字节信号」才用跑马灯；下载虽暂时还没读到文件，
                # 也留在连续条上等它出现，免得样式来回跳。多项时步进条本身就能反映真实进度。
                if ($frac -le 0 -and $totalItems -eq 1 -and -not $prog.WatchPath) {
                    if ($bar.Style -ne [System.Windows.Forms.ProgressBarStyle]::Marquee) { $bar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee }
                    $prog.Pct.Text = '传输中…'
                } else {
                    if ($bar.Style -ne [System.Windows.Forms.ProgressBarStyle]::Continuous) { $bar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous }
                    $bar.Value = $overall
                    $prog.Pct.Text = "$overall%"
                }
                $txt = if ($frac -gt 0) { "$tip  ·  $overall%" } else { $tip }
                if ($status.Text -ne $txt) { $status.Text = $txt }
            } catch {}
        }
    }
    try { [void][System.Threading.Tasks.Task]::WaitAll(@($outTask, $errTask), 3000) } catch {}
    $out = if ($outTask.IsCompleted -and -not $outTask.IsFaulted) { $outTask.Result } else { '' }
    $err = if ($errTask.IsCompleted -and -not $errTask.IsFaulted) { $errTask.Result } else { '' }
    $code = try { $p.ExitCode } catch { -1 }
    try { $p.Dispose() } catch {}
    # 进程很快就退出的那一项也要带上关窗结论：调用方靠 Aborted 决定是否停止整批。
    if (-not $aborted -and $dlg -and ($dlg.IsDisposed -or -not $dlg.Visible)) { $aborted = $true }
    return @{ Ok = ($code -eq 0 -and -not $aborted); Code = $code; Aborted = $aborted; Detail = (($out + "`n" + $err).Trim()) }
}

function Show-FileManager {
    param($owner, [string[]]$devices)
    # 新版 main 的 Ensure-Devices 只启动后台扫描、靠 OnDone / OnFinally 交付结果，不再同步返回数组。
    # 入口用 Invoke-MainFlow -WithDevices 接好：查询失败由它提示「查询设备失败，请稍后重试」，
    # 取消时根本不会进本函数、由 OnFinally 里的 Complete-MainFlow 复位忙态和光标。
    # 所以能走到这里、且 $devs 为空，含义是「扫描成功但确实没连手机」，不是「没查到设备」。
    $devs = @($devices | Where-Object { $_ })
    if ($devs.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("没检测到手机，请先连接手机再打开「文件管理」。`n`n用数据线连接并点「允许 USB 调试」，或点主界面右上角的连接状态走无线连接。", '文件管理') | Out-Null
        return
    }
    # 每次打开重新探一次：设置里可能换过 adb 路径，或上次探测时设备刚好在重连。
    $script:fmShellMode = $null

    $dlg = New-Dialog '文件管理 · 手机文件' 680 424 $owner
    # Set-DpiScale 在 Load 时按真实 DPI 整体 Scale 窗体和控件；本处理器后注册，排在它之后，
    # 拿到的是缩放后的真实像素。列表原本只有 206px（约 10 行），一次看到的文件太少，
    # 所以把屏幕工作区剩余的垂直空间匀给它：窗口跟着变高、下面一整行控件下移。
    # 关键是别把老坑踩回去：150% 缩放的笔记本放不下时增长量自动归 0，完全退回 680x424，
    # 底部那排按钮不会被挤出屏幕。设计基准高度保持 424 不变，只做「有余量才长高」的正向增长。
    $dlg.Add_Load({
        try {
            $wa = [System.Windows.Forms.Screen]::FromControl($dlg).WorkingArea
            $grow = [Math]::Min(240, ($wa.Height - 24 - $dlg.Height))
            if ($grow -lt 0) { $grow = 0 }
            if ($grow -gt 0) {
                # 先撑高窗体：万一后面某步异常，最坏只是底部多一段空白，按钮不会被裁掉。
                $dlg.ClientSize = New-Object System.Drawing.Size($dlg.ClientSize.Width, ($dlg.ClientSize.Height + $grow))
                $lv.Height += $grow
                foreach ($c in @($lblInfo, $barFm, $lblPct, $lineFm,
                                $btnUpload, $btnDownload, $btnRename, $btnRefresh, $btnNew, $btnDel, $btnClose)) {
                    if ($null -ne $c) { $c.Top += $grow }
                }
            }
            if ($dlg.Bottom -gt $wa.Bottom) { $dlg.Top = [Math]::Max($wa.Top, ($wa.Bottom - $dlg.Height)) }
            if ($dlg.Right -gt $wa.Right) { $dlg.Left = [Math]::Max($wa.Left, ($wa.Right - $dlg.Width)) }
            # 打开就把键盘焦点交给文件列表：不用先点一下列表，↑↓ 选、← / → / Enter 导航就能直接用。
            # 用 ActiveControl 而不是 Focus()，此时窗体刚进入 Load，后者不一定已经能接受焦点。
            try { $dlg.ActiveControl = $lv } catch {}
        } catch {}
    })
    $fmtip = New-Object System.Windows.Forms.ToolTip
    $fmtip.AutoPopDelay = 12000
    $startSerial = if ($settings.defaultDevice -and ($devs -contains $settings.defaultDevice)) { $settings.defaultDevice } else { $devs[0] }
    $state = @{ Path = '/sdcard'; Serial = $startSerial; Serials = @($devs); Rebuilding = $false; DropPaths = @() }

    # —— 第一行：设备（多设备时直接在这里切，不用退回主界面）——
    $lblDev = New-Lbl '设备' 16 14
    $cmbDev = New-Object System.Windows.Forms.ComboBox
    $cmbDev.DropDownStyle = 'DropDownList'
    $cmbDev.Location = New-Object System.Drawing.Point(52, 10)
    $cmbDev.Size = New-Object System.Drawing.Size(420, 26)
    $cmbDev.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    foreach ($s in $devs) { [void]$cmbDev.Items.Add("$(Get-FriendlyName $s)   ·   $s") }
    $idx = [array]::IndexOf($state.Serials, $state.Serial); if ($idx -lt 0) { $idx = 0 }
    $cmbDev.SelectedIndex = $idx
    $lblDevInfo = New-Caption '通过 ADB 直接读写手机文件' 490 14
    $lblDevInfo.AutoSize = $false; $lblDevInfo.Size = New-Object System.Drawing.Size(174, 20)
    $lblDevInfo.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight

    # —— 第二行：常用位置 ——
    # 按钮是定宽居中文字：「下载」比原来的 Download 短，这一格收窄 30px，后面三个跟着左移，间距才齐。
    $lnkHome = New-LinkBtn '内部存储' 16 40 76
    $lnkDl   = New-LinkBtn '下载'     100 40 52
    $lnkDcim = New-LinkBtn '相册 DCIM' 160 40 90
    $lnkPic  = New-LinkBtn '图片'      258 40 52
    $lnkRoot = New-LinkBtn '根目录 /'  318 40 82

    # —— 第三行：路径 + 上一级 / 转到 ——
    $btnUp = New-SecondaryBtn '↑ 上一级' 16 72 88 30
    $txtPath = New-Txt 112 74 468 26
    $txtPath.Text = $state.Path
    $txtPath.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $btnGo = New-SecondaryBtn '转到' 588 72 76 30

    # —— 列表 ——
    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location = New-Object System.Drawing.Point(16, 108)
    $lv.Size = New-Object System.Drawing.Size(648, 206)
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $true
    $lv.HideSelection = $false; $lv.HeaderStyle = 'Nonclickable'
    $lv.BackColor = $cWhite; $lv.AllowDrop = $true
    $lv.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    # 四列合计 614px，列表客户区约 644px，扣掉可能的垂直滚动条仍不触发水平滚动条。
    [void]$lv.Columns.Add('名称', 318)
    [void]$lv.Columns.Add('类型', 72)
    [void]$lv.Columns.Add('大小', 88)
    [void]$lv.Columns.Add('修改时间', 136)
    $boldFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5, [System.Drawing.FontStyle]::Bold)

    # 列表让出 22px 给下面这一行进度条：整个弹窗高度不变，150% DPI 下也不会把底部按钮顶出屏幕。
    $lblInfo = New-Caption '正在读取…' 16 320
    $lblInfo.AutoSize = $false
    $lblInfo.Size = New-Object System.Drawing.Size(648, 20)
    $barFm = New-Object System.Windows.Forms.ProgressBar
    $barFm.Location = New-Object System.Drawing.Point(16, 344)
    $barFm.Size = New-Object System.Drawing.Size(556, 14)
    $barFm.Minimum = 0; $barFm.Maximum = 100; $barFm.Value = 0
    $barFm.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $barFm.MarqueeAnimationSpeed = 40
    $barFm.Visible = $false
    $lblPct = New-Caption '' 580 342
    $lblPct.AutoSize = $false
    $lblPct.Size = New-Object System.Drawing.Size(84, 20)
    $lblPct.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $lblPct.Visible = $false
    $lineFm = New-Object System.Windows.Forms.Panel
    $lineFm.Size = New-Object System.Drawing.Size(648, 1)
    $lineFm.Location = New-Object System.Drawing.Point(16, 366)
    $lineFm.BackColor = $cLine

    # —— 操作行：7 个按钮按 8px 间隔铺满 16..664，加了「重命名」也不挤出去 ——
    $btnUpload   = New-SecondaryBtn '上传…'      16  376 88  34
    $btnDownload = New-SecondaryBtn '下载…'      112 376 88  34
    $btnRename   = New-SecondaryBtn '重命名'      208 376 88  34
    $btnRefresh  = New-SecondaryBtn '刷新'        304 376 72  34
    $btnNew      = New-SecondaryBtn '新建文件夹'   384 376 104 34
    $btnDel      = New-SecondaryBtn '删除'        496 376 72  34
    $btnDel.ForeColor = $cRed
    $btnClose    = New-PrimaryBtn   '关闭'        576 376 88  34 10
    $fmtip.SetToolTip($btnUpload, '选电脑上的文件传到手机当前目录（可多选），也可以直接把文件拖进列表。')
    $fmtip.SetToolTip($btnDownload, '把选中的文件 / 文件夹下载到电脑（可多选，会让你挑保存位置）。合并文件夹时，仅跳过确认框列出的冲突子项，其余文件继续保存；链接检查仅覆盖本次实际写入的路径。')
    $fmtip.SetToolTip($btnRename, '给选中的一个文件 / 文件夹改名（F2）。只在当前目录里改名字，遇到同名会提示换名，不会覆盖。')
    $fmtip.SetToolTip($btnRefresh, '重新读取当前目录，并刷新设备列表。')
    $fmtip.SetToolTip($btnNew, '在手机当前目录里新建一个文件夹。')
    $fmtip.SetToolTip($btnDel, '删除选中的项。先列出全部待删项再确认，只作用于当前目录里的这些名字；手机上的删除不进回收站，无法恢复。')
    $fmtip.SetToolTip($txtPath, '可直接填手机上的绝对路径，回车或点「转到」跳转。')
    $fmtip.SetToolTip($barFm, '下载单个文件时按已收到的字节显示真实百分比；上传或整个文件夹时按已完成的项数步进。')
    # 列表本身不挂 Tooltip：鼠标在文件上划过就弹一条长说明很打扰。时间列的含义写在「使用说明.txt」里。

    $dlg.Controls.AddRange(@($lblDev, $cmbDev, $lblDevInfo,
        $lnkHome, $lnkDl, $lnkDcim, $lnkPic, $lnkRoot,
        $btnUp, $txtPath, $btnGo, $lv, $lblInfo, $barFm, $lblPct, $lineFm,
        $btnUpload, $btnDownload, $btnRename, $btnRefresh, $btnNew, $btnDel, $btnClose))

    # —— 传输进度：一个对象在整批上传/下载里复用，逐项改 Index / WatchPath / TotalBytes ——
    $progState = @{ Bar = $barFm; Pct = $lblPct; Index = 0; Total = 1; WatchPath = ''; TotalBytes = 0L }
    $beginProgress = {
        param($n)
        $progState.Total = [Math]::Max(1, [int]$n)
        $progState.Index = 0
        $barFm.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
        $barFm.Value = 0
        $lblPct.Text = '0%'
        $barFm.Visible = $true; $lblPct.Visible = $true
        $barFm.Refresh(); $lblPct.Refresh()
    }
    $endProgress = {
        param([bool]$allOk = $true)
        # 成功才归到满格再隐藏：单项传输可能 120ms 内就结束、一次 tick 都没赶上，也别留下半截的条；
        # 有失败项时不冒充 100%，直接收起，错误详情由下面的结果弹窗负责。
        try {
            if ($allOk -and $barFm.Visible) {
                $barFm.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
                $barFm.Value = 100; $lblPct.Text = '100%'
                $barFm.Refresh(); $lblPct.Refresh()
            }
        } catch {}
        try { $barFm.Visible = $false; $lblPct.Visible = $false; $lblPct.Text = '' } catch {}
    }

    # 批量操作期间锁死设备下拉框：Fm-Transfer / Fm-ShellLong 等待时靠 DoEvents 泵消息，
    # 那段时间窗口仍「活着」，用户能切设备。锁控件 + 事件守卫 + 快照三道一起做，
    # 才不会把同一批文件分头发到两台手机上。
    $setDeviceLock = {
        param([bool]$on)
        try {
            if ($dlg.IsDisposed) { return }
            $cmbDev.Enabled = (-not $on)
        } catch {}
    }

    # —— 状态 / 按钮可用性 ——
    $updateButtons = {
        # 框选松手时会批量改 Selected，会逐项触发 SelectedIndexChanged；那期间跳过重算，结束后手动调一次。
        if ($state.RubberBusy) { return }
        $sel = @($lv.SelectedItems | Where-Object { $_.Tag })
        $btnDownload.Enabled = ($sel.Count -gt 0)
        $btnDel.Enabled = ($sel.Count -gt 0)
        # 重命名只认恰好一项：多选时没有一个明确的「旧名字」，按钮和 F2 一起禁用。
        $btnRename.Enabled = ($sel.Count -eq 1)
        $btnUp.Enabled = ($state.Path -ne '/')
    }

    # —— 读目录 ——
    $refresh = {
        # 长传输中点「关闭」会先杀掉 adb，回到这里时窗体可能已 Dispose；别再碰控件。
        if ($dlg.IsDisposed) { return }
        # 读一次就固定住：整次读取（包括失败重试）都用同一台设备、同一个目录。
        $snapSerial = [string]$state.Serial
        $snapPath = [string]$state.Path
        # 列目录要起 adb、设备端还要遍历文件；先把状态行刷出来，别让窗口看着像卡死。
        $lblInfo.ForeColor = $cMuted
        $lblInfo.Text = '正在读取…'
        try { $lblInfo.Refresh() } catch {}
        $lv.BeginUpdate()
        try {
            $lv.Items.Clear()
            $r = Fm-ListDir $dlg $snapSerial $snapPath
            # 后台读取期间会泵消息；关窗取消后控件可能已释放，不能再填列表或更新状态。
            if ($dlg.IsDisposed -or -not $dlg.Visible) { return }
            # 逐项 Items.Add 在几百上千项时也是一笔开销；攒成数组一次 AddRange。
            $newItems = New-Object System.Collections.ArrayList
            if (-not $r.Ok) {
                $it = New-Object System.Windows.Forms.ListViewItem('（打不开这个目录）')
                $it.ForeColor = $cRed; [void]$newItems.Add($it)
                $lblInfo.ForeColor = $cRed
                $lblInfo.Text = '读不到这个目录：手机可能已掉线、目录已不存在，或当前系统不允许 ADB 访问。请确认连接后点「刷新」，或点「上一级」返回。'
            } else {
                $dirs  = @($r.Items | Where-Object { $_.IsDir } | Sort-Object { $_.Name })
                $files = @($r.Items | Where-Object { -not $_.IsDir } | Sort-Object { $_.Name })
                foreach ($e in (@($dirs) + @($files))) {
                    $prefix = if ($e.IsDir) { '▸  ' } elseif ($e.IsLink) { '↪  ' } else { '    ' }
                    $it = New-Object System.Windows.Forms.ListViewItem(($prefix + $e.Name))
                    $kind = if ($e.IsDir) { '文件夹' } elseif ($e.IsLink) { '链接' } else { '文件' }
                    [void]$it.SubItems.Add($kind)
                    [void]$it.SubItems.Add($(if ($e.IsDir -or $e.IsLink) { '—' } else { Fm-SizeText $e.Size }))
                    [void]$it.SubItems.Add((Fm-TimeText $e.Time))
                    if ($e.IsDir) { $it.Font = $boldFont }
                    $it.Tag = $e
                    [void]$newItems.Add($it)
                }
                if ($newItems.Count -eq 0) {
                    $it = New-Object System.Windows.Forms.ListViewItem('（这个文件夹是空的）')
                    $it.ForeColor = $cMuted; [void]$newItems.Add($it)
                }
                $lblInfo.ForeColor = $cMuted
                $infoTip = "共 $($r.Items.Count) 项（$($dirs.Count) 个文件夹） · 双击进入 · 可多选下载 / 删除 · 可拖文件进来上传"
                # 名称含控制字符的条目会被安全隐藏，不做成可点击项；这里让用户知道「少了东西」，
                # 免得以为目录里真的没有。
                if ($r.Hidden -gt 0) { $infoTip = "有 $($r.Hidden) 项名称含特殊字符，已隐藏（不可操作） · $infoTip" }
                $lblInfo.Text = $infoTip
            }
            if ($newItems.Count -gt 0) {
                [void]$lv.Items.AddRange($newItems.ToArray([System.Windows.Forms.ListViewItem]))
            }
        } finally { if (-not $lv.IsDisposed) { $lv.EndUpdate() } }
        $txtPath.Text = $snapPath
        & $updateButtons
    }

    $enter = {
        param($p)
        $state.Path = Fm-NormPath $p
        & $refresh
    }

    # —— 导航动作：按钮、双击、方向键共用同一份判断，免得两处逻辑走偏 ——
    $goUp = {
        if ($state.Path -ne '/') { & $enter (Fm-ParentPath $state.Path) }
    }
    $selectedFolder = {
        # 跟原来的双击保持一致：只有「恰好选中一项，且是文件夹 / 链接」才算有目标。
        # 多选、选中的是文件、空目录占位行都返回 $null —— 不猜意图，也就不会误进别的目录。
        if ($lv.SelectedItems.Count -ne 1) { return $null }
        $t = $lv.SelectedItems[0].Tag
        if ($t -and ($t.IsDir -or $t.IsLink)) { return $t.Path }
        return $null
    }
    $openSelected = {
        $p = & $selectedFolder
        if ($p) { & $enter $p }
    }

    # —— 上传：按钮选文件，或直接把文件拖进列表 ——
    $doUpload = {
        param($paths)
        # 整批从这一刻起就钉死目标：同名检查、确认框、每一项 push 都用这两个快照值，
        # 不重新读 $state。等待期间 DoEvents 会让设备下拉框事件插进来，重读就会换手机 / 换目录。
        $batchSerial = [string]$state.Serial
        $batchPath = [string]$state.Path
        # 去掉结尾的 \ / 再取名字：盘符根 C:\ 的 GetFileName 是空串，直接 push 会把整个盘推上去。
        $list = @($paths | Where-Object { $_ } | ForEach-Object {
            $t = ([string]$_).TrimEnd([char[]]@([char]92, [char]47))
            if ($t -and (Test-Path -LiteralPath $t) -and [System.IO.Path]::GetFileName($t)) { $t }
        })
        if ($list.Count -eq 0) { return }
        # 同名检查要把所有名字拼进一条 adb 命令；超过上限宁可让用户分批，也不能漏检后闷头覆盖。
        if ($list.Count -gt 200) {
            [void](Show-ResultDialog $dlg '上传' '一次最多处理 200 项' '同名检查需要把所有文件名放进一条设备端命令里。为避免命令过长导致漏检、进而覆盖手机上的原文件，请分几次上传。' '' @('ok'))
            return
        }
        # adb push 会把手机上的同名文件直接覆盖掉，且不问一声。先在设备端批量查一次同名项，
        # 让用户选「覆盖 / 跳过 / 取消」；不查就等同于把手机上的原件无声地弄丢。
        $names = @($list | ForEach-Object { [System.IO.Path]::GetFileName($_) })
        try { Assert-FmNames $names } catch {
            [void](Show-ResultDialog $dlg '上传' '请先处理重名或不支持的名称' $_.Exception.Message '' @('ok'))
            return
        }
        $chk = Fm-ExistingIndexes $dlg $batchSerial $batchPath $names
        if ($dlg.IsDisposed -or -not $dlg.Visible) { return }
        if (-not $chk.Ok) {
            [void](Show-ResultDialog $dlg '上传' '没能确认手机上有没有同名文件' '为避免悄悄覆盖已有文件，本次上传已取消。请确认手机仍连着，点「刷新」后再试。' '' @('ok'))
            return
        }
        $existing = @($chk.Indexes)
        $approved = @()
        if ($existing.Count -gt 0) {
            $choice = Fm-ConfirmOverwrite $dlg '上传' @($existing | ForEach-Object { $names[$_] }) "手机上的 $batchPath"
            if ($choice -eq 'cancel') { return }
            if ($choice -eq 'overwrite') { $approved = @($existing | ForEach-Object { $names[$_] }) }
            if ($choice -eq 'skip') {
                $keep = @()
                for ($k = 0; $k -lt $list.Count; $k++) { if ($existing -notcontains $k) { $keep += $list[$k] } }
                $list = @($keep)
                if ($list.Count -eq 0) { $lblInfo.ForeColor = $cMuted; $lblInfo.Text = '同名项都跳过了，没有上传任何文件'; return }
            }
        }
        & $beginProgress $list.Count
        try {
            & $setDeviceLock $true
            $okN = 0; $fail = @(); $i = 0; $aborted = $false
            foreach ($f in $list) {
                # 每项开始前先看窗口：关窗后一项都不再启动，短传输来不及进等待循环也照样拦住。
                if ($dlg.IsDisposed -or -not $dlg.Visible) { $aborted = $true; break }
                $i++
                $name = [System.IO.Path]::GetFileName($f)
                $remote = Fm-ChildPath $batchPath $name
                # 批量确认后目录仍可能变化；未获授权的新同名项必须再次确认。
                $check = Fm-ExistingIndexes $dlg $batchSerial $batchPath @($name)
                if ($dlg.IsDisposed -or -not $dlg.Visible) { $aborted = $true; break }
                if (-not $check.Ok) { $fail += "$name → 无法复查目标，已跳过"; continue }
                if (@($check.Indexes).Count -gt 0 -and $approved -notcontains $name) {
                    $answer = Fm-ConfirmOverwrite $dlg '上传' @($name) "手机上的 $batchPath"
                    if ($answer -eq 'cancel') { $aborted = $true; break }
                    if ($answer -eq 'skip') { continue }
                }
                try { Assert-FmUploadTarget $dlg $batchSerial $f $remote } catch {
                    if ($dlg.IsDisposed -or -not $dlg.Visible) { $aborted = $true; break }
                    $fail += "$name → $($_.Exception.Message)"; continue
                }
                # adb 以父目录为目的地时，目录上传合并到同名目录，避免产生 name/name。
                $remote = $batchPath.TrimEnd('/') + '/'
                # push 的方向是「电脑→手机」，本地文件大小不变，没有可用的字节信号，按项数步进。
                $progState.Index = $i; $progState.WatchPath = ''; $progState.TotalBytes = 0L
                $r = Fm-Transfer (@('-s', $batchSerial, 'push', $f, $remote)) $dlg $lblInfo "正在上传 ($i/$($list.Count))：$name" $progState
                if ($r.Aborted) { $aborted = $true; break }
                if ($r.Ok) { $okN++ } else { $fail += "$name → $($r.Detail)" }
            }
            # 关窗 / 中止后整批到此为止：不刷新、不弹结果框，窗体可能已经没了。
            if ($aborted -or $dlg.IsDisposed -or -not $dlg.Visible) { return }
            & $refresh
            if ($fail.Count -gt 0) {
                [void](Show-ResultDialog $dlg '上传' "有 $($fail.Count) 项没传成功" '可能是手机存储空间不足，或当前目录不允许写入。换到「内部存储 > Download」再试。' ($fail -join "`r`n") @('ok'))
            } else {
                $lblInfo.ForeColor = $cGreen
                $lblInfo.Text = "已上传 $okN 项到 $batchPath"
            }
        } finally {
            & $endProgress (-not $aborted -and $fail.Count -eq 0)
            & $setDeviceLock $false
        }
    }
    $pickAndUpload = {
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Title = '选择要传到手机的文件（可多选）'
        $ofd.Multiselect = $true
        $ofd.Filter = '所有文件 (*.*)|*.*'
        if ($ofd.ShowDialog($dlg) -eq [System.Windows.Forms.DialogResult]::OK) { & $doUpload $ofd.FileNames }
        $ofd.Dispose()
    }

    # —— 下载：多选后挑一个电脑目录，逐项 pull；用「本地是否出现同名项」再验一次，
    #    因为部分老 adb 传输出错时退出码仍是 0。——
    $doDownload = {
        # 整批固定目标设备；每条来源路径取自列表项的 Tag.Path 快照，保存位置取自下面选中的 $dest，
        # 两者都不再读 $state，所以中途切设备 / 跳目录都不会把后续项拉到别的手机上。
        $batchSerial = [string]$state.Serial
        $sel = @($lv.SelectedItems | Where-Object { $_.Tag })
        if ($sel.Count -eq 0) { return }
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = "选择保存到电脑的文件夹（共 $($sel.Count) 项）"
        $fbd.ShowNewFolderButton = $true
        if ($fbd.ShowDialog($dlg) -ne [System.Windows.Forms.DialogResult]::OK) { $fbd.Dispose(); return }
        $dest = $fbd.SelectedPath
        $fbd.Dispose()
        if (-not (Test-Path -LiteralPath $dest)) { return }
        $relativeTargets = @{}
        try {
            $dest = Get-FmSaveRoot $dest
            Assert-FmNames @($sel | ForEach-Object { $_.Tag.Name })
            foreach ($item in $sel) {
                if ($item.Tag.IsLink) { throw '下载暂不支持链接，请选择原文件。' }
                if ($item.Tag.IsDir) { $relativeTargets[$item.Tag.Name] = @(Assert-FmRemoteTree $dlg $batchSerial $item.Tag.Path) }
            }
        } catch {
            if ($dlg.IsDisposed -or -not $dlg.Visible) { return }
            [void](Show-ResultDialog $dlg '下载' '无法安全保存这批文件' $_.Exception.Message '' @('ok'))
            return
        }
        $approvedTargets = @{}
        $existingTargets = @{}
        # adb pull 同样会覆盖电脑上已有的同名文件，且不问一声。纯本地检查，不需要 adb。
        $overlap = @()
        for ($k = 0; $k -lt $sel.Count; $k++) {
            $target = Join-Path $dest ([string]$sel[$k].Tag.Name)
            $targets = @($target)
            foreach ($relative in @($relativeTargets[[string]$sel[$k].Tag.Name])) {
                if ($relative) { $targets += Join-Path $target $relative }
            }
            $check = Get-FmTargetPaths $dlg $target -Paths $targets
            if ($dlg.IsDisposed -or -not $dlg.Visible -or $check.Cancelled) { return }
            if (-not $check.Ok) {
                [void](Show-ResultDialog $dlg '下载' '无法安全保存这批文件' $check.Error '' @('ok'))
                return
            }
            $existingTargets[$k] = @($check.Paths)
            if ($existingTargets[$k].Count -gt 0) { $overlap += $k }
        }
        if ($overlap.Count -gt 0) {
            $choice = Fm-ConfirmOverwrite $dlg '下载' @($overlap | ForEach-Object { [string]$sel[$_].Tag.Name }) "电脑上的 $dest"
            if ($choice -eq 'cancel') { return }
            if ($choice -eq 'overwrite') {
                foreach ($k in $overlap) {
                    foreach ($path in $existingTargets[$k]) { $approvedTargets[$path] = $true }
                }
            }
            if ($choice -eq 'skip') {
                $keep = @()
                for ($k = 0; $k -lt $sel.Count; $k++) { if ($overlap -notcontains $k) { $keep += $sel[$k] } }
                $sel = @($keep)
                if ($sel.Count -eq 0) { $lblInfo.ForeColor = $cMuted; $lblInfo.Text = '同名项都跳过了，没有下载任何文件'; return }
            }
        }
        & $beginProgress $sel.Count
        try {
            & $setDeviceLock $true
            $okN = 0; $fail = @(); $i = 0; $aborted = $false
            foreach ($it in $sel) {
                # 每项开始前先看窗口：关窗后不再启动新的 pull，短传输也不会漏网。
                if ($dlg.IsDisposed -or -not $dlg.Visible) { $aborted = $true; break }
                $i++; $e = $it.Tag
                # 设备端合法、Windows 非法的名字（: * ? " < > |、结尾的点或空格）会让 adb 报
                # 「cannot create ...」这种看不懂的错。提前拦下并说明原因，别把锅甩给存储权限。
                if ($e.Name -match '[:*?"<>|]' -or $e.Name -match '[. ]$') {
                    $fail += "$($e.Name) → 文件名含 Windows 不允许的字符，无法直接保存；请在手机上改名后再下载"
                    continue
                }
                $local = Join-Path $dest $e.Name
                # Unicode 父目录由 Windows 设置，adb 只接收相对临时名，无需写盘符根目录。
                $stageName = '__scrcpy_pull_' + [guid]::NewGuid().ToString('N')
                $stage = Join-Path $dest $stageName
                # 中转文件在电脑上边写边长，用「当前大小 ÷ 手机上列出的大小」得到真实百分比；
                # 文件夹没有单一大小，退回按项数步进。
                $sz = 0L
                if (-not $e.IsDir) { [void][long]::TryParse([string]$e.Size, [ref]$sz) }
                $progState.Index = $i
                $progState.WatchPath = $(if ($sz -gt 0) { $stage } else { '' })
                $progState.TotalBytes = $sz
                $r = $null
                try {
                    # 只把纯 ASCII 路径交给 adb；成功后由 Move-FmPulledItem 改成真正的中文名。
                    $r = Fm-Transfer (@('-s', $batchSerial, 'pull', $e.Path, $stageName)) $dlg $lblInfo "正在下载 ($i/$($sel.Count))：$($e.Name)" $progState $dest
                    if (-not $r.Aborted) {
                        $commit = $null
                        if ($r.Ok) {
                            $skippedTargets = @{}
                            $check = Get-FmTargetPaths $dlg $local $stage $approvedTargets
                            if ($dlg.IsDisposed -or -not $dlg.Visible -or $check.Cancelled) { $aborted=$true; break }
                            if (-not $check.Ok) { $fail += "$($e.Name) → $($check.Error)"; continue }
                            $conflicts = @($check.Paths)
                            if ($conflicts.Count -gt 0) {
                                $answer = Fm-ConfirmOverwrite $dlg '下载' $conflicts "电脑上的 $dest"
                                if ($dlg.IsDisposed -or -not $dlg.Visible -or $answer -eq 'cancel') { $aborted = $true; break }
                                if ($answer -eq 'skip') {
                                    foreach ($path in $conflicts) { $skippedTargets[$path] = $true }
                                    if ($skippedTargets.ContainsKey([IO.Path]::GetFullPath($local))) { continue }
                                } else {
                                    foreach ($path in $conflicts) { $approvedTargets[$path] = $true }
                                }
                            }
                            $commit = Invoke-FmTask $dlg -Functions @('Fm-ValidName','Assert-FmNames','Assert-FmLocalPath','Assert-FmTree','Test-FmOverwrite','Copy-FmFile','Merge-FmDirectory','Move-FmPulledItem') -Inputs @{ From=$stage; To=$local; Overwrite=$approvedTargets; Skipped=$skippedTargets } -Work {
                                $ok=Move-FmPulledItem $Inputs.From $Inputs.To $Inputs.Overwrite $Control $Inputs.Skipped
                                [pscustomobject]@{ Info=@{}; Connected=@(); Ok=$ok; Cancelled=[bool]$Control.Cancelled }
                            }
                        }
                        if ($dlg.IsDisposed -or -not $dlg.Visible -or ($commit -and $commit.Cancelled)) { $aborted=$true; break }
                        if ($commit -and $commit.Ok) { $okN++ }
                        else {
                            $detail = if ($r.Detail) { ([string]$r.Detail).Replace($stage, $local) } else { '手机上的文件没保存到指定位置' }
                            $fail += "$($e.Name) → $detail"
                        }
                    }
                } finally {
                    # 失败 / 取消后清掉中转残留，别在用户目录里留下 __scrcpy_pull_xxx。
                    if (Test-Path -LiteralPath $stage) {
                        $cleanup = Invoke-FmTask $null -Inputs @{ Path=$stage; Parent=$dest } -Work {
                            try {
                                $path=[IO.Path]::GetFullPath($Inputs.Path)
                                if ([IO.Path]::GetDirectoryName($path).TrimEnd('\') -ne [IO.Path]::GetFullPath($Inputs.Parent).TrimEnd('\') -or [IO.Path]::GetFileName($path) -notmatch '^__scrcpy_pull_[a-f0-9]{32}$') { throw '无效暂存路径' }
                                if ([IO.Directory]::Exists($path)) { [IO.Directory]::Delete($path,$true) }
                                elseif ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
                                [pscustomobject]@{ Info=@{}; Connected=@(); Ok=$true }
                            } catch { [pscustomobject]@{ Info=@{}; Connected=@(); Ok=$false } }
                        }
                    }
                }
                if ($r -and $r.Aborted) { $aborted = $true; break }
            }
            # 关窗 / 中止后整批到此为止，不碰可能已经释放的控件。
            if ($aborted -or $dlg.IsDisposed -or -not $dlg.Visible) { return }
            if ($fail.Count -gt 0) {
                [void](Show-ResultDialog $dlg '下载' "有 $($fail.Count) 项没下载成功" '确认电脑磁盘空间充足、保存位置可写；手机上的文件若刚被移走，点「刷新」后再试。' ($fail -join "`r`n") @('ok'))
            }
            $lblInfo.ForeColor = $(if ($fail.Count -gt 0) { $cRed } else { $cGreen })
            $lblInfo.Text = "已下载 $okN 项到 $dest"
        } finally {
            & $endProgress (-not $aborted -and $fail.Count -eq 0)
            & $setDeviceLock $false
        }
    }

    # —— 新建文件夹 ——
    $doNew = {
        $name = [Microsoft.VisualBasic.Interaction]::InputBox("在当前目录新建一个文件夹，输入名称：", '新建文件夹', '新建文件夹')
        $name = ([string]$name).Trim()
        if (-not $name) { return }
        if (-not (Fm-ValidName $name) -or $name.IndexOfAny($fmBadNameChars) -ge 0) {
            [System.Windows.Forms.MessageBox]::Show('名称里不能包含 \ / : * ? " < > | 等符号、空格以外的控制字符，也不能叫「.」或「..」。', '新建文件夹') | Out-Null
            return
        }
        # 与批量操作同理：输入 / 等待 adb 期间不让设备切换把 mkdir 挪到另一台手机上。
        $batchSerial = [string]$state.Serial
        $batchPath = [string]$state.Path
        $target = Fm-ChildPath $batchPath $name
        $q = Fm-ShQuote $target
        # 必须先判「本来就在」：否则同名时 mkdir 虽然失败，[ -d ] 却是真，会误报新建成功。
        $cmd = "if [ -e $q ]; then printf 'FM_EXISTS\n'; else mkdir $q 2>&1; if [ -d $q ]; then printf 'FM_OK\n'; else printf 'FM_FAIL\n'; fi; fi"
        $out = @(Fm-Shell $batchSerial $cmd $dlg) -join "`n"
        if ($out -match '(?m)^FM_EXISTS\r?$') {
            [System.Windows.Forms.MessageBox]::Show("当前目录里已经有叫「$name」的了，换一个名称再试。", '新建文件夹') | Out-Null
        } elseif ($out -match '(?m)^FM_OK\r?$') {
            & $refresh
            $lblInfo.ForeColor = $cGreen; $lblInfo.Text = "已新建文件夹：$name"
        } else {
            [void](Show-ResultDialog $dlg '新建文件夹' '没能新建这个文件夹' '多半是当前目录不允许写入，或手机存储已满。换个位置（如 内部存储 > Download）再试。' $out @('ok'))
        }
    }

    # —— 重命名：只改当前目录里的名字，不移动、不覆盖 ——
    $doRename = {
        $sel = @($lv.SelectedItems | Where-Object { $_.Tag })
        if ($sel.Count -ne 1) { return }   # 多选改名没有唯一目标，宁可不提供也不猜
        $e = $sel[0].Tag
        $old = [string]$e.Name
        # 旧名字要拼进设备端命令：被列目录协议撕开过的名字（含控制字符 / 路径分隔符）一律不碰。
        if (-not (Fm-ValidName $old)) { return }
        $new = [Microsoft.VisualBasic.Interaction]::InputBox("给「$old」换个名称：", '重命名', $old)
        $new = ([string]$new).Trim()
        # -ceq 区分大小写：Linux 文件系统大小写敏感，只改大小写也是一次合法的重命名。
        if (-not $new -or $new -ceq $old) { return }
        if (-not (Fm-ValidName $new) -or $new.IndexOfAny($fmBadNameChars) -ge 0) {
            [System.Windows.Forms.MessageBox]::Show('名称里不能包含 \ / : * ? " < > | 等符号、空格以外的控制字符，也不能叫「.」或「..」。', '重命名') | Out-Null
            return
        }
        # 与批量操作同理：输入框 / 等待 adb 期间不让设备切换把 mv 挪到另一台手机或别的目录。
        $batchSerial = [string]$state.Serial
        $batchPath = [string]$state.Path
        $cd = Fm-ShQuote $batchPath
        $qo = './' + (Fm-ShQuote $old)
        $qn = './' + (Fm-ShQuote $new)
        # 同名直接 FM_EXISTS：重命名覆盖等于静默删掉目标文件，绝不做。
        # mv 后双向确认「新名字在、旧名字不在」，只读目录 / 厂商限制导致失败时不会误报成功。
        $cmd = "cd $cd 2>/dev/null || { printf 'FM_FAIL\n'; exit 1; }; if [ -e $qn ] || [ -L $qn ]; then printf 'FM_EXISTS\n'; else mv $qo $qn 2>&1; if [ -e $qn ] || [ -L $qn ]; then if [ -e $qo ] || [ -L $qo ]; then printf 'FM_FAIL\n'; else printf 'FM_OK\n'; fi; else printf 'FM_FAIL\n'; fi; fi"
        $out = @(Fm-Shell $batchSerial $cmd $dlg) -join "`n"
        if ($out -match '(?m)^FM_EXISTS\r?$') {
            [System.Windows.Forms.MessageBox]::Show("当前目录里已经有叫「$new」的了，换一个名称再试。", '重命名') | Out-Null
        } elseif ($out -match '(?m)^FM_OK\r?$') {
            & $refresh
            $lblInfo.ForeColor = $cGreen; $lblInfo.Text = "已重命名：$old → $new"
        } else {
            [void](Show-ResultDialog $dlg '重命名' '没能重命名' '可能是当前目录不允许写入、文件正被占用，或手机存储已满。换个位置或名称再试。' $out @('ok'))
        }
    }

    # —— 删除：确认 / 范围钉死 / 结论不明立即停 ——
    $doDelete = {
        $sel = @($lv.SelectedItems | Where-Object { $_.Tag })
        if ($sel.Count -eq 0) { return }
        # 整批固定设备和目录：确认框里写的、cd 进去的、以及每一项 rm 用的，全都是这两个快照。
        # 删到一半换成另一台手机、或跳到别的目录，是这里最不能出的事故。
        $batchSerial = [string]$state.Serial
        $batchPath = [string]$state.Path
        # 删除目标只取「当前目录 + 列表里的名字」，绝不用 Tag.Path：
        # 就算列目录协议被奇怪文件名撕开过，也删不到当前目录之外去。
        # 设备端先 cd 到当前目录、再用 ./名字 操作，范围被钉死在这一层。
        $names = @($sel | ForEach-Object { [string]$_.Tag.Name })
        $bad = @($names | Where-Object { -not (Fm-ValidName $_) })
        if ($bad.Count -gt 0) {
            [void](Show-ResultDialog $dlg '删除' '选中的项目名称不合法，本次已取消' '名称里含有路径分隔符或控制字符。为避免删错位置，这次什么都没有删除；请点「刷新」重新读取后再看一次。' ($bad -join "`r`n") @('ok'))
            return
        }
        $showN = [Math]::Min(20, $sel.Count)
        $preview = @($sel | Select-Object -First $showN | ForEach-Object {
            $kind = if ($_.Tag.IsDir) { '文件夹' } elseif ($_.Tag.IsLink) { '链接' } else { '文件' }
            '· [' + $kind + '] ' + $_.Tag.Name
        }) -join "`n"
        if ($sel.Count -gt $showN) { $preview += "`n· …以及另外 $($sel.Count - $showN) 项" }
        $dirN = @($sel | Where-Object { $_.Tag.IsDir }).Count
        $msg = "确定要删除手机上的这 $($sel.Count) 项吗？（其中 $dirN 个文件夹）`n`n$preview`n`n位置：$batchPath`n`n删除文件夹会连同里面所有内容一起删；手机上的删除不进回收站，无法恢复。"
        $ask = [System.Windows.Forms.MessageBox]::Show(
            [System.Windows.Forms.IWin32Window]$dlg, [string]$msg, '确认删除',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($ask -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        # 不在用户自有存储里的位置再拦一道：普通机器 ADB 本来就没权限，但 root / 工程机真能删掉系统文件。
        $here = $batchPath
        $inStorage = ($here -eq '/sdcard' -or $here.StartsWith('/sdcard/') -or
                      $here -eq '/storage' -or $here.StartsWith('/storage/') -or
                      $here -eq '/mnt/sdcard' -or $here.StartsWith('/mnt/sdcard/'))
        if (-not $inStorage) {
            $warn = "当前位置不是内部存储：$here`n`n这里可能是系统目录。普通手机 ADB 删不掉，但已 root 或工程机上真的会删掉系统文件，可能导致手机无法开机。`n`n确定仍要继续删除吗？"
            $ask2 = [System.Windows.Forms.MessageBox]::Show(
                [System.Windows.Forms.IWin32Window]$dlg, [string]$warn, '再确认一次',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning,
                [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
            if ($ask2 -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        $okN = 0; $fail = @(); $i = 0; $uncertain = $false; $aborted = $false
        & $setDeviceLock $true
        try {
            foreach ($it in $sel) {
                # 关窗后绝不启动下一条 rm：删除是不可恢复操作，比传输更需要这条前置检查。
                if ($dlg.IsDisposed -or -not $dlg.Visible) { $aborted = $true; break }
                $i++; $e = $it.Tag
                $q = './' + (Fm-ShQuote $e.Name)
                $flag = if ($e.IsDir) { '-rf' } else { '-f' }
                $cd = Fm-ShQuote $batchPath
                # cd 失败就直接 FM_FAIL 退出：宁可什么都没删，也不能在错误的工作目录里执行 rm。
                # -L 一并检查，否则「断链」会让 -e 恒为假、把删除失败误报成成功。
                $cmd = "cd $cd 2>/dev/null || { printf 'FM_FAIL\n'; exit 1; }; rm $flag $q 2>&1; if [ -e $q ] || [ -L $q ]; then printf 'FM_FAIL\n'; else printf 'FM_OK\n'; fi"
                $r = Fm-ShellLong $batchSerial $cmd $dlg $lblInfo "正在删除 ($i/$($sel.Count))：$($e.Name)"
                if ($r.Aborted) { $aborted = $true; break }
                $out = [string]$r.Output
                if ($r.Code -eq 0 -and $out -match '(?m)^FM_OK\r?$') { $okN++ }
                else {
                    $fail += "$($e.Name) → $(if ($out) { $out } else { '设备没有返回结果' })"
                    # 普通文件报 FM_FAIL＝还在原地、没删掉，可以继续下一项；但文件夹不一样：
                    # rm -rf 可能已经删掉里面一部分才在某个子文件上失败，这时 FM_FAIL 不代表「没动过」。
                    # 连标记都没有（命令没跑完 / 输出被截断）同理。两种情况都立刻停，不碰剩下的项。
                    if ($out -notmatch '(?m)^FM_FAIL\r?$' -or $e.IsDir) { $uncertain = $true; break }
                }
            }
        } finally { & $setDeviceLock $false }
        if ($dlg.IsDisposed -or -not $dlg.Visible) {
            # 关窗中止时已经没有可挂靠的窗体了，用一个不挂 Owner 的提示把风险说清楚，
            # 否则用户下次打开看到的只是「少了一些文件」，不知道是删了一半。
            if ($aborted -or $uncertain) {
                [void][System.Windows.Forms.MessageBox]::Show('删除已中止，手机上的文件可能只删了一部分。下次打开「文件管理」请先点「刷新」确认，不要直接重试整批。', '删除已中止', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            }
            return
        }
        & $refresh
        if ($aborted -or $uncertain) {
            $why = if ($aborted) { '删除过程中窗口被关闭，设备端命令已中止。' } else { '设备端没有返回明确的成功 / 失败结论。' }
            [void](Show-ResultDialog $dlg '删除' '已停止继续删除' "$why 前面几项可能只删了一部分，现在不能保证状态一致。请先点「刷新」重新读取目录，确认后再决定，不要直接重试整批。" ($fail -join "`r`n") @('ok'))
        } elseif ($fail.Count -gt 0) {
            [void](Show-ResultDialog $dlg '删除' "有 $($fail.Count) 项没能删除" '其余项已处理。系统目录、正在使用的文件，或厂商限制的路径，ADB 也删不掉。' ($fail -join "`r`n") @('ok'))
        } else {
            $lblInfo.ForeColor = $cGreen; $lblInfo.Text = "已删除 $okN 项"
        }
    }

    # —— 事件 ——
    $lv.Add_SelectedIndexChanged($updateButtons)

    # —— 框选补全 ——
    # ListView 的原生框选只能从「没有任何 item 的空白区」起手；FullRowSelect=true 时整行都算 item，
    # 文件一铺满列表就找不到起点，框选彻底失效。这里补一条路径：从文件行上按下左键、拖过 6px
    # 也进入框选（松手时框还得有 8x8，手抖不算）。空白区起手仍交给原生框选（起点互斥，
    # 不会画出两个框）；单击、双击、拖电脑文件进来上传全部照旧。松手才一次算命中项，
    # 避免拖动中反复改 Selected 在几千项时闪烁。
    # 状态放在 $state 里并只改属性：事件脚本块里给普通变量重新赋值不会写回外层作用域。
    $state.Rubber = @{
        Down = $false; Owned = $false; Active = $false; Additive = $false
        Start = [System.Drawing.Point]::Empty; Frame = [System.Drawing.Rectangle]::Empty
    }
    $rb = $state.Rubber
    $eraseFrame = {
        if ($rb.Frame.Width -gt 0 -and $rb.Frame.Height -gt 0) {
            try {
                [System.Windows.Forms.ControlPaint]::DrawReversibleFrame(
                    $lv.RectangleToScreen($rb.Frame), $lv.BackColor,
                    [System.Windows.Forms.FrameStyle]::Dashed)
            } catch {}
        }
        $rb.Frame = [System.Drawing.Rectangle]::Empty
    }
    $lv.Add_MouseDown({
        param($s, $e)
        & $eraseFrame    # 顺手擦掉上次可能残留的框
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { $rb.Down = $false; return }
        $rb.Down = $true; $rb.Active = $false; $rb.Start = $e.Location
        # 起点确实落在文件行上才由我们接管；落在空白区交给 ListView 原生框选。
        $ht = $lv.HitTest($e.Location)
        $rb.Owned = ($null -ne $ht.Item -and $null -ne $ht.Item.Tag)
        $rb.Additive = (([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Control) -ne 0)
    })
    $lv.Add_MouseMove({
        param($s, $e)
        if (-not $rb.Down -or -not $rb.Owned) { return }
        $p = $e.Location
        if (-not $rb.Active) {
            if ([Math]::Abs($p.X - $rb.Start.X) -lt 6 -and [Math]::Abs($p.Y - $rb.Start.Y) -lt 6) { return }
            $rb.Active = $true
            $lv.Capture = $true    # 拖出列表也继续收消息，框不会卡在屏幕上
        }
        $x = [Math]::Max(0, [Math]::Min($p.X, ($lv.ClientSize.Width - 1)))
        $y = [Math]::Max(0, [Math]::Min($p.Y, ($lv.ClientSize.Height - 1)))
        $r = [System.Drawing.Rectangle]::FromLTRB(
            [Math]::Min($rb.Start.X, $x), [Math]::Min($rb.Start.Y, $y),
            [Math]::Max($rb.Start.X, $x) + 1, [Math]::Max($rb.Start.Y, $y) + 1)
        & $eraseFrame
        try {
            [System.Windows.Forms.ControlPaint]::DrawReversibleFrame(
                $lv.RectangleToScreen($r), $lv.BackColor, [System.Windows.Forms.FrameStyle]::Dashed)
            $rb.Frame = $r
        } catch {}
    })
    $lv.Add_MouseUp({
        param($s, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
        $rb.Down = $false
        if (-not $rb.Active) { return }
        $rb.Active = $false
        $r = $rb.Frame
        & $eraseFrame
        if ($lv.Capture) { $lv.Capture = $false }
        # 太小的框只当手抖：擦掉框、保持 ListView 原生的单击结果，别把一次点选改成一片选中。
        if ($r.Width -lt 8 -or $r.Height -lt 8) { return }
        # 按住 Ctrl 框选 = 在原有选择上追加；否则替换。
        $keep = @()
        if ($rb.Additive) { $keep = @($lv.SelectedItems) }
        # 只给可见行算纵向命中：大目录里对几千个不可见项调 GetItemRect 是最明显的开销。
        $n = $lv.Items.Count
        $first = 0
        try { if ($lv.TopItem) { $first = $lv.TopItem.Index } } catch {}
        $rowH = 20
        if ($n -gt 0) { try { $rowH = [Math]::Max(1, $lv.GetItemRect($first).Height) } catch {} }
        $last = [Math]::Min(($n - 1), ($first + [int]($lv.ClientSize.Height / $rowH) + 2))
        $state.RubberBusy = $true
        try {
            $lv.BeginUpdate()
            try {
                for ($i = 0; $i -lt $n; $i++) {
                    $it = $lv.Items[$i]
                    if (-not $it.Tag) { if (-not $rb.Additive) { $it.Selected = $false }; continue }
                    $want = $false
                    if ($i -ge $first -and $i -le $last) {
                        # 只按纵向区间判断，不用整个矩形相交：FullRowSelect 本来就是按整行选，
                        # 而 GetItemRect 的行宽未必盖到最后一列右侧的空白，从那里起手会一行都选不中。
                        try {
                            $ir = $lv.GetItemRect($i)
                            $want = ($r.Bottom -gt $ir.Top -and $r.Top -lt $ir.Bottom)
                        } catch {}
                    }
                    if ($keep -contains $it) { $want = $true }
                    if ($it.Selected -ne $want) { $it.Selected = $want }
                }
            } finally { $lv.EndUpdate() }
        } finally { $state.RubberBusy = $false }
        & $updateButtons
    })

    $lv.Add_DoubleClick({ Invoke-MainFlow ($openSelected) $dlg $script:fmFlow })
    $lv.Add_DragEnter({ param($s, $e) if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy } })
    $lv.Add_DragDrop({
        param($s, $e)
        $state.DropPaths = @($e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
        Invoke-MainFlow ({ & $doUpload $state.DropPaths }) $dlg $script:fmFlow
    })
    $lv.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Delete -and $btnDel.Enabled) {
            $e.SuppressKeyPress = $true
            Invoke-MainFlow ({ & $doDelete }) $dlg $script:fmFlow
        }
    })

    # —— 方向键导航：← 返回上一级，→ / Enter 进入选中的文件夹 ——
    # 挂在窗体上并开 KeyPreview：焦点落在按钮 / 快捷入口上时方向键照样有效。
    # 只有路径框和设备下拉框例外——那里 ← → 是移动光标 / 切设备，Enter 是「转到」，不能抢。
    $dlg.KeyPreview = $true
    $dlg.Add_KeyDown({
        param($s, $e)
        # 带 Ctrl / Alt / Shift 的组合键一律不碰，留给控件和系统（Ctrl+A 全选、Alt+F4 等）。
        if ($e.Modifiers -ne [System.Windows.Forms.Keys]::None) { return }
        $f = $dlg.ActiveControl
        if ($f -is [System.Windows.Forms.TextBoxBase] -or $f -is [System.Windows.Forms.ComboBox]) { return }
        $k = $e.KeyCode
        $back = $false; $folder = $null
        if ($k -eq [System.Windows.Forms.Keys]::Left) {
            $e.SuppressKeyPress = $true; $e.Handled = $true
            if ($state.Path -eq '/') { return }   # 已在根目录：吞掉按键，不发一次没有意义的 adb 刷新
            $back = $true
        }
        elseif ($k -eq [System.Windows.Forms.Keys]::Right -or $k -eq [System.Windows.Forms.Keys]::Enter) {
            $folder = & $selectedFolder
            # 没选中文件夹就不吞键：焦点在按钮上时 Enter 仍应激活按钮，选中文件时也不假装导航。
            if (-not $folder) { return }
            $e.SuppressKeyPress = $true; $e.Handled = $true
        }
        elseif ($k -eq [System.Windows.Forms.Keys]::F2) {
            # 和「重命名」按钮共用同一条流程；没选中恰好一项时不吞键，交给控件自己处理。
            if (-not $btnRename.Enabled) { return }
            $e.SuppressKeyPress = $true; $e.Handled = $true
            Invoke-MainFlow ({ & $doRename }) $dlg $script:fmFlow
            return
        }
        else { return }
        if ($back) { Invoke-MainFlow ($goUp) $dlg $script:fmFlow }
        else       { Invoke-MainFlow ($openSelected) $dlg $script:fmFlow }
        # 导航完把焦点交回列表：接着用 ↑↓ 选、→ 进才连贯（刚用鼠标点过按钮时尤其需要）。
        try { [void]$lv.Focus() } catch {}
    })

    $btnUp.Add_Click({ Invoke-MainFlow ($goUp) $dlg $script:fmFlow })
    $btnGo.Add_Click({ Invoke-MainFlow ({ & $enter $txtPath.Text }) $dlg $script:fmFlow })
    $txtPath.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $e.SuppressKeyPress = $true
            Invoke-MainFlow ({ & $enter $txtPath.Text }) $dlg $script:fmFlow
            # 跳到新目录后把焦点交还列表，否则方向键会一直被路径框当成移动光标吃掉。
            try { [void]$lv.Focus() } catch {}
        }
    })
    # 逐条写死路径，不用「数组套数组 + 循环」：PowerShell 的 @() 会把嵌套数组摊平成标量，
    # 那样 $pair[1] 取到的是路径字符串的第二个字符，跳过去的目录全是错的。
    $lnkHome.Add_Click({ Invoke-MainFlow ({ & $enter '/sdcard' }) $dlg $script:fmFlow })
    $lnkDl.Add_Click({ Invoke-MainFlow ({ & $enter '/sdcard/Download' }) $dlg $script:fmFlow })
    $lnkDcim.Add_Click({ Invoke-MainFlow ({ & $enter '/sdcard/DCIM' }) $dlg $script:fmFlow })
    $lnkPic.Add_Click({ Invoke-MainFlow ({ & $enter '/sdcard/Pictures' }) $dlg $script:fmFlow })
    $lnkRoot.Add_Click({ Invoke-MainFlow ({ & $enter '/' }) $dlg $script:fmFlow })
    $cmbDev.Add_SelectedIndexChanged({
        if ($state.Rebuilding -or $cmbDev.SelectedIndex -lt 0) { return }
        $pick = [string]$state.Serials[$cmbDev.SelectedIndex]
        # Fm-Transfer / Fm-ShellLong 等待时会 DoEvents，这个事件照样会插进来。忙时绝不能改
        # $state.Serial / $script:fmShellMode：正在跑的批量循环一旦重读，下一项就发到另一台手机上。
        # 同时把下拉框拨回当前设备，别让用户以为切换已经生效。
        if ($script:fmFlow.Busy) {
            if ($pick -ne $state.Serial) {
                $j = [array]::IndexOf($state.Serials, $state.Serial)
                if ($j -ge 0 -and $j -ne $cmbDev.SelectedIndex) {
                    $state.Rebuilding = $true
                    try { $cmbDev.SelectedIndex = $j } finally { $state.Rebuilding = $false }
                }
                try {
                    $lblInfo.ForeColor = $cMuted
                    $lblInfo.Text = '正在处理，等这一批完成再切换设备'
                } catch {}
            }
            return
        }
        $state.Serial = $pick
        $script:fmShellMode = $null
        Invoke-MainFlow ({ & $refresh }) $dlg $script:fmFlow
    })
    $btnUpload.Add_Click({ Invoke-MainFlow ({ & $pickAndUpload }) $dlg $script:fmFlow })
    $btnDownload.Add_Click({ Invoke-MainFlow ({ & $doDownload }) $dlg $script:fmFlow })
    $btnRename.Add_Click({ Invoke-MainFlow ({ & $doRename }) $dlg $script:fmFlow })
    $btnNew.Add_Click({ Invoke-MainFlow ({ & $doNew }) $dlg $script:fmFlow })
    $btnDel.Add_Click({ Invoke-MainFlow ({ & $doDelete }) $dlg $script:fmFlow })
    $btnRefresh.Add_Click({ Invoke-MainFlow ({
        # 顺带刷新设备列表：刷新时手机可能刚插上 / 刚掉线，下拉框要跟着变。
        # 同时清掉 shell 写法缓存：上次探测若正好赶上设备重连失败，会一直用错写法直到关窗。
        $script:fmShellMode = $null
        $now = @(Get-DeviceList)
        if ($now.Count -gt 0) {
            $state.Rebuilding = $true
            try {
                $keep = $state.Serial
                $state.Serials = @($now); $cmbDev.Items.Clear()
                foreach ($s in $now) { [void]$cmbDev.Items.Add("$(Get-FriendlyName $s)   ·   $s") }
                $j = [array]::IndexOf($state.Serials, $keep); if ($j -lt 0) { $j = 0; $state.Serial = $now[0]; $script:fmShellMode = $null }
                $cmbDev.SelectedIndex = $j
            } finally { $state.Rebuilding = $false }
        }
        & $refresh
    }) $dlg $script:fmFlow })
    $btnClose.Add_Click({ $dlg.Close() })
    $dlg.CancelButton = $btnClose
    # 关窗时把挂在本窗口名下的后台命令一并取消（慢目录 / 退出收尾）：worker 的 Control 被置位后
    # Invoke-ShortCommand 会杀掉 adb 子进程，OnFinally 仍会跑，不会留一个悬空的「正在读取…」。
    $dlg.Add_FormClosed({ Cancel-OwnerTasks $dlg })
    # 首屏读目录等窗口真正显示（Shown）后再跑：后台任务靠 WinForms Timer 收结果，
    # ShowDialog 之前窗口还没进消息循环、Visible 也是 false，过早读会出现「打不开这个目录」，
    # 而用户点一下「内部存储」又能正常打开。窗口显示后所有按 Visible 判关窗的传输/删除逻辑也才成立。
    # 首屏读取也占用文件窗口的忙锁，防止等待时切设备或导航触发嵌套读取、把旧列表填到新目录。
    $dlg.Add_Shown({ Invoke-MainFlow ($refresh) $dlg $script:fmFlow })

    [void]$dlg.ShowDialog($owner)
    # 不主动 Dispose $boldFont / $fmtip：列表行还持有这个 Font 引用，窗口 Close 后句柄未必立刻释放，
    # 提前 Dispose 会让系统的最后一次重绘抛异常。这几个小对象随窗口一起被回收即可。
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
                if ([Native.Win]::IsIconic($hwnd)) { [void][Native.Win]::ShowWindow($hwnd, 1) }   # SW_SHOWNORMAL：最小化/收进托盘（隐藏且最小化）时一步还原并显示；SW_RESTORE 不会给隐藏窗口加 WS_VISIBLE
                if (-not [Native.Win]::IsWindowVisible($hwnd)) { [void][Native.Win]::ShowWindow($hwnd, 5) }   # SW_SHOW：窗口只是被隐藏（托盘态）时显示
                [void][Native.Win]::SetForegroundWindow($hwnd)
                Start-Sleep -Milliseconds 60
                if ([Native.Win]::GetForegroundWindow() -ne $hwnd) { [void][Native.Win]::ShowWindow($hwnd, 6); [void][Native.Win]::ShowWindow($hwnd, 1) }   # 6=SW_MINIMIZE→1=SW_SHOWNORMAL 兜底，必成
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
    $lblStatus.Text = '◌ 检测中…'
    $lblStatus.Cursor = [System.Windows.Forms.Cursors]::Hand   # 点状态药丸 = 进入设备管理（状态→管理，语义自洽）
    $form.Controls.Add($lblStatus)
    Set-Rounded $lblStatus 13

    # 设备信息小字（型号 + 安卓版本），让用户一眼看出摄像头(12+)/独立窗口(11+)能不能用
    $lblDevInfo = New-Object System.Windows.Forms.Label
    $lblDevInfo.Size = New-Object System.Drawing.Size(200, 16)
    $lblDevInfo.Location = New-Object System.Drawing.Point(284, 60)
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

    # 底部：提示（左） + 设备/快捷键/设置 链接 + GitHub 图标（右，归入「工具/关于」这组安静的次要入口）
    $lblHint = New-Caption '首次连接点「允许 USB 调试」' 28 338
    $form.Controls.Add($lblHint)
    # 底部非模态临时提示（录制提示 / 摄像头自动重连提示共用）：换文案几秒后自动恢复原提示。
    # 只在「当前不是提示态」时记住原始文案——否则短时间内连续两次提示会把上一条提示当成「原文」记下。
    # 恢复用一只常驻定时器（新提示只是重置它的间隔），且回调不可用 GetNewClosure：
    # 闭包会绑到新的动态模块，里面 $script: 前缀解析到该模块自己的空 script 作用域全是 $null——
    # 恢复时 ForeColor 被赋 $null 直接抛「无法转换为 System.Drawing.Color」的未处理异常弹窗。
    $script:hintRestore = New-Object System.Windows.Forms.Timer
    # 还原动作单独成块：定时器到点走它，防重入提示也要在流程结束时主动走它（否则提示比流程先消失）
    $script:restoreHint = {
        $script:hintRestore.Stop()
        $lblHint.Text = $script:recHintText; $lblHint.ForeColor = $script:recHintColor
        if ($script:hintLinksHidden) {
            $btnFiles.Visible = $true; $btnDevices.Visible = $true; $btnShortcuts.Visible = $true; $btnSettings.Visible = $true; $btnGh.Visible = $true
            $script:hintLinksHidden = $false
        }
        $script:recTipActive = $false
    }
    $script:hintRestore.Add_Tick({ & $script:restoreHint })
    $script:showTempHint = {
        param($text, $color, $ms = 6000)
        if (-not $script:recTipActive) { $script:recHintText = $lblHint.Text; $script:recHintColor = $lblHint.ForeColor }
        $script:recTipActive = $true
        $lblHint.Text = $text; $lblHint.ForeColor = $color
        # 提示长到够着链接行（x=288）就先临时隐藏链接，提示结束再还原——否则两者叠字
        if ([System.Windows.Forms.TextRenderer]::MeasureText([string]$text, $lblHint.Font).Width -gt 250 -and -not $script:hintLinksHidden) {
            $btnFiles.Visible = $false; $btnDevices.Visible = $false; $btnShortcuts.Visible = $false; $btnSettings.Visible = $false; $btnGh.Visible = $false
            $script:hintLinksHidden = $true
        }
        $script:hintRestore.Stop()
        if ($null -ne $ms) { $script:hintRestore.Interval = $ms; $script:hintRestore.Start() }   # $null = 挂着不自动还原
    }
    # 主流程收尾一律清掉忙提示；流程内确实要保留的提示（如「录制中」）用它豁免一次，
    # 让提示自己的定时器负责还原——否则刚亮出来就被 Invoke-MainFlow 的 finally 抹掉。
    $script:hintKeepAfterFlow = $false
    # 不再放「刷新」：状态会在窗口重新获得焦点时自动重测，「设备」管理打开也会重新扫描
    # 「文件」和「设备 / 快捷键 / 设置」同属底部这组辅助面板入口，按 x 顺序排开。
    $btnFiles = New-LinkBtn '文件' 230 334 52
    $btnDevices = New-LinkBtn '设备' 288 334 52
    $btnShortcuts = New-LinkBtn '快捷键' 344 334 62
    $btnSettings = New-LinkBtn '设置' 410 334 52
    $form.Controls.AddRange(@($btnFiles, $btnDevices, $btnShortcuts, $btnSettings))

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

    $tt.SetToolTip($btnWired, '用数据线连接，最稳定、延迟最低。若当前没有数据线设备，这个按钮投的是已连上的那台无线设备。')
    $tt.SetToolTip($btnWireless, '不用线。已连手机时直接开始；首次可选插一次线，或 Android 11+ 用配对码免插线。')
    $tt.SetToolTip($btnCamera, '把手机摄像头当电脑摄像头用（需 Android 12+）；支持横屏、竖屏和「旋转 180°（倒置修正）」。')
    $tt.SetToolTip($btnRecord, '把手机屏幕录制成视频文件。')
    $tt.SetToolTip($btnNd, '在电脑上单开一块屏运行某个 App，不影响手机（需 Android 11+）。')
    $tt.SetToolTip($btnShortcuts, 'scrcpy 常用快捷键速查（全屏、息屏、旋转、复制粘贴、拖文件装 APK 等）。')
    $tt.SetToolTip($btnSettings, '画质、声音、控制、窗口、独立窗口、录制等都可在这里自定义。')
    $tt.SetToolTip($btnFiles, '浏览手机上的文件：上传、下载、新建文件夹、删除（直接走 ADB，不用装 App）。')
    $tt.SetToolTip($btnDevices, '管理多台设备：切换、断开、设默认、忘记，或输入 IP 直连。')
    $tt.SetToolTip($lblStatus, '点击管理设备：切换 / 断开 / 输入 IP 连接（状态会在切回窗口时自动刷新）。')

    # ---------------- 行为 ----------------
    $renderStatus = {
        param($result)
        if ($script:mainFlow -and $script:mainFlow.Busy) { return }
        if (-not $result.Success) {
            $lblStatus.BackColor=$cTagBg; $lblStatus.ForeColor=$cMuted
            $lblStatus.Text='○ 状态查询失败'
            $lblDevInfo.Text=''
            return
        }
        $devs=@($result.Devices)
        # 掉线且开了自动重连：后台探测+连回上次的无线地址（不阻塞界面，下次刷新生效）。
        # 排除名单仍由 Reconnect-LastAsync 检查，避免用户断开的设备被刷新逻辑连回。
        if ($devs.Count -eq 0 -and $settings.autoConnect -and $settings.lastWirelessAddr) {
            Reconnect-LastAsync $settings.lastWirelessAddr
        }
        if ($devs.Count -gt 0) {
            $w = $devs | Where-Object { Test-Wireless $_ } | Select-Object -First 1
            if ($w) {
                if ($settings.lastWirelessAddr -ne $w) { $settings.lastWirelessAddr = $w; Save-Settings }
                Add-KnownDevice $w (Get-FriendlyName $w -CachedOnly)   # 任何方式连上的无线设备都自动记住，供「设备管理」重连
            }
            # 状态显示哪台：默认设备（若在线）优先，否则无线优先，再否则第一台
            $isDefault = $settings.defaultDevice -and ($devs -contains $settings.defaultDevice)
            $dev = if ($isDefault) { $settings.defaultDevice } elseif ($w) { $w } else { $devs[0] }
            $type = if (Test-Wireless $dev) { '无线' } else { 'USB' }
            $lblStatus.BackColor = $cGreenBg; $lblStatus.ForeColor = $cGreen
            $lblStatus.Text = "● 已连接 $type"
            $info = Get-DevInfo $dev -CachedOnly
            $ver = if ($info.Ver -gt 0) { " · Android $($info.Ver)" } else { '' }
            $star = if ($isDefault -and $devs.Count -gt 1) { '★ ' } else { '' }   # 多设备时标出当前是默认那台
            $lblDevInfo.Text = "$star$(Get-FriendlyName $dev -CachedOnly)$ver"
        } else {
            $lblStatus.BackColor = $cTagBg; $lblStatus.ForeColor = $cMuted
            $lblStatus.Text = '○ 未连接'
            $lblDevInfo.Text = ''
        }
    }
    $updateStatus = {
        if ($script:mainFlow -and $script:mainFlow.Busy) { return }
        Start-DeviceScan -Owner $form -Kind 'status' -OnDone $renderStatus
    }
    $btnShortcuts.Add_Click({ Invoke-MainFlow ({ Show-Shortcuts $form }) })
    $btnSettings.Add_Click({ Invoke-MainFlow ({ Show-Settings $form }) })
    # 与「有线 / 无线投屏」等入口一样走 -WithDevices：异步查询成功后把设备数组交给文件管理窗口，
    # 失败 / 取消 / 忙态收尾都由 Invoke-MainFlow 统一负责，不在窗口里自己再查一次。
    $btnFiles.Add_Click({ Invoke-MainFlow -WithDevices -Source $btnFiles ({
        param($devices)
        Show-FileManager $form $devices
    }) })
    # 设备管理入口：底部「设备」链接 + 右上角状态药丸都可进；关掉后刷新一次状态
    $openDevices = { Invoke-MainFlow ({ Show-DeviceManager $form; & $updateStatus }) }
    $btnDevices.Add_Click($openDevices)
    $lblStatus.Add_Click($openDevices)

    # 主操作防重入。这些流程内部全是模态框（ShowDialog 自己会泵消息队列），期间排队的第二次点击
    # 会被立刻派发 → 整条流程跑两遍（表现为同一个提示弹两次、叠两个设备管理窗）。而 adb 冷启动一次
    # 能阻塞界面 ~2.4 秒且毫无反馈，正是诱发那一次重复点击的源头，所以忙时同时挂等待光标。
    # 标志必须走「哈希表 + 引用」：闭包有自己的模块作用域，写 $script:裸变量 赋的是副本、真实标志不变；跨闭包共享状态一律用哈希表通过捕获引用传递。
    $script:mainFlow = @{ Busy = $false }
    # 设备管理另用一把锁：它是模态窗，「设备」那条流程的锁会占满整个设备管理开着的时段，
    # 窗内按钮若共用同一把，开完窗就全点不动了。
    $script:dmFlow = @{ Busy = $false }
    # 文件管理也是模态窗，同理单用一把锁：否则主流程锁占满整个窗口开着的时间，窗内按钮全点不动。
    $script:fmFlow = @{ Busy = $false }
    # 忙时的可见反馈：只挂沙漏光标 + 一行小字，四个大按钮看着照样能点，用户以为没点上就再点一次。
    # 置灰只针对主流程那把锁；设备管理窗内的按钮走 dmFlow，不能跟着灰掉。
    # 分两组刷：主操作与更多功能各自的退档幅度不同；底部三个链接也要一起退，否则忙时它们成了画面里最亮的东西。
    $script:busyPrimary   = @($btnWired, $btnWireless)
    $script:busySecondary = @($btnCamera, $btnRecord, $btnNd)
    $script:busyLinks     = @($btnFiles, $btnDevices, $btnShortcuts, $btnSettings)
    $script:busySnap = @()
    function Set-BusyLook {
        param([bool]$On, $Source)
        if (-not $On) {
            foreach ($s in $script:busySnap) {
                $s.Btn.BackColor = $s.Back; $s.Btn.ForeColor = $s.Fore
                $s.Btn.FlatAppearance.MouseOverBackColor = $s.Over
                $s.Btn.FlatAppearance.MouseDownBackColor = $s.Down
                $s.Btn.FlatAppearance.BorderColor = $s.Line
            }
            $script:busySnap = @()
            foreach ($l in $script:busyLinks) { $l.ForeColor = $cMuted }
            return
        }
        $groups = @(
            @{ List = $script:busyPrimary;   Back = $cBusyInk;     Fore = $cBusyInkText; Over = $cBusyInk;   Down = $cBusyInk;   Line = $cBusyInk },
            @{ List = $script:busySecondary; Back = $cBusySecBg;   Fore = $cBusySecText; Over = $cBusySecBg; Down = $cBusySecBg; Line = $cBusySecLine })
        foreach ($g in $groups) {
            foreach ($b in $g.List) {
                if ($b -eq $Source) { continue }   # 被点的那一个留原色——一眼看出是哪一步在跑（Source 由调用处显式传，$sender 在这个宿主里取不到）
                $script:busySnap += [pscustomobject]@{ Btn = $b; Back = $b.BackColor; Fore = $b.ForeColor; Over = $b.FlatAppearance.MouseOverBackColor; Down = $b.FlatAppearance.MouseDownBackColor; Line = $b.FlatAppearance.BorderColor }
                $b.BackColor = $g.Back; $b.ForeColor = $g.Fore
                # hover/按下色一起钉住：否则忙时鼠标一放上去按钮又亮回可用样
                $b.FlatAppearance.MouseOverBackColor = $g.Over
                $b.FlatAppearance.MouseDownBackColor = $g.Down
                $b.FlatAppearance.BorderColor = $g.Line
            }
        }
        foreach ($l in $script:busyLinks) { $l.ForeColor = $cBusyLink }
    }
    function Invoke-MainFlow {
        param([scriptblock]$Body, $Owner, $Flag, $Source, [switch]$WithDevices)
        if (-not $Flag) { $Flag = $script:mainFlow }
        if ($Flag.Busy) {
            # 忙时不动光标：正在跑的那条流程已经把窗口设成等待光标了，这里再设一次没人给它复位
            & $script:showTempHint '正在处理，请稍候…' $cMuted $null
            $script:hintHeld = $true
            return
        }
        $Flag.Busy = $true
        $w = if ($Owner) { $Owner } else { $form }
        $w.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $isMain = ($Flag -eq $script:mainFlow)
        $statusSnap = $null
        if ($isMain) {
            Set-BusyLook -On $true -Source $Source
            $script:hintKeepAfterFlow = $false
            try { $form.ActiveControl = $null } catch {}   # 去掉刚点过那个链接留下的焦点框
            $statusSnap = @{ Text = $lblStatus.Text; Back = $lblStatus.BackColor; Fore = $lblStatus.ForeColor }
            $lblStatus.BackColor = $cTagBg; $lblStatus.ForeColor = $cMuted
            $lblStatus.Text = '○ 正在处理…'
            # 提示从流程一开始就挂上（不是等第二次点击被挡才亮），并持续到流程结束
            & $script:showTempHint '正在处理，请稍候…' $cMuted $null
            $script:hintHeld = $true
        }
        $flow=@{ Owner=$w; Flag=$Flag; IsMain=$isMain; Status=$statusSnap }
        if ($WithDevices) {
            $done={
                param($result)
                if ($result.Success) { & $Body @($result.Devices) }
                else { Show-DeviceQueryFailure }
            }.GetNewClosure()
            $finished={ Complete-MainFlow $flow }.GetNewClosure()
            try { Ensure-Devices $w $done $finished }
            catch { Complete-MainFlow $flow; throw }
            return
        }
        try { & $Body } finally { Complete-MainFlow $flow }
    }
    function Show-DeviceQueryFailure {
        & $script:showTempHint '查询设备失败，请稍后重试' $cRed 8000
        $script:hintKeepAfterFlow=$true
    }
    function Complete-MainFlow {
        param($flow)
        $Flag=$flow.Flag
        if ($script:deviceScanState.Closing -or $flow.Owner.IsDisposed) { $Flag.Busy=$false; return }
        $w=$flow.Owner; $isMain=$flow.IsMain; $statusSnap=$flow.Status
        $w.Cursor = [System.Windows.Forms.Cursors]::Default
        if ($isMain) {
            Set-BusyLook -On $false
            if ($statusSnap) {
                $lblStatus.Text = $statusSnap.Text; $lblStatus.BackColor = $statusSnap.Back; $lblStatus.ForeColor = $statusSnap.Fore
            }
            $script:hintHeld = $false
            if ($script:hintKeepAfterFlow) {
                $script:hintKeepAfterFlow = $false
            } else {
                & $script:restoreHint
            }
        }
        $Flag.Busy = $false
    }


    $btnWired.Add_Click({ Invoke-MainFlow -WithDevices -Source $btnWired ({
        param($devices)
        $devs=@($devices)
        if ($devs.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("没检测到手机。请用数据线连接并点「允许 USB 调试」，或点右上角的连接状态走无线连接。`n`n不会开 USB 调试？看同目录的「使用说明.txt」第一节。", '有线投屏') | Out-Null; return }
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
    }) })

    $btnWireless.Add_Click({ Invoke-MainFlow -WithDevices -Source $btnWireless ({
        param($devices)
        $devs=@($devices)
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
            $pick = New-Dialog '无线投屏' 360 262 $form

            $pl = New-Lbl '没有检测到手机，选一种无线连接方式：' 16 14
            $btnCable = New-PrimaryBtn '插数据线连接（推荐 · 最省事）' 16 42 328 46 11
            $capCable = New-Caption '插一次线即可，连上后自动切无线、可拔线。' 20 94
            $btnPair = New-SecondaryBtn '用配对码连接（Android 11+ · 免插线）' 16 116 328 40
            $capPair = New-Caption '手机开「无线调试 → 使用配对码配对设备」。' 20 162
            $btnIpc = New-SecondaryBtn '输入 IP 直接连接（保底 · 无需配对码）' 16 184 328 40
            $capIp = New-Caption '手机开着无线调试（网络 adb）时，给个 IP 即可，新旧设备都行。' 20 230

            $btnCable.Add_Click({ $pick.Tag = 'cable'; $pick.Close() })
            $btnPair.Add_Click({ $pick.Tag = 'pair'; $pick.Close() })
            $btnIpc.Add_Click({ $pick.Tag = 'ip'; $pick.Close() })
            $pick.Controls.AddRange(@($pl, $btnCable, $capCable, $btnPair, $capPair, $btnIpc, $capIp))
            New-EscCancel $pick
            [void]$pick.ShowDialog($form)

            if ($pick.Tag -eq 'cable') {
                # 引导 → 重新数设备 → 没连上就地给「重试 / 输入 IP / 取消」，不再用一句「确定」把人弹回起点重做整条流程
                $devs = @(); $wantIp = $false
                while ($true) {
                    $ask = Show-ResultDialog $form '连接手机' '插一次数据线，之后就能免线' "1. 用数据线把手机连上电脑`n2. 手机上点「允许 USB 调试」`n`n连好后点「继续」，会自动切到无线，之后就能拔掉数据线。" '' @('continue', 'cancel')
                    if ($ask -ne 'continue') { return }
                    # 点完继续必须重新数一遍设备：不带 -s 的 scrcpy 遇到「还没插线」会报 Could not find any
                    # ADB device、遇到「插着两台」会报 Multiple (2) ADB devices 然后退出，而控制台默认隐藏——
                    # 用户看到的就是「点了继续什么都没发生」。
                    $devs = @(Get-DeviceList)
                    if ($devs.Count -gt 0) { break }
                    $again = Show-ResultDialog $form '连接手机' '还是没检测到手机' "检查数据线是否插好、手机上是否点过「允许 USB 调试」。手机重启过也要重新插一次线；不想插线也可以直接输 IP。`n`n不会开 USB 调试？看同目录的「使用说明.txt」第一节。" '' @('retry', 'ip', 'cancel')
                    if ($again -eq 'ip') { $wantIp = $true; break }
                    if ($again -ne 'retry') { return }
                }
                if ($wantIp) {
                    $addr = Connect-ByIp $form   # 内部已成功即记住
                    if ($addr) {
                        if ($settings.lastWirelessAddr -ne $addr) { $settings.lastWirelessAddr = $addr; Save-Settings }
                        Start-Scrcpy (@('-s', $addr) + (Get-MirrorArgs -Wireless:$true))
                    }
                    return
                }
                $usb = @($devs | Where-Object { -not (Test-Wireless $_) })
                $t = if ($usb.Count -eq 1) { $usb[0] }
                     elseif ($devs.Count -eq 1) { $devs[0] }
                     else { Select-Device $form $devs '无线投屏 · 选择设备' }
                if ($t) { Start-Scrcpy (@('-s', $t, '--tcpip') + (Get-MirrorArgs -Wireless:$true)) }
            }
            elseif ($pick.Tag -eq 'pair') {
                $addr = Show-WirelessPair $form
                if ($addr) {
                    if ($settings.lastWirelessAddr -ne $addr) { $settings.lastWirelessAddr = $addr; Save-Settings }
                    Touch-KnownDevice $addr (Get-FriendlyName $addr -CachedOnly)
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
    }) })

    $btnCamera.Add_Click({ Invoke-MainFlow -WithDevices -Source $btnCamera ({
        param($devices)
        $serial = Resolve-TargetForFeature $form 12 '手机当摄像头' -Devices $devices   # 点击即定设备、查版本，不够直接弹提示并中止
        if (-not $serial) { return }
        # 自动读取这台设备真正支持的采集分辨率（约 1~2 秒），让分辨率下拉与随后启动的镜头一致
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $camSizes = Get-CameraSizes $serial $form
        if ($null -eq $camSizes) { return }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $camDetected = ((@($camSizes.back).Count + @($camSizes.front).Count) -gt 0)
        $dlg = New-Dialog '手机当摄像头' 264 404 $form

        $gb1 = New-Object System.Windows.Forms.GroupBox
        $gb1.Text = '摄像头'; $gb1.Location = '16,12'; $gb1.Size = '232,52'
        $rbBack = New-Object System.Windows.Forms.RadioButton; $rbBack.Text = '后置'; $rbBack.Location = '16,20'; $rbBack.AutoSize = $true; $rbBack.Checked = ($settings.camFacing -ne 'front')
        $rbFront = New-Object System.Windows.Forms.RadioButton; $rbFront.Text = '前置'; $rbFront.Location = '124,20'; $rbFront.AutoSize = $true; $rbFront.Checked = ($settings.camFacing -eq 'front')
        $gb1.Controls.AddRange(@($rbBack, $rbFront))

        $gb2 = New-Object System.Windows.Forms.GroupBox
        $gb2.Text = '画面方向'; $gb2.Location = '16,74'; $gb2.Size = '232,80'
        $rbLand = New-Object System.Windows.Forms.RadioButton; $rbLand.Text = '横屏'; $rbLand.Location = '16,20'; $rbLand.AutoSize = $true; $rbLand.Checked = ($settings.camOrientation -ne 'port')
        $rbPort = New-Object System.Windows.Forms.RadioButton; $rbPort.Text = '竖屏'; $rbPort.Location = '124,20'; $rbPort.AutoSize = $true; $rbPort.Checked = ($settings.camOrientation -eq 'port')
        $chkRotate180 = New-Chk '旋转 180°（倒置修正）' $settings.camRotate180 16 48
        $tt.SetToolTip($chkRotate180, '手机倒置时勾选，在横屏或竖屏基础上再旋转 180°，不是左右镜像。点「开始」后记住。')
        $gb2.Controls.AddRange(@($rbLand, $rbPort, $chkRotate180))

        # 分辨率：优先用实测支持尺寸（精确 --camera-size，与镜头一致）；读不到时回退到「最大边长」通用档位。
        # 下拉内容随「后置/前置」切换重填——两个摄像头支持的尺寸常常不一样。
        $lblRes = New-Lbl '分辨率' 16 168
        $cbRes = New-Combo @('自动') @('auto') 'auto' 78 165 170
        $tt.SetToolTip($cbRes,'同一朝向只使用第一颗镜头的尺寸与变焦范围。')
        # 说明文字顶格放、限宽自动换行：原先跟在下拉下方 x=78 起步，固定宽度的窗横向摆不下、尾巴被裁掉看不全
        $capRes = New-Caption '' 16 196
        $capRes.MaximumSize = New-Object System.Drawing.Size(230, 0)
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
        $capRes.Text = if ($camDetected) { '✓ 已读取本机支持的尺寸；带不动会自动降一档重试' } else { '没读到支持列表，用通用档位；打不开会自动重试' }
        # 初始倍率：可填范围按这台设备实测的 zoom-range 定（读不到就 1~10 通用范围），倍率值让用户自己填并按设备+前后记住。
        # 控件摆在下面的复选框之后，但得赶在朝向事件之前定义好——前后置的变焦范围不一样，切朝向要跟着重填。
        $lblZoom = New-Lbl '初始倍率' 16 296
        $nudZoom = New-Object System.Windows.Forms.NumericUpDown
        $nudZoom.DecimalPlaces = 1; $nudZoom.Increment = [decimal]0.1
        $nudZoom.Location = New-Object System.Drawing.Point(78, 293); $nudZoom.Size = New-Object System.Drawing.Size(90, 26)
        $nudZoom.BorderStyle = 'FixedSingle'; $nudZoom.BackColor = $cWhite   # 扁平描边，同 New-Nud
        $fillZoom = {
            param($facing)
            # 兜底范围故意放得很宽（不是 1~10）：读不到 zoom-range 时我们并不知道这台机器支持到哪，
            # 写窄了会把「支持 0.5x 超广角但列表没读到」的机型挡在门外。放宽是安全的——实测越界由设备侧夹住
            # （--camera-zoom=99 → Set camera zoom: 10.0，客户端不校验），而且会话结束回传的是夹住后的真实值，
            # 下次打开面板会自己修正成这台机器的实际上限。
            $rg = $camSizes.zoom[$facing]
            $lo = if ($rg) { [decimal]$rg[0] } else { [decimal]0.1 }
            $hi = if ($rg) { [decimal]$rg[1] } else { [decimal]100 }
            $nudZoom.Minimum = $lo; $nudZoom.Maximum = $hi     # 先定范围再赋值，否则超范围的记忆值会被 WinForms 挡下
            $v = [decimal](Get-CamZoom $serial $facing)
            if ($v -lt $lo) { $v = $lo }; if ($v -gt $hi) { $v = $hi }
            $nudZoom.Value = $v
        }
        $initFacing = if ($settings.camFacing -eq 'front') { 'front' } else { 'back' }   # 按上次记住的前后置初始填充
        & $fillRes $initFacing
        & $fillZoom $initFacing
        $rbBack.Add_CheckedChanged({ if ($rbBack.Checked) { & $fillRes 'back'; & $fillZoom 'back' } })
        $rbFront.Add_CheckedChanged({ if ($rbFront.Checked) { & $fillRes 'front'; & $fillZoom 'front' } })

        $chkTorch = New-Chk '打开补光灯' $settings.camTorch 16 236
        $chkMic = New-Chk '同时采集麦克风声音' $settings.camMic 16 264

        $capZoom = New-Caption '投屏中还能按 左 Alt + ↑ / ↓ 实时变焦' 16 324
        $capZoom.MaximumSize = New-Object System.Drawing.Size(230, 0)

        $btnGo = New-PrimaryBtn '开始' 16 352 232 34 11
        $btnGo.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Close() })

        $dlg.Controls.AddRange(@($gb1, $gb2, $lblRes, $cbRes, $capRes, $chkTorch, $chkMic, $lblZoom, $nudZoom, $capZoom, $btnGo))
        $dlg.AcceptButton = $btnGo
        New-EscCancel $dlg
        if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $selVal = [string]$cbRes.Vals[$cbRes.SelectedIndex]
            $facing = if ($rbFront.Checked) { 'front' } else { 'back' }
            $zs = Format-Zoom $nudZoom.Value
            Set-CamRemembered $serial $facing $selVal                  # 分辨率按设备+前后记
            Set-CamZoom $serial $facing $zs                            # 初始倍率同理（看门狗重连沿用同一份参数，倍率不会丢）
            # 面板其余选择记成全局偏好，下次打开沿用：前后置 / 横竖屏 / 倒置修正 / 补光灯 / 麦克风
            $settings.camFacing = $facing
            $settings.camOrientation = if ($rbPort.Checked) { 'port' } else { 'land' }
            $settings.camRotate180 = $chkRotate180.Checked
            $settings.camTorch = $chkTorch.Checked
            $settings.camMic = $chkMic.Checked
            Save-Settings
            $a = @('-s', $serial, '--video-source=camera') + @(Get-CameraSelectionArgs $camSizes $facing)
            if ($zs -ne '1') { $a += "--camera-zoom=$zs" }   # 1 倍是默认值，不必显式传
            if ($selVal -match '^\d+x\d+$') {
                # 设备实测支持的精确采集尺寸：直接用 --camera-size，不再加 --camera-ar 以免比例冲突。
                # 不再加 --no-downsize-on-error：scrcpy 4.1 若这档编码器带不动，会用分级阶梯 {2560..800} 单步降档、进程不退继续跑
                #（不再是 4.0 一步砍到 800 糊成一片），残余失败交给 4.1 原生处理。看门狗只保留「亮屏被抢自动重连」。
                # 若真机上原生降档不理想，回退＝在此加回 '--no-downsize-on-error' 并恢复看门狗 cfg 手动降档分支。
                $a += "--camera-size=$selVal"
            } else {
                # 回退档位：宽高比 + 最大边长，让 scrcpy 自己在支持范围里挑
                $a += '--camera-ar=16:9'
                if ([int]$selVal -gt 0) { $a += @('-m', "$selVal") }
            }
            # 采集尺寸可能大于屏幕工作区（如 1856x1392 落在 1080p 上）；只缩窗口，不改采集分辨率。
            # 数字 fallback（1920/1280）按 16:9 推导 WxH 后再适配；0=原始最高，无法预知，不猜。
            $fitSize = $selVal
            if ($fitSize -match '^(\d+)$') {
                $longEdge = [int]$fitSize
                if ($longEdge -gt 0) { $fitSize = '{0}x{1}' -f $longEdge, [int][Math]::Round($longEdge * 9 / 16) }
            }
            if ($fitSize -match '^(\d+)x(\d+)$' -and $rbPort.Checked) { $fitSize = "$($matches[2])x$($matches[1])" }
            $a += @(Get-FitWindowArgs $fitSize)
            # 画面方向：横屏 / 竖屏 各有自己的基准角，再按「旋转 180°（倒置修正）」叠加半圈——手机整个倒过来放时，
            # 画面正好转 180°，靠这个勾纠正。基准角怎么算见 Get-CamOrientationArgs。
            $a += @(Get-CamOrientationArgs $facing $rbPort.Checked $chkRotate180.Checked)
            if ($chkTorch.Checked) { $a += '--camera-torch' }
            if ($chkMic.Checked) { $a += '--audio-source=mic' } else { $a += '--no-audio' }
            $a += @(Get-HwDecArgs)
            # 交给看门狗盯着（$script:camWatch）：只管「亮屏被抢自动重连」；分辨率带不动已交给 scrcpy 4.1 原生降档，看门狗不再手动换档
            # 同一台的旧会话先标停：用户重新从面板开摄像头 = 放弃旧会话，否则两个会话的看门狗会抢着拉进程
            $previousSessions=@($script:camSessions | Where-Object { $_.Serial -eq $serial })
            if ($previousSessions.Count) {
                foreach ($old in $previousSessions) { $old.SkipZoom=$true }
                $previousItems=@($scrcpyProcs | Where-Object {
                    $item=$_
                    @($previousSessions | Where-Object { [object]::ReferenceEquals($_.Proc,$item.Proc) }).Count -gt 0
                })
                $stopped=Stop-DevicesUi $form -Items $previousItems
                if (-not $stopped.Success) {
                    foreach ($old in $previousSessions) { if (-not (Test-ProcessExited $old.Proc)) { $old.SkipZoom=$false } }
                    return
                }
            }
            $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
            $errFile = Join-Path $env:TEMP ("scrcpy-helper-cam-{0}.log" -f $tag)
            $outFile = Join-Path $env:TEMP ("scrcpy-helper-cam-{0}.out.log" -f $tag)   # 倍率回传用，见 Read-CamZoom
            $p = Start-CamProc $a $errFile $outFile
            if ($p) {
                [void]$script:camSessions.Add([pscustomobject]@{
                    Serial = $serial; Facing = $facing; Args = [string[]]$a
                    Proc = $p; StartedAt = (Get-Date); ErrFile = $errFile; OutFile = $outFile; LastZoom = $null
                    Fails = 0; Proven = $false; Stopped = $false; Reconnecting=$false; SkipZoom = $false; NextTryAt = [datetime]::MinValue
                })
                $script:camWatch.Start()
            }
        }
    }) })

    $btnRecord.Add_Click({ Invoke-MainFlow -WithDevices -Source $btnRecord ({
        param($devices)
        $tgt = Resolve-Target $form -Devices $devices
        if (-not $tgt.Ok) { if ($tgt.Reason -eq 'none') { [System.Windows.Forms.MessageBox]::Show('没检测到手机，请先连接手机再录制。', '录制屏幕') | Out-Null }; return }
        $recExt = Get-RecordingExtension
        $mkvOnly = ($settings.videoCodec -in @('vp8', 'vp9') -or ($settings.audioOn -and $settings.audioCodec -eq 'raw'))
        $sfd = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.InitialDirectory = $PSScriptRoot
        $sfd.FileName = "录屏-$(Get-Date -Format 'yyyyMMdd-HHmmss').$recExt"
        $sfd.DefaultExt = $recExt
        $sfd.Filter = if ($mkvOnly) { 'MKV 视频|*.mkv' } else { 'MP4 视频|*.mp4|MKV 视频|*.mkv' }
        $sfd.FilterIndex = if (-not $mkvOnly -and $recExt -eq 'mkv') { 2 } else { 1 }
        # 不在对话框关闭后改路径；显式填写不兼容后缀时留在对话框里修改，确保覆盖确认与写入同一文件。
        $sfd.Add_FileOk({
            param($sender, $eventArgs)
            $ext = [System.IO.Path]::GetExtension($sender.FileName)
            if (($mkvOnly -and $ext -ne '.mkv') -or $ext -notin @('.mp4', '.mkv')) {
                $eventArgs.Cancel = $true
                [System.Windows.Forms.MessageBox]::Show($(if ($mkvOnly) { '当前编码需使用 mkv，请把文件后缀改为 .mkv。' } else { '请使用 .mp4 或 .mkv 文件后缀。' }), '录制屏幕') | Out-Null
            }
        })
        if ($sfd.ShowDialog($form) -eq 'OK') {
            $recPath = $sfd.FileName
            $a = @('-s', $tgt.Serial, '-r', $recPath) + (Get-VideoArgs) + (Get-AudioArgs)
            # 保持唤醒要分连接方式：无线用 --keep-active（-w/--stay-awake 只在 USB 插电时生效，无线录制会中途息屏断流）
            if ($settings.noControl) { $a += '--no-control' }
            elseif ($settings.stayAwake) { $a += $(if (Test-Wireless $tgt.Serial) { '--keep-active' } else { '-w' }) }
            if ([int]$settings.recTimeLimit -gt 0) { $a += "--time-limit=$($settings.recTimeLimit)" }
            if ($settings.recBackground) { $a += @('--no-window', '--no-playback') }
            $newRec=Start-Scrcpy $a -Recording -PassThru
            $recStarted=($newRec -and -not (Test-ProcessExited $newRec))
            if ($recStarted) {
                $recTip = if ($settings.recBackground) { '● 后台录制中 · 「设备」里可停止录制' } else { '● 录制中 · 关掉投屏窗口可停止录制' }
                & $script:showTempHint $recTip $cGreen
                $script:hintKeepAfterFlow = $true
            }
        }
    }) })

    $btnNd.Add_Click({ Invoke-MainFlow -WithDevices -Source $btnNd ({
        param($devices)
        $serial = Resolve-TargetForFeature $form 11 '独立窗口' -Devices $devices   # 点击即定设备、查版本，不够直接弹提示并中止
        if (-not $serial) { return }
        Show-NewDisplay $form $serial
    }) })

    # 设备状态轮询：仅在窗口处于前台时进行；最小化/失焦自动暂停，省电省资源
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 8000
    $timer.Add_Tick($updateStatus)

    # 摄像头看门狗：手机亮屏/人脸解锁时，Android 相机服务会把摄像头从 scrcpy（shell 优先级低）手里抢走——
    # 这是系统级仲裁，scrcpy 挡不住。只能事后自救。退出后按「退出码 + stderr 报错」分类（病因串核对自 scrcpy 4.x）：
    # ① 退出码 0 = 用户自己关窗 / Stopped 标记 = 助手主动停止 → 不重连；
    # ② stderr 有被抢病因（CAMERA_IN_USE / Camera disconnected 等）= 被抢 → 原参数重连（退避递增，连 12 次失败才罢手）；
    # ③ stderr 有配置/编码器病因（Camera configuration error / MediaCodec 栈等）= 分辨率带不动。
    #    已去掉 --no-downsize-on-error，scrcpy 4.1 能降档时会内部单步降档、进程不退；真走到这里 = 它把分级阶梯也试完了仍开不出
    #    → 直接停并提示选更低分辨率（不再手动换档，那套已交给 4.1 原生）；
    # ④ stderr 只剩通用断流尾声（Device disconnected）= 真断流 → 同②重连（设备不在线则收手）；
    # ⑤ 其它一概不明原因 → 收手不折腾。以前只按「退出码≠0 + 跑了多久」猜，开头 15 秒内被抢会被误判成带不动、连环重开退不掉。
    # 匹配次序②③④不可换：scrcpy 客户端在 server 任何猝死时结尾都补一句 "WARN: Device disconnected"
    # （实测被抢的 CAMERA_IN_USE 日志和带不动的场景都带这尾声），先查它会把「带不动」也吞成「被抢」、分类错。
    $script:camWatch = New-Object System.Windows.Forms.Timer
    $script:camWatch.Interval = 1500
    $script:camWatch.Add_Tick({
        if ($script:closeState.InProgress) { return }
        Update-ProcessLifecycle
        if ($script:camSessions.Count -eq 0) { return }
        $now = Get-Date
        foreach ($cs in @($script:camSessions)) {
          try {
            if ($cs.Reconnecting) { continue }
            if ($cs.Stopped -or -not $cs.Proc) { Remove-CamSession $cs; continue }
            if (-not $cs.Proc.HasExited) {
                # 稳定运行 15 秒 = 这次会话确实起来了：清失败计数（供被抢重连的 12 次上限用）
                if ((($now - $cs.StartedAt).TotalSeconds -ge 15) -and (-not $cs.Proven -or $cs.Fails -gt 0)) {
                    # 每次稳定运行都清零 Fails（不只首次）：12 次上限管的是「连续」失败，
                    # 否则长时间用下来亮屏中断的次数累计够 12 次后就再也不重连了
                    $cs.Proven = $true; $cs.Fails = 0
                }
                continue
            }
            $code = 1; try { $code = $cs.Proc.ExitCode } catch {}
            if ($code -eq 0) { Remove-CamSession $cs; continue }   # 用户自己关的窗，不重连
            if ($now -lt $cs.NextTryAt) { continue }               # 还在退避期，等下个周期
            $errTxt = ''; try { if ($cs.ErrFile) { $errTxt = [System.IO.File]::ReadAllText($cs.ErrFile) } } catch {}
            $cs.Fails++
            # 病因分类（字符串核对自 scrcpy 4.0 客户端与 scrcpy-server 二进制 + 实测 stderr 日志），具体病因优先、通用尾声兜底
            $kind = if ($errTxt -match 'CAMERA_IN_USE|Higher-priority client|Camera disconnected') { 'grab' }
                elseif ($errTxt -match 'Camera configuration error|MediaCodec|CodecException|IllegalArgumentException|Could not select camera size|Could not create video encoder|stream configuration error') { 'cfg' }
                elseif ($errTxt -match 'Device disconnected|stream disabled due to connection error') { 'grab' }
                else { 'unknown' }
            if ($kind -eq 'grab') {
                # 被抢 / 断流：典型是亮屏/解锁把摄像头抢走 → 重连。人脸解锁期间相机可能仍被占着，退避 2/4/6…10s 再试
                if ($cs.Fails -gt 12) {
                    Remove-CamSession $cs
                    & $script:showTempHint '多次重连失败，摄像头已停止' $cRed 12000
                    continue
                }
                $cs.NextTryAt = $now.AddSeconds([Math]::Min(2 * $cs.Fails, 10))
                $cs.Reconnecting=$true
                $session=$cs
                Start-DeviceScan -Owner $form -Kind 'camera' -OnDone ({
                    param($snapshot)
                    Resume-CameraSession $session $snapshot
                }.GetNewClosure()) -OnFinally ({ $session.Reconnecting=$false }.GetNewClosure())
            } elseif ($kind -eq 'cfg') {
                # 编码器/配置类失败退出。已去掉 --no-downsize-on-error：scrcpy 4.1 能降档时会内部单步降档、进程不退；
                # 走到这里 = 它把分级阶梯 {2560..800} 也试完了仍开不出 → 手动再降没意义，直接停并提示选更低分辨率。
                Remove-CamSession $cs
                & $script:showTempHint '摄像头没能打开，请选更低的分辨率' $cRed 12000
            } else {
                # 不明原因退出（stderr 没有认识的报错）：宁可不折腾也别跟用户抢——自动重开才是更大的骚扰
                Remove-CamSession $cs
                & $script:showTempHint '摄像头已退出，未自动重连' $cMuted 8000
            }
          } catch { try { Remove-CamSession $cs } catch {} }   # 看门狗内部任何意外都只放弃这个会话，绝不让异常冒成弹窗
        }
        Update-ProcessLifecycle
    })
    $form.Add_Shown({
        & $updateStatus
        if ($settings.liveStatus -or $settings.autoConnect) { $timer.Start() }
        Connect-RememberedAsync ({ param($connected) & $updateStatus }.GetNewClosure())
        $script:camWatch.Start()
        Start-ActivationWaiter $form.Handle $script:actEvent   # 开始监听"再次启动时激活本窗口"的信号
        # 首次显示主动抢一次前台：conhost --headless 启动的进程窗口有时不会自动到前台/不聚焦，用户以为"没反应"。
        # 本进程激活自己的窗口是可靠的：Activate + TopMost 翻转 + SetForegroundWindow(自身句柄)。
        try { $form.Activate(); $form.TopMost = $true; $form.TopMost = $false; [void][Native.Win]::SetForegroundWindow($form.Handle) } catch {}
    })
    # ---------------- 最小化到系统托盘（设置 > 窗口 里开关，默认关） ----------------
    $tray = New-Object System.Windows.Forms.NotifyIcon
    $tray.Icon = Get-AppIcon
    $tray.Text = 'scrcpy 投屏助手'
    $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $miTrayRestore = $trayMenu.Items.Add('显示主窗口')
    [void]$trayMenu.Items.Add('-')
    $miTrayExit = $trayMenu.Items.Add('退出助手')
    $tray.ContextMenuStrip = $trayMenu
    $script:trayHintShown = $false
    $restoreFromTray = {
        if ($form.IsDisposed) { return }
        # 必须先 Show 再把状态设回 Normal：隐藏状态下直接改 WindowState 不生效，会变成「可见但仍最小化」
        $tray.Visible = $false
        $form.Show()
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $form.Activate()
    }
    $miTrayRestore.Add_Click($restoreFromTray)
    $tray.Add_DoubleClick($restoreFromTray)
    # Win11 习惯：单击托盘图标也还原；右键仍由系统弹菜单
    $tray.Add_MouseClick({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { & $restoreFromTray } })
    $miTrayExit.Add_Click({ $form.Close() })
    # 最小化时收进托盘：延迟到本轮 Resize 消息处理完再 Hide，避免在系统最小化过程中同步隐藏
    $form.Add_Resize({
        if ($settings.minToTray -and $form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
            [void]$form.BeginInvoke([System.Action]{
                if (-not $form.IsDisposed -and $settings.minToTray -and $form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
                    $form.Hide()
                    $tray.Visible = $true
                    if (-not $script:trayHintShown) {
                        $script:trayHintShown = $true
                        $tray.BalloonTipTitle = 'scrcpy 投屏助手'
                        $tray.BalloonTipText = '已收起到系统托盘，单击/双击图标即可还原窗口。'
                        $tray.ShowBalloonTip(2000)
                    }
                }
            })
        }
    })

    # 激活事件仅排队查询，资源管理器可以立即处理还原窗口的消息。
    $form.Add_Activated({
        & $updateStatus
        if ($settings.liveStatus -or $settings.autoConnect) { $timer.Start() } else { $timer.Stop() }
    })
    $form.Add_Deactivate({ $timer.Stop() })
    $form.Add_FormClosing({
        param($sender,$eventArgs)
        Request-AppClose $sender $eventArgs $updateStatus
    })
    $form.Add_FormClosed({ Stop-DeviceScans; Update-ProcessLifecycle; $timer.Stop(); $timer.Dispose(); $script:camWatch.Stop(); $script:camWatch.Dispose(); $script:hintRestore.Stop(); $script:hintRestore.Dispose(); Stop-ActivationWaiter; $tray.Visible = $false; $tray.Dispose(); $trayMenu.Dispose() })   # 让激活等待线程退出，否则它阻塞 WaitOne 会钉住进程不退出；托盘图标先隐藏再释放，避免退出后残留幽灵图标

    # 必须用非模态消息循环（Show + Application::Run），不能 ShowDialog()：「最小化到托盘」要在
    # 窗口隐藏（Hide）后进程继续存活；实测模态循环在窗口 Hide 的瞬间就直接返回，进程随即退出，
    # 托盘图标变成点不动的幽灵图标。非模态循环只在窗口真正关闭时才结束。
    $form.Show()
    [System.Windows.Forms.Application]::Run($form)
}
catch {
    [System.Windows.Forms.MessageBox]::Show("启动出错：`n$($_.Exception.Message)", 'scrcpy 投屏助手') | Out-Null
}
