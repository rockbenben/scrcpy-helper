$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path (Split-Path $PSScriptRoot) 'scrcpy-helper.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join "`n") }
foreach ($name in @('Request-AppClose','Invoke-ExitDisconnect','Test-CommandSuccess','Get-CommandDetail',
    'Test-TcpAddress','Test-MdnsSerial','Test-Wireless')) {
    $definition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Check($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$adb = 'fixture-adb'
$first = '192.0.2.10:5555'
$second = 'adb-example._adb-tls-connect._tcp'
$processOnly = '192.0.2.11:37123'
$owner = @{
    WindowState=[Windows.Forms.FormWindowState]::Normal; Location=@{ X=20; Y=40 }
    IsDisposed=$false; Cursor=$null
}
$onResume = { $fixture.Resumes++ }
function Reset-Fixture {
    $script:fixture = @{
        Calls=[Collections.ArrayList]::new(); Outcomes=@{}; Resumes=0; Saves=0
        Dialogs=0; Choice='cancel'; Stopped=$false; StopsSuccessfully=$true
    }
    $script:closeState = @{ InProgress=$false; DisconnectAddresses=@() }
    $script:deviceScanState = @{ Paused=$false; Closing=$false }
    $script:knownDevices = [ordered]@{ $first='First'; $second='Second'; usb='Wired' }
    $script:scrcpyProcs = [Collections.ArrayList]::new()
    foreach ($serial in @($first,$processOnly,'usb')) { [void]$script:scrcpyProcs.Add(@{ Serial=$serial }) }
    $script:settings = @{ disconnectOnClose=$true; winX=0; winY=0 }
    $script:eventArgs = @{ Cancel=$false }
}
function Update-ProcessLifecycle {}
function Test-Recording { return $false }
function Stop-DeviceScans { $script:deviceScanState.Closing=$true }
function Stop-AllScrcpy {
    Check (-not $script:deviceScanState.Closing) 'Shutdown tasks were kept disabled'
    $fixture.Stopped = $true
    $scrcpyProcs.Clear()
    return @{ Success=$fixture.StopsSuccessfully }
}
function Save-Settings { $fixture.Saves++ }
function Set-BusyLook { param([bool]$On) }
function Wait-UiTask {
    param($Owner, [scriptblock]$Work, [hashtable]$Inputs, [string[]]$Functions, [string]$Kind)
    Check ($fixture.Stopped -and $Kind -eq 'shutdown') 'Disconnect ran before stopping mirroring'
    Check ($Functions -contains 'Invoke-ExitDisconnect') 'Shutdown worker did not receive its disconnect function'
    if ($fixture.ContainsKey('Report')) { return $fixture.Report }
    $Control = @{ Cancelled=$false }
    return (& $Work)
}
function Show-ResultDialog {
    param($Owner, $Title, $Heading, $Body, $Detail, $Buttons, [switch]$ExpandDetail, [switch]$CancelByDefault)
    Check ($eventArgs.Cancel -and $fixture.Saves -eq 0) 'Shutdown continued before asking for a decision'
    Check ($Heading -eq '无线连接未全部断开' -and ($Buttons -join '|') -eq 'exit|cancel') 'Missing explicit exit decision'
    Check ($ExpandDetail -and $CancelByDefault) 'Device details or safe default are missing'
    $fixture.Dialogs++
    $fixture.Body = $Body
    $fixture.Detail = $Detail
    return $fixture.Choice
}
function Invoke-ShortCommand {
    param($FilePath, [string[]]$ArgumentList, [int]$TimeoutMs, $Control)
    Check ($FilePath -eq $adb -and $ArgumentList.Count -eq 2 -and $ArgumentList[0] -eq 'disconnect') 'Expected a directed ADB disconnect'
    Check ($TimeoutMs -ge 1 -and $TimeoutMs -le 3000) 'Disconnect exceeded its command deadline'
    $address = $ArgumentList[1]
    [void]$fixture.Calls.Add($address)
    $command = [pscustomobject]@{ Started=$true; ExitCode=0; TimedOut=$false; Cancelled=$false; Error=''; Stdout="disconnected $address"; Stderr='' }
    switch ($fixture.Outcomes[$address]) {
        'fail' { $command.ExitCode=1; $command.Stdout=''; $command.Stderr='error: server communication failed' }
        'timeout' { $command.TimedOut=$true; $command.Stdout='' }
        'budget' { Start-Sleep -Milliseconds ($TimeoutMs + 30); $command.TimedOut=$true; $command.Stdout='' }
        'absent' { $command.ExitCode=1; $command.Stdout=''; $command.Stderr="error: no such device '${address}:5555'" }
        'cancel' { $Control.Cancelled=$true; $command.Cancelled=$true; $command.Stdout='' }
    }
    return $command
}

Reset-Fixture
$fixture.Outcomes[$second] = 'absent'
Request-AppClose $owner $eventArgs $onResume
Check (-not $eventArgs.Cancel -and $fixture.Dialogs -eq 0 -and $fixture.Saves -eq 1) 'Successful or already absent devices blocked exit'
Check (($fixture.Calls -join '|') -ceq "$first|$second|$processOnly") 'Shutdown missed a target, duplicated it, or included USB'

Reset-Fixture
$fixture.Outcomes[$first] = 'fail'
$fixture.Outcomes[$processOnly] = 'timeout'
Request-AppClose $owner $eventArgs $onResume
Check ($eventArgs.Cancel -and $fixture.Dialogs -eq 1 -and $fixture.Resumes -eq 1) 'Declining an incomplete disconnect did not keep the app open'
Check (-not $script:closeState.InProgress -and -not $script:deviceScanState.Paused) 'Cancelling exit did not restore the app state'
Check ($fixture.Body -like '*断开失败 2 台，尚未处理 0 台。*') 'The failure count did not match the attempted devices'
Check ($fixture.Detail.Contains("$first · error: server communication failed") -and
    $fixture.Detail.Contains("$processOnly · 操作超时") -and -not $fixture.Detail.Contains($second)) 'Failure report hid a device or included a success'
Check ($script:closeState.DisconnectAddresses -contains $processOnly) 'Retry lost a device from the stopped process list'

$eventArgs.Cancel = $false
$fixture.Calls.Clear()
$fixture.Outcomes.Clear()
Request-AppClose $owner $eventArgs $onResume
Check (-not $eventArgs.Cancel -and $fixture.Calls -contains $processOnly -and $fixture.Dialogs -eq 1) 'Retry did not disconnect the retained target'

Reset-Fixture
$fixture.Outcomes[$first] = 'budget'
$fixture.Report = Invoke-ExitDisconnect $adb @($first,$second,$processOnly) @{ Cancelled=$false } -BudgetMs 1000
Check (($fixture.Calls -join '|') -ceq $first -and $fixture.Report.Failed[0].Address -eq $first -and
    ($fixture.Report.Unprocessed -join '|') -ceq "$second|$processOnly") 'Budget exhaustion did not preserve the exact unprocessed tail'
$fixture.Choice = 'exit'
Request-AppClose $owner $eventArgs $onResume
Check (-not $eventArgs.Cancel -and $fixture.Dialogs -eq 1 -and $fixture.Saves -eq 1) 'Explicitly accepting an incomplete disconnect did not allow exit'
Check ($fixture.Body -like '*断开失败 1 台，尚未处理 2 台。*' -and
    $fixture.Detail -match ("尚未处理\r?\n" + [regex]::Escape($second) + "\r?\n" + [regex]::Escape($processOnly))) 'Unprocessed addresses were missing from the dialog'

Reset-Fixture
$fixture.Outcomes[$first] = 'cancel'
Request-AppClose $owner $eventArgs $onResume
Check ($eventArgs.Cancel -and $fixture.Calls.Count -eq 1 -and $fixture.Dialogs -eq 0 -and $fixture.Resumes -eq 1) 'Cancelling the background wait did not leave the app open'

Reset-Fixture
$fixture.Report = [pscustomobject]@{ Success=$false; Error='worker failed' }
Request-AppClose $owner $eventArgs $onResume
Check ($eventArgs.Cancel -and $fixture.Dialogs -eq 1 -and $fixture.Detail -like '*未确认结果*worker failed*') 'Missing worker output was accepted or misreported'

Reset-Fixture
$settings.disconnectOnClose = $false
Request-AppClose $owner $eventArgs $onResume
Check (-not $eventArgs.Cancel -and $fixture.Calls.Count -eq 0 -and $fixture.Dialogs -eq 0) 'Disabled auto-disconnect still ran'

Reset-Fixture
$fixture.StopsSuccessfully = $false
Request-AppClose $owner $eventArgs $onResume
Check ($eventArgs.Cancel -and $fixture.Calls.Count -eq 0) 'Disconnected devices before mirroring stopped successfully'

'PASS exit disconnect regression on PowerShell ' + $PSVersionTable.PSVersion
