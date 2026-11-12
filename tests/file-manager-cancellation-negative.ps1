param(
    [ValidateRange(0, 40000)][int]$TaskStartupDelayMs = 0,
    [ValidateRange(1, 60000)][int]$ParentTimeoutMs = 45000,
    [string]$EvidencePath = ''
)
. (Join-Path $PSScriptRoot 'file-manager-test-support.ps1')
. (Join-Path $PSScriptRoot 'file-manager-process-support.ps1')
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
$evidence = if ($EvidencePath) { $EvidencePath } else { Join-Path $root 'child-evidence.jsonl' }
$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $testDirectory 'file-manager-cancellation.ps1'),
               '-TaskCloseDelayMs', '12500', '-TaskStartupDelayMs', [string]$TaskStartupDelayMs, '-EvidencePath', $evidence)
$psi.Arguments = (@($arguments | ForEach-Object { Fm-WinArg $_ }) -join ' ')
$psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
$psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
$process = [Diagnostics.Process]::Start($psi)
try {
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    Check ($process.WaitForExit($ParentTimeoutMs)) 'Negative cancellation fixture timed out'
    $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    Check ($process.ExitCode -ne 0) 'Delayed close with active cancellation disabled incorrectly passed'
    Check ($output.Contains('Insufficient command timeout margin at close')) 'Negative fixture failed for an unrelated reason'
    Check (Test-Path -LiteralPath $evidence) 'Negative fixture did not record child identity'
    $records = @([IO.File]::ReadAllLines($evidence) | ForEach-Object { $_ | ConvertFrom-Json })
    $started = @([IO.File]::ReadAllText("$evidence.task.started.json") | ConvertFrom-Json)
    $cleaned = @($records | Where-Object { $_.Phase -eq 'cleaned' -and $_.Mode -eq 'task' })
    Check ($started.Count -eq 1 -and $cleaned.Count -eq 1) 'Child cleanup evidence is incomplete'
    Check ($started[0].Id -eq $cleaned[0].Id -and $started[0].StartTicks -eq $cleaned[0].StartTicks -and $cleaned[0].Exited) 'Failed test did not clean up its original child'
    Check ($cleaned[0].TimeoutRemainingMs -lt 6000) 'Negative fixture did not reproduce insufficient timeout margin'
    $child = Get-FixtureProcess $started[0]
    try { Check ($null -eq $child) 'Fixture child survived the failed test' }
    finally { if ($child) { $child.Dispose() } }
    'PASS delayed close without active cancellation fails on timeout margin and cleans up child on PowerShell ' + $PSVersionTable.PSVersion
} finally {
    try {
        if (-not $process.HasExited) {
            $process.Kill()
            Check ($process.WaitForExit(2000)) 'Negative fixture host did not terminate'
        }
    } finally {
        try { Stop-FixtureProcesses $evidence }
        finally { $process.Dispose() }
    }
}
