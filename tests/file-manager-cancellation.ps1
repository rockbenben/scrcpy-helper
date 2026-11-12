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
# The deadline starts at the close event, excluding interpreter startup on busy CI hosts.
function Test-ProcessCancellation([string]$Mode) {
    $owner = if ($Mode -eq 'task') { New-Object Windows.Forms.Form } else { $null }
    $window = @{ Visible=$true; IsDisposed=$false }
    $timer = New-Object Windows.Forms.Timer
    $childIdFile = Join-Path $root ($Mode + '.pid')
    $escapedPath = $childIdFile.Replace("'", "''")
    # Publish readiness atomically so a timer cannot read a newly created, still empty PID file.
    $command = "[IO.File]::WriteAllText('$escapedPath.tmp',[string]`$PID); [IO.File]::Move('$escapedPath.tmp','$escapedPath'); Start-Sleep -Seconds 30"
    $startup = [Diagnostics.Stopwatch]::StartNew()
    $cancellation = @{ Child=$null; Closed=$false; CloseWatch=$null }
    $timer.Interval = 50
    $timer.Add_Tick({
        $ready = Test-Path -LiteralPath $childIdFile
        if ($ready -or $startup.ElapsedMilliseconds -gt 12000) {
            $timer.Stop()
            if ($ready) {
                $childId = [int][IO.File]::ReadAllText($childIdFile)
                $cancellation.Child = Get-Process -Id $childId -ErrorAction Stop
                # Retain the process handle so cleanup cannot target a later process reusing its PID.
                $null = $cancellation.Child.Handle
            }
            $cancellation.Closed = $true
            $cancellation.CloseWatch = [Diagnostics.Stopwatch]::StartNew()
            if ($owner) { $owner.Dispose() }
            else { $window.Visible=$false; $window.IsDisposed=$true }
        }
    })
    try {
        $timer.Start()
        if ($Mode -eq 'task') {
            $result = Invoke-FmTask $owner -Inputs @{ File=(Get-Command powershell.exe).Source; Args=@('-NoProfile', '-Command', $command) } -Work {
                $commandResult = Invoke-ShortCommand -FilePath $Inputs.File -ArgumentList $Inputs.Args -TimeoutMs 15000 -Control $Control
                [pscustomobject]@{ Info=@{}; Connected=@(); Ok=($commandResult.ExitCode -eq 0); Cancelled=$commandResult.Cancelled }
            }
        } else {
            # Exercise the real transfer function, including its process wait loop and Kill call.
            $adb = (Get-Command powershell.exe).Source
            $result = Fm-Transfer @('-NoProfile', '-Command', $command) $window $null 'fixture' $null $root
        }
        Check ($cancellation.Closed -and $null -ne $cancellation.Child) "$Mode child did not reach the close fixture"
        $elapsed = $cancellation.CloseWatch.ElapsedMilliseconds
        Check ($elapsed -lt 5000) "$Mode cancellation took $elapsed ms after close (limit 5000 ms)"
        $cancelled = if ($Mode -eq 'task') { $result.Cancelled } else { $result.Aborted }
        Check ($cancelled -and -not $result.Ok) "$Mode did not report cancellation"
        Check $cancellation.Child.HasExited "$Mode child process is still running after close"
        if ($Mode -eq 'task') {
            Check (-not $script:deviceScanState.Active -and $script:deviceScanState.Pending.Count -eq 0) 'Cancelled task leaked in queue'
        }
        "PASS $Mode process terminated within $elapsed ms after close"
    } finally {
        $timer.Stop(); $timer.Dispose()
        if ($owner) { $owner.Dispose(); Stop-DeviceScans }
        # Broken cancellation must fail without leaving the fixture child running in CI.
        if ($cancellation.Child) {
            try {
                if (-not $cancellation.Child.HasExited) {
                    $cancellation.Child.Kill()
                    [void]$cancellation.Child.WaitForExit(2000)
                }
            } finally { $cancellation.Child.Dispose() }
        }
    }
}
Test-ProcessCancellation 'task'
Test-ProcessCancellation 'transfer'
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
