param([string]$EvidencePath = '')
. (Join-Path $PSScriptRoot 'file-manager-test-support.ps1')
. (Join-Path $PSScriptRoot 'file-manager-process-support.ps1')
$evidence = if ($EvidencePath) { $EvidencePath } else { Join-Path $root 'timeout-evidence.jsonl' }
$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
# Shorten only this watchdog; the child must start late and the parent must expire before close.
$arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'file-manager-cancellation-negative.ps1'),
               '-TaskStartupDelayMs', '3000', '-ParentTimeoutMs', '10000', '-EvidencePath', $evidence)
$psi.Arguments = (@($arguments | ForEach-Object { Fm-WinArg $_ }) -join ' ')
$psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
$psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
$process = [Diagnostics.Process]::Start($psi)
$child = $null
try {
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not $process.WaitForExit(100)) {
        Check ($watch.ElapsedMilliseconds -lt 45000) 'Parent timeout regression hung'
        if (-not $child -and (Test-Path -LiteralPath "$evidence.task.started.json")) {
            $identity = [IO.File]::ReadAllText("$evidence.task.started.json") | ConvertFrom-Json
            $child = Get-FixtureProcess $identity
        }
    }
    Check ([Threading.Tasks.Task]::WaitAll(@($stdout, $stderr), 2000)) 'Fixture child kept parent output pipes open after failure'
    $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    Check ($process.ExitCode -ne 0 -and $output.Contains('Negative cancellation fixture timed out')) 'Fixture did not fail at the parent watchdog'
    Check ($null -ne $child) 'Parent timed out before recording a running fixture child'
    Check ($identity.StartupElapsedMs -ge 3000) 'Fixture did not delay process startup'
    Check (Test-Path -LiteralPath $evidence) 'Parent did not publish cleanup evidence'
    $records = @([IO.File]::ReadAllLines($evidence) | ForEach-Object { $_ | ConvertFrom-Json })
    Check (@($records | Where-Object { $_.Phase -eq 'closed' -or $_.Phase -eq 'cleaned' }).Count -eq 0) 'Fixture reached close or child-side cleanup before the parent watchdog'
    $cleaned = @($records | Where-Object { $_.Phase -eq 'parent-cleaned' -and $_.Mode -eq 'task' })
    Check ($cleaned.Count -eq 1 -and $cleaned[0].WasRunning -and $cleaned[0].Exited) 'Parent did not terminate the still-running fixture child'
    Check ($cleaned[0].Id -eq $identity.Id -and $cleaned[0].StartTicks -eq $identity.StartTicks) 'Parent cleaned a different process'
    Check $child.HasExited 'Fixture child survived parent timeout cleanup'
    $remaining = Get-FixtureProcess $identity
    try { Check ($null -eq $remaining) 'Fixture child is still registered as running after parent failure' }
    finally { if ($remaining) { $remaining.Dispose() } }
    'PASS delayed startup and parent timeout before close leave no child process on PowerShell ' + $PSVersionTable.PSVersion
} finally {
    try {
        if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(2000) }
    } finally {
        try {
            # This independent readiness record also contains a broken launch-registration mutation.
            if (-not $child -and (Test-Path -LiteralPath "$evidence.task.ready.json")) {
                $child = Get-FixtureProcess ([IO.File]::ReadAllText("$evidence.task.ready.json") | ConvertFrom-Json)
            }
            if ($child -and -not $child.HasExited) {
                $child.Kill()
                Check ($child.WaitForExit(2000) -and $child.HasExited) 'Regression safety cleanup did not terminate its child'
            }
        } finally {
            if ($child) { $child.Dispose() }
            $process.Dispose()
        }
    }
}
