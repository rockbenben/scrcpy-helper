$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path (Split-Path $PSScriptRoot) 'scrcpy-helper.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join "`n") }
foreach ($name in @('Start-DeviceScan','Start-UiTask','Complete-MainFlow','Reconnect-LastAsync','Wait-DeviceScan','Invoke-DeviceScan',
        'Test-Wireless','Test-TcpAddress','Test-MdnsSerial')) {
    $definition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

function Check($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Get-Action($Scope, [string]$Name) {
    $assignment = $Scope.Find({ param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq ('$' + $Name)
    }, $true)
    return $assignment.Right.Expression.ScriptBlock.GetScriptBlock()
}
$fileManager = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Show-FileManager'
}, $true)
$refreshButton = $fileManager.Find({ param($node)
    $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'Add_Click' -and
    $node.Expression.VariablePath.UserPath -eq 'btnRefresh'
}, $true).Arguments[0].ScriptBlock.GetScriptBlock()
$refresh = Get-Action $fileManager 'refresh'
$updateButtons = Get-Action $fileManager 'updateButtons'
$renderStatus = Get-Action $ast 'renderStatus'
$renderConnectedStatus = Get-Action $ast 'renderConnectedStatus'
$updateStatus = Get-Action $ast 'updateStatus'
$openDevices = Get-Action $ast 'openDevices'
$deviceManager = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Show-DeviceManager'
}, $true)

$cableBranch = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq '$pick.Tag -eq ''cable'''
}, $true)
$continueByCable = [scriptblock]::Create(($cableBranch.Clauses[0].Item2.Statements.Extent.Text -join "`n"))

$adb = 'fixture-adb'
$form = @{ Visible=$true; IsDisposed=$false }
$dlg = @{ Visible=$true; IsDisposed=$false }
$script:fmFlow = @{ Busy=$false }
$script:mainFlow = @{ Busy=$false; RefreshPending=$false }
$script:closeState = @{ InProgress=$false }
$fixture = @{}
$cRed = [Drawing.Color]::Red; $cMuted = [Drawing.Color]::Gray
$cTagBg = [Drawing.Color]::Beige; $cGreenBg = [Drawing.Color]::Honeydew; $cGreen = [Drawing.Color]::Green
$settings = @{ autoConnect=$false }
$lblStatus = @{ Text='' }; $lblDevInfo = @{ Text='' }
$statusTip = '点击打开「设备管理」。切回窗口时会自动刷新。'
$tt = [pscustomobject]@{ Tip='' }
$tt | Add-Member ScriptMethod SetToolTip { param($Control, $Text) $this.Tip = $Text }
$script:devInfo = @{ 'old-usb'=@{}; 'new-usb'=@{} }
$header = "List of devices attached`r`n"
$results = @(
    @{ Name='cancel'; Command=@{ Cancelled=$true }; Outcome='cancel' }
    @{ Name='timeout'; Command=@{ TimedOut=$true; Stdout="${header}old-usb`tdevice`r`n" }; Outcome='failed'; Detail='等待 ADB 返回设备列表超时。' }
    @{ Name='command failure'; Command=@{ ExitCode=1; Stderr='ADB startup failed'; Stdout=$header }; Outcome='failed'; Detail='ADB startup failed' }
    @{ Name='invalid response'; Command=@{ Stdout="unrelated output`r`nold-usb`tdevice`r`n" }; Outcome='failed'; Detail='ADB 返回的设备列表格式异常。' }
    @{ Name='no attached devices'; Command=@{ Stdout=$header }; Outcome='empty'; Status='○ 未连接'; Tip=$statusTip }
    @{ Name='only offline'; Command=@{ Stdout="${header}old-usb`toffline`r`n" }; Outcome='empty'; Status='○ 手机离线'; Tip='检查 Wi-Fi' }
    @{ Name='authorization takes precedence over offline'; Command=@{ Stdout="${header}old-usb`toffline`r`nunauth`tunauthorized`r`n" }; Outcome='empty'; Status='○ 等待手机授权'; Tip='允许 USB 调试' }
    @{ Name='selected device still online'; Command=@{ Stdout="${header}new-usb`tdevice`r`nold-usb`tdevice`r`nunauth`tunauthorized`r`n" }; Outcome='online'; Serial='old-usb'; Status='● 已连接 USB'; Tip=$statusTip }
    @{ Name='only a new device remains'; Command=@{ Stdout="${header}old-usb`toffline`r`nnew-usb`tdevice`r`n" }; Outcome='online'; Serial='new-usb'; Status='● 已连接 USB'; Tip=$statusTip }
)

