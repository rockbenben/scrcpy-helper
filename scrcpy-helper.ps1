# scrcpy 投屏助手（图形界面）
# 由「投屏助手-双击运行.bat」启动，无需手动运行本文件。

Set-Location -LiteralPath $PSScriptRoot

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
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
$scrcpyProcs = New-Object System.Collections.ArrayList   # 记录本助手启动的所有 scrcpy 进程，关助手时一并停止

if (-not (Test-Path -LiteralPath $exe)) {
    [System.Windows.Forms.MessageBox]::Show('没找到 scrcpy.exe，请把本程序和 scrcpy.exe 放在同一个文件夹里。', 'scrcpy 投屏助手') | Out-Null
    return
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
$defaults = @{
    # 画面
    maxSize = 1496; maxFps = 0; bitRate = 0; videoCodec = ''; crop = ''
    # 声音
    audioOn = $true; audioSource = ''; audioCodec = ''
    # 控制
    keyboard = ''; mouse = ''; gamepad = $false; noControl = $false
    screenOff = $false; stayAwake = $true; showTouches = $false; powerOffOnClose = $false
    # 摄像头
    camResMax = 1920
    # 窗口
    fullscreen = $false; onTop = $false; borderless = $false
    # 独立窗口
    ndSize = ''; ndDpi = ''; ndNoDecor = $false
    # 录制
    recFormat = 'mp4'; recTimeLimit = 0; recBackground = $false
    # 通用
    liveStatus = $true; autoReconnect = $false; disconnectOnClose = $false; extraArgs = ''; lastWirelessAddr = ''; defaultDevice = ''
    # 记住主窗口位置（-1 = 还没记，居中显示）
    winX = -1; winY = -1
}
$settings = @{}
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
    } catch { }
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
        ($o | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $cfgPath -Encoding UTF8
    } catch { }
}

Load-Settings

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
    $sz = $settings.ndSize; $dpi = $settings.ndDpi
    $nd = if ($sz -and $dpi) { "--new-display=$sz/$dpi" } elseif ($sz) { "--new-display=$sz" } elseif ($dpi) { "--new-display=/$dpi" } else { '--new-display' }
    $a = @($nd, '--flex-display')
    if ($settings.ndNoDecor) { $a += '--no-vd-system-decorations' }
    return $a
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
    $p = if ($clean.Count -gt 0) { Start-Process -FilePath $exe -ArgumentList $clean -WorkingDirectory $PSScriptRoot -PassThru }
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
# 停止本助手启动的所有投屏：先优雅关闭（让录屏正常收尾、不损坏文件），关不掉再兜底强杀
function Stop-AllScrcpy {
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
        $out = & $adb devices 2>$null
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
        $vraw  = ((& $adb -s $serial shell getprop ro.build.version.release 2>$null | Select-Object -First 1) | Out-String).Trim()
        $model = ((& $adb -s $serial shell getprop ro.product.model       2>$null | Select-Object -First 1) | Out-String).Trim()
        if ($vraw -match '^(\d+)') { $ver = [int]$matches[1] }
        if ($vraw)  { $txt = "Android $vraw" }
        if ($model) { $txt = if ($txt) { "$txt · $model" } else { $model } }
    } catch {}
    $info = @{ Ver = $ver; Text = $txt }
    $script:devInfo[$serial] = $info
    return $info
}
# 版本门控改为「按实际目标设备」检查，见下方 Resolve-TargetForFeature（要先有 Resolve-Target）。

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
    $d = $radius * 2
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc(0, 0, $d, $d, 180, 90)
    $p.AddArc($ctl.Width - $d - 1, 0, $d, $d, 270, 90)
    $p.AddArc($ctl.Width - $d - 1, $ctl.Height - $d - 1, $d, $d, 0, 90)
    $p.AddArc(0, $ctl.Height - $d - 1, $d, $d, 90, 90)
    $p.CloseAllFigures()
    $ctl.Region = New-Object System.Drawing.Region($p)
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

