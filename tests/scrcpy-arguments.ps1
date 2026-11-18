$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path (Split-Path $PSScriptRoot) 'scrcpy-helper.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join [Environment]::NewLine) }
foreach ($name in @('Start-Scrcpy','Split-WindowsArguments','Fm-WinArg')) {
    $definition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Check($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Arguments($Actual, $Expected, [string]$Label) {
    Check ($Actual.Count -eq $Expected.Count) "$Label had $($Actual.Count) arguments, expected $($Expected.Count)"
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        Check ([string]::Equals($Actual[$index], $Expected[$index], [StringComparison]::Ordinal)) (
            "$Label argument $index expected [$($Expected[$index])], received [$($Actual[$index])]")
    }
}

$splitCases = @(
    @{ Text=''; Values=@() },
    @{ Text=('  --angle=90' + [char]9 + '--time-limit=300  '); Values=@('--angle=90','--time-limit=300') },
    @{ Text='--window-title="Living Room" --angle=90'; Values=@('--window-title=Living Room','--angle=90') },
    @{ Text='"a b"mid" c" C:\plain\'; Values=@('a bmid c','C:\plain\') },
    @{ Text='--window-title="He said ""hello"""'; Values=@('--window-title=He said "hello"') },
    @{ Text='--push-target="C:\Phone Files\\" ""'; Values=@('--push-target=C:\Phone Files\','') },
    @{ Text='--window-title="A\\\"B"'; Values=@('--window-title=A\"B') },
    @{ Text='--window-title="Still one value'; Values=@('--window-title=Still one value') }
)
foreach ($case in $splitCases) {
    Assert-Arguments @(Split-WindowsArguments $case.Text) $case.Values "Split [$($case.Text)]"
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy-argv-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$argSpy = Join-Path $testRoot 'argument spy.ps1'
$hostExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$stdout = Join-Path $testRoot 'stdout.txt'
$stderr = Join-Path $testRoot 'stderr.txt'
$fixture = @{}
$exe = 'fixture-scrcpy'
$form = @{}
function Get-FriendlyName { return 'Test phone' }
function Wait-ScrcpyWindow { param($Proc, $Title) $fixture.Title = $Title; return 'shown' }
function Start-Process {
    param($FilePath, [string]$ArgumentList, $WorkingDirectory, [switch]$PassThru, $WindowStyle)
    $process = $null
    try {
        Check ($FilePath -eq $exe) 'Raw argument test tried to launch an unexpected executable'
        $command = '-NoProfile -ExecutionPolicy Bypass -File ' + (Fm-WinArg $argSpy) + ' ' + $ArgumentList
        $launch = @{
            FilePath=$hostExe; ArgumentList=$command; WorkingDirectory=$testRoot; PassThru=$true
            WindowStyle='Hidden'; RedirectStandardOutput=$stdout; RedirectStandardError=$stderr
        }
        $process = Microsoft.PowerShell.Management\Start-Process @launch
        # Keep the process handle so Windows PowerShell can read ExitCode after it exits.
        $null = $process.Handle
        Check ($process.WaitForExit(15000)) 'Argument spy timed out'
        Check ($process.ExitCode -eq 0) "Argument spy exited with [$($process.ExitCode)]. $([IO.File]::ReadAllText($stderr))"
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([IO.File]::ReadAllText($stdout).Trim()))
        $fixture.Actual = (ConvertFrom-Json -InputObject $json).Arguments
        return [pscustomobject]@{ HasExited=$false }
    } catch {
        $fixture.LaunchError = $_.Exception.Message
    } finally {
        if ($process) {
            if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(2000) }
            $process.Dispose()
        }
    }
}
try {
    [IO.File]::WriteAllText($argSpy, @'
# Read OS arguments before interpreting PowerShell script parameters.
$argv = @([Environment]::GetCommandLineArgs() | Select-Object -Skip 6)
$json = ConvertTo-Json -InputObject @{ Arguments=$argv } -Compress
[Console]::WriteLine([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)))
'@)
    $launchCases = @(
        @{
            Extra='--window-title="Living Room" --angle=90'; Title='Living Room'; Rec=$false
            Values=@('-s','test-device','--window-title=Living Room','--angle=90')
        },
        @{
            Extra='--window-title "房间 \"东\"" --record="C:\My Videos\clip.mp4" --push-target="C:\Phone Files\\" ""'
            Title='房间 "东"'; Rec=$true; BuiltInTitle='--window-title=Test phone · App'
            Values=@('-s','test-device','--window-title=Test phone · App','--window-title','房间 "东"',
                '--record=C:\My Videos\clip.mp4','--push-target=C:\Phone Files\','')
        }
    )
    foreach ($case in $launchCases) {
        $fixture.Clear()
        $settings = @{ extraArgs=$case.Extra; showConsole=$false }
        $scrcpyProcs = [Collections.ArrayList]::new()
        Start-Scrcpy @('-s','test-device','',$case.BuiltInTitle)
        Check (-not $fixture.LaunchError) "Argument spy failed: $($fixture.LaunchError)"
        Assert-Arguments $fixture.Actual $case.Values 'Child process'
        Check ($fixture.Title -ceq $case.Title) 'Startup used the wrong window title'
        Check ($scrcpyProcs.Count -eq 1 -and $scrcpyProcs[0].Rec -eq $case.Rec) 'Process registration did not use the parsed options'
    }
} finally {
    foreach ($file in [IO.Directory]::GetFiles($testRoot)) { [IO.File]::Delete($file) }
    [IO.Directory]::Delete($testRoot)
}
'PASS scrcpy command-line argument regression on PowerShell ' + $PSVersionTable.PSVersion