function Wait-UiTask {
    param($Owner, [scriptblock]$Work, $Inputs)
    $fixture.Owner = $Owner
    $Control = @{ Cancelled=$false }
    $InfoCache = $script:devInfo
    $value = & $Work
    # The modal task suppresses delivery of a cancelled job.
    if ($Control.Cancelled) { return @{ Success=$false; Cancelled=$true } }
    return $value
}
function Invoke-ShortCommand {
    param($FilePath, [string[]]$ArgumentList, [int]$TimeoutMs, $Control)
    Check ($FilePath -ceq $adb -and ($ArgumentList -join ' ') -ceq 'devices') 'Unexpected ADB command'
    $result = @{ Started=$true; ExitCode=0; TimedOut=$false; Cancelled=$false; Stdout=''; Stderr=''; Error='' }
    $command = if ($fixture.Commands) { $fixture.Commands.Dequeue() } else { $fixture.Command }
    foreach ($key in $command.Keys) { $result[$key] = $command[$key] }
    $Control.Cancelled = $result.Cancelled
    return [pscustomobject]$result
}
function Get-ReachableAddrs {
    param($Candidates, $TimeoutMs)
    Check (-not $Candidates.Count) 'A local refresh tried to reconnect remembered devices'
}
function Invoke-MainFlow { param($Body, $Owner, $Flag) & $Body }
function Show-DeviceQueryFailure { $fixture.QueryErrors++ }
function Show-ResultDialog {
    param($Owner, $Title, $Heading, $Body, $Detail, $Choices)
    if ($Choices -contains 'continue') { return 'continue' }
    if ($Choices -contains 'ip') { $fixture.NoDevicePrompts++; return 'cancel' }
    $fixture.QueryErrors++
    $fixture.Detail = $Detail
    return 'ok'
}
function Select-Device { param($Owner, $Devices, $Title) return $Devices[-1] }
function Start-WirelessMirror { param($Owner, $Serial) $fixture.WirelessTarget = $Serial }
function Get-FriendlyName { param($Serial, [switch]$CachedOnly) return $Serial }
function Get-DevInfo { param($Serial, [switch]$CachedOnly) return $script:devInfo[$Serial] }
function Fm-ListDir {
    param($Owner, $Serial, $Path)
    [void]$fixture.Reads.Add($Serial)
    return @{ Ok=$true; Items=@(); Hidden=0 }
}

# Closing the modal window restores the old status before the current device list is requested.
& {
    $lblStatus.Text = '● 已连接 无线'
    $lblDevInfo.Text = 'old wireless phone'
    function Invoke-MainFlow {
        param($Body)
        $previous = $lblStatus.Text
        $script:mainFlow.Busy = $true
        try { & $Body } finally { $lblStatus.Text = $previous; $script:mainFlow.Busy = $false }
    }
    function Show-DeviceManager { param($Owner) $fixture.ManagerOpened = $true }
    function Start-UiTask {
        param($Owner, $Kind, $OnDone, $OnFinally, $Inputs)
        Check (-not $script:mainFlow.Busy) 'Status refresh was requested while the main flow was busy'
        Check ($Kind -ceq 'status') 'Closing device management must use the shared status queue'
        Check ($lblStatus.Text -ceq '◌ 检测中…' -and -not $lblDevInfo.Text) 'Stale connection remained visible while refreshing'
        $fixture.Scan = $OnDone
    }
    & $openDevices
    Check ($fixture.ManagerOpened -and $fixture.Scan) 'Closing device management never requested a new status'
    & $fixture.Scan @{ Success=$true; Devices=@() }
    Check ($lblStatus.Text -ceq '○ 未连接') 'Main window stayed connected after the only device was disconnected'
    & $fixture.Scan @{ Success=$true; Devices=@('new-usb') }
    Check ($lblStatus.Text -ceq '● 已连接 USB' -and $lblDevInfo.Text -ceq 'new-usb') 'Main window did not show the other connected device'
}