# 统一风格的弹窗：标题/尺寸/居中父窗/固定边框/字体/底色一处定义，各弹窗共用
function New-Dialog {
    param($title, $w, $h, $owner)
    $d = New-Object System.Windows.Forms.Form
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
    $chkReconnect = New-Chk '无线掉线后自动重连（断了自动连回来）' $settings.autoReconnect 14 130
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
    $tabCtrl.Controls.AddRange(@(
        (New-Lbl '键盘模式：' 14 16), $cbKb,
        (New-Lbl '鼠标模式：' 14 52), $cbMouse,
        $chkNoCtrl, $chkPowerOff, $chkTouches, $chkGamepad))

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
    $tabGen.Controls.AddRange(@(
        $chkLive,
        (New-Lbl '高级·其它命令行参数（看不懂就留空，多个用空格隔开）：' 14 52), $txtExtra, $lblExHint))

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
        $settings.autoReconnect = $chkReconnect.Checked
        $settings.disconnectOnClose = $chkDisconnect.Checked
        $settings.extraArgs  = $txtExtra.Text.Trim()
        Save-Settings
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    })
    $btnReset = New-Object System.Windows.Forms.Button
    $btnReset.Text = '恢复默认'; $btnReset.Size = New-Object System.Drawing.Size(110, 34); $btnReset.Location = New-Object System.Drawing.Point(14, 292)
    $btnReset.Add_Click({
        if ([System.Windows.Forms.MessageBox]::Show('确定把所有设置恢复为默认值吗？', '恢复默认', 'YesNo', 'Warning') -eq 'Yes') {
            foreach ($k in @($defaults.Keys)) { $settings[$k] = $defaults[$k] }
            Save-Settings
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
    param($owner)
    $owner.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try { $raw = (& $exe --list-apps 2>&1) -join "`n" } catch { $raw = '' }
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
    $dlg = New-Dialog '独立窗口' 320 176 $owner

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

    $btnGo = New-PrimaryBtn '打开' 18 120 284 38 11
    $btnGo.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Close() })
    $dlg.Controls.AddRange(@($l1, $l2, $cb, $btnGo))
    $dlg.AcceptButton = $btnGo
    if ($dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) {
        $sel = [string]$cb.SelectedItem
        if ($sel -eq '管理我的常用应用…') { Show-ManageApps $owner; return }
        if ($sel -like '更多应用*') {
            $app = Show-AppPicker $owner
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
        $pre = if ($serial) { @('-s', $serial) } else { @() }
        Start-Scrcpy ($pre + (Get-NewDisplayArgs) + "--start-app=$target")
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
        try { $pairOut = (& $adb pair $pairAddr $code 2>&1) -join "`n" } catch { $pairOut = $_.Exception.Message }
        if ($pairOut -notmatch 'Successfully paired') {
            [System.Windows.Forms.MessageBox]::Show("配对失败。请核对配对地址和配对码（配对码会过期，必要时在手机上重新生成一个）。`n`n$pairOut", '配对') | Out-Null
            return
        }
        # 配对成功：用 mdns 自动发现连接端口（同一 IP，端口不同），轮询几次等服务出现
        $connAddr = $null
        for ($i = 0; $i -lt 5 -and -not $connAddr; $i++) {
            try { $mdns = (& $adb mdns services 2>&1) -join "`n" } catch { $mdns = '' }
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
        try { $connOut = (& $adb connect $connAddr 2>&1) -join "`n" } catch { $connOut = $_.Exception.Message }
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
function Resolve-Target {
    param($owner, [string]$Prefer = '')
    $devs = @(Get-DeviceList)
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
    $devs = @(Get-DeviceList)
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
        try { $out = (& $adb connect $addr 2>&1) -join "`n" } catch { $out = $_.Exception.Message }
        if ($out -match 'connected to') {
            $result.addr = $addr; $dlg.Close()
        } else {
            [System.Windows.Forms.MessageBox]::Show("连接 $addr 失败。`n`n多半是手机没开「网络 adb」。Android 11+ 在开发者选项「无线调试」里打开即可；更早的系统可先用主界面「无线投屏 → 插数据线连接」插一次线完成切换，之后即可用 IP 直连。`n`n$out", '输入 IP 连接') | Out-Null
        }
    })
    $dlg.Controls.AddRange(@($l1, $l2, $l3, $txtIp, $l4, $txtPort, $btnGo))
    $dlg.AcceptButton = $btnGo
    [void]$dlg.ShowDialog($owner)
    if ($result.addr) { Add-KnownDevice $result.addr }
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
            [void]$it.SubItems.Add($typ)
            $it.Tag = @{ Serial = $s; Connected = $true; Wireless = $wl }
            [void]$lv.Items.Add($it)
        }
        foreach ($addr in $script:knownDevices.Keys) {
            if ($connected -contains $addr) { continue }
            $it = New-Object System.Windows.Forms.ListViewItem(('○  ' + (Get-FriendlyName $addr)))
            $it.Group = $grpKnown; $it.ForeColor = $cMuted
            [void]$it.SubItems.Add($addr)
            [void]$it.SubItems.Add('无线 · 未连接')
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
            try { $out = (& $adb connect $addr 2>&1) -join "`n" } catch { $out = $_.Exception.Message }
            if ($out -match 'connected to') { Add-KnownDevice $addr } else { $fail += "$addr：$out" }
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
        try { & $adb disconnect $addr 2>$null | Out-Null } catch {}
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
        Save-Settings; & $refresh
    })
    $btnIp.Add_Click({ if (Connect-ByIp $dlg) { & $refresh } })
    $btnRefresh2.Add_Click($refresh)
    $btnDone.Add_Click({ $dlg.Close() })

    $dlg.Controls.AddRange(@($lv, $line1, $line2, $capCast, $capManage,
        $btnConnect, $btnCast, $btnStop, $btnAll, $btnDefault, $btnDisc, $btnRename, $btnForget,
        $btnIp, $btnRefresh2, $btnDone))
    $dlg.AcceptButton = $btnDone
    & $refresh
    [void]$dlg.ShowDialog($owner)
}

