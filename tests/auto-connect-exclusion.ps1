$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path (Split-Path $PSScriptRoot) 'scrcpy-helper.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join "`n") }
foreach ($name in @('Ensure-Devices','Connect-RememberedAsync','Reconnect-LastAsync','Get-AutoConnectCandidates',
        'Test-AutoConnectExcluded','Set-AutoConnectExcluded','Test-Wireless','Test-TcpAddress','Test-MdnsSerial',
        'Invoke-DeviceScan','Connect-DevicesUi','Invoke-ConnectDevices','Get-AdbDeviceState','Test-CommandSuccess','Get-CommandDetail')) {
    $definition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

function Check($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$manager = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Show-DeviceManager'
}, $true)
$manualConnect = $manager.Find({ param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$connectSelected'
}, $true).Right.Expression.ScriptBlock.GetScriptBlock()

$adb = 'fixture-adb'
$form = @{}; $dlg = @{}
$skipTcp = '192.0.2.20:5555'
$skipMdns = 'adb-excluded._adb-tls-connect._tcp.'
$allowed = '192.0.2.21:5555'
$settings = @{ defaultDevice=$skipTcp; lastWirelessAddr=$skipMdns; autoConnect=$true }
$script:autoConnectExclude = [Collections.Generic.List[string]]::new()
$script:autoConnectExclude.AddRange([string[]]@($skipTcp,$skipMdns))
$script:knownDevices = [ordered]@{}
foreach ($address in @($skipTcp,$skipMdns,$allowed,'old-usb-serial')) { $script:knownDevices[$address] = $address }
$fixture = @{}
$refresh = {}

function Reset-Fixture([string[]]$Reachable) {
    $fixture.Clear()
    $fixture.Reachable = $Reachable
    $fixture.Online = [Collections.Generic.List[string]]::new()
    $fixture.Attempts = [Collections.Generic.List[string]]::new()
    $fixture.Scans = [Collections.ArrayList]::new()
    $script:autoConnectStarted = $false
    $script:reconnectState = @{ InFlight=$false }
}
function Get-ReachableAddrs {
    param($Addrs, $TimeoutMs)
    return @($Addrs | Where-Object { $fixture.Reachable -contains $_ })
}
function Invoke-ShortCommand {
    param($FilePath, [string[]]$ArgumentList, [int]$TimeoutMs, $Control)
    Check ($FilePath -ceq $adb) 'Unexpected executable'
    $stdout = switch ($ArgumentList[0]) {
        'devices' { "List of devices attached`r`n" + (@($fixture.Online | ForEach-Object { "$_`tdevice`r`n" }) -join '') }
        'connect' {
            $address = $ArgumentList[1]
            $fixture.Attempts.Add($address)
            if (-not $fixture.Online.Contains($address)) { $fixture.Online.Add($address) }
            "connected to $address"
        }
        default { throw "Unexpected ADB arguments: $ArgumentList" }
    }
    return @{ Started=$true; ExitCode=0; TimedOut=$false; Cancelled=$false; Error=''; Stdout=$stdout; Stderr='' }
}
function Start-DeviceScan {
    param($Owner, [string[]]$Candidates=@(), [bool]$ConnectAlways, $Kind, $OnDone, $OnFinally)
    [void]$fixture.Scans.Add(@{ Kind=$Kind; Candidates=$Candidates; Owner=$Owner })
    $infoCache = @{}
    foreach ($address in @($Candidates) + @($fixture.Online.ToArray())) { $infoCache[$address] = @{} }
    try {
        $value = Invoke-DeviceScan -AdbPath $adb -Candidates $Candidates -ConnectAlways $ConnectAlways -InfoCache $infoCache -Control @{ Cancelled=$false }
        if ($OnDone) { & $OnDone $value }
    } finally { if ($OnFinally) { & $OnFinally } }
}
function Wait-UiTask {
    param($Owner, [scriptblock]$Work, $Inputs, $Functions)
    $Control = @{ Cancelled=$false }
    & $Work
}
function Save-Settings {}
function Get-FriendlyName { param($Address, [switch]$CachedOnly) return $Address }
function Touch-KnownDevice { param($Address, $Name) $script:knownDevices[$Address] = $Name }

