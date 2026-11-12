. (Join-Path $PSScriptRoot 'file-manager-test-support.ps1')
# Use the actual task queue and a harmless local child process to exercise cancellation.
foreach ($name in @('Start-UiTask', 'Start-NextDeviceScan', 'Receive-DeviceScan', 'Stop-DeviceScans', 'Cancel-OwnerTasks',
                    'Invoke-ShortCommand', 'Test-TcpAddress', 'Test-MdnsSerial', 'Test-Wireless', 'Get-ReachableAddrs', 'Invoke-DeviceScan')) {
    $definition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    Invoke-Expression $definition.Extent.Text
}
$script:deviceScanState = @{ Active=$null; Pending=(New-Object Collections.ArrayList); Closing=$false; Paused=$false }
$script:closeState = @{ InProgress=$false }
$script:devInfo = @{}
$owner = New-Object Windows.Forms.Form
$timer = New-Object Windows.Forms.Timer
$childIdFile = Join-Path $root 'child.pid'
$escapedPath = $childIdFile.Replace("'", "''")
$command = "[IO.File]::WriteAllText('$escapedPath',[string]`$PID); Start-Sleep -Seconds 30"
$watch = [Diagnostics.Stopwatch]::StartNew()
$timer.Interval = 50
$timer.Add_Tick({
    if ((Test-Path -LiteralPath $childIdFile) -or $watch.ElapsedMilliseconds -gt 12000) {
        $timer.Stop()
        $owner.Dispose()
    }
})
try {
    $timer.Start()
    $result = Invoke-FmTask $owner -Inputs @{ File=(Get-Command powershell.exe).Source; Args=@('-NoProfile', '-Command', $command) } -Work {
        $commandResult = Invoke-ShortCommand -FilePath $Inputs.File -ArgumentList $Inputs.Args -TimeoutMs 15000 -Control $Control
        [pscustomobject]@{ Info=@{}; Connected=@(); Ok=($commandResult.ExitCode -eq 0); Cancelled=$commandResult.Cancelled }
    }
    Check (Test-Path -LiteralPath $childIdFile) 'Child process did not reach the cancellation fixture'
    Check ($result.Cancelled -and -not $result.Ok) 'Closing the owner did not cancel the task'
    Check (-not $script:deviceScanState.Active -and $script:deviceScanState.Pending.Count -eq 0) 'Cancelled task leaked in queue'
    $childId = [int][IO.File]::ReadAllText($childIdFile)
    Check (-not (Get-Process -Id $childId -ErrorAction SilentlyContinue)) 'Cancelled child process is still running'
} finally {
    $timer.Stop(); $timer.Dispose(); $owner.Dispose()
    Stop-DeviceScans
}
# Deterministic cancellation between copy chunks verifies preservation of the original file.
$from = Join-Path $root 'large.bin'
$to = Join-Path $root 'original.bin'
$stream = [IO.File]::Create($from)
try { $stream.SetLength(8MB) } finally { $stream.Dispose() }
[IO.File]::WriteAllText($to, 'original')
$cancelState = @{ Reads=0 }
$control = New-Object psobject
$control | Add-Member ScriptProperty Cancelled { $cancelState.Reads++; return $cancelState.Reads -gt 3 }
$cancelled = $false
try { Copy-FmFile $from $to $true $control } catch { $cancelled=$true }
Check ($cancelled -and $cancelState.Reads -gt 3) 'Copy did not observe cancellation between chunks'
Check ([IO.File]::ReadAllText($to) -eq 'original') 'Cancelled copy damaged the original file'
Check (@(Get-ChildItem -LiteralPath $root -Force -Filter '.scrcpy-*').Count -eq 0) 'Cancelled copy left an intermediate file'
# Verify that scoped grants survive a real runspace boundary as well as the synchronous doubles.
$script:deviceScanState = @{ Active=$null; Pending=(New-Object Collections.ArrayList); Closing=$false; Paused=$false }
$owner = New-Object Windows.Forms.Form
try {
    $snapshot = Get-FmTargetPaths $owner $to
    Check ($snapshot.Ok -and $snapshot.Paths.Count -eq 1) 'Background snapshot did not return the target'
    $grants = @{}; foreach ($path in $snapshot.Paths) { $grants[$path]=$true }
    $result = Invoke-FmTask $owner -Functions @('Fm-ValidName', 'Assert-FmNames', 'Assert-FmLocalPath', 'Assert-FmTree',
        'Test-FmOverwrite', 'Copy-FmFile', 'Merge-FmDirectory', 'Move-FmPulledItem') -Inputs @{ From=$from; To=$to; Approved=$grants } -Work {
        $ok = Move-FmPulledItem $Inputs.From $Inputs.To $Inputs.Approved $Control
        [pscustomobject]@{ Info=@{}; Connected=@(); Ok=$ok }
    }
    Check ($result.Ok -and (Get-Item -LiteralPath $to).Length -eq 8MB) 'Background writer lost the specific target grant'
} finally {
    $owner.Dispose()
    Stop-DeviceScans
}
'PASS file manager background cancellation regressions on PowerShell ' + $PSVersionTable.PSVersion