try {
    # ---------------- 主窗口 ----------------
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'scrcpy 投屏助手'
    $form.ClientSize = New-Object System.Drawing.Size(512, 384)
    # 记住上次的位置：存过且仍落在可见屏幕范围内就沿用，否则居中（换了显示器/分辨率也不会跑到屏幕外）
    $savedX = [int]$settings.winX; $savedY = [int]$settings.winY
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    if (($savedX -ge 0 -or $savedY -ge 0) -and $savedX -ge $vs.Left -and $savedX -le ($vs.Right - 120) -and $savedY -ge $vs.Top -and $savedY -le ($vs.Bottom - 60)) {
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
        # 掉线且开了自动重连：后台 adb connect 连回上次的无线地址（不阻塞界面，下次刷新生效）
        if ($devs.Count -eq 0 -and $settings.autoReconnect -and $settings.lastWirelessAddr) {
            Start-Process -FilePath $adb -ArgumentList @('connect', $settings.lastWirelessAddr) -WindowStyle Hidden -WorkingDirectory $PSScriptRoot
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
        $devs = @(Get-DeviceList)
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
        $devs = @(Get-DeviceList)
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
                    Add-KnownDevice $addr
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
        $dlg = New-Dialog '手机当摄像头' 264 308 $form

        $gb1 = New-Object System.Windows.Forms.GroupBox
        $gb1.Text = '摄像头'; $gb1.Location = '16,12'; $gb1.Size = '232,52'
        $rbBack = New-Object System.Windows.Forms.RadioButton; $rbBack.Text = '后置'; $rbBack.Location = '16,20'; $rbBack.AutoSize = $true; $rbBack.Checked = $true
        $rbFront = New-Object System.Windows.Forms.RadioButton; $rbFront.Text = '前置'; $rbFront.Location = '124,20'; $rbFront.AutoSize = $true
        $gb1.Controls.AddRange(@($rbBack, $rbFront))

        $gb2 = New-Object System.Windows.Forms.GroupBox
        $gb2.Text = '画面方向'; $gb2.Location = '16,74'; $gb2.Size = '232,52'
        $rbLand = New-Object System.Windows.Forms.RadioButton; $rbLand.Text = '横屏'; $rbLand.Location = '16,20'; $rbLand.AutoSize = $true; $rbLand.Checked = $true
        $rbPort = New-Object System.Windows.Forms.RadioButton; $rbPort.Text = '竖屏'; $rbPort.Location = '124,20'; $rbPort.AutoSize = $true
        $gb2.Controls.AddRange(@($rbLand, $rbPort))

        # 分辨率按「宽高比 + 最大边长」选，scrcpy 只会在该摄像头实际支持的尺寸里挑，避免写死尺寸导致的
        # “Camera configuration error”（很多机型/前置摄像头并不支持精确的 1920x1080）。
        $lblRes = New-Lbl '分辨率' 18 140
        $cbRes = New-Combo @('高（约 1080p，推荐）', '中（更流畅）', '原始最高') @(1920, 1280, 0) ([int]$settings.camResMax) 78 137 170

        $chkTorch = New-Chk '打开补光灯' $false 18 174
        $chkMic = New-Chk '同时采集麦克风声音' $false 18 200

        $btnGo = New-PrimaryBtn '开始' 16 234 232 32 11
        $btnGo.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Close() })

        $dlg.Controls.AddRange(@($gb1, $gb2, $lblRes, $cbRes, $chkTorch, $chkMic, $btnGo))
        $dlg.AcceptButton = $btnGo
        if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $camMax = [int]$cbRes.Vals[$cbRes.SelectedIndex]
            if ([int]$settings.camResMax -ne $camMax) { $settings.camResMax = $camMax; Save-Settings }
            $a = @('-s', $serial, '--video-source=camera', "--camera-facing=$(if($rbFront.Checked){'front'}else{'back'})", '--camera-ar=16:9')
            if ($camMax -gt 0) { $a += @('-m', "$camMax") }
            if ($rbPort.Checked) { $a += '--capture-orientation=90' }
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
            if ($settings.stayAwake) { $a += '-w' }
            if ([int]$settings.recTimeLimit -gt 0) { $a += "--time-limit=$($settings.recTimeLimit)" }
            if ($settings.recBackground) { $a += @('--no-window', '--no-playback') }
            Start-Scrcpy $a -Recording
            $tip = if ($settings.recBackground) { '已在后台开始录制（无画面）。' } else { '已开始录制。' }
            [System.Windows.Forms.MessageBox]::Show($tip + '关掉投屏窗口或在原命令窗口按 Ctrl+C 即停止保存。', '录制屏幕') | Out-Null
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
    $form.Add_Shown({ & $updateStatus; if ($settings.liveStatus -or $settings.autoReconnect) { $timer.Start() } })
    $form.Add_Activated({ & $updateStatus; if ($settings.liveStatus -or $settings.autoReconnect) { $timer.Start() } else { $timer.Stop() } })
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
        if ($settings.disconnectOnClose) { try { & $adb disconnect 2>$null | Out-Null } catch {} }
    })
    $form.Add_FormClosed({ $timer.Stop(); $timer.Dispose() })

    [void]$form.ShowDialog()
}
catch {
    [System.Windows.Forms.MessageBox]::Show("启动出错：`n$($_.Exception.Message)", 'scrcpy 投屏助手') | Out-Null
}