Reset-Fixture @($skipTcp,$skipMdns,$allowed)
Ensure-Devices $form { param($value) $fixture.Result=$value } { $fixture.Finished=$true }
Check (($fixture.Attempts -join '|') -ceq $allowed) "Main feature connected the wrong addresses: $($fixture.Attempts -join ', ')"
Check (($fixture.Scans[0].Candidates -join '|') -ceq $allowed) 'Main feature submitted excluded or non-wireless addresses'
Check ($fixture.Result.Success -and ($fixture.Result.Devices -join '|') -ceq $allowed -and $fixture.Finished) 'Main feature did not receive the eligible device'

Reset-Fixture @($skipTcp,$skipMdns,$allowed)
Connect-RememberedAsync { param($result) $fixture.Connected=@($result.Connected) }
Check (($fixture.Attempts -join '|') -ceq $allowed -and ($fixture.Connected -join '|') -ceq $allowed) 'Startup connected an excluded address'

Reset-Fixture @($skipTcp,$skipMdns)
Reconnect-LastAsync $skipTcp
Reconnect-LastAsync $skipMdns
Check ($fixture.Scans.Count -eq 0) 'Dropout reconnect queued an excluded address'

$script:knownDevices.Remove($allowed)
Ensure-Devices $form { param($value) $fixture.Result=$value }
Check ($fixture.Attempts.Count -eq 0 -and $fixture.Scans[0].Candidates.Count -eq 0) 'Excluded-only startup candidates reached ADB through a main feature'
Check ($fixture.Result.Success -and $fixture.Result.Devices.Count -eq 0) 'Excluded-only main feature did not return a successful empty list'

$lv = @{ SelectedItems=@(@{ Tag=@{ Serial=$skipMdns; Connected=$false } }) }
& $manualConnect
$ip = Connect-DevicesUi $dlg @($skipTcp) -Probe
Check ($ip.Records[0].Success -and ($fixture.Attempts -join '|') -ceq "$skipMdns|$skipTcp") 'Explicit manual connection was blocked'
Ensure-Devices $form { param($value) $fixture.Result=$value }
Check (($fixture.Result.Devices -join '|') -ceq "$skipMdns|$skipTcp" -and $fixture.Attempts.Count -eq 2) 'Already connected excluded devices were filtered out or reconnected'
Check ((Test-AutoConnectExcluded $skipMdns) -and (Test-AutoConnectExcluded $skipTcp)) 'Manual connection cleared the exclusion'

Set-AutoConnectExcluded $skipMdns $false
Reset-Fixture @($skipMdns)
Reconnect-LastAsync $skipMdns
Check (($fixture.Attempts -join '|') -ceq $skipMdns -and -not $script:reconnectState.InFlight) 'Restoring automatic reconnect did not take effect'

$script:knownDevices.Clear()
foreach ($i in 1..17) { $script:knownDevices["192.0.2.$($i):5555"] = "Phone $i" }
$last = '192.0.2.17:5555'
Reset-Fixture @($last)
Connect-RememberedAsync
Check ($fixture.Scans[0].Candidates.Count -eq 16 -and $fixture.Attempts.Count -eq 0) 'Startup candidate cap changed'
Ensure-Devices $form { param($value) $fixture.Result=$value }
Check ($fixture.Scans[1].Candidates.Count -eq 17 -and ($fixture.Result.Devices -join '|') -ceq $last) 'Main feature lost a candidate beyond the startup limit'

'PASS automatic connection exclusion regression on PowerShell ' + $PSVersionTable.PSVersion