& {
    function Start-NextDeviceScan {}
    function Set-BusyLook {}
    $script:restoreHint = {}
    $script:deviceScanState = @{ Active=@{ Kind='camera' }; Pending=[Collections.ArrayList]::new(); Closing=$false }
    $script:mainFlow.Busy = $true
    $flow = @{ Flag=$script:mainFlow; IsMain=$true; Owner=$form }
    & $updateStatus
    & $updateStatus
    Check ($script:mainFlow.RefreshPending -and $script:deviceScanState.Pending.Count -eq 0) 'Refresh requests were lost or queued during a busy main operation'
    Complete-MainFlow $flow
    & $updateStatus
    Check (-not $script:mainFlow.RefreshPending -and $script:deviceScanState.Pending.Count -eq 1) 'Deferred and concurrent refresh requests were not coalesced behind a background job'

    $job = $script:deviceScanState.Pending[0]
    $script:deviceScanState.Pending.Clear()
    $script:mainFlow.Busy = $true
    $lblStatus.Text = '○ 正在处理…'
    & $job.OnDone @{ Success=$true; Devices=@('old-usb') }
    Check ($lblStatus.Text -ceq '○ 正在处理…' -and $script:mainFlow.RefreshPending) 'A result arriving during another operation replaced the busy state or was lost'
    Complete-MainFlow $flow
    Check ($script:deviceScanState.Pending.Count -eq 1) 'Main flow did not retry the refresh whose result became stale'
    & $script:deviceScanState.Pending[0].OnDone @{ Success=$true; Devices=@() }
    Check ($lblStatus.Text -ceq '○ 未连接') 'The retried refresh did not render the latest status'
}

& {
    function Test-AutoConnectExcluded { return $false }
    function Add-KnownDevice {}
    function Start-UiTask {
        param($Owner, $Kind, $OnDone, $OnFinally, $Inputs)
        Check ($Kind -ceq 'reconnect') 'Rendering a reconnect result queued an extra scan'
        $fixture.Reconnect = @{ OnDone=$OnDone; OnFinally=$OnFinally; Inputs=$Inputs }
    }
    $script:reconnectState = @{ InFlight=$false }
    $settings = @{ autoConnect=$true; lastWirelessAddr='192.0.2.20:5555' }
    & $renderStatus @{ Success=$true; Devices=@() }
    Check ($script:reconnectState.InFlight -and $lblStatus.Text -ceq '○ 未连接') 'An empty list did not start a reconnect'
    & $fixture.Reconnect.OnDone @{ Success=$true; Devices=@() }
    Check ($lblStatus.Text -ceq '○ 未连接') 'An unsuccessful reconnect changed the current status'
    & $fixture.Reconnect.OnDone @{ Success=$true; Devices=@($settings.lastWirelessAddr) }
    Check ($lblStatus.Text -ceq '● 已连接 无线' -and $lblDevInfo.Text -ceq $settings.lastWirelessAddr) 'Reconnect did not immediately render the returned device list'
    & $fixture.Reconnect.OnFinally
    Check (-not $script:reconnectState.InFlight) 'The reconnect guard was not released'
}

