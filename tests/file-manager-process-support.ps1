function Get-FixtureProcessDefinition([string]$Name, [string]$ProcessVariable, [string]$IdentityPath, [string]$Mode) {
    $definition = (Get-Item "function:$Name").Definition
    $start = if ($Name -eq 'Invoke-ShortCommand') { '$proc = [Diagnostics.Process]::Start($psi)' }
             else { '$p = [System.Diagnostics.Process]::Start($psi)' }
    Check ($definition.Contains($start)) "$Name process start observer did not match"
    # Observe the real launch, before interpreter startup or any UI callback can delay registration.
    $registration = @'
try {
    $null = __PROCESS__.Handle
    $identity = [pscustomobject]@{ Phase='started'; Mode='__MODE__'; Id=__PROCESS__.Id; StartTicks=__PROCESS__.StartTime.ToUniversalTime().Ticks; StartupElapsedMs=__STARTUP__ }
    [IO.File]::WriteAllText('__PATH__.tmp', ($identity | ConvertTo-Json -Compress))
    [IO.File]::Move('__PATH__.tmp', '__PATH__')
} catch {
    try { if (-not __PROCESS__.HasExited) { __PROCESS__.Kill(); [void]__PROCESS__.WaitForExit(2000) } } finally { __PROCESS__.Dispose() }
    throw
}
'@
    $startup = if ($Mode -eq 'task') { '$Inputs.Timing.StartupWatch.ElapsedMilliseconds' } else { '0' }
    $registration = $registration.Replace('__PROCESS__', $ProcessVariable).Replace('__MODE__', $Mode).Replace('__STARTUP__', $startup).Replace('__PATH__', $IdentityPath.Replace("'", "''"))
    return ("function $Name { " + $definition.Replace($start, ($start + ";`n" + $registration)) + "`n}")
}

function Get-FixtureProcess($Identity) {
    $process = Get-Process -Id $Identity.Id -ErrorAction SilentlyContinue
    if (-not $process) { return $null }
    try {
        # Hold the handle before checking identity so later Kill cannot follow a recycled PID.
        $null = $process.Handle
        if (-not $process.HasExited -and $process.StartTime.ToUniversalTime().Ticks -eq $Identity.StartTicks) { return $process }
    } catch {
        if (Get-Process -Id $Identity.Id -ErrorAction SilentlyContinue) { $process.Dispose(); throw }
    }
    $process.Dispose()
    return $null
}

function Stop-FixtureProcesses([string]$EvidencePath) {
    foreach ($mode in @('task', 'transfer')) {
        $identityPath = "$EvidencePath.$mode.started.json"
        if (-not (Test-Path -LiteralPath $identityPath)) { continue }
        $identity = [IO.File]::ReadAllText($identityPath) | ConvertFrom-Json
        $child = Get-FixtureProcess $identity
        try {
            $wasRunning = $null -ne $child
            if ($child) {
                $child.Kill()
                Check ($child.WaitForExit(2000) -and $child.HasExited) 'Parent cleanup did not terminate its fixture child'
            }
            $record = [pscustomobject]@{
                Phase='parent-cleaned'; Mode=$mode; Id=$identity.Id; StartTicks=$identity.StartTicks
                WasRunning=$wasRunning; Exited=($null -eq $child -or $child.HasExited)
            }
            [IO.File]::AppendAllText($EvidencePath, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine))
        } finally { if ($child) { $child.Dispose() } }
    }
}
