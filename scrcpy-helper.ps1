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
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)] public static extern System.IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)] public static extern bool CloseHandle(System.IntPtr hObject);
[System.Runtime.InteropServices.DllImport("ntdll.dll")] public static extern int NtQueryInformationProcess(System.IntPtr hProcess, int processInformationClass, System.IntPtr[] processInformation, int processInformationLength, out int returnLength);
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

# 配色（宣纸墨印 2.0：宣纸暖白打底，纯白浮层卡片，炭墨主操作，朱砂仅作印章与录制提示）
$cPaper        = [System.Drawing.Color]::FromArgb(245, 242, 236)   # 宣纸暖白（#F5F2EC）
$cFooterBg     = [System.Drawing.Color]::FromArgb(239, 235, 227)   # 底部状态栏底色（#EFEBE3）
$cInk          = [System.Drawing.Color]::FromArgb(38, 36, 33)      # 炭墨主色（#262421）
$cInkDark      = [System.Drawing.Color]::FromArgb(59, 56, 51)      # 主按钮悬停（#3B3833）
$cText2        = [System.Drawing.Color]::FromArgb(94, 90, 82)      # 次正文字（#5E5A52）
$cMuted        = [System.Drawing.Color]::FromArgb(125, 119, 109)   # 次要说明（#7D776D）
$cRed          = [System.Drawing.Color]::FromArgb(184, 59, 58)     # 朱砂印 / 告警（#B83B3A）
$cRedDark      = [System.Drawing.Color]::FromArgb(152, 42, 41)
$cRedBg        = [System.Drawing.Color]::FromArgb(252, 238, 235)   # 录制/停止浅红底（#FCEEEB）
$cRedStripBg   = [System.Drawing.Color]::FromArgb(253, 247, 246)   # 运行态条底色（#FDF7F6）
$cRedBorder    = [System.Drawing.Color]::FromArgb(242, 201, 199)   # 浅红描边（#F2C9C7）
$cLine         = [System.Drawing.Color]::FromArgb(230, 224, 214)   # 卡片描边 / 发丝线（#E6E0D6）
$cLineStrong   = [System.Drawing.Color]::FromArgb(216, 209, 197)   # 次按钮描边（#D8D1C5）
$cLineHover    = [System.Drawing.Color]::FromArgb(207, 198, 184)   # 卡片悬停描边（#CFC6B8）
$cGreen        = [System.Drawing.Color]::FromArgb(36, 110, 74)     # 已连接绿（#246E4A）
$cGreenBg      = [System.Drawing.Color]::FromArgb(230, 242, 236)   # 绿药丸底（#E6F2EC）
$cGreenBorder  = [System.Drawing.Color]::FromArgb(194, 223, 208)   # 绿药丸描边（#C2DFD0）
$cAmber        = [System.Drawing.Color]::FromArgb(154, 99, 24)     # 待授权琥珀（#9A6318）
$cAmberBg      = [System.Drawing.Color]::FromArgb(251, 243, 228)   # 琥珀药丸底（#FBF3E4）
$cAmberBorder  = [System.Drawing.Color]::FromArgb(234, 212, 168)   # 琥珀描边（#EAD4A8）
$cSoft         = [System.Drawing.Color]::FromArgb(236, 231, 222)   # 未激活胶囊底（#ECE7DE）
$cSoftHover    = [System.Drawing.Color]::FromArgb(226, 219, 208)   # 胶囊悬停底（#E2DBD0）
$cTagBg        = $cSoft
$cWhite        = [System.Drawing.Color]::FromArgb(255, 255, 255)   # 浮层纯白（#FFFFFF）
$cHover        = [System.Drawing.Color]::FromArgb(250, 248, 244)   # 卡片悬停白（#FAF8F4）
# 忙时退档色：自绘按钮在忙态下用这组退档色，避免系统禁用态色差。
$cBusyInk      = [System.Drawing.Color]::FromArgb(108, 103, 95)
$cBusyInkText  = [System.Drawing.Color]::FromArgb(236, 232, 224)
$cBusySecBg    = [System.Drawing.Color]::FromArgb(245, 242, 236)
$cBusySecText  = [System.Drawing.Color]::FromArgb(148, 142, 132)
$cBusySecLine  = [System.Drawing.Color]::FromArgb(226, 220, 210)
$cBusyLink     = [System.Drawing.Color]::FromArgb(182, 176, 166)

$exe = Join-Path $PSScriptRoot 'scrcpy.exe'
$adb = Join-Path $PSScriptRoot 'adb.exe'
$cfgPath = Join-Path $PSScriptRoot '投屏助手-设置.json'

