param(
    [ValidateRange(0, 20000)][int]$TaskCloseDelayMs = 0,
    [ValidateRange(0, 40000)][int]$TaskStartupDelayMs = 0,
    [string]$EvidencePath = ''
)
. (Join-Path $PSScriptRoot 'file-manager-test-support.ps1')
. (Join-Path $PSScriptRoot 'file-manager-process-support.ps1')
if (-not $EvidencePath) { $EvidencePath = Join-Path $root 'child-evidence.jsonl' }
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
    $identityPath = "$EvidencePath.$Mode.started.json"
    $name = if ($Mode -eq 'task') { 'Invoke-ShortCommand' } else { 'Fm-Transfer' }
    $variable = if ($Mode -eq 'task') { '$proc' } else { '$p' }
    Invoke-Expression (Get-FixtureProcessDefinition $name $variable $identityPath $Mode)
    $owner = if ($Mode -eq 'task') { New-Object Windows.Forms.Form } else { $null }
    $window = @{ Visible=$true; IsDisposed=$false }
    $timer = New-Object Windows.Forms.Timer
    $childIdFile = "$EvidencePath.$Mode.ready.json"
    $escapedPath = $childIdFile.Replace("'", "''")
    # Keep readiness independent of the launch observer so broken registration can still be contained.
    $command = "`$identity = [pscustomobject]@{ Id=`$PID; StartTicks=[Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks }; [IO.File]::WriteAllText('$escapedPath.tmp', (`$identity | ConvertTo-Json -Compress)); [IO.File]::Move('$escapedPath.tmp','$escapedPath'); Start-Sleep -Seconds 30"
    $startup = [Diagnostics.Stopwatch]::StartNew()
    $taskTiming = [hashtable]::Synchronized(@{ Watch=$null; StartupWatch=$null })
    $commandTimeoutMs = 15000
    $closeDelayMs = if ($Mode -eq 'task') { $TaskCloseDelayMs } else { 0 }
    $startupLimitMs = [Math]::Max(12000, ($closeDelayMs + 5000))
    $cancellation = @{ Child=$null; Closed=$false; CloseWatch=$null; TimeoutRemainingMs=$null }
    $timer.Interval = 50
    $timer.Add_Tick({
        $ready = Test-Path -LiteralPath $childIdFile
        $delayElapsed = if ($Mode -eq 'task' -and $taskTiming.Watch) { $taskTiming.Watch.ElapsedMilliseconds }
                        else { $startup.ElapsedMilliseconds }
        if (($ready -and $delayElapsed -ge $closeDelayMs) -or $startup.ElapsedMilliseconds -gt $startupLimitMs) {
            $timer.Stop()
            if ($ready) {
                $identity = [IO.File]::ReadAllText($childIdFile) | ConvertFrom-Json
                $cancellation.Child = Get-FixtureProcess $identity
                Check ($null -ne $cancellation.Child) 'Ready fixture child already exited'
            }
            $cancellation.Closed = $true
            $cancellation.CloseWatch = [Diagnostics.Stopwatch]::StartNew()
            if ($taskTiming.Watch) {
                $cancellation.TimeoutRemainingMs = $commandTimeoutMs - $taskTiming.Watch.ElapsedMilliseconds
            }
            $record = [pscustomobject]@{ Phase='closed'; Mode=$Mode; TimeoutRemainingMs=$cancellation.TimeoutRemainingMs }
            [IO.File]::AppendAllText($EvidencePath, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine))
            if ($owner) { $owner.Dispose() }
            else { $window.Visible=$false; $window.IsDisposed=$true }
        }
    })
    try {
        $timer.Start()
        if ($Mode -eq 'task') {
            $result = Invoke-FmTask $owner -Inputs @{ File=(Get-Command powershell.exe).Source; Args=@('-NoProfile', '-Command', $command); Timing=$taskTiming; TimeoutMs=$commandTimeoutMs; StartupDelayMs=$TaskStartupDelayMs } -Work {
                $Inputs.Timing.StartupWatch = [Diagnostics.Stopwatch]::StartNew()
                if ($Inputs.StartupDelayMs) { Start-Sleep -Milliseconds $Inputs.StartupDelayMs }
                # Starting just before the command gives the UI a conservative timeout budget.
                $Inputs.Timing.Watch = [Diagnostics.Stopwatch]::StartNew()
                $commandResult = Invoke-ShortCommand -FilePath $Inputs.File -ArgumentList $Inputs.Args -TimeoutMs $Inputs.TimeoutMs -Control $Control
                [pscustomobject]@{ Info=@{}; Connected=@(); Ok=($commandResult.ExitCode -eq 0); Cancelled=$commandResult.Cancelled }
            }
        } else {
            # Exercise the real transfer function, including its process wait loop and Kill call.
            $adb = (Get-Command powershell.exe).Source
            $result = Fm-Transfer @('-NoProfile', '-Command', $command) $window $null 'fixture' $null $root
        }
        Check ($cancellation.Closed -and $null -ne $cancellation.Child) "$Mode child did not reach the close fixture"
        if ($Mode -eq 'task') {
            # A fallback deadline inside the cancellation window cannot prove proactive cancellation.
            Check ($cancellation.TimeoutRemainingMs -ge 6000) "Insufficient command timeout margin at close: $($cancellation.TimeoutRemainingMs) ms (minimum 6000 ms)"
        }
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
        try {
            $timer.Stop(); $timer.Dispose()
            if ($owner) { $owner.Dispose(); Stop-DeviceScans }
        } finally {
            # Even an assertion or task teardown failure must not leave the fixture child alive.
            if (-not $cancellation.Child -and (Test-Path -LiteralPath $identityPath)) {
                $cancellation.Child = Get-FixtureProcess ([IO.File]::ReadAllText($identityPath) | ConvertFrom-Json)
            }
            if ($cancellation.Child) {
                try {
                    if (-not $cancellation.Child.HasExited) {
                        $cancellation.Child.Kill()
                        [void]$cancellation.Child.WaitForExit(2000)
                    }
                } finally {
                    try {
                        if ($EvidencePath) {
                            $record = [pscustomobject]@{
                                Phase='cleaned'; Mode=$Mode; Id=$cancellation.Child.Id
                                StartTicks=$cancellation.Child.StartTime.ToUniversalTime().Ticks
                                Exited=$cancellation.Child.HasExited
                                TimeoutRemainingMs=$cancellation.TimeoutRemainingMs
                            }
                            [IO.File]::AppendAllText($EvidencePath, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine))
                        }
                    } finally { $cancellation.Child.Dispose() }
                }
            }
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
