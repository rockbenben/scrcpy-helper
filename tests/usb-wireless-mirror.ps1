$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path (Split-Path $PSScriptRoot) 'scrcpy-helper.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join "`n") }

$definitions = @(
    'Invoke-UsbWirelessConnection','Invoke-ConnectDevices','Invoke-DeviceScan','Wait-DeviceScan','Get-AdbDeviceState',
    'Test-CommandSuccess','Get-CommandDetail','Test-TcpAddress','Test-MdnsSerial','Test-Wireless',
    'Start-WirelessMirror','Start-Scrcpy','Split-WindowsArguments','Fm-WinArg','Get-MirrorArgs','Get-VideoArgs',
    'Get-DisplayCompatibilityArgs','Get-HwDecArgs','Get-AudioArgs',
    'Get-ControlArgs','Get-WindowArgs','Get-FriendlyName','Touch-KnownDevice','Test-AutoConnectExcluded',
    'Get-ActiveSerials','Stop-DevicesUi','Invoke-StopItems','Test-ProcessExited','Wait-ScrcpyExit',
    'Update-ProcessLifecycle','Release-ExitedProcess'
)
foreach ($definition in $definitions) {
    $node = $ast.Find({ param($n)
        $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $definition
    }, $true)
    . ([scriptblock]::Create($node.Extent.Text))
}
function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message (expected [$Expected], received [$Actual])" }
}
function Get-ManagerAction([string]$Name) {
    $manager = $ast.Find({ param($n)
        $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-DeviceManager'
    }, $true)
    $assignment = $manager.Find({ param($n)
        $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq ('$' + $Name)
    }, $true)
    return $assignment.Right.Expression.ScriptBlock.GetScriptBlock()
}

$adb = 'fixture-adb'
$exe = 'fixture-scrcpy'
$usbSerial = 'selected-usb'
$otherAddress = '192.0.2.23:5555'
$fixture = @{}
$script:autoConnectExclude = @()
$script:deviceNames = [ordered]@{ 'selected-usb' = 'Selected phone' }
$script:devInfo = @{}
$dlg = @{}
$cGreen = [Drawing.Color]::Green
$cMuted = [Drawing.Color]::Gray
$grpConn = New-Object System.Windows.Forms.ListViewGroup
$grpKnown = New-Object System.Windows.Forms.ListViewGroup
$capNoDev = @{}
$lv = [pscustomobject]@{ Items = [Collections.ArrayList]::new(); SelectedItems = @() }
$lv | Add-Member ScriptMethod BeginUpdate {}
$lv | Add-Member ScriptMethod EndUpdate {}
$updateButtons = Get-ManagerAction 'updateButtons'
$refresh = Get-ManagerAction 'refresh'
$stopSelected = Get-ManagerAction 'stopSelected'
$btnConnect = @{}; $btnCast = @{}; $btnStop = @{}; $btnAll = @{}
$btnDefault = @{}; $btnDisc = @{}; $btnRename = @{}; $btnForget = @{}; $btnAuto = @{}
$state = @{}

function Save-Settings {}
function Get-DevInfo { param($Serial, [switch]$CachedOnly) return $script:devInfo[$Serial] }
function Show-ResultDialog { param($Owner, $Title, $Heading) $fixture.Dialog = $Heading; return 'ok' }
function Wait-UiTask {
    param($Owner, [scriptblock]$Work, [hashtable]$Inputs, [string[]]$Functions, [string]$Kind)
    $Control = @{ Cancelled = $false }
    $InfoCache = $script:devInfo
    $value = & $Work
    if ($Control.Cancelled) { return [pscustomobject]@{ Cancelled = $true } }
    return $value
}
function Invoke-ShortCommand {
    param($FilePath, [string[]]$ArgumentList, [int]$TimeoutMs, $Control)
    Assert-Equal $FilePath $adb 'Wrong ADB executable'
    $command = $ArgumentList -join ' '
    [void]$fixture.Commands.Add($command)
    $result = [pscustomobject]@{ Started=$true; ExitCode=0; TimedOut=$false; Cancelled=$false; Error=''; Stdout=''; Stderr='' }
    switch ($command) {
        "-s $usbSerial shell ip route" {
            $result.Stdout = '198.51.100.0/24 dev rmnet0 proto kernel scope link src 198.51.100.5'
            if ($fixture.Case -ne 'no-wifi') { $result.Stdout += "`r`n192.0.2.0/24 dev wlan0 proto kernel scope link src 192.0.2.10" }
        }
        "-s $usbSerial shell getprop service.adb.tcp.port" {
            if ($fixture.Case -eq 'cancel' -and $fixture.Restarted) {
                $Control.Cancelled = $true
                $result.Cancelled = $true
            }
            if ($fixture.Restarted) {
                $fixture.PortChecks++
                if ($fixture.PortChecks -eq 2) { $fixture.Port = 5555 }
            }
            $result.Stdout = "$($fixture.Port)"
        }
        "-s $usbSerial tcpip 5555" {
            $fixture.Restarted = $true
        }
        "connect $($fixture.Address)" {
            Assert-Equal $fixture.Port $fixture.ExpectedPort 'Connected before adbd enabled the requested port'
            $fixture.Connected = $true
            $result.Stdout = "connected to $($fixture.Address)"
        }
        'devices' {
            $result.Stdout = "List of devices attached`r`n$otherAddress`tdevice`r`n"
            if (-not $fixture.Unplugged) { $result.Stdout += "$usbSerial`tdevice`r`n" }
            if ($fixture.Connected) {
                $deviceState = if ($fixture.Case -eq 'unauthorized') { 'unauthorized' } else { 'device' }
                $result.Stdout += "$($fixture.Address)`t$deviceState`r`n"
            }
        }
        "disconnect $($fixture.Address)" { $fixture.Connected = $false }
        default { throw "Unexpected ADB command: $command" }
    }
    return $result
}
function Start-Process {
    param($FilePath, $ArgumentList, $WorkingDirectory, [switch]$PassThru, $WindowStyle)
    Assert-Equal $FilePath $exe 'Wrong scrcpy executable'
    Assert-Equal $fixture.Connected $true 'scrcpy started before ADB confirmed the connection'
    [void]$fixture.Launches.Add($ArgumentList)
    $process = [pscustomobject]@{ HasExited=$false; ExitCode=0; Closed=0; Disposed=$false }
    $process | Add-Member ScriptMethod CloseMainWindow { $this.Closed++; $this.HasExited=$true; return $true }
    $process | Add-Member ScriptMethod Dispose { $this.Disposed=$true }
    return $process
}

