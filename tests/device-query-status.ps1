$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path (Split-Path $PSScriptRoot) 'scrcpy-helper.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join "`n") }
foreach ($name in @('Wait-DeviceScan','Invoke-DeviceScan','Test-Wireless','Test-TcpAddress','Test-MdnsSerial')) {
    $definition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

function Check($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Get-FileManagerAction([string]$Name) {
    $assignment = $fileManager.Find({ param($node)
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
$refresh = Get-FileManagerAction 'refresh'
$updateButtons = Get-FileManagerAction 'updateButtons'

$cableBranch = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq '$pick.Tag -eq ''cable'''
}, $true)
$continueByCable = [scriptblock]::Create(($cableBranch.Clauses[0].Item2.Statements.Extent.Text -join "`n"))

$adb = 'fixture-adb'
$form = @{ Visible=$true; IsDisposed=$false }
$dlg = @{ Visible=$true; IsDisposed=$false }
$script:fmFlow = @{ Busy=$false }
$fixture = @{}
$cRed = [Drawing.Color]::Red; $cMuted = [Drawing.Color]::Gray
$script:devInfo = @{ 'old-usb'=@{}; 'new-usb'=@{} }
$header = "List of devices attached`r`n"
$results = @(
    @{ Name='cancel'; Command=@{ Cancelled=$true }; Outcome='cancel' }
    @{ Name='timeout'; Command=@{ TimedOut=$true; Stdout="${header}old-usb`tdevice`r`n" }; Outcome='failed' }
    @{ Name='command failure'; Command=@{ ExitCode=1; Stderr='ADB startup failed'; Stdout=$header }; Outcome='failed' }
    @{ Name='invalid response'; Command=@{ Stdout="unrelated output`r`nold-usb`tdevice`r`n" }; Outcome='failed' }
    @{ Name='no online devices'; Command=@{ Stdout="${header}old-usb`toffline`r`nunauth`tunauthorized`r`n" }; Outcome='empty' }
    @{ Name='selected device still online'; Command=@{ Stdout="${header}new-usb`tdevice`r`nold-usb`tdevice`r`n" }; Outcome='online'; Serial='old-usb' }
    @{ Name='only a new device remains'; Command=@{ Stdout="${header}old-usb`toffline`r`nnew-usb`tdevice`r`n" }; Outcome='online'; Serial='new-usb' }
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
    foreach ($key in $fixture.Command.Keys) { $result[$key] = $fixture.Command[$key] }
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
function Fm-ListDir {
    param($Owner, $Serial, $Path)
    [void]$fixture.Reads.Add($Serial)
    return @{ Ok=$true; Items=@(); Hidden=0 }
}

foreach ($case in $results) {
    $fixture = @{ Command=$case.Command; QueryErrors=0; NoDevicePrompts=0 }
    & $continueByCable
    $label = $case.Name
    Check ($fixture.QueryErrors -eq [int]($case.Outcome -eq 'failed')) "Cable wizard query feedback was wrong for $label"
    Check ($fixture.NoDevicePrompts -eq [int]($case.Outcome -eq 'empty')) "Cable wizard showed the wrong no-device prompt for $label"
    Check ($fixture.WirelessTarget -ceq $case.Serial) "Cable wizard chose an unexpected target for $label"
    Check ([object]::ReferenceEquals($fixture.Owner,$form)) "Cable wizard ran under the wrong owner for $label"

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
    if ($case.Name -ceq 'command failure') {
        Check ($fixture.Detail -ceq 'ADB startup failed') 'File manager lost the ADB failure diagnostic'
    }
}

'PASS device query status regression on PowerShell ' + $PSVersionTable.PSVersion