$script:customApps = [ordered]@{}   # 用户自定义的常用 App（名称 => 包名），随设置一起存进 投屏助手-设置.json
$script:hiddenBuiltInApps = @{}    # 按包名记住移除项，避免应用改名后又出现在常用列表。
$script:appFavoriteOrder = [Collections.Generic.List[string]]::new()
$script:phoneAppListCache = @{}
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
          [ValidateRange(1,60000)][int]$TimeoutMs = 15000, $Control)
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
    param($AdbPath, [string[]]$Candidates, [bool]$ConnectAlways, $InfoCache, $Control, [int]$BudgetMs = 15000, [bool]$RetryDeviceList = $false)
    $scan = [pscustomobject]@{ Success = $false; Cancelled = $false; Devices = @(); UnavailableStates = @(); Connected = @(); Info = @{}; Error = '' }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    function Run-Adb {
        param([string[]]$Arguments, [int]$Limit = 3000)
        $left = $BudgetMs - [int]$clock.ElapsedMilliseconds
        if ($left -le 0) { return [pscustomobject]@{ Started = $false; ExitCode = $null; TimedOut = $true; Cancelled = $false; Stdout = ''; Stderr = ''; Error = '' } }
        return (Invoke-ShortCommand -FilePath $AdbPath -ArgumentList $Arguments -TimeoutMs ([Math]::Min($Limit,$left)) -Control $Control)
    }
    function Read-Devices {
        $r = Run-Adb @('devices')
        if ($r.Cancelled) { $scan.Cancelled = $true; return $false }
        if (-not $r.Started -or $r.ExitCode -ne 0 -or $r.TimedOut -or $r.Stdout -notmatch '(?m)^List of devices attached[ \t]*\r?$') {
            $scan.Error = if ($r.Error) { $r.Error }
                elseif ($r.TimedOut) { '等待 ADB 返回设备列表超时。' }
                elseif ($r.Stderr) { $r.Stderr }
                elseif (-not $r.Started) { '无法启动 ADB。' }
                elseif ($r.ExitCode -ne 0) { "ADB 查询设备列表失败（退出码 $($r.ExitCode)）。" }
                else { 'ADB 返回的设备列表格式异常。' }
            return $false
        }
        $scan.Error = ''
        $lines = @($r.Stdout -split "`r?`n")
        $scan.Devices = @($lines | Where-Object { $_ -match "`tdevice`r?$" } | ForEach-Object { ($_ -split "`t")[0] })
        # 保留 ADB 的待授权和离线状态供主界面提示，功能入口仍只接收在线设备。
        $scan.UnavailableStates = @($lines | Where-Object { $_ -match "`t(?:unauthorized|offline)$" } | ForEach-Object { ($_ -split "`t")[1] })
        return $true
    }
    if (-not (Read-Devices)) {
        # ADB 冷启动可能错过第一次查询，后台状态刷新先确认一次再提示。
        if (-not $RetryDeviceList -or $scan.Cancelled -or $Control.Cancelled -or -not (Read-Devices)) { return $scan }
    }
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
        RetryDeviceList = ($Kind -eq 'status')
    }
}
function Start-UiTask {
    param($Owner, [string]$Kind = 'operation', [scriptblock]$Work, [hashtable]$Inputs = @{},
          [string[]]$Functions = @(), [scriptblock]$OnDone, [scriptblock]$OnFinally)
    $state = $script:deviceScanState
    if ($state.Closing -or ($script:closeState.InProgress -and $Kind -ne 'shutdown')) { if ($OnFinally) { & $OnFinally }; return }
    # 保留一个待处理的刷新，避免激活窗口和轮询在同一个后台任务期间排出多份。
    if ($Kind -eq 'status' -and $state.Pending.Kind -contains 'status') { return }
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
            'Invoke-DeviceScan -AdbPath $Inputs.AdbPath -Candidates $Inputs.Candidates -ConnectAlways $Inputs.ConnectAlways -InfoCache $InfoCache -Control $Control -RetryDeviceList $Inputs.RetryDeviceList'
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
    param($Owner, [scriptblock]$Work, [hashtable]$Inputs = @{}, [string[]]$Functions = @(),
          [string]$Kind='operation', [string]$StatusText='正在处理，请稍候…')
    if ($script:deviceScanState.Closing -or ($Owner -and $Owner.IsDisposed)) {
        return [pscustomobject]@{ Success = $false; Cancelled = $true; Error = '操作已取消' }
    }
    $box = @{ Completed = $false; InsideClosing=$false; Result = [pscustomobject]@{ Success = $false; Cancelled = $true; Error = '操作已取消' } }
    $wait = New-Dialog $StatusText 280 100 $Owner
    $wait.Controls.Add((New-Lbl $StatusText 16 14))
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
# 手动刷新只查询当前设备，保留等待框的取消结果和后台扫描的错误信息。
function Wait-DeviceScan {
    param($Owner)
    return (Wait-UiTask -Owner $Owner -StatusText '正在读取设备列表…' -Inputs @{ Adb=$adb } -Work {
        Invoke-DeviceScan -AdbPath $Inputs.Adb -Candidates @() -ConnectAlways $false -InfoCache $InfoCache -Control $Control
    })
}
function Invoke-UiCommand {
    param($Owner, [string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutMs = 15000,
          [string]$StatusText='正在处理，请稍候…')
    return (Wait-UiTask -Owner $Owner -StatusText $StatusText -Inputs @{ FilePath = $FilePath; ArgumentList = $ArgumentList; TimeoutMs = $TimeoutMs } -Work {
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

function Start-PhoneRing {
    param([string]$Serial)
    # 单文件发行包携带下方 Java 源码编译出的 DEX。手机用自带的 app_process 播放，无需安装应用。
    <#
// 从这一段复制为 ScrcpyPhoneRing.java。使用 Android SDK 36 的 android.jar 和 D8 36.0.0。
// javac -g:none --release 8 -classpath <android.jar> ScrcpyPhoneRing.java
// d8 --release --min-api 23 --lib <android.jar> ScrcpyPhoneRing.class 'ScrcpyPhoneRing$RingtoneSource.class'
// 将生成的 classes.dex 转为 Base64，替换下方 $player 的内容。
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioTrack;
import android.media.MediaCodec;
import android.media.MediaDataSource;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.net.Uri;
import android.os.SystemClock;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;

public final class ScrcpyPhoneRing {
    // The player runs as an ADB shell tool, so it has no application Context.
    private static final class RingtoneSource extends MediaDataSource {
        private final RandomAccessFile file;

        RingtoneSource(String path) throws IOException {
            file = new RandomAccessFile(path, "r");
        }

        @Override public synchronized int readAt(long position, byte[] buffer, int offset, int size)
                throws IOException {
            file.seek(position);
            return file.read(buffer, offset, size);
        }

        @Override public synchronized long getSize() throws IOException {
            return file.length();
        }

        @Override public synchronized void close() throws IOException {
            file.close();
        }
    }

    private static MediaFormat selectAudio(MediaExtractor extractor) throws IOException {
        for (int index = 0; index < extractor.getTrackCount(); ++index) {
            MediaFormat format = extractor.getTrackFormat(index);
            String mime = format.getString(MediaFormat.KEY_MIME);
            if (mime != null && mime.startsWith("audio/")) {
                extractor.selectTrack(index);
                return format;
            }
        }
        throw new IOException("The ringtone does not contain audio");
    }

    private static AudioTrack openTrack(MediaFormat format) {
        int channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT);
        int encoding = format.containsKey(MediaFormat.KEY_PCM_ENCODING)
                ? format.getInteger(MediaFormat.KEY_PCM_ENCODING) : AudioFormat.ENCODING_PCM_16BIT;
        AudioFormat.Builder pcm = new AudioFormat.Builder()
                .setEncoding(encoding)
                .setSampleRate(format.getInteger(MediaFormat.KEY_SAMPLE_RATE));
        if (channels <= 2) {
            pcm.setChannelMask(channels == 1 ? AudioFormat.CHANNEL_OUT_MONO : AudioFormat.CHANNEL_OUT_STEREO);
        } else {
            pcm.setChannelIndexMask((1 << channels) - 1);
        }
        return new AudioTrack.Builder()
                .setAudioAttributes(new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build())
                .setAudioFormat(pcm.build())
                .build();
    }

    private static void play(MediaExtractor extractor, MediaCodec decoder) throws IOException {
        AudioTrack track = null;
        boolean inputEnded = false;
        long nextHeartbeat = 0;
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        try {
            // Write to the ADB shell pipe without Android's Java stream redirection.
            FileOutputStream stdout = new FileOutputStream(FileDescriptor.out);
            byte[] heartbeat = "FIND_PHONE_PLAYING\n".getBytes(StandardCharsets.US_ASCII);
            for (;;) {
                int input = inputEnded ? -1 : decoder.dequeueInputBuffer(10000);
                if (input >= 0) {
                    int size = extractor.readSampleData(decoder.getInputBuffer(input), 0);
                    inputEnded = size < 0;
                    decoder.queueInputBuffer(input, 0, Math.max(size, 0),
                            inputEnded ? 0 : extractor.getSampleTime(),
                            inputEnded ? MediaCodec.BUFFER_FLAG_END_OF_STREAM : 0);
                    if (!inputEnded) {
                        extractor.advance();
                    }
                }

                int output = decoder.dequeueOutputBuffer(info, 10000);
                if (output < 0) {
                    continue;
                }
                if (info.size > 0) {
                    if (track == null) {
                        track = openTrack(decoder.getOutputFormat(output));
                        track.play();
                    }
                    ByteBuffer pcm = decoder.getOutputBuffer(output);
                    pcm.position(info.offset);
                    pcm.limit(info.offset + info.size);
                    if (track.write(pcm, info.size, AudioTrack.WRITE_BLOCKING) != info.size) {
                        throw new IOException("The ringtone audio could not be played");
                    }
                    long now = SystemClock.elapsedRealtime();
                    if (now >= nextHeartbeat) {
                        stdout.write(heartbeat);
                        nextHeartbeat = now + 1500;
                    }
                }
                decoder.releaseOutputBuffer(output, false);
                if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                    // Keep queued PCM playing while the decoder goes back to the start.
                    extractor.seekTo(0, MediaExtractor.SEEK_TO_CLOSEST_SYNC);
                    decoder.flush();
                    inputEnded = false;
                }
            }
        } finally {
            if (track != null) {
                track.release();
            }
        }
    }

    public static void main(String[] args) throws IOException {
        Uri source = Uri.parse(args[0]);
        String path = "file".equals(source.getScheme()) ? source.getPath() : args[0];
        try (RingtoneSource ringtone = new RingtoneSource(path)) {
            MediaExtractor extractor = new MediaExtractor();
            try {
                extractor.setDataSource(ringtone);
                MediaFormat format = selectAudio(extractor);
                MediaCodec decoder = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME));
                try {
                    decoder.configure(format, null, null, 0);
                    decoder.start();
                    play(extractor, decoder);
                } finally {
                    decoder.release();
                }
            } finally {
                extractor.release();
            }
        } catch (IOException | IllegalArgumentException | SecurityException ex) {
            System.err.println("FIND_PHONE_RINGTONE_UNAVAILABLE");
            throw ex;
        }
    }
}
    #>
    $player = @'
ZGV4CjAzNQA2cCfb9t8YZMKbQYp+GObFFvAPvf6qFNAEGQAAcAAAAHhWNBIAAAAAAAAAAEwYAACMAAAAcAAAACsAAACgAgAALQAA
AEwDAAAHAAAAaAUAAEoAAACgBQAAAgAAAPAHAADUEAAAMAgAAIIOAACKDgAAnw4AAMAOAADDDgAAyA4AAMwOAADTDgAA1w4AANwO
AADiDgAA5w4AAOoOAADtDgAA8Q4AAPUOAAAXDwAAKg8AAFMPAAB0DwAAmQ8AALYPAADaDwAA9g8AAB0QAAA5EAAAVhAAAHcQAACX
EAAAtBAAAMcQAADhEAAA+RAAAB0RAAA9EQAAYBEAAHwRAACWEQAAshEAAMkRAADgEQAA/BEAACISAAA0EgAASBIAAGcSAAB7EgAA
jxIAAKYSAAC5EgAA0BIAAOwSAAAREwAAIRMAAEkTAABuEwAAeBMAAHsTAAB/EwAAhxMAAIwTAACQEwAAlRMAAJkTAACeEwAApRMA
AKgTAACsEwAAsBMAAMUTAADSEwAA4RMAAOoTAADyEwAA+RMAAAgUAAAPFAAAGhQAACcUAAA8FAAAUBQAAGUUAAB2FAAAfhQAAIMU
AACJFAAAkBQAAJcUAAChFAAAsRQAAL0UAADOFAAA3xQAAOgUAAD3FAAAAhUAAAsVAAAWFQAAJRUAADUVAAA9FQAARBUAAEoVAABP
FQAAVRUAAFsVAABjFQAAbhUAAHMVAAB6FQAAiBUAAI4VAACYFQAAoRUAALMVAAC2FQAAvBUAAMQVAADUFQAA3RUAAPIVAAD/FQAA
BRYAAA0WAAAaFgAAJxYAADsWAABLFgAAYBYAAHAWAACAFgAAjxYAAJwWAACrFgAAtRYAALsWAADCFgAAzhYAANUWAADcFgAAAwAA
AAsAAAAPAAAAEAAAABEAAAASAAAAEwAAABQAAAAVAAAAFgAAABcAAAAYAAAAGQAAABoAAAAbAAAAHAAAAB0AAAAeAAAAHwAAACAA
AAAhAAAAIgAAACMAAAAkAAAAJQAAACYAAAAnAAAAKAAAACkAAAAqAAAAKwAAACwAAAAtAAAALgAAAC8AAAAwAAAAMQAAADIAAAAz
AAAAOAAAAEEAAABDAAAARAAAAAMAAAAAAAAAAAAAAAQAAAAAAAAAnA0AAAUAAAAAAAAApA0AAAYAAAAAAAAArA0AAAoAAAAAAAAA
uA0AAAcAAAAAAAAAwA0AAAgAAAAAAAAAyA0AAAkAAAAAAAAA0A0AAAkAAAAAAAAA3A0AAAsAAAABAAAAAAAAAA0AAAAEAAAA6A0A
AAwAAAAFAAAAAAAAAA0AAAAGAAAA6A0AAAwAAAAHAAAAAAAAAA4AAAAIAAAA8A0AAA4AAAAIAAAA+A0AAAwAAAAJAAAAAAAAAA4A
AAAJAAAAAA4AAA4AAAALAAAAwA0AAA0AAAAPAAAA6A0AAA4AAAAPAAAACA4AAA4AAAAQAAAAwA0AAAwAAAAgAAAAAAAAAA4AAAAg
AAAAwA0AAA0AAAAjAAAA6A0AAA0AAAAkAAAA6A0AADgAAAAnAAAAAAAAADkAAAAnAAAA6A0AADoAAAAnAAAAEA4AADsAAAAnAAAA
IA4AADwAAAAnAAAApA0AAD0AAAAnAAAAKA4AAD4AAAAnAAAAMA4AAD8AAAAnAAAAOA4AAEAAAAAnAAAAQA4AAD4AAAAnAAAATA4A
AD4AAAAnAAAAwA0AAD8AAAAnAAAAVA4AAD4AAAAnAAAAXA4AAD4AAAAnAAAAZA4AAD4AAAAnAAAAbA4AAEEAAAAoAAAAAAAAAEIA
AAAoAAAAdA4AAEIAAAAoAAAAwA0AAA4AAAApAAAAfA4AAAIAGwBUAAAACgAAAFUAAAAKAAAAaQAAAAoAAACGAAAAFwAXAGsAAAAh
ABoAUwAAACYAJQA3AAAAAgAkAAAAAAACABoASwAAAAIACQBfAAAAAgADAHQAAAADABoAAAAAAAMAKABlAAAAAwARAGoAAAADACEA
bgAAAAMAFAB7AAAABAAaAAAAAAAEAAsASQAAAAQACgCBAAAABAAKAIUAAAAGABoAAAAAAAYADQBJAAAABgAMAH8AAAAGAAwAgAAA
AAYADACDAAAABgAMAIQAAAAIABoAAAAAAAgAEABJAAAACAAOAH0AAAAIAA8AfgAAAAkAGgBuAAAACQAaAHYAAAAJAAcAigAAAAoA
GgAAAAAACwAiAEwAAAALABIATgAAAAsAAgBPAAAACwAEAFAAAAALABoAVgAAAAsAGQBYAAAACwAZAFoAAAALABMAWwAAAAsAHABx
AAAACwAaAHYAAAALAB0AdwAAAAsAGgCHAAAADQAaAAAAAAAOABoAAAAAAA4AKQBHAAAADgAJAF0AAAAOAAAAYQAAAA4AEwBiAAAA
DgAGAHUAAAAOABoAdgAAAA4AHwB6AAAADgAbAHwAAAAOACAAggAAAA8AKwBNAAAADwAFAFkAAAAPABcAYAAAABAAFgBcAAAAEAAW
AF4AAAAQABUAbAAAABEACQBRAAAAGAAjAAAAAAAYACcAigAAABkAJAAAAAAAGgAkAHAAAAAbACUAAAAAABsAGgBLAAAAGwAJAGMA
AAAbAAgAcwAAABsAHgB5AAAAHQABAGYAAAAeABoAAAAAACAAKgBSAAAAIAAsAFcAAAAgACsAiAAAACIAJgBGAAAAJAAYAGQAAAAk
ABgAbwAAAAIAAAAQAAAADQAAAAAAAAD/////9BcAAKAXAAAAAAAAAwAAABEAAAAeAAAAAAAAAP////8kGAAAvhcAAAAAAAAHAAYA
BAACAAAAAAARAAAAHQFUEAAAbjBBACADVBIAAG5AQABCZQoCHgEPAg0CHgEnAgAAAQAAAAsAAQAPAAAAAQABAAEADgADAAEAAQAC
AAAAAAAMAAAAHQJUIAAAbhA/AAAACwAeAhAADQAeAicAAQAAAAYAAQAKAAAAAQABAAEACQAEAAIAAwAAAAAAAAANAAAAcBAnAAIA
IgAbABoBcgBwMD0AMAFbIAAADgAAAAIAAQABAAIAAAAAAAsAAAAdAVQQAABuED4AAAAeAQ4ADQAeAScAAAABAAAABQABAAkAAAAB
AAEAAQAIAAUAAQACAAAAAAAAAGMAAAAaAEoAbiAzAAQACgAaAW0AbiAyABQACgISIzgCBwBuIDMAFAAKASgCATEiAgYAcBANAAIA
biARABIADAEaAngAbiAzACQACgRuIBIAQQAMBBJBEhI2MAwAMyAEAAEQKAMTAAwAbiAQAAQAKAeYAAIAsSBuIA8ABAAiAAgAcBAT
AAAAIgIEAHAQCQACAG4gDAASAAwCbiALABIADAFuEAoAAQAMAW4gFQAQAAwAbhAOAAQADARuIBYAQAAMBG4QFAAEAAwEEQQAAAUA
AQACAAAAAAAAACoAAAASAG4QKwAEAAoBNRAdAG4gLAAEAAwBGgJnAG4gNAAhAAwCOAIOABoDSABuIEYAMgAKAjgCBgBuIDAABAAR
AdgAAAEo4CIEGQAaADYAcCA7AAQAJwQBAAEAAQAAAAAAAAAEAAAAcBBDAAAADgAGAAEABQALAAAAAABmAAAAEgBGAQUAcRA3AAEA
DAEaAlQAbhA2AAEADANuIEQAMgAKAjgCBwBuEDUAAQAMBSgDRgUFACIBAgBwIAAAUQAiBQ4AcBAoAAUAbiAxABUAcRAIAAUADAIa
A2cAbiA0ADIADANxEBwAAwAMAxIEblAbACNEbhAmAAMAcSAHADUAbhAkAAMAbhAuAAUAbhABAAEADgANAG4QJAADACcADQBuEC4A
BQAnAA0FbhABAAEAKAUNAG4gRwAFACcFDQViAAUAGgECAG4gPAAQACcFGgAAAAUAAQAfAAAABQAIACQAAAARAAoANgAAAAkADAA/
AAAAAwAKAEIAAAADAAgARQAAAAMAAQBKAAAABAAKAE8AAAAEAAgAVAAAAAMADgBZAAAABAABAAUDGV0cXR9dAFMATgBJAFgXAAIA
BwAEAAAAAADWAAAACAAVAAgBFgAiCAoAcBAaAAgAEgIiCRgAYgMEAHAgOQA5ABoDAQBiBAYAbiBFAEMADAoSCwcuAbIWDwAAFgMQ
JzgCBAAS9SgFbjAdADEECgUTEQQAOgU4AG4gIABRAAwCbjAtACALCgI7AgYAEhYCEgYAKAMCEgsAcSBCALIACgI4EgUAFgYAACgF
bhAqAAAACwYFEwMAASQBUgRlOBIFAAIHEQAoAgG3EgMFDBMAdAcjAAEAORIFAG4QKQAAAAICEgAoAgQ8bkAeAIHcCgM7AwMAKLVS
hAMAPQRHADkOEgBuICIAMQAMBHEQBgAEAAwEbhAXAAQAB04oBA0AB0IoUW4gIQAxAAwEUoUCAG4gSQBUAFKFAgBShgMAsGVuIEgA
VABShQMAbkAZAE61CgRShQMAM1QSAHEAOAAAAAsEMQYEDzoGEgBuIDoAqQAWBtwFu2QETygJIgAZABoBNQBwIDsAEAAnAG4wJQAx
C1KDAQDdAwMEOAMOABIiFgMAAG5ALwAwJG4QHwABAAGyKQBY/xYDAAApAFT/DQAH4igCDQA4AgUAbhAYAAIAJwAKAAAADwABACQA
AABUAAQAeAAAAAMABwCAAAAARQAEAAMAzwEAzAEAfQAAAAIAAAAAAAAAAQAAAAEAAAAEAAAAAQApAAAAAAACAAAACgABAAEAAAAg
AAAAAgAAACQAAAADAAAAJAAAAAAAAAADAAAAKQAAAAAAAAABAAAAAAAAAAEAAAAFAAAAAQAAAAcAAAABAAAADwAAAAEAAAAOAAAA
BQAAAAAAAAAAAAEAAAAAAAIAAAAAACgAAgAAAAEAAAABAAAADQAAAAIAAAAOAAsABAAAAA8AEgAMAAAAAQAAABcAAAACAAAAIAAg
AAEAAAAiAAAAAQAAACkAAAABAAAAKgAAAAEAAAAeAAAAAQAAACUABjxpbml0PgATRklORF9QSE9ORV9QTEFZSU5HCgAfRklORF9Q
SE9ORV9SSU5HVE9ORV9VTkFWQUlMQUJMRQABSQADSUlJAAJJSgAFSUpMSUkAAklMAANJTEkABElMSUkAA0lMSgABSgABTAACTEkA
AkxMACBMU2NyY3B5UGhvbmVSaW5nJFJpbmd0b25lU291cmNlOwARTFNjcmNweVBob25lUmluZzsAJ0xhbmRyb2lkL21lZGlhL0F1
ZGlvQXR0cmlidXRlcyRCdWlsZGVyOwAfTGFuZHJvaWQvbWVkaWEvQXVkaW9BdHRyaWJ1dGVzOwAjTGFuZHJvaWQvbWVkaWEvQXVk
aW9Gb3JtYXQkQnVpbGRlcjsAG0xhbmRyb2lkL21lZGlhL0F1ZGlvRm9ybWF0OwAiTGFuZHJvaWQvbWVkaWEvQXVkaW9UcmFjayRC
dWlsZGVyOwAaTGFuZHJvaWQvbWVkaWEvQXVkaW9UcmFjazsAJUxhbmRyb2lkL21lZGlhL01lZGlhQ29kZWMkQnVmZmVySW5mbzsA
GkxhbmRyb2lkL21lZGlhL01lZGlhQ29kZWM7ABtMYW5kcm9pZC9tZWRpYS9NZWRpYUNyeXB0bzsAH0xhbmRyb2lkL21lZGlhL01l
ZGlhRGF0YVNvdXJjZTsAHkxhbmRyb2lkL21lZGlhL01lZGlhRXh0cmFjdG9yOwAbTGFuZHJvaWQvbWVkaWEvTWVkaWFGb3JtYXQ7
ABFMYW5kcm9pZC9uZXQvVXJpOwAYTGFuZHJvaWQvb3MvU3lzdGVtQ2xvY2s7ABZMYW5kcm9pZC92aWV3L1N1cmZhY2U7ACJMZGFs
dmlrL2Fubm90YXRpb24vRW5jbG9zaW5nQ2xhc3M7AB5MZGFsdmlrL2Fubm90YXRpb24vSW5uZXJDbGFzczsAIUxkYWx2aWsvYW5u
b3RhdGlvbi9NZW1iZXJDbGFzc2VzOwAaTGRhbHZpay9hbm5vdGF0aW9uL1Rocm93czsAGExqYXZhL2lvL0ZpbGVEZXNjcmlwdG9y
OwAaTGphdmEvaW8vRmlsZU91dHB1dFN0cmVhbTsAFUxqYXZhL2lvL0lPRXhjZXB0aW9uOwAVTGphdmEvaW8vUHJpbnRTdHJlYW07
ABpMamF2YS9pby9SYW5kb21BY2Nlc3NGaWxlOwAkTGphdmEvbGFuZy9JbGxlZ2FsQXJndW1lbnRFeGNlcHRpb247ABBMamF2YS9s
YW5nL01hdGg7ABJMamF2YS9sYW5nL09iamVjdDsAHUxqYXZhL2xhbmcvU2VjdXJpdHlFeGNlcHRpb247ABJMamF2YS9sYW5nL1N0
cmluZzsAEkxqYXZhL2xhbmcvU3lzdGVtOwAVTGphdmEvbGFuZy9UaHJvd2FibGU7ABFMamF2YS9uaW8vQnVmZmVyOwAVTGphdmEv
bmlvL0J5dGVCdWZmZXI7ABpMamF2YS9uaW8vY2hhcnNldC9DaGFyc2V0OwAjTGphdmEvbmlvL2NoYXJzZXQvU3RhbmRhcmRDaGFy
c2V0czsADlJpbmd0b25lU291cmNlACZUaGUgcmluZ3RvbmUgYXVkaW8gY291bGQgbm90IGJlIHBsYXllZAAjVGhlIHJpbmd0b25l
IGRvZXMgbm90IGNvbnRhaW4gYXVkaW8ACFVTX0FTQ0lJAAFWAAJWSQAGVklJSUpJAANWSVoAAlZKAANWSkkAAlZMAANWTEwABVZM
TExJAAFaAAJaTAACW0IAE1tMamF2YS9sYW5nL1N0cmluZzsAC2FjY2Vzc0ZsYWdzAA1hZGRTdXBwcmVzc2VkAAdhZHZhbmNlAAZh
dWRpby8ABWJ1aWxkAA1jaGFubmVsLWNvdW50AAVjbG9zZQAJY29uZmlndXJlAAtjb250YWluc0tleQATY3JlYXRlRGVjb2RlckJ5
VHlwZQASZGVxdWV1ZUlucHV0QnVmZmVyABNkZXF1ZXVlT3V0cHV0QnVmZmVyAA9lbGFwc2VkUmVhbHRpbWUABmVxdWFscwADZXJy
AARmaWxlAAVmbGFncwAFZmx1c2gACGdldEJ5dGVzAA5nZXRJbnB1dEJ1ZmZlcgAKZ2V0SW50ZWdlcgAPZ2V0T3V0cHV0QnVmZmVy
AA9nZXRPdXRwdXRGb3JtYXQAB2dldFBhdGgADWdldFNhbXBsZVRpbWUACWdldFNjaGVtZQAHZ2V0U2l6ZQAJZ2V0U3RyaW5nAA1n
ZXRUcmFja0NvdW50AA5nZXRUcmFja0Zvcm1hdAAGbGVuZ3RoAAVsaW1pdAAEbWFpbgADbWF4AARtaW1lAARuYW1lAAZvZmZzZXQA
CW9wZW5UcmFjawADb3V0AAVwYXJzZQAMcGNtLWVuY29kaW5nAARwbGF5AAhwb3NpdGlvbgAHcHJpbnRsbgAQcXVldWVJbnB1dEJ1
ZmZlcgABcgAEcmVhZAAGcmVhZEF0AA5yZWFkU2FtcGxlRGF0YQAHcmVsZWFzZQATcmVsZWFzZU91dHB1dEJ1ZmZlcgALc2FtcGxl
LXJhdGUABHNlZWsABnNlZWtUbwALc2VsZWN0QXVkaW8AC3NlbGVjdFRyYWNrABJzZXRBdWRpb0F0dHJpYnV0ZXMADnNldEF1ZGlv
Rm9ybWF0ABNzZXRDaGFubmVsSW5kZXhNYXNrAA5zZXRDaGFubmVsTWFzawAOc2V0Q29udGVudFR5cGUADXNldERhdGFTb3VyY2UA
C3NldEVuY29kaW5nAA1zZXRTYW1wbGVSYXRlAAhzZXRVc2FnZQAEc2l6ZQAFc3RhcnQACnN0YXJ0c1dpdGgABXZhbHVlAAV3cml0
ZQCfAX5+RDh7ImJhY2tlbmQiOiJkZXgiLCJjb21waWxhdGlvbi1tb2RlIjoicmVsZWFzZSIsImhhcy1jaGVja3N1bXMiOmZhbHNl
LCJtaW4tYXBpIjoyMywic2hhLTEiOiJhN2FkMThhNzA0NjBiNzk5ZDA0ODJlNDk3YzEwOWE3NWJmN2Y5MWRlIiwidmVyc2lvbiI6
IjguMTAuOS1kZXYifQACFgGJARwBGBkCEwGJARgDAhQCRQQaaBc0AhUBiQEcARgCAAEBAwASAICABLQRAYGACOARAYGACPgQAYGA
CLAQAAAFAASBgATYFAEJ8BQBCpwSAQq0FwEK9BMBAAAAfhcAAAIAAACHFwAAjhcAAAEAAACXFwAA4BcAAAAAAAAEAAAAAAAAAAAA
AADYFwAAAQAAANgXAAACAAAA2BcAAAMAAADYFwAA7BcAAAAAAAADAAAAAAAAAAUAAADYFwAABwAAANgXAAAIAAAA2BcAAA8AAAAA
AAAAAQAAAAAAAAABAAAAjAAAAHAAAAACAAAAKwAAAKACAAADAAAALQAAAEwDAAAEAAAABwAAAGgFAAAFAAAASgAAAKAFAAAGAAAA
AgAAAPAHAAABIAAACQAAADAIAAABEAAAGgAAAJwNAAACIAAAjAAAAIIOAAAEIAAABAAAAH4XAAAAIAAAAgAAAKAXAAADEAAAAwAA
ANgXAAAGIAAAAgAAAPQXAAAAEAAAAQAAAEwYAAA=
'@ -replace '\s'
    # 音量恢复和临时文件清理留在手机上，ADB 断开后电脑无法代为收尾。
    $remote = @'
volume_range() {
    cmd media_session volume --stream 4 "$@" --get |
        sed -n 's/.*volume is \([0-9][0-9]*\) in range \[\([0-9][0-9]*\)\.\.\([0-9][0-9]*\)\].*/\1 \2 \3/p'
}
set_alarm_volume() {
    # 部分系统只接受 audio 服务的改音量命令，旧版 Android 则只支持 media_session。
    cmd audio set-volume 4 "$1" >/dev/null 2>&1
    range=$(volume_range)
    if [ "${range%% *}" != "$1" ]; then
        range=$(volume_range --set "$1")
    fi
    [ "${range%% *}" = "$1" ]
}
cleanup() {
    # 部分 ROM 的 app_process 会卡在退出阶段，直接结束本次的专用播放器。
    if [ -n "$player_pid" ]; then
        kill -KILL "$player_pid" 2>/dev/null
        wait "$player_pid" 2>/dev/null
    fi
    if [ -n "$restore" ] && ! set_alarm_volume "$restore"; then
        echo FIND_PHONE_RESTORE_FAILED >&2
    fi
    rm -f "$player" "$ringtone_file"
    rmdir "$workdir"
}

umask 077
workdir=$(mktemp -d /data/local/tmp/scrcpy-helper-ring.XXXXXX) || exit 1
player="$workdir/player.dex"
ringtone_file="$workdir/ringtone"
restore=
player_pid=
trap cleanup EXIT
# adb 断开时让播放器先通过 stdin 或心跳停下来，shell 才有机会恢复音量。
trap '' HUP PIPE
trap 'exit 1' INT TERM
# Android 14 起，动态加载的 DEX 必须是只读文件。
{ chmod 400 "$player" && printf '%s' '__PLAYER__' | base64 -d; } > "$player" || exit 1

user=$(am get-current-user)
tone=$(settings --user "$user" get system ringtone)
source=
case "$tone" in
    file:/*|/*)
        source=$tone
        ;;
    content://*)
        # 优先读取当前设置的 URI，权限受限时再用 Android 为来电铃声留的缓存。
        if { content read --user "$user" --uri "$tone" > "$ringtone_file" 2>/dev/null && [ -s "$ringtone_file" ]; } ||
           { content read --user "$user" --uri content://settings/system/ringtone_cache > "$ringtone_file" 2>/dev/null && [ -s "$ringtone_file" ]; }; then
            source=$ringtone_file
        fi
        ;;
esac
if [ -z "$source" ]; then
    echo FIND_PHONE_RINGTONE_UNAVAILABLE >&2
    exit 1
fi

set -- $(volume_range)
if [ "$#" -ne 3 ] || [ "$3" -le 0 ] || [ "$1" -lt "$2" ] || [ "$1" -gt "$3" ]; then
    echo FIND_PHONE_VOLUME_UNAVAILABLE >&2
    exit 1
fi
if [ "$1" != "$3" ]; then
    restore=$1
    if ! set_alarm_volume "$3"; then
        echo FIND_PHONE_VOLUME_UNAVAILABLE >&2
        exit 1
    fi
fi
CLASSPATH="$player" app_process /system/bin ScrcpyPhoneRing "$source" </dev/null &
player_pid=$!
# 等待电脑确认播放器仍在正常回报。电脑退出、断线或卡住时，手机会自己收尾。
while IFS= read -r -t 10 heartbeat && [ "$heartbeat" = "." ]; do
    kill -0 "$player_pid" 2>/dev/null || exit 1
done
'@
    $remote = $remote.Replace("`r`n", "`n").Replace('__PLAYER__', $player)
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $adb
    $psi.Arguments = (@(@('-s', $Serial, 'shell', '-T', $remote) | ForEach-Object { Fm-WinArg $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $proc = [Diagnostics.Process]::Start($psi)
    return @{
        Process = $proc; Phase = 'starting'; Clock = [Diagnostics.Stopwatch]::StartNew()
        Line = $proc.StandardOutput.ReadLineAsync(); Errors = $proc.StandardError.ReadToEndAsync()
        Output = [Collections.Generic.List[string]]::new(); Failed = $false
    }
}

function Stop-PhoneRing {
    param([hashtable]$Ring)
    if (-not $Ring -or $Ring.Phase -eq 'stopping') { return }
    $Ring.Phase = 'stopping'
    $Ring.Clock.Restart()
    try { $Ring.Process.StandardInput.Close() } catch {}
}

function Update-PhoneRing {
    param([hashtable]$Ring)
    $proc = $Ring.Process
    while ($Ring.Line -and $Ring.Line.IsCompleted) {
        if ($Ring.Line.IsFaulted) {
            $Ring.Output.Add($Ring.Line.Exception.GetBaseException().Message)
            $Ring.Line = $null
            break
        }
        $line = $Ring.Line.Result
        $Ring.Line = if ($null -ne $line) { $proc.StandardOutput.ReadLineAsync() }
        if ($line -eq 'FIND_PHONE_PLAYING') {
            if ($Ring.Phase -ne 'stopping' -and -not $proc.HasExited) {
                # 只给正在回报的播放器续期，避免 ADB 卡住时向它的输入管道堆数据。
                try {
                    $proc.StandardInput.Write(".`n")
                    $Ring.Phase = 'playing'
                    $Ring.Clock.Restart()
                } catch {
                    $Ring.Output.Add($_.Exception.Message)
                    $Ring.Failed = $true
                    Stop-PhoneRing $Ring
                }
            }
        } elseif ($line) {
            $Ring.Output.Add($line)
        }
    }
    if ($proc.HasExited -and -not $Ring.Line -and $Ring.Errors.IsCompleted) {
        if (-not $Ring.Errors.IsFaulted -and $Ring.Errors.Result) {
            $Ring.Output.Add($Ring.Errors.Result.Trim())
        }
        $Ring.Detail = $Ring.Output -join "`n"
        $Ring.Failed = $Ring.Failed -or $Ring.Phase -ne 'stopping' -or $proc.ExitCode -ne 0 -or
            $Ring.Detail -match 'FIND_PHONE_RESTORE_FAILED'
        $Ring.Finished = $true
        $proc.Dispose()
    } elseif ($Ring.Clock.ElapsedMilliseconds -gt 12000) {
        $Ring.Failed = $true
        if ($Ring.Phase -eq 'stopping') {
            try { $proc.Kill() } catch {}
            $Ring.Detail = '未收到手机已停止响铃及恢复音量的回报。'
            $Ring.Finished = $true
            $proc.Dispose()
        } else {
            $Ring.Output.Add('等待手机回报响铃状态超时。')
            Stop-PhoneRing $Ring
        }
    }
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
    Wait-UiTask -Owner $Owner -StatusText '正在连接无线设备…' -Functions @('Invoke-ConnectDevices','Test-CommandSuccess','Get-CommandDetail','Get-AdbDeviceState') -Inputs @{
        Adb = $adb; Addresses = $Addresses; Probe = [bool]$Probe
    } -Work {
        Invoke-ConnectDevices -Adb $Inputs.Adb -Addresses $Inputs.Addresses -Probe:$Inputs.Probe -Control $Control
    }
}
function Invoke-UsbWirelessConnection {
    param($Adb, [string]$Serial, $Control)
    $result = [pscustomobject]@{ Address = $null; Error = '' }
    if ($Control.Cancelled) { return $result }
    $route = Invoke-ShortCommand $Adb @('-s',$Serial,'shell','ip','route') -TimeoutMs 3000 -Control $Control
    if (-not (Test-CommandSuccess $route)) {
        $result.Error = Get-CommandDetail $route
        return $result
    }
    # 从选中的 USB 设备取 WLAN 地址，不能用设备列表中新出现的第一台无线设备。
    $ip = $null
    foreach ($line in ($route.Stdout -split "`r?`n")) {
        if ($line -match '\bdev[ \t]+wlan\S*[ \t]+.*\bsrc[ \t]+(\d{1,3}(?:\.\d{1,3}){3})(?=\s|$)' -and
            (Test-TcpAddress ($matches[1] + ':5555'))) {
            $ip = $matches[1]
            break
        }
    }
    if (-not $ip) { $result.Error = '没能读取手机的 Wi-Fi 地址。'; return $result }
    if ($Control.Cancelled) { return $result }

    $portArgs = @('-s',$Serial,'shell','getprop','service.adb.tcp.port')
    $readPort = Invoke-ShortCommand $Adb $portArgs -TimeoutMs 2000 -Control $Control
    $port = 0
    if ($Control.Cancelled) { return $result }
    # 已启用的端口可能并非 5555，重复 tcpip 会重启 adbd，影响已有会话。
    if (-not (Test-CommandSuccess $readPort) -or
        -not [int]::TryParse($readPort.Stdout.Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        $port = 5555
        $restart = Invoke-ShortCommand $Adb @('-s',$Serial,'tcpip',"$port") -TimeoutMs 5000 -Control $Control
        if (-not (Test-CommandSuccess $restart)) {
            $result.Error = Get-CommandDetail $restart
            return $result
        }
        $ready = $false
        $clock = [Diagnostics.Stopwatch]::StartNew()
        # tcpip 返回时 adbd 可能还在重启，等设备确认端口再尝试连接。
        while (-not $Control.Cancelled -and $clock.ElapsedMilliseconds -lt 10000) {
            $left = 10000 - [int]$clock.ElapsedMilliseconds
            $readPort = Invoke-ShortCommand $Adb $portArgs -TimeoutMs ([Math]::Max(1,[Math]::Min(1000,$left))) -Control $Control
            if ((Test-CommandSuccess $readPort) -and $readPort.Stdout.Trim() -eq "$port") {
                $ready = $true
                break
            }
            if (-not $Control.Cancelled) { Start-Sleep -Milliseconds 250 }
        }
        if (-not $ready) { $result.Error = '等待手机启用网络 ADB 超时。'; return $result }
    }

    $address = "${ip}:$port"
    $connection = Invoke-ConnectDevices $Adb @($address) $Control
    $record = $connection.Records | Select-Object -First 1
    if ($record.Success -and -not $connection.Cancelled) { $result.Address = $record.Address }
    else { $result.Error = $record.Error }
    return $result
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
                    $closed = $false
                    if (-not $item.RecBg -and -not $sent) {
                        try { $closed = [bool]$item.Proc.CloseMainWindow() } catch {}
                    }
                    if ($closed) {
                        $sent = $true
                        $item.StopSignalSent = $true
                        $outcome = if (Wait-ScrcpyExit $item.Proc $left $Control) { 'Stopped' } else { 'TimedOut' }
                    } else {
                        $stopped=Stop-ScrcpyGraceful $item.Proc $left $Control -WaitOnly:$sent
                        $sent=$sent -or $stopped.SignalSent
                        $item.StopSignalSent=$sent
                        $errorText=$stopped.Error
                        $outcome=if ($stopped.Exited) { 'Stopped' } else { 'TimedOut' }
                    }
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
    $stopText = if ($Disconnect) { '正在停止投屏并断开无线…' } elseif ($Items.Count -gt 0 -and @($Items | Where-Object { -not $_.Rec }).Count -eq 0) { '正在停止录制…' } else { '正在停止投屏和录制…' }
    try {
        do {
            $result=Wait-UiTask -Owner $Owner -StatusText $stopText -Kind $(if ($ForExit) { 'shutdown' } else { 'operation' }) -Functions @(
                'Invoke-StopItems','Stop-ScrcpyGraceful','Get-ParentProcessId','Test-ProcessDescendant','Wait-ScrcpyExit','Test-ProcessExited','Test-CommandSuccess','Get-CommandDetail'
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
                if (-not $result.Success) {
                    $heading = if ($Disconnect) { '无线连接未能断开' } else { '未能确认停止结果' }
                    $body = if ($result.Error) { '可点「查看原因」查看错误详情。' } else { '请在「设备管理」重新查看设备状态。' }
                    [void](Show-ResultDialog $Owner '停止投屏' $heading $body $result.Error @('ok'))
                }
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

function Invoke-ExitDisconnect {
    param($Adb, [string[]]$Addresses, $Control, [int]$BudgetMs=15000)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $failed = @()
    $attempted = 0
    foreach ($addr in $Addresses) {
        $left = $BudgetMs - [int]$clock.ElapsedMilliseconds
        if ($Control.Cancelled -or $left -le 0) { break }
        $command = Invoke-ShortCommand $Adb @('disconnect',$addr) -TimeoutMs ([Math]::Min(3000,$left)) -Control $Control
        if ($command.Cancelled) { break }
        $attempted++
        if ((Test-CommandSuccess $command) -and -not $command.Error) { continue }
        $detail = Get-CommandDetail $command
        # 已记住的设备可以早已离线。ADB 明确找不到这条连接时，断开目标已经达成。
        $reportedAddress = [regex]::Escape($addr)
        if (Test-MdnsSerial $addr) { $reportedAddress += '(?::5555)?' }
        if ($command.Started -and -not $command.TimedOut -and
            $detail -match ("(?m)^error: no such device '" + $reportedAddress + "'\s*$")) { continue }
        if (-not $detail) { $detail = 'ADB 未返回有效的断开结果。' }
        $failed += [pscustomobject]@{ Address=$addr; Error=$detail }
    }
    $unprocessed = @($Addresses | Select-Object -Skip $attempted)
    [pscustomobject]@{
        Success=($failed.Count -eq 0 -and $unprocessed.Count -eq 0 -and -not $Control.Cancelled)
        Failed=$failed; Unprocessed=$unprocessed; Cancelled=[bool]$Control.Cancelled
    }
}

$script:closeState=@{ InProgress=$false; DisconnectAddresses=@() }
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
        $addresses=@(@($script:knownDevices.Keys) + @($scrcpyProcs | ForEach-Object { $_.Serial }) + @($script:closeState.DisconnectAddresses) |
            Where-Object { Test-Wireless $_ } | Select-Object -Unique)
        Stop-DeviceScans
        $quiesced=$true
        # 旧查询已取消；只允许 shutdown 任务运行，用户取消退出后可重新发起普通查询。
        $script:deviceScanState.Closing=$false
        $script:deviceScanState.Paused=$false
        # 停止投屏会清掉进程表；用户取消退出后仍要能重试这些地址。
        if ($settings.disconnectOnClose) { $script:closeState.DisconnectAddresses = $addresses }
        $stopped=Stop-AllScrcpy $Owner
        if (-not $stopped.Success) { return }
        if ($settings.disconnectOnClose -and $addresses.Count) {
            $disconnected=Wait-UiTask -Owner $Owner -StatusText '正在断开无线设备…' -Kind 'shutdown' -Functions @(
                'Invoke-ExitDisconnect','Test-CommandSuccess','Get-CommandDetail'
            ) -Inputs @{ Adb=$adb; Addresses=$addresses } -Work {
                Invoke-ExitDisconnect $Inputs.Adb $Inputs.Addresses $Control
            }
            if ($disconnected.Cancelled) { return }
            if (-not $disconnected.Success) {
                if ($disconnected.Failed.Count -or $disconnected.Unprocessed.Count) {
                    $failed = @($disconnected.Failed | ForEach-Object { "$($_.Address) · $($_.Error)" })
                    $unprocessed = @($disconnected.Unprocessed)
                    $script:closeState.DisconnectAddresses = @($disconnected.Failed | ForEach-Object { $_.Address }) + $unprocessed
                    $summary = "断开失败 $($failed.Count) 台，尚未处理 $($unprocessed.Count) 台。"
                    $detail = (@(if ($failed.Count) { '断开失败'; $failed }
                                 if ($unprocessed.Count) { '尚未处理'; $unprocessed }) -join "`r`n")
                } else {
                    # 后台任务未返回报告时，不能推断哪些地址已处理。
                    $summary = '无法确认无线设备的断开结果。'
                    $detail = (@('未确认结果') + $addresses + @($disconnected.Error)) -join "`r`n"
                }
                $choice = Show-ResultDialog $Owner '关闭助手' '无线连接未全部断开' "$summary 可以选择「仍然退出」或「取消」。" $detail @('exit','cancel') -ExpandDetail -CancelByDefault
                if ($choice -ne 'exit') { return }
            }
            $script:closeState.DisconnectAddresses = @()
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
            }
            if ($OnResume -and -not $Owner.IsDisposed) { & $OnResume }
        }
    }
}

# 「独立窗口」可一键打开的最常用 App（按使用度排，购物类靠后）；其余 App 用「更多应用」从手机列表里挑
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
    ndSize = ''; ndDpi = ''; ndNoDecor = $false; ndMode = 'portrait'; ndFixed = $true; ndAudio = 'auto'
    # 录制
    recFormat = 'mp4'; recTimeLimit = 0; recBackground = $false; recDir = ''; lastRecDir = ''
    # 通用
    liveStatus = $true; autoConnect = $true; disconnectOnClose = $false; extraArgs = ''; lastWirelessAddr = ''; defaultDevice = ''; lastDownloadDir = ''
    # 自定义 adb / scrcpy 可执行文件路径（留空=用本助手同目录自带的）；在「设置 > 通用」里改，随设置存进 JSON
    scrcpyPath = ''; adbPath = ''
    # 记住主窗口位置（-1 = 还没记，居中显示）
    winX = -1; winY = -1
    # 控制台
    showConsole = $false
}
$settings = [ordered]@{}
foreach ($k in $defaults.Keys) { $settings[$k] = $defaults[$k] }
$script:preserveUnreadableSettings = $false

function Test-SettingsZoom {
    param([string]$Value)
    $zoom = 0.0
    return ([double]::TryParse($Value, [Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$zoom) -and
        $zoom -gt 0 -and $zoom -lt [double][decimal]::MaxValue)
}
function Convert-SettingsValue {
    param([string]$Name, $Value, $Default)
    if ($Default -is [bool]) {
        if ($Value -is [bool]) { return $Value }
        $flag = $false
        # PowerShell 把非空字符串 "false" 转成布尔值时会得到 true。
        if ($Value -is [string] -and [bool]::TryParse($Value, [ref]$flag)) { return $flag }
        return $Default
    }
    if ($Default -is [int]) {
        $number = 0
        if (($Value -is [int] -or $Value -is [long] -or $Value -is [string]) -and
            [int]::TryParse([string]$Value, [ref]$number) -and ($number -ge 0 -or $Name -in @('winX','winY'))) {
            return $number
        }
        return $Default
    }
    # 早期版本把摄像头最大边长档位保存成 JSON 数字。
    if ($Name -eq 'camResMax' -and ($Value -is [int] -or $Value -is [long])) { $Value = [string]$Value }
    # 旧版 pwsh 没有 DateKind，沿用原先的字符串转换，避免丢掉被解析器自动转成日期的文本。
    if ($Value -is [datetime]) { $Value = [string]$Value }
    if ($Value -isnot [string]) { return $Default }
    switch ($Name) {
        'camResMax' { if ($Value -notmatch '^(?:[0-9]+|[0-9]+x[0-9]+)$') { return $Default } }
        'camZoom' { if (-not (Test-SettingsZoom $Value)) { return $Default } }
        'ndSize' { if ($Value -and $Value -notmatch '^[0-9]+x[0-9]+$') { return $Default } }
        'ndDpi' {
            $dpi = 0
            if ($Value -and (-not [int]::TryParse($Value, [ref]$dpi) -or $dpi -le 0)) { return $Default }
        }
        'crop' { if ($Value -and $Value -notmatch '^[0-9]+:[0-9]+:[0-9]+:[0-9]+$') { return $Default } }
        'recFormat' { if ($Value -cnotin @('mp4','mkv')) { return $Default } }
        'ndAudio' { if ($Value -cnotin @('auto','on','off')) { return $Default } }
    }
    return $Value
}
function Load-Settings {
    if (-not (Test-Path -LiteralPath $cfgPath)) { return }
    try {
        $raw = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 -ErrorAction Stop
        # ConvertFrom-Json 会展开单元素数组，先确认文件本身的根节点是对象。
        if (-not $raw -or -not $raw.TrimStart().StartsWith('{')) { throw '无效的设置文件' }
        $jsonArgs = @{ InputObject=$raw; ErrorAction='Stop' }
        # 设备备注可能恰好长得像日期，支持该选项的 PowerShell 要按字符串保留。
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonArgs.DateKind = 'String' }
        $j = ConvertFrom-Json @jsonArgs
        $script:preserveUnreadableSettings = $false
    } catch {
        $script:preserveUnreadableSettings = $true
        return
    }

    foreach ($key in $defaults.Keys) {
        $settings[$key] = Convert-SettingsValue $key $j.PSObject.Properties[$key].Value $defaults[$key]
    }
    # 各表独立恢复，坏条目不能挡住同一张表里后面的有效记忆。
    $maps = @{
        customApps=$script:customApps; knownDevices=$script:knownDevices
        deviceNames=$script:deviceNames; camResByDevice=$script:camResByDevice
    }
    foreach ($key in $maps.Keys) {
        $map = $j.PSObject.Properties[$key].Value
        if ($map -isnot [pscustomobject]) { continue }
        foreach ($entry in $map.PSObject.Properties) {
            $settingName = if ($key -eq 'camResByDevice') {
                if ($entry.Name -like '*|zoom') { 'camZoom' } else { 'camResMax' }
            }
            $value = Convert-SettingsValue $settingName $entry.Value $null
            if ($entry.Name -and $value) { $maps[$key][$entry.Name] = $value }
        }
    }
    foreach ($pkg in @($j.PSObject.Properties['hiddenBuiltInApps'].Value)) {
        if ($pkg -is [string] -and -not [string]::IsNullOrWhiteSpace($pkg)) { $script:hiddenBuiltInApps[$pkg] = $true }
    }
    foreach ($id in @($j.PSObject.Properties['appFavoriteOrder'].Value)) {
        if ($id -is [string] -and $id -match '^(?:builtin|custom):.+$' -and $script:appFavoriteOrder -notcontains $id) {
            $script:appFavoriteOrder.Add($id)
        }
    }
    foreach ($address in @($j.PSObject.Properties['autoConnectExclude'].Value)) {
        if ($address -is [string] -and $address) { [void]$script:autoConnectExclude.Add($address) }
    }
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
        $o['customApps'] = $script:customApps
        $o['hiddenBuiltInApps'] = @($script:hiddenBuiltInApps.psbase.Keys | Sort-Object)
        $o['appFavoriteOrder'] = @($script:appFavoriteOrder)
        $o['knownDevices'] = $script:knownDevices
        $o['deviceNames'] = $script:deviceNames
        $o['autoConnectExclude'] = @($script:autoConnectExclude)
        $o['camResByDevice'] = $script:camResByDevice
        # 原子写：先写临时文件再替换，避免写到一半中断把设置文件截断。
        $tmp = "$cfgPath.tmp"
        (Format-Json ($o | ConvertTo-Json -Depth 5)) | Set-Content -LiteralPath $tmp -Encoding UTF8
        if (Test-Path -LiteralPath $cfgPath) {
            $backupPath = [NullString]::Value
            # 整份文件没能读取时，首次保存需要留下原件，防止自动保存抹掉可手动恢复的数据。
            if ($script:preserveUnreadableSettings) { $backupPath = "$cfgPath.unreadable-$([guid]::NewGuid().ToString('N')).bak" }
            [System.IO.File]::Replace($tmp, $cfgPath, $backupPath)
        } else { Move-Item -LiteralPath $tmp -Destination $cfgPath -Force }
        $script:preserveUnreadableSettings = $false
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
function Get-HwDecArgs {
    if ($settings.hwDec) { return @("--hwdec=$($settings.hwDec)") }
    return @()
}
function Get-DisplayCompatibilityArgs {
    $a = @(Get-HwDecArgs)
    # 普通投屏与独立窗口都可能遇到机型上报的编码器分辨率限制不准。
    if ($settings.ignoreEncoderConstraints) { $a += '--ignore-video-encoder-constraints' }
    return @($a)
}
function Get-VideoArgs {
    $a = @()
    if ([int]$settings.maxSize -gt 0) { $a += @('-m', "$($settings.maxSize)") }
    if ([int]$settings.maxFps  -gt 0) { $a += "--max-fps=$($settings.maxFps)" }
    if ([int]$settings.bitRate -gt 0) { $a += "--video-bit-rate=$($settings.bitRate)M" }
    if ($settings.videoCodec)         { $a += "--video-codec=$($settings.videoCodec)" }
    if ($settings.crop)               { $a += "--crop=$($settings.crop)" }
    $a += @(Get-DisplayCompatibilityArgs)
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
function Get-RecordingArgs {
    param([string]$Serial, [string]$Path, [bool]$Wireless)
    $a = @('-s', $Serial, '-r', $Path) + @(Get-VideoArgs) + @(Get-AudioArgs)
    # 保持唤醒要分连接方式：无线用 --keep-active（-w/--stay-awake 只在 USB 插电时生效，无线录制会中途息屏断流）
    if ($settings.noControl) { $a += '--no-control' }
    else {
        if ($settings.stayAwake) { $a += $(if ($Wireless) { '--keep-active' } else { '-w' }) }
        if ($settings.screenOff) { $a += '--turn-screen-off' }
    }
    if ([int]$settings.recTimeLimit -gt 0) { $a += "--time-limit=$($settings.recTimeLimit)" }
    if ($settings.recBackground) { $a += @('--no-window', '--no-playback') }
    else { $a += @(Get-WindowArgs) }
    return @($a)
}
function Resolve-RecordingPath {
    param([string]$Ext, [string]$Timestamp = (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $dir = if ($settings.recDir) { ([string]$settings.recDir).Trim() } else { '' }
    if (-not $dir) { return [pscustomobject]@{ Mode = 'prompt'; Path = ''; Dir = '' } }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return [pscustomobject]@{ Mode = 'missing'; Path = ''; Dir = $dir } }
    $base = "录屏-$Timestamp"
    $candidate = Join-Path $dir "$base.$Ext"
    $idx = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $dir "$base-$idx.$Ext"
        $idx++
    }
    return [pscustomobject]@{ Mode = 'fixed'; Path = $candidate; Dir = $dir }
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
    # 固定分辨率时不加 --flex-display，避免调整电脑窗口大小时安卓应用重新排版。
    if (-not $fixed) { $a += '--flex-display' }
    if ($noDecor) { $a += '--no-vd-system-decorations' }
    return $a
}
# 按摄像头画面比例限制初始窗口大小（--window-width/height），避免竖屏预览超出工作区。
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
        $command=Invoke-UiCommand $Owner $exe $argv -StatusText '正在读取手机摄像头信息…'
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
        $outputs=Wait-UiTask -Owner $form -StatusText '正在读取手机屏幕尺寸…' -Inputs @{ Adb=$adb; Size=$szArgs; Density=$dnArgs } -Work {
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

# 高级参数是 Windows 命令行文本。先还原每个参数，之后才能识别标题、录屏等选项。
function Split-WindowsArguments {
    param([string]$CommandLine)
    $arguments = [Collections.Generic.List[string]]::new()
    $word = [Text.StringBuilder]::new()
    $quoted = $false
    $started = $false
    $slashes = 0
    for ($i = 0; $i -lt $CommandLine.Length; $i++) {
        $ch = $CommandLine[$i]
        if ($ch -eq [char]92) { $slashes++; $started=$true; continue }
        if ($ch -eq '"') {
            $started = $true
            # 只有紧贴双引号的反斜杠才参与转义；引号内的连续两个双引号表示字面引号。
            [void]$word.Append([char]92, [int][Math]::Floor($slashes / 2))
            if ($slashes % 2) {
                [void]$word.Append($ch)
            } elseif ($quoted -and $i + 1 -lt $CommandLine.Length -and $CommandLine[$i + 1] -eq '"') {
                [void]$word.Append($ch)
                $i++
            } else {
                $quoted = -not $quoted
            }
            $slashes = 0
            continue
        }
        if ($slashes) { [void]$word.Append([char]92, $slashes); $slashes=0 }
        if (-not $quoted -and [char]::IsWhiteSpace($ch)) {
            if ($started) {
                $arguments.Add($word.ToString())
                [void]$word.Clear()
                $started = $false
            }
            continue
        }
        $started = $true
        [void]$word.Append($ch)
    }
    if ($started) {
        if ($slashes) { [void]$word.Append([char]92, $slashes) }
        $arguments.Add($word.ToString())
    }
    return @($arguments.ToArray())
}

# 启动器生成的空占位参数应过滤，用户显式输入的 "" 则需要原样传下去。
function Start-Scrcpy {
    param(
        [string[]]$Options,
        [switch]$Recording,
        [switch]$PassThru,
        [string]$StderrFile,
        [string]$StdoutFile,
        # 本窗口声音：Auto=同设备已有出声窗口时自动静音（默认）；On=强制出声；Off=强制静音
        [ValidateSet('Auto', 'On', 'Off')][string]$AudioMode = 'Auto',
        [string]$ReconnectCameraZoom
    )
    $clean = @($Options | Where-Object { $_ -ne '' -and $null -ne $_ }) + @(Split-WindowsArguments $settings.extraArgs)
    if ($ReconnectCameraZoom) {
        # scrcpy 以最后一个 --camera-zoom 为准，恢复值放在面板和自定义参数之后才会生效。
        $clean += "--camera-zoom=$ReconnectCameraZoom"
    }
    $Recording=[switch]($Recording -or @($clean | Where-Object { $_ -eq '-r' -or $_ -eq '--record' -or $_ -like '--record=*' }).Count -gt 0)
    $isCamera = @($clean | Where-Object { $_ -like '--video-source=camera*' }).Count -gt 0
    # 解析目标设备序列号（来自 -s），用于「投屏中」标记 / 「停止这台」，并据此给窗口起友好标题
    $serial = ''
    $winTitle = $null
    for ($i = 0; $i -lt $clean.Count; $i++) {
        $arg = $clean[$i]
        if ($arg -ceq '-s' -and $i + 1 -lt $clean.Count) {
            if (-not $serial) { $serial = $clean[$i + 1] }
            $i++
        } elseif ($arg.StartsWith('--window-title=', [StringComparison]::Ordinal)) {
            $winTitle = $arg.Substring('--window-title='.Length)
        } elseif ($arg -ceq '--window-title' -and $i + 1 -lt $clean.Count) {
            $i++
            $winTitle = $clean[$i]
        }
    }
    # 后面的自定义标题会覆盖默认标题，检测窗口时要用 scrcpy 最终收到的值。
    if ($null -eq $winTitle -and $serial) {
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
    $cmd = (@($clean | ForEach-Object { if ($_ -eq '' -or $_ -match '[\s"]') { Fm-WinArg $_ } else { $_ } }) -join ' ')
    # StderrFile：摄像头看门狗要靠 stderr 里的报错分类「被抢 / 带不动 / 不明原因」，只对摄像头会话把 stderr 落到文件。
    # scrcpy 是控制台程序：一旦 -RedirectStandardError（=UseShellExecute 关）就会继承本助手的控制台，退出时触发它
    # Windows 版自带的「Press Enter to continue…」暂停——进程卡着不退、还冒出黑窗，看门狗误判成异常又反复重开。
    # 两道一起下才干净：① -RedirectStandardInput 指到一个空文件 → scrcpy 那次 getchar 立刻读到 EOF，不等回车；
    # ② -WindowStyle Hidden → 不弹控制台窗。stderr 落文件由 OS 直接写（不占管道缓冲，避免 scrcpy 刷不动 stderr 卡死）。
    # 让 Start-Process 的错误进入结果弹窗，保留 Windows 返回的原因（如找不到程序或取消了系统提示）。
    $p = $null
    try {
        $winStyle = if ($settings.showConsole) { 'Normal' } else { 'Hidden' }
        # StdoutFile 只有摄像头会话传：scrcpy 的 INFO 级日志（含每次变焦的 "Set camera zoom: 3.16"）走的是 stdout，
        # ERROR/WARN 才走 stderr——两路分开落两个文件，看门狗读 stderr 判病因，倍率回传读 stdout。
        $launch = @{ FilePath=$exe; WorkingDirectory=$PSScriptRoot; PassThru=$true; WindowStyle=$winStyle; ErrorAction='Stop' }
        if ($cmd) { $launch.ArgumentList = $cmd }
        if ($cmd -and $StderrFile) {
            $launch.RedirectStandardError = $StderrFile
            $launch.RedirectStandardInput = Get-NulStdin
            if ($StdoutFile) { $launch.RedirectStandardOutput = $StdoutFile }
        }
        $p = Start-Process @launch
        if ($p -and $StderrFile -and $StdoutFile) {
            # Windows PowerShell 5.1 的重定向启动可能不保留进程句柄，进程退出后看门狗就读不到退出码。
            try { $null = $p.Handle } catch {}
        }
    } catch {
        $detail = $_.Exception.Message
        # 摄像头看门狗也走这个入口，启动失败时不能用对话框阻塞自动重连回调。
        if ($StderrFile -and $StdoutFile) {
            $logged = Add-ErrorLog '摄像头启动失败' $detail
            $hint = if ($logged) { '无法启动摄像头，请查看「投屏助手-错误日志.txt」。' }
                else { '无法启动摄像头，请核对 scrcpy 路径。' }
            if ($script:showTempHint) { & $script:showTempHint $hint $cRed 12000 }
        } else {
            [void](Show-ResultDialog $form '投屏' '无法启动投屏' '先点「查看原因」看详情。如果提示找不到程序，请检查压缩包是否已完整解压。' $detail @('ok'))
        }
        return
    }
    # Audio=本会话是否在电脑上出声（被自动静音的新会话记 false，供后续同设备会话判定「是否已有出声窗口」）
    if (-not $p) { return }
    $entry=[pscustomobject]@{ Proc=$p; Rec=[bool]$Recording; RecBg=[bool]($Recording -and (@($clean | Where-Object { $_ -eq '--no-window' }).Count -gt 0)); Serial=$serial; Audio=[bool]$playsAudio; Starting=$true; StopInProgress=$false; StopSignalSent=$false; Forced=$false; ExitReported=$false }
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
        [void](Show-ResultDialog $form '投屏' '投屏窗口没能打开' '投屏在窗口打开前就结束了。到「设置 > 常用」勾选「显示投屏日志窗口」，保存后再投一次，就能看到报错。' ("命令：scrcpy.exe $cmd`r`n退出码：$code") @('ok'))
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
    param([string[]]$argv, [string]$errFile, [string]$outFile, [string]$ReconnectCameraZoom)
    $camMode=if ($argv -contains '--no-audio') { 'Off' } else { 'On' }
    return (Start-Scrcpy $argv -StderrFile $errFile -StdoutFile $outFile -AudioMode $camMode -ReconnectCameraZoom $ReconnectCameraZoom -PassThru)
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
    # 重启会清空输出日志；单独保留上次有效值，供尚未写出新倍率就再次断流时使用。
    $zoom=Read-CamZoom $Session.OutFile
    if ($null -ne $zoom) { $Session.LastZoom=$zoom }
    $previous=$Session.Proc
    $Session.Proc=$null
    Release-ExitedProcess $previous
    $Session.Proc=Start-CamProc $Session.Args $Session.ErrFile $Session.OutFile -ReconnectCameraZoom $Session.LastZoom
    $Session.StartedAt=Get-Date
    if ($Session.Proc) { & $script:showTempHint '摄像头已自动重连。关闭摄像头窗口可停止。' $cGreen }
}

# 从 scrcpy 的 stdout 日志里取「最后一次生效的倍率」：投屏中每按一下 MOD+↑/↓ 都会打一行 "Set camera zoom: 3.1640973"。
# 原样保留有效数字，避免重连时随面板步进舍入倍率。
function Read-CamZoom {
    param([string]$file)
    if (-not $file) { return $null }
    try { $txt = [System.IO.File]::ReadAllText($file) } catch { return $null }
    $entries = [regex]::Matches($txt, '(?m)Set camera zoom:[ \t]*(\S+)[ \t]*\r?$')
    for ($i = $entries.Count - 1; $i -ge 0; $i--) {
        $zoom = $entries[$i].Groups[1].Value
        if (Test-SettingsZoom $zoom) { return $zoom }
    }
    return $null
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
            Set-CamZoom $cs.Serial $cs.Facing (Format-Zoom ([Math]::Round([double]$zoom,1)))
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
function Get-ParentProcessId {
    param([uint32]$ProcessId)
    if ($ProcessId -eq 0) { return [uint32]0 }
    $h = [IntPtr]::Zero
    try {
        # PROCESS_QUERY_LIMITED_INFORMATION (0x1000) 足够读取 BasicInformation 中的 InheritedFromUniqueProcessId
        $h = [Native.ConIO]::OpenProcess(0x1000, $false, $ProcessId)
        if ($h -eq [IntPtr]::Zero) { return [uint32]0 }
        $buf = New-Object System.IntPtr[] 6
        $ret = 0
        if ([Native.ConIO]::NtQueryInformationProcess($h, 0, $buf, 6 * [IntPtr]::Size, [ref]$ret) -ne 0) { return [uint32]0 }
        return [uint32]$buf[5].ToInt64()
    } catch { return [uint32]0 }
    finally {
        if ($h -ne [IntPtr]::Zero) { try { [void][Native.ConIO]::CloseHandle($h) } catch {} }
    }
}
function Test-ProcessDescendant {
    param([uint32]$ProcessId, [uint32]$AncestorId, $AncestorStart = $null)
    if ($ProcessId -eq 0 -or $AncestorId -eq 0 -or $ProcessId -eq $AncestorId) { return $false }
    $cur = $ProcessId
    $seen = @{}
    for ($hop = 0; $hop -lt 16; $hop++) {
        if ($seen.ContainsKey($cur)) { return $false }
        $seen[$cur] = $true
        $parent = Get-ParentProcessId $cur
        if ($parent -eq 0) { return $false }
        if ($parent -eq $AncestorId) {
            if ($null -ne $AncestorStart) {
                $p = $null
                try {
                    $p = [System.Diagnostics.Process]::GetProcessById([int]$cur)
                    return ($p.StartTime -ge $AncestorStart)
                } catch { return $false }
                finally { if ($p) { $p.Dispose() } }
            }
            return $true
        }
        $cur = $parent
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
                $ancestorStart = $null; try { $ancestorStart = $proc.StartTime } catch {}
                # Ctrl+C 会广播到整个控制台；scrcpy 自身派生的子进程（如 adb.exe）会继承它的私有控制台，
                # 不应误判成共享控制台；若存在非目标子孙的其它进程，则保留进程交由用户决定是否强制结束。
                $foreign=@($ids | Select-Object -First ([Math]::Min(64,[int]$count)) | Where-Object {
                    $_ -ne $PID -and $_ -ne $proc.Id -and -not (Test-ProcessDescendant ([uint32]$_) ([uint32]$proc.Id) $ancestorStart)
                })
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
# 读取单个地址的 adb 状态：device / offline / unauthorized。查询本身失败返回 $null，地址不在列表返回空串。
function Get-AdbDeviceState {
    param($addr, [string]$DeviceText, [switch]$FromText)
    if (-not $addr) { return $null }
    if (-not $FromText) {
        $command=Invoke-UiCommand $form $adb @('devices') -TimeoutMs 3000 -StatusText '正在读取设备列表…'
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
        $props=Wait-UiTask -Owner $form -StatusText '正在读取手机型号和版本…' -Inputs @{ Adb=$adb; Serial=$serial } -Work {
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

$script:dpiScale = 1.0

# 通过反射打开双缓冲，避免自绘圆角卡片/按钮闪烁，同时绕开受限环境下的 Add-Type 编译。
function Enable-DoubleBuffer {
    param($ctrl)
    try {
        $prop = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
        if ($prop) { $prop.SetValue($ctrl, $true, $null) }
    } catch {}
}

# Win11 窗口标题栏与宣纸底色同色（DWMWA_CAPTION_COLOR = 35）；Win10 或受限环境静默跳过。
function Set-TitleBarColor {
    param($form, $color)
    try {
        if (-not ('Native.DwmEmit' -as [type])) {
            $_asm = [AppDomain]::CurrentDomain.DefineDynamicAssembly(
                (New-Object Reflection.AssemblyName('scrcpyHelperDwm')), [Reflection.Emit.AssemblyBuilderAccess]::Run)
            $_mod = $_asm.DefineDynamicModule('scrcpyHelperDwm')
            $_tb = $_mod.DefineType('Native.DwmEmit', [Reflection.TypeAttributes]'Public, Class, Sealed, Abstract')
            [void]$_tb.DefinePInvokeMethod(
                'DwmSetWindowAttribute', 'dwmapi.dll',
                [Reflection.MethodAttributes]'Public, Static, PinvokeImpl', [Reflection.CallingConventions]::Standard,
                [int], @([IntPtr], [int], [int].MakeByRefType(), [int]),
                [Runtime.InteropServices.CallingConvention]::Winapi, [Runtime.InteropServices.CharSet]::Auto)
            [void]$_tb.CreateType()
        }
        $colorRef = ([int]$color.B -shl 16) -bor ([int]$color.G -shl 8) -bor [int]$color.R
        $form | Add-Member -NotePropertyName TitleBarColorRef -NotePropertyValue $colorRef -Force
        $form.Add_HandleCreated({
            param($f)
            try {
                if ($f.IsHandleCreated) {
                    $v = [int]$f.TitleBarColorRef
                    [void][Native.DwmEmit]::DwmSetWindowAttribute($f.Handle, 35, [ref]$v, 4)
                }
            } catch {}
        })
        if ($form.IsHandleCreated) {
            $v = [int]$form.TitleBarColorRef
            [void][Native.DwmEmit]::DwmSetWindowAttribute($form.Handle, 35, [ref]$v, 4)
        }
    } catch {}
}

function New-RoundedPath {
    param([float]$x, [float]$y, [float]$w, [float]$h, [float]$r)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($w -le 0 -or $h -le 0) { return $p }
    $maxR = [Math]::Min($w, $h) / 2.0
    if ($r -gt $maxR) { $r = $maxR }
    $d = [float]($r * 2.0)
    if ($d -lt 1.0) {
        $p.AddRectangle([System.Drawing.RectangleF]::new($x, $y, $w, $h))
        return $p
    }
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseAllFigures()
    return $p
}

function Draw-Glyph {
    param($g, [string]$name, [System.Drawing.RectangleF]$rect, $color, [float]$strokeWidth = 1.5)
    $oldSmooth = $g.SmoothingMode
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $pen = New-Object System.Drawing.Pen($color, $strokeWidth)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $brush = New-Object System.Drawing.SolidBrush($color)
    $x = $rect.X; $y = $rect.Y; $w = $rect.Width; $h = $rect.Height
    try {
        switch ($name) {
            'play' {
                $p = New-RoundedPath ($x + $w * 0.22) ($y + $h * 0.12) ($w * 0.56) ($h * 0.76) ($w * 0.1)
                $g.DrawPath($pen, $p); $p.Dispose()
                $tri = [System.Drawing.PointF[]]@(
                    [System.Drawing.PointF]::new($x + $w * 0.43, $y + $h * 0.36),
                    [System.Drawing.PointF]::new($x + $w * 0.64, $y + $h * 0.50),
                    [System.Drawing.PointF]::new($x + $w * 0.43, $y + $h * 0.64)
                )
                $g.FillPolygon($brush, $tri)
            }
            'wifi' {
                $cx = $x + $w * 0.5; $cy = $y + $h * 0.78
                $r1 = $w * 0.44; $g.DrawArc($pen, $cx - $r1, $cy - $r1, $r1 * 2, $r1 * 2, 225, 90)
                $r2 = $w * 0.28; $g.DrawArc($pen, $cx - $r2, $cy - $r2, $r2 * 2, $r2 * 2, 225, 90)
                $dot = [Math]::Max(2.0, $w * 0.11)
                $g.FillEllipse($brush, $cx - $dot / 2, $cy - $dot / 2, $dot, $dot)
            }
            'folder' {
                $fp = New-Object System.Drawing.Drawing2D.GraphicsPath
                $x0 = $x + $w * 0.12; $y0 = $y + $h * 0.22; $fw = $w * 0.76; $fh = $h * 0.56
                $fp.AddLines([System.Drawing.PointF[]]@(
                    [System.Drawing.PointF]::new($x0, $y0 + $fh * 0.12),
                    [System.Drawing.PointF]::new($x0 + $fw * 0.34, $y0 + $fh * 0.12),
                    [System.Drawing.PointF]::new($x0 + $fw * 0.46, $y0 + $fh * 0.28),
                    [System.Drawing.PointF]::new($x0 + $fw, $y0 + $fh * 0.28),
                    [System.Drawing.PointF]::new($x0 + $fw, $y0 + $fh),
                    [System.Drawing.PointF]::new($x0, $y0 + $fh)
                ))
                $fp.CloseFigure()
                $g.DrawPath($pen, $fp); $fp.Dispose()
            }
            'camera' {
                $bp = New-RoundedPath ($x + $w * 0.12) ($y + $h * 0.28) ($w * 0.76) ($h * 0.54) ($w * 0.1)
                $g.DrawPath($pen, $bp); $bp.Dispose()
                $g.DrawLine($pen, [float]($x + $w * 0.35), [float]($y + $h * 0.28), [float]($x + $w * 0.42), [float]($y + $h * 0.18))
                $g.DrawLine($pen, [float]($x + $w * 0.42), [float]($y + $h * 0.18), [float]($x + $w * 0.58), [float]($y + $h * 0.18))
                $g.DrawLine($pen, [float]($x + $w * 0.58), [float]($y + $h * 0.18), [float]($x + $w * 0.65), [float]($y + $h * 0.28))
                $lr = $w * 0.14
                $g.DrawEllipse($pen, $x + $w * 0.5 - $lr, $y + $h * 0.55 - $lr, $lr * 2, $lr * 2)
            }
            'record' {
                $or = $w * 0.36
                $g.DrawEllipse($pen, $x + $w * 0.5 - $or, $y + $h * 0.5 - $or, $or * 2, $or * 2)
                $rb = New-Object System.Drawing.SolidBrush($cRed)
                $ir = $w * 0.16
                $g.FillEllipse($rb, $x + $w * 0.5 - $ir, $y + $h * 0.5 - $ir, $ir * 2, $ir * 2)
                $rb.Dispose()
            }
            'stop' {
                $or = $w * 0.36
                $g.DrawEllipse($pen, $x + $w * 0.5 - $or, $y + $h * 0.5 - $or, $or * 2, $or * 2)
                $sq = $w * 0.28
                $sp = New-RoundedPath ($x + $w * 0.5 - $sq * 0.5) ($y + $h * 0.5 - $sq * 0.5) $sq $sq ([float]([Math]::Max(1.5, $w * 0.06)))
                $sb = New-Object System.Drawing.SolidBrush($cRed)
                $g.FillPath($sb, $sp); $sb.Dispose(); $sp.Dispose()
            }
            'window' {
                $wp = New-RoundedPath ($x + $w * 0.15) ($y + $h * 0.18) ($w * 0.70) ($h * 0.64) ($w * 0.1)
                $g.DrawPath($pen, $wp); $wp.Dispose()
                $g.DrawLine($pen, [float]($x + $w * 0.15), [float]($y + $h * 0.38), [float]($x + $w * 0.85), [float]($y + $h * 0.38))
                $g.DrawLine($pen, [float]($x + $w * 0.44), [float]($y + $h * 0.38), [float]($x + $w * 0.44), [float]($y + $h * 0.82))
            }
            'keyboard' {
                $kp = New-RoundedPath ($x + $w * 0.1) ($y + $h * 0.22) ($w * 0.8) ($h * 0.56) ($w * 0.1)
                $g.DrawPath($pen, $kp); $kp.Dispose()
                $g.DrawLine($pen, [float]($x + $w * 0.24), [float]($y + $h * 0.42), [float]($x + $w * 0.32), [float]($y + $h * 0.42))
                $g.DrawLine($pen, [float]($x + $w * 0.45), [float]($y + $h * 0.42), [float]($x + $w * 0.55), [float]($y + $h * 0.42))
                $g.DrawLine($pen, [float]($x + $w * 0.68), [float]($y + $h * 0.42), [float]($x + $w * 0.76), [float]($y + $h * 0.42))
                $g.DrawLine($pen, [float]($x + $w * 0.28), [float]($y + $h * 0.60), [float]($x + $w * 0.72), [float]($y + $h * 0.60))
            }
            'settings' {
                $ir = $w * 0.16
                $g.DrawEllipse($pen, $x + $w * 0.5 - $ir, $y + $h * 0.5 - $ir, $ir * 2, $ir * 2)
                for ($i = 0; $i -lt 8; $i++) {
                    $ang = $i * [Math]::PI / 4.0
                    $x1 = $x + $w * 0.5 + [Math]::Cos($ang) * ($w * 0.27)
                    $y1 = $y + $h * 0.5 + [Math]::Sin($ang) * ($h * 0.27)
                    $x2 = $x + $w * 0.5 + [Math]::Cos($ang) * ($w * 0.39)
                    $y2 = $y + $h * 0.5 + [Math]::Sin($ang) * ($h * 0.39)
                    $g.DrawLine($pen, [float]$x1, [float]$y1, [float]$x2, [float]$y2)
                }
            }
            'bell' {
                $g.DrawLine($pen, [float]($x + $w * 0.50), [float]($y + $h * 0.08), [float]($x + $w * 0.50), [float]($y + $h * 0.17))
                $bp = New-Object System.Drawing.Drawing2D.GraphicsPath
                $bp.AddArc([float]($x + $w * 0.24), [float]($y + $h * 0.17), [float]($w * 0.52), [float]($h * 0.48), [float]180, [float]180)
                $bp.AddLine([float]($x + $w * 0.84), [float]($y + $h * 0.72), [float]($x + $w * 0.16), [float]($y + $h * 0.72))
                $bp.CloseFigure()
                $g.DrawPath($pen, $bp); $bp.Dispose()
                $g.DrawArc($pen, [float]($x + $w * 0.39), [float]($y + $h * 0.65), [float]($w * 0.22), [float]($h * 0.23), [float]20, [float]140)
            }
        }
    } finally {
        $pen.Dispose(); $brush.Dispose(); $g.SmoothingMode = $oldSmooth
    }
}

function Set-CardStyle {
    param($panel, [int]$Radius = 10, $Bg = $cWhite, $Border = $cLine)
    Enable-DoubleBuffer $panel
    $panel.BackColor = $Bg
    $st = @{ Radius = $Radius; Bg = $Bg; Border = $Border }
    $panel | Add-Member -NotePropertyName CardStyle -NotePropertyValue $st -Force
    $panel.Add_Paint({
        param($s, $e)
        $st = $s.CardStyle; if (-not $st) { return }
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $parBg = if ($s.Parent) { $s.Parent.BackColor } else { $cPaper }
        $g.Clear($parBg)
        $r = [float]($st.Radius * $script:dpiScale)
        $rect = [System.Drawing.RectangleF]::new(0.5, 0.5, ($s.ClientSize.Width - 1.5), ($s.ClientSize.Height - 1.5))
        $path = New-RoundedPath $rect.X $rect.Y $rect.Width $rect.Height $r
        $fb = New-Object System.Drawing.SolidBrush($st.Bg)
        $bp = New-Object System.Drawing.Pen($st.Border, 1.0)
        $g.FillPath($fb, $path)
        if ($st.Border -ne [System.Drawing.Color]::Transparent) { $g.DrawPath($bp, $path) }
        $fb.Dispose(); $bp.Dispose(); $path.Dispose()
    })
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
    $n.BorderStyle = 'FixedSingle'; $n.BackColor = $cWhite
    return $n
}
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

function Add-RoundedButtonPaint {
    param($btn, [int]$Radius = 8, [bool]$HasBorder = $true, [string]$Glyph = '')
    Enable-DoubleBuffer $btn
    $st = @{ Hover = $false; Down = $false; Radius = $Radius; HasBorder = $HasBorder; Glyph = $Glyph }
    $btn | Add-Member -NotePropertyName BtnPaint -NotePropertyValue $st -Force
    $btn.Add_MouseEnter({ $b = $args[0]; if ($b.BtnPaint) { $b.BtnPaint.Hover = $true }; $b.Invalidate() })
    $btn.Add_MouseLeave({ $b = $args[0]; if ($b.BtnPaint) { $b.BtnPaint.Hover = $false; $b.BtnPaint.Down = $false }; $b.Invalidate() })
    $btn.Add_MouseDown({ $b = $args[0]; if ($b.BtnPaint) { $b.BtnPaint.Down = $true }; $b.Invalidate() })
    $btn.Add_MouseUp({ $b = $args[0]; if ($b.BtnPaint) { $b.BtnPaint.Down = $false }; $b.Invalidate() })
    $btn.Add_EnabledChanged({ $args[0].Invalidate() })
    $btn.Add_Paint({
        param($b, $e)
        $st = $b.BtnPaint; if (-not $st) { return }
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $parBg = if ($b.Parent) { $b.Parent.BackColor } else { $cPaper }
        $g.Clear($parBg)
        $isEn = $b.Enabled
        $bg = $b.BackColor
        $fg = $b.ForeColor
        $bd = $b.FlatAppearance.BorderColor
        if (-not $isEn) {
            if ($st.HasBorder) {
                $bg = $cBusySecBg; $fg = $cBusySecText; $bd = $cBusySecLine
            } else {
                $bg = if ($bg.R -lt 90) { $cBusyInk } else { $parBg }
                $fg = if ($bg.R -lt 130) { $cBusyInkText } else { $cBusyLink }
                $bd = $bg
            }
        } elseif ($st.Hover -or $st.Down) {
            $ov = $b.FlatAppearance.MouseOverBackColor
            if (-not $ov.IsEmpty -and $ov.A -gt 0) { $bg = $ov }
            if ($st.HasBorder -and $bd -eq $cLineStrong) { $bd = $cLineHover }
        }
        $r = [float]($st.Radius * $script:dpiScale)
        $rect = [System.Drawing.RectangleF]::new(0.5, 0.5, ($b.ClientSize.Width - 1.5), ($b.ClientSize.Height - 1.5))
        $path = New-RoundedPath $rect.X $rect.Y $rect.Width $rect.Height $r
        $sb = New-Object System.Drawing.SolidBrush($bg)
        $g.FillPath($sb, $path)
        $sb.Dispose()
        if ($st.HasBorder -and -not $bd.IsEmpty -and $bd -ne [System.Drawing.Color]::Transparent) {
            $pen = New-Object System.Drawing.Pen($bd, 1.0)
            $g.DrawPath($pen, $path)
            $pen.Dispose()
        }
        $path.Dispose()
        $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::SingleLine -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis
        $textRect = $b.ClientRectangle
        if ($st.Glyph) {
            if ([string]::IsNullOrEmpty($b.Text)) {
                $sz = [float](14 * $script:dpiScale)
                $sx = ($b.ClientSize.Width - $sz) / 2.0
                $sy = ($b.ClientSize.Height - $sz) / 2.0
                Draw-Glyph $g $st.Glyph ([System.Drawing.RectangleF]::new($sx, $sy, $sz, $sz)) $fg (1.4 * $script:dpiScale)
                return
            }
            $sz = [float](13 * $script:dpiScale)
            $txSz = [System.Windows.Forms.TextRenderer]::MeasureText($g, $b.Text, $b.Font, $b.ClientSize, $flags)
            $gap = [float](4 * $script:dpiScale)
            $totalW = $sz + $gap + $txSz.Width
            $sx = ($b.ClientSize.Width - $totalW) / 2.0
            $sy = ($b.ClientSize.Height - $sz) / 2.0
            Draw-Glyph $g $st.Glyph ([System.Drawing.RectangleF]::new($sx, $sy, $sz, $sz)) $fg (1.4 * $script:dpiScale)
            $textRect = [System.Drawing.Rectangle]::new([int]($sx + $sz + $gap), 0, [int]([Math]::Ceiling($txSz.Width) + 4), $b.ClientSize.Height)
            $flags = [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::SingleLine
        }
        [System.Windows.Forms.TextRenderer]::DrawText($g, $b.Text, $b.Font, $textRect, $fg, $flags)
    })
}

# 主操作按钮（炭墨实心圆角）
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
    Add-RoundedButtonPaint $b 8 $false
    return $b
}
# 次要操作按钮（白底圆角描边）
function New-SecondaryBtn {
    param($text, $x, $y, $w, $h)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 1; $b.FlatAppearance.BorderColor = $cLineStrong
    $b.BackColor = $cWhite; $b.ForeColor = $cInk
    $b.FlatAppearance.MouseOverBackColor = $cHover
    $b.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    Add-RoundedButtonPaint $b 7 $true
    return $b
}
# 文字链接 / 幽灵按钮（透明底圆角悬停）
function New-LinkBtn {
    param($text, $x, $y, $w, [string]$Glyph = '')
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($w, 26)
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $cPaper; $b.ForeColor = $cText2
    $b.FlatAppearance.MouseOverBackColor = $cSoft
    $b.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    Add-RoundedButtonPaint $b 6 $false $Glyph
    return $b
}

# 主窗口高辨识度圆角功能卡 / 主按钮
function New-ActionCard {
    param($title, $sub, [string]$glyph, $x, $y, $w, $h, [switch]$Primary)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $title
    $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
    $b.BackColor = if ($Primary) { $cInk } else { $cWhite }
    $b.ForeColor = if ($Primary) { $cWhite } else { $cInk }
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    Enable-DoubleBuffer $b
    $cd = @{ Title = $title; Sub = $sub; Glyph = $glyph; Primary = [bool]$Primary; Muted = $false; Dimmed = $false; Accent = $false; Hover = $false }
    $b | Add-Member -NotePropertyName CardData -NotePropertyValue $cd -Force
    $b.Add_MouseEnter({ $btn = $args[0]; if ($btn.CardData) { $btn.CardData.Hover = $true }; $btn.Invalidate() })
    $b.Add_MouseLeave({ $btn = $args[0]; if ($btn.CardData) { $btn.CardData.Hover = $false }; $btn.Invalidate() })
    $b.Add_Paint({
        param($btn, $e)
        $cd = $btn.CardData; if (-not $cd) { return }
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $parBg = if ($btn.Parent) { $btn.Parent.BackColor } else { $cPaper }
        $g.Clear($parBg)
        $s = $script:dpiScale
        $r = [float](10 * $s)
        $rect = [System.Drawing.RectangleF]::new(0.5, 0.5, ($btn.ClientSize.Width - 1.5), ($btn.ClientSize.Height - 1.5))
        $path = New-RoundedPath $rect.X $rect.Y $rect.Width $rect.Height $r
        if ($cd.Primary) {
            if ($cd.Dimmed) {
                $bg = $cBusyInk; $fg = $cBusyInkText; $subFg = $cBusyInkText; $badgeBg = [System.Drawing.Color]::FromArgb(124, 118, 110); $bd = $bg
            } elseif ($cd.Muted) {
                $bg = if ($cd.Hover) { [System.Drawing.Color]::FromArgb(103, 98, 90) } else { [System.Drawing.Color]::FromArgb(119, 114, 106) }
                $fg = $cWhite; $subFg = [System.Drawing.Color]::FromArgb(228, 224, 216); $badgeBg = [System.Drawing.Color]::FromArgb(136, 130, 122); $bd = $bg
            } else {
                $bg = if ($cd.Hover) { $cInkDark } else { $cInk }
                $fg = $cWhite; $subFg = [System.Drawing.Color]::FromArgb(210, 204, 194); $badgeBg = [System.Drawing.Color]::FromArgb(62, 59, 55); $bd = $bg
            }
        } else {
            if ($cd.Dimmed) {
                $bg = $cBusySecBg; $fg = $cBusySecText; $subFg = $cBusyLink; $badgeBg = $cPaper; $bd = $cBusySecLine
            } elseif ($cd.Accent) {
                $bg = if ($cd.Hover) { $cRedBg } else { $cRedStripBg }
                $fg = $cRed; $subFg = $cText2; $badgeBg = $cRedBg; $bd = $cRedBorder
            } else {
                $bg = if ($cd.Hover) { $cHover } else { $cWhite }
                $fg = $cInk; $subFg = $cMuted; $badgeBg = $cPaper; $bd = if ($cd.Hover) { $cLineHover } else { $cLine }
            }
        }
        $sb = New-Object System.Drawing.SolidBrush($bg); $g.FillPath($sb, $path); $sb.Dispose()
        $pen = New-Object System.Drawing.Pen($bd, 1.0); $g.DrawPath($pen, $path); $pen.Dispose()
        $path.Dispose()

        $padX = [float](14 * $s)
        $icoSz = [float]($(if ($cd.Primary) { 36 } else { 34 }) * $s)
        $icoY = ($btn.ClientSize.Height - $icoSz) / 2.0
        $icoPath = New-RoundedPath $padX $icoY $icoSz $icoSz ([float](8 * $s))
        $ib = New-Object System.Drawing.SolidBrush($badgeBg); $g.FillPath($ib, $icoPath); $ib.Dispose(); $icoPath.Dispose()
        $gInset = $icoSz * 0.24
        $gRect = [System.Drawing.RectangleF]::new($padX + $gInset, $icoY + $gInset, $icoSz - $gInset * 2, $icoSz - $gInset * 2)
        Draw-Glyph $g $cd.Glyph $gRect $fg ([float](1.5 * $s))

        $tx = [int]($padX + $icoSz + 11 * $s)
        $tw = [Math]::Max(20, $btn.ClientSize.Width - $tx - [int](10 * $s))
        $titleSize = if ($cd.Primary) { 11.5 } else { 10 }
        $fTitle = New-Object System.Drawing.Font('Microsoft YaHei UI', $titleSize, [System.Drawing.FontStyle]::Bold)
        $fSub = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
        $tH = [System.Windows.Forms.TextRenderer]::MeasureText($g, $cd.Title, $fTitle).Height
        $sH = [System.Windows.Forms.TextRenderer]::MeasureText($g, $cd.Sub, $fSub).Height
        $topY = [int](($btn.ClientSize.Height - ($tH + $sH + [int](2 * $s))) / 2)
        $tf = [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::SingleLine -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis
        [System.Windows.Forms.TextRenderer]::DrawText($g, $cd.Title, $fTitle, [System.Drawing.Rectangle]::new($tx, $topY, $tw, $tH + 2), $fg, $tf)
        [System.Windows.Forms.TextRenderer]::DrawText($g, $cd.Sub, $fSub, [System.Drawing.Rectangle]::new($tx, $topY + $tH + [int](2 * $s), $tw, $sH + 2), $subFg, $tf)
        $fTitle.Dispose(); $fSub.Dispose()
    })
    return $b
}

# 快捷偏好胶囊按钮
function New-CapsuleBtn {
    param([string]$text, $x, $y, $w, $h, [bool]$On = $false, [switch]$Dropdown)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $cPaper; $b.ForeColor = $cText2
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    Enable-DoubleBuffer $b
    $cp = @{ Text = $text; On = $On; Dropdown = [bool]$Dropdown; Dimmed = $false; Hover = $false }
    $b | Add-Member -NotePropertyName CapData -NotePropertyValue $cp -Force
    $b.Add_MouseEnter({ $btn = $args[0]; if ($btn.CapData) { $btn.CapData.Hover = $true }; $btn.Invalidate() })
    $b.Add_MouseLeave({ $btn = $args[0]; if ($btn.CapData) { $btn.CapData.Hover = $false }; $btn.Invalidate() })
    $b.Add_Paint({
        param($btn, $e)
        $cp = $btn.CapData; if (-not $cp) { return }
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $parBg = if ($btn.Parent) { $btn.Parent.BackColor } else { $cPaper }
        $g.Clear($parBg)
        $s = $script:dpiScale
        $rect = [System.Drawing.RectangleF]::new(0.5, 0.5, ($btn.ClientSize.Width - 1.5), ($btn.ClientSize.Height - 1.5))
        $path = New-RoundedPath $rect.X $rect.Y $rect.Width $rect.Height ($rect.Height / 2.0)
        if ($cp.Dimmed) {
            $bg = $cBusySecBg; $bd = $cBusySecLine; $fg = $cBusySecText; $bw = 1.0
        } elseif ($cp.Dropdown) {
            $bg = if ($cp.Hover) { $cHover } else { $cWhite }; $bd = if ($cp.Hover) { $cLineHover } else { $cLineStrong }; $fg = $cInk; $bw = 1.0
        } elseif ($cp.On) {
            $bg = $cWhite; $bd = $cInk; $fg = $cInk; $bw = 1.2
        } else {
            $bg = if ($cp.Hover) { $cSoftHover } else { $cSoft }; $bd = [System.Drawing.Color]::Transparent; $fg = $cText2; $bw = 1.0
        }
        $sb = New-Object System.Drawing.SolidBrush($bg); $g.FillPath($sb, $path); $sb.Dispose()
        if ($bd -ne [System.Drawing.Color]::Transparent) {
            $pen = New-Object System.Drawing.Pen($bd, $bw); $g.DrawPath($pen, $path); $pen.Dispose()
        }
        $path.Dispose()
        $f = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5, $(if ($cp.On -and -not $cp.Dimmed) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }))
        $tf = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::SingleLine
        if (-not $cp.Dropdown -and $cp.On) {
            $dotSz = [float](6 * $s)
            $txSz = [System.Windows.Forms.TextRenderer]::MeasureText($g, $cp.Text, $f, $btn.ClientSize, $tf)
            $gap = [float](5 * $s)
            $sx = ($btn.ClientSize.Width - ($dotSz + $gap + $txSz.Width)) / 2.0
            $db = New-Object System.Drawing.SolidBrush($(if ($cp.Dimmed) { $cBusySecText } else { $cGreen }))
            $g.FillEllipse($db, $sx, ($btn.ClientSize.Height - $dotSz) / 2.0, $dotSz, $dotSz); $db.Dispose()
            $tr = [System.Drawing.Rectangle]::new([int]($sx + $dotSz + $gap), 0, [int]([Math]::Ceiling($txSz.Width) + 4), $btn.ClientSize.Height)
            [System.Windows.Forms.TextRenderer]::DrawText($g, $cp.Text, $f, $tr, $fg, ([System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::SingleLine))
        } else {
            [System.Windows.Forms.TextRenderer]::DrawText($g, $cp.Text, $f, $btn.ClientRectangle, $fg, $tf)
        }
        $f.Dispose()
    })
    return $b
}

# 统一风格的文本输入弹窗（取代 VB InputBox）
function Show-InputDialog {
    param($owner, [string]$title, [string]$prompt, [string]$defaultValue = '')
    $capFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $sz = [System.Windows.Forms.TextRenderer]::MeasureText($prompt, $capFont, (New-Object System.Drawing.Size(348, 0)), [System.Windows.Forms.TextFormatFlags]::WordBreak)
    $promptH = [Math]::Max(20, [int]$sz.Height)
    $txtTop = 16 + $promptH + 10
    $btnTop = $txtTop + 38
    $dlg = New-Dialog $title 380 ($btnTop + 50) $owner
    $lbl = New-Lbl $prompt 16 16
    $lbl.Font = $capFont
    $lbl.MaximumSize = New-Object System.Drawing.Size(348, 0)
    $txt = New-Txt 16 $txtTop 348 26
    $txt.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $txt.Text = $defaultValue
    $ok = New-PrimaryBtn '确定' 192 $btnTop 84 34 10
    $cancel = New-SecondaryBtn '取消' 282 $btnTop 82 34
    $ok.Add_Click({ $dlg.Tag = $txt.Text; $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Close() })
    $cancel.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $dlg.Close() })
    $dlg.Controls.AddRange(@($lbl, $txt, $ok, $cancel))
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $dlg.Add_Shown({ try { $txt.SelectAll(); [void]$txt.Focus() } catch {} })
    if ($dlg.ShowDialog($owner) -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return [string]$dlg.Tag
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
                $script:dpiScale = $fac
                $f.Scale([System.Drawing.SizeF]::new($fac, $fac))
                Update-ListViewColumnWidths $f $fac   # Scale 不管列宽，这里按同一比例补上
            } else {
                $script:dpiScale = 1.0
            }
        } catch {}
    })
}

# 统一风格的弹窗：标题/尺寸/居中父窗/固定边框/字体/底色一处定义，各弹窗共用
function New-Dialog {
    param($title, $w, $h, $owner)
    $d = New-Object System.Windows.Forms.Form
    Set-DpiScale $d   # 高 DPI 清晰化：Load 时按真实 DPI 等比放大
    Enable-DoubleBuffer $d
    $d.Text = $title; $d.ClientSize = New-Object System.Drawing.Size($w, $h)
    $d.Icon = Get-AppIcon
    $d.FormBorderStyle = 'FixedDialog'
    $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.Font = $owner.Font; $d.BackColor = $cPaper
    Set-TitleBarColor $d $cPaper
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
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $bgClear = New-Object System.Drawing.SolidBrush($cPaper)
        $g.FillRectangle($bgClear, $r); $bgClear.Dispose()
        if ($sel) {
            $pill = New-RoundedPath ([float]($r.Left + 2)) ([float]($r.Top + 2)) ([float]($r.Width - 6)) ([float]($r.Height - 4)) ([float](6 * $script:dpiScale))
            $bg = New-Object System.Drawing.SolidBrush($cWhite)
            $g.FillPath($bg, $pill); $bg.Dispose()
            $bd = New-Object System.Drawing.Pen($cLine, 1.0)
            $g.DrawPath($bd, $pill); $bd.Dispose(); $pill.Dispose()
            $red = New-Object System.Drawing.SolidBrush($cRed)
            $barR = New-RoundedPath ([float]($r.Left + 4)) ([float]($r.Top + 8)) ([float](3 * $script:dpiScale)) ([float]($r.Height - 16)) ([float](1.5 * $script:dpiScale))
            $g.FillPath($red, $barR); $red.Dispose(); $barR.Dispose()
        }
        $fg = New-Object System.Drawing.SolidBrush($(if ($sel) { $cInk } else { $cText2 }))
        $f = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, $(if ($sel) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }))
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
    $chkStay = New-Chk '投屏时保持手机唤醒' $settings.stayAwake 14 74
    $chkScreenOff = New-Chk '开始投屏时熄灭手机屏幕' $settings.screenOff 14 102
    $chkReconnect = New-Chk '自动重连已记住的无线设备' $settings.autoConnect 14 130
    $chkDisconnect = New-Chk '关闭助手时断开无线连接' $settings.disconnectOnClose 14 158
    $chkShowConsole = New-Chk '显示投屏日志窗口' $settings.showConsole 14 186
    $tt.SetToolTip($nudSize, '按比例缩小投屏画面，最长的一边不超过这个像素数。0=不限制。投屏卡顿时可试 1280。')
    $tt.SetToolTip($chkAudio, '适用于普通投屏和屏幕录制。需要 Android 11+。Android 11 请先解锁手机再开始。')
    $tt.SetToolTip($chkStay, '投屏时防止手机因长时间没操作而休眠。手机仍可手动锁屏。')
    $tt.SetToolTip($chkScreenOff, '开始投屏时熄灭手机屏幕，电脑画面继续显示。按手机电源键或在投屏窗口按左 Alt+Shift+O 点亮。')
    $tt.SetToolTip($chkReconnect, '打开助手时尝试连回记住的手机。手机掉线后也会尝试重连。')
    $tt.SetToolTip($chkDisconnect, '想在退出时顺便断开助手记住或使用过的无线设备，就勾选这项。')
    $tt.SetToolTip($chkShowConsole, '保存后重新投屏，就能看到日志窗口。投屏打不开时可在这里看报错。')
    $tabCommon.Controls.AddRange(@(
        (New-Lbl '清晰度：' 14 16), $nudSize, (New-Caption '像素，0=不限制' 210 19),
        $chkAudio, $chkStay, $chkScreenOff, $chkReconnect, $chkDisconnect, $chkShowConsole))

    # ===== 画面 =====
    $tabVideo = New-Object System.Windows.Forms.Panel
    $nudFps  = New-Nud $settings.maxFps  0 240 5  110 16
    $nudBit  = New-Nud $settings.bitRate 0 50  1  110 52
    $cbVCodec = New-Combo @('默认（H.264，兼容最好）', 'H.265', 'AV1', 'VP8', 'VP9') @('', 'h265', 'av1', 'vp8', 'vp9') $settings.videoCodec 110 88 230
    $txtCrop = New-Txt 110 124 230
    $txtCrop.Text = $settings.crop
    $chkIgnoreEnc = New-Chk '忽略画面尺寸限制（高级）' $settings.ignoreEncoderConstraints 14 184
    $tt.SetToolTip($chkIgnoreEnc, '画面比设定的尺寸小很多时可以试试。若开启后投屏打不开，关掉再试。')
    $cbHwDec = New-Combo @('自动（推荐）', '软件解码') @('', 'disabled') $settings.hwDec 110 217 230
    $tt.SetToolTip($cbHwDec, '平时选「自动」即可。遇到花屏、偏色或黑屏时，可换「软件解码」再试。')
    $tt.SetToolTip($nudFps, '每秒最多更新多少次画面。0=不限制。正看静止画面时，实际更新次数会更少。')
    $tt.SetToolTip($nudBit, '数字越高，画面通常越清楚，也更占网速。0=用默认（8 Mbps）。无线投屏卡顿时可试 4 Mbps。')
    $tt.SetToolTip($cbVCodec, '平时用默认的 H.264。改过后如果投屏打不开或变卡，可以先换回默认。')
    $tt.SetToolTip($txtCrop, '按设备的自然方向填写宽:高:左:上（像素）。手机通常以竖屏为准，例如 1080:1080:0:300。不填=投整屏。')
    $tabVideo.Controls.AddRange(@(
        (New-Lbl '帧率：' 14 19), $nudFps, (New-Caption '帧/秒，0=不限制' 210 21),
        (New-Lbl '画质：' 14 55), $nudBit, (New-Caption '越高越占网速，0=用默认' 210 57),
        (New-Lbl '视频编码：' 14 91), $cbVCodec,
        (New-Lbl '裁剪画面：' 14 127), $txtCrop,
        (New-Caption '宽:高:左:上，不填=投整屏。例 1080:1080:0:300' 110 156),
        $chkIgnoreEnc,
        (New-Lbl '解码方式：' 14 220), $cbHwDec,
        (New-Caption '花屏或偏色时，可换软件解码再试' 110 249)))

    # ===== 声音 =====
    $tabAudio = New-Object System.Windows.Forms.Panel
    $cbASrc = New-Combo @('手机正在播放的声音', '手机麦克风') @('', 'mic') $settings.audioSource 110 73 230
    $cbACodec = New-Combo @('默认（Opus）', 'AAC（兼容）', 'FLAC（无损）', '原始 PCM') @('', 'aac', 'flac', 'raw') $settings.audioCodec 110 111 230
    # 主开关在「常用」类里也有一个：两处勾选框同时存在，状态必须互相同步，否则保存时后读的会把先改的抹掉
    $chkAudio2 = New-Chk '把手机声音也传到电脑' $settings.audioOn 14 18
    $chkAudio2.Add_CheckedChanged({ $chkAudio.Checked = $chkAudio2.Checked }.GetNewClosure())
    $chkAudio.Add_CheckedChanged({ $chkAudio2.Checked = $chkAudio.Checked }.GetNewClosure())
    $lblAudioTip = New-Caption '需 Android 11+。Android 11 请先解锁手机再开始。' 14 46
    $tt.SetToolTip($cbASrc, '想听手机里正在播放的内容，选第一项，声音会改从电脑播放。想收周围的声音，选「手机麦克风」。')
    $tt.SetToolTip($cbACodec, '默认使用 Opus。若录屏文件在播放器里没有声音，可选 AAC 后重新录制。选原始 PCM 时录屏使用 mkv。')
    $tabAudio.Controls.AddRange(@(
        $lblAudioTip,
        $chkAudio2,
        (New-Lbl '声音来源：' 14 76), $cbASrc,
        (New-Lbl '音频编码：' 14 114), $cbACodec))

    # ===== 控制 =====
    $tabCtrl = New-Object System.Windows.Forms.Panel
    $cbKb = New-Combo @('默认（推荐）', '模拟实体键盘', 'USB 直连（只控制）') @('', 'uhid', 'aoa') $settings.keyboard 110 13 300
    $cbMouse = New-Combo @('默认（推荐）', '模拟实体鼠标', 'USB 直连（只控制）') @('', 'uhid', 'aoa') $settings.mouse 110 89 300
    $capMouse = New-Caption '选「模拟实体鼠标」后，按左 Alt 或左 Win 可把鼠标切回电脑。' 14 120
    $capMouse.MaximumSize = New-Object System.Drawing.Size(396, 0)
    # 顺序按使用度：键鼠模式在前，常用的「只投屏」「关窗息屏」次之，niche 的触摸点 / 手柄沉底
    $chkNoCtrl = New-Chk '只投屏，不允许控制手机' $settings.noControl 14 148
    $chkPowerOff = New-Chk '结束投屏后熄灭手机屏幕' $settings.powerOffOnClose 14 176
    $chkTouches = New-Chk '显示触摸点' $settings.showTouches 14 204
    $chkGamepad = New-Chk '启用手柄（把电脑手柄映射到手机）' $settings.gamepad 14 232
    $tt.SetToolTip($chkTouches, '在画面中标出手指实际触摸手机的位置。')
    $tt.SetToolTip($cbKb, '中文可以用 Ctrl+V 粘贴。想用手机输入法打字，可选「模拟实体键盘」。投屏时请选前两项。')
    $tt.SetToolTip($cbMouse, '平时选「默认」。使用「模拟实体鼠标」后，按左 Alt 或左 Win 可把鼠标指针切回电脑。投屏时请选前两项。')
    $tt.SetToolTip($chkNoCtrl, '只看画面、禁止鼠标键盘操作手机；保持唤醒、投屏关屏、显示触摸点和关窗息屏暂不生效。开启「只投屏，不允许控制手机」时，独立窗口不可用。')
    $tt.SetToolTip($chkPowerOff, '结束投屏（关掉投屏窗口）时，顺手把手机屏幕熄灭，省电、防亮屏。')
    $tt.SetToolTip($chkGamepad, '把接到电脑的手柄用在手机上。游戏也得支持手柄。')
    # 说明紧跟「键盘模式」，两行封顶：离得远用户不知道它讲的是哪一项，长段落还会折出孤儿字
    $capKbCn = New-Caption "中文可用 Ctrl+V 粘贴。`n也可选「模拟实体键盘」，用手机输入法打字。" 14 44
    $capKbCn.MaximumSize = New-Object System.Drawing.Size(396, 0)   # 不限宽会裁出面板右缘；窄于 396 第一行就折出孤儿字
    $tabCtrl.Controls.AddRange(@(
        (New-Lbl '键盘模式：' 14 16), $cbKb,
        (New-Lbl '鼠标模式：' 14 92), $cbMouse, $capMouse,
        $chkNoCtrl, $chkPowerOff, $chkTouches, $chkGamepad, $capKbCn))

    # ===== 窗口 =====
    $tabWin = New-Object System.Windows.Forms.Panel
    $chkFull = New-Chk '启动即全屏' $settings.fullscreen 14 18
    $chkTop = New-Chk '窗口总在最前' $settings.onTop 14 46
    $chkBorderless = New-Chk '无边框窗口' $settings.borderless 14 74
    $capBorderless = New-Caption '去掉标题栏与边框，关窗按左 Alt+Q，也可在主界面点「■ 停止」。' 32 99
    $chkMinTray = New-Chk '最小化时收起到系统托盘（不在任务栏占位）' $settings.minToTray 14 126
    $tt.SetToolTip($chkFull, '投屏后画面直接铺满整个屏幕；在投屏窗口按 左 Alt+f（或 F11）可退出全屏。')
    $tt.SetToolTip($chkTop, '投屏窗口始终浮在其它窗口上方，边看手机边操作电脑很方便。')
    $tt.SetToolTip($chkBorderless, '去掉投屏窗口的标题栏和边框，像把手机屏幕贴在桌面上。关窗用 左 Alt+q。')
    $tt.SetToolTip($chkMinTray, '勾上后点标题栏最小化，助手窗口会收起到右下角托盘区，任务栏不再占位；单击/双击托盘图标还原，右键菜单可退出或停止会话。投屏、录制等功能在托盘下照常运行。')
    $tabWin.Controls.AddRange(@($chkFull, $chkTop, $chkBorderless, $capBorderless, $chkMinTray))

    # ===== 独立窗口 =====
    $tabNd = New-Object System.Windows.Forms.Panel
    $cbNdSize = New-Object System.Windows.Forms.ComboBox
    $cbNdSize.DropDownStyle = 'DropDown'
    $cbNdSize.Location = New-Object System.Drawing.Point(110, 15); $cbNdSize.Size = New-Object System.Drawing.Size(200, 26)
    @('自动', '1280x720', '1600x900', '1920x1080') | ForEach-Object { [void]$cbNdSize.Items.Add($_) }
    $cbNdSize.Text = if ($settings.ndSize) { $settings.ndSize } else { '自动' }
    $ndDpiLabels = @('自动', '小', '中', '大')
    $ndDpiValues = @('', '160', '240', '320')
    $ndDpiCurrent = [string]$settings.ndDpi
    # 自定义尺寸面板允许任意数字 DPI，保存其它设置时不能把它静默重置为预设的「自动」。
    if ($ndDpiCurrent -match '^\d+$' -and $ndDpiValues -notcontains $ndDpiCurrent) {
        $ndDpiLabels += "自定义 $ndDpiCurrent"
        $ndDpiValues += $ndDpiCurrent
    }
    $cbNdDpi = New-Combo $ndDpiLabels $ndDpiValues $ndDpiCurrent 110 73 110
    $chkNoDecor = New-Chk '隐藏独立窗口的系统栏' $settings.ndNoDecor 14 110
    $tt.SetToolTip($cbNdSize, '一般选「自动」即可。需要指定尺寸时，可输入宽和高，例如 2560x1440。')
    $tt.SetToolTip($cbNdDpi, '调节独立窗口里的字和按钮大小。显示太大时选「小」。')
    $tt.SetToolTip($chkNoDecor, '隐藏独立窗口里的时间、电量和底部导航栏。想恢复时，取消勾选并重开窗口。')
    $tabNd.Controls.AddRange(@(
        (New-Lbl '分辨率：' 14 18), $cbNdSize,
        (New-Caption '可直接输入，如 2560x1440。不填=自动。' 110 46),
        (New-Lbl '界面缩放：' 14 76), $cbNdDpi,
        $chkNoDecor))

    # ===== 录制 =====
    $tabRec = New-Object System.Windows.Forms.Panel
    $cbRecFmt = New-Combo @('mp4', 'mkv') @('mp4', 'mkv') $settings.recFormat 110 15 110
    $nudTime = New-Nud $settings.recTimeLimit 0 86400 10 110 77
    $chkRecBg = New-Chk '后台录制（不显示画面，更省资源）' $settings.recBackground 14 114
    $capRecBg = New-Caption '开始后可在主界面点「停止录制」或上方「■ 停止」结束。' 32 139
    $txtRecDir = New-Txt 110 172 214
    $txtRecDir.Text = $settings.recDir
    $btnRecDirBrowse = New-SecondaryBtn '浏览…' 330 171 68 26
    $btnRecDirBrowse.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = '选择录屏默认保存目录'
        $fbd.ShowNewFolderButton = $true
        $curDir = $txtRecDir.Text.Trim()
        if ($curDir -and (Test-Path -LiteralPath $curDir -PathType Container)) { $fbd.SelectedPath = $curDir }
        if ($fbd.ShowDialog($dlg) -eq [System.Windows.Forms.DialogResult]::OK) { $txtRecDir.Text = $fbd.SelectedPath }
        $fbd.Dispose()
    }.GetNewClosure())
    $capRecDir = New-Caption '填好后点「录制屏幕」直接保存到这里；不填=每次弹窗选择。' 110 202
    $capRecDir.MaximumSize = New-Object System.Drawing.Size(294, 0)
    $tt.SetToolTip($nudTime, '到达指定秒数自动停止录制。0=不限时。后台录制可在主界面点「停止录制」或上方「■ 停止」结束。')
    $tt.SetToolTip($cbRecFmt, 'mp4 通用好打开；mkv 更稳——录制中途若被强退，mp4 可能整段丢失，mkv 一般能保住已录部分。')
    $tt.SetToolTip($chkRecBg, '录制时电脑不显示画面、不播放声音。已开启且能采集的声音仍会写入录屏文件。开始后可在主界面、托盘菜单或「设备管理」停止。')
    $tt.SetToolTip($txtRecDir, '录屏默认保存文件夹。填好后点「录制屏幕」会直接按时间戳保存，不再每次弹窗；不填=每次手动选（并记住上次目录）。')
    $tabRec.Controls.AddRange(@(
        (New-Lbl '保存格式：' 14 18), $cbRecFmt,
        (New-Caption 'mp4 好打开；担心中途被强退丢整段，选 mkv 更稳' 110 46),
        (New-Lbl '录制时长：' 14 80), $nudTime, (New-Caption '秒，0=不限时长' 210 82),
        $chkRecBg, $capRecBg,
        (New-Lbl '保存目录：' 14 176), $txtRecDir, $btnRecDirBrowse, $capRecDir))

    # ===== 通用 =====
    $tabGen = New-Object System.Windows.Forms.Panel
    $chkLive = New-Chk '自动刷新主界面的连接状态（不影响投屏）' $settings.liveStatus 14 18
    $txtExtra = New-Txt 14 78 392
    $txtExtra.Text = $settings.extraArgs
    $lblExHint = New-Lbl '例如：--angle=90   --display-id=1   --time-limit=300' 14 108; $lblExHint.ForeColor = $cMuted
    $tt.SetToolTip($chkLive, '切回主界面会更新连接状态。开启自动刷新或无线重连后，主界面在最前面时也会定时检查。')
    $tt.SetToolTip($txtExtra, '高级用法（可选，一般不用填）：在这里追加 scrcpy 命令行参数，参数之间用空格分隔。含空格的值用双引号包住，例如 --window-title="Living Room"。')

    # 自定义 adb / scrcpy 路径（留空=用本助手同目录自带的）
    $lblPathHdr = New-Lbl '自定义 adb / scrcpy 路径（可选）' 14 150; $lblPathHdr.ForeColor = $cMuted
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
    $btnCancel = New-SecondaryBtn '取消' 458 308 96 34
    $btnCancel.Add_Click({ $dlg.Close() })
    $btnSave.Add_Click({
        $ndText = $cbNdSize.Text.Trim()
        if ($ndText -and $ndText -ne '自动' -and $ndText -notmatch '^\d{3,4}x\d{3,4}$') {
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
        $settings.ndSize     = if ($ndText -eq '自动') { '' } else { $ndText }
        $settings.ndDpi      = $cbNdDpi.Vals[$cbNdDpi.SelectedIndex]
        $settings.ndNoDecor  = $chkNoDecor.Checked
        $settings.recFormat  = $cbRecFmt.Vals[$cbRecFmt.SelectedIndex]
        $settings.recTimeLimit = [int]$nudTime.Value
        $settings.recBackground = $chkRecBg.Checked
        $settings.recDir     = $txtRecDir.Text.Trim()
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
        if ($settings.recDir -and -not (Test-Path -LiteralPath $settings.recDir -PathType Container)) {
            [System.Windows.Forms.MessageBox]::Show("填写的录制保存目录不存在，录制时将改为弹窗选择：`n$($settings.recDir)", '设置') | Out-Null
        }
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    })
    $btnReset = New-SecondaryBtn '恢复默认' 16 308 110 34
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

function Get-AppFavorites {
    $remaining = [ordered]@{}
    foreach ($map in @($apps, $script:customApps)) {
        $builtIn = [object]::ReferenceEquals($map, $apps)
        foreach ($name in $map.psbase.Keys) {
            $pkg = $map[$name]
            if ($builtIn -and $script:hiddenBuiltInApps.ContainsKey($pkg)) { continue }
            # 内置项按包名记顺序，自定义项按显示名区分旧设置里同包名的多个快捷项。
            $id = if ($builtIn) { "builtin:$pkg" } else { "custom:$name" }
            $remaining[$id] = [pscustomobject]@{ Id=$id; Name=$name; Pkg=$pkg; Favorite=$true; BuiltIn=$builtIn }
        }
    }
    $ordered = @(
        foreach ($id in $script:appFavoriteOrder) {
            if ($remaining.Contains($id)) {
                $remaining[$id]
                $remaining.Remove($id)
            }
        }
        $remaining.psbase.Values
    )
    return @($ordered)
}

function Move-AppFavorite {
    param([string]$sourceId, [string]$targetId)
    if ($sourceId -eq $targetId) { return $false }
    $order = [Collections.Generic.List[string]]::new()
    foreach ($item in @(Get-AppFavorites)) { $order.Add($item.Id) }
    $sourceIndex = $order.IndexOf($sourceId)
    $targetIndex = $order.IndexOf($targetId)
    if ($sourceIndex -lt 0 -or $targetIndex -lt 0) { return $false }

    # 移到目标原来的行号，向下拖放在目标后面，向上拖放在目标前面。
    $order.RemoveAt($sourceIndex)
    $order.Insert($targetIndex, $sourceId)
    $script:appFavoriteOrder.Clear()
    $script:appFavoriteOrder.AddRange($order)
    Save-Settings
    return $true
}

function Add-AppFavorite {
    param($owner, [string]$name, [string]$pkg, [switch]$FromPhone)
    $builtInName = foreach ($key in $apps.psbase.Keys) {
        if ($apps[$key] -eq $pkg) { $key; break }
    }
    if (($builtInName -and -not $script:hiddenBuiltInApps.ContainsKey($pkg)) -or $script:customApps.psbase.Values -contains $pkg) {
        [void](Show-ResultDialog $owner '更多应用' '这个应用已在常用列表中' $pkg '' @('ok'))
        return
    }
    if ($builtInName) {
        $script:hiddenBuiltInApps.Remove($pkg)
        Save-Settings
        return $builtInName
    }
    if ($apps.Contains($name) -or $script:customApps.Contains($name)) {
        if (-not $FromPhone) {
            [void](Show-ResultDialog $owner '更多应用' '这个显示名称已被使用' '请用其他名称添加该应用。' '' @('ok'))
            return
        }
        # 手机上的不同应用可以同名，用包名区分，避免覆盖已有条目。
        $name = "$name ($pkg)"
        while ($apps.Contains($name) -or $script:customApps.Contains($name)) { $name += ' ·' }
    }
    $script:customApps[$name] = $pkg
    Save-Settings
    return $name
}

function Read-PhoneAppList {
    param($owner, $serial, [switch]$Refresh)
    $cached = if ($serial) { $script:phoneAppListCache[$serial] }
    if (-not $Refresh -and $cached -and $cached.ExpiresAt -gt [DateTime]::UtcNow) { return $cached }

    # 手机应用多或无线连接较慢时，默认命令超时可能赶不上 scrcpy 返回列表。
    $listArgs = if ($serial) { @('-s', $serial, '--list-apps') } else { @('--list-apps') }
    $oldCursor = $owner.Cursor
    $owner.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try { $command = Invoke-UiCommand $owner $exe $listArgs -TimeoutMs 60000 -StatusText '正在读取手机应用列表…' }
    finally { $owner.Cursor = $oldCursor }

    if (Test-CommandSuccess $command) {
        $installed = @{}
        $raw = $command.Stdout + "`n" + $command.Stderr
        foreach ($line in ($raw -split "`n")) {
            if ($line -match '^\s*[-*]\s+(.*?)\s+([A-Za-z][A-Za-z0-9._]+)\s*$') {
                $installed[$matches[2]] = $matches[1].Trim()
            }
        }
        $result = @{ Apps=$installed; Status=''; Detail=''; ExpiresAt=[DateTime]::UtcNow.AddMinutes(2) }
        if ($serial) { $script:phoneAppListCache[$serial] = $result }
        return $result
    }

    $status = if ($command.Cancelled) { '已取消读取手机应用列表。' }
        elseif ($command.TimedOut) { '读取手机应用列表超时。' }
        else { '读取手机应用列表失败。' }
    $lastApps = if ($cached) { $cached.Apps } else { @{} }
    return @{ Apps=$lastApps; Status=$status; Detail=(Get-CommandDetail $command) }
}

# ---------------- 从手机已装 App 和常用应用里挑一个（可搜索） ----------------
function Show-AppPicker {
    param($owner, $serial)
    $appList = @{ Current=(Read-PhoneAppList $owner $serial) }
    $dlg = New-Dialog '更多应用' 460 388 $owner
    $lbl = New-Lbl '按应用名称或包名搜索' 16 14
    $btnRefresh = New-LinkBtn '刷新应用列表' 336 8 108
    $txt = New-Txt 16 40 308
    $chkFavorites = New-Chk '只看常用' $false 344 42
    $lblSortHint = New-Caption '拖动常用应用调整顺序。' 16 71
    $lblStatus = New-Caption '' 192 71
    $lb = New-Object System.Windows.Forms.ListBox
    $lb.Location = '16,94'; $lb.Size = '428,236'
    $lb.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $lb.AllowDrop = $true
    $lblEmpty = New-Caption '没有匹配的应用' 24 104
    $lblEmpty.BackColor = $cWhite

    $btnGo = New-PrimaryBtn '选择应用' 16 342 102 34 10
    $btnFavorite = New-SecondaryBtn '加入常用' 126 342 80 34
    $btnRemove = New-SecondaryBtn '移除常用' 214 342 80 34
    $btnManual = New-SecondaryBtn '手动添加' 302 342 80 34
    $btnClose = New-SecondaryBtn '关闭' 390 342 54 34
    $btnClose.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $shown = New-Object System.Collections.ArrayList
    $result = @{ SelectedApp=$null; FavoritesChanged=$false }

    $syncButtons = {
        $selectedApp = if ($lb.SelectedIndex -ge 0 -and $lb.SelectedIndex -lt $shown.Count) { $shown[$lb.SelectedIndex] }
        $btnGo.Enabled = $null -ne $selectedApp
        $btnFavorite.Enabled = $btnGo.Enabled -and -not $selectedApp.Favorite
        $btnFavorite.Text = if ($selectedApp.Favorite) { '已在常用' } else { '加入常用' }
        $btnRemove.Enabled = [bool]$selectedApp.Favorite
    }
    $fill = {
        param([string]$preferredName, [string]$preferredPackage, [switch]$ClearSelection)
        $query = $txt.Text.Trim()
        $installed = $appList.Current.Apps
        $favorites = @(Get-AppFavorites)
        $entries = if ($chkFavorites.Checked) { $favorites } else {
            $listedPackages = @{}
            $all = @(
                foreach ($entry in $favorites) {
                    $listedPackages[$entry.Pkg] = $true
                    $entry
                }
                foreach ($name in $apps.psbase.Keys) {
                    $pkg = $apps[$name]
                    if (-not $listedPackages.ContainsKey($pkg)) {
                        $listedPackages[$pkg] = $true
                        [pscustomobject]@{ Name=$name; Pkg=$pkg; Favorite=$false; BuiltIn=$true }
                    }
                }
                foreach ($pkg in $installed.psbase.Keys) {
                    if (-not $listedPackages.ContainsKey($pkg)) {
                        [pscustomobject]@{ Name=$installed[$pkg]; Pkg=$pkg; Favorite=$false; BuiltIn=$false }
                    }
                }
            )
            $all | Sort-Object Name, Pkg
        }
        $preferredIndex = -1
        $lb.BeginUpdate(); $lb.Items.Clear(); $shown.Clear()
        foreach ($entry in $entries) {
            $phoneName = [string]$installed[$entry.Pkg]
            if ($query -and $entry.Name.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
                $entry.Pkg.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
                $phoneName.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $index = $lb.Items.Add("$($entry.Name)   ·   $($entry.Pkg)")
            [void]$shown.Add($entry)
            if ($entry.Name -eq $preferredName -and $entry.Pkg -eq $preferredPackage) { $preferredIndex = $index }
        }
        $lb.EndUpdate()
        $hasApps = $shown.Count -gt 0
        if ($hasApps -and -not $ClearSelection) { $lb.SelectedIndex = [Math]::Max(0, $preferredIndex) }
        $lblEmpty.Visible = -not $hasApps
        $lblSortHint.Visible = $chkFavorites.Checked
        $lblStatus.Text = $appList.Current.Status
        if ($tt) { $tt.SetToolTip($lblStatus, $appList.Current.Detail) }
        & $syncButtons
    }
    & $fill
    $txt.Add_TextChanged({ & $fill })
    $chkFavorites.Add_CheckedChanged({
        $current = if ($lb.SelectedIndex -ge 0) { $shown[$lb.SelectedIndex] }
        & $fill $current.Name $current.Pkg
    })
    $lb.Add_SelectedIndexChanged($syncButtons)
    $btnRefresh.Add_Click({
        if (-not $btnRefresh.Enabled) { return }
        $current = if ($lb.SelectedIndex -ge 0) { $shown[$lb.SelectedIndex] }
        $btnRefresh.Enabled = $false
        try {
            $appList.Current = Read-PhoneAppList $dlg $serial -Refresh
            & $fill $current.Name $current.Pkg
        } finally { $btnRefresh.Enabled = $true }
    })

    $btnFavorite.Add_Click({
        if (-not $btnFavorite.Enabled) { return }
        $entry = $shown[$lb.SelectedIndex]
        $added = Add-AppFavorite $dlg $entry.Name $entry.Pkg -FromPhone
        if ($added) { $result.FavoritesChanged = $true; & $fill $added $entry.Pkg }
    })
    $btnRemove.Add_Click({
        if (-not $btnRemove.Enabled) { return }
        $entry = $shown[$lb.SelectedIndex]
        if ($entry.BuiltIn) { $script:hiddenBuiltInApps[$entry.Pkg] = $true }
        else {
            $script:customApps.Remove($entry.Name)
            [void]$script:appFavoriteOrder.Remove($entry.Id)
        }
        Save-Settings
        $result.FavoritesChanged = $true
        # 要先选中下一项再移除，避免连点时误删相邻的收藏。
        & $fill -ClearSelection
    })
    $btnManual.Add_Click({
        $name = Show-InputDialog $dlg '手动添加' '输入应用的显示名称，例如飞书。' ''
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        $pkg = Show-InputDialog $dlg '手动添加' '输入应用的完整包名，例如 com.ss.android.lark。' ''
        if ([string]::IsNullOrWhiteSpace($pkg)) { return }
        $pkg = $pkg.Trim()
        if ($pkg -notmatch '^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+$') {
            [void](Show-ResultDialog $dlg '手动添加' '请输入有效的包名' '例如 com.ss.android.lark。' '' @('ok'))
            return
        }
        $added = Add-AppFavorite $dlg $name.Trim() $pkg
        if ($added) { $result.FavoritesChanged = $true; & $fill $added $pkg }
    })

    $dragFormat = 'ScrcpyHelper.AppFavorite'
    $drag = @{ Start=$null; Source=$null; Index=-1 }
    $lb.Add_MouseDown({
        param($sender, $eventArgs)
        $drag.Source = $null
        if (-not $chkFavorites.Checked -or $eventArgs.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
        $index = $sender.IndexFromPoint($eventArgs.Location)
        if ($index -lt 0) { return }
        $drag.Start = $eventArgs.Location
        $drag.Source = $shown[$index].Id
        $drag.Index = $index
    })
    $lb.Add_MouseMove({
        param($sender, $eventArgs)
        if (-not $drag.Source -or $eventArgs.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
        $threshold = [System.Windows.Forms.SystemInformation]::DragSize
        if ([Math]::Abs($eventArgs.X - $drag.Start.X) -lt $threshold.Width / 2 -and
            [Math]::Abs($eventArgs.Y - $drag.Start.Y) -lt $threshold.Height / 2) { return }

        $data = New-Object System.Windows.Forms.DataObject
        $data.SetData($dragFormat, $false, $drag.Source)
        $drag.Source = $null
        $effect = $sender.DoDragDrop($data, [System.Windows.Forms.DragDropEffects]::Move)
        if ($effect -eq [System.Windows.Forms.DragDropEffects]::None -and $drag.Index -lt $shown.Count) {
            $sender.SelectedIndex = $drag.Index
        }
    })
    $getDropIndex = {
        param($sender, $eventArgs)
        if (-not $chkFavorites.Checked -or -not $eventArgs.Data.GetDataPresent($dragFormat, $false)) { return -1 }
        $point = $sender.PointToClient([System.Drawing.Point]::new($eventArgs.X, $eventArgs.Y))
        return $sender.IndexFromPoint($point)
    }
    $showDrop = {
        param($sender, $eventArgs)
        $index = & $getDropIndex $sender $eventArgs
        $eventArgs.Effect = [System.Windows.Forms.DragDropEffects]::None
        if ($index -ge 0) {
            $eventArgs.Effect = [System.Windows.Forms.DragDropEffects]::Move
            $sender.SelectedIndex = $index
        }
    }
    $lb.Add_DragEnter($showDrop)
    $lb.Add_DragOver($showDrop)
    $lb.Add_DragDrop({
        param($sender, $eventArgs)
        $index = & $getDropIndex $sender $eventArgs
        if ($index -lt 0) { return }
        $sourceId = [string]$eventArgs.Data.GetData($dragFormat, $false)
        $source = $shown | Where-Object { $_.Id -ceq $sourceId } | Select-Object -First 1
        if ($source -and (Move-AppFavorite $sourceId $shown[$index].Id)) {
            $result.FavoritesChanged = $true
            & $fill $source.Name $source.Pkg
        }
    })

    $pick = {
        if ($lb.SelectedIndex -lt 0) { return }
        $result.SelectedApp = $shown[$lb.SelectedIndex]
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
    }
    $btnGo.Add_Click($pick)
    $lb.Add_MouseDoubleClick({
        param($sender, $mouseEvent)
        $index = $sender.IndexFromPoint($mouseEvent.Location)
        if ($index -lt 0) { return }
        $sender.SelectedIndex = $index
        & $pick
    })
    $dlg.Controls.AddRange(@($lbl, $btnRefresh, $txt, $chkFavorites, $lblSortHint, $lblStatus, $lb, $lblEmpty, $btnGo, $btnFavorite, $btnRemove, $btnManual, $btnClose))
    $lblEmpty.BringToFront()
    $dlg.AcceptButton = $btnGo
    $dlg.CancelButton = $btnClose
    # 关闭时仍须刷新父窗的常用列表，因为增删操作已经保存。
    [void]$dlg.ShowDialog($owner)
    return $result
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
    $c1 = New-Caption '不填=自动。例 1080x2340' 150 47
    $e1 = New-ErrCaption 16 65
    $l2 = New-Lbl 'DPI：' 16 96
    $t2 = New-Txt 150 92 190
    $t2.Text = $dpi
    $c2 = New-Caption '不填=默认。常见 160~640' 150 122
    $e2 = New-ErrCaption 16 140
    $c3 = New-Caption '相同分辨率下，DPI 越大字越大。' 150 158
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
        Add-Content -LiteralPath $logPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Tag`r`n$Text`r`n" -Encoding UTF8 -ErrorAction Stop
        return $logPath
    } catch { return '' }
}

# ---------------- 结果窗：结论在前、出路给全、原始报错折进「查看原因」 ----------------
# 系统 MessageBox 是白底黑框，和助手的暖米色自绘窗两副面孔；按钮只有「确定」，失败时等于把人弹回起点重做。
# $Buttons 按主次顺序传（第一个是深色主按钮，最后一个兼作 Esc/取消），返回被点按钮的键。
function Show-ResultDialog {
    param($owner, $Title, $Heading, $Body, $Detail = '', $Buttons = @('ok'), [switch]$ExpandDetail, [switch]$CancelByDefault)
    $labels = @{ wait='继续等待'; force='强制结束'; ok = '确定'; continue = '继续'; retry = '重试'; ip = '输入 IP 连接'; exit = '仍然退出'; cancel = '取消' }
    $widths = @{ wait=96; force=96; ok = 96; continue = 96; retry = 96; ip = 112; exit = 96; cancel = 84 }
    # 正文按限宽量一次真实高度再定窗高：写死高度会在长文案时把最后一行裁掉
    $capFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
    $sz = [System.Windows.Forms.TextRenderer]::MeasureText([string]$Body, $capFont, (New-Object System.Drawing.Size(388, 0)), [System.Windows.Forms.TextFormatFlags]::WordBreak)
    $bodyH = [Math]::Max([int]$sz.Height, 18)
    $linkTop = 44 + $bodyH + 8
    $btnTop = $linkTop + $(if ($Detail) { 28 } else { 8 })
    if ($Detail -and $ExpandDetail) { $btnTop += 102 }
    $baseH = $btnTop + 50
    $d = New-Dialog $Title 420 $baseH $owner
    $lHead = New-Lbl $Heading 16 16
    $lHead.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5, [System.Drawing.FontStyle]::Bold)
    $lBody = New-Caption $Body 16 44
    $lBody.MaximumSize = New-Object System.Drawing.Size(388, 0)
    $link = $null; $txt = $null
    if ($Detail) {
        $link = New-Object System.Windows.Forms.LinkLabel
        $link.Text = if ($ExpandDetail) { '收起原因' } else { '查看原因' }
        $link.AutoSize = $true
        $link.Font = $capFont
        $link.LinkColor = $cMuted; $link.VisitedLinkColor = $cMuted; $link.LinkVisited = $true
        $link.Location = New-Object System.Drawing.Point(16, $linkTop)
        $txt = New-Object System.Windows.Forms.TextBox
        $txt.Multiline = $true; $txt.ReadOnly = $true; $txt.ScrollBars = 'Vertical'
        $txt.Text = $Detail; $txt.Visible = [bool]$ExpandDetail; $txt.TabStop = $false
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
    if ($CancelByDefault) { $d.AcceptButton = $d.CancelButton; $d.ActiveControl = $d.CancelButton }
    [void]$d.ShowDialog($owner)
    return [string]$d.Tag
}

function New-SegSwitch {
    param([string[]]$Labels, [string[]]$Values, [string]$Current, $x, $y, $w, $h, [scriptblock]$OnChange)
    $wrap = New-Object System.Windows.Forms.Panel
    $wrap.Location = New-Object System.Drawing.Point($x, $y)
    $wrap.Size = New-Object System.Drawing.Size($w, $h)
    $wrap.BackColor = $cSoft
    Enable-DoubleBuffer $wrap
    $st = @{ Index = [Math]::Max(0, [array]::IndexOf($Values, $Current)); Labels = $Labels; Values = $Values; HoverIdx = -1; OnChange = $OnChange }
    $wrap | Add-Member -NotePropertyName SegState -NotePropertyValue $st -Force
    $wrap.Add_Paint({
        param($p, $e)
        $st = $p.SegState; if (-not $st) { return }
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $parBg = if ($p.Parent) { $p.Parent.BackColor } else { $cWhite }
        $g.Clear($parBg)
        $s = $script:dpiScale
        $outer = New-RoundedPath 0.5 0.5 ($p.ClientSize.Width - 1.5) ($p.ClientSize.Height - 1.5) ([float](7 * $s))
        $ob = New-Object System.Drawing.SolidBrush($cSoft); $g.FillPath($ob, $outer); $ob.Dispose(); $outer.Dispose()

        $n = $st.Labels.Count
        if ($n -le 0) { return }
        $pad = [float](3 * $s)
        $gap = [float](3 * $s)
        $cw = ($p.ClientSize.Width - $pad * 2 - $gap * ($n - 1)) / [float]$n
        $ch = $p.ClientSize.Height - $pad * 2
        $fNorm = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
        $fBold = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
        $tf = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::SingleLine
        for ($i = 0; $i -lt $n; $i++) {
            $cx = $pad + $i * ($cw + $gap)
            $sel = ($i -eq $st.Index)
            if ($sel -or $i -eq $st.HoverIdx) {
                $cp = New-RoundedPath $cx $pad $cw $ch ([float](5 * $s))
                $cb = New-Object System.Drawing.SolidBrush($(if ($sel) { $cWhite } else { $cHover }))
                $g.FillPath($cb, $cp); $cb.Dispose()
                if ($sel) {
                    $cpen = New-Object System.Drawing.Pen($cLine, 1.0); $g.DrawPath($cpen, $cp); $cpen.Dispose()
                }
                $cp.Dispose()
            }
            $fg = if ($sel) { $cInk } else { $cText2 }
            $f = if ($sel) { $fBold } else { $fNorm }
            $tr = [System.Drawing.Rectangle]::new([int]$cx, [int]$pad, [int]$cw, [int]$ch)
            [System.Windows.Forms.TextRenderer]::DrawText($g, $st.Labels[$i], $f, $tr, $fg, $tf)
        }
        $fNorm.Dispose(); $fBold.Dispose()
    })
    $wrap.Cursor = [System.Windows.Forms.Cursors]::Hand
    $wrap.Add_MouseMove({
        param($p, $e)
        $st = $p.SegState; if (-not $st) { return }
        $n = $st.Labels.Count; if ($n -le 0) { return }
        $idx = [Math]::Max(0, [Math]::Min($n - 1, [int][Math]::Floor($e.X * $n / [Math]::Max(1, $p.ClientSize.Width))))
        if ($idx -ne $st.HoverIdx) { $st.HoverIdx = $idx; $p.Invalidate() }
    })
    $wrap.Add_MouseLeave({ $p = $args[0]; if ($p.SegState) { $p.SegState.HoverIdx = -1 }; $p.Invalidate() })
    $wrap.Add_MouseClick({
        param($p, $e)
        $st = $p.SegState; if (-not $st) { return }
        $n = $st.Labels.Count; if ($n -le 0) { return }
        $idx = [Math]::Max(0, [Math]::Min($n - 1, [int][Math]::Floor($e.X * $n / [Math]::Max(1, $p.ClientSize.Width))))
        if ($idx -ne $st.Index) {
            $st.Index = $idx; $p.Invalidate()
            if ($st.OnChange) { & $st.OnChange $st.Values[$idx] }
        }
    })
    return $wrap
}

# ---------------- 独立窗口：选 App ----------------
function Show-NewDisplay {
    param($owner, $serial)
    $useCards = [bool](Get-Command Set-CardStyle -ErrorAction SilentlyContinue)
    $useSeg = [bool](Get-Command New-SegSwitch -ErrorAction SilentlyContinue)
    $dlg = New-Dialog '独立窗口' 340 $(if ($useCards -and $useSeg) { 410 } else { 360 }) $owner
    $ndAudioState = @{ Val = $(if ($settings.ndAudio -in @('auto', 'on', 'off')) { [string]$settings.ndAudio } else { 'auto' }) }

    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.DropDownStyle = 'DropDownList'
    $cb.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $cb.DisplayMember = 'Label'
    $refreshApps = {
        param($picked)
        $current = if ($picked) { $picked } else { $cb.SelectedItem }
        $selectedIndex = -1
        $matchingTargetIndex = -1
        $cb.BeginUpdate()
        $cb.SelectedIndex = -1
        $cb.Items.Clear()
        foreach ($favorite in @(Get-AppFavorites)) {
            $name = $favorite.Name
            $pkg = $favorite.Pkg
            $label = if (-not $favorite.BuiltIn -and $apps.Contains($name)) { "$name ($pkg)" } else { $name }
            $item = [pscustomobject]@{ Name=$name; Target="+$pkg"; Label=$label; Temporary=$false }
            $index = $cb.Items.Add($item)
            if ($item.Target -eq $current.Target) {
                if ($matchingTargetIndex -lt 0) { $matchingTargetIndex = $index }
                if ($item.Name -eq $current.Name) { $selectedIndex = $index }
            }
        }
        if ($selectedIndex -lt 0 -and $current.Temporary) {
            if ($matchingTargetIndex -ge 0) {
                $selectedIndex = $matchingTargetIndex
            } else {
                if (@($cb.Items | Where-Object { $_.Label -eq $current.Label }).Count -gt 0) {
                    $current.Label = "$($current.Name) ($($current.Target.TrimStart('+')))"
                }
                $selectedIndex = $cb.Items.Add($current)
            }
        }
        if ($cb.Items.Count -gt 0) { $cb.SelectedIndex = [Math]::Max(0, $selectedIndex) }
        $cb.EndUpdate()
    }
    & $refreshApps

    $btnMore = New-LinkBtn '更多应用' 12 64 82
    $btnManual = New-LinkBtn '手动输入' 102 64 82
    $appActionState = @{ Busy=$false }
    $btnMore.Add_Click({
        if ($appActionState.Busy) { return }
        $appActionState.Busy = $true
        try {
            $picked = Show-AppPicker $dlg $serial
            $app = $picked.SelectedApp
            if ($app) {
                & $refreshApps ([pscustomobject]@{ Name=$app.Name; Target="+$($app.Pkg)"; Label=$app.Name; Temporary=$true })
            } elseif ($picked.FavoritesChanged) {
                & $refreshApps
            }
        } finally { $appActionState.Busy = $false }
    })
    $btnManual.Add_Click({
        if ($appActionState.Busy) { return }
        $name = Show-InputDialog $dlg '手动输入' "输入 App 名字（如 chrome）或完整包名（如 com.tencent.mm）。`n中文 App 建议用包名，更准确。" ''
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        $name = $name.Trim()
        $target = if ($name -match '\.') { "+$name" } else { "+?$name" }
        & $refreshApps ([pscustomobject]@{ Name=$name; Target=$target; Label=$name; Temporary=$true })
    })

    # 窗口比例/方向：微信、QQ 等手机应用在“横屏平板”虚拟屏上会用平板版面、显示不全，选「竖屏·手机」即用手机版面
    $customLabel = if ($settings.ndSize) { "自定义 $($settings.ndSize)" } else { '自定义…' }
    $cbMode = New-Combo @('竖屏·手机版面（推荐微信/QQ）', '横屏·平板版面', '跟随「设置」里的尺寸', $customLabel) @('portrait', 'landscape', 'settings', 'custom') $settings.ndMode 16 140 284

    if ($useCards -and $useSeg) {
        $cardApp = New-Object System.Windows.Forms.Panel
        $cardApp.Location = New-Object System.Drawing.Point(16, 12); $cardApp.Size = New-Object System.Drawing.Size(308, 100)
        Set-CardStyle $cardApp 10 $cWhite $cLine
        $lApp = New-Lbl '选择应用（需 Android 11+）' 12 10; $lApp.ForeColor = $cText2; $lApp.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
        $cb.Location = New-Object System.Drawing.Point(12, 34); $cb.Size = New-Object System.Drawing.Size(284, 28)
        foreach ($button in @($btnMore, $btnManual)) { $button.BackColor = $cWhite }
        $cardApp.Controls.AddRange(@($lApp, $cb, $btnMore, $btnManual))

        $cardMode = New-Object System.Windows.Forms.Panel
        $cardMode.Location = New-Object System.Drawing.Point(16, 122); $cardMode.Size = New-Object System.Drawing.Size(308, 96)
        Set-CardStyle $cardMode 10 $cWhite $cLine
        $lblMode = New-Lbl '窗口比例' 12 10; $lblMode.ForeColor = $cText2; $lblMode.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
        $cbMode.Location = New-Object System.Drawing.Point(12, 34); $cbMode.Size = New-Object System.Drawing.Size(284, 26)
        $chkFixed = New-Chk '固定分辨率（缩放窗体不改变排版）' $settings.ndFixed 12 66
        $cardMode.Controls.AddRange(@($lblMode, $cbMode, $chkFixed))

        $cardAudio = New-Object System.Windows.Forms.Panel
        $cardAudio.Location = New-Object System.Drawing.Point(16, 228); $cardAudio.Size = New-Object System.Drawing.Size(308, 72)
        Set-CardStyle $cardAudio 10 $cWhite $cLine
        $lblAudio = New-Lbl '此窗口的声音' 12 10; $lblAudio.ForeColor = $cText2; $lblAudio.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
        $segAudio = New-SegSwitch @('自动', '强制播放', '静音') @('auto', 'on', 'off') $ndAudioState.Val 12 33 284 30 ({
            param($val)
            $ndAudioState.Val = [string]$val
        }.GetNewClosure())
        $cardAudio.Controls.AddRange(@($lblAudio, $segAudio))

        $capMode = New-Caption "手机主屏可继续正常使用；应用双开 / 分身若黑屏，`n请改用普通投屏在手机上打开。" 16 308
        $capMode.MaximumSize = New-Object System.Drawing.Size(308, 0)
        $audioTt = '独立窗口播放手机的系统声音，需要 Android 11+。「自动」遵循声音总开关，并在已有窗口播放时静音。「强制播放」允许本窗口播放，即使总开关关闭。'
        if ($tt) { $tt.SetToolTip($segAudio, $audioTt); $tt.SetToolTip($lblAudio, $audioTt) }
        $btnGo = New-PrimaryBtn '打开独立窗口' 16 354 308 40 11
        $dlg.Controls.AddRange(@($cardApp, $cardMode, $cardAudio, $capMode, $btnGo))
    } else {
        $l1 = New-Lbl '在电脑上单开一块屏，运行下面这个 App：' 16 14
        $l2 = New-Lbl '需要 Android 11 或更新版本' 16 38; $l2.ForeColor = $cMuted
        $cb.Location = New-Object System.Drawing.Point(16, 64); $cb.Size = New-Object System.Drawing.Size(288, 28)
        $btnMore.Location = '16,96'; $btnManual.Location = '106,96'
        $lblMode = New-Lbl '窗口比例' 16 140
        $cbMode.Location = New-Object System.Drawing.Point(84, 137); $cbMode.Size = New-Object System.Drawing.Size(220, 26)
        $chkFixed = New-Chk '固定分辨率（窗口缩放时尺寸不变）' $settings.ndFixed 16 173
        $capMode = New-Caption "勾选「固定分辨率」后，拖动窗口边缘只改变电脑上的显示大小。`n应用分身若黑屏，请改用普通投屏，在手机上打开分身。" 16 197
        $capMode.MaximumSize = New-Object System.Drawing.Size(288, 0)
        $lblAudio = New-Lbl '声音' 16 265
        $cbAudio = New-Combo @('自动（同设备避免重音）', '播放（允许此窗口出声）', '静音（这扇窗不出声）') @('auto', 'on', 'off') $ndAudioState.Val 84 262 220
        $cbAudio.Add_SelectedIndexChanged({ $ndAudioState.Val = [string]$cbAudio.Vals[$cbAudio.SelectedIndex] }.GetNewClosure())
        $btnGo = New-PrimaryBtn '打开独立窗口' 16 304 288 38 11
        $dlg.Controls.AddRange(@($l1, $l2, $cb, $btnMore, $btnManual, $lblMode, $cbMode, $chkFixed, $capMode, $lblAudio, $cbAudio, $btnGo))
    }

    $btnGo.Enabled = $cb.SelectedIndex -ge 0
    $cb.Add_SelectedIndexChanged({ $btnGo.Enabled = $cb.SelectedIndex -ge 0 })

    # 空字符串是用户明确清空后的值，不能再用值的真假来判断是否确认过。
    $state = @{ Target = $null; Label = $null; CustomSize = $null; CustomDpi = $null; CustomConfirmed=$false }
    $btnGo.Add_Click({
        if ($appActionState.Busy) { return }
        $appActionState.Busy = $true
        try {
            $selectedApp = $cb.SelectedItem
            if (-not $selectedApp) { return }
            $ndModeSel = [string]$cbMode.Vals[$cbMode.SelectedIndex]
            if ($ndModeSel -eq 'custom') {
                $askSize = if ($state.CustomConfirmed) { [string]$state.CustomSize } else { [string]$settings.ndSize }
                $askDpi = if ($state.CustomConfirmed) { [string]$state.CustomDpi } else { [string]$settings.ndDpi }
                $ask = Show-CustomDisplaySize $dlg $askSize $askDpi
                if (-not $ask) { return }   # 取消：留在独立窗口面板，比例/声音不丢
                $state.CustomSize = [string]$ask.Size; $state.CustomDpi = [string]$ask.Dpi
                $state.CustomConfirmed=$true
                $i = $cbMode.SelectedIndex
                $cbMode.Items[3] = $(if ($ask.Size) { "自定义 $($ask.Size)" } else { '自定义…' })
                $cbMode.SelectedIndex = $i
            }
            $state.Label = $selectedApp.Name
            $state.Target = $selectedApp.Target
            $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Close()
        } finally { $appActionState.Busy = $false }
    })
    $dlg.AcceptButton = $btnGo
    New-EscCancel $dlg
    if ($dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) {
        $target = [string]$state.Target
        $appLabel = [string]$state.Label
        if (-not $target) { return }
        $ndModeSel = [string]$cbMode.Vals[$cbMode.SelectedIndex]
        $ndSz = $settings.ndSize; $ndDpi = $settings.ndDpi
        switch ($ndModeSel) {
            'portrait'  {
                $disp = Get-DeviceDisplay $serial
                if ($disp.Cancelled) { return }
                if ($disp) {
                    $w = [Math]::Min($disp.W, $disp.H); $h = [Math]::Max($disp.W, $disp.H)
                    $d = if ($disp.Dpi -gt 0) { $disp.Dpi } else { 420 }
                } else { $w = 1080; $h = 2340; $d = 420 }
                $ndSz = "${w}x${h}"; $ndDpi = "$d"
            }
            'landscape' { $ndSz = '1920x1080'; $ndDpi = '240' }
            'custom'    {
                if ($state.CustomConfirmed) { $ndSz = [string]$state.CustomSize; $ndDpi = [string]$state.CustomDpi }
            }
        }
        $audioSel = [string]$ndAudioState.Val
        $effAudio = if (-not $settings.audioOn -and $audioSel -eq 'auto') { 'off' } else { $audioSel }
        if ($ndModeSel -eq 'custom' -and $state.CustomConfirmed) {
            $settings.ndSize = [string]$state.CustomSize; $settings.ndDpi = [string]$state.CustomDpi
        }
        $settings.ndMode = $ndModeSel; $settings.ndFixed = $chkFixed.Checked; $settings.ndAudio = $audioSel; Save-Settings
        $pre = if ($serial) { @('-s', $serial) } else { @() }
        $friendly = if ($serial) { Get-FriendlyName $serial } else { '' }
        $winLabel = (@($friendly, $appLabel) | Where-Object { $_ }) -join ' · '
        $winLabel = ($winLabel -replace '[\r\n\x00-\x1F"]', ' ').Trim()
        $titleArg = if ($winLabel) { @("--window-title=$winLabel") } else { @() }
        Start-Scrcpy ($pre + @(Get-DisplayCompatibilityArgs) + @(Get-NewDisplayArgs $ndSz $ndDpi $chkFixed.Checked $settings.ndNoDecor) + $titleArg + "--start-app=$target") -AudioMode $effAudio
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

    $lblNote = New-Lbl '配对后会尝试自动查找连接端口。' 16 176; $lblNote.ForeColor = $cMuted

    $btnGo = New-PrimaryBtn '配对并连接' 16 206 328 38 11
    $result = @{ addr = $null }
    $connectionFlow=@{ Busy=$false }
    $btnGo.Add_Click({ Invoke-MainFlow ({
        $pairAddr = $txtPair.Text.Trim()
        $code = $txtCode.Text.Trim()
        if ($pairAddr -notmatch '^(\d{1,3}(\.\d{1,3}){3}):\d+$') { [System.Windows.Forms.MessageBox]::Show('配对地址格式应为 IP:端口，例如 192.168.1.5:37123。', '配对') | Out-Null; return }
        $ip = $matches[1]
        if ($code -notmatch '^\d{6}$') { [System.Windows.Forms.MessageBox]::Show('配对码应为 6 位数字。', '配对') | Out-Null; return }
        $discovery=Wait-UiTask -Owner $dlg -StatusText '正在配对并连接手机…' -Functions @('Invoke-PairDiscovery','Test-CommandSuccess','Get-CommandDetail') -Inputs @{
            Adb=$adb; PairAddress=$pairAddr; Code=$code; Ip=$ip
        } -Work { Invoke-PairDiscovery $Inputs.Adb $Inputs.PairAddress $Inputs.Code $Inputs.Ip $Control }
        if ($discovery.Cancelled) { return }
        if (-not $discovery.Paired) {
            [void](Show-ResultDialog $dlg '用配对码连接' '配对失败' '请确认手机与电脑在同一 Wi-Fi。重新打开手机的配对码弹窗，填入新的地址和 6 位配对码。' $discovery.Error @('ok'))
            return
        }
        $connAddr=$discovery.Address
        # 自动没找到（mdns 不可用等）：退一步问端口号
        if (-not $connAddr) {
            $port = Show-InputDialog $dlg '用配对码连接' "已配对。请手动填写连接端口。`n在手机「无线调试」主界面的「IP 地址和端口」里，填入冒号后的数字。" ''
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
            [void](Show-ResultDialog $dlg '用配对码连接' "已配对成功，但连接 $connAddr 失败" '到手机「无线调试」主界面核对 IP 和连接端口，再用「输入 IP 连接」重试。' $(if ($record) { $record.Error } else { $connection.Error }) @('ok'))
        }
    }) $dlg $connectionFlow })
    $dlg.Controls.AddRange(@($l1, $l2, $l3, $txtPair, $l4, $txtCode, $lblNote, $btnGo))
    $dlg.AcceptButton = $btnGo
    New-EscCancel $dlg
    [void]$dlg.ShowDialog($owner)
    return $result.addr
}

# ---------------- 快捷键速查（键帽分组卡片） ----------------
# 内容依据 scrcpy 官方 doc/shortcuts.md；官方写作 MOD（默认 = 左 Alt 或左 Super），界面按用户口径统一叫 Alt。
function Show-Shortcuts {
    param($owner)
    $dlg = New-Dialog '快捷键速查' 420 470 $owner

    $tip = New-Object System.Windows.Forms.Panel
    $tip.Location = New-Object System.Drawing.Point(16, 12); $tip.Size = New-Object System.Drawing.Size(388, 32)
    Set-CardStyle $tip 7 $cSoft $cSoft
    $lblTip = New-Lbl '以下 Alt 均指 左 Alt 或 左 Win 键（两者通用）' 12 7
    $lblTip.ForeColor = $cText2; $lblTip.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
    $tip.Controls.Add($lblTip)

    $scroll = New-Object System.Windows.Forms.Panel
    $scroll.Location = New-Object System.Drawing.Point(16, 52); $scroll.Size = New-Object System.Drawing.Size(388, 354)
    $scroll.AutoScroll = $true; $scroll.BackColor = $cPaper
    Enable-DoubleBuffer $scroll

    $groups = @(
        @{ Title = '窗口与显示'; Rows = @(
            @('全屏 / 退出全屏', 'Alt + F / F11'),
            @('退出投屏窗口', 'Alt + Q'),
            @('消除黑边', 'Alt + W / 双击'),
            @('显示帧率', 'Alt + I')
        ) },
        @{ Title = '手机操控'; Rows = @(
            @('回到桌面', 'Alt + H / 中键'),
            @('返回上一页', 'Alt + B / 右键'),
            @('实体鼠标模式快捷键', 'Shift + 中/右键'),
            @('多任务 / 菜单', 'Alt + S / Alt + M'),
            @('音量 加 / 减', 'Alt + ↑ / ↓'),
            @('锁屏 / 点亮 · 息屏继续投', 'Alt + P · Alt + O'),
            @('唤醒并点亮手机屏幕', 'Alt + Shift + O'),
            @('通知栏 展开 / 收起', 'Alt + N / Shift+N'),
            @('复制到电脑 / 粘贴到手机', 'Alt + C / Alt + V')
        ) },
        @{ Title = '旋转与暂停'; Rows = @(
            @('旋转手机屏幕', 'Alt + R'),
            @('旋转投屏画面', 'Alt + ← / →'),
            @('暂停 / 恢复画面', 'Alt + Z / Shift+Z')
        ) },
        @{ Title = '拖拽与摄像头'; Rows = @(
            @('安装 APK / 传至 Download', '拖入投屏窗口'),
            @('摄像头补光灯 开 / 关', 'Alt + T / Shift+T'),
            @('摄像头实时变焦', 'Alt + ↑ / ↓')
        ) }
    )

    $y = 0
    $fTitle = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5, [System.Drawing.FontStyle]::Bold)
    $fRow   = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $fKbd   = New-Object System.Drawing.Font('Consolas', 8.5, [System.Drawing.FontStyle]::Bold)
    foreach ($g in $groups) {
        $rows = $g.Rows
        $cardH = 30 + $rows.Count * 28 + 8
        $card = New-Object System.Windows.Forms.Panel
        $card.Location = New-Object System.Drawing.Point(0, $y); $card.Size = New-Object System.Drawing.Size(370, $cardH)
        Set-CardStyle $card 10 $cWhite $cLine
        $gt = New-Object System.Windows.Forms.Label
        $gt.Text = $g.Title; $gt.AutoSize = $true; $gt.Location = New-Object System.Drawing.Point(12, 9)
        $gt.Font = $fTitle; $gt.ForeColor = $cRed
        $card.Controls.Add($gt)
        $ry = 30
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $pair = $rows[$i]
            $act = New-Object System.Windows.Forms.Label
            $act.Text = $pair[0]; $act.AutoSize = $false
            $act.Location = New-Object System.Drawing.Point(12, ($ry + 4)); $act.Size = New-Object System.Drawing.Size(196, 20)
            $act.Font = $fRow; $act.ForeColor = $cInk
            $kbd = New-Object System.Windows.Forms.Label
            $kbd.Text = $pair[1]; $kbd.AutoSize = $false
            $kbd.Location = New-Object System.Drawing.Point(212, ($ry + 2)); $kbd.Size = New-Object System.Drawing.Size(146, 22)
            $kbd.TextAlign = 'MiddleCenter'; $kbd.Font = $fKbd; $kbd.ForeColor = $cInk; $kbd.BackColor = $cPaper
            $kbd.Add_Paint({
                param($lbl, $e)
                $gr = $e.Graphics; $gr.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
                $gr.Clear($cWhite)
                $kp = New-RoundedPath 0.5 0.5 ($lbl.ClientSize.Width - 1.5) ($lbl.ClientSize.Height - 1.5) ([float](5 * $script:dpiScale))
                $kb = New-Object System.Drawing.SolidBrush($cPaper); $gr.FillPath($kb, $kp); $kb.Dispose()
                $kpen = New-Object System.Drawing.Pen($cLineStrong, 1.0); $gr.DrawPath($kpen, $kp); $kpen.Dispose(); $kp.Dispose()
                $tf = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::SingleLine
                [System.Windows.Forms.TextRenderer]::DrawText($gr, $lbl.Text, $lbl.Font, $lbl.ClientRectangle, $lbl.ForeColor, $tf)
            })
            $card.Controls.AddRange(@($act, $kbd))
            if ($i -lt ($rows.Count - 1)) {
                $sep = New-Object System.Windows.Forms.Panel
                $sep.Location = New-Object System.Drawing.Point(12, ($ry + 27)); $sep.Size = New-Object System.Drawing.Size(346, 1)
                $sep.BackColor = $cSoft
                $card.Controls.Add($sep)
            }
            $ry += 28
        }
        $scroll.Controls.Add($card)
        $y += $cardH + 10
    }

    $btnClose = New-PrimaryBtn '知道了' 16 420 388 36 10
    $btnClose.Add_Click({ $dlg.Close() })
    $dlg.Controls.AddRange(@($tip, $scroll, $btnClose))
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

function Start-WirelessMirror {
    param($Owner, [string]$Serial)
    if (-not (Test-Wireless $Serial)) {
        $connection = Wait-UiTask -Owner $Owner -StatusText '正在将手机切换到无线连接…' -Functions @(
            'Invoke-UsbWirelessConnection','Invoke-ConnectDevices','Test-CommandSuccess','Get-CommandDetail','Get-AdbDeviceState'
        ) -Inputs @{ Adb = $adb; Serial = $Serial } -Work {
            Invoke-UsbWirelessConnection $Inputs.Adb $Inputs.Serial $Control
        }
        if ($connection.Cancelled) { return }
        $address = $connection.Address
        if (-not $address) {
            [void](Show-ResultDialog $Owner '无线投屏' '无线连接失败' '先别拔线。确认手机已允许 USB 调试，并和电脑连着同一个 Wi-Fi。可点「查看原因」看详情。' $connection.Error @('ok'))
            return
        }
        $name = Get-FriendlyName $address -CachedOnly
        if ($name -eq $address) {
            $usbName = Get-FriendlyName $Serial -CachedOnly
            if ($usbName -ne $Serial) { $name = $usbName }
        }
        if ($settings.lastWirelessAddr -ne $address) { $settings.lastWirelessAddr = $address; Save-Settings }
        Touch-KnownDevice $address $name
        $Serial = $address
    }
    # 进程登记和设备管理共用 adb devices 中已确认的无线序列号。
    Start-Scrcpy (@('-s', $Serial) + (Get-MirrorArgs -Wireless:$true))
}

# 启动和主功能共用排除名单。默认和上次设备只有在允许自动连接时才优先尝试。
function Get-AutoConnectCandidates {
    param([int]$Max = [int]::MaxValue)
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
    Start-DeviceScan -Owner $form -Candidates $cands -ConnectAlways $true -Kind 'startup' -OnDone $OnDone
}
$script:reconnectState = @{ InFlight = $false }
function Reconnect-LastAsync {
    param($addr, [scriptblock]$OnDone)
    if (-not $addr -or $script:reconnectState.InFlight -or (Test-AutoConnectExcluded $addr)) { return }
    $flag = $script:reconnectState
    $flag.InFlight = $true
    Start-DeviceScan -Owner $form -Candidates @($addr) -Kind 'reconnect' -OnDone $OnDone -OnFinally ({ $flag.InFlight = $false }.GetNewClosure())
}

# 多设备时让用户挑一台投屏，返回序列号 / 地址，取消返回 $null。
function Select-Device {
    param($owner, $devs, $title = '选择设备', $Prompt = '检测到多台设备，选择要投屏的一台：', $ButtonText = '投屏这台', [string]$SelectedSerial)
    $dlg = New-Dialog $title 340 296 $owner
    $lbl = New-Lbl $Prompt 16 14
    $lb = New-Object System.Windows.Forms.ListBox
    $lb.Location = '16,42'; $lb.Size = '308,160'
    $lb.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    foreach ($s in $devs) {
        $tp = if (Test-Wireless $s) { '无线' } else { 'USB' }
        [void]$lb.Items.Add("$(Get-FriendlyName $s)   ·   $tp   ·   $s")
    }
    if ($lb.Items.Count -gt 0) {
        $lb.SelectedIndex = [Math]::Max(0, [array]::IndexOf(@($devs), $SelectedSerial))
    }
    $btnGo = New-PrimaryBtn $ButtonText 16 218 308 34 10
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
    Start-DeviceScan -Owner $owner -Candidates @(Get-AutoConnectCandidates) -Kind 'ensure' -OnDone $OnDone -OnFinally $OnFinally
}

function Resolve-Target {
    param($owner, [string]$Prefer = '', [string[]]$Devices=@())
    $devs=@($Devices)
    if ($devs.Count -eq 0) { return @{ Ok = $false; Reason = 'none'; Serial = $null } }
    if ($devs.Count -eq 1) { return @{ Ok = $true; Serial = $devs[0] } }
    if ($script:uiState -and $script:uiState.SelectedSerial -and ($devs -contains $script:uiState.SelectedSerial)) { return @{ Ok = $true; Serial = $script:uiState.SelectedSerial } }
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
    if ($script:uiState -and $script:uiState.SelectedSerial -and ($eligible -contains $script:uiState.SelectedSerial)) { return $script:uiState.SelectedSerial }
    if ($settings.defaultDevice -and ($eligible -contains $settings.defaultDevice)) { return $settings.defaultDevice }
    return (Select-Device $owner $eligible "$Feature · 选择设备")
}

# ---------------- 无线：输入 IP 直连（保底连法，不限系统版本；无需配对码） ----------------
# 只要手机已开启网络 adb（Android 11+ 的「无线调试」，或更早系统 tcpip 过一次），给个 IP 就能连。
# 成功返回连接地址（ip:port）并自动记住，失败/取消返回 $null。
function Connect-ByIp {
    param($owner)
    $dlg = New-Dialog '输入 IP 连接' 360 182 $owner
    $l1 = New-Lbl '已配对：填「无线调试」主页的 IP 和连接端口。' 16 14; $l1.ForeColor = $cMuted
    $l2 = New-Lbl '插线转无线：填手机的 Wi-Fi IP，端口通常为 5555。' 16 36; $l2.ForeColor = $cMuted
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
        if ($port -notmatch '^\d+$') { [System.Windows.Forms.MessageBox]::Show('请填写手机显示的连接端口。插线转无线通常用 5555。', '输入 IP 连接') | Out-Null; return }
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
                '手机还没允许这台电脑连接。插线的手机请解锁并确认授权。用配对码连过的手机，请在「无线调试」里检查这台电脑是否还在配对列表中。'
            } else {
                '手机暂时没有回应。请确认手机和电脑连着同一个 Wi-Fi，核对连接端口后再试。'
            }
            [void](Show-ResultDialog $owner '输入 IP 连接' "连不上 $addr" $body $out @('ok'))
        } elseif ($state -eq '') {
            [void](Show-ResultDialog $owner '输入 IP 连接' "连不上 $addr" '这个地址连不上手机。请到手机的「无线调试」核对 IP 和端口，并确认手机与电脑连着同一个 Wi-Fi。首次连接请先配对或用数据线。' $out @('ok'))
        } else {
            [void](Show-ResultDialog $owner '输入 IP 连接' "连不上 $addr" '暂时无法确认手机是否连上，请稍后重试。' $out @('ok'))
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
    $dlg = New-Dialog '设备管理' 552 422 $owner

    $lvWrap = New-Object System.Windows.Forms.Panel
    $lvWrap.Location = New-Object System.Drawing.Point(16, 14)
    $lvWrap.Size = New-Object System.Drawing.Size(520, 198)
    Set-CardStyle $lvWrap 10 $cWhite $cLine

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location = New-Object System.Drawing.Point(4, 4); $lv.Size = New-Object System.Drawing.Size(512, 190)
    $lv.BorderStyle = 'None'
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $true; $lv.HideSelection = $false
    $lv.HeaderStyle = 'Nonclickable'; $lv.BackColor = $cWhite
    $lv.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    # 透明占位图拉高行距，视觉更舒展
    $rowSpacer = New-Object System.Windows.Forms.ImageList
    $rowSpacer.ImageSize = New-Object System.Drawing.Size(1, 28)
    $lv.SmallImageList = $rowSpacer
    # 空态提示放列表下方常驻一行：ListView 的行文字只占第一列宽，长指引会被截没
    $noDeviceHint = '还没有设备？点下方「+ 输入 IP 连接…」添加，或回主界面点「无线连接…」'
    $capNoDev = New-Caption $noDeviceHint 16 218
    $capNoDev.Visible = $false
    [void]$lv.Columns.Add('设备', 156)
    [void]$lv.Columns.Add('地址', 132)
    [void]$lv.Columns.Add('类型 · 系统', 214)   # 这栏要装下「无线 · Android 13  ▶ 投屏中  ⊘ 不自动连」，给它最宽，别截断
    $grpConn  = New-Object System.Windows.Forms.ListViewGroup -ArgumentList '已连接'
    $grpKnown = New-Object System.Windows.Forms.ListViewGroup -ArgumentList '已记住（未连接）'
    [void]$lv.Groups.Add($grpConn)   # 逐个加：AddRange 收 PS 的 Object[] 会因类型转换失败
    [void]$lv.Groups.Add($grpKnown)
    $lvWrap.Controls.Add($lv)

    # 第一组「投屏」：主次动作分层，常用投屏/停止放前排
    $btnCast    = New-PrimaryBtn   '▶ 投屏'     16  246 92  34 9.5
    $btnStop    = New-SecondaryBtn '■ 停止投屏' 116 246 104 34
    $btnStop.ForeColor = $cRed
    $btnConnect = New-SecondaryBtn '连接'       228 246 84  34
    $btnAll     = New-SecondaryBtn '全部投屏'   444 246 92  34

    $lineMid = New-Object System.Windows.Forms.Panel; $lineMid.Size = New-Object System.Drawing.Size(520, 1); $lineMid.Location = New-Object System.Drawing.Point(16, 290); $lineMid.BackColor = $cLine

    # 第二组「管理」：对单台设备的配置项
    $btnDefault = New-SecondaryBtn '设为默认' 16  300 96  32
    $btnRename  = New-SecondaryBtn '重命名'   120 300 92  32
    $btnDisc    = New-SecondaryBtn '断开'     220 300 84  32
    $btnAuto    = New-SecondaryBtn '不自动连' 312 300 104 32
    $btnForget  = New-SecondaryBtn '忘记'     424 300 112 32
    $btnForget.ForeColor = $cRed

    $line2 = New-Object System.Windows.Forms.Panel; $line2.Size = New-Object System.Drawing.Size(520, 1); $line2.Location = New-Object System.Drawing.Point(16, 344); $line2.BackColor = $cLine

    # 第三组「全局」
    $btnIp       = New-SecondaryBtn '+ 输入 IP 连接…' 16  356 156 36
    $btnRefresh2 = New-SecondaryBtn '刷新'            348 356 88  36
    $btnDone     = New-PrimaryBtn   '完成'            444 356 92  36 10
    $tt.SetToolTip($btnConnect, '连接选中的已记住设备。连好后点「投屏」打开窗口。')
    $tt.SetToolTip($btnCast, '为选中的已连设备开一个镜像窗口。')
    $tt.SetToolTip($btnStop, '停止所选设备的投屏、录屏（含后台录制）和摄像头。')
    $tt.SetToolTip($btnAll, '给每台已连接、还没开窗的设备各开一个窗口。')
    $tt.SetToolTip($btnDefault, '这台设备在功能的候选列表中时优先使用。再点一次取消默认。')
    $tt.SetToolTip($btnDisc, '断开这台的无线连接，并先关掉它的投屏窗口（其它设备不受影响）。它仍留在「已记住」里。要让助手跳过这台设备的自动连接，请用「不自动连」。USB 设备请直接拔数据线。')
    $tt.SetToolTip($btnRename, '起个好认的名字，窗口标题和设备列表都会用。')
    $tt.SetToolTip($btnForget, '从「已记住」里去掉，这台设备的自定义名字和「默认设备」标记也一并清掉；以后连上会重新记住。设备还连着时点不动——要先「断开」（或拔掉数据线），否则它会立刻被重新记住。')
    $tt.SetToolTip($btnAuto, '开启「不自动连」后，助手会跳过这台手机。已经配对的手机仍可能自己连上。要取消配对，请在手机的「无线调试」里忘记这台电脑。')

    # refresh 把「已连接设备」「正在投屏的序列号」算一次塞进 $state；updateButtons 只读它，不再每次点都跑 adb
    $state = @{ Active = @(); Connected = @(); SnapshotReady=$false }

    # 按选中项启用/禁用：连接=有选中的未连设备；投屏=有选中的已连且未在投；停止=有选中的在投；管理类仅单选有效
    $updateButtons = {
        $items = @($lv.SelectedItems | Where-Object { $_.Tag })
        $one = if ($items.Count -eq 1) { $items[0].Tag } else { $null }
        $ready = $state.SnapshotReady
        # ADB 读不到时仍可停止正在运行的本地进程。
        $active = @(if ($ready) { $state.Active } else { Get-ActiveSerials })
        $btnConnect.Enabled = $ready -and @($items | Where-Object { -not $_.Tag.Connected }).Count -gt 0
        $btnCast.Enabled    = $ready -and @($items | Where-Object { $_.Tag.Connected -and ($active -notcontains $_.Tag.Serial) }).Count -gt 0
        $btnStop.Enabled    = @($items | Where-Object { $active -contains $_.Tag.Serial }).Count -gt 0
        $btnAll.Enabled     = $ready -and @($state.Connected | Where-Object { $active -notcontains $_ }).Count -gt 0
        # 设为默认 ↔ 取消默认：选中的就是当前默认时，按钮变「取消默认」，让人知道再点是取消
        if ($ready -and $one -and $one.Connected) {
            $btnDefault.Enabled = $true
            $btnDefault.Text = if ($settings.defaultDevice -eq $one.Serial) { '取消默认' } else { '设为默认' }
        } else {
            $btnDefault.Enabled = $false; $btnDefault.Text = '设为默认'
        }
        $btnDisc.Enabled    = [bool]($ready -and $one -and $one.Connected -and $one.Wireless)
        $btnRename.Enabled  = [bool]$one
        $btnForget.Enabled  = [bool]($ready -and $one -and -not $one.Connected)
        if ($one -and $one.Wireless) {
            $btnAuto.Enabled = $true
            $btnAuto.Text = if (Test-AutoConnectExcluded $one.Serial) { '恢复自动连' } else { '不自动连' }
        } else { $btnAuto.Enabled = $false; $btnAuto.Text = '不自动连' }
    }
    $refresh = {
        $state.SnapshotReady=$false
        & $updateButtons
        $snapshot=Wait-DeviceScan $dlg
        if ($snapshot.Cancelled -or -not $snapshot.Success) {
            $capNoDev.Text = '连接状态待确认，请点击「刷新」重试。'
            $capNoDev.Visible = $true
            foreach ($it in $lv.Items) { $it.ForeColor = $cMuted }
            if (-not $snapshot.Cancelled) {
                [void](Show-ResultDialog $dlg '设备管理' '无法读取设备列表' '请稍后重试。' $snapshot.Error @('ok'))
            }
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
        $capNoDev.Text = $noDeviceHint
        $capNoDev.Visible = ($lv.Items.Count -eq 1 -and $lv.Items[0].Text -eq '（还没有设备）')
        foreach ($it in $lv.Items) { if ($it.Tag -and ($selSerials -contains $it.Tag.Serial)) { $it.Selected = $true } }   # 还原选中
        $lv.EndUpdate()
        $state.SnapshotReady=$true
        & $updateButtons
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
        if ($fail) { [void](Show-ResultDialog $dlg '设备管理' ("有 " + $fail.Count + " 台没连上") '请确认手机与电脑在同一 Wi-Fi，并核对已记住的地址。地址已变时，用「输入 IP 连接」填手机当前地址。' ($fail -join "`r`n") @('ok')) }
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
        if (-not $state.SnapshotReady) { return }
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
        $name = Show-InputDialog $dlg '重命名设备' '给这台设备起个名字（如 客厅电视）：' (Get-FriendlyName $s -CachedOnly)
        if ($null -eq $name) { return }
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

    $dlg.Controls.AddRange(@($lvWrap, $capNoDev, $lineMid, $line2,
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
# 19) 覆盖授权仅记录确认框出现前已存在的具体目标路径，避免给整批或树形合并中新出现的冲突文件顺带授权；
#     若下载或合并中途产生新冲突，会二次弹窗确认。
# 20) 保存根目录通过句柄或 Target 解析实际物理路径，允许用户选择目录联接作为保存位置，但实际写入路径
#     中的链接和上传目标链接仍逐级拦截；合并文件夹时仅跳过确认框列出的冲突子项，其余非冲突文件继续保存。

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
    # 空格可能属于设备目录名，内部路径只归一化分隔符和方向段。
    $t = [string]$p
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

# 简单 shell 调用方需要同时看到标准输出和诊断。目录清单直接用 Invoke-FmShell 读取各自的结果。
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
    # 读取失败由命令结果和目录协议判定，文件名可以包含与 ADB 诊断相同的字样。
    foreach ($template in @($fmListTemplate, $fmListTemplateLegacy)) {
        $shell = Invoke-FmShell $Owner $serial ($template.Replace('__PATH__', $q))
        if (-not $shell.Ok) { break }
        $listing = Fm-ParseListLines $shell.Lines $path
        if (-not $listing.NeedLegacy) { return $listing }
    }
    return @{ Ok = $false; Items = @(); Hidden = 0; NeedLegacy = $false }
}

# 完整路径可滚动查看，授权只覆盖这份清单里的文件。
function Fm-ConfirmOverwrite {
    param($owner, [string]$action, [string[]]$names, [string]$where)
    $dialog = New-Dialog '发现同名文件' 480 300 $owner
    try {
        $heading = New-Lbl "$action · 发现 $($names.Count) 个同名项" 16 14
        $location = New-Txt 16 42 448
        $location.ReadOnly = $true
        $location.Text = $where
        $list = New-Object System.Windows.Forms.TextBox
        $list.Location = '16,80'; $list.Size = '448,124'
        $list.Multiline = $true; $list.ReadOnly = $true; $list.ScrollBars = 'Vertical'
        $list.Text = $names -join [Environment]::NewLine
        $caption = New-Caption '仅覆盖或跳过列出的冲突项，其余文件继续传输。覆盖后无法恢复。' 16 214
        $yes = New-SecondaryBtn '覆盖' 160 250 96 34
        $no = New-SecondaryBtn '跳过' 264 250 96 34
        $cancel = New-SecondaryBtn '取消' 368 250 96 34
        $yes.DialogResult = 'Yes'; $no.DialogResult = 'No'; $cancel.DialogResult = 'Cancel'
        $dialog.Controls.AddRange(@($heading, $location, $list, $caption, $yes, $no, $cancel))
        $dialog.AcceptButton = $cancel; $dialog.CancelButton = $cancel
        $dialog.ActiveControl = $cancel
        $result = $dialog.ShowDialog($owner)
        if ($result -eq 'Yes') { return 'overwrite' }
        if ($result -eq 'No') { return 'skip' }
        return 'cancel'
    } finally { $dialog.Dispose() }
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
# 在受限环境或特定 Windows 权限配置下，PowerShell 5.1 的 Add-Type/csc 可能会抛出权限异常；
# 用 try/catch 保护并提供 Target 解析兜底，避免非管理员或管控环境在下载选目录时直接报错中断。
function Get-FmSaveRoot {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not ('Native.FmPath' -as [type])) {
        try {
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
        } catch {}
    }
    if ('Native.FmPath' -as [type]) {
        try {
            $root = [Native.FmPath]::Resolve($full)
            Assert-FmLocalPath $root
            return $root
        } catch {}
    }
    $curr = $full
    while ($true) {
        $item = Get-Item -LiteralPath $curr -Force -ErrorAction SilentlyContinue
        if ($item -and $item.Target) {
            $target = [string]($item.Target | Select-Object -First 1)
            if ($target) {
                $curr = [IO.Path]::GetFullPath($target)
                continue
            }
        }
        break
    }
    Assert-FmLocalPath $curr
    return $curr
}
function Test-FmOverwrite {
    param($Approved, [string]$Path)
    if ($Approved -is [bool]) { return $Approved }
    return ($null -ne $Approved -and $Approved.ContainsKey([IO.Path]::GetFullPath($Path)))
}
# 授权只记录确认框出现之前实际存在的路径，避免给整批中新出现的目标顺带授权。
function Get-FmExistingTargets {
    param([string]$Path, $Control, [bool]$SourceIsDir)
    if ($Control -and $Control.Cancelled) { throw '操作已取消' }
    Assert-FmLocalPath $Path
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $target = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($SourceIsDir -and $target.PSIsContainer) { return @() }
    return @([IO.Path]::GetFullPath($Path))
}
function Get-FmUnapprovedTargets {
    param([string]$From, [string]$To, $Approved, $Control, $Skipped)
    if ($Control -and $Control.Cancelled) { throw '操作已取消' }
    if ($Skipped.ContainsKey([IO.Path]::GetFullPath($To))) { return @() }
    Assert-FmLocalPath $From
    $sourceIsDir = (Get-Item -LiteralPath $From -Force -ErrorAction Stop).PSIsContainer
    $existing = @(Get-FmExistingTargets $To $Control $sourceIsDir)
    if ($existing.Count) {
        if (-not (Test-FmOverwrite $Approved $To)) { return @($existing) }
        return @()
    }
    if ($sourceIsDir) {
        foreach ($child in @(Get-ChildItem -LiteralPath $From -Force -ErrorAction Stop)) {
            Get-FmUnapprovedTargets $child.FullName (Join-Path $To $child.Name) $Approved $Control $Skipped
        }
    }
}
function Get-FmTargetPaths {
    param($Owner, [string]$Path, [string]$From = '', $Approved = @{}, [hashtable]$Paths = @{}, $Skipped = @{})
    return (Invoke-FmTask $Owner -Functions @('Get-FmExistingTargets','Get-FmUnapprovedTargets','Test-FmOverwrite','Assert-FmLocalPath') -Inputs @{ Path=$Path; From=$From; Approved=$Approved; Paths=$Paths; Skipped=$Skipped } -Work {
        try {
            $paths = @(if ($Inputs.From) { Get-FmUnapprovedTargets $Inputs.From $Inputs.Path $Inputs.Approved $Control $Inputs.Skipped }
                     else {
                         # 只扫描远端清单对应的目标，已有目录中的无关内容不会被访问。
                         if ($Inputs.Paths.Count) {
                             foreach ($target in $Inputs.Paths.Keys) { Get-FmExistingTargets $target $Control $Inputs.Paths[$target] }
                         } else { Get-FmExistingTargets $Inputs.Path $Control }
                     })
            [pscustomobject]@{ Info=@{}; Connected=@(); Ok=$true; Paths=@($paths) }
        } catch {
            [pscustomobject]@{ Info=@{}; Connected=@(); Ok=$false; Cancelled=[bool]$Control.Cancelled; Error=$_.Exception.Message }
        }
    })
}
function Get-FmUploadTree {
    param($Item, [string]$Relative, $Control)
    if ($Control.Cancelled) { throw '操作已取消' }
    if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "路径包含链接：$($Item.FullName)" }
    return @(
        @{ Relative = $Relative; IsDir = [bool]$Item.PSIsContainer }
        if ($Item.PSIsContainer) {
            $children = @(Get-ChildItem -LiteralPath $Item.FullName -Force -ErrorAction Stop)
            Assert-FmNames @($children | ForEach-Object { $_.Name })
            foreach ($child in $children) {
                Get-FmUploadTree $child ($Relative + '/' + $child.Name) $Control
            }
        }
    )
}
function Invoke-FmUploadEntry {
    param($Owner, $Serial, [string]$Base, $Entry, [string]$Stage, [bool]$Overwrite, $Status)
    $parts = $Entry.Relative.Split('/')
    $q = './' + (Fm-ShQuote $parts[-1])
    # 逐级进入已检查的父目录，避免让上传沿着合并树里的链接走到别处。
    $commands = @("cd $(Fm-ShQuote $Base) || exit 1")
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $parent = './' + (Fm-ShQuote $parts[$i])
        $commands += "[ ! -L $parent ] && cd $parent || exit 1"
    }
    $guard = "if [ -L $q ]; then echo FM_FAIL;"
    if (-not $Stage) {
        $commands += "$guard elif [ -d $q ]; then echo FM_DIR; elif [ -f $q ]; then echo FM_FILE; elif [ -e $q ]; then echo FM_FAIL; else echo FM_NEW; fi"
    } elseif ($Entry.IsDir) {
        $commands += "$guard elif [ -d $q ] || mkdir $q; then echo FM_OK; else echo FM_FAIL; fi"
    } else {
        $source = Fm-ShQuote (Fm-ChildPath $Stage $Entry.Relative)
        # 已授权文件按原名移入已定位的父目录。新文件用独占创建，覆盖检查到真正写入之间也不能覆盖原件。
        $replace = if ($Overwrite) { "mv -f $source ./ && echo FM_OK" } else { 'echo FM_FILE' }
        $commands += "$guard elif [ ! -f $source ] || [ -L $source ]; then echo FM_FAIL; elif [ -f $q ]; then $replace; elif [ -e $q ]; then echo FM_FAIL; elif (set -C; cat $source > $q); then touch -r $source $q 2>/dev/null; echo FM_OK; else echo FM_FAIL; fi"
    }
    $command = $commands -join '; '
    if ($Stage -and -not $Entry.IsDir) {
        $result = Fm-ShellLong $Serial $command $Owner $Status "正在上传：$($Entry.Relative)"
        if ($result.Aborted -or $result.Code -ne 0) { return 'FM_FAIL' }
        $lines = @($result.Output -split "`r?`n")
    } else {
        $lines = @(Fm-Shell $Serial $command $Owner)
    }
    $markers = @($lines | Where-Object { $_ -cmatch '^FM_(NEW|DIR|FILE|OK|FAIL)$' })
    if ($markers.Count -eq 1) { return $markers[0] }
    return 'FM_FAIL'
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
        if (-not $a.PSIsContainer -and -not (Test-FmOverwrite $Overwrite $To)) { throw "目标已存在：$To" }
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
    param($Owner, $Serial, [string]$Path, [string]$Prefix = '')
    $listing = Fm-ListDir $Owner $Serial $Path
    if (-not $listing.Ok -or $listing.Hidden -gt 0) { throw "目录未能完整检查：$Path" }
    Assert-FmNames @($listing.Items | ForEach-Object { $_.Name })
    return @(foreach ($entry in $listing.Items) {
        if ($entry.IsLink) { throw "下载目录含链接：$($entry.Path)" }
        $relative = $Prefix + $entry.Name
        @{ Relative = $relative; IsDir = [bool]$entry.IsDir }
        if ($entry.IsDir) {
            Assert-FmRemoteTree $Owner $Serial $entry.Path ($relative + '/')
        }
    })
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
    # 入口用 Invoke-MainFlow -WithDevices 接好：查询失败由它统一提示，
    # 取消时根本不会进本函数、由 OnFinally 里的 Complete-MainFlow 复位忙态和光标。
    # 所以能走到这里、且 $devs 为空，含义是「扫描成功但确实没连手机」，不是「没查到设备」。
    $devs = @($devices | Where-Object { $_ })
    if ($devs.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("没检测到手机，请先连接手机再打开「文件管理」。`n`n用数据线连接并点「允许 USB 调试」，或点主界面「无线连接…」。", '文件管理') | Out-Null
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
    $startSerial = if ($script:uiState -and $script:uiState.SelectedSerial -and ($devs -contains $script:uiState.SelectedSerial)) { $script:uiState.SelectedSerial } elseif ($settings.defaultDevice -and ($devs -contains $settings.defaultDevice)) { $settings.defaultDevice } else { $devs[0] }
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
    $fmtip.SetToolTip($btnUpload, '选电脑上的文件传到手机当前目录（可多选），也可以直接把文件拖进列表。合并文件夹时，仅覆盖或跳过列出的冲突项，其余文件继续传输。覆盖后无法恢复。')
    $fmtip.SetToolTip($btnDownload, '把选中的文件 / 文件夹下载到电脑（可多选，会让你挑保存位置）。合并文件夹时，仅覆盖或跳过列出的冲突项，其余文件继续传输。覆盖后无法恢复。')
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
        # 刷新确认没有设备后仍可留在窗口等待重连，但此时没有文件操作目标。
        $hasDevice = [bool]$state.Serial
        foreach ($control in @($btnUpload,$btnNew,$btnGo,$txtPath,$lnkHome,$lnkDl,$lnkDcim,$lnkPic,$lnkRoot)) {
            $control.Enabled = $hasDevice
        }
        $lv.AllowDrop = $hasDevice
        $sel = @($lv.SelectedItems | Where-Object { $_.Tag })
        $btnDownload.Enabled = ($sel.Count -gt 0)
        $btnDel.Enabled = ($sel.Count -gt 0)
        # 重命名只认恰好一项：多选时没有一个明确的「旧名字」，按钮和 F2 一起禁用。
        $btnRename.Enabled = ($sel.Count -eq 1)
        $btnUp.Enabled = ($hasDevice -and $state.Path -ne '/')
    }

    # —— 读目录 ——
    $refresh = {
        # 长传输中点「关闭」会先杀掉 adb，回到这里时窗体可能已 Dispose；别再碰控件。
        if ($dlg.IsDisposed) { return }
        # 读一次就固定住：整次读取（包括失败重试）都用同一台设备、同一个目录。
        $snapSerial = [string]$state.Serial
        $snapPath = [string]$state.Path
        if (-not $snapSerial) {
            $lv.Items.Clear()
            $lblInfo.ForeColor = $cMuted
            $lblInfo.Text = '没检测到手机，请先连接手机再点刷新。'
            & $updateButtons
            return
        }
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
        param([string]$p, [switch]$FromPathBox)
        if (-not $state.Serial) { return }
        # 继续容忍手输时贴进来的外侧空白，但路径框原样回车应重新打开当前目录。
        if ($FromPathBox -and $p -cne $state.Path) { $p = $p.Trim() }
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
        $names = @($list | ForEach-Object { [System.IO.Path]::GetFileName($_) })
        try { Assert-FmNames $names } catch {
            [void](Show-ResultDialog $dlg '上传' '请先处理重名或不支持的名称' $_.Exception.Message '' @('ok'))
            return
        }
        $fail = @(); $aborted = $false
        & $beginProgress $list.Count
        try {
            & $setDeviceLock $true
            $plans = @()
            foreach ($f in $list) {
                $name = [System.IO.Path]::GetFileName($f)
                if ($dlg.IsDisposed -or -not $dlg.Visible) { $aborted = $true; return }
                $snapshot = Invoke-FmTask $dlg -Functions @('Fm-ValidName','Assert-FmNames','Get-FmUploadTree') -Inputs @{ Local=$f; Name=$name } -Work {
                    try {
                        $item = Get-Item -LiteralPath $Inputs.Local -Force -ErrorAction Stop
                        $entries = @(Get-FmUploadTree $item $Inputs.Name $Control)
                        [pscustomobject]@{ Info=@{}; Connected=@(); Ok=$true; Entries=$entries }
                    } catch { [pscustomobject]@{ Info=@{}; Connected=@(); Ok=$false; Error=$_.Exception.Message } }
                }
                if ($dlg.IsDisposed -or -not $dlg.Visible -or $snapshot.Cancelled) { $aborted = $true; return }
                if (-not $snapshot.Ok) { $fail += "$name → $($snapshot.Error)"; continue }
                $conflicts = @()
                $missingDirs = @{}
                $badTarget = $null
                foreach ($entry in $snapshot.Entries) {
                    $slash = $entry.Relative.LastIndexOf('/')
                    $parent = if ($slash -ge 0) { $entry.Relative.Substring(0, $slash) } else { '' }
                    $type = if ($missingDirs.ContainsKey($parent)) { 'FM_NEW' } else {
                        Invoke-FmUploadEntry $dlg $batchSerial $batchPath $entry
                    }
                    if ($dlg.IsDisposed -or -not $dlg.Visible) { $aborted = $true; return }
                    if ($type -eq 'FM_NEW') {
                        if ($entry.IsDir) { $missingDirs[$entry.Relative] = $true }
                    } elseif ($type -eq 'FM_FILE' -and -not $entry.IsDir) {
                        $conflicts += $entry.Relative
                    } elseif ($type -ne 'FM_DIR' -or -not $entry.IsDir) {
                        $badTarget = $entry.Relative
                        break
                    }
                }
                if ($badTarget) { $fail += "$badTarget → 无法安全写入目标"; continue }
                $plans += @{ Local=$f; Name=$name; Entries=$snapshot.Entries; Conflicts=$conflicts }
            }
            $approved = @{}
            $skipped = @{}
            $allConflicts = @($plans | ForEach-Object { $_.Conflicts })
            if ($allConflicts.Count) {
                $choice = Fm-ConfirmOverwrite $dlg '上传' $allConflicts "手机上的 $batchPath"
                if ($choice -eq 'cancel' -or $dlg.IsDisposed -or -not $dlg.Visible) { $aborted = $true; return }
                $decisions = if ($choice -eq 'overwrite') { $approved } else { $skipped }
                foreach ($path in $allConflicts) { $decisions[$path] = $true }
            }
            $okN = 0; $i = 0
            foreach ($plan in $plans) {
                if ($dlg.IsDisposed -or -not $dlg.Visible) { $aborted = $true; break }
                $i++
                $name = $plan.Name
                if ($skipped.ContainsKey($name)) { continue }
                # push 只写入本次独占的暂存目录，ADB 自带的目录合并不会直接碰到用户文件。
                $stage = Fm-ChildPath $batchPath ('.scrcpy-upload-' + [guid]::NewGuid().ToString('N'))
                $qStage = Fm-ShQuote $stage
                $created = @(Fm-Shell $batchSerial "mkdir $qStage && echo FM_OK" $dlg)
                if ($created -cnotcontains 'FM_OK') {
                    if ($dlg.IsDisposed -or -not $dlg.Visible) { $aborted = $true; break }
                    $fail += "$name → 无法建立上传暂存目录"; continue
                }
                try {
                    $progState.Index = $i; $progState.WatchPath = ''; $progState.TotalBytes = 0L
                    $r = Fm-Transfer (@('-s', $batchSerial, 'push', $plan.Local, ($stage + '/'))) $dlg $lblInfo "正在上传 ($i/$($list.Count))：$name" $progState
                    if ($r.Aborted -or $dlg.IsDisposed -or -not $dlg.Visible) { $aborted = $true; break }
                    if (-not $r.Ok) { $fail += "$name → $($r.Detail)"; continue }
                    $itemOk = $true
                    foreach ($entry in $plan.Entries) {
                        if ($dlg.IsDisposed -or -not $dlg.Visible) { $aborted = $true; break }
                        $path = $entry.Relative
                        if ($skipped.ContainsKey($path)) { continue }
                        $result = Invoke-FmUploadEntry $dlg $batchSerial $batchPath $entry $stage ($approved.ContainsKey($path)) $lblInfo
                        if ($dlg.IsDisposed -or -not $dlg.Visible) { $aborted = $true; break }
                        if ($result -eq 'FM_FILE') {
                            $choice = Fm-ConfirmOverwrite $dlg '上传' @($path) "手机上的 $batchPath"
                            if ($choice -eq 'cancel' -or $dlg.IsDisposed -or -not $dlg.Visible) { $aborted = $true; break }
                            if ($choice -eq 'skip') { continue }
                            $result = Invoke-FmUploadEntry $dlg $batchSerial $batchPath $entry $stage $true $lblInfo
                            if ($dlg.IsDisposed -or -not $dlg.Visible) { $aborted = $true; break }
                        }
                        if ($result -ne 'FM_OK') {
                            $fail += "$path → 无法安全写入目标"
                            $itemOk = $false
                            break
                        }
                    }
                    if ($aborted) { break }
                    if ($itemOk) { $okN++ }
                } finally {
                    # 暂存文件由本批拥有，关掉文件窗口后也要尝试清理。
                    $cleanup = Invoke-FmShell $null $batchSerial "rm -rf $qStage"
                    if (-not $cleanup.Ok -and -not $aborted) { $fail += "$stage → 无法清理上传暂存目录" }
                }
            }
            # 关窗 / 中止后整批到此为止：不刷新、不弹结果框，窗体可能已经没了。
            if ($aborted -or $dlg.IsDisposed -or -not $dlg.Visible) { return }
            & $refresh
            if ($fail.Count -gt 0) {
                [void](Show-ResultDialog $dlg '上传' "有 $($fail.Count) 项没传成功" '点「查看原因」看哪些文件没传过去。手机不允许写入时，可换到「内部存储 > Download」再试。' ($fail -join "`r`n") @('ok'))
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
        if ($settings -and $settings.lastDownloadDir -and (Test-Path -LiteralPath $settings.lastDownloadDir -PathType Container)) { $fbd.SelectedPath = $settings.lastDownloadDir }
        if ($fbd.ShowDialog($dlg) -ne [System.Windows.Forms.DialogResult]::OK) { $fbd.Dispose(); return }
        $dest = $fbd.SelectedPath
        $fbd.Dispose()
        if (-not (Test-Path -LiteralPath $dest)) { return }
        if ($settings -and $settings.lastDownloadDir -ne $dest) {
            $settings.lastDownloadDir = $dest
            if (Get-Command Save-Settings -ErrorAction SilentlyContinue) { Save-Settings }
        }
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
        $skippedTargets = @{}
        # 同名目录可以共存，只有将被替换或挡住写入的具体路径才算冲突。
        $conflicts = @(foreach ($item in $sel) {
            $target = Join-Path $dest $item.Tag.Name
            $targets = @{}
            $targets[$target] = [bool]$item.Tag.IsDir
            foreach ($entry in $relativeTargets[$item.Tag.Name]) {
                $targets[(Join-Path $target $entry.Relative)] = $entry.IsDir
            }
            $check = Get-FmTargetPaths $dlg $target -Paths $targets
            if ($dlg.IsDisposed -or -not $dlg.Visible -or $check.Cancelled) { return }
            if (-not $check.Ok) {
                [void](Show-ResultDialog $dlg '下载' '无法安全保存这批文件' $check.Error '' @('ok'))
                return
            }
            $check.Paths
        })
        if ($conflicts.Count -gt 0) {
            $choice = Fm-ConfirmOverwrite $dlg '下载' $conflicts "电脑上的 $dest"
            if ($choice -eq 'cancel') { return }
            if ($choice -eq 'skip') {
                foreach ($path in $conflicts) { $skippedTargets[$path] = $true }
                $sel = @($sel | Where-Object { -not $skippedTargets.ContainsKey([IO.Path]::GetFullPath((Join-Path $dest $_.Tag.Name))) })
                if ($sel.Count -eq 0) { $lblInfo.ForeColor = $cMuted; $lblInfo.Text = '同名项都跳过了，没有下载任何文件'; return }
            } else {
                foreach ($path in $conflicts) { $approvedTargets[$path] = $true }
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
                            $check = Get-FmTargetPaths $dlg $local $stage $approvedTargets -Skipped $skippedTargets
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
        $name = Show-InputDialog $dlg '新建文件夹' '在当前目录新建一个文件夹，输入名称：' '新建文件夹'
        if ($null -eq $name) { return }
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
            [void](Show-ResultDialog $dlg '新建文件夹' '没能新建这个文件夹' '点「查看原因」查看手机返回的信息。若目录不可写，可切到「内部存储 > Download」再试。' $out @('ok'))
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
        $new = Show-InputDialog $dlg '重命名' "给「$old」换个名称：" $old
        if ($null -eq $new) { return }
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
            [void](Show-ResultDialog $dlg '重命名' '没能重命名' '请先点「刷新」确认原文件和新名称的状态。可点「查看原因」查看手机返回的信息。' $out @('ok'))
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
            $why = if ($aborted) { '删除时窗口被关掉，助手已停止继续删除。' } else { '设备端没有返回明确的成功 / 失败结论。' }
            [void](Show-ResultDialog $dlg '删除' '已停止继续删除' "$why 部分文件可能已删除。请先点「刷新」确认当前目录，再选择仍需删除的项目。" ($fail -join "`r`n") @('ok'))
        } elseif ($fail.Count -gt 0) {
            [void](Show-ResultDialog $dlg '删除' "有 $($fail.Count) 项没能删除" '可点「查看原因」看哪些文件没删掉。手机可能限制了这个目录里的操作。' ($fail -join "`r`n") @('ok'))
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
    $btnGo.Add_Click({ Invoke-MainFlow ({ & $enter $txtPath.Text -FromPathBox }) $dlg $script:fmFlow })
    $txtPath.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $e.SuppressKeyPress = $true
            Invoke-MainFlow ({ & $enter $txtPath.Text -FromPathBox }) $dlg $script:fmFlow
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
        $snapshot = Wait-DeviceScan $dlg
        if ($dlg.IsDisposed -or -not $dlg.Visible -or $snapshot.Cancelled) { return }
        if (-not $snapshot.Success) {
            [void](Show-ResultDialog $dlg '文件管理' '无法读取设备列表' '请稍后再点「刷新」。' $snapshot.Error @('ok'))
            return
        }
        # 同时清掉 shell 写法缓存：上次探测若正好赶上设备重连失败，会一直用错写法直到关窗。
        $script:fmShellMode = $null
        $state.Rebuilding = $true
        try {
            $state.Serials = @($snapshot.Devices)
            $cmbDev.Items.Clear()
            foreach ($s in $state.Serials) { [void]$cmbDev.Items.Add("$(Get-FriendlyName $s -CachedOnly)   ·   $s") }
            $j = [array]::IndexOf($state.Serials, $state.Serial)
            if ($j -lt 0 -and $state.Serials.Count -gt 0) { $j = 0 }
            $state.Serial = if ($j -ge 0) { $state.Serials[$j] } else { '' }
            $cmbDev.SelectedIndex = $j
        } finally { $state.Rebuilding = $false }
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
    # ---------------- 主窗口（方案 A：设备中心 · 卡片工作台 + 宣纸墨印 2.0） ----------------
    $form = New-Object System.Windows.Forms.Form
    Set-DpiScale $form   # 高 DPI 清晰化：Load 时按真实 DPI 等比放大
    Enable-DoubleBuffer $form
    $form.Text = 'scrcpy 投屏助手'
    $form.ClientSize = New-Object System.Drawing.Size(540, 428)
    # 记住上次的位置：存过且仍落在可见屏幕范围内就沿用，否则居中（换了显示器/分辨率也不会跑到屏幕外）
    $savedX = [int]$settings.winX; $savedY = [int]$settings.winY
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
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
    Set-TitleBarColor $form $cPaper
    $tt = New-Object System.Windows.Forms.ToolTip
    $tt.AutoPopDelay = 12000

    $script:uiState = @{
        SelectedSerial = ''
        OnlineDevices  = @()
        LastResult     = $null
        DotColor       = $cMuted
        DevTitle       = '检测中…'
        DevMeta        = '正在读取设备连接状态'
        PillText       = ''
        PillBg         = $cSoft
        PillFg         = $cText2
        PillBd         = $cLine
        CanSwitch      = $false
        RightMode      = 'devices'
        StatusTip      = '点击打开「设备管理」。切回窗口时会自动刷新。'
    }

    # 兼容测试与状态的隐藏同步标签（tests/device-query-status.ps1 断言其文本与 ToolTip）
    $statusTip = $script:uiState.StatusTip
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Visible = $false; $lblStatus.Size = New-Object System.Drawing.Size(1, 1); $lblStatus.Location = New-Object System.Drawing.Point(-20, -20)
    $lblStatus.BackColor = $cTagBg; $lblStatus.ForeColor = $cMuted; $lblStatus.Text = '◌ 检测中…'
    $lblDevInfo = New-Object System.Windows.Forms.Label
    $lblDevInfo.Visible = $false; $lblDevInfo.Size = New-Object System.Drawing.Size(1, 1); $lblDevInfo.Location = New-Object System.Drawing.Point(-20, -20)
    $form.Controls.AddRange(@($lblStatus, $lblDevInfo))
    $tt.SetToolTip($lblStatus, $statusTip)

    # 首栏：朱砂印竖条 + 「当前设备」小节头（窗口标题仅保留在系统标题栏，不重复）
    $brand = New-Object System.Windows.Forms.Panel
    $brand.Size = New-Object System.Drawing.Size(3, 14); $brand.Location = New-Object System.Drawing.Point(20, 17)
    $brand.BackColor = $cRed
    $form.Controls.Add($brand)
    $lblSection = New-Object System.Windows.Forms.Label
    $lblSection.Text = '当前设备'; $lblSection.AutoSize = $true
    $lblSection.Location = New-Object System.Drawing.Point(31, 14)
    $lblSection.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
    $lblSection.ForeColor = $cInk
    $form.Controls.Add($lblSection)

    $btnShortcuts = New-LinkBtn '快捷键' 382 11 72 'keyboard'
    $btnSettings  = New-LinkBtn '设置'   458 11 62 'settings'
    $form.Controls.AddRange(@($btnShortcuts, $btnSettings))

    # 设备与运行态卡片
    $pnlDevCard = New-Object System.Windows.Forms.Panel
    $pnlDevCard.Location = New-Object System.Drawing.Point(20, 44); $pnlDevCard.Size = New-Object System.Drawing.Size(500, 66)
    Set-CardStyle $pnlDevCard 10 $cWhite $cLine
    $form.Controls.Add($pnlDevCard)

    $pnlDevTop = New-Object System.Windows.Forms.Panel
    $pnlDevTop.Location = New-Object System.Drawing.Point(6, 4); $pnlDevTop.Size = New-Object System.Drawing.Size(488, 58)
    $pnlDevTop.BackColor = $cWhite
    Enable-DoubleBuffer $pnlDevTop
    $pnlDevTop.Add_Paint({
        param($p, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $s = $script:dpiScale
        $dotSz = [float](9 * $s)
        $db = New-Object System.Drawing.SolidBrush($script:uiState.DotColor)
        $g.FillEllipse($db, [float](9 * $s), [float](($p.ClientSize.Height - $dotSz) / 2.0), $dotSz, $dotSz)
        $db.Dispose()
    })

    $btnDevName = New-Object System.Windows.Forms.Button
    $btnDevName.Location = New-Object System.Drawing.Point(27, 7); $btnDevName.Size = New-Object System.Drawing.Size(330, 26)
    $btnDevName.FlatStyle = 'Flat'; $btnDevName.FlatAppearance.BorderSize = 0
    $btnDevName.BackColor = $cWhite; $btnDevName.ForeColor = $cInk
    $btnDevName.Cursor = [System.Windows.Forms.Cursors]::Default
    Enable-DoubleBuffer $btnDevName
    $btnDevName.Add_Paint({
        param($b, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear($cWhite)
        $s = $script:dpiScale
        $f = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5, [System.Drawing.FontStyle]::Bold)
        $titleTxt = [string]$script:uiState.DevTitle
        $tf = [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::SingleLine -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis
        $pillTxt = [string]$script:uiState.PillText
        $maxTitleW = $b.ClientSize.Width - $(if ($pillTxt) { [int](86 * $s) } else { [int](10 * $s) })
        $sz = [System.Windows.Forms.TextRenderer]::MeasureText($g, $titleTxt, $f, [System.Drawing.Size]::new($maxTitleW, $b.ClientSize.Height), $tf)
        $tw = [Math]::Min($maxTitleW, [int]$sz.Width + 2)
        [System.Windows.Forms.TextRenderer]::DrawText($g, $titleTxt, $f, [System.Drawing.Rectangle]::new(0, 0, $tw, $b.ClientSize.Height), $cInk, $tf)
        $f.Dispose()
        $cx = $tw + [int](4 * $s)
        if ($script:uiState.CanSwitch) {
            $fa = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
            [System.Windows.Forms.TextRenderer]::DrawText($g, '▾', $fa, [System.Drawing.Rectangle]::new($cx, 0, [int](14 * $s), $b.ClientSize.Height), $cMuted, $tf)
            $fa.Dispose()
            $cx += [int](16 * $s)
        }
        if ($pillTxt) {
            $fp = New-Object System.Drawing.Font('Microsoft YaHei UI', 8, [System.Drawing.FontStyle]::Bold)
            $psz = [System.Windows.Forms.TextRenderer]::MeasureText($g, $pillTxt, $fp)
            $pw = [float]($psz.Width + 14 * $s)
            $ph = [float](20 * $s)
            $py = ($b.ClientSize.Height - $ph) / 2.0
            $pp = New-RoundedPath ([float]$cx) $py $pw $ph ($ph / 2.0)
            $pb = New-Object System.Drawing.SolidBrush($script:uiState.PillBg); $g.FillPath($pb, $pp); $pb.Dispose()
            $ppen = New-Object System.Drawing.Pen($script:uiState.PillBd, 1.0); $g.DrawPath($ppen, $pp); $ppen.Dispose(); $pp.Dispose()
            $ptf = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::SingleLine
            [System.Windows.Forms.TextRenderer]::DrawText($g, $pillTxt, $fp, [System.Drawing.Rectangle]::new($cx, [int]$py, [int]$pw, [int]$ph), $script:uiState.PillFg, $ptf)
            $fp.Dispose()
        }
    })

    $lblCardMeta = New-Caption '正在读取设备连接状态' 27 35
    $lblCardMeta.AutoSize = $false; $lblCardMeta.Size = New-Object System.Drawing.Size(330, 18)
    $lblCardMeta.ForeColor = $cMuted

    $btnFindPhone = New-Object System.Windows.Forms.Button
    $btnFindPhone.Text = ''
    $btnFindPhone.AccessibleName = '寻找手机'
    $btnFindPhone.Location = New-Object System.Drawing.Point(362, 15)
    $btnFindPhone.Size = New-Object System.Drawing.Size(28, 28)
    $btnFindPhone.FlatStyle = 'Flat'; $btnFindPhone.FlatAppearance.BorderSize = 0
    $btnFindPhone.BackColor = $cWhite; $btnFindPhone.ForeColor = $cMuted
    $btnFindPhone.FlatAppearance.MouseOverBackColor = $cSoft
    $btnFindPhone.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btnFindPhone.Visible = $false
    Add-RoundedButtonPaint $btnFindPhone 7 $false 'bell'
    $findPhoneTip = '寻找手机：以最大闹钟音量循环播放手机当前的来电铃声，直到停止。'
    $tt.SetToolTip($btnFindPhone, $findPhoneTip)

    $btnDevices = New-SecondaryBtn '设备管理' 396 15 82 28
    $btnDevices.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
    $pnlDevTop.Controls.AddRange(@($btnDevName, $lblCardMeta, $btnFindPhone, $btnDevices))

    # 多设备切换菜单
    $devMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $devMenu.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)

    # 未连接新手引导条（仅未连接时显示，左右留白避开卡片 10px 圆角）
    $pnlGuide = New-Object System.Windows.Forms.Panel
    $pnlGuide.Location = New-Object System.Drawing.Point(6, 62); $pnlGuide.Size = New-Object System.Drawing.Size(488, 36)
    $pnlGuide.BackColor = $cHover; $pnlGuide.Visible = $false
    Enable-DoubleBuffer $pnlGuide
    $guideLine = New-Object System.Windows.Forms.Panel; $guideLine.Location = New-Object System.Drawing.Point(0, 0); $guideLine.Size = New-Object System.Drawing.Size(488, 1); $guideLine.BackColor = $cLine
    $btnGuidePair = New-SecondaryBtn '用配对码连接' 9 5 108 27; $btnGuidePair.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
    $btnGuideIp   = New-SecondaryBtn '输入 IP 连接' 123 5 98 27; $btnGuideIp.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
    $btnGuideHelp = New-LinkBtn '开启步骤 ?' 396 5 82; $btnGuideHelp.BackColor = $cHover
    $pnlGuide.Controls.AddRange(@($guideLine, $btnGuidePair, $btnGuideIp, $btnGuideHelp))

    # 运行中会话条（有投屏 / 录屏 / 摄像头进程时展开，可直接停止）
    $pnlSession = New-Object System.Windows.Forms.Panel
    $pnlSession.Location = New-Object System.Drawing.Point(6, 62); $pnlSession.Size = New-Object System.Drawing.Size(488, 34)
    $pnlSession.BackColor = $cRedStripBg; $pnlSession.Visible = $false
    Enable-DoubleBuffer $pnlSession
    $pnlSession.Add_Paint({
        param($p, $e)
        $g = $e.Graphics; $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $s = $script:dpiScale
        $dotSz = [float](7 * $s)
        $db = New-Object System.Drawing.SolidBrush($cRed)
        $g.FillEllipse($db, [float](10 * $s), [float](($p.ClientSize.Height - $dotSz) / 2.0), $dotSz, $dotSz); $db.Dispose()
    })
    $sessLine = New-Object System.Windows.Forms.Panel; $sessLine.Location = New-Object System.Drawing.Point(0, 0); $sessLine.Size = New-Object System.Drawing.Size(488, 1); $sessLine.BackColor = $cLine
    $lblSession = New-Lbl '' 25 8
    $lblSession.AutoSize = $false; $lblSession.Size = New-Object System.Drawing.Size(374, 18)
    $lblSession.ForeColor = $cRed; $lblSession.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5, [System.Drawing.FontStyle]::Bold)
    $btnQuickStop = New-SecondaryBtn '■ 停止' 408 4 70 26
    $btnQuickStop.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5, [System.Drawing.FontStyle]::Bold)
    $btnQuickStop.ForeColor = $cRed
    $btnQuickStop.FlatAppearance.BorderColor = $cRedBorder
    $btnQuickStop.FlatAppearance.MouseOverBackColor = $cRedBg
    $pnlSession.Controls.AddRange(@($sessLine, $lblSession, $btnQuickStop))

    $pnlDevCard.Controls.AddRange(@($pnlDevTop, $pnlGuide, $pnlSession))

    # 主操作区：开始投屏 + 无线连接/切无线
    $btnCastHero     = New-ActionCard '开始投屏' '连上手机后即可一键投屏' 'play' 20 122 294 68 -Primary
    $btnWirelessHero = New-ActionCard '无线连接…' '配对码 / IP / 切无线' 'wifi' 326 122 194 68
    $form.Controls.AddRange(@($btnCastHero, $btnWirelessHero))

    # 快捷偏好胶囊栏（与设置实时同步保存）
    $btnCapAudio     = New-CapsuleBtn '传声音'       20  202 74 28 $settings.audioOn
    $btnCapScreenOff = New-CapsuleBtn '投屏息屏'     102 202 82 28 $settings.screenOff
    $btnCapOnTop     = New-CapsuleBtn '窗口置顶'     192 202 82 28 $settings.onTop
    $resLabelInit    = if ([int]$settings.maxSize -le 0) { '清晰度：原画 ▾' } else { "清晰度：$($settings.maxSize) ▾" }
    $btnCapRes       = New-CapsuleBtn $resLabelInit 410 202 110 28 $false -Dropdown
    $resMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $resMenu.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $form.Controls.AddRange(@($btnCapAudio, $btnCapScreenOff, $btnCapOnTop, $btnCapRes))

    # 2x2 功能矩阵
    $btnFiles  = New-ActionCard '文件管理'     '电脑与手机直连互传'     'folder' 20  242 244 64
    $btnCamera = New-ActionCard '手机当摄像头' '配 OBS 当会议/直播镜头' 'camera' 276 242 244 64
    $btnRecord = New-ActionCard '录制屏幕'     '边投边录或后台静默录'   'record' 20  316 244 64
    $btnNd     = New-ActionCard '独立窗口'     '单开 App 手机照常用'    'window' 276 316 244 64
    $form.Controls.AddRange(@($btnFiles, $btnCamera, $btnRecord, $btnNd))

    # 底部独立状态栏（不与按钮抢位，含设备统计与 GitHub 入口）
    $pnlFooter = New-Object System.Windows.Forms.Panel
    $pnlFooter.Location = New-Object System.Drawing.Point(0, 394); $pnlFooter.Size = New-Object System.Drawing.Size(540, 34)
    $pnlFooter.BackColor = $cFooterBg
    $footerLine = New-Object System.Windows.Forms.Panel; $footerLine.Location = New-Object System.Drawing.Point(0, 0); $footerLine.Size = New-Object System.Drawing.Size(540, 1); $footerLine.BackColor = $cLine
    $lblHint = New-Caption '首次连接请在手机点「允许 USB 调试」' 20 9
    $lblHint.AutoSize = $false; $lblHint.Size = New-Object System.Drawing.Size(392, 18)
    $lblHint.AutoEllipsis = $true
    $lblFooterMeta = New-Caption '检测中…' 418 9
    $lblFooterMeta.AutoSize = $false; $lblFooterMeta.Size = New-Object System.Drawing.Size(80, 18)
    $lblFooterMeta.TextAlign = 'MiddleRight'
    $footerSep = New-Object System.Windows.Forms.Panel; $footerSep.Location = New-Object System.Drawing.Point(503, 11); $footerSep.Size = New-Object System.Drawing.Size(1, 12); $footerSep.BackColor = $cLineStrong

    $ghB64 = 'iVBORw0KGgoAAAANSUhEUgAAACQAAAAkCAYAAADhAJiYAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAOkSURBVFhH7ZdXU1sxEIX550lIo5liSgyG0EzL0DEEDMEYMAyYYooxvYQAaf9hM58cORfp2r4OkwkPPJxBSGd3j3RX2nXJz69X8phQYk78bzwJKoQHCbq5OpbTw6Qc7CbkYHddjZkzecWgaEFXZweyOD8l/aGgNDdWSX3NG6mteqnAmLm+7qDiwDXtC8GzoLvrU4lMDUuTv1yqyp5JTWWp+KtfS33NW2mozYAxc6zBaawrk5nJIbn9fGL5ywVPgtJ7CWlrrlVBCEggLSIX4MDFpjVQqz6r6dcNBQUlN5alzpfZtRchJrDBFh/biSXLv4m8glI761Lne6VAfvjKn0t1xQs1zieONThwsWGMIPJsP7lmxfEk6MvlkUpQnOCso7Ve1uKfJDzarwISSIPAOrgGnImRPmXT2daQFYTP64tDK15BQTjTiUmA6fBgdu38eE8mRnplanxAVhYjsrkWU2A8Nf5Bxod75exoN8vnMmiR+GTdjJdX0Ek6+fszZT4BzqKzExbPK2KfJpUPfOGTkzo+2LZ4wFUQu9Q70oLGhnosnldw2lqQPvHJsQGLByxB327O1TXlhHSSkh+rS7OWsVesxefVTdP+8N0aqFGxTK4l6Ci1dU8Mx9vTGbAMiwWvN76coo5SmxbPEpRYjWaPV3+uhbmwZVgsKCWm3/WVqMWzBLkZcuQmr1gkVhcsv8QyeZYgTsM0fEj+aPAemX7dTt4StLwwbRnOTY9ahsViPjJu+SWWybMEba0vqlulDUnE3q4Wy7BY0K44bxoxiGXyLEG8wtQeZ1uBKOqayfUKuoVMv5Txx19iEMvkWoJ+3F1K1/vG7BVlVxwvb9PlacpyUAjY0Lo4rzxjYhDL5FuCAMlGzcGYuhPqeKf+pzDGY5G8xVEDTjw2o2ycrYuuZ24JDVwF4YzOsLqiVCUjO0EYjvj2gYZKCXUEXOvRSXpbrcHhZKnyzlaFpq3JX5FzU66CAG8EAgCimOOY9VxLk8/16WeuPei/dzGcwNbt/dHIKYhT6etuUQ5IQHb0/fZClqIf1TNAiTFtNMKjf4qphi6q+HTLHY2cgsD1RVolM6K4+l5/RVDJnYK0GHzh0+Q7kVcQ4JbQLSKKvOoPtSpx+fojukqnIGzbg/WebmlBQYCfMfRDOn/A6GDI4mnQTSKIS0EujQ2FPP8U8iRIY2czns2rfA2bFg8XG3M9H4oSpHG4vyEXJ/vWvAZrcMx5L/grQf8ST4IK4dEJ+gX3m3AeIyd/VAAAAABJRU5ErkJggg=='
    $btnGh = New-Object System.Windows.Forms.PictureBox
    $btnGh.Size = New-Object System.Drawing.Size(16, 16); $btnGh.Location = New-Object System.Drawing.Point(511, 9)
    $btnGh.SizeMode = 'Zoom'; $btnGh.BackColor = $cFooterBg
    $btnGh.Cursor = [System.Windows.Forms.Cursors]::Hand
    try { $btnGh.Image = [System.Drawing.Image]::FromStream((New-Object System.IO.MemoryStream(,[Convert]::FromBase64String($ghB64)))) } catch {}
    $btnGh.Add_Click({ try { Start-Process 'https://github.com/rockbenben/scrcpy-helper' } catch {} })
    $pnlFooter.Controls.AddRange(@($footerLine, $lblHint, $lblFooterMeta, $footerSep, $btnGh))
    $form.Controls.Add($pnlFooter)

    # 动态布局：设备卡（无副条 / 引导条 / 运行条）展开或收起时，保持等比间距并调整窗口高度
    $layoutMainBody = {
        $s = $script:dpiScale
        $g12 = [int][Math]::Round(12 * $s)
        $g10 = [int][Math]::Round(10 * $s)
        $g14 = [int][Math]::Round(14 * $s)
        $topH = $pnlDevTop.Bottom
        $extraY = $topH
        if ($pnlGuide.Visible) { $pnlGuide.Top = $extraY; $extraY += $pnlGuide.Height }
        if ($pnlSession.Visible) { $pnlSession.Top = $extraY; $extraY += $pnlSession.Height }
        $pnlDevCard.Height = $extraY + [int][Math]::Round(4 * $s)
        $pnlDevCard.Invalidate()

        $heroY = $pnlDevCard.Bottom + $g12
        $btnCastHero.Top = $heroY; $btnWirelessHero.Top = $heroY

        $capY = $btnCastHero.Bottom + $g12
        foreach ($c in @($btnCapAudio, $btnCapScreenOff, $btnCapOnTop, $btnCapRes)) { $c.Top = $capY }

        $gridY1 = $btnCapAudio.Bottom + $g12
        $btnFiles.Top = $gridY1; $btnCamera.Top = $gridY1
        $gridY2 = $btnFiles.Bottom + $g10
        $btnRecord.Top = $gridY2; $btnNd.Top = $gridY2

        $pnlFooter.Top = $btnRecord.Bottom + $g14
        $targetClientH = $pnlFooter.Bottom
        if ($form.ClientSize.Height -ne $targetClientH) {
            $form.ClientSize = New-Object System.Drawing.Size($form.ClientSize.Width, $targetClientH)
        }
    }

    # 底部非模态临时提示（录制提示 / 摄像头自动重连提示共用）：换文案几秒后自动恢复原提示。
    $script:hintRestore = New-Object System.Windows.Forms.Timer
    $script:restoreHint = {
        $script:hintRestore.Stop()
        $lblHint.Text = $script:recHintText; $lblHint.ForeColor = $script:recHintColor
        $script:recTipActive = $false
    }
    $script:hintRestore.Add_Tick({ & $script:restoreHint })
    $script:showTempHint = {
        param($text, $color, $ms = 6000)
        if (-not $script:recTipActive) { $script:recHintText = $lblHint.Text; $script:recHintColor = $lblHint.ForeColor }
        $script:recTipActive = $true
        $lblHint.Text = $text; $lblHint.ForeColor = $color
        $script:hintRestore.Stop()
        if ($null -ne $ms) { $script:hintRestore.Interval = $ms; $script:hintRestore.Start() }
    }
    $script:hintKeepAfterFlow = $false

    $tt.SetToolTip($btnGh, '在 GitHub 查看源码 / 反馈问题')
    $tt.SetToolTip($btnCastHero, '直接投屏当前选中的手机。')
    $tt.SetToolTip($btnWirelessHero, '有线设备可一键切到无线；未连接时支持配对码或输入 IP 连接。')
    $tt.SetToolTip($btnCamera, '在电脑窗口显示手机摄像头画面（Android 12+）。供会议软件使用时，请用 OBS 捕获窗口并启动虚拟摄像头。')
    $tt.SetToolTip($btnRecord, '把手机屏幕录制成视频文件（可边投边录或后台静默录）。')
    $tt.SetToolTip($btnNd, '在电脑上单开一块屏运行某个 App，不影响手机（需 Android 11+）。')
    $tt.SetToolTip($btnShortcuts, 'scrcpy 常用快捷键速查（全屏、息屏、旋转、复制粘贴、拖文件装 APK 等）。')
    $tt.SetToolTip($btnSettings, '画质、声音、控制、窗口、独立窗口、录制等都可在这里自定义。')
    $tt.SetToolTip($btnFiles, '浏览手机上的文件：上传、下载、新建文件夹、重命名、删除（直接走 ADB，不用装 App）。')
    $tt.SetToolTip($btnDevices, '管理多台设备：切换、断开、设默认、忘记，或输入 IP 直连。')
    $tt.SetToolTip($btnCapAudio, '开关「把手机声音也传到电脑」（需要 Android 11+）。点一下立即保存。')
    $tt.SetToolTip($btnCapScreenOff, '开关「开始投屏时熄灭手机屏幕」，省电防打扰。点一下立即保存。')
    $tt.SetToolTip($btnCapOnTop, '开关「投屏窗口总在最前」。点一下立即保存。')
    $tt.SetToolTip($btnCapRes, '快速调整投屏最长边清晰度上限。点一下可挑常用档位并自动保存。')

    # ---------------- 状态与交互同步 ----------------
    $syncCapsules = {
        $btnCapAudio.CapData.On = [bool]$settings.audioOn; $btnCapAudio.Invalidate()
        $btnCapScreenOff.CapData.On = [bool]$settings.screenOff; $btnCapScreenOff.Invalidate()
        $btnCapOnTop.CapData.On = [bool]$settings.onTop; $btnCapOnTop.Invalidate()
        $btnCapRes.CapData.Text = if ([int]$settings.maxSize -le 0) { '清晰度：原画 ▾' } else { "清晰度：$($settings.maxSize) ▾" }
        $btnCapRes.Invalidate()
    }

    $script:phoneRing = $null
    $syncFindPhoneButton = {
        $ring = $script:phoneRing
        $ringActive = ($null -ne $ring -and -not $ring.Finished)
        $hasOnline = (@($script:uiState.OnlineDevices).Count -gt 0)
        $btnFindPhone.Visible = ($hasOnline -or $ringActive)
        if ($ringActive) {
            $stopping = ($ring.Phase -eq 'stopping')
            $btnFindPhone.Text = ''
            $btnFindPhone.AccessibleName = if ($stopping) { '正在停止响铃' } else { '停止响铃' }
            $btnFindPhone.Enabled = (-not $stopping)
            $btnFindPhone.BackColor = $cRedStripBg
            $btnFindPhone.ForeColor = $cRed
            $btnFindPhone.FlatAppearance.BorderColor = $cRedBorder
            $btnFindPhone.FlatAppearance.MouseOverBackColor = $cRedBg
            $btnFindPhone.BtnPaint.HasBorder = $true
            $btnFindPhone.BtnPaint.Glyph = 'stop'
            if ($stopping) {
                $btnFindPhone.BtnPaint.Hover = $false
                $btnFindPhone.BtnPaint.Down = $false
            }
            $ringName = if ($ring.DeviceName) { $ring.DeviceName } else { '手机' }
            $tt.SetToolTip($btnFindPhone, $(if ($stopping) { "正在停止「$ringName」响铃并恢复闹钟音量…" } else { "停止「$ringName」响铃并恢复原来的闹钟音量。" }))
        } else {
            $btnFindPhone.Text = ''
            $btnFindPhone.AccessibleName = '寻找手机'
            $btnFindPhone.Enabled = $true
            $btnFindPhone.BackColor = $cWhite
            $btnFindPhone.FlatAppearance.BorderColor = [System.Drawing.Color]::Empty
            $btnFindPhone.FlatAppearance.MouseOverBackColor = $cSoft
            $btnFindPhone.BtnPaint.HasBorder = $false
            $btnFindPhone.BtnPaint.Glyph = 'bell'
            $btnFindPhone.BtnPaint.Hover = $false
            $btnFindPhone.BtnPaint.Down = $false
            $btnFindPhone.ForeColor = if ($script:mainFlow -and $script:mainFlow.Busy) { $cBusyLink } else { $cMuted }
            $tt.SetToolTip($btnFindPhone, $findPhoneTip)
        }
        $btnFindPhone.Invalidate()
    }

    $script:recCardState = @{ Active = $false; Bg = $false }
    $script:trayTextCache = ''
    $syncLiveSession = {
        Update-ProcessLifecycle
        $activeProcs = @($scrcpyProcs | Where-Object { $_.Proc -and -not (Test-ProcessExited $_.Proc) })
        $activeRecProcs = @($activeProcs | Where-Object { $_.Rec })
        $recCount = $activeRecProcs.Count
        $hasBgRec = (@($activeRecProcs | Where-Object { $_.RecBg }).Count -gt 0)
        $ring = $script:phoneRing
        $ringActive = ($null -ne $ring -and -not $ring.Finished)
        $ringStopping = ($ringActive -and $ring.Phase -eq 'stopping')
        $ringName = if ($ringActive -and $ring.DeviceName) { $ring.DeviceName } else { '手机' }
        $showSess = ($activeProcs.Count -gt 0 -or $ringActive)
        if ($showSess) {
            if ($activeProcs.Count -gt 0) {
                $camCount = @($script:camSessions | Where-Object { -not $_.Stopped -and $_.Proc -and -not (Test-ProcessExited $_.Proc) }).Count
                $firstSerial = [string]$activeProcs[0].Serial
                $firstName = if ($firstSerial) { Get-FriendlyName $firstSerial -CachedOnly } else { '设备' }
                if ($activeProcs.Count -eq 1) {
                    if ($recCount -gt 0) {
                        $sessText = $(if ($activeRecProcs[0].RecBg) { "后台录屏中 · $firstName" } else { "录屏中 · $firstName" })
                    } elseif ($camCount -gt 0) {
                        $sessText = "摄像头运行中 · $firstName"
                    } else {
                        $sessText = "投屏中 · $firstName"
                    }
                } else {
                    $sessText = $(if ($recCount -gt 0) { "运行中 · 共 $($activeProcs.Count) 个会话（含录屏）" } else { "运行中 · 共 $($activeProcs.Count) 个会话" })
                }
                if ($ringActive) {
                    $sessText += $(if ($ringStopping) { ' · 正在停止响铃' } else { ' · 正在响铃' })
                }
                $lblSession.Text = $sessText
                $btnQuickStop.Text = '■ 停止'
                $btnQuickStop.Enabled = $true
            } else {
                $lblSession.Text = if ($ringStopping) { "正在停止响铃 · $ringName" } else { "正在响铃 · $ringName" }
                $btnQuickStop.Text = if ($ringStopping) { '停止中…' } else { '■ 停止' }
                $btnQuickStop.Enabled = (-not $ringStopping)
            }
            if ($ringActive -and $activeProcs.Count -eq 0) {
                $tt.SetToolTip($btnQuickStop, "停止「$ringName」响铃并恢复原来的闹钟音量。")
            } elseif ($ringActive) {
                $tt.SetToolTip($btnQuickStop, '停止当前运行的投屏、录制与寻找手机响铃。')
            } else {
                $tt.SetToolTip($btnQuickStop, '停止当前全部投屏、录制和摄像头会话。')
            }
        } else {
            $btnQuickStop.Text = '■ 停止'
            $btnQuickStop.Enabled = $true
            $tt.SetToolTip($btnQuickStop, '停止当前全部投屏、录制和摄像头会话。')
        }
        $recActive = ($recCount -gt 0)
        if ($recActive -ne $script:recCardState.Active -or $hasBgRec -ne $script:recCardState.Bg) {
            $script:recCardState.Active = $recActive
            $script:recCardState.Bg = $hasBgRec
            if ($recActive) {
                $btnRecord.CardData.Title = '停止录制'
                $btnRecord.CardData.Sub = if ($hasBgRec) { '后台录屏中 · 点此结束（不影响投屏）' } else { '正在录屏 · 点此结束（不影响投屏）' }
                $btnRecord.CardData.Glyph = 'stop'
                $btnRecord.CardData.Accent = $true
                $btnRecord.Text = '停止录制'
                $tt.SetToolTip($btnRecord, '仅停止当前录制并保存视频，不影响正在运行的投屏窗口。')
            } else {
                $btnRecord.CardData.Title = '录制屏幕'
                $btnRecord.CardData.Sub = '边投边录或后台静默录'
                $btnRecord.CardData.Glyph = 'record'
                $btnRecord.CardData.Accent = $false
                $btnRecord.Text = '录制屏幕'
                $tt.SetToolTip($btnRecord, '把手机屏幕录制成视频文件（可边投边录或后台静默录）。')
            }
            $btnRecord.Invalidate()
        }
        if ($tray) {
            $trayText = if ($recActive) {
                if ($hasBgRec) { 'scrcpy 投屏助手 · 后台录屏中' } else { 'scrcpy 投屏助手 · 录屏中' }
            } elseif ($activeProcs.Count -gt 0) {
                'scrcpy 投屏助手 · 投屏运行中'
            } else {
                'scrcpy 投屏助手'
            }
            if ($trayText -ne $script:trayTextCache) {
                $script:trayTextCache = $trayText
                $tray.Text = $trayText
            }
            $miTrayStopRec.Visible = $recActive
            $miTrayStopAll.Visible = ($activeProcs.Count -gt $recCount)
        }
        $changed = ($pnlSession.Visible -ne $showSess)
        $pnlSession.Visible = $showSess
        if ($changed) { & $layoutMainBody }
    }

    $syncDeviceCard = {
        param($result)
        $devs = if ($result -and $result.Success) { @($result.Devices) } else { @() }
        $script:uiState.OnlineDevices = $devs
        $script:uiState.LastResult = $result

        if ($null -eq $result) {
            $script:uiState.DotColor = $cMuted
            $script:uiState.DevTitle = '正在检测手机…'
            $script:uiState.DevMeta  = '正在刷新设备连接状态'
            $script:uiState.PillText = ''
            $script:uiState.CanSwitch = $false
            $script:uiState.RightMode = 'devices'
            $btnDevices.Text = '设备管理'
            $lblFooterMeta.Text = '检测中…'
            $pnlGuide.Visible = $false
            $btnCastHero.CardData.Title = '开始投屏'
            $btnCastHero.CardData.Sub   = '正在等待设备检测…'
            $btnCastHero.CardData.Muted = $true
            $btnWirelessHero.CardData.Title = '无线连接…'
            $btnWirelessHero.CardData.Sub   = '配对码 / IP / 切无线'
        } elseif (-not $result.Success) {
            $script:uiState.DotColor = $cAmber
            $script:uiState.DevTitle = '连接状态待确认'
            $script:uiState.DevMeta  = '暂时无法读取 ADB，请重试或打开设备管理'
            $script:uiState.PillText = '待确认'
            $script:uiState.PillBg   = $cAmberBg; $script:uiState.PillFg = $cAmber; $script:uiState.PillBd = $cAmberBorder
            $script:uiState.CanSwitch = $false
            $script:uiState.RightMode = 'refresh'
            $btnDevices.Text = '重试'
            $lblFooterMeta.Text = '待确认'
            $pnlGuide.Visible = $false
            $btnCastHero.CardData.Title = '开始投屏'
            $btnCastHero.CardData.Sub   = '点击重试或查看设备管理'
            $btnCastHero.CardData.Muted = $true
            $btnWirelessHero.CardData.Title = '无线连接…'
            $btnWirelessHero.CardData.Sub   = '配对码 / IP / 切无线'
        } elseif ($devs.Count -gt 0) {
            $w = $devs | Where-Object { Test-Wireless $_ } | Select-Object -First 1
            $sel = $script:uiState.SelectedSerial
            if (-not $sel -or ($devs -notcontains $sel)) {
                $sel = if ($settings.defaultDevice -and ($devs -contains $settings.defaultDevice)) { $settings.defaultDevice }
                       elseif ($w) { $w }
                       else { $devs[0] }
                $script:uiState.SelectedSerial = $sel
            }
            $isWl = Test-Wireless $sel
            $isDefault = ($settings.defaultDevice -eq $sel)
            $info = Get-DevInfo $sel -CachedOnly
            $ver = if ($info.Ver -gt 0) { "Android $($info.Ver)" } else { '' }
            $star = if ($isDefault -and $devs.Count -gt 1) { '★ ' } else { '' }
            $script:uiState.DotColor = $cGreen
            $script:uiState.DevTitle = "$star$(Get-FriendlyName $sel -CachedOnly)"
            $metaParts = @()
            if ($ver) { $metaParts += $ver }
            $metaParts += $sel
            if ($devs.Count -gt 1) { $metaParts += '点击名称切换设备' }
            $script:uiState.DevMeta  = ($metaParts -join ' · ')
            $script:uiState.PillText = if ($isWl) { 'Wi-Fi' } else { 'USB' }
            $script:uiState.PillBg   = if ($isWl) { $cGreenBg } else { $cSoft }
            $script:uiState.PillFg   = if ($isWl) { $cGreen } else { $cText2 }
            $script:uiState.PillBd   = if ($isWl) { $cGreenBorder } else { $cLine }
            $script:uiState.CanSwitch = ($devs.Count -gt 1)
            $script:uiState.RightMode = 'devices'
            $btnDevices.Text = '设备管理'
            $lblFooterMeta.Text = "$($devs.Count) 台在线"
            $pnlGuide.Visible = $false
            $btnCastHero.CardData.Title = '开始投屏'
            $btnCastHero.CardData.Sub   = if ($isWl) { "通过 Wi-Fi · $sel" } else { '通过数据线 · 低延迟最稳定' }
            $btnCastHero.CardData.Muted = $false
            if (-not $isWl) {
                $btnWirelessHero.CardData.Title = '切到无线'
                $btnWirelessHero.CardData.Sub   = '转 Wi-Fi 后可拔线'
            } else {
                $btnWirelessHero.CardData.Title = '无线连接…'
                $btnWirelessHero.CardData.Sub   = '配对码 / IP / 新设备'
            }
        } else {
            $script:uiState.SelectedSerial = ''
            $script:uiState.CanSwitch = $false
            $btnCastHero.CardData.Title = '开始投屏'
            $btnCastHero.CardData.Muted = $true
            $btnWirelessHero.CardData.Title = '无线连接…'
            $btnWirelessHero.CardData.Sub   = '配对码 / IP 直连'
            if ($result.UnavailableStates -contains 'unauthorized') {
                $script:uiState.DotColor = $cAmber
                $script:uiState.DevTitle = '等待手机授权'
                $script:uiState.DevMeta  = '请解锁手机，在弹窗勾选并点「允许 USB 调试」'
                $script:uiState.PillText = '需手机确认'
                $script:uiState.PillBg   = $cAmberBg; $script:uiState.PillFg = $cAmber; $script:uiState.PillBd = $cAmberBorder
                $script:uiState.RightMode = 'refresh'
                $btnDevices.Text = '重试'
                $lblFooterMeta.Text = '等待授权'
                $pnlGuide.Visible = $false
                $btnCastHero.CardData.Sub = '请在手机点允许后再试'
            } elseif ($result.UnavailableStates -contains 'offline') {
                $script:uiState.DotColor = $cAmber
                $script:uiState.DevTitle = '手机离线'
                $script:uiState.DevMeta  = '请重新插拔数据线，或检查 Wi-Fi 后重试'
                $script:uiState.PillText = '离线'
                $script:uiState.PillBg   = $cAmberBg; $script:uiState.PillFg = $cAmber; $script:uiState.PillBd = $cAmberBorder
                $script:uiState.RightMode = 'refresh'
                $btnDevices.Text = '重试'
                $lblFooterMeta.Text = '手机离线'
                $pnlGuide.Visible = $true
                $btnCastHero.CardData.Sub = '设备未响应，重连后可投屏'
            } else {
                $script:uiState.DotColor = $cMuted
                $script:uiState.DevTitle = '未检测到手机'
                $script:uiState.DevMeta  = '插数据线并允许 USB 调试，或选下方无线连接'
                $script:uiState.PillText = ''
                $script:uiState.RightMode = 'refresh'
                $btnDevices.Text = '刷新'
                $lblFooterMeta.Text = '未连接'
                $pnlGuide.Visible = $true
                $btnCastHero.CardData.Sub = '连上手机后即可一键投屏'
            }
        }
        $btnDevName.Cursor = if ($script:uiState.CanSwitch) { [System.Windows.Forms.Cursors]::Hand } else { [System.Windows.Forms.Cursors]::Default }
        $lblCardMeta.Text = $script:uiState.DevMeta
        $pnlDevTop.Invalidate(); $btnDevName.Invalidate()
        $btnCastHero.Invalidate(); $btnWirelessHero.Invalidate()
        & $syncFindPhoneButton
        & $syncLiveSession
        & $layoutMainBody
    }

    # ---------------- 行为 ----------------
    $renderStatus = {
        param($result)
        if ($script:mainFlow.Busy) {
            # 忙态结束后再查，避免用操作前拿到的结果覆盖新状态。
            $script:mainFlow.RefreshPending = $true
            return
        }
        if (-not $result.Success) {
            $lblStatus.BackColor=$cTagBg; $lblStatus.ForeColor=$cMuted
            $lblStatus.Text='○ 状态待确认'
            $tt.SetToolTip($lblStatus, '暂时无法确认手机连接状态。切回窗口会重试，也可以点击打开「设备管理」查看原因。')
            $lblDevInfo.Text=''
            if ($syncDeviceCard) { & $syncDeviceCard $result }
            return
        }
        $devs=@($result.Devices)
        if ($devs.Count -eq 0 -and $settings.autoConnect -and $settings.lastWirelessAddr) {
            Reconnect-LastAsync $settings.lastWirelessAddr $renderConnectedStatus
        }
        if ($devs.Count -gt 0) {
            $w = $devs | Where-Object { Test-Wireless $_ } | Select-Object -First 1
            if ($w) {
                if ($settings.lastWirelessAddr -ne $w) { $settings.lastWirelessAddr = $w; Save-Settings }
                Add-KnownDevice $w (Get-FriendlyName $w -CachedOnly)   # 任何方式连上的无线设备都自动记住，供「设备管理」重连
            }
            $isDefault = $settings.defaultDevice -and ($devs -contains $settings.defaultDevice)
            $dev = if ($isDefault) { $settings.defaultDevice } elseif ($w) { $w } else { $devs[0] }
            $type = if (Test-Wireless $dev) { '无线' } else { 'USB' }
            $lblStatus.BackColor = $cGreenBg; $lblStatus.ForeColor = $cGreen
            $lblStatus.Text = "● 已连接 $type"
            $tt.SetToolTip($lblStatus, $statusTip)
            $info = Get-DevInfo $dev -CachedOnly
            $ver = if ($info.Ver -gt 0) { " · Android $($info.Ver)" } else { '' }
            $star = if ($isDefault -and $devs.Count -gt 1) { '★ ' } else { '' }
            $lblDevInfo.Text = "$star$(Get-FriendlyName $dev -CachedOnly)$ver"
        } else {
            $lblStatus.BackColor = $cTagBg; $lblStatus.ForeColor = $cMuted
            $lblDevInfo.Text = ''
            if ($result.UnavailableStates -contains 'unauthorized') {
                $lblStatus.Text = '○ 等待手机授权'
                $tt.SetToolTip($lblStatus, "USB 连接：解锁手机并点「允许 USB 调试」。无线连接：确认手机仍记着这台电脑的配对记录。$statusTip")
            } elseif ($result.UnavailableStates -contains 'offline') {
                $lblStatus.Text = '○ 手机离线'
                $tt.SetToolTip($lblStatus, "手机暂未响应。请重新插拔数据线，或检查 Wi-Fi 后重新连接。$statusTip")
            } else {
                $lblStatus.Text = '○ 未连接'
                $tt.SetToolTip($lblStatus, $statusTip)
            }
        }
        if ($syncDeviceCard) { & $syncDeviceCard $result }
    }
    $renderConnectedStatus = {
        param($result)
        if ($result.Success -and $result.Devices.Count -gt 0) { & $renderStatus $result }
    }
    $updateStatus = {
        if ($script:mainFlow.Busy -or $script:closeState.InProgress) {
            $script:mainFlow.RefreshPending = $true
            return
        }
        $script:mainFlow.RefreshPending = $false
        Start-DeviceScan -Owner $form -Kind 'status' -OnDone $renderStatus
    }
    $requestStopPhoneRing = {
        if (-not $script:phoneRing -or $script:phoneRing.Finished) { return }
        Stop-PhoneRing $script:phoneRing
        & $syncFindPhoneButton
        & $syncLiveSession
    }
    $phoneRingTimer = New-Object System.Windows.Forms.Timer
    $phoneRingTimer.Interval = 150
    $phoneRingTimer.Add_Tick({
        $ring = $script:phoneRing
        $phase = $ring.Phase
        Update-PhoneRing $ring
        if ($ring.Finished) {
            $phoneRingTimer.Stop()
            $script:phoneRing = $null
            & $syncFindPhoneButton
            & $syncLiveSession
            if ($ring.Failed) {
                if ($ring.Detail -match 'FIND_PHONE_RESTORE_FAILED') {
                    $heading = '未能恢复闹钟音量'
                    $body = '请在手机上检查闹钟音量。'
                } elseif ($ring.Detail -match 'FIND_PHONE_VOLUME_UNAVAILABLE') {
                    $heading = '手机未能调至最大闹钟音量'
                    $body = '请检查手机的音量和勿扰设置。'
                } elseif ($ring.Detail -match 'FIND_PHONE_RINGTONE_UNAVAILABLE') {
                    $heading = '无法读取手机当前的来电铃声'
                    $body = '请在手机的声音设置中选一首能正常播放的来电铃声，再重试。'
                } else {
                    $heading = '手机响铃未能继续'
                    $body = '请确认手机仍在线后重试。'
                }
                if ($form.Visible) { [void](Show-ResultDialog $form '寻找手机' $heading $body $ring.Detail) }
                else { & $script:showTempHint $heading $cRed 8000 }
            } else { & $script:showTempHint '已停止响铃。' $cMuted 6000 }
        } elseif ($phase -eq 'starting' -and $ring.Phase -eq 'playing') {
            & $script:showTempHint "「$($ring.DeviceName)」正在响铃，点「■ 停止」结束。" $cRed $null
            & $syncLiveSession
        }
    })
    $btnFindPhone.Add_Click({
        if ($script:phoneRing) {
            & $requestStopPhoneRing
            return
        }
        Invoke-MainFlow -WithDevices -Source $btnFindPhone ({
            param($devices)
            $devs = @($devices)
            if ($devs.Count -eq 0) {
                [void](Show-ResultDialog $form '寻找手机' '没检测到手机' '请用数据线连接并允许 USB 调试，或点「无线连接…」。')
                return
            }
            $serial = if ($devs.Count -eq 1) { $devs[0] }
                      else {
                          Select-Device $form $devs '寻找手机 · 选择设备' '检测到多台设备，选择要寻找的一台：' '寻找这台' -SelectedSerial $script:uiState.SelectedSerial
                      }
            if (-not $serial) { return }
            try { $script:phoneRing = Start-PhoneRing $serial }
            catch {
                [void](Show-ResultDialog $form '寻找手机' '无法启动响铃' '请确认手机仍在线后重试。' $_.Exception.Message)
                return
            }
            $script:phoneRing.DeviceName = Get-FriendlyName $serial -CachedOnly
            & $syncFindPhoneButton
            & $syncLiveSession
            & $script:showTempHint "正在让「$($script:phoneRing.DeviceName)」响铃…" $cMuted $null
            $script:hintKeepAfterFlow = $true
            $phoneRingTimer.Start()
        })
    })
    $form.Add_FormClosed({
        $phoneRingTimer.Dispose()
        if ($script:phoneRing) {
            Stop-PhoneRing $script:phoneRing
            $script:phoneRing.Process.Dispose()
            $script:phoneRing = $null
        }
    })
    $btnShortcuts.Add_Click({ Invoke-MainFlow ({ Show-Shortcuts $form }) })
    $btnSettings.Add_Click({
        Invoke-MainFlow ({ Show-Settings $form })
        if ($syncCapsules) { & $syncCapsules }
    })
    $btnFiles.Add_Click({ Invoke-MainFlow -WithDevices -Source $btnFiles ({
        param($devices)
        Show-FileManager $form $devices
    }) })
    $openDevices = {
        Invoke-MainFlow ({ Show-DeviceManager $form })
        if ($script:mainFlow.Busy) { return }
        # 模态窗口关闭后，主流程才恢复旧状态。此时排队刷新，即使定时查询暂停也能同步。
        $lblStatus.BackColor=$cTagBg; $lblStatus.ForeColor=$cMuted
        $lblStatus.Text='◌ 检测中…'
        $lblDevInfo.Text=''
        $tt.SetToolTip($lblStatus, $statusTip)
        if ($syncDeviceCard) { & $syncDeviceCard $null }
        & $updateStatus
    }
    $btnDevices.Add_Click({
        if ($script:uiState.RightMode -eq 'refresh') {
            $lblStatus.BackColor = $cTagBg; $lblStatus.ForeColor = $cMuted
            $lblStatus.Text = '◌ 检测中…'; $lblDevInfo.Text = ''
            & $syncDeviceCard $null
            & $updateStatus
        } else {
            & $openDevices
        }
    })
    $lblStatus.Add_Click($openDevices)

    $btnDevName.Add_Click({
        $devs = @($script:uiState.OnlineDevices)
        if ($devs.Count -le 1) { return }
        $devMenu.Items.Clear()
        foreach ($d in $devs) {
            $wl = Test-Wireless $d
            $star = if ($settings.defaultDevice -eq $d) { '★ ' } else { '' }
            $chkMark = if ($script:uiState.SelectedSerial -eq $d) { '✓ ' } else { '   ' }
            $mi = New-Object System.Windows.Forms.ToolStripMenuItem("$chkMark$star$(Get-FriendlyName $d -CachedOnly) · $(if ($wl) { 'Wi-Fi' } else { 'USB' })")
            $serialCopy = $d
            $mi.Add_Click({
                $script:uiState.SelectedSerial = $serialCopy
                if ($script:uiState.LastResult) { & $syncDeviceCard $script:uiState.LastResult }
                & $script:showTempHint "已切换当前设备：$(Get-FriendlyName $serialCopy -CachedOnly)" $cText2 4000
            }.GetNewClosure())
            [void]$devMenu.Items.Add($mi)
        }
        [void]$devMenu.Items.Add('-')
        $miMgr = New-Object System.Windows.Forms.ToolStripMenuItem('管理全部设备…')
        $miMgr.Add_Click($openDevices)
        [void]$devMenu.Items.Add($miMgr)
        $devMenu.Show($btnDevName, 0, $btnDevName.Height)
    })

    $btnGuidePair.Add_Click({ Invoke-MainFlow ({
        $addr = Show-WirelessPair $form
        if ($addr) {
            if ($settings.lastWirelessAddr -ne $addr) { $settings.lastWirelessAddr = $addr; Save-Settings }
            Touch-KnownDevice $addr (Get-FriendlyName $addr -CachedOnly)
            $script:uiState.SelectedSerial = $addr
            & $updateStatus
            Start-Scrcpy (@('-s', $addr) + (Get-MirrorArgs -Wireless:$true))
            & $syncLiveSession
        }
    }) })
    $btnGuideIp.Add_Click({ Invoke-MainFlow ({
        $addr = Connect-ByIp $form
        if ($addr) {
            if ($settings.lastWirelessAddr -ne $addr) { $settings.lastWirelessAddr = $addr; Save-Settings }
            $script:uiState.SelectedSerial = $addr
            & $updateStatus
            Start-Scrcpy (@('-s', $addr) + (Get-MirrorArgs -Wireless:$true))
            & $syncLiveSession
        }
    }) })
    $btnGuideHelp.Add_Click({ Invoke-MainFlow ({
        [void](Show-ResultDialog $form '如何开启 USB 调试' '三步开启调试权限' "1. 打开手机「设置 > 关于手机」，连续点击 7 次「版本号」开启开发者模式。`n2. 返回「设置 > 开发者选项」，打开「USB 调试」。`n3. 用支持数据传输的 USB 线连接电脑，并在手机弹窗点击「允许 USB 调试」。`n`n完整说明见同目录「使用说明.txt」第一节。" '' @('ok'))
    }) })

    $btnQuickStop.Add_Click({
        Update-ProcessLifecycle
        $activeProcs = @($scrcpyProcs | Where-Object { $_.Proc -and -not (Test-ProcessExited $_.Proc) })
        if ($activeProcs.Count -eq 0 -and $script:phoneRing -and -not $script:phoneRing.Finished) {
            & $requestStopPhoneRing
            return
        }
        Invoke-MainFlow ({
            $res = Stop-DevicesUi $form -All
            if ($script:phoneRing -and -not $script:phoneRing.Finished) { & $requestStopPhoneRing }
            & $syncLiveSession
            if ($res -and $res.Success) {
                & $script:showTempHint '已停止当前运行的投屏 / 录制会话' $cGreen 4000
                $script:hintKeepAfterFlow = $true
            }
        })
    })

    $btnCapAudio.Add_Click({
        if ($script:mainFlow.Busy) { return }
        $settings.audioOn = (-not [bool]$settings.audioOn)
        Save-Settings; & $syncCapsules
        & $script:showTempHint $(if ($settings.audioOn) { '已开启「传声音」（新投屏生效）' } else { '已关闭「传声音」（新投屏生效）' }) $cText2 3500
    })
    $btnCapScreenOff.Add_Click({
        if ($script:mainFlow.Busy) { return }
        $settings.screenOff = (-not [bool]$settings.screenOff)
        Save-Settings; & $syncCapsules
        & $script:showTempHint $(if ($settings.screenOff) { '已开启「投屏息屏」（新投屏生效）' } else { '已关闭「投屏息屏」（新投屏生效）' }) $cText2 3500
    })
    $btnCapOnTop.Add_Click({
        if ($script:mainFlow.Busy) { return }
        $settings.onTop = (-not [bool]$settings.onTop)
        Save-Settings; & $syncCapsules
        & $script:showTempHint $(if ($settings.onTop) { '已开启「窗口置顶」（新投屏生效）' } else { '已关闭「窗口置顶」（新投屏生效）' }) $cText2 3500
    })
    $btnCapRes.Add_Click({
        if ($script:mainFlow.Busy) { return }
        $resMenu.Items.Clear()
        foreach ($opt in @(
            @{ Text = '原画（不限制）'; Val = 0 },
            @{ Text = '1920 px（超清）'; Val = 1920 },
            @{ Text = '1496 px（均衡推荐）'; Val = 1496 },
            @{ Text = '1280 px（更流畅）'; Val = 1280 },
            @{ Text = '960 px（弱网省流）'; Val = 960 }
        )) {
            $mark = if ([int]$settings.maxSize -eq $opt.Val) { '✓ ' } else { '   ' }
            $mi = New-Object System.Windows.Forms.ToolStripMenuItem("$mark$($opt.Text)")
            $v = $opt.Val
            $mi.Add_Click({
                $settings.maxSize = $v
                Save-Settings; & $syncCapsules
                $label = if ($v -le 0) { '原画（不限制）' } else { "$v px" }
                & $script:showTempHint "清晰度上限已改为 $label（新投屏生效）" $cText2 3500
            }.GetNewClosure())
            [void]$resMenu.Items.Add($mi)
        }
        $resMenu.Show($btnCapRes, 0, $btnCapRes.Height)
    })

    # 主操作防重入。标志必须走「哈希表 + 引用」。
    $script:mainFlow = @{ Busy = $false; RefreshPending = $false }
    $script:dmFlow = @{ Busy = $false }
    $script:fmFlow = @{ Busy = $false }
    $script:busyCards    = @($btnCastHero, $btnWirelessHero, $btnFiles, $btnCamera, $btnRecord, $btnNd)
    $script:busyCapsules = @($btnCapAudio, $btnCapScreenOff, $btnCapOnTop, $btnCapRes)
    $script:busyLinks    = @($btnFindPhone, $btnShortcuts, $btnSettings, $btnDevices)
    $script:busySnap = @()
    function Set-BusyLook {
        param([bool]$On, $Source)
        if (-not $On) {
            foreach ($b in $script:busyCards) { if ($b.CardData) { $b.CardData.Dimmed = $false; $b.Invalidate() } }
            foreach ($c in $script:busyCapsules) { if ($c.CapData) { $c.CapData.Dimmed = $false; $c.Invalidate() } }
            foreach ($l in $script:busyLinks) {
                if ($l -eq $btnFindPhone) { & $syncFindPhoneButton }
                else { $l.ForeColor = if ($l -eq $btnDevices) { $cInk } else { $cText2 }; $l.Invalidate() }
            }
            return
        }
        foreach ($b in $script:busyCards) {
            if ($b -eq $Source) { continue }
            if ($b.CardData) { $b.CardData.Dimmed = $true; $b.Invalidate() }
        }
        foreach ($c in $script:busyCapsules) { if ($c.CapData) { $c.CapData.Dimmed = $true; $c.Invalidate() } }
        $ringActive = ($null -ne $script:phoneRing -and -not $script:phoneRing.Finished)
        foreach ($l in $script:busyLinks) {
            if ($l -eq $btnFindPhone -and $ringActive) { continue }
            $l.ForeColor = $cBusyLink; $l.Invalidate()
        }
    }
    function Invoke-MainFlow {
        param([scriptblock]$Body, $Owner, $Flag, $Source, [switch]$WithDevices)
        if (-not $Flag) { $Flag = $script:mainFlow }
        if ($Flag.Busy) {
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
            try { $form.ActiveControl = $null } catch {}
            $statusSnap = @{ Text = $lblStatus.Text; Back = $lblStatus.BackColor; Fore = $lblStatus.ForeColor }
            $lblStatus.BackColor = $cTagBg; $lblStatus.ForeColor = $cMuted
            $lblStatus.Text = '○ 正在处理…'
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
        & $script:showTempHint '无法读取设备列表，请重试。' $cRed 8000
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
            if ($syncLiveSession) { & $syncLiveSession }
        }
        $Flag.Busy = $false
        if ($isMain -and $Flag.RefreshPending) { & $updateStatus }
    }

    # 主按钮：开始投屏（按当前选中设备直连投屏，无设备时提示）
    $btnCastHero.Add_Click({ Invoke-MainFlow -WithDevices -Source $btnCastHero ({
        param($devices)
        $devs = @($devices)
        if ($devs.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("没检测到手机。请用数据线连接并点「允许 USB 调试」，或点右侧「无线连接…」。`n`n不会开 USB 调试？看同目录的「使用说明.txt」第一节。", '开始投屏') | Out-Null
            return
        }
        $t = if ($script:uiState.SelectedSerial -and ($devs -contains $script:uiState.SelectedSerial)) { $script:uiState.SelectedSerial }
             elseif ($devs.Count -eq 1) { $devs[0] }
             elseif ($settings.defaultDevice -and ($devs -contains $settings.defaultDevice)) { $settings.defaultDevice }
             else { Select-Device $form $devs '开始投屏 · 选择设备' }
        if ($t) {
            Start-Scrcpy (@('-s', $t) + (Get-MirrorArgs -Wireless:(Test-Wireless $t)))
            & $syncLiveSession
        }
    }) })

    # 次主按钮：切到无线 / 无线连接…（保留 $pick.Tag -eq 'cable' 结构供回归测试抽取）
    $btnWirelessHero.Add_Click({ Invoke-MainFlow -WithDevices -Source $btnWirelessHero ({
        param($devices)
        $devs = @($devices)
        $usb = @($devs | Where-Object { -not (Test-Wireless $_) })
        $sel = $script:uiState.SelectedSerial
        $selIsUsb = ($sel -and ($usb -contains $sel))
        if ($selIsUsb) {
            Start-WirelessMirror $form $sel
            & $syncLiveSession
            return
        }
        if ($devs.Count -gt 0 -and $usb.Count -ge 1 -and $devs.Count -eq $usb.Count) {
            $t = if ($usb.Count -eq 1) { $usb[0] } else { Select-Device $form $usb }
            if ($t) { Start-WirelessMirror $form $t; & $syncLiveSession }
            return
        }
        # 没有 USB 设备（或已连无线想配对新设备）：三条路——插线切无线 / 配对码 / 输入 IP 直连
        $pick = New-Dialog '无线连接' 360 268 $form
        $pl = New-Lbl '选择一种无线连接方式：' 16 14
        $btnCable = New-PrimaryBtn '插数据线切到无线' 16 44 328 46 11
        $capCable = New-Caption '插一次线即可，连上后自动切无线、可拔线。' 20 96
        $btnPair = New-SecondaryBtn '用配对码连接（Android 11+ · 免插线）' 16 118 328 40
        $capPair = New-Caption '手机开「无线调试 → 使用配对码配对设备」。' 20 164
        $btnIpc = New-SecondaryBtn '输入 IP 连接' 16 186 328 40
        $capIp = New-Caption '适用于已配对或已用数据线启用无线连接的手机。' 20 232

        $btnCable.Add_Click({ $pick.Tag = 'cable'; $pick.Close() })
        $btnPair.Add_Click({ $pick.Tag = 'pair'; $pick.Close() })
        $btnIpc.Add_Click({ $pick.Tag = 'ip'; $pick.Close() })
        $pick.Controls.AddRange(@($pl, $btnCable, $capCable, $btnPair, $capPair, $btnIpc, $capIp))
        New-EscCancel $pick
        [void]$pick.ShowDialog($form)

        if ($pick.Tag -eq 'cable') {
            $devs = @(); $wantIp = $false
            while ($true) {
                $ask = Show-ResultDialog $form '连接手机' '插一次数据线，之后就能免线' "1. 用数据线把手机连上电脑`n2. 手机上点「允许 USB 调试」`n`n连好后点「继续」，会自动切到无线，之后就能拔掉数据线。" '' @('continue', 'cancel')
                if ($ask -ne 'continue') { return }
                $snapshot = Wait-DeviceScan $form
                if ($snapshot.Cancelled) { return }
                if (-not $snapshot.Success) { Show-DeviceQueryFailure; return }
                $devs = @($snapshot.Devices)
                if ($devs.Count -gt 0) { break }
                $again = Show-ResultDialog $form '连接手机' '没有检测到可用的设备' "请用支持数据传输的 USB 线连接手机，解锁手机并点「允许 USB 调试」，再选「重试」。已配对的手机也可选「输入 IP 连接」。`n`n开启 USB 调试的步骤见「使用说明.txt」第一节。" '' @('retry', 'ip', 'cancel')
                if ($again -eq 'ip') { $wantIp = $true; break }
                if ($again -ne 'retry') { return }
            }
            if ($wantIp) {
                $addr = Connect-ByIp $form
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
            if ($t) { Start-WirelessMirror $form $t }
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
            $addr = Connect-ByIp $form
            if ($addr) {
                if ($settings.lastWirelessAddr -ne $addr) { $settings.lastWirelessAddr = $addr; Save-Settings }
                Start-Scrcpy (@('-s', $addr) + (Get-MirrorArgs -Wireless:$true))
            }
        }
    }) })

    $btnCamera.Add_Click({ Invoke-MainFlow -WithDevices -Source $btnCamera ({
        param($devices)
        $serial = Resolve-TargetForFeature $form 12 '手机当摄像头' -Devices $devices
        if (-not $serial) { return }
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $camSizes = Get-CameraSizes $serial $form
        if ($null -eq $camSizes) { return }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $dlg = New-Dialog '手机当摄像头' 316 446 $form
        $camState = @{
            Facing = $(if ($settings.camFacing -eq 'front') { 'front' } else { 'back' })
            Orient = $(if ($settings.camOrientation -eq 'port') { 'port' } else { 'land' })
        }

        $cardOrient = New-Object System.Windows.Forms.Panel
        $cardOrient.Location = New-Object System.Drawing.Point(16, 94); $cardOrient.Size = New-Object System.Drawing.Size(284, 98)
        Set-CardStyle $cardOrient 10 $cWhite $cLine
        $lOrient = New-Lbl '画面方向' 12 10; $lOrient.ForeColor = $cText2; $lOrient.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
        $segOrient = New-SegSwitch @('横屏', '竖屏') @('land', 'port') $camState.Orient 12 33 260 30 ({
            param($val)
            $camState.Orient = [string]$val
        }.GetNewClosure())
        $chkRotate180 = New-Chk '旋转 180°（手机倒置时修正）' $settings.camRotate180 12 69
        $tt.SetToolTip($chkRotate180, '手机倒置时勾选，在横屏或竖屏基础上再旋转 180°，不是左右镜像。点「开始预览」后记住。')
        $cardOrient.Controls.AddRange(@($lOrient, $segOrient, $chkRotate180))

        $cardParam = New-Object System.Windows.Forms.Panel
        $cardParam.Location = New-Object System.Drawing.Point(16, 202); $cardParam.Size = New-Object System.Drawing.Size(284, 112)
        Set-CardStyle $cardParam 10 $cWhite $cLine
        $lblRes = New-Lbl '分辨率' 12 14; $lblRes.ForeColor = $cText2; $lblRes.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
        $cbRes = New-Combo @('自动') @('auto') 'auto' 82 11 190
        $tt.SetToolTip($cbRes, '前置和后置各使用手机报告的第一颗镜头。分辨率和变焦范围随所选镜头变化。')
        $lblZoom = New-Lbl '初始倍率' 12 48; $lblZoom.ForeColor = $cText2; $lblZoom.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
        $nudZoom = New-Object System.Windows.Forms.NumericUpDown
        $nudZoom.DecimalPlaces = 1; $nudZoom.Increment = [decimal]0.1
        $nudZoom.Location = New-Object System.Drawing.Point(82, 45); $nudZoom.Size = New-Object System.Drawing.Size(96, 26)
        $nudZoom.BorderStyle = 'FixedSingle'; $nudZoom.BackColor = $cWhite
        $capRes = New-Caption '' 12 77
        $capRes.MaximumSize = New-Object System.Drawing.Size(260, 0)
        $cardParam.Controls.AddRange(@($lblRes, $cbRes, $lblZoom, $nudZoom, $capRes))

        $fillRes = {
            param($facing)
            $list = @($camSizes[$facing])
            $cbRes.Items.Clear()
            if ($list.Count -gt 0) {
                $capRes.Text = '打不开可降一档分辨率；投屏中按 Alt + ↑ / ↓ 实时变焦'
                foreach ($size in $list) { [void]$cbRes.Items.Add($size) }
                $cbRes.Vals = [array]$list
            } else {
                $capRes.Text = '暂读不到镜头分辨率，先试「中」档；Alt + ↑ / ↓ 可变焦'
                [void]$cbRes.Items.Add('高（约 1080p，推荐）')
                [void]$cbRes.Items.Add('中（更流畅）')
                [void]$cbRes.Items.Add('原始最高')
                $cbRes.Vals = @('1920', '1280', '0')
            }
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
        $fillZoom = {
            param($facing)
            $rg = $camSizes.zoom[$facing]
            $lo = if ($rg) { [decimal]$rg[0] } else { [decimal]0.1 }
            $hi = if ($rg) { [decimal]$rg[1] } else { [decimal]100 }
            $nudZoom.Minimum = $lo; $nudZoom.Maximum = $hi
            $v = [decimal](Get-CamZoom $serial $facing)
            if ($v -lt $lo) { $v = $lo }; if ($v -gt $hi) { $v = $hi }
            $nudZoom.Value = $v
        }

        $cardCam = New-Object System.Windows.Forms.Panel
        $cardCam.Location = New-Object System.Drawing.Point(16, 12); $cardCam.Size = New-Object System.Drawing.Size(284, 72)
        Set-CardStyle $cardCam 10 $cWhite $cLine
        $lCam = New-Lbl '摄像头' 12 10; $lCam.ForeColor = $cText2; $lCam.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
        $lVer = New-Caption 'Android 12+' 206 11
        # GetNewClosure 会捕获当时的变量值，先定义刷新函数才能让切换镜头时调用它们。
        $segFacing = New-SegSwitch @('后置镜头', '前置镜头') @('back', 'front') $camState.Facing 12 33 260 30 ({
            param($val)
            $camState.Facing = [string]$val
            & $fillRes $camState.Facing
            & $fillZoom $camState.Facing
        }.GetNewClosure())
        $cardCam.Controls.AddRange(@($lCam, $lVer, $segFacing))
        & $fillRes $camState.Facing
        & $fillZoom $camState.Facing

        $cardOpt = New-Object System.Windows.Forms.Panel
        $cardOpt.Location = New-Object System.Drawing.Point(16, 324); $cardOpt.Size = New-Object System.Drawing.Size(284, 62)
        Set-CardStyle $cardOpt 10 $cWhite $cLine
        $chkTorch = New-Chk '打开补光灯' $settings.camTorch 12 9
        $chkMic = New-Chk '同时采集麦克风声音' $settings.camMic 12 34
        $cardOpt.Controls.AddRange(@($chkTorch, $chkMic))

        $btnGo = New-PrimaryBtn '开始预览' 16 396 284 38 11
        $btnGo.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Close() })

        $dlg.Controls.AddRange(@($cardCam, $cardOrient, $cardParam, $cardOpt, $btnGo))
        $dlg.AcceptButton = $btnGo
        New-EscCancel $dlg
        if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $selVal = [string]$cbRes.Vals[$cbRes.SelectedIndex]
            $facing = $camState.Facing
            $isPort = ($camState.Orient -eq 'port')
            $zs = Format-Zoom $nudZoom.Value
            Set-CamRemembered $serial $facing $selVal
            Set-CamZoom $serial $facing $zs
            $settings.camFacing = $facing
            $settings.camOrientation = $camState.Orient
            $settings.camRotate180 = $chkRotate180.Checked
            $settings.camTorch = $chkTorch.Checked
            $settings.camMic = $chkMic.Checked
            Save-Settings
            $a = @('-s', $serial, '--video-source=camera') + @(Get-CameraSelectionArgs $camSizes $facing)
            if ($zs -ne '1') { $a += "--camera-zoom=$zs" }
            if ($selVal -match '^\d+x\d+$') {
                $a += "--camera-size=$selVal"
            } else {
                $a += '--camera-ar=16:9'
                if ([int]$selVal -gt 0) { $a += @('-m', "$selVal") }
            }
            $fitSize = $selVal
            if ($fitSize -match '^(\d+)$') {
                $longEdge = [int]$fitSize
                if ($longEdge -gt 0) { $fitSize = '{0}x{1}' -f $longEdge, [int][Math]::Round($longEdge * 9 / 16) }
            }
            if ($fitSize -match '^(\d+)x(\d+)$' -and $isPort) { $fitSize = "$($matches[2])x$($matches[1])" }
            $a += @(Get-FitWindowArgs $fitSize)
            $a += @(Get-CamOrientationArgs $facing $isPort $chkRotate180.Checked)
            if ($chkTorch.Checked) { $a += '--camera-torch' }
            if ($chkMic.Checked) { $a += '--audio-source=mic' } else { $a += '--no-audio' }
            $a += @(Get-HwDecArgs)
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
            $outFile = Join-Path $env:TEMP ("scrcpy-helper-cam-{0}.out.log" -f $tag)
            $p = Start-CamProc $a $errFile $outFile
            if ($p) {
                [void]$script:camSessions.Add([pscustomobject]@{
                    Serial = $serial; Facing = $facing; Args = [string[]]$a
                    Proc = $p; StartedAt = (Get-Date); ErrFile = $errFile; OutFile = $outFile; LastZoom = $null
                    Fails = 0; Proven = $false; Stopped = $false; Reconnecting=$false; SkipZoom = $false; NextTryAt = [datetime]::MinValue
                })
                $script:camWatch.Start()
                & $syncLiveSession
            }
        }
    }) })

    $btnRecord.Add_Click({
        Update-ProcessLifecycle
        $recItems = @($scrcpyProcs | Where-Object { $_.Rec -and $_.Proc -and -not (Test-ProcessExited $_.Proc) })
        if ($recItems.Count -gt 0) {
            Invoke-MainFlow -Source $btnRecord ({
                $res = Stop-DevicesUi $form -Items $recItems
                & $syncLiveSession
                if ($res -and $res.Success) {
                    & $script:showTempHint '已停止录制' $cGreen 4000
                    $script:hintKeepAfterFlow = $true
                }
            })
            return
        }
        Invoke-MainFlow -WithDevices -Source $btnRecord ({
            param($devices)
            $tgt = Resolve-Target $form -Devices $devices
            if (-not $tgt.Ok) { if ($tgt.Reason -eq 'none') { [System.Windows.Forms.MessageBox]::Show('没检测到手机，请先连接手机再录制。', '录制屏幕') | Out-Null }; return }
            $recExt = Get-RecordingExtension
            $recTarget = Resolve-RecordingPath $recExt
            $recPath = ''
            if ($recTarget.Mode -eq 'fixed') {
                $recPath = $recTarget.Path
            } else {
                if ($recTarget.Mode -eq 'missing') {
                    [System.Windows.Forms.MessageBox]::Show("设置的录制保存目录不存在：`n$($recTarget.Dir)`n`n请在接下来的窗口中手动选择保存位置。", '录制屏幕', 'OK', 'Warning') | Out-Null
                }
                $mkvOnly = ($settings.videoCodec -in @('vp8', 'vp9') -or ($settings.audioOn -and $settings.audioCodec -eq 'raw'))
                $sfd = New-Object System.Windows.Forms.SaveFileDialog
                $sfd.InitialDirectory = if ($settings.lastRecDir -and (Test-Path -LiteralPath $settings.lastRecDir -PathType Container)) { $settings.lastRecDir } else { $PSScriptRoot }
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
                if ($sfd.ShowDialog($form) -ne 'OK') { return }
                $recPath = $sfd.FileName
                $parentDir = Split-Path -Parent $recPath
                if ($parentDir -and $settings.lastRecDir -ne $parentDir) {
                    $settings.lastRecDir = $parentDir
                    Save-Settings
                }
            }
            $a = Get-RecordingArgs -Serial $tgt.Serial -Path $recPath -Wireless:(Test-Wireless $tgt.Serial)
            $newRec=Start-Scrcpy $a -Recording -PassThru
            $recStarted=($newRec -and -not (Test-ProcessExited $newRec))
            if ($recStarted) {
                $recName = [System.IO.Path]::GetFileName($recPath)
                $recTip = if ($settings.recBackground) { "● 后台录制中（$recName）· 点「停止录制」可结束" } else { "● 录制中（$recName）· 关窗或点「停止录制」可结束" }
                & $script:showTempHint $recTip $cGreen
                $script:hintKeepAfterFlow = $true
                & $syncLiveSession
            }
        })
    })

    $btnNd.Add_Click({
        # scrcpy 的 --start-app 和 --flex-display 都需要控制通道，禁用控制时无需连接设备。
        if ($settings.noControl) {
            Invoke-MainFlow ({
                [void](Show-ResultDialog $form '独立窗口' '独立窗口需要在手机上启动应用' '开启「只投屏，不允许控制手机」时，独立窗口不可用。可以用「开始投屏」只看画面。' '' @('ok'))
            }) -Source $btnNd
            return
        }
        Invoke-MainFlow -WithDevices -Source $btnNd ({
            param($devices)
            $serial = Resolve-TargetForFeature $form 11 '独立窗口' -Devices $devices   # 点击即定设备、查版本，不够直接弹提示并中止
            if (-not $serial) { return }
            Show-NewDisplay $form $serial
            if ($syncLiveSession) { & $syncLiveSession }
        })
    })

    # 设备状态轮询与运行中会话同步：仅在窗口处于前台时进行；最小化/失焦自动暂停，省电省资源
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 8000
    $timer.Add_Tick($updateStatus)

    # 摄像头看门狗与运行态条刷新
    $script:camWatch = New-Object System.Windows.Forms.Timer
    $script:camWatch.Interval = 1500
    $script:camWatch.Add_Tick({
        if ($script:closeState.InProgress) { return }
        Update-ProcessLifecycle
        if ($syncLiveSession) { & $syncLiveSession }
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
            } else {
                # 会话清理会删掉临时日志，先保存 scrcpy 返回的错误供用户查看。
                $logged = Add-ErrorLog '摄像头异常退出' "退出码：$code`r`n$errTxt"
                Remove-CamSession $cs
                $hint = if ($kind -eq 'cfg') { '摄像头配置失败，请试更低的分辨率。' }
                    elseif ($logged) { '摄像头异常退出，请查看「投屏助手-错误日志.txt」。' }
                    else { '摄像头异常退出，请重新打开摄像头。' }
                & $script:showTempHint $hint $cRed 12000
            }
          } catch { try { Remove-CamSession $cs } catch {} }   # 看门狗内部任何意外都只放弃这个会话，绝不让异常冒成弹窗
        }
        Update-ProcessLifecycle
        if ($syncLiveSession) { & $syncLiveSession }
    })
    $form.Add_Shown({
        & $syncLiveSession
        & $layoutMainBody
        & $updateStatus
        if ($settings.liveStatus -or $settings.autoConnect) { $timer.Start() }
        Connect-RememberedAsync $renderConnectedStatus
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
    $miTrayStopRec = $trayMenu.Items.Add('■ 停止录制'); $miTrayStopRec.Visible = $false
    $miTrayStopAll = $trayMenu.Items.Add('■ 停止全部会话'); $miTrayStopAll.Visible = $false
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
    $miTrayStopRec.Add_Click({
        Update-ProcessLifecycle
        $recItems = @($scrcpyProcs | Where-Object { $_.Rec -and $_.Proc -and -not (Test-ProcessExited $_.Proc) })
        if ($recItems.Count -eq 0) { & $syncLiveSession; return }
        Invoke-MainFlow ({
            $res = Stop-DevicesUi $form -Items $recItems
            & $syncLiveSession
            if ($res -and $res.Success) {
                & $script:showTempHint '已停止录制' $cGreen 4000
                $script:hintKeepAfterFlow = $true
                if ($tray.Visible) {
                    $tray.BalloonTipTitle = 'scrcpy 投屏助手'
                    $tray.BalloonTipText = '已停止录制。'
                    $tray.ShowBalloonTip(2000)
                }
            }
        })
    })
    $miTrayStopAll.Add_Click({
        Invoke-MainFlow ({
            $res = Stop-DevicesUi $form -All
            & $syncLiveSession
            if ($res -and $res.Success) {
                & $script:showTempHint '已停止当前运行的投屏 / 录制会话' $cGreen 4000
                $script:hintKeepAfterFlow = $true
                if ($tray.Visible) {
                    $tray.BalloonTipTitle = 'scrcpy 投屏助手'
                    $tray.BalloonTipText = '已停止全部投屏 / 录制会话。'
                    $tray.ShowBalloonTip(2000)
                }
            }
        })
    })
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