foreach ($case in @('enable-tcpip', 'existing-port', 'no-wifi', 'cancel', 'unauthorized')) {
    $fixture.Clear()
    $fixture.Case = $case
    $fixture.Port = if ($case -eq 'existing-port') { 37123 } else { -1 }
    $fixture.ExpectedPort = if ($case -eq 'existing-port') { 37123 } else { 5555 }
    $fixture.Address = "192.0.2.10:$($fixture.ExpectedPort)"
    $fixture.Connected = $false
    $fixture.Commands = [Collections.ArrayList]::new()
    $fixture.Launches = [Collections.ArrayList]::new()
    $settings = @{ showConsole=$true; stayAwake=$true; lastWirelessAddr='' }
    $script:knownDevices = [ordered]@{}
    $script:camSessions = @()
    $scrcpyProcs = [Collections.ArrayList]::new()
    $script:devInfo = @{
        $otherAddress = @{ Ver=13; Text='Android 13 · Other phone' }
        $fixture.Address = @{ Ver=13; Text='Android 13 · Selected phone' }
    }

    Start-WirelessMirror $dlg $usbSerial
    if ($case -in @('no-wifi','cancel','unauthorized')) {
        Assert-Equal $fixture.Launches.Count 0 'Started scrcpy without a usable wireless connection'
        Assert-Equal $script:knownDevices.Count 0 'Remembered an unverified wireless address'
        $expectedDialog = if ($case -eq 'cancel') { $null } else { '无线连接失败' }
        Assert-Equal $fixture.Dialog $expectedDialog 'Unexpected feedback on an unsuccessful switch'
        if ($case -in @('no-wifi','cancel')) {
            Assert-Equal ($fixture.Commands -contains "connect $($fixture.Address)") $false 'Connected without a resolved and ready endpoint'
        }
        continue
    }

    Assert-Equal ([bool]$fixture.Restarted) ($case -eq 'enable-tcpip') 'Restarted adbd on the wrong branch'
    Assert-Equal $scrcpyProcs.Count 1 'Expected a single mirroring process'
    Assert-Equal $scrcpyProcs[0].Serial $fixture.Address 'Process was not registered under its wireless address'
    Assert-Equal $settings.lastWirelessAddr $fixture.Address 'Wrong address was remembered for reconnection'
    Assert-Equal ((($fixture.Launches[0] -split ' ')[0..1]) -join ' ') "-s $($fixture.Address)" 'scrcpy was not started with the wireless serial'
    Assert-Equal ($fixture.Launches[0] -match '--keep-active' -and $fixture.Launches[0] -notmatch '--tcpip') $true 'Wrong wireless mirroring arguments'
    $targetProcess = $scrcpyProcs[0].Proc
    Start-WirelessMirror $dlg $otherAddress
    $otherProcess = $scrcpyProcs[1].Proc

    $fixture.Unplugged = $true
    $lv.SelectedItems = @()
    & $refresh
    Assert-Equal ($state.Connected -contains $usbSerial) $false 'Fixture still sees the unplugged USB device'
    $row = $lv.Items | Where-Object { $_.Tag.Serial -ceq $fixture.Address }
    Assert-Equal $row.SubItems[2].Text '无线 · Android 13  ▶ 投屏中' 'Wireless row did not show active mirroring after unplug'
    $lv.SelectedItems = @($row)
    & $updateButtons
    Assert-Equal $btnStop.Enabled $true 'Stop was disabled on the wireless row'
    Assert-Equal $btnCast.Enabled $false 'Wireless row permitted duplicate mirroring'

    & $stopSelected
    Assert-Equal $targetProcess.Closed 1 'Stop did not close the migrated mirroring window'
    Assert-Equal $targetProcess.Disposed $true 'Stopped process was not released'
    Assert-Equal $otherProcess.Closed 0 'Stop closed a different wireless session'
    $row = $lv.Items | Where-Object { $_.Tag.Serial -ceq $fixture.Address }
    Assert-Equal $row.SubItems[2].Text '无线 · Android 13' 'Wireless row still showed mirroring after stop'
}

'PASS USB-to-wireless mirroring regression on PowerShell ' + $PSVersionTable.PSVersion
