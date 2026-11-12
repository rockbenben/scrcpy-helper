. (Join-Path $PSScriptRoot 'file-manager-test-support.ps1')
$workspace = Join-Path $root 'negative-workspace'
$testDirectory = Join-Path $workspace 'tests'
[void][IO.Directory]::CreateDirectory($testDirectory)
foreach ($file in @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File)) {
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $testDirectory $file.Name)
}
# Restrict the deliberate mutation to a temporary copy of the task wrapper.
$definition = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-FmTask'
}, $true).Extent.Text
$mutated = $definition.Replace('Cancel-OwnerTasks $Owner', '$null')
Check ($mutated -ne $definition) 'Active cancellation mutation did not match the task wrapper'
$source = [IO.File]::ReadAllText((Join-Path $repo 'scrcpy-helper.ps1'))
Check ($source.Contains($definition)) 'Task wrapper did not match the source being copied'
$source = $source.Replace($definition, $mutated)
[IO.File]::WriteAllText((Join-Path $workspace 'scrcpy-helper.ps1'), $source, (New-Object Text.UTF8Encoding($true)))
$evidence = Join-Path $root 'child-evidence.jsonl'
$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $testDirectory 'file-manager-cancellation.ps1'),
               '-TaskCloseDelayMs', '12500', '-EvidencePath', $evidence)
$psi.Arguments = (@($arguments | ForEach-Object { Fm-WinArg $_ }) -join ' ')
$psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
$psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
$process = [Diagnostics.Process]::Start($psi)
$stdout = $process.StandardOutput.ReadToEndAsync()
$stderr = $process.StandardError.ReadToEndAsync()
try {
    Check ($process.WaitForExit(45000)) 'Negative cancellation fixture timed out'
    $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    Check ($process.ExitCode -ne 0) 'Delayed close with active cancellation disabled incorrectly passed'
    Check ($output.Contains('Insufficient command timeout margin at close')) 'Negative fixture failed for an unrelated reason'
    Check (Test-Path -LiteralPath $evidence) 'Negative fixture did not record child identity'
    $records = @([IO.File]::ReadAllLines($evidence) | ForEach-Object { $_ | ConvertFrom-Json })
    $started = @($records | Where-Object { $_.Phase -eq 'started' -and $_.Mode -eq 'task' })
    $cleaned = @($records | Where-Object { $_.Phase -eq 'cleaned' -and $_.Mode -eq 'task' })
    Check ($started.Count -eq 1 -and $cleaned.Count -eq 1) 'Child cleanup evidence is incomplete'
    Check ($started[0].Id -eq $cleaned[0].Id -and $started[0].StartTicks -eq $cleaned[0].StartTicks -and $cleaned[0].Exited) 'Failed test did not clean up its original child'
    Check ($cleaned[0].TimeoutRemainingMs -lt 6000) 'Negative fixture did not reproduce insufficient timeout margin'
    $child = Get-Process -Id $started[0].Id -ErrorAction SilentlyContinue
    if ($child) {
        try { Check ($child.StartTime.ToUniversalTime().Ticks -ne $started[0].StartTicks) 'Fixture child survived the failed test' }
        finally { $child.Dispose() }
    }
    'PASS delayed close without active cancellation fails on timeout margin and cleans up child on PowerShell ' + $PSVersionTable.PSVersion
} finally {
    if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(2000) }
    $process.Dispose()
    # Also contain an unexpected fixture crash or timeout, matching identity before killing anything.
    if (Test-Path -LiteralPath $evidence) {
        foreach ($record in @([IO.File]::ReadAllLines($evidence) | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.Phase -eq 'started' })) {
            $child = Get-Process -Id $record.Id -ErrorAction SilentlyContinue
            if ($child) {
                try {
                    if ($child.StartTime.ToUniversalTime().Ticks -eq $record.StartTicks) {
                        $child.Kill(); [void]$child.WaitForExit(2000)
                    }
                } finally { $child.Dispose() }
            }
        }
    }
}