& {
    $refresh = Get-Action $deviceManager 'refresh'
    $updateButtons = Get-Action $deviceManager 'updateButtons'
    $rowDouble = Get-Action $deviceManager 'rowDouble'
    function Get-ActiveSerials { $fixture.LocalProcesses }
    function Test-AutoConnectExcluded { return $false }
    $castSelected = { $fixture.Casts++ }
    $connectSelected = { $fixture.Connects++ }
    $fixture = @{ Command=@{ TimedOut=$true }; QueryErrors=0; Casts=0; Connects=0 }
    $serial = '192.0.2.20:5555'
    $script:devInfo[$serial] = @{}
    $script:knownDevices = @{}
    $state = @{ Active=@(); Connected=@($serial); SnapshotReady=$true }
    $row = [System.Windows.Forms.ListViewItem]::new('old device')
    $row.Tag = @{ Serial=$serial; Connected=$true; Wireless=$true }
    $row.ForeColor = $cGreen
    $lv = [pscustomobject]@{ Items=[Collections.ArrayList]::new(); SelectedItems=@($row) }
    $lv | Add-Member ScriptMethod BeginUpdate {}
    $lv | Add-Member ScriptMethod EndUpdate {}
    [void]$lv.Items.Add($row)
    $noDeviceHint = 'empty device list'
    $capNoDev = @{ Visible=$false; Text=$noDeviceHint }
    foreach ($name in @('btnConnect','btnCast','btnStop','btnAll','btnDefault','btnDisc','btnRename','btnForget','btnAuto')) {
        Set-Variable -Name $name -Value @{ Enabled=$false; Text='' }
    }
    & $updateButtons
    Check ($btnCast.Enabled -and $btnAll.Enabled -and $btnDisc.Enabled -and $btnDefault.Enabled) 'Online row did not enable its actions before failure'
    & $refresh
    Check ($fixture.QueryErrors -eq 1 -and $capNoDev.Visible -and $capNoDev.Text.Contains('连接状态待确认')) 'Failed manager refresh did not leave a persistent status hint'
    Check (-not $state.SnapshotReady -and [object]::ReferenceEquals($lv.Items[0],$row) -and $row.ForeColor -eq $cMuted) 'The cached device list was not retained and dimmed'
    Check (-not ($btnCast.Enabled -or $btnAll.Enabled -or $btnDisc.Enabled -or $btnDefault.Enabled)) 'Online actions stayed enabled on a stale list'
    & $rowDouble
    $fixture.LocalProcesses = @($serial)
    & $updateButtons
    Check ($btnStop.Enabled -and $btnRename.Enabled -and $btnAuto.Enabled) 'Actions independent of ADB status were disabled'

    $row.Tag.Connected = $false
    & $updateButtons
    & $rowDouble
    Check (-not ($btnConnect.Enabled -or $btnForget.Enabled -or $fixture.Casts -or $fixture.Connects)) 'A stale cached row could still trigger a connection-dependent action'
    $fixture.Command = @{ Stdout="${header}$serial`tdevice`r`n" }
    $fixture.LocalProcesses = @()
    & $refresh
    $lv.SelectedItems = @($lv.Items[0])
    & $updateButtons
    Check ($state.SnapshotReady -and -not $capNoDev.Visible -and $capNoDev.Text -ceq $noDeviceHint) 'A successful refresh did not clear the pending-status hint'
    Check ($btnCast.Enabled -and $btnAll.Enabled -and $btnDisc.Enabled -and $btnDefault.Enabled) 'Actions stayed disabled after a successful refresh'
}

& {
    function Start-UiTask {
        param($Owner, $Kind, $OnDone, $OnFinally, $Inputs)
        $fixture.ScanInputs = $Inputs
    }
    Start-DeviceScan -Owner $form -Kind 'status'
    foreach ($second in @(@{ Stdout=$header }, @{ ExitCode=1; Stderr='still unavailable' })) {
        $fixture.Commands = [Collections.Queue]::new()
        $fixture.Commands.Enqueue(@{ TimedOut=$true })
        $fixture.Commands.Enqueue($second)
        $scanInputs = $fixture.ScanInputs
        $result = Invoke-DeviceScan @scanInputs -InfoCache $script:devInfo -Control @{ Cancelled=$false }
        Check ($fixture.Commands.Count -eq 0) 'Status query did not retry once'
        Check ($result.Success -eq [bool]$second.Stdout) 'Status query did not use the retry result'
    }
    $fixture.Commands.Enqueue(@{ Cancelled=$true })
    $fixture.Commands.Enqueue(@{ Stdout=$header })
    $result = Invoke-DeviceScan @scanInputs -InfoCache $script:devInfo -Control @{ Cancelled=$false }
    Check ($result.Cancelled -and $fixture.Commands.Count -eq 1) 'Status query retried after cancellation'
}

