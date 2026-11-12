. (Join-Path $PSScriptRoot 'file-manager-test-support.ps1')
. (Join-Path $PSScriptRoot 'file-manager-process-support.ps1')

function Receive-MutationChildren([string]$Evidence, [hashtable]$Children) {
    foreach ($mode in @('task', 'transfer')) {
        # Readiness is independent of registration, which one of the cases deliberately disables.
        foreach ($suffix in @('started.json', 'ready.json')) {
            $path = "$Evidence.$mode.$suffix"
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $identity = [IO.File]::ReadAllText($path) | ConvertFrom-Json
            $key = '{0}:{1}' -f $identity.Id, $identity.StartTicks
            if ($Children.ContainsKey($key)) { continue }
            $child = Get-FixtureProcess $identity
            if ($child) { $Children[$key] = @{ Process=$child; Identity=$identity; Mode=$mode } }
        }
    }
}

function Test-CancellationMutation($Case) {
    $workspace = Join-Path $root $Case.Name
    $testDirectory = Join-Path $workspace 'tests'
    [void][IO.Directory]::CreateDirectory($testDirectory)
    foreach ($file in @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File)) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $testDirectory $file.Name)
    }
    Copy-Item -LiteralPath (Join-Path $repo 'scrcpy-helper.ps1') -Destination $workspace
    $path = Join-Path $workspace $Case.Source
    $source = [IO.File]::ReadAllText($path)
    $body = if ($Case.Function) {
        $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Case.Function
        }, $true).Extent.Text
    } else { $source }
    Check ($body -and $source.Contains($body)) "$($Case.Name) mutation source did not match"
    Check ([regex]::Matches($body, [regex]::Escape($Case.Before)).Count -eq $Case.Matches) "$($Case.Name) mutation did not match the expected sites"
    $mutated = $body.Replace($Case.Before, '$null')
    [IO.File]::WriteAllText($path, $source.Replace($body, $mutated), (New-Object Text.UTF8Encoding($true)))

    $evidence = Join-Path $workspace 'evidence.jsonl'
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $testDirectory $Case.Script), '-EvidencePath', $evidence)
    $psi.Arguments = (@($arguments | ForEach-Object { Fm-WinArg $_ }) -join ' ')
    $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    $testProcess = [Diagnostics.Process]::Start($psi)
    $children = @{}
    try {
        $stdout = $testProcess.StandardOutput.ReadToEndAsync()
        $stderr = $testProcess.StandardError.ReadToEndAsync()
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (-not $testProcess.WaitForExit(100)) {
            Check ($watch.ElapsedMilliseconds -lt 60000) "$($Case.Name) mutation fixture hung"
            Receive-MutationChildren $evidence $children
        }
        Check ($testProcess.ExitCode -ne 0) "$($Case.Name) mutation incorrectly passed"
        Check (@($children.Values | Where-Object { $_.Mode -eq $Case.Mode }).Count -gt 0) "$($Case.Name) did not exercise a running target child"
        $ready = @(Get-ChildItem -LiteralPath $workspace -Filter 'evidence.jsonl.*.ready.json' -File)
        Check ($ready.Count -eq $Case.ReadyCount) "$($Case.Name) did not reach the expected process fixtures"
        # Check before this harness's finally: safety cleanup must not conceal a leaking failed test.
        foreach ($entry in @($children.Values)) {
            Check $entry.Process.HasExited "$($Case.Name) left a captured child running after failure"
        }
        foreach ($file in $ready) {
            $remaining = Get-FixtureProcess ([IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json)
            try { Check ($null -eq $remaining) "$($Case.Name) left a child running after failure" }
            finally { if ($remaining) { $remaining.Dispose() } }
        }
        Check ([Threading.Tasks.Task]::WaitAll(@($stdout, $stderr), 2000)) "$($Case.Name) left output pipes open"
        $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        Check (@($Case.Errors | Where-Object { $output.Contains($_) }).Count -gt 0) "$($Case.Name) failed for an unrelated reason: $output"
        "PASS mutation $($Case.Name): expected failure and no child processes remain"
    } finally {
        try {
            if (-not $testProcess.HasExited) {
                $testProcess.Kill()
                Check ($testProcess.WaitForExit(2000)) "$($Case.Name) test host did not terminate"
            }
        } finally {
            try {
                Receive-MutationChildren $evidence $children
                foreach ($entry in @($children.Values)) {
                    try {
                        if (-not $entry.Process.HasExited) {
                            $entry.Process.Kill()
                            Check ($entry.Process.WaitForExit(2000) -and $entry.Process.HasExited) "$($Case.Name) safety cleanup failed"
                        }
                    } finally { $entry.Process.Dispose() }
                }
            } finally { $testProcess.Dispose() }
        }
    }
}

$cases = @(
    @{ Name='active-cancel'; Source='scrcpy-helper.ps1'; Function='Invoke-FmTask'; Before='Cancel-OwnerTasks $Owner'; Matches=2
       Script='file-manager-cancellation.ps1'; Mode='task'; ReadyCount=1; Errors=@('task cancellation took ') },
    @{ Name='transfer-kill'; Source='scrcpy-helper.ps1'; Function='Fm-Transfer'; Before='$p.Kill()'; Matches=1
       Script='file-manager-cancellation.ps1'; Mode='transfer'; ReadyCount=2; Errors=@('transfer child process is still running after close', 'transfer cancellation took ') },
    @{ Name='startup-registration'; Source='tests/file-manager-process-support.ps1'; Before="[IO.File]::Move('__PATH__.tmp', '__PATH__')"; Matches=1
       Script='file-manager-cancellation-timeout.ps1'; Mode='task'; ReadyCount=1
       Errors=@('Fixture child kept parent output pipes open after failure', 'Parent timed out before recording a running fixture child') },
    @{ Name='parent-cleanup'; Source='tests/file-manager-cancellation-negative.ps1'; Before='Stop-FixtureProcesses $evidence'; Matches=1
       Script='file-manager-cancellation-timeout.ps1'; Mode='task'; ReadyCount=1
       Errors=@('Fixture child kept parent output pipes open after failure', 'Parent did not publish cleanup evidence', 'Parent did not terminate the still-running fixture child') }
)
foreach ($case in $cases) { Test-CancellationMutation $case }
'PASS all cancellation mutation regressions on PowerShell ' + $PSVersionTable.PSVersion