foreach ($case in $results) {
    $fixture = @{ Command=$case.Command; QueryErrors=0; NoDevicePrompts=0 }
    & $continueByCable
    $label = $case.Name
    Check ($fixture.QueryErrors -eq [int]($case.Outcome -eq 'failed')) "Cable wizard query feedback was wrong for $label"
    Check ($fixture.NoDevicePrompts -eq [int]($case.Outcome -eq 'empty')) "Cable wizard showed the wrong no-device prompt for $label"
    Check ($fixture.WirelessTarget -ceq $case.Serial) "Cable wizard chose an unexpected target for $label"
    Check ([object]::ReferenceEquals($fixture.Owner,$form)) "Cable wizard ran under the wrong owner for $label"

    if ($case.Outcome -ne 'cancel') {
        $snapshot = Wait-DeviceScan $form
        & $renderStatus $snapshot
        $expectedStatus = if ($case.Outcome -eq 'failed') { '○ 状态待确认' } else { $case.Status }
        $expectedTip = if ($case.Outcome -eq 'failed') { '暂时无法确认手机连接状态' } else { $case.Tip }
        Check ($lblStatus.Text -ceq $expectedStatus -and $tt.Tip.Contains($expectedTip)) "Main window device status was wrong for $label"
    }

    $fixture = @{ Command=$case.Command; QueryErrors=0; Reads=[Collections.ArrayList]::new() }
    $state = @{ Serial='old-usb'; Serials=@('old-usb'); Path='/sdcard'; Rebuilding=$false }
    $oldRow = [pscustomobject]@{ Tag=@{ Name='cached file' } }
    $lv = [pscustomobject]@{ Items=[Collections.ArrayList]::new(); SelectedItems=@(); IsDisposed=$false; AllowDrop=$true }
    $lv | Add-Member ScriptMethod BeginUpdate {}
    $lv | Add-Member ScriptMethod EndUpdate {}
    [void]$lv.Items.Add($oldRow)
    $cmbDev = @{ Items=[Collections.ArrayList]::new(); SelectedIndex=0 }
    [void]$cmbDev.Items.Add('old device')
    $lblInfo = @{ Text='previous list' }; $txtPath = @{}
    $btnUpload = @{ Enabled=$true }; $btnNew = @{ Enabled=$true }
    $btnDownload = @{}; $btnDel = @{}; $btnRename = @{}; $btnUp = @{}; $btnGo = @{}
    $lnkHome = @{}; $lnkDl = @{}; $lnkDcim = @{}; $lnkPic = @{}; $lnkRoot = @{}
    $script:fmShellMode = 'cached'
    & $refreshButton
    Check ($fixture.QueryErrors -eq [int]($case.Outcome -eq 'failed')) "File manager query feedback was wrong for $label"
    Check ([object]::ReferenceEquals($fixture.Owner,$dlg)) "File manager scan ran under the wrong owner for $label"
    if ($case.Outcome -eq 'online') {
        Check ($fixture.Reads.Count -eq 1 -and $fixture.Reads[0] -ceq $case.Serial) "File manager chose an unexpected target for $label"
        Check ($state.Serial -ceq $case.Serial -and $state.Serials[$cmbDev.SelectedIndex] -ceq $case.Serial -and $btnUpload.Enabled) "File manager did not select the online device for $label"
        Check ($null -eq $script:fmShellMode) 'File manager did not invalidate the shell cache after a successful scan'
    } elseif ($case.Outcome -eq 'empty') {
        Check ($fixture.Reads.Count -eq 0 -and -not $state.Serial -and $state.Serials.Count -eq 0) 'File manager kept the stale target after a successful empty scan'
        Check ($cmbDev.SelectedIndex -eq -1 -and $lv.Items.Count -eq 0 -and -not $btnUpload.Enabled -and -not $btnNew.Enabled -and -not $lv.AllowDrop) 'File manager did not clear and disable the empty view'
        $fixture.Command = $results[-1].Command
        & $refreshButton
        Check ($fixture.Reads.Count -eq 1 -and $fixture.Reads[0] -ceq 'new-usb' -and $btnUpload.Enabled -and $lv.AllowDrop) 'File manager did not recover after a device reconnected'
    } else {
        Check ($fixture.Reads.Count -eq 0 -and $state.Serial -ceq 'old-usb' -and $cmbDev.Items[0] -ceq 'old device') "File manager refreshed the stale device after $label"
        Check ([object]::ReferenceEquals($lv.Items[0],$oldRow) -and $script:fmShellMode -ceq 'cached') "File manager mutated a previous snapshot after $label"
    }
    if ($case.Outcome -ceq 'failed') {
        Check ($fixture.Detail -ceq $case.Detail) "File manager lost the ADB failure diagnostic for $label"
    }
}

'PASS device query status regression on PowerShell ' + $PSVersionTable.PSVersion
